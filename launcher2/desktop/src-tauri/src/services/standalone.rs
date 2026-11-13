//! Native standalone execution. The executable and hashes come from the bundled
//! catalog, never from arbitrary UI paths or shell commands.
use crate::services::{catalog, inventory, verify};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{atomic::AtomicBool, Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, State};

#[derive(Default)]
pub struct RuntimeState {
    running: Arc<Mutex<HashMap<String,u32>>>,
    launching: Arc<Mutex<Option<String>>>,
    // A tiny, bounded in-memory ancestry hint. Game bootstrappers frequently
    // exit before the real child does. This is not persisted or a game lease.
    launch_ancestors: Arc<Mutex<Vec<LaunchAncestor>>>,
}

#[derive(Clone, Debug)]
struct LaunchAncestor { game_id:String, pid:u32, started:Instant }

const ANCESTOR_TTL:Duration=Duration::from_secs(8*60*60);
#[cfg(windows)]
const CREATE_SUSPENDED:u32=0x0000_0004;
/// Fixes show their credits box while the game boots; a long margin costs nothing.
const GUARD_CREDITS_FOR:Duration=Duration::from_secs(10*60);

#[derive(Clone, Serialize)]
#[serde(rename_all="camelCase")]
pub struct RuntimeEvent {
    id:String,
    state:&'static str,
    pid:Option<u32>,
    exit_code:Option<i32>,
}

/// A current OS-process observation, not just the Child handle launched by
/// this Coco process. Only game-associated IDs/PIDs are sent to the frontend;
/// paths and names of other users' processes never leave native code.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all="camelCase")]
pub struct ActiveGameProcess {
    pub pid: u32,
    pub game_id: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all="camelCase")]
pub struct ActiveGameProcessReport {
    /// none only when no known game is observed and no relevant uncertainty
    pub status: &'static str,
    /// The updater must also recheck immediately before installing.
    pub safe_to_update: bool,
    pub game_ids: Vec<String>,
    pub process_count: usize,
    pub unknown_candidates: usize,
    pub matched_processes: Vec<ActiveGameProcess>,
}

#[derive(Clone, Debug)]
struct KnownGameRoot {
    id: String,
    /// Original registered root and physical canonical root may differ when a
    /// custom location is an alias. Only canonical paths prove membership.
    registered: PathBuf,
    canonical: PathBuf,
    executable_name: String,
}

#[derive(Clone, Debug)]
struct ObservedProcess {
    pid: u32,
    parent_pid: u32,
    executable_name: String,
    executable_path: Option<PathBuf>,
}

fn unknown_process_report() -> ActiveGameProcessReport {
    ActiveGameProcessReport { status:"unknown", safe_to_update:false,
        game_ids:Vec::new(), process_count:0, unknown_candidates:1,
        matched_processes:Vec::new() }
}

/// Case-insensitive component-aware match, independent of the separator
/// spelling returned by Win32 QueryFullProcessImageNameW or canonicalize.
/// A sibling like C:\\Games\\demo-old is not within C:\\Games\\demo.
fn win_path_key(path:&Path)->String {
    let text=path.to_string_lossy();
    let path=text.strip_prefix(r"\\?\").unwrap_or(&text);
    path.replace('\\',"/").trim_end_matches('/').to_lowercase()
}

fn within_root(path:&Path,root:&Path)->bool {
    let file=win_path_key(path);
    let base=win_path_key(root);
    !base.is_empty() && file.len()>base.len()
        && file.starts_with(&base) && file.as_bytes().get(base.len())==Some(&b'/')
}

/// Find a unique best root; nested registered installations choose the
/// deepest one. Equal canonical roots with different IDs are ambiguous.
fn match_game_root<'a>(path:&Path,roots:&'a [KnownGameRoot])->Result<Option<&'a str>,()> {
    let mut longest=0usize;
    let mut candidate=None;
    for root in roots {
        if !within_root(path,&root.canonical) {continue;}
        let length=win_path_key(&root.canonical).len();
        if length>longest {longest=length;candidate=Some(root.id.as_str());}
        else if length==longest && candidate!=Some(root.id.as_str()) {return Err(());}
    }
    Ok(candidate)
}

fn expected_executable_name(executable:&str)->Option<String> {
    let path=verify::safe_relative_path(executable)?;
    let name=path.file_name()?.to_str()?.to_lowercase();
    if name.ends_with(".exe") && name.len()>4 {Some(name)}else{None}
}

/// Java runtimes do not live inside a managed Minecraft instance root, and
/// the process image path alone cannot prove which world a JVM is running.
/// Treat these as *unknown*, never a safe-to-update report. This intentionally
/// trades false positives for not replacing Coco while Minecraft may be live.
/// No arbitrary process paths or command lines are exposed to the frontend.
fn potentially_active_minecraft(name:&str)->bool {
    matches!(name.to_ascii_lowercase().as_str(),
        "java.exe"|"javaw.exe"|"minecraft.windows.exe")
}

/// Builds only local registered standalone roots. Missing installations are
/// harmless; malformed or unreadable registered locations are uncertain.
fn registered_game_roots(entries:&[catalog::Experience],app_data:&Path,
                         locations:&serde_json::Map<String,serde_json::Value>)
    ->Result<Vec<KnownGameRoot>,String>
{
    let mut roots=Vec::new();
    for entry in entries.iter().filter(|e|e.workflow=="coco-standalone") {
        let root=inventory::resolve_instance_root(entry,app_data,locations);
        if !root.is_absolute() || root.to_string_lossy().starts_with("\\\\") {
            return Err("A standalone instance has an unknown or remote location".into());
        }
        let name=expected_executable_name(&entry.executable)
            .ok_or("A standalone executable is not a valid relative EXE")?;
        match fs::metadata(&root) {
            Ok(metadata) if metadata.is_dir() => {
                let physical=fs::canonicalize(&root)
                    .map_err(|_|"Cannot verify a registered standalone root")?;
                roots.push(KnownGameRoot{id:entry.id.clone(),registered:root,
                    canonical:physical,executable_name:name});
            }
            Ok(_) => return Err("A registered standalone location is not a directory".into()),
            Err(error) if error.kind()==std::io::ErrorKind::NotFound => {},
            Err(_) => return Err("Cannot inspect a registered standalone location".into()),
        }
    }
    Ok(roots)
}

/// Pure classifier; suitable for synthetic test snapshots. A resolved path
/// within a registered game root is authoritative even if the game was started
/// externally or by a previous Coco process. Children of those processes are
/// conservatively associated with the game, even if their image lives outside
/// the root. Inaccessible known EXE names are reported as unknown (fail closed).
fn classify_processes_with_history(roots:&[KnownGameRoot],observed:&[ObservedProcess],
                      directly_running:&HashMap<String,u32>,launching:Option<&str>,
                      launch_ancestors:&[(String,u32)],
                      resolve_image:impl Fn(&Path)->Result<PathBuf,String>)
    ->ActiveGameProcessReport
{
    let mut assigned=HashMap::<u32,String>::new();
    let mut uncertain=HashSet::<u32>::new();
    let mut parent_by_pid=HashMap::<u32,u32>::new();
    let ancestor_by_pid:HashMap<u32,String>=launch_ancestors.iter()
        .map(|(id,pid)|(*pid,id.clone())).collect();
    let pinned_names:HashSet<_>=roots.iter().map(|r|r.executable_name.as_str()).collect();
    for process in observed {
        if process.pid==0 {continue;}
        parent_by_pid.insert(process.pid,process.parent_pid);
        if potentially_active_minecraft(&process.executable_name) {
            uncertain.insert(process.pid);
        }
        let Some(ref image)=process.executable_path else {
            if pinned_names.contains(process.executable_name.to_lowercase().as_str()) {
                uncertain.insert(process.pid);
            }
            continue;
        };
        // Avoid probing random unrelated users' process files: only paths
        // potentially under a registered root are candidates for canonicalize.
        let maybe_game=roots.iter().any(|r|within_root(image,&r.registered)
            ||within_root(image,&r.canonical));
        if !maybe_game {continue;}
        let canonical=match resolve_image(image) {
            Ok(canonical)=>canonical,
            Err(_)=>{uncertain.insert(process.pid);continue;}
        };
        match match_game_root(&canonical,roots) {
            Ok(Some(game_id))=>{assigned.insert(process.pid,game_id.to_string());}
            Ok(None)=>{},
            Err(())=>{uncertain.insert(process.pid);}
        }
    }
    // Propagate ancestry only through the same snapshot (never an old PID
    // recorded in persisted state), with a cycle/length bound.
    for process in observed {
        if assigned.contains_key(&process.pid) || process.pid==0 {continue;}
        let mut parent=process.parent_pid;
        let mut visited=HashSet::new();
        while parent!=0 && parent!=process.pid && visited.insert(parent)
            && visited.len()<=observed.len()
        {
            if let Some(game_id)=assigned.get(&parent).cloned() {
                assigned.insert(process.pid,game_id);break;
            }
            if uncertain.contains(&parent) {uncertain.insert(process.pid);break;}
            // The original bootstrapper may already have exited. A current
            // descendant's recorded parent PID can still reference it. Only
            // accept that historical PID if it is NOT itself in the current
            // snapshot (to avoid attributing a reused PID to a different app).
            if !parent_by_pid.contains_key(&parent) {
                if let Some(game_id)=ancestor_by_pid.get(&parent) {
                    assigned.insert(process.pid,game_id.clone());break;
                }
            }
            parent=*parent_by_pid.get(&parent).unwrap_or(&0);
        }
    }
    // RuntimeState bridges the short spawn/scan window, and blocks when Coco
    // has launched a PID that Windows did not resolve yet.
    for (game_id,pid) in directly_running {
        if !assigned.contains_key(pid) {uncertain.insert(*pid);}
        else if assigned.get(pid)!=Some(game_id) {uncertain.insert(*pid);}
    }
    if launching.is_some() {uncertain.insert(0);}
    let mut matched_processes=assigned.into_iter()
        .map(|(pid,game_id)|ActiveGameProcess{pid,game_id})
        .collect::<Vec<_>>();
    matched_processes.sort_by(|a,b|a.game_id.cmp(&b.game_id).then(a.pid.cmp(&b.pid)));
    let mut game_ids=matched_processes.iter().map(|p|p.game_id.clone())
        .collect::<Vec<_>>();
    game_ids.sort();game_ids.dedup();
    let status=if !uncertain.is_empty(){"unknown"}
        else if !matched_processes.is_empty(){"active"}else{"none"};
    ActiveGameProcessReport {status,safe_to_update:status=="none",
        process_count:matched_processes.len(),unknown_candidates:uncertain.len(),
        matched_processes,game_ids}
}

#[cfg(test)]
fn classify_processes_with(roots:&[KnownGameRoot],observed:&[ObservedProcess],
                      directly_running:&HashMap<String,u32>,launching:Option<&str>,
                      resolve_image:impl Fn(&Path)->Result<PathBuf,String>)
    ->ActiveGameProcessReport
{
    classify_processes_with_history(roots,observed,directly_running,launching,&[],resolve_image)
}

#[cfg(windows)]
fn os_process_snapshot()->Result<Vec<ObservedProcess>,String> {
    #[repr(C)]
    struct ProcessEntry32W {
        dw_size:u32, cnt_usage:u32, th32_process_id:u32,
        th32_default_heap_id:usize, th32_module_id:u32, cnt_threads:u32,
        th32_parent_process_id:u32, pc_pri_class_base:i32, dw_flags:u32,
        sz_exe_file:[u16;260],
    }
    #[link(name="kernel32")]
    extern "system" {
        fn CreateToolhelp32Snapshot(flags:u32, process_id:u32)->isize;
        fn Process32FirstW(snapshot:isize, entry:*mut ProcessEntry32W)->i32;
        fn Process32NextW(snapshot:isize, entry:*mut ProcessEntry32W)->i32;
        fn OpenProcess(desired_access:u32, inherit_handle:i32, process_id:u32)->isize;
        fn QueryFullProcessImageNameW(process:isize, flags:u32,
            name:*mut u16, size:*mut u32)->i32;
        fn CloseHandle(handle:isize)->i32;
        fn GetLastError()->u32;
    }
    struct Handle(isize);
    impl Drop for Handle {fn drop(&mut self){unsafe{CloseHandle(self.0);}}}
    const TH32CS_SNAPPROCESS:u32=0x00000002;
    const PROCESS_QUERY_LIMITED_INFORMATION:u32=0x1000;
    const ERROR_NO_MORE_FILES:u32=18;
    let raw=unsafe{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0)};
    if raw == -1 || raw == 0 {
        return Err("Windows process snapshot unavailable".into());
    }
    let snapshot=Handle(raw);
    let mut entry=ProcessEntry32W {
        dw_size:std::mem::size_of::<ProcessEntry32W>() as u32,
        cnt_usage:0,th32_process_id:0,th32_default_heap_id:0,
        th32_module_id:0,cnt_threads:0,th32_parent_process_id:0,
        pc_pri_class_base:0,dw_flags:0,sz_exe_file:[0;260],
    };
    if unsafe{Process32FirstW(snapshot.0,&mut entry)}==0 {
        return if unsafe{GetLastError()}==ERROR_NO_MORE_FILES {Ok(Vec::new())}
               else {Err("Cannot read Windows process snapshot".into())};
    }
    let mut observed=Vec::new();
    loop {
        let exe_end=entry.sz_exe_file.iter().position(|c|*c==0).unwrap_or(260);
        let exe_name=String::from_utf16_lossy(&entry.sz_exe_file[..exe_end]);
        let executable_path=if entry.th32_process_id==0 {None}else{
            let handle=unsafe{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,entry.th32_process_id)};
            if handle==0 {None}else{
                let process=Handle(handle);
                // Windows supports extended-length paths up to 32767 UTF-16
                // code units; do not truncate valid long game paths.
                let mut wide=vec![0u16;32768];
                let mut len=wide.len() as u32;
                if unsafe{QueryFullProcessImageNameW(process.0,0,wide.as_mut_ptr(),&mut len)}!=0 {
                    Some(PathBuf::from(String::from_utf16_lossy(&wide[..len as usize])))
                }else{None}
            }
        };
        observed.push(ObservedProcess{pid:entry.th32_process_id,
            parent_pid:entry.th32_parent_process_id,
            executable_name:exe_name,executable_path});
        if observed.len()>131_072 {return Err("Windows process snapshot exceeds safety limit".into());}
        entry.dw_size=std::mem::size_of::<ProcessEntry32W>() as u32;
        if unsafe{Process32NextW(snapshot.0,&mut entry)}==0 {
            return if unsafe{GetLastError()}==ERROR_NO_MORE_FILES {Ok(observed)}
                   else {Err("Windows process snapshot ended unexpectedly".into())};
        }
    }
}

#[cfg(not(windows))]
fn os_process_snapshot()->Result<Vec<ObservedProcess>,String> {
    Err("Native Windows process enumeration unavailable".into())
}

fn active_snapshot(directly_running:HashMap<String,u32>,launching:Option<String>,
                   launch_ancestors:Vec<(String,u32)>)
    ->ActiveGameProcessReport
{
    let (app_data,local_data)=match current_roots() {
        Ok(roots)=>roots,Err(_)=>return unknown_process_report(),
    };
    let entries=match catalog::read_catalog() {
        Ok(entries)=>entries,Err(_)=>return unknown_process_report(),
    };
    let locations=match inventory::custom_locations(&local_data) {
        Ok(locations)=>locations,Err(_)=>return unknown_process_report(),
    };
    let roots=match registered_game_roots(&entries,&app_data,&locations) {
        Ok(roots)=>roots,Err(_)=>return unknown_process_report(),
    };
    let observed=match os_process_snapshot() {
        Ok(observed)=>observed,Err(_)=>return unknown_process_report(),
    };
    classify_processes_with_history(&roots,&observed,&directly_running,
        launching.as_deref(),&launch_ancestors,
        |path|fs::canonicalize(path).map_err(|e|e.to_string()))
}

fn process_is_running(name:&str)->bool{
    os_process_snapshot().map(|processes|processes.iter().any(|process|process.executable_name.eq_ignore_ascii_case(name))).unwrap_or(false)
}

/// For cleanups: when the process list cannot be read, assume it is running.
pub(crate) fn process_may_be_running(name:&str)->bool{
    os_process_snapshot().map(|processes|processes.iter().any(|process|process.executable_name.eq_ignore_ascii_case(name))).unwrap_or(true)
}

/// Adds every descendant of the known processes; false once all of them have exited.
fn extend_process_tree(pids:&mut std::collections::HashSet<u32>)->bool{
    let Ok(processes)=os_process_snapshot() else {return true};
    loop{
        let before=pids.len();
        for process in &processes{if pids.contains(&process.parent_pid){pids.insert(process.pid);}}
        if pids.len()==before{break;}
    }
    processes.iter().any(|process|pids.contains(&process.pid))
}

/// Fails closed: an unknown process picture counts as active.
pub(crate) async fn is_game_active(id:&str,state:&RuntimeState)->bool{
    let (Ok(running),Ok(launching),Ok(history))=(state.running.lock().map(|value|value.clone()),
        state.launching.lock().map(|value|value.clone()),
        state.launch_ancestors.lock().map(|value|value.iter().filter(|entry|entry.started.elapsed()<ANCESTOR_TTL)
            .map(|entry|(entry.game_id.clone(),entry.pid)).collect::<Vec<_>>())) else {return true};
    if launching.as_deref()==Some(id)||running.contains_key(id){return true;}
    let Ok(report)=tauri::async_runtime::spawn_blocking(move||active_snapshot(running,launching,history)).await else {return true};
    report.game_ids.iter().any(|game|game==id)||(!report.safe_to_update&&report.game_ids.is_empty())
}

/// Test-only adapter exercises the SAME native Win32 snapshot/classifier and
/// `safe_to_update` predicate as Tauri, but on an explicit isolated profile.
/// It never consults or mutates APPDATA, services, or the runtime's UI state.
#[cfg(all(test,windows))]
pub(crate) fn active_synthetic_profile(entry:&catalog::Experience,root:&Path,
    prior_launch_pid:Option<u32>)->ActiveGameProcessReport{
    let physical=match fs::canonicalize(root){Ok(root)=>root,Err(_)=>return unknown_process_report()};
    let executable_name=match expected_executable_name(&entry.executable){
        Some(name)=>name,None=>return unknown_process_report(),
    };
    let roots=vec![KnownGameRoot{id:entry.id.clone(),registered:root.to_owned(),
        canonical:physical,executable_name}];
    let observed=match os_process_snapshot(){Ok(snapshot)=>snapshot,Err(_)=>return unknown_process_report()};
    let history=prior_launch_pid.map(|pid|vec![(entry.id.clone(),pid)]).unwrap_or_default();
    classify_processes_with_history(&roots,&observed,&HashMap::new(),None,&history,
        |path|fs::canonicalize(path).map_err(|e|e.to_string()))
}

#[cfg(all(test,windows))]
pub(crate) fn synthetic_process_is_running(executable:&Path)->bool{
    let Ok(expected)=fs::canonicalize(executable) else{return false;};
    let Ok(observed)=os_process_snapshot() else{return true;}; // fail-closed
    observed.into_iter().filter_map(|p|p.executable_path).any(|path|{
        fs::canonicalize(&path).is_ok_and(|canonical|win_path_key(&canonical)==win_path_key(&expected))
    })
}

/// Read-only, whole-OS game detection for update preflight. A result of
/// `none`/safeToUpdate=true is an observation at this instant, NOT a durable
/// lock: the updater must re-query immediately before replacing its EXE.
/// The conservative `unknown` state always forbids update/install.
#[tauri::command]
pub async fn get_active_game_processes(state:State<'_,RuntimeState>)
    ->Result<ActiveGameProcessReport,String>
{
    let running=match state.running.lock() {
        Ok(running)=>running.clone(),Err(_)=>return Ok(unknown_process_report()),
    };
    let launching=match state.launching.lock() {
        Ok(launching)=>launching.clone(),Err(_)=>return Ok(unknown_process_report()),
    };
    let history=match state.launch_ancestors.lock() {
        Ok(history)=>history.iter().filter(|entry|entry.started.elapsed()<ANCESTOR_TTL)
            .map(|entry|(entry.game_id.clone(),entry.pid)).collect(),
        Err(_)=>return Ok(unknown_process_report()),
    };
    tauri::async_runtime::spawn_blocking(move||active_snapshot(running,launching,history))
        .await.map_err(|_|"Game process enumeration interrupted; updates must remain blocked".into())
}

fn current_roots()->Result<(PathBuf,PathBuf),String>{
    let app_data=std::env::var_os("APPDATA").map(PathBuf::from).ok_or("APPDATA no disponible")?;
    let local_data=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or("LOCALAPPDATA no disponible")?;
    Ok((app_data,local_data))
}

fn resolve_executable(entry:&catalog::Experience,root:&Path)->Result<PathBuf,String>{
    if entry.workflow!="coco-standalone" || entry.hosting_mode!="p2p"{
        return Err("Este juego todavía requiere el motor de sesiones nativo".into());
    }
    let name=verify::safe_relative_path(&entry.executable).ok_or("Ejecutable no válido")?;
    if !entry.required_files.iter().any(|file|file.path==entry.executable){
        return Err("El ejecutable no está fijado en los archivos verificados".into());
    }
    let path=root.join(name);
    let canonical_root=root.canonicalize().map_err(|e|format!("Instancia inaccesible: {e}"))?;
    let canonical_exe=path.canonicalize().map_err(|e|format!("Ejecutable inaccesible: {e}"))?;
    if !canonical_exe.starts_with(canonical_root){return Err("Ejecutable fuera de la instancia".into());}
    Ok(path)
}

fn game_command(entry:&catalog::Experience,root:&Path)->Result<Command,String>{
    let path=resolve_executable(entry,root)?;
    let mut command=Command::new(path);
    command.current_dir(root).args(&entry.launch_arguments)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    Ok(command)
}

/// Exercises precisely the native verifier and process command used by the
/// real launcher, but never constructs Tauri windows or touches user profiles.
/// Only compiled synthetic EXEs in per-test temporary roots may be supplied.
#[cfg(all(test,windows))]
pub(crate) fn launch_synthetic_fixture(entry:&catalog::Experience,app_data:&Path,
    local_data:&Path,root:&Path)->Result<Child,String>{
    let outcome=verify::verify_entry(entry,app_data,local_data,&std::sync::atomic::AtomicBool::new(false),|_|{})?;
    if outcome.status!="essential-files-verified"{
        return Err(format!("Synthetic fixture verification failed: {}",outcome.status));
    }
    game_command(entry,root)?.spawn().map_err(|e|format!("Synthetic native process failed: {e}"))
}

fn active_id(state:&RuntimeState)->Result<Vec<String>,String>{
    state.running.lock().map(|jobs|jobs.keys().cloned().collect())
        .map_err(|_|"Estado del juego no disponible".into())
}

#[tauri::command]
pub fn list_running_games(state:State<'_,RuntimeState>)->Result<Vec<String>,String>{active_id(&state)}

/// Like extend_process_tree, and a browser that the game started is closed on sight.
fn extend_process_tree_closing_browsers(pids:&mut std::collections::HashSet<u32>)->bool{
    let alive=extend_process_tree(pids);
    if let Ok(processes)=os_process_snapshot(){
        for process in processes.iter().filter(|process|pids.contains(&process.pid)){
            if !crate::services::launch_guard::is_browser(&process.executable_name){continue;}
            terminate_process(process.pid);
            crate::services::diagnostics::log("online-fix",&format!("navegador abierto por el juego cerrado: {}",process.executable_name));
        }
    }
    alive
}

#[cfg(windows)]
fn terminate_process(pid:u32){
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess,TerminateProcess,PROCESS_TERMINATE};
    let handle=unsafe{OpenProcess(PROCESS_TERMINATE,0,pid)};
    if handle.is_null(){return;}
    unsafe{TerminateProcess(handle,1);CloseHandle(handle);}
}
#[cfg(not(windows))]
fn terminate_process(_pid:u32){}

fn monitor(id:String,mut child:Child,app:AppHandle,running:Arc<Mutex<HashMap<String,u32>>>,after_exit:Box<dyn FnOnce()+Send>) {
    std::thread::spawn(move||{
        let pid=child.id();
        crate::services::game_prepare::watch_popups(pid,extend_process_tree_closing_browsers);
        let code=child.wait().ok().and_then(|status|status.code());
        after_exit();
        if let Ok(mut jobs)=running.lock(){if jobs.get(&id)==Some(&pid){jobs.remove(&id);}}
        let _=app.emit("coco2://runtime",RuntimeEvent{id,state:"exited",pid:Some(pid),exit_code:code});
    });
}

struct LaunchGuard(Arc<Mutex<Option<String>>>);
impl Drop for LaunchGuard {
    fn drop(&mut self){if let Ok(mut job)=self.0.lock(){*job=None;}}
}

#[tauri::command]
pub async fn launch_standalone(id:String,app:AppHandle,state:State<'_,RuntimeState>)->Result<RuntimeEvent,String>{
    let entry=catalog::read_catalog()?.into_iter().find(|x|x.id==id).ok_or("Juego desconocido")?;
    if entry.workflow!="coco-standalone" || entry.hosting_mode!="p2p" {
        return Err("El lanzamiento de este tipo de experiencia aún está en desarrollo".into());
    }
    let (app_data,local_data)=current_roots()?;
    let running=Arc::clone(&state.running);
    let launching=Arc::clone(&state.launching);
    let launch_ancestors=Arc::clone(&state.launch_ancestors);
    {
        let mut current=launching.lock().map_err(|_|"Motor ocupado")?;
        if current.is_some(){return Err("Ya se está preparando un juego".into());}
        if !active_id(&state)?.is_empty(){return Err("Hay un juego iniciado desde Coco 2".into());}
        *current=Some(id.clone());
    }
    tauri::async_runtime::spawn_blocking(move||{
        let _guard=LaunchGuard(launching);
        let _=app.emit("coco2://runtime",RuntimeEvent{id:id.clone(),state:"verifying",pid:None,exit_code:None});
        let locations=inventory::custom_locations(&local_data)?;
        let root=inventory::resolve_instance_root(&entry,&app_data,&locations);
        if !root.is_absolute()||root.to_string_lossy().starts_with("\\\\"){
            return Err("La ruta de la instancia no es local".into());
        }
        crate::services::defender::ensure(&app,std::slice::from_ref(&root));
        // When the signed channel advances to B, allow an intact installed A
        // to launch with A's trusted manifest; a mutable receipt alone never
        // supplies paths/hashes, and a pending journal always blocks launch.
        let verified_entry=crate::services::install::trusted_installed_launch_entry(&entry,&root)?
            .unwrap_or_else(||entry.clone());
        let outcome=verify::verify_entry(&verified_entry,&app_data,&local_data,&AtomicBool::new(false),|progress|{
            let _=app.emit("coco2://verification-progress",progress);
        })?;
        if outcome.status!="essential-files-verified" {
            return Err(format!("Archivos no verificados ({})",outcome.first_issue.unwrap_or(outcome.status.into())));
        }
        crate::services::game_prepare::prepare_files(&verified_entry,&root);
        crate::services::game_prepare::wait_for_steam(process_is_running,|waiting|{let _=app.emit("coco2://steam-starting",waiting);})?;
        // The first time on this PC, the fix gets its popup out of the way where nobody sees it.
        if crate::services::game_prepare::needs_first_run(&verified_entry,&root){
            let _=app.emit("coco2://first-run",true);
            let game_exe=resolve_executable(&verified_entry,&root)?;
            let conclusive=crate::services::online_fix_prime::first_run(&root,&game_exe,&verified_entry.launch_arguments);
            // Only a run that settled the hash is kept; otherwise the next launch tries again.
            if conclusive{crate::services::game_prepare::trust_current(&verified_entry,&root);}
            let _=app.emit("coco2://first-run",false);
        }
        let hashes_before=crate::services::game_prepare::current_hashes(&verified_entry,&root);
        // Recheck after hashing and resolve executable strictly under the verified root.
        let mut command=game_command(&verified_entry,&root)?;
        // Answers the fix's credits box the moment it shows, should this PC's hash not hold.
        crate::services::launch_guard::guard_credits_box(GUARD_CREDITS_FOR);
        // Started paused and let go only once inside its job: a browser it opens, however early,
        // is ended as it is born.
        #[cfg(windows)]
        {use std::os::windows::process::CommandExt;command.creation_flags(CREATE_SUSPENDED);}
        let child=command.spawn().map_err(|e|format!("No se pudo iniciar el juego: {e}"))?;
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawHandle;
            crate::services::launch_guard::guard_children(child.as_raw_handle());
            crate::services::launch_guard::resume(child.as_raw_handle());
        }
        let pid=child.id();
        // Record before the child can exit; subsequent snapshot checks can
        // attribute an orphaned child launcher process by parent PID.
        if let Ok(mut history)=launch_ancestors.lock() {
            history.retain(|entry|entry.started.elapsed()<ANCESTOR_TTL);
            if history.len()>=128 {history.remove(0);}
            history.push(LaunchAncestor{game_id:id.clone(),pid,started:Instant::now()});
        }
        {
            let mut jobs=running.lock().map_err(|_|"Estado del juego no disponible")?;
            jobs.insert(id.clone(),pid);
        }
        let event=RuntimeEvent{id:id.clone(),state:"running",pid:Some(pid),exit_code:None};
        let _=app.emit("coco2://runtime",event.clone());
        let adopted_root=root.clone();
        monitor(id,child,app,running,Box::new(move||{
            crate::services::game_prepare::adopt_new_hashes(&verified_entry,&adopted_root,&hashes_before);
        }));
        Ok(event)
    }).await.map_err(|e|format!("Motor interrumpido: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(id:&str,registered:&str,canonical:&str,exe:&str)->KnownGameRoot{
        KnownGameRoot{id:id.into(),registered:PathBuf::from(registered),
            canonical:PathBuf::from(canonical),executable_name:exe.into()}
    }

    fn process(pid:u32,parent_pid:u32,path:Option<&str>,name:&str)->ObservedProcess{
        ObservedProcess{pid,parent_pid,executable_name:name.into(),
            executable_path:path.map(PathBuf::from)}
    }

    fn classify(roots:&[KnownGameRoot],processes:&[ObservedProcess])
        ->ActiveGameProcessReport
    {
        // Pure synthetic Windows paths: no files, processes or registry entries
        // are created/read by the matcher tests.
        classify_processes_with(roots,processes,&HashMap::new(),None,
            |path|Ok(path.to_path_buf()))
    }

    #[test]
    fn minecraft_or_java_must_block_update_even_outside_standalone_roots(){
        let roots=[root("demo",r"C:\Games\Demo",r"C:\Games\Demo","demo.exe")];
        for name in ["javaw.exe","JAVA.EXE","Minecraft.Windows.exe"] {
            let processes=[process(901,1,Some(r"C:\Program Files\Java\bin\javaw.exe"),name)];
            let report=classify(&roots,&processes);
            assert_eq!(report.status,"unknown", "{name}");
            assert!(!report.safe_to_update);
            assert_eq!(report.unknown_candidates,1);
            assert!(report.matched_processes.is_empty(),"no arbitrary process should leak");
        }
        // An unrelated ordinary process does not become a false game match.
        assert_eq!(classify(&roots,&[process(902,1,Some(r"C:\Tools\editor.exe"),"editor.exe")]).status,"none");
    }

    #[test]
    fn refuse_executable_not_pinned_and_path_escapes(){
        let mut entry=catalog::read_catalog().unwrap().into_iter().find(|e|e.id=="machine-party").unwrap();
        let base=std::env::temp_dir();
        entry.executable="../evil.exe".into();
        assert!(resolve_executable(&entry,&base).is_err());
        entry.executable="MadeUp.exe".into();
        assert!(resolve_executable(&entry,&base).is_err());
        entry.hosting_mode="lan".into();
        assert!(resolve_executable(&entry,&base).is_err());
    }

    #[test]
    fn detects_external_previous_session_and_nested_executable_without_false_sibling_match(){
        let roots=[root("demo",r"C:\Games\Demo",r"\\?\C:\Games\Demo","game.exe")];
        let snapshot=[
            process(42,1,Some(r"c:\GAMES\DEMO\Binaries\game.exe"),"game.exe"),
            process(43,1,Some(r"C:\Games\Demo-old\game.exe"),"game.exe"),
            process(44,1,Some(r"C:\Games\Different\editor.exe"),"editor.exe"),
        ];
        let result=classify(&roots,&snapshot);
        assert_eq!(result.status,"active");
        assert!(!result.safe_to_update);
        assert_eq!(result.game_ids,vec!["demo"]);
        assert_eq!(result.process_count,1);
        assert_eq!(result.matched_processes,
            vec![ActiveGameProcess{pid:42,game_id:"demo".into()}]);
        assert_eq!(result.unknown_candidates,0);
    }

    #[test]
    fn recognizes_custom_location_alias_and_non_game_processes_do_not_leak(){
        let roots=[root("custom",r"D:\Alias\Custom",r"E:\Library\Custom","launcher.exe")];
        let snapshot=[
            process(10,0,Some(r"D:\Alias\Custom\launcher.exe"),"launcher.exe"),
            process(20,0,Some(r"C:\Users\someone\Secret\private-app.exe"),"private-app.exe"),
        ];
        let result=classify_processes_with(&roots,&snapshot,&HashMap::new(),None,|path|{
            if within_root(path,Path::new(r"D:\Alias\Custom")) {
                Ok(PathBuf::from(r"E:\Library\Custom\launcher.exe"))
            }else{Ok(path.to_path_buf())}
        });
        assert_eq!(result.status,"active");
        assert_eq!(result.game_ids,vec!["custom"]);
        assert_eq!(result.matched_processes[0].pid,10);
        let serialized=serde_json::to_string(&result).unwrap();
        assert!(!serialized.contains("private-app"));
        assert!(!serialized.contains("Secret"));
        assert!(!serialized.contains("E:\\Library"));
    }

    #[test]
    fn descendant_launcher_process_is_counted_even_outside_game_root(){
        let roots=[root("demo",r"C:\Games\Demo",r"C:\Games\Demo","starter.exe")];
        // Snapshot order intentionally reversed; grandchild ancestry still
        // resolves directly to the game process without relying on child wait.
        let snapshot=[
            process(103,102,Some(r"C:\Tools\overlay-helper.exe"),"overlay-helper.exe"),
            process(102,101,Some(r"C:\Windows\Temp\other-helper.exe"),"other-helper.exe"),
            process(101,90,Some(r"C:\Games\Demo\starter.exe"),"starter.exe"),
        ];
        let result=classify(&roots,&snapshot);
        assert_eq!(result.status,"active");
        assert_eq!(result.process_count,3);
        assert_eq!(result.game_ids,vec!["demo"]);
        assert!(result.matched_processes.iter().any(|p|p.pid==103));
        assert_eq!(result.unknown_candidates,0);
    }

    #[test]
    fn detached_child_from_exited_bootstrapper_is_still_attributed_temporarily(){
        let roots=[root("demo",r"C:\Games\Demo",r"C:\Games\Demo","bootstrap.exe")];
        // PID 900's parent already exited. The child is currently outside the
        // game root (e.g. a child unpacked to a transient directory).
        let snapshot=[process(901,900,Some(r"C:\Temp\game-child.exe"),"game-child.exe")];
        let history=[("demo".to_string(),900)];
        let result=classify_processes_with_history(&roots,&snapshot,&HashMap::new(),None,
            &history,|p|Ok(p.to_path_buf()));
        assert_eq!(result.status,"active");
        assert_eq!(result.matched_processes,
            vec![ActiveGameProcess{pid:901,game_id:"demo".into()}]);
        // PID reuse with a *current* unrelated parent must not create a
        // ghost attribution to a game from hours earlier.
        let reused=[process(900,1,Some(r"C:\Tools\other.exe"),"other.exe"),
                    process(901,900,Some(r"C:\Tools\child.exe"),"child.exe")];
        assert_eq!(classify_processes_with_history(&roots,&reused,&HashMap::new(),None,
            &history,|p|Ok(p.to_path_buf())).status,"none");
    }

    #[test]
    fn unknown_candidate_and_changing_snapshot_fail_closed(){
        let roots=[root("demo",r"C:\Games\Demo",r"C:\Games\Demo","game.exe")];
        let missing_path=[process(91,90,None,"game.exe")];
        let result=classify(&roots,&missing_path);
        assert_eq!(result.status,"unknown");
        assert!(!result.safe_to_update);
        assert_eq!(result.unknown_candidates,1);
        assert_eq!(result.process_count,0);
        let unresolved=[process(92,90,Some(r"C:\Games\Demo\new-game.exe"),"new-game.exe")];
        let result=classify_processes_with(&roots,&unresolved,&HashMap::new(),None,
            |_|Err("file vanished while enumerating".into()));
        assert_eq!(result.status,"unknown");
        assert!(!result.safe_to_update);
        let mut tracked=HashMap::new();tracked.insert("demo".into(),200);
        let report=classify_processes_with(&roots,&[],&tracked,None,|p|Ok(p.to_path_buf()));
        assert_eq!(report.status,"unknown","launched process not yet visible");
        assert_eq!(classify_processes_with(&roots,&[],&HashMap::new(),Some("demo"),
            |p|Ok(p.to_path_buf())).status,"unknown");
    }

    #[test]
    fn no_game_is_clean_and_ambiguous_roots_are_unknown(){
        let roots=[root("demo",r"C:\Games\Demo",r"C:\Games\Demo","game.exe")];
        let safe=classify(&roots,&[process(10,1,Some(r"C:\Other\game.exe"),"game.exe")]);
        assert_eq!(safe.status,"none");
        assert!(safe.safe_to_update);
        let same_location=[root("one",r"C:\Games\Demo",r"C:\Games\Demo","game.exe"),
                           root("two",r"C:\Games\Demo",r"C:\Games\Demo","game.exe")];
        let suspicious=classify(&same_location,&[
            process(45,1,Some(r"C:\Games\Demo\game.exe"),"game.exe")]);
        assert_eq!(suspicious.status,"unknown");
        assert!(!suspicious.safe_to_update);
        assert_eq!(suspicious.unknown_candidates,1);
    }
}
