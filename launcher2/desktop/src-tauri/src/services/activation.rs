//! Native, path-only Windows file-association activation for Coco Launcher 2.
//! No ZIP is opened or imported by this module.
use serde::Serialize;
use std::collections::VecDeque;
use std::ffi::{OsString,OsStr};
use std::path::{Path,PathBuf};
use std::sync::{Arc,Mutex,OnceLock};
use std::sync::atomic::{AtomicBool,Ordering};
use std::time::{Duration,Instant};
use tauri::{AppHandle,Emitter};

pub const PACKAGE_OPEN_EVENT:&str="coco2://package-open-request";
const MAX_REQUESTS:usize=24;
const MAX_PATH_UNITS:usize=8192;
const MAX_PAYLOAD:usize=128*1024;
const MAX_PENDING:usize=96;
// Immediate double-clicks/Explorer retries must not open the same package
// repeatedly. A later explicit open remains possible after this brief window.
const REPLAY_WINDOW:Duration=Duration::from_secs(2);

#[derive(Clone,Debug,PartialEq,Eq,Serialize)]
#[serde(rename_all="camelCase")]
pub struct PackageOpenRequest {
    pub path:String,
    pub source:&'static str,
}

#[derive(Default)]
struct State{
    items:VecDeque<PackageOpenRequest>,
    recent:VecDeque<(String,Instant)>,
    app:Option<AppHandle>,
    ready:bool,
}
static STATE:OnceLock<Mutex<State>>=OnceLock::new();
static ACTIVATION_CLOSED:AtomicBool=AtomicBool::new(false);
// The app updater can start NSIS and exit Coco. Its final native arming is
// serialized with accepted Explorer submissions so no authenticated path can
// be ACKed immediately before the updater terminates the owning process.
static APP_UPDATE_INSTALL_ARMED:AtomicBool=AtomicBool::new(false);
fn state()->&'static Mutex<State>{STATE.get_or_init(||Mutex::new(State::default()))}
// Serializes warm submissions through their UI dispatch. Without this gate,
// a later concurrently accepted WM_COPYDATA batch can emit before an earlier
// batch after each sender drops the state mutex.
static DELIVERY:OnceLock<Mutex<()>>=OnceLock::new();
fn delivery()->&'static Mutex<()>{DELIVERY.get_or_init(||Mutex::new(()))}

fn has_extension(path:&Path)->bool{
    path.file_name().and_then(OsStr::to_str).is_some_and(|s|{
        let lower=s.to_ascii_lowercase();
        lower.ends_with(".coco2pack")||lower.ends_with(".coco2pack.zip")
    })
}
fn checked_path(raw:&OsString)->Result<String,String>{
    let path=PathBuf::from(raw);
    if !path.is_absolute()||!has_extension(&path){
        return Err("Expected an absolute .coco2pack or .coco2pack.zip file".into());
    }
    #[cfg(windows)]{
        use std::os::windows::ffi::OsStrExt;
        let text=path.as_os_str().to_string_lossy();
        if text.starts_with(r"\\")
            && !(text.starts_with(r"\\?\")
                && text.as_bytes().get(4).is_some_and(u8::is_ascii_alphabetic)
                && text.as_bytes().get(5)==Some(&b':')
                && text.as_bytes().get(6)==Some(&b'\\')) {
            return Err("UNC and native device paths are not accepted".into());
        }
        if path.as_os_str().encode_wide().count()>MAX_PATH_UNITS {
            return Err("Association path too long".into());
        }
    }
    #[cfg(not(windows))]
    if path.to_string_lossy().len()>MAX_PATH_UNITS{return Err("Association path too long".into());}
    for ancestor in path.ancestors(){
        let meta=std::fs::symlink_metadata(ancestor)
            .map_err(|_|"Cannot inspect associated package path")?;
        if meta.file_type().is_symlink(){return Err("Symlink package path rejected".into());}
        #[cfg(windows)]{
            use std::os::windows::fs::MetadataExt;
            if meta.file_attributes()&0x400!=0{return Err("Reparse-point package path rejected".into());}
        }
    }
    let canonical=path.canonicalize().map_err(|_|"Associated package does not exist")?;
    if !canonical.is_file()||!has_extension(&canonical){return Err("Package path is not a regular file".into());}
    canonical.into_os_string().into_string().map_err(|_|"Package path has non-Unicode characters".into())
}
fn parse<I>(args:I,source:&'static str)->Result<Vec<PackageOpenRequest>,String>
where I:IntoIterator<Item=OsString>{
    let mut result=Vec::new();let mut total=4usize;let mut supplied=0usize;
    for arg in args{
        supplied+=1;
        if supplied>MAX_REQUESTS{return Err("Too many package arguments".into());}
        let path=checked_path(&arg)?;
        // The IPC wire format contains only unique canonical paths. Charging
        // repeated Explorer arguments against MAX_PAYLOAD used to reject a
        // valid single package after enough double-click/reentry duplicates.
        if result.iter().any(|item:&PackageOpenRequest|item.path.eq_ignore_ascii_case(&path)){continue;}
        total=total.saturating_add(4+path.encode_utf16().count()*2);
        if total>MAX_PAYLOAD{return Err("Package request exceeds IPC limit".into());}
        result.push(PackageOpenRequest{path,source});
    }
    Ok(result)
}
fn select_requests(current:&mut State,requests:Vec<PackageOpenRequest>,
    now:Instant,can_emit:bool)->Result<Vec<PackageOpenRequest>,String>{
    current.recent.retain(|(_,created)|now.duration_since(*created)<REPLAY_WINDOW);
    let mut accepted=Vec::new();
    for item in requests {
        if current.items.iter().any(|prior|prior.path.eq_ignore_ascii_case(&item.path))
            ||current.recent.iter().any(|(path,_)|path.eq_ignore_ascii_case(&item.path))
            ||accepted.iter().any(|prior:&PackageOpenRequest|prior.path.eq_ignore_ascii_case(&item.path)) {
            continue;
        }
        // Even after the UI has drained its pending queue, thousands of
        // distinct warm opens could otherwise grow recent without bound.
        // Bound both the pending backlog and the replay ledger, atomically
        // rejecting an oversized batch before inserting any of its entries.
        if current.items.len().saturating_add(accepted.len())>=MAX_PENDING
            ||current.recent.len().saturating_add(accepted.len())>=MAX_PENDING {
            return Err("Package activation queue or replay window is full".into());
        }
        accepted.push(item);
    }
    let mut outbound=Vec::new();
    for item in accepted {
        current.recent.push_back((item.path.clone(),now));
        if can_emit{
            outbound.push(item);
        } else {
            current.items.push_back(item);
        }
    }
    Ok(outbound)
}
fn select_with_backlog(current:&mut State, requests:Vec<PackageOpenRequest>,
    now:Instant,can_emit:bool)->Result<Vec<PackageOpenRequest>,String>{
    // Validate/cap the whole incoming batch BEFORE draining failed events.
    // A later retry must deliver the earlier undelivered suffix first, even
    // when the new request was suppressed by the replay ledger.
    let mut fresh=select_requests(current,requests,now,can_emit)?;
    if !can_emit{return Ok(fresh);}
    let mut outbound:Vec<_>=current.items.drain(..).collect();
    outbound.append(&mut fresh);
    Ok(outbound)
}
fn deliver_with_fallback(
    pending:&Mutex<State>,outbound:Vec<PackageOpenRequest>,
    mut emit:impl FnMut(&PackageOpenRequest)->Result<(),String>,
)->Result<(),String>{
    let mut items=outbound.into_iter();
    while let Some(item)=items.next(){
        if ACTIVATION_CLOSED.load(Ordering::Acquire){
            return Err("Package activation receiver has shut down".into());
        }
        if emit(&item).is_err(){
            let mut current=pending.lock().map_err(|_|"Package activation queue poisoned")?;
            if ACTIVATION_CLOSED.load(Ordering::Acquire){
                return Err("Package activation receiver has shut down".into());
            }
            // An event-bus failure is NOT a successful delivery/ACK. Retain
            // the failed item and untouched suffix in original order so the
            // next warm attempt or frontend take_pending can recover them.
            // Already emitted prefixes must never be replayed.
            let mut undelivered=std::iter::once(item).chain(items).collect::<Vec<_>>();
            if current.items.len().saturating_add(undelivered.len())>MAX_PENDING{
                return Err("Package activation retry queue is full".into());
            }
            current.items.extend(undelivered.drain(..));
            return Err("Package activation UI event failed; undelivered paths retained".into());
        }
    }
    Ok(())
}
fn queue(requests:Vec<PackageOpenRequest>)->Result<(),String>{
    if ACTIVATION_CLOSED.load(Ordering::Acquire){
        return Err("Package activation receiver has shut down".into());
    }
    let _ordered=delivery().lock().map_err(|_|"Package activation delivery poisoned")?;
    if APP_UPDATE_INSTALL_ARMED.load(Ordering::Acquire){
        // Win32 WM_COPYDATA receives a negative ACK: never claim this handoff
        // was accepted when Coco's signed updater is already restarting.
        return Err("Coco updater restart in progress; package was not accepted".into());
    }
    let mut current=state().lock().map_err(|_|"Package activation queue poisoned")?;
    if ACTIVATION_CLOSED.load(Ordering::Acquire){
        return Err("Package activation receiver has shut down".into());
    }
    // Native paths remain the authoritative FIFO until the frontend explicitly
    // takes them. An app.emit() returning Ok only says the event bus accepted
    // a notification; it does NOT prove that a JS listener received it (e.g.
    // between the cold drain and listen() completion). Never remove a path
    // merely because an event was emitted successfully.
    select_requests(&mut current,requests,Instant::now(),false)?;
    let app=if current.ready&&!current.items.is_empty(){current.app.clone()}else{None};
    drop(current); // Do not hold the queue mutex during Tauri event callbacks.
    if let Some(app)=app{
        // Advisory wake only; payload is intentionally path-free. Even a
        // failed or unobserved emit cannot destroy pending native requests.
        let _=app.emit(PACKAGE_OPEN_EVENT,());
    }
    Ok(())
}

/// Attach from tauri Builder.setup. The frontend must register its event
/// listener before confirming readiness. Peeking pending requests does not
/// acknowledge them; React must explicitly ACK after synchronizing its inbox.
pub fn attach_app(handle:&AppHandle)->Result<(),String>{
    let mut state=state().lock().map_err(|_|"Package activation queue poisoned")?;
    if ACTIVATION_CLOSED.load(Ordering::Acquire){
        return Err("Package activation receiver has shut down".into());
    }
    state.app=Some(handle.clone());
    Ok(())
}

/// Cancel an undelivered request only. Never deletes, opens, or modifies a
/// package; a cancelled path can be explicitly opened again immediately.
#[tauri::command]
pub fn cancel_pending_package_open_request(path:String)->bool{
    let Ok(mut s)=state().lock() else{return false};
    cancel_in_state(&mut s,&path)
}
/// Called only after the WebView has attached its package-open listener.
/// A cold take_pending before that point must never activate lossy emits.
#[tauri::command]
pub fn confirm_package_open_listener_ready()->bool{
    let Ok(_ordered)=delivery().lock() else{return false};
    let Ok(mut s)=state().lock() else{return false};
    if ACTIVATION_CLOSED.load(Ordering::Acquire)||s.app.is_none(){return false;}
    s.ready=true;
    true
}
fn cancel_in_state(state:&mut State,path:&str)->bool{
    let before=state.items.len();
    state.items.retain(|item|!item.path.eq_ignore_ascii_case(path));
    let removed=before!=state.items.len();
    if removed{state.recent.retain(|(recent,_)|!recent.eq_ignore_ascii_case(path));}
    removed
}
// Once a human has actually finished a review, a new Explorer double-click
// must be a new explicit request, even within the two-second WM_COPYDATA
// duplicate-suppression window. Do not remove a *new* queued request for this
// path: a later activation might already have won the native delivery race.
fn release_review_replay(state:&mut State,path:&str)->bool{
    if state.items.iter().any(|item|item.path.eq_ignore_ascii_case(path)){
        return false;
    }
    let old=state.recent.len();
    state.recent.retain(|(recent,_)|!recent.eq_ignore_ascii_case(path));
    state.recent.len()!=old
}

/// A user explicitly discarded or completed a review already stored in the
/// React inbox. This only clears short-term duplicate suppression. No file is
/// opened, deleted, imported, installed or executed, and native FIFO is not
/// consumed. The UI invokes it after persisting the dismissal.
#[tauri::command]
pub fn release_reviewed_package_replay_suppression(path:String)->bool{
    let Ok(_ordered)=delivery().lock() else{return false};
    let Ok(mut state)=state().lock() else{return false};
    if ACTIVATION_CLOSED.load(Ordering::Acquire){return false;}
    release_review_replay(&mut state,&path)
}

/// Snapshot without consuming. A delayed IPC response must not discard paths
/// when the WebView is disposed, navigated or re-mounted before React consumes
/// the result. This remains safe while a Win32 sender concurrently appends.
#[tauri::command]
pub fn peek_pending_package_open_requests()->Vec<PackageOpenRequest>{
    let Ok(_ordered)=delivery().lock() else{return Vec::new()};
    if let Ok(state)=state().lock(){
        if ACTIVATION_CLOSED.load(Ordering::Acquire){return Vec::new();}
        return state.items.iter().cloned().collect();
    }
    Vec::new()
}

/// ACK only an exact FIFO prefix that the frontend has added to its own live
/// review inbox. Invalid, stale, reordered or oversized ACKs fail closed.
/// A newly accepted suffix is never removed by an earlier frontend receipt.
#[tauri::command]
pub fn acknowledge_pending_package_open_requests(paths:Vec<String>)->bool{
    let Ok(_ordered)=delivery().lock() else{return false};
    let Ok(mut state)=state().lock() else{return false};
    if ACTIVATION_CLOSED.load(Ordering::Acquire)||paths.is_empty()||paths.len()>MAX_PENDING
        ||state.items.len()<paths.len(){return false;}
    if !state.items.iter().zip(paths.iter()).all(|(item,path)|item.path==*path){return false;}
    for _ in 0..paths.len(){state.items.pop_front();}
    true
}

/// Read-only updater guard. An accepted Explorer request may still be native
/// while its asynchronous WebView IPC/React state update is in flight.
/// On a poisoned lock or closed receiver, fail closed as if work is pending.
#[tauri::command]
pub fn has_pending_package_open_requests()->bool{
    let Ok(_ordered)=delivery().lock() else{return true};
    let Ok(state)=state().lock() else{return true};
    ACTIVATION_CLOSED.load(Ordering::Acquire)
        ||APP_UPDATE_INSTALL_ARMED.load(Ordering::Acquire)||!state.items.is_empty()
}

/// Atomically choose between a new authenticated Explorer path and restarting
/// the app. If any request already entered native FIFO, restart is deferred;
/// if restart wins, later Win32 senders get a negative receipt (never a false
/// successful delivery) until the updater attempt settles or Coco exits.
#[tauri::command]
pub fn try_arm_app_update_install()->bool{
    let Ok(_ordered)=delivery().lock() else{return false};
    let Ok(state)=state().lock() else{return false};
    if ACTIVATION_CLOSED.load(Ordering::Acquire)||!state.items.is_empty()
        ||APP_UPDATE_INSTALL_ARMED.load(Ordering::Acquire){return false;}
    APP_UPDATE_INSTALL_ARMED.store(true,Ordering::Release);
    true
}

/// Always invoked if signed update install() returns/rejects without exiting.
/// Never retain the restart gate indefinitely after a failed attempt.
#[tauri::command]
pub fn finish_app_update_install_guard()->bool{
    let Ok(_ordered)=delivery().lock() else{return false};
    APP_UPDATE_INSTALL_ARMED.swap(false,Ordering::AcqRel)
}

#[tauri::command]
pub fn take_pending_package_open_requests()->Vec<PackageOpenRequest>{
    // A warm WM_COPYDATA dispatch temporarily moves pending FIFO entries out
    // of State while it emits UI events. A concurrent frontend drain must not
    // observe the transiently-empty queue before a failed emit restores its
    // undelivered suffix; otherwise a cold/warm package is stranded until a
    // later focus/Explorer event. Match the sender's delivery-before-state
    // lock order to preserve FIFO without holding State over UI callbacks.
    let Ok(_ordered)=delivery().lock() else{return Vec::new()};
    if let Ok(mut state)=state().lock(){
        if ACTIVATION_CLOSED.load(Ordering::Acquire){return Vec::new();}
        return state.items.drain(..).collect();
    }
    Vec::new()
}

/// Cooperatively stop hidden activation listeners and cancel pending paths.
/// Intended hook: call on Tauri RunEvent::Exit, not on a window hide.
/// No registry, game, or external process is affected. Irreversible until
/// process exit; new warm senders fail closed instead of spawning extra UI.
pub fn shutdown_activation()->Result<(),String>{
    let _ordered=delivery().lock().map_err(|_|"Package activation delivery poisoned")?;
    ACTIVATION_CLOSED.store(true,Ordering::Release);
    APP_UPDATE_INSTALL_ARMED.store(false,Ordering::Release);
    if let Ok(mut state)=state().lock(){
        state.items.clear();
        state.recent.clear();
        state.app=None;
        state.ready=false;
    }
    #[cfg(windows)]windows_impl::shutdown_listeners()?;
    Ok(())
}
#[cfg(windows)]
mod windows_impl{
    use super::*;
    use sha2::{Digest,Sha256};
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStringExt;
    use std::ptr;
    use std::sync::mpsc;
    use std::time::{Duration,Instant};

    const ERROR_ALREADY_EXISTS:u32=183;
    const ERROR_INVALID_PARAMETER:u32=87;
    const WM_COPYDATA:u32=0x004A;
    const WM_DESTROY:u32=0x0002;
    const WM_CLOSE:u32=0x0010;
    const HWND_MESSAGE:isize=-3;
    const COPY_ID:usize=0xC0C0_2A61;
    const PROCESS_QUERY_LIMITED_INFORMATION:u32=0x1000;
    const SYNCHRONIZE:u32=0x0010_0000;
    const WAIT_OBJECT_0:u32=0;
    const TOKEN_QUERY:u32=8;
    const SMTO_BLOCK:u32=1;
    const SMTO_ABORTIFHUNG:u32=2;
    const PIPE_ACCESS_DUPLEX:u32=3;
    const FILE_FLAG_FIRST_PIPE_INSTANCE:u32=0x0008_0000;
    const PIPE_TYPE_MESSAGE:u32=4;
    const PIPE_READMODE_MESSAGE:u32=2;
    const PIPE_REJECT_REMOTE_CLIENTS:u32=8;
    const GENERIC_READ_WRITE:u32=0xC000_0000;
    const OPEN_EXISTING:u32=3;
    const INVALID_HANDLE:isize=-1;
    const ERROR_PIPE_CONNECTED:u32=535;
    const ERROR_PIPE_BUSY:u32=231;
    const CAPABILITY_SIZE:usize=16;
    #[cfg(test)]
    static TEST_SERVER_ACK_DELAY_MS:std::sync::atomic::AtomicU64=
        std::sync::atomic::AtomicU64::new(0);
    #[cfg(test)]
    static TEST_PRIMARY_PRELISTENER_DELAY_MS:std::sync::atomic::AtomicU64=
        std::sync::atomic::AtomicU64::new(0);
    #[cfg(test)]
    static TEST_PRIMARY_MUTEX_CREATED:AtomicBool=AtomicBool::new(false);
    #[cfg(test)]
    pub(super) fn set_server_ack_delay_for_test(ms:u64){
        TEST_SERVER_ACK_DELAY_MS.store(ms,Ordering::Release);
    }

    #[repr(C)]
    struct CopyData{id:usize,len:u32,bytes:*const c_void}
    #[repr(C)]
    struct Message{hwnd:isize,message:u32,wparam:usize,lparam:isize,time:u32,x:i32,y:i32,private:u32}
    #[repr(C)]
    struct WndClass{
        style:u32,
        callback:Option<unsafe extern "system" fn(isize,u32,usize,isize)->isize>,
        class_extra:i32,window_extra:i32,instance:isize,icon:isize,cursor:isize,
        background:isize,menu:*const u16,class:*const u16,
    }
    #[repr(C)]
    struct SidAttributes{sid:*mut c_void,attributes:u32}
    #[repr(C)]
    #[derive(Default)]
    struct FileTime{lo:u32,hi:u32}

    #[link(name="kernel32")]
    extern "system" {
        fn CreateMutexW(attributes:*const c_void,owned:i32,name:*const u16)->isize;
        fn GetLastError()->u32;
        fn CloseHandle(handle:isize)->i32;
        fn GetCurrentProcess()->isize;
        fn OpenProcess(access:u32,inherit:i32,pid:u32)->isize;
        fn WaitForSingleObject(handle:isize,millis:u32)->u32;
        fn QueryFullProcessImageNameW(handle:isize,flags:u32,text:*mut u16,length:*mut u32)->i32;
        fn GetModuleHandleW(name:*const u16)->isize;
        fn Sleep(millis:u32);
        fn GetProcessTimes(process:isize,created:*mut FileTime,exited:*mut FileTime,
            kernel:*mut FileTime,user:*mut FileTime)->i32;
        fn CreateNamedPipeW(name:*const u16,mode:u32,pipe_mode:u32,instances:u32,
            outgoing:u32,incoming:u32,timeout:u32,security:*const c_void)->isize;
        fn ConnectNamedPipe(pipe:isize,overlapped:*const c_void)->i32;
        fn DisconnectNamedPipe(pipe:isize)->i32;
        fn GetNamedPipeClientProcessId(pipe:isize,pid:*mut u32)->i32;
        fn GetNamedPipeServerProcessId(pipe:isize,pid:*mut u32)->i32;
        fn CreateFileW(name:*const u16,access:u32,share:u32,security:*const c_void,
            creation:u32,flags:u32,template:isize)->isize;
        fn WaitNamedPipeW(name:*const u16,timeout:u32)->i32;
        fn ReadFile(handle:isize,buffer:*mut c_void,length:u32,read:*mut u32,overlapped:*mut c_void)->i32;
        fn WriteFile(handle:isize,buffer:*const c_void,length:u32,written:*mut u32,overlapped:*mut c_void)->i32;
        fn PeekNamedPipe(handle:isize,buffer:*mut c_void,size:u32,read:*mut u32,
            available:*mut u32,remaining:*mut u32)->i32;
    }
    #[link(name="bcrypt")]
    extern "system" {
        fn BCryptGenRandom(algorithm:isize,buffer:*mut u8,len:u32,flags:u32)->i32;
    }
    #[link(name="advapi32")]
    extern "system" {
        fn OpenProcessToken(process:isize,access:u32,token:*mut isize)->i32;
        fn GetTokenInformation(token:isize,kind:u32,info:*mut c_void,size:u32,needed:*mut u32)->i32;
        fn GetLengthSid(sid:*const c_void)->u32;
    }
    #[link(name="user32")]
    extern "system" {
        fn RegisterClassW(definition:*const WndClass)->u16;
        fn CreateWindowExW(ex:u32,class:*const u16,title:*const u16,style:u32,x:i32,y:i32,
            width:i32,height:i32,parent:isize,menu:isize,instance:isize,param:*const c_void)->isize;
        fn DestroyWindow(window:isize)->i32;
        fn FindWindowExW(parent:isize,after:isize,class:*const u16,title:*const u16)->isize;
        fn GetWindowThreadProcessId(window:isize,pid:*mut u32)->u32;
        fn SendMessageTimeoutW(window:isize,message:u32,wparam:usize,lparam:isize,flags:u32,
            millis:u32,result:*mut usize)->isize;
        fn DefWindowProcW(window:isize,message:u32,wparam:usize,lparam:isize)->isize;
        fn GetMessageW(message:*mut Message,window:isize,min:u32,max:u32)->i32;
        fn TranslateMessage(message:*const Message)->i32;
        fn DispatchMessageW(message:*const Message)->isize;
        fn PostQuitMessage(code:i32);
        fn AllowSetForegroundWindow(pid:u32)->i32;
        fn PostMessageW(window:isize,message:u32,wparam:usize,lparam:isize)->i32;
        fn EnumWindows(callback:Option<unsafe extern "system" fn(isize,isize)->i32>,arg:isize)->i32;
        fn IsWindowVisible(window:isize)->i32;
        fn ShowWindow(window:isize,command:i32)->i32;
        fn SetForegroundWindow(window:isize)->i32;
    }
    struct Handle(isize);
    impl Drop for Handle{
        fn drop(&mut self){if self.0!=0{unsafe{CloseHandle(self.0);}}}
    }
    // Held until process exit. Windows releases it automatically on crash.
    static PRIMARY_MUTEX:OnceLock<Handle>=OnceLock::new();
    struct Listener {
        class:Vec<u16>,
        title:Vec<u16>,
        pipe:Vec<u16>,
        stop:Arc<AtomicBool>,
    }
    static LISTENERS:OnceLock<Mutex<Vec<Listener>>>=OnceLock::new();
    fn listeners()->&'static Mutex<Vec<Listener>>{
        LISTENERS.get_or_init(||Mutex::new(Vec::new()))
    }
    #[cfg(test)]
    pub(super) fn listeners_count_for_test()->usize{
        listeners().lock().map(|items|items.len()).unwrap_or(usize::MAX)
    }
    #[cfg(test)]
    pub(super) fn process_cpu_millis_for_test()->Result<u64,String>{
        let (mut a,mut b,mut kernel,mut user)=(
            FileTime::default(),FileTime::default(),FileTime::default(),FileTime::default());
        if unsafe{GetProcessTimes(GetCurrentProcess(),&mut a,&mut b,&mut kernel,&mut user)}==0 {
            return Err("Cannot inspect synthetic process CPU time".into());
        }
        let ticks=|t:FileTime|((t.hi as u64)<<32)|(t.lo as u64);
        Ok((ticks(kernel)+ticks(user))/10_000)
    }
    type Capability=([u8;CAPABILITY_SIZE],u32,Instant);
    static CAPABILITIES:OnceLock<Mutex<Vec<Capability>>>=OnceLock::new();
    fn caps()->&'static Mutex<Vec<Capability>>{
        CAPABILITIES.get_or_init(||Mutex::new(Vec::new()))
    }
    fn process_has_exited(pid:u32)->bool{
        if pid==0{return true;}
        // We inspect only PIDs previously authenticated as this executable.
        // A process that is unqueryable is retained until its normal 10s TTL;
        // lack of access must never revoke a live sender's one-time token.
        let raw=unsafe{OpenProcess(SYNCHRONIZE,0,pid)};
        if raw==0{
            // After a secondary has exited and its final OS handle closes,
            // OpenProcess returns INVALID_PARAMETER for its vanished PID.
            // ACCESS_DENIED or other errors remain fail-closed and expire by
            // TTL, so a live protected sender is never arbitrarily revoked.
            return unsafe{GetLastError()}==ERROR_INVALID_PARAMETER;
        }
        let _process=Handle(raw);
        (unsafe{WaitForSingleObject(raw,0)})==WAIT_OBJECT_0
    }
    fn issue_capability(pid:u32)->Result<[u8;CAPABILITY_SIZE],String>{
        let mut token=[0u8;CAPABILITY_SIZE];
        if unsafe{BCryptGenRandom(0,token.as_mut_ptr(),token.len() as u32,2)}!=0{
            return Err("Windows secure randomness unavailable".into());
        }
        let mut lock=caps().lock().map_err(|_|"IPC capability state poisoned")?;
        let now=Instant::now();
        lock.retain(|(_,owner,born)|
            now.duration_since(*born)<Duration::from_secs(10)&&!process_has_exited(*owner));
        if lock.len()>=MAX_PENDING{return Err("Too many outstanding IPC capabilities".into());}
        if lock.iter().any(|(existing,_,_)|*existing==token){
            return Err("Windows IPC capability collision".into());
        }
        lock.push((token,pid,now));
        Ok(token)
    }
    fn consume_capability(token:&[u8],pid:u32)->bool{
        if token.len()!=CAPABILITY_SIZE{return false;}
        let Ok(mut lock)=caps().lock() else{return false};
        let Some(index)=lock.iter().position(|(value,_,_)|value.as_slice()==token) else{return false};
        // A sender with the wrong PID must not revoke another process's
        // authenticated one-time capability. Only its intended owner can
        // consume it, whether valid or expired.
        if lock[index].1!=pid{return false;}
        let (_,allowed,issued)=lock.swap_remove(index);
        allowed==pid&&issued.elapsed()<Duration::from_secs(10)
    }
    fn revoke_capability(token:&[u8;CAPABILITY_SIZE]){
        if let Ok(mut lock)=caps().lock(){
            lock.retain(|(value,_,_)|value!=token);
        }
    }
    #[cfg(test)]
    pub(super) fn outstanding_capabilities_for_test()->usize{
        caps().lock().map(|s|s.len()).unwrap_or(usize::MAX)
    }
    #[cfg(test)]
    pub(super) fn capability_for_test(pid:u32)->Result<[u8;CAPABILITY_SIZE],String>{
        issue_capability(pid)
    }
    #[cfg(test)]
    pub(super) fn consume_capability_for_test(token:&[u8],pid:u32)->bool{
        consume_capability(token,pid)
    }

    fn wide(text:&str)->Vec<u16>{text.encode_utf16().chain(Some(0)).collect()}
    fn user_sid(process:isize)->Result<Vec<u8>,String>{
        let mut token=0isize;
        if unsafe{OpenProcessToken(process,TOKEN_QUERY,&mut token)}==0{
            return Err("Cannot inspect Windows process owner".into());
        }
        let token=Handle(token);
        let mut needed=0u32;
        unsafe{GetTokenInformation(token.0,1,ptr::null_mut(),0,&mut needed);}
        if needed<16||needed>4096{return Err("Invalid Windows owner token size".into());}
        let mut buffer=vec![0u64;(needed as usize+7)/8];
        if unsafe{GetTokenInformation(token.0,1,buffer.as_mut_ptr().cast(),needed,&mut needed)}==0{
            return Err("Cannot read Windows process owner".into());
        }
        let info=unsafe{ptr::read_unaligned(buffer.as_ptr() as *const SidAttributes)};
        if info.sid.is_null(){return Err("Windows process has no user SID".into());}
        let size=unsafe{GetLengthSid(info.sid)};
        if !(8..=128).contains(&size){return Err("Invalid Windows SID length".into());}
        Ok(unsafe{std::slice::from_raw_parts(info.sid.cast::<u8>(),size as usize)}.to_vec())
    }
    fn own_sid()->Result<Vec<u8>,String>{user_sid(unsafe{GetCurrentProcess()})}
    fn peer_is_our_executable(pid:u32)->bool{
        if pid==0{return false;}
        let raw=unsafe{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,pid)};
        if raw==0{return false;}
        let peer=Handle(raw);
        let mut buffer=vec![0u16;32768];let mut len=buffer.len() as u32;
        if unsafe{QueryFullProcessImageNameW(peer.0,0,buffer.as_mut_ptr(),&mut len)}==0{
            return false;
        }
        let path=PathBuf::from(OsString::from_wide(&buffer[..len as usize]));
        let Ok(ours)=std::env::current_exe() else{return false};
        let norm=|p:&Path|p.to_string_lossy().trim_start_matches(r"\\?\").to_ascii_lowercase();
        if norm(&ours)!=norm(&path){return false;}
        let Ok(our_sid)=own_sid() else{return false};
        user_sid(peer.0).is_ok_and(|sid|sid==our_sid)
    }
    fn namespace()->Result<(Vec<u16>,Vec<u16>,Vec<u16>),String>{
        let exe=std::env::current_exe().map_err(|_|"Cannot resolve installed executable")?;
        let mut digest=Sha256::new();
        digest.update(exe.to_string_lossy().to_ascii_lowercase().as_bytes());
        digest.update(own_sid()?);
        let hex=format!("{:x}",digest.finalize());
        let id=&hex[..32];
        Ok((wide(&format!("Local\\Coco2.FileActivation.{id}")),
            wide(&format!("Coco2.Activation.Class.{id}")),
            wide(&format!("Coco2.Activation.Window.{id}"))))
    }
    fn pipe_for_class(class:&[u16])->Result<Vec<u16>,String>{
        let class=String::from_utf16(class.strip_suffix(&[0]).unwrap_or(class))
            .map_err(|_|"Invalid native package class name")?;
        let suffix=format!("{:x}",Sha256::digest(class.as_bytes()));
        Ok(wide(&format!(r"\\.\pipe\Coco2.Activation.{}",&suffix[..32])))
    }
    fn run_pipe_server(name:Vec<u16>,ready:mpsc::SyncSender<Result<(),String>>,
        stop:Arc<AtomicBool>){
        // Hold one first-instance pipe handle for the server lifetime so
        // other processes never claim its name between two connections.
        let raw=unsafe{CreateNamedPipeW(name.as_ptr(),PIPE_ACCESS_DUPLEX|FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_REJECT_REMOTE_CLIENTS,
            1,64,64,1500,ptr::null())};
        if raw==INVALID_HANDLE{
            let _=ready.send(Err("Private IPC pipe name is already owned".into()));
            return;
        }
        let pipe=Handle(raw);
        let _=ready.send(Ok(()));
        while !stop.load(Ordering::Acquire) {
            let connected=unsafe{ConnectNamedPipe(pipe.0,ptr::null())};
            if connected==0 && unsafe{GetLastError()}!=ERROR_PIPE_CONNECTED {
                // A failed connection may leave the pipe disconnected.
                // Reset + sleep before retrying, never spin at 100% CPU.
                unsafe{DisconnectNamedPipe(pipe.0);Sleep(25);}
                continue;
            }
            if stop.load(Ordering::Acquire){
                unsafe{DisconnectNamedPipe(pipe.0);}
                break;
            }
            let mut peer_pid=0u32;
            let got_peer=unsafe{GetNamedPipeClientProcessId(pipe.0,&mut peer_pid)}!=0;
            let peer_trusted=got_peer && peer_is_our_executable(peer_pid);
            if peer_trusted {
                if let Ok(token)=issue_capability(peer_pid){
                    let mut wrote=0u32;
                    let successful=unsafe{WriteFile(pipe.0,token.as_ptr().cast(),token.len() as u32,
                        &mut wrote,ptr::null_mut())}!=0;
                    let mut acknowledged=false;
                    if successful&&wrote==CAPABILITY_SIZE as u32 {
                        // PeekNamedPipe never blocks awaiting unread client
                        // data, unlike FlushFileBuffers. Keep normal blocking
                        // pipe mode for the client's ReadFile and bound this
                        // acknowledgment wait to 1200 ms.
                        let deadline=Instant::now()+Duration::from_millis(1200);
                        loop {
                            let mut available=0u32;
                            let alive=unsafe{PeekNamedPipe(pipe.0,ptr::null_mut(),0,
                                ptr::null_mut(),&mut available,ptr::null_mut())}!=0;
                            if !alive || Instant::now()>=deadline
                                ||stop.load(Ordering::Acquire) {break;}
                            if available>=1 {
                                let mut ack=[0u8;1];let mut count=0u32;
                                let received=unsafe{ReadFile(pipe.0,ack.as_mut_ptr().cast(),1,
                                    &mut count,ptr::null_mut())};
                                if received!=0&&count==1&&ack[0]==0xA5 {
                                    #[cfg(test)]{
                                        let delay=TEST_SERVER_ACK_DELAY_MS.load(Ordering::Acquire);
                                        if delay!=0{unsafe{Sleep(delay as u32);}}
                                    }
                                    // The sender used to close its pipe right
                                    // after writing 0xA5. Windows can report a
                                    // disconnected pipe before this loop reads
                                    // that ACK, revoking a token already being
                                    // sent over WM_COPYDATA. Confirm receipt
                                    // before the sender uses the capability.
                                    let ready=[0x5Au8];
                                    let mut confirmed=0u32;
                                    let sent=unsafe{WriteFile(pipe.0,ready.as_ptr().cast(),1,
                                        &mut confirmed,ptr::null_mut())}!=0;
                                    if sent&&confirmed==1 {
                                        acknowledged=true;
                                        // Keep the pipe connected until the
                                        // client has actually read 0x5A. Do
                                        // not use blocking FlushFileBuffers:
                                        // a dead peer must never hang the
                                        // primary IPC thread indefinitely.
                                        let read_deadline=Instant::now()+Duration::from_millis(1200);
                                        loop {
                                            let mut available=0u32;
                                            let alive=unsafe{PeekNamedPipe(pipe.0,ptr::null_mut(),0,
                                                ptr::null_mut(),&mut available,ptr::null_mut())}!=0;
                                            if !alive||Instant::now()>=read_deadline
                                                ||stop.load(Ordering::Acquire){break;}
                                            if available>=1 {
                                                let mut receipt=[0u8;1];
                                                let mut count=0u32;
                                                let received=unsafe{ReadFile(pipe.0,
                                                    receipt.as_mut_ptr().cast(),1,&mut count,
                                                    ptr::null_mut())}!=0;
                                                if received&&count==1&&receipt[0]==0xC3{break;}
                                                break;
                                            }
                                            unsafe{Sleep(10);}
                                        }
                                    }
                                    break;
                                }
                            }
                            unsafe{Sleep(10);}
                        }
                    }
                    // A peer that exits without acknowledging must not
                    // consume one of the bounded one-time capability slots.
                    // Concurrent successful WM_COPYDATA may have already
                    // consumed the token; removing it again is harmless.
                    if !acknowledged{revoke_capability(&token);}
                }
            }
            unsafe{DisconnectNamedPipe(pipe.0);}
        }
    }
    fn start_pipe_server(name:Vec<u16>,stop:Arc<AtomicBool>)->Result<(),String>{
        let (tx,rx)=mpsc::sync_channel(1);
        std::thread::Builder::new().name("coco2-activation-auth".into())
            .spawn(move||run_pipe_server(name,tx,stop))
            .map_err(|_|"Cannot start secure native activation authentication")?;
        rx.recv_timeout(Duration::from_secs(3))
            .map_err(|_|"Secure native activation listener did not start")?
    }
    fn get_pipe_capability(name:&[u16])->Result<[u8;CAPABILITY_SIZE],String>{
        // After CreateMutexW, a first run may need several seconds for
        // antivirus inspection or slow storage before it exposes the pipe.
        // The former 32*25ms missing-pipe retry budget dropped valid Explorer
        // openings after less than a second. Use one bounded cold-start
        // deadline; every successful pipe still authenticates its server PID.
        let connect_deadline=Instant::now()+Duration::from_secs(9);
        let pipe=loop {
            let handle=unsafe{CreateFileW(name.as_ptr(),GENERIC_READ_WRITE,0,ptr::null(),
                OPEN_EXISTING,0,0)};
            if handle!=INVALID_HANDLE{
                break Handle(handle);
            }
            let code=unsafe{GetLastError()};
            if code!=ERROR_PIPE_BUSY&&code!=2 {
                return Err("Native activation endpoint is unavailable".into());
            }
            if Instant::now()>=connect_deadline {
                return Err("Native activation authentication timed out".into());
            }
            if code==ERROR_PIPE_BUSY {
                unsafe{WaitNamedPipeW(name.as_ptr(),75);}
            } else {
                unsafe{Sleep(40);}
            }
        };
        let mut server_pid=0u32;
        if unsafe{GetNamedPipeServerProcessId(pipe.0,&mut server_pid)}==0
            ||!peer_is_our_executable(server_pid) {
            return Err("Authentication pipe owner is not a trusted Coco2 process".into());
        }
        // A malicious same-name server must not freeze the secondary launch:
        // a blocking read runs in its own thread with a 2-second deadline.
        let (tx,rx)=mpsc::sync_channel(1);
        std::thread::Builder::new().name("coco2-activation-auth-read".into())
            .spawn(move||{
                let mut token=[0u8;CAPABILITY_SIZE];
                let mut count=0u32;
                let rc=unsafe{ReadFile(pipe.0,token.as_mut_ptr().cast(),token.len() as u32,
                    &mut count,ptr::null_mut())};
                if rc!=0&&count==CAPABILITY_SIZE as u32 {
                    let ack=[0xA5u8];
                    let mut sent=0u32;
                    let done=unsafe{WriteFile(pipe.0,ack.as_ptr().cast(),1,
                        &mut sent,ptr::null_mut())}!=0;
                    if !done||sent!=1 {
                        let _=tx.send(Err("Activation pipe acknowledgment failed".into()));
                        return;
                    }
                    let mut confirmed=[0u8;1];
                    let mut read=0u32;
                    let ready=unsafe{ReadFile(pipe.0,confirmed.as_mut_ptr().cast(),1,
                        &mut read,ptr::null_mut())}!=0;
                    if !ready||read!=1||confirmed[0]!=0x5A {
                        let _=tx.send(Err("Activation server did not confirm acknowledgment".into()));
                        return;
                    }
                    // Give the server evidence it may safely disconnect;
                    // a later handoff cannot race its token revocation.
                    let receipt=[0xC3u8];
                    let mut written=0u32;
                    let final_ack=unsafe{WriteFile(pipe.0,receipt.as_ptr().cast(),1,
                        &mut written,ptr::null_mut())}!=0;
                    let _=tx.send(if final_ack&&written==1 {Ok(token)}
                        else {Err("Activation confirmation receipt failed".into())});
                }else {
                    let _=tx.send(Err("Authentication pipe returned incomplete capability".into()));
                }
            }).map_err(|_|"Cannot start bounded activation pipe read")?;
        rx.recv_timeout(Duration::from_secs(2))
            .map_err(|_|"Authentication pipe timed out")?
    }
    #[cfg(test)]
    pub(super) fn delayed_ack_contract_for_test()->Result<(u128,usize),String>{
        use std::sync::atomic::{AtomicU64,Ordering};
        static NEXT:AtomicU64=AtomicU64::new(0);
        let id=NEXT.fetch_add(1,Ordering::Relaxed);
        let class=wide(&format!("Coco2.Test.AckWait.{}.{}",std::process::id(),id));
        let title=wide(&format!("Coco2.Test.AckWindow.{}.{}",std::process::id(),id));
        start_listeners(class.clone(),title)?;
        TEST_SERVER_ACK_DELAY_MS.store(250,Ordering::Release);
        let start=Instant::now();
        let result=get_pipe_capability(&pipe_for_class(&class)?);
        let elapsed=start.elapsed().as_millis();
        TEST_SERVER_ACK_DELAY_MS.store(0,Ordering::Release);
        let token=result?;
        let valid=consume_capability(&token,std::process::id());
        if !valid{return Err("Delayed ACK capability was revoked before client could use it".into());}
        Ok((elapsed,outstanding_capabilities_for_test()))
    }

    fn encode(requests:&[PackageOpenRequest])->Result<Vec<u8>,String>{
        if requests.len()>MAX_REQUESTS{return Err("Activation count too large".into());}
        let mut bytes=(requests.len() as u32).to_le_bytes().to_vec();
        for request in requests{
            let utf16=request.path.encode_utf16().collect::<Vec<_>>();
            if utf16.is_empty()||utf16.len()>MAX_PATH_UNITS||utf16.contains(&0){
                return Err("Activation path contains invalid UTF-16 units".into());
            }
            bytes.extend_from_slice(&(utf16.len() as u32).to_le_bytes());
            for ch in utf16 {bytes.extend_from_slice(&ch.to_le_bytes());}
            if bytes.len()>MAX_PAYLOAD{return Err("Activation IPC too large".into());}
        }
        Ok(bytes)
    }
    fn decode(bytes:&[u8])->Result<Vec<PackageOpenRequest>,String>{
        if bytes.len()<4||bytes.len()>MAX_PAYLOAD{return Err("IPC payload has unsafe length".into());}
        let count=u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
        if count>MAX_REQUESTS{return Err("IPC request count too large".into());}
        let mut cursor=4;let mut args=Vec::with_capacity(count);
        for _ in 0..count{
            if cursor+4>bytes.len(){return Err("IPC path header truncated".into());}
            let n=u32::from_le_bytes(bytes[cursor..cursor+4].try_into().unwrap()) as usize;
            cursor+=4;
            let remaining=n.checked_mul(2).ok_or("IPC path size overflow")?;
            if n==0||n>MAX_PATH_UNITS||cursor+remaining>bytes.len(){
                return Err("IPC path body truncated or oversized".into());
            }
            let mut utf16=Vec::with_capacity(n);
            for at in (cursor..cursor+remaining).step_by(2){
                utf16.push(u16::from_le_bytes([bytes[at],bytes[at+1]]));
            }
            if utf16.contains(&0){return Err("IPC path contains embedded terminator".into());}
            args.push(OsString::from_wide(&utf16));
            cursor+=remaining;
        }
        if cursor!=bytes.len(){return Err("IPC trailing bytes refused".into());}
        parse(args,"warm")
    }
    unsafe extern "system" fn find_primary_window(hwnd:isize,context:isize)->i32 {
        let mut pid=0u32;
        if GetWindowThreadProcessId(hwnd,&mut pid)!=0
            && pid==std::process::id() && IsWindowVisible(hwnd)!=0 {
            let target=&mut *(context as *mut isize);
            *target=hwnd;
            return 0;
        }
        1
    }
    fn foreground_primary_window(){
        let mut target=0isize;
        unsafe {
            EnumWindows(Some(find_primary_window),&mut target as *mut isize as isize);
            if target!=0 {
                ShowWindow(target,9); // SW_RESTORE
                SetForegroundWindow(target);
            }
        }
    }
    unsafe extern "system" fn window_proc(hwnd:isize,kind:u32,wparam:usize,lparam:isize)->isize{
        if kind==WM_COPYDATA{
            if ACTIVATION_CLOSED.load(Ordering::Acquire){return 0;}
            let mut pid=0u32;
            if wparam==0||GetWindowThreadProcessId(wparam as isize,&mut pid)==0
                ||!peer_is_our_executable(pid)||lparam==0{return 0;}
            let data=&*(lparam as *const CopyData);
            if data.id!=COPY_ID||data.bytes.is_null()||data.len<(4+CAPABILITY_SIZE) as u32
                ||data.len as usize>MAX_PAYLOAD+CAPABILITY_SIZE{return 0;}
            let raw=std::slice::from_raw_parts(data.bytes.cast::<u8>(),data.len as usize);
            // Authenticate before decoding filenames or touching filesystem
            // metadata: forged WM_COPYDATA cannot trigger disk scans.
            if consume_capability(&raw[..CAPABILITY_SIZE],pid){
                if let Ok(requests)=decode(&raw[CAPABILITY_SIZE..]){
                    if queue(requests).is_err(){return 0;}
                    // HWND focus doesn't require constructing Wry webviews or
                    // opening a new Tauri window in the second process.
                    foreground_primary_window();
                    return 1;
                }
            }
            return 0;
        }
        if kind==WM_CLOSE{DestroyWindow(hwnd);return 0;}
        if kind==WM_DESTROY{PostQuitMessage(0);return 0;}
        DefWindowProcW(hwnd,kind,wparam,lparam)
    }
    fn make_window(class:&[u16],title:&[u16],receiver:bool)->Result<isize,String>{
        let module=unsafe{GetModuleHandleW(ptr::null())};
        if module==0{return Err("Cannot get Win32 module handle".into());}
        if receiver{
            let def=WndClass{
                style:0,callback:Some(window_proc),class_extra:0,window_extra:0,
                instance:module,icon:0,cursor:0,background:0,menu:ptr::null(),class:class.as_ptr(),
            };
            if unsafe{RegisterClassW(&def)}==0{return Err("Cannot register activation receiver class".into());}
        }
        let hwnd=unsafe{CreateWindowExW(0,class.as_ptr(),title.as_ptr(),0,0,0,0,0,
            HWND_MESSAGE,0,module,ptr::null())};
        if hwnd==0{return Err("Cannot create hidden package receiver window".into());}
        Ok(hwnd)
    }
    fn start_receiver(class:Vec<u16>,title:Vec<u16>)->Result<(),String>{
        let (tx,rx)=mpsc::sync_channel(1);
        std::thread::Builder::new().name("coco2-activation".into())
            .spawn(move||{
                match make_window(&class,&title,true){
                    Ok(hwnd)=>{
                        let _=tx.send(Ok(()));
                        let mut message=Message{hwnd:0,message:0,wparam:0,lparam:0,
                            time:0,x:0,y:0,private:0};
                        loop{
                            let status=unsafe{GetMessageW(&mut message,0,0,0)};
                            if status<=0{break;}
                            unsafe{TranslateMessage(&message);DispatchMessageW(&message);}
                        }
                        unsafe{DestroyWindow(hwnd);}
                    }
                    Err(e)=>{let _=tx.send(Err(e));}
                }
            }).map_err(|_|"Cannot start package activation listener")?;
        rx.recv_timeout(Duration::from_secs(3))
            .map_err(|_|"Native package listener did not start")?
    }
    fn start_listeners(class:Vec<u16>,title:Vec<u16>)->Result<(),String>{
        let pipe=pipe_for_class(&class)?;
        let stop=Arc::new(AtomicBool::new(false));
        start_receiver(class.clone(),title.clone())?;
        if let Err(error)=start_pipe_server(pipe.clone(),stop.clone()){
            let hwnd=unsafe{FindWindowExW(HWND_MESSAGE,0,class.as_ptr(),title.as_ptr())};
            if hwnd!=0{unsafe{PostMessageW(hwnd,WM_CLOSE,0,0);}}
            return Err(error);
        }
        let mut active=listeners().lock().map_err(|_|"Activation listener registry poisoned")?;
        active.push(Listener{class,title,pipe,stop});
        Ok(())
    }
    pub(super) fn shutdown_listeners()->Result<(),String>{
        let mut active=listeners().lock().map_err(|_|"Activation listener registry poisoned")?;
        for listener in active.drain(..){
            listener.stop.store(true,Ordering::Release);
            let hwnd=unsafe{FindWindowExW(HWND_MESSAGE,0,
                listener.class.as_ptr(),listener.title.as_ptr())};
            if hwnd!=0{unsafe{PostMessageW(hwnd,WM_CLOSE,0,0);}}
            // Wake the blocking ConnectNamedPipe without sending a package
            // or reading data. The listener checks stop before authentication.
            let raw=unsafe{CreateFileW(listener.pipe.as_ptr(),GENERIC_READ_WRITE,0,
                ptr::null(),OPEN_EXISTING,0,0)};
            if raw!=INVALID_HANDLE{drop(Handle(raw));}
        }
        Ok(())
    }
    fn handoff(class:&[u16],title:&[u16],requests:&[PackageOpenRequest])->Result<(),String>{
        let mut bytes=get_pipe_capability(&pipe_for_class(class)?)?.to_vec();
        bytes.extend_from_slice(&encode(requests)?);
        let sender=make_window(&wide("STATIC"),&wide("Coco2.Activation.Sender"),false)?;
        let result=(||{
            for _ in 0..32{
                let hwnd=unsafe{FindWindowExW(HWND_MESSAGE,0,class.as_ptr(),title.as_ptr())};
                if hwnd!=0{
                    let mut pid=0u32;
                    if unsafe{GetWindowThreadProcessId(hwnd,&mut pid)}==0
                        ||!peer_is_our_executable(pid) {
                        return Err("Existing activation receiver identity is not trusted".into());
                    }
                    unsafe{AllowSetForegroundWindow(pid);}
                    let data=CopyData{id:COPY_ID,len:bytes.len() as u32,bytes:bytes.as_ptr().cast()};
                    let mut accepted=0usize;
                    let sent=unsafe{SendMessageTimeoutW(hwnd,WM_COPYDATA,sender as usize,
                        &data as *const _ as isize,SMTO_ABORTIFHUNG|SMTO_BLOCK,
                        1750,&mut accepted)};
                    if sent!=0&&accepted==1{return Ok(());}
                    return Err("Existing app rejected or timed out during activation handoff".into());
                }
                unsafe{Sleep(100);}
            }
            Err("Existing Coco2 process has not exposed the package receiver".into())
        })();
        unsafe{DestroyWindow(sender);}
        result
    }
    #[cfg(test)]
    fn isolated_namespace(channel:&str)->Result<(Vec<u16>,Vec<u16>,Vec<u16>),String>{
        if channel.is_empty() || channel.len()>64 ||
            !channel.bytes().all(|c|c.is_ascii_alphanumeric()) {
            return Err("Isolated activation test namespace invalid".into());
        }
        let (mutex,_,_)=namespace()?;
        let mut sha=Sha256::new();
        for code_unit in &mutex {sha.update(code_unit.to_le_bytes());}
        sha.update(channel.as_bytes());
        let id=format!("{:x}",sha.finalize());
        let id=&id[..32];
        Ok((
            wide(&format!("Local\\Coco2.TEST.FileActivation.{id}")),
            wide(&format!("Coco2.TEST.Activation.Class.{id}")),
            wide(&format!("Coco2.TEST.Activation.Window.{id}")),
        ))
    }
    fn start_with(requests:Vec<PackageOpenRequest>,isolated_channel:Option<&str>)
        ->Result<bool,String>{
        let (mut mutex,mut class,mut title)=namespace()?;
        #[cfg(test)]
        if let Some(channel)=isolated_channel {
            (mutex,class,title)=isolated_namespace(channel)?;
        }
        #[cfg(not(test))]
        let _=isolated_channel;
        let raw=unsafe{CreateMutexW(ptr::null(),0,mutex.as_ptr())};
        if raw==0{return Err("Could not create native single-instance mutex".into());}
        let is_secondary=unsafe{GetLastError()}==ERROR_ALREADY_EXISTS;
        if is_secondary{
            let _handle=Handle(raw);
            handoff(&class,&title,&requests)?;
            return Ok(false);
        }
        PRIMARY_MUTEX.set(Handle(raw)).map_err(|_|"Activation already initialized")?;
        #[cfg(test)] {
            TEST_PRIMARY_MUTEX_CREATED.store(true,Ordering::Release);
            let delay=TEST_PRIMARY_PRELISTENER_DELAY_MS.load(Ordering::Acquire);
            if delay!=0{unsafe{Sleep(delay as u32);}}
        }
        start_listeners(class,title)?;
        queue(requests)?;
        Ok(true)
    }
    #[cfg(test)]
    pub(super) fn delay_primary_listener_for_test(milliseconds:u64){
        TEST_PRIMARY_PRELISTENER_DELAY_MS.store(milliseconds,Ordering::Release);
        TEST_PRIMARY_MUTEX_CREATED.store(false,Ordering::Release);
    }
    #[cfg(test)]
    pub(super) fn primary_mutex_created_for_test()->bool{
        TEST_PRIMARY_MUTEX_CREATED.load(Ordering::Acquire)
    }
    pub(super) fn start_or_handoff()->Result<bool,String>{
        start_with(parse(std::env::args_os().skip(1),"cold")?,None)
    }
    #[cfg(test)]
    pub(super) fn start_isolated_for_test(
        channel:&str,args:Vec<OsString>,
    )->Result<bool,String>{
        start_with(parse(args,"cold")?,Some(channel))
    }
    #[cfg(test)]
    pub(super) fn abandoned_pipe_client_for_test(
        channel:&str,after_token:bool,
    )->Result<(),String>{
        let (_,class,_)=isolated_namespace(channel)?;
        let pipe_name=pipe_for_class(&class)?;
        if after_token{
            // Authenticated subprocess receives a one-time capability but
            // exits before the WM_COPYDATA handoff. The primary must remain
            // responsive and accept an unrelated later opening.
            let _unused=get_pipe_capability(&pipe_name)?;
        }else{
            // Crash/close immediately after connecting, without reading any
            // server bytes or acknowledging them. Only this test-owned pipe
            // endpoint is opened; no UI, files or external services.
            let raw=unsafe{CreateFileW(pipe_name.as_ptr(),GENERIC_READ_WRITE,0,
                ptr::null(),OPEN_EXISTING,0,0)};
            if raw==INVALID_HANDLE{
                return Err("Synthetic aborted IPC client could not connect".into());
            }
            drop(Handle(raw));
        }
        Ok(())
    }
    #[cfg(test)]
    pub(super) fn unacknowledged_pipe_client_for_test(channel:&str)->Result<(),String>{
        let (_,class,_)=isolated_namespace(channel)?;
        let pipe_name=pipe_for_class(&class)?;
        let raw=unsafe{CreateFileW(pipe_name.as_ptr(),GENERIC_READ_WRITE,0,
            ptr::null(),OPEN_EXISTING,0,0)};
        if raw==INVALID_HANDLE{return Err("Test-owned no-ACK pipe could not connect".into());}
        let pipe=Handle(raw);
        let mut token=[0u8;CAPABILITY_SIZE];
        let mut received=0u32;
        if unsafe{ReadFile(pipe.0,token.as_mut_ptr().cast(),token.len() as u32,
            &mut received,ptr::null_mut())}==0 || received!=token.len() as u32 {
            return Err("Test-owned no-ACK client did not receive its capability".into());
        }
        // No 0xA5 ACK and no WM_COPYDATA; closing this exact handle simulates
        // process death between authentication and delivering the package.
        Ok(())
    }
    #[cfg(test)]
    pub(super) fn roundtrip_for_test(requests:&[PackageOpenRequest])
        ->Result<Vec<PackageOpenRequest>,String>{decode(&encode(requests)?)}

    #[cfg(test)]
    pub(super) fn synthetic_native_handoff_for_test(
        request:PackageOpenRequest,
    )->Result<Vec<PackageOpenRequest>,String>{
        use std::sync::atomic::{AtomicU64,Ordering};
        static NEXT:AtomicU64=AtomicU64::new(0);
        let id=NEXT.fetch_add(1,Ordering::SeqCst);
        let class=wide(&format!("Coco2.Test.Activation.{}.{}",std::process::id(),id));
        let title=wide(&format!("Coco2.Test.Receiver.{}.{}",std::process::id(),id));
        start_listeners(class.clone(),title.clone())?;
        // This sender owns a valid HWND and runs from the SAME binary and
        // user identity. Its WM_COPYDATA is still rejected without a
        // one-time capability obtained through the authenticated pipe.
        let hwnd=unsafe{FindWindowExW(HWND_MESSAGE,0,class.as_ptr(),title.as_ptr())};
        let sender=make_window(&wide("STATIC"),&wide("Coco2.Test.Unauthenticated"),false)?;
        let mut forged=vec![0u8;CAPABILITY_SIZE];
        forged.extend_from_slice(&encode(&[request.clone()])?);
        let fake=CopyData{id:COPY_ID,len:forged.len() as u32,bytes:forged.as_ptr().cast()};
        let mut accepted=0usize;
        let outcome=unsafe{SendMessageTimeoutW(hwnd,WM_COPYDATA,sender as usize,
            &fake as *const _ as isize,SMTO_BLOCK|SMTO_ABORTIFHUNG,1750,&mut accepted)};
        unsafe{DestroyWindow(sender);}
        if outcome==0||accepted!=0{return Err("Unauthenticated HWND sender was not rejected".into());}
        handoff(&class,&title,&[request])?;
        let items=take_pending_package_open_requests();
        let hwnd=unsafe{FindWindowExW(HWND_MESSAGE,0,class.as_ptr(),title.as_ptr())};
        if hwnd!=0{unsafe{PostMessageW(hwnd,WM_CLOSE,0,0);}}
        Ok(items)
    }

    #[cfg(test)]
    pub(super) fn cross_process_receiver_for_test(channel:&str)->Result<(),String>{
        let class=wide(&format!("Coco2.Test.Activation.CrossProcess.{channel}"));
        let title=wide(&format!("Coco2.Test.Receiver.CrossProcess.{channel}"));
        start_listeners(class,title)
    }

    #[cfg(test)]
    pub(super) fn cross_process_sender_for_test(channel:&str,path:&Path)->Result<(),String>{
        let class=wide(&format!("Coco2.Test.Activation.CrossProcess.{channel}"));
        let title=wide(&format!("Coco2.Test.Receiver.CrossProcess.{channel}"));
        let requests=parse([path.as_os_str().to_os_string()],"warm")?;
        handoff(&class,&title,&requests)
    }
}

/// Before constructing a Tauri Builder: Ok(true) owns primary instance.
/// Ok(false) means a trusted existing instance received the handoff.
pub fn start_or_handoff()->Result<bool,String>{
    #[cfg(windows)]{windows_impl::start_or_handoff()}
    #[cfg(not(windows))]{
        queue(parse(std::env::args_os().skip(1),"cold")?)?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests{
    use super::*;
    use std::time::{SystemTime,UNIX_EPOCH};
    // Windows' system clock can return the same nanosecond-looking timestamp
    // to concurrent tests. Give every synthetic TEMP fixture a process-local
    // serial as well: a real collision previously caused create_dir to fail.
    static TEMP_SERIAL:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
    fn root()->PathBuf{
        let tick=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let serial=TEMP_SERIAL.fetch_add(1,Ordering::Relaxed);
        let dir=std::env::temp_dir().join(format!("coco2-activation-{}-{tick}-{serial}",std::process::id()));
        std::fs::create_dir(&dir).unwrap();dir
    }
    // The real receiver intentionally deposits all activations in one global
    // queue. Tests that drain that queue must not run alongside one another:
    // otherwise a concurrent test can consume another test's valid request.
    fn exclusive_pending_queue()->std::sync::MutexGuard<'static,()>{
        static SERIAL:OnceLock<Mutex<()>>=OnceLock::new();
        SERIAL.get_or_init(||Mutex::new(())).lock().unwrap()
    }
    #[test]
    fn unicode_spaces_both_extensions_and_dedup(){
        let dir=root();
        let a=dir.join("Mi juego 漢字.coco2pack");
        let b=dir.join("A 💜.coco2pack.zip");
        std::fs::write(&a,b"untrusted data not inspected").unwrap();
        std::fs::write(&b,b"untrusted data not inspected").unwrap();
        let found=parse([a.clone().into_os_string(),b.clone().into_os_string(),a.into_os_string()],"cold").unwrap();
        assert_eq!(found.len(),2);
        assert!(found[0].path.contains("漢字"));
        assert!(found[1].path.contains("💜"));
        #[cfg(windows)]{
            let ipc=windows_impl::roundtrip_for_test(&found).unwrap();
            assert_eq!(ipc.len(),2);assert_eq!(ipc[0].path,found[0].path);
            assert_eq!(ipc[0].source,"warm");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn flags_relative_unknown_and_missing_rejected(){
        let dir=root();
        let a=dir.join("a.coco2pack");
        std::fs::write(&a,b"x").unwrap();
        assert!(parse([OsString::from("--bad")],"cold").is_err());
        assert!(parse([OsString::from("relative.coco2pack")],"cold").is_err());
        assert!(parse([dir.join("bad.zip").into_os_string()],"cold").is_err());
        assert!(parse([dir.join("missing.coco2pack").into_os_string()],"cold").is_err());
        assert!(parse(vec![a.into_os_string();MAX_REQUESTS+1],"cold").is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn repeated_long_path_dedup_does_not_spend_ipc_budget_on_duplicates(){
        let dir=root();
        let mut nested=dir.clone();
        for i in 0..29 {
            nested=nested.join(format!("Nivel {i:02} 漢字{}", "x".repeat(95)));
            std::fs::create_dir(&nested).unwrap();
        }
        let file=nested.join("Entrega Unicode 💜.coco2pack");
        std::fs::write(&file,b"synthetic, not a ZIP").unwrap();
        let canonical=checked_path(&file.clone().into_os_string()).unwrap();
        let units=canonical.encode_utf16().count();
        assert!(units>MAX_PAYLOAD/(MAX_REQUESTS*2),
            "fixture must exceed the IPC budget only when duplicates are counted");
        assert!(units<MAX_PATH_UNITS);
        let parsed=parse(vec![file.into_os_string();MAX_REQUESTS],"cold").unwrap();
        assert_eq!(parsed.len(),1);
        assert_eq!(parsed[0].path,canonical);
        assert_eq!(windows_impl::roundtrip_for_test(&parsed).unwrap()[0].source,"warm");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn requests_drain_once(){
        let _exclusive=exclusive_pending_queue();
        let dir=root();let path=dir.join("q.coco2pack");
        std::fs::write(&path,b"not a zip").unwrap();
        let items=parse([path.into_os_string()],"cold").unwrap();
        queue(items.clone()).unwrap();
        assert_eq!(take_pending_package_open_requests(),items);
        assert!(take_pending_package_open_requests().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn v26_native_drain_before_js_subscription_cannot_advertise_ready_listener(){
        // A cold drain runs BEFORE listen('coco2://package-open-request') has
        // resolved. If it sets ready=true, native app.emit() can acknowledge
        // a later Explorer delivery although no JS listener exists yet.
        // Synthetic queue only: no files, browser, HKCU or Windows app needed.
        let _exclusive=exclusive_pending_queue();
        {
            let mut s=state().lock().unwrap();
            s.items.clear();s.recent.clear();s.ready=false;
            s.items.push_back(PackageOpenRequest{
                path:r"C:\Test\first.coco2pack".into(),source:"cold"
            });
        }
        assert_eq!(take_pending_package_open_requests().len(),1);
        let pre_listener_ready=state().lock().unwrap().ready;
        {
            let mut s=state().lock().unwrap();
            s.items.clear();s.recent.clear();s.ready=false;
        }
        assert!(!pre_listener_ready,
            "a native drain without a subscribed JS event handler must not enable lossy warm emits");
    }
    #[test]
    fn v30_completed_review_allows_immediate_reopen_without_dropping_new_native_suffix(){
        let mut s=State::default();
        let first=PackageOpenRequest{path:r"C:\Synthetic\Friend 漢字.coco2pack".into(),source:"warm"};
        let now=Instant::now();
        select_requests(&mut s,vec![first.clone()],now,false).unwrap();
        assert_eq!(s.items.pop_front(),Some(first.clone()),"frontend ACK is explicit");
        // Two WM_COPYDATA sends without an intervening human review count as
        // the same delivery. Completion of the review changes that contract.
        select_requests(&mut s,vec![first.clone()],now,false).unwrap();
        assert!(s.items.is_empty(),"transient duplicate must stay suppressed");
        assert!(release_review_replay(&mut s,&first.path));
        select_requests(&mut s,vec![first.clone()],now,false).unwrap();
        assert_eq!(s.items.front(),Some(&first),"new explicit double click must re-open review");
        assert!(!release_review_replay(&mut s,&first.path),
            "a new queued activation is never invalidated by an old dismissal callback");
        assert_eq!(s.items.len(),1);
    }
    #[test]
    fn v27_native_peek_receipt_acks_only_matching_fifo_prefix_and_retains_suffix(){
        // Native receives two requests while React is still mounting. A peek
        // must never consume either: React might unmount before that IPC
        // resolves. A stale, reordered or overlong receipt must fail closed.
        // No filesystem, installed app, registry or external network.
        let _exclusive=exclusive_pending_queue();
        let a=PackageOpenRequest{path:r"C:\Tests\Amigo 漢字.coco2pack".into(),source:"cold"};
        let b=PackageOpenRequest{path:r"C:\Tests\Amigo 💜.coco2pack".into(),source:"warm"};
        {
            let mut s=state().lock().unwrap();
            s.items.clear();s.recent.clear();s.ready=false;
            s.items.push_back(a.clone());s.items.push_back(b.clone());
        }
        assert!(has_pending_package_open_requests());
        assert_eq!(peek_pending_package_open_requests(),vec![a.clone(),b.clone()]);
        assert_eq!(peek_pending_package_open_requests(),vec![a.clone(),b.clone()]);
        assert!(!acknowledge_pending_package_open_requests(vec![b.path.clone()]));
        assert!(!acknowledge_pending_package_open_requests(vec![a.path.clone(),"foreign".into()]));
        assert_eq!(peek_pending_package_open_requests().len(),2);
        assert!(acknowledge_pending_package_open_requests(vec![a.path.clone()]));
        assert_eq!(peek_pending_package_open_requests(),vec![b.clone()]);
        assert!(has_pending_package_open_requests());
        assert!(acknowledge_pending_package_open_requests(vec![b.path]));
        assert!(!has_pending_package_open_requests());
        assert!(peek_pending_package_open_requests().is_empty());
    }
    #[test]
    fn v27_updater_arming_and_authenticated_queue_are_atomic_and_reversible(){
        let _exclusive=exclusive_pending_queue();
        {
            let mut s=state().lock().unwrap();
            s.items.clear();s.recent.clear();s.ready=false;
        }
        APP_UPDATE_INSTALL_ARMED.store(false,Ordering::Release);
        let item=PackageOpenRequest{path:r"C:\Synthetic\Warm 漢字.coco2pack".into(),source:"warm"};
        // Restart wins first: a sender gets a negative handoff receipt, never
        // a false positive followed by loss during NSIS's process exit.
        assert!(try_arm_app_update_install());
        assert!(!try_arm_app_update_install());
        assert!(has_pending_package_open_requests());
        assert!(queue(vec![item.clone()]).is_err());
        assert!(peek_pending_package_open_requests().is_empty());
        assert!(finish_app_update_install_guard());
        assert!(!finish_app_update_install_guard());
        // Sender wins first: the updater cannot arm until React ACKs the FIFO.
        queue(vec![item.clone()]).unwrap();
        assert!(!try_arm_app_update_install());
        assert_eq!(peek_pending_package_open_requests(),vec![item.clone()]);
        assert!(acknowledge_pending_package_open_requests(vec![item.path]));
        assert!(try_arm_app_update_install());
        assert!(finish_app_update_install_guard());
        assert!(!has_pending_package_open_requests());
        state().lock().unwrap().recent.clear();
    }
    #[test]
    fn replay_burst_cancellation_and_capacity_are_bounded_and_atomic(){
        let mut state=State::default();
        let begin=Instant::now();
        let a=PackageOpenRequest{path:"C:\\Synthetic\\漢字 name.coco2pack".into(),source:"warm"};
        assert!(select_requests(&mut state,vec![a.clone()],begin,false).unwrap().is_empty());
        assert_eq!(state.items.len(),1);
        // A burst of repeated Explorer invokes must neither grow memory nor
        // send duplicate events. No Win32 or disk/network I/O involved.
        let started=Instant::now();
        for _ in 0..2_500{
            assert!(select_requests(&mut state,vec![a.clone()],begin,false).unwrap().is_empty());
        }
        assert!(started.elapsed()<Duration::from_secs(3),"Replay loop unexpectedly hot");
        assert_eq!(state.items.len(),1);
        assert_eq!(state.recent.len(),1);
        assert!(cancel_in_state(&mut state,&a.path));
        assert!(!cancel_in_state(&mut state,&a.path));
        assert!(state.items.is_empty());
        assert!(state.recent.is_empty());
        assert!(select_requests(&mut state,vec![a.clone()],begin,false).unwrap().is_empty());
        assert_eq!(state.items.len(),1,"Cancelled path can reopen immediately");
        state.items.clear(); // Simulate take_pending after UI is ready.
        assert!(select_requests(&mut state,vec![a.clone()],begin,true).unwrap().is_empty());
        let later=begin+REPLAY_WINDOW+Duration::from_millis(1);
        assert_eq!(select_requests(&mut state,vec![a],later,true).unwrap().len(),1);
        assert!(state.items.is_empty(),"Successful UI events do not enter pending queue");

        state.items=(0..MAX_PENDING-1).map(|i|PackageOpenRequest{
            path:format!("C:\\Synthetic\\valid{i}.coco2pack"),source:"cold"
        }).collect();
        let prior=state.items.len();let recent=state.recent.len();
        let result=select_requests(&mut state,vec![
            PackageOpenRequest{path:"C:\\Synthetic\\nextA.coco2pack".into(),source:"warm"},
            PackageOpenRequest{path:"C:\\Synthetic\\nextB.coco2pack".into(),source:"warm"},
        ],later,true);
        assert!(result.is_err(),"Over-capacity batches must fail as one transaction");
        assert_eq!(state.items.len(),prior);
        assert_eq!(state.recent.len(),recent);

        // The UI is ready, so each accepted path is emitted directly and the
        // pending backlog remains empty. The recent-path ledger must STILL
        // enforce the limit; previously it could grow for every new path.
        state.items.clear();
        state.recent.clear();
        for i in 0..MAX_PENDING{
            let item=PackageOpenRequest{
                path:format!("C:\\Synthetic\\UI event {i} 漢字.coco2pack"),source:"warm"
            };
            assert_eq!(select_requests(&mut state,vec![item],later,true).unwrap().len(),1);
        }
        assert!(state.items.is_empty());
        assert_eq!(state.recent.len(),MAX_PENDING);
        let rejected=PackageOpenRequest{
            path:"C:\\Synthetic\\UI event overflow.coco2pack".into(),source:"warm"
        };
        assert!(select_requests(&mut state,vec![rejected.clone()],later,true).is_err());
        assert_eq!(state.recent.len(),MAX_PENDING,
            "Rejected UI-ready events must not allocate additional replay entries");
        assert!(state.items.is_empty());
        // The bounded replay ledger expires normally, without permanently
        // preventing new user-initiated opens after the suppression window.
        let expired=later+REPLAY_WINDOW+Duration::from_millis(1);
        assert_eq!(select_requests(&mut state,vec![rejected],expired,true).unwrap().len(),1);
        assert_eq!(state.recent.len(),1);
    }
    #[test]
    fn first_install_96th_unique_package_fits_exactly_but_97th_is_rejected(){
        // Explorer may queue 96 requested files while WebView starts. The
        // documented bound is inclusive: entry #96 must not be silently lost.
        let make=|i:usize|PackageOpenRequest{
            path:format!("C:\\Synthetic\\Primer arranque {i:03} 漢字.coco2pack"),
            source:"warm",
        };
        let mut state=State::default();
        let now=Instant::now();
        for i in 0..95 {
            assert!(select_requests(&mut state,vec![make(i)],now,false).unwrap().is_empty());
        }
        assert_eq!(state.items.len(),95);
        assert_eq!(state.recent.len(),95);
        assert!(select_requests(&mut state,vec![make(95)],now,false).is_ok(),
            "96th unique Explorer activation must fit the advertised 96-slot FIFO");
        assert_eq!(state.items.len(),96);
        assert_eq!(state.recent.len(),96);
        assert!(select_requests(&mut state,vec![make(96)],now,false).is_err());
        assert_eq!(state.items.len(),96);
        let drained=state.items.drain(..).collect::<Vec<_>>();
        for (index,request) in drained.iter().enumerate(){
            assert_eq!(*request,make(index));
        }
    }
    #[test]
    fn failed_ui_emit_returns_error_and_recovers_fifo_before_new_warm_requests(){
        // No AppHandle/GUI is required to exercise the same selection and
        // dispatch functions used by the authenticated Win32 receiver.
        let pending=Mutex::new(State::default());
        let now=Instant::now();
        let mk=|label:&str|PackageOpenRequest{
            path:format!("C:\\Synthetic\\{label} 漢字.coco2pack"),source:"warm",
        };
        let (a,b,c,d)=(mk("a"),mk("b"),mk("c"),mk("d"));
        let first={
            let mut current=pending.lock().unwrap();
            select_with_backlog(&mut current,vec![a.clone(),b.clone(),c.clone()],now,true).unwrap()
        };
        let mut attempted=Vec::new();
        let failed=deliver_with_fallback(&pending,first,|item|{
            attempted.push(item.path.clone());
            if item.path==b.path{Err("synthetic missing JS listener".into())}else{Ok(())}
        });
        assert!(failed.is_err(),"a failed Tauri emit must not ACK warm handoff");
        assert_eq!(attempted,vec![a.path.clone(),b.path.clone()]);
        {
            let current=pending.lock().unwrap();
            assert_eq!(current.items.iter().map(|p|p.path.as_str()).collect::<Vec<_>>(),
                vec![b.path.as_str(),c.path.as_str()],
                "failed event and suffix must survive without replaying emitted prefix");
        }
        // Browser reload or another warm handoff replays the backlog first.
        let recovered={
            let mut current=pending.lock().unwrap();
            select_with_backlog(&mut current,vec![b.clone(),d.clone()],now,true).unwrap()
        };
        assert_eq!(recovered,vec![b.clone(),c.clone(),d.clone()],
            "duplicate warm retry cannot overtake an older undelivered event");
        let mut delivered=Vec::new();
        deliver_with_fallback(&pending,recovered,|item|{
            delivered.push(item.path.clone());Ok(())
        }).unwrap();
        assert_eq!(delivered,vec![b.path,c.path,d.path]);
        assert!(pending.lock().unwrap().items.is_empty());
    }
    #[cfg(windows)]
    #[test]
    fn v21_failed_ui_emit_racing_native_drain_never_strands_pending_fifo(){
        // The frontend can call take_pending while a warm IPC delivery is
        // attempting an event. The event fails, but its failed item + suffix
        // must be recoverable in that SAME drain, not require another focus or
        // Explorer launch. All I/O is synthetic TEMP; no Tauri window needed.
        let _exclusive=exclusive_pending_queue();
        let dir=root();
        let older=dir.join("Primero Unicode 漢字.coco2pack");
        let newer=dir.join("Segundo 💜.coco2pack.zip");
        for path in [&older,&newer]{std::fs::write(path,b"path-only synthetic test").unwrap();}
        let a=parse([older.into_os_string()],"cold").unwrap().remove(0);
        let b=parse([newer.into_os_string()],"warm").unwrap().remove(0);
        {
            let mut pending=state().lock().unwrap();
            pending.items.clear();pending.recent.clear();pending.ready=false;
            pending.items.push_back(a.clone());
        }
        let (emitting_tx,emitting_rx)=std::sync::mpsc::channel();
        let (release_tx,release_rx)=std::sync::mpsc::channel();
        let sender=std::thread::spawn(move||{
            let _ordered=delivery().lock().unwrap();
            let outbound={
                let mut pending=state().lock().unwrap();
                select_with_backlog(&mut pending,vec![b],Instant::now(),true).unwrap()
            };
            deliver_with_fallback(state(),outbound,|_item|{
                emitting_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(3)).unwrap();
                Err("synthetic missing UI listener".into())
            })
        });
        emitting_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let (reading_tx,reading_rx)=std::sync::mpsc::channel();
        let receiver=std::thread::spawn(move||{
            reading_tx.send(()).unwrap();
            take_pending_package_open_requests()
        });
        reading_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        // Force the read to race while the delivery lock is held and the
        // original FIFO has been removed from State for event dispatch.
        std::thread::sleep(Duration::from_millis(75));
        release_tx.send(()).unwrap();
        assert!(sender.join().unwrap().is_err());
        let recovered=receiver.join().unwrap();
        {
            let mut pending=state().lock().unwrap();
            pending.items.clear();pending.recent.clear();pending.ready=false;
        }
        std::fs::remove_dir_all(dir).unwrap();
        assert_eq!(recovered.len(),2,
            "a simultaneous native drain must recover the failed event and its FIFO suffix");
        assert_eq!(recovered[0],a);
        assert!(recovered[1].path.contains("Segundo 💜"));
    }
    #[cfg(windows)]
    #[test]
    fn authenticated_capability_is_single_use_and_wrong_pid_is_rejected(){
        let pid=std::process::id();
        let token=windows_impl::capability_for_test(pid).unwrap();
        assert!(!windows_impl::consume_capability_for_test(&token,pid.wrapping_add(1)));
        assert!(windows_impl::consume_capability_for_test(&token,pid),
            "wrong PID must not destroy the legitimate sender's token");
        assert!(!windows_impl::consume_capability_for_test(&token,pid),
            "the legitimate sender cannot replay its consumed capability");
        let valid=windows_impl::capability_for_test(pid).unwrap();
        assert!(windows_impl::consume_capability_for_test(&valid,pid));
        assert!(!windows_impl::consume_capability_for_test(&valid,pid));
    }
    #[cfg(windows)]
    #[test]
    fn orphaned_pipe_capabilities_do_not_block_healthy_first_install_handoff(){
        let _exclusive=exclusive_pending_queue();
        // Model 96 already-acknowledged Explorer helpers that exit before
        // WM_COPYDATA. PID zero is never a live process; the auth ledger must
        // reclaim their slots rather than blocking a healthy sender for 10s.
        for _ in 0..MAX_PENDING {
            windows_impl::capability_for_test(0).unwrap();
        }
        let pid=std::process::id();
        let valid=windows_impl::capability_for_test(pid)
            .expect("dead Explorer children exhausted live authentication capacity");
        assert!(windows_impl::consume_capability_for_test(&valid,pid));
        assert_eq!(windows_impl::outstanding_capabilities_for_test(),0);
    }
    #[cfg(windows)]
    #[test]
    fn native_explorer_v15_delayed_first_install_handoff_without_gui(){
        const ENABLE:&str="COCO2_EXPLORER_FIRST_INSTALL_V15";
        const CHILD:&str="COCO2_EXPLORER_FIRST_INSTALL_CHILD";
        const CHANNEL:&str="COCO2_EXPLORER_FIRST_INSTALL_CHANNEL";
        const COLD:&str="COCO2_EXPLORER_FIRST_INSTALL_COLD";
        const WARM:&str="COCO2_EXPLORER_FIRST_INSTALL_WARM";
        const THIRD:&str="COCO2_EXPLORER_FIRST_INSTALL_THIRD";
        const NAME:&str="services::activation::tests::native_explorer_v15_delayed_first_install_handoff_without_gui";
        if std::env::var(ENABLE).as_deref()!=Ok("1"){return;}
        if let Ok(mode)=std::env::var(CHILD){
            let channel=std::env::var(CHANNEL).expect("Missing isolated test channel");
            let warm=std::env::var_os(WARM).expect("Missing synthetic warm package");
            let third=std::env::var_os(THIRD).expect("Missing synthetic third package");
            match mode.as_str(){
                "abort-no-ack"=>windows_impl::unacknowledged_pipe_client_for_test(&channel).unwrap(),
                "abort-after-token"=>windows_impl::abandoned_pipe_client_for_test(&channel,true).unwrap(),
                "reject-unc"=>assert!(windows_impl::start_isolated_for_test(&channel,
                    vec![OsString::from(r"\\forged-server\share\bad.coco2pack")]).is_err()),
                "warm-after-shutdown"=>assert!(windows_impl::start_isolated_for_test(&channel,
                    vec![warm]).is_err()),
                _=>{
                    let inputs=match mode.as_str(){
                        "warm-first"=>vec![warm],
                        "warm-repeat"=>vec![warm.clone(),warm],
                        "warm-third"=>vec![third],
                        _=>panic!("Unsupported synthetic first-install mode"),
                    };
                    assert_eq!(windows_impl::start_isolated_for_test(&channel,inputs).unwrap(),false,
                        "a trusted second invocation must hand off without starting another UI");
                }
            }
            println!("COCO2_EXPLORER_FIRST_INSTALL_CHILD_OK mode={mode} pid={}",std::process::id());
            return;
        }
        use std::process::{Command,Stdio};
        let _exclusive=exclusive_pending_queue();
        let dir=root();
        let cold=dir.join("Primer inicio 🎮 漢字.coco2pack");
        let warm=dir.join("Nuevo archivo 💜 Unicode.coco2pack");
        let third=dir.join("Último archivo Áé.coco2pack.zip");
        for file in [&cold,&warm,&third] {
            std::fs::write(file,b"synthetic path-only; no import or execution").unwrap();
        }
        let channel=format!("{}{}",std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos());
        // First-install antivirus inspection can delay the authentication
        // listener AFTER the primary's mutex is already visible to Explorer.
        windows_impl::delay_primary_listener_for_test(2_400);
        let cold_copy=cold.clone();
        let channel_copy=channel.clone();
        let primary=std::thread::spawn(move||windows_impl::start_isolated_for_test(
            &channel_copy,vec![cold_copy.into_os_string()]));
        let primary_deadline=Instant::now()+Duration::from_secs(2);
        while !windows_impl::primary_mutex_created_for_test(){
            assert!(Instant::now()<primary_deadline,"synthetic cold mutex never appeared");
            std::thread::sleep(Duration::from_millis(10));
        }
        let mut child_pids=Vec::new();
        let mut invoke=|mode:&str|{
            let mut child=Command::new(std::env::current_exe().unwrap())
                .args(["--exact",NAME,"--nocapture"])
                .env(ENABLE,"1").env(CHILD,mode).env(CHANNEL,&channel)
                .env(COLD,&cold).env(WARM,&warm).env(THIRD,&third)
                .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped())
                .spawn().unwrap();
            let pid=child.id();
            println!("COCO2_EXPLORER_FIRST_INSTALL_SPAWN mode={mode} pid={pid}");
            let deadline=Instant::now()+Duration::from_secs(11);
            let status=loop{
                if let Some(status)=child.try_wait().unwrap(){break status;}
                if Instant::now()>deadline{
                    let _=child.kill();let _=child.wait();
                    panic!("Test-owned Explorer helper {mode} timed out");
                }
                std::thread::sleep(Duration::from_millis(25));
            };
            let output=child.wait_with_output().unwrap();
            assert!(status.success(),"Test-owned {mode} PID {pid} failed: {}",
                String::from_utf8_lossy(&output.stderr));
            assert!(String::from_utf8_lossy(&output.stdout).contains("COCO2_EXPLORER_FIRST_INSTALL_CHILD_OK"));
            child_pids.push(pid);
        };
        // Red before fix: 32 short retries expire before the deliberately
        // delayed primary exposes its authenticated pipe to the first warm EXE.
        invoke("warm-first");
        assert!(primary.join().unwrap().unwrap(),"cold instance must be primary");
        windows_impl::delay_primary_listener_for_test(0);
        invoke("abort-no-ack");
        invoke("abort-after-token");
        invoke("warm-repeat");
        assert_eq!(windows_impl::outstanding_capabilities_for_test(),0,
            "actual exited Explorer helper left an authenticated capability after new handoff");
        invoke("warm-third");
        invoke("reject-unc");
        let delivered=take_pending_package_open_requests();
        assert_eq!(delivered.len(),3,"cold + one warm + third; retries must dedupe");
        assert_eq!(delivered[0].source,"cold");
        assert!(delivered[0].path.contains("Primer inicio"));
        assert_eq!(delivered[1].source,"warm");
        assert!(delivered[1].path.contains("Nuevo archivo"));
        assert!(delivered[2].path.contains("Último archivo"));
        assert!(take_pending_package_open_requests().is_empty());
        shutdown_activation().unwrap();
        assert_eq!(windows_impl::listeners_count_for_test(),0);
        invoke("warm-after-shutdown");
        assert_eq!(child_pids.len(),7);
        println!("COCO2_EXPLORER_FIRST_INSTALL_PASS children=7 cold=1 warm=2 replay=0 expired_ack=1 untrusted=1 shutdown=1 no_gui=1");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn actual_windows_message_only_sender_receiver_delivers_without_shell(){
        let _exclusive=exclusive_pending_queue();
        let dir=root();
        let file=dir.join("warm 漢字 💜.coco2pack.zip");
        std::fs::write(&file,b"raw untrusted data never opened").unwrap();
        let request=parse([file.into_os_string()],"warm").unwrap().remove(0);
        let delivered=windows_impl::synthetic_native_handoff_for_test(request.clone()).unwrap();
        assert!(delivered.iter().any(|entry|entry.path==request.path&&entry.source=="warm"));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn native_pipe_capability_waits_for_server_ack_under_delayed_receipt(){
        let _exclusive=exclusive_pending_queue();
        let (elapsed,remaining)=windows_impl::delayed_ack_contract_for_test().unwrap();
        assert!(elapsed>=200,"Client returned a usable IPC capability after {elapsed} ms before the server processed its ACK");
        assert_eq!(remaining,0);
    }
    #[cfg(windows)]
    #[test]
    fn native_activation_surge_v12_cross_process_no_gui(){
        const ENABLE:&str="COCO2_ACTIVATION_SURGE_V12";
        const CHANNEL:&str="COCO2_ACTIVATION_SURGE_V12_CHANNEL";
        const CHILD:&str="COCO2_ACTIVATION_SURGE_V12_CHILD";
        const PATH:&str="COCO2_ACTIVATION_SURGE_V12_PATH";
        const NAME:&str="services::activation::tests::native_activation_surge_v12_cross_process_no_gui";
        if std::env::var(ENABLE).as_deref()!=Ok("1"){return;}
        if std::env::var_os(CHILD).is_some(){
            let channel=std::env::var_os(CHANNEL).expect("synthetic channel absent");
            let file=std::env::var_os(PATH).expect("synthetic input path absent");
            assert!(!windows_impl::start_isolated_for_test(
                &channel.to_string_lossy(),vec![file]).unwrap(),
                "concurrent sender must never open a second GUI");
            return;
        }
        use std::process::{Command,Stdio};
        let _exclusive=exclusive_pending_queue();
        let dir=root();
        let nested=dir.join("ruta con espacios 漢字").join("subdirectorio 12345678901234567890")
            .join("más niveles 💜 12345678901234567890")
            .join("nivel largo 01234567890123456789012345678901234567890123456789")
            .join("otro nivel 01234567890123456789012345678901234567890123456789");
        std::fs::create_dir_all(&nested).unwrap();
        let files=(0..12).map(|i|{
            let file=nested.join(format!("surge {i:02} 路徑💜.coco2pack"));
            std::fs::write(&file,b"test-owned non ZIP; never imported").unwrap();
            file
        }).collect::<Vec<_>>();
        assert!(files.iter().all(|p|p.as_os_str().to_string_lossy().encode_utf16().count()>260),
            "Win32 E2E must exercise Unicode paths beyond the traditional MAX_PATH");
        let id=format!("{}{}",std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos());
        assert!(windows_impl::start_isolated_for_test(&id,Vec::new()).unwrap());
        let expected=files.iter().map(|p|checked_path(&p.clone().into_os_string()).unwrap())
            .collect::<std::collections::HashSet<_>>();
        // Force sustained overlap while 12 actual, authenticated test EXEs
        // contend for the single-instance named pipe.
        windows_impl::set_server_ack_delay_for_test(35);
        struct OwnedChildren(Vec<std::process::Child>);
        impl Drop for OwnedChildren{
            fn drop(&mut self){
                for child in &mut self.0{
                    if child.try_wait().ok().flatten().is_none(){
                        let _=child.kill();let _=child.wait();
                    }
                }
            }
        }
        let mut children=OwnedChildren(Vec::new());
        for file in &files{
            let child=Command::new(std::env::current_exe().unwrap())
                .args(["--exact",NAME])
                .env(ENABLE,"1").env(CHANNEL,&id).env(CHILD,"warm").env(PATH,file)
                .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
                .spawn().unwrap();
            println!("COCO2_ACTIVATION_SURGE_SPAWN pid={}",child.id());
            children.0.push(child);
        }
        let deadline=Instant::now()+Duration::from_secs(18);
        let mut failures=Vec::new();
        // Reap every exact test-owned process, including on timeout/failure.
        for child in &mut children.0{
            loop{
                if let Some(status)=child.try_wait().unwrap(){
                    if !status.success(){failures.push(child.id());}
                    break;
                }
                if Instant::now()>=deadline{
                    failures.push(child.id());
                    let _=child.kill();let _=child.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        windows_impl::set_server_ack_delay_for_test(0);
        assert!(failures.is_empty(),"Synthetic activation senders failed: {failures:?}");
        let received=take_pending_package_open_requests();
        assert_eq!(received.len(),12,"all twelve authenticated activations must survive contention");
        let observed=received.iter().map(|x|x.path.clone())
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(observed,expected,"surge lost or duplicated Unicode paths");
        assert!(received.iter().all(|x|x.source=="warm"));
        assert!(take_pending_package_open_requests().is_empty());
        shutdown_activation().unwrap();
        assert_eq!(windows_impl::listeners_count_for_test(),0);
        println!("COCO2_ACTIVATION_SURGE_PASS count=12 distinct=12 closed=1 no_gui=1");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn native_explorer_v13_long_duplicate_fifo_cancel_shutdown(){
        const ENABLE:&str="COCO2_EXPLORER_V13_E2E";
        const CHANNEL:&str="COCO2_EXPLORER_V13_CHANNEL";
        const MODE:&str="COCO2_EXPLORER_V13_MODE";
        const FIRST:&str="COCO2_EXPLORER_V13_FIRST";
        const SECOND:&str="COCO2_EXPLORER_V13_SECOND";
        const THIRD:&str="COCO2_EXPLORER_V13_THIRD";
        const NAME:&str="services::activation::tests::native_explorer_v13_long_duplicate_fifo_cancel_shutdown";
        if std::env::var(ENABLE).as_deref()!=Ok("1"){return;}
        if let Ok(mode)=std::env::var(MODE){
            let channel=std::env::var(CHANNEL).expect("isolated channel absent");
            let first=std::env::var_os(FIRST).expect("synthetic first path absent");
            let second=std::env::var_os(SECOND).expect("synthetic second path absent");
            let third=std::env::var_os(THIRD).expect("synthetic third path absent");
            let args=match mode.as_str(){
                "warm-repeated-long"=>vec![second;MAX_REQUESTS],
                "warm-third"=>vec![third],
                "warm-no-files"=>Vec::new(),
                "reject-unc"=>vec![OsString::from(r"\\untrusted\share\fake.coco2pack")],
                "reject-relative"=>vec![OsString::from("fake.coco2pack")],
                "reject-unknown"=>vec![OsString::from("fake.zip")],
                "reject-missing"=>vec![Path::new(&first).parent().unwrap()
                    .join("absent.coco2pack").into_os_string()],
                "warm-after-shutdown"=>vec![second],
                other=>panic!("unsupported synthetic child mode: {other}"),
            };
            let result=windows_impl::start_isolated_for_test(&channel,args);
            if mode.starts_with("reject-")||mode=="warm-after-shutdown"{
                assert!(result.is_err(),"untrusted or closed Explorer handoff must fail closed");
            } else {
                assert_eq!(result.unwrap(),false,"only the test primary may start a listener");
            }
            println!("COCO2_EXPLORER_V13_CHILD_OK mode={mode} pid={}",std::process::id());
            return;
        }
        use std::process::{Command,Stdio};
        let _exclusive=exclusive_pending_queue();
        let dir=root();
        let first=dir.join("Frío 漢字.coco2pack");
        let third=dir.join("Tercero 💜.coco2pack.zip");
        std::fs::write(&first,b"test-only untrusted bytes").unwrap();
        std::fs::write(&third,b"test-only untrusted bytes").unwrap();
        let mut nested=dir.clone();
        for i in 0..29 {
            nested=nested.join(format!("Nivel {i:02} 漢字{}", "x".repeat(95)));
            std::fs::create_dir(&nested).unwrap();
        }
        let second=nested.join("Largo 💜.coco2pack");
        std::fs::write(&second,b"test-only untrusted bytes").unwrap();
        assert!(checked_path(&second.clone().into_os_string()).unwrap()
            .encode_utf16().count()>MAX_PAYLOAD/(MAX_REQUESTS*2));
        // A link under our temporary fixture is rejected when Windows grants
        // test process symlink privileges. Never create an OS-wide junction.
        let link=dir.join("untrusted-link.coco2pack");
        let symlink_checked=match std::os::windows::fs::symlink_file(&first,&link){
            Ok(())=>{
                assert!(parse([link.into_os_string()],"cold").is_err());
                true
            },
            Err(_)=>false,
        };
        let id=format!("{}{}",std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos());
        assert!(windows_impl::start_isolated_for_test(
            &id,vec![first.clone().into_os_string()]).unwrap());
        let mut child_pids=Vec::new();
        let mut spawn_test=|mode:&str|{
            let mut child=Command::new(std::env::current_exe().unwrap())
                .args(["--exact",NAME,"--nocapture"])
                .env(ENABLE,"1").env(CHANNEL,&id).env(MODE,mode)
                .env(FIRST,&first).env(SECOND,&second).env(THIRD,&third)
                .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped())
                .spawn().unwrap();
            let pid=child.id();
            println!("COCO2_EXPLORER_V13_SPAWN pid={pid} mode={mode}");
            // A synthetic primary that calls shutdown_activation() but stays
            // alive still owns the Windows single-instance mutex. Its pipe is
            // intentionally absent, so the last sender must exhaust the full
            // nine-second cold-start allowance before failing closed. Give
            // that negative scenario a separate test watchdog margin instead
            // of racing a nine-second child timeout against its own deadline.
            let deadline=Instant::now()+if mode=="warm-after-shutdown"{
                Duration::from_secs(12)
            }else{Duration::from_secs(9)};
            let status=loop{
                if let Some(status)=child.try_wait().unwrap(){break status;}
                if Instant::now()>deadline{
                    let _=child.kill();let _=child.wait();
                    panic!("synthetic Explorer child timed out: {mode} pid={pid}");
                }
                std::thread::sleep(Duration::from_millis(25));
            };
            let output=child.wait_with_output().unwrap();
            assert!(status.success(),"child {mode} failed: {}",String::from_utf8_lossy(&output.stderr));
            assert!(String::from_utf8_lossy(&output.stdout).contains("COCO2_EXPLORER_V13_CHILD_OK"));
            child_pids.push(pid);
        };
        for mode in ["reject-unc","reject-relative","reject-unknown","reject-missing",
            "warm-repeated-long","warm-repeated-long","warm-third","warm-no-files"] {
            spawn_test(mode);
        }
        let canonical_second=checked_path(&second.clone().into_os_string()).unwrap();
        assert!(cancel_pending_package_open_request(canonical_second.clone()));
        assert!(!cancel_pending_package_open_request(canonical_second));
        spawn_test("warm-repeated-long");
        let items=take_pending_package_open_requests();
        assert_eq!(items.len(),3,"cold + one deduped long warm + third must be delivered once");
        assert_eq!(items[0].source,"cold");
        assert_eq!(items[1].source,"warm");
        assert_eq!(items[2].source,"warm");
        assert_eq!(items[0].path,checked_path(&first.clone().into_os_string()).unwrap());
        assert_eq!(items[1].path,checked_path(&third.clone().into_os_string()).unwrap(),
            "FIFO must retain third while cancelled long package is reopened at tail");
        assert_eq!(items[2].path,checked_path(&second.clone().into_os_string()).unwrap());
        assert!(take_pending_package_open_requests().is_empty());
        shutdown_activation().unwrap();
        assert_eq!(windows_impl::listeners_count_for_test(),0);
        spawn_test("warm-after-shutdown");
        assert_eq!(std::fs::read(&second).unwrap(),b"test-only untrusted bytes");
        assert_eq!(child_pids.len(),10);
        println!("COCO2_EXPLORER_V13_PASS children={} cold=1 warm=2 dedup24=1 fifo=1 cancel=1 closed=1 symlink_checked={} no_gui=1",
            child_pids.len(),u8::from(symlink_checked));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn actual_two_win32_processes_authenticate_and_deliver_unicode_path(){
        // The same test binary is used as the authenticated *second* process.
        // Unlike the in-process HWND test, Windows supplies real distinct PIDs
        // to the named-pipe server. No Tauri GUI, ZeroTier or user profile data
        // are opened or modified by either process.
        const CHILD:&str="COCO2_ACTIVATION_IPC_TEST_CHILD";
        const FILE:&str="COCO2_ACTIVATION_IPC_TEST_FILE";
        if let Some(channel)=std::env::var_os(CHILD){
            let file=PathBuf::from(std::env::var_os(FILE).expect("test file missing"));
            windows_impl::cross_process_sender_for_test(&channel.to_string_lossy(),&file).unwrap();
            return;
        }
        let _exclusive=exclusive_pending_queue();
        use std::process::{Command,Stdio};
        use std::time::{Duration,Instant};
        let dir=root();
        let file=dir.join("Instalación compartida 漢字 💜.coco2pack");
        std::fs::write(&file,b"untrusted zip never inspected by IPC").unwrap();
        let channel=format!("{}{}",std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos());
        windows_impl::cross_process_receiver_for_test(&channel).unwrap();
        let mut child=Command::new(std::env::current_exe().unwrap())
            .args(["--exact","services::activation::tests::actual_two_win32_processes_authenticate_and_deliver_unicode_path"])
            .env(CHILD,&channel).env(FILE,&file)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap();
        let deadline=Instant::now()+Duration::from_secs(10);
        let status=loop{
            if let Some(status)=child.try_wait().unwrap(){break status;}
            if Instant::now()>deadline{
                let _=child.kill();let _=child.wait();
                panic!("Native two-process activation timed out");
            }
            std::thread::sleep(Duration::from_millis(25));
        };
        assert!(status.success(),"native second process refused authenticated handoff");
        let delivered=take_pending_package_open_requests();
        assert!(delivered.iter().any(|request|request.path.contains("漢字 💜")&&request.source=="warm"));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn isolated_real_cold_warm_single_instance_two_processes_no_gui(){
        // Explicitly opt-in from the Node E2E runner. Cargo's default tests
        // skip this test rather than create Windows activation processes in
        // a developer's interactive session.
        const ENABLE:&str="COCO2_ACTIVATION_REAL_E2E";
        const CHILD:&str="COCO2_ACTIVATION_REAL_E2E_CHILD";
        const CHANNEL:&str="COCO2_ACTIVATION_REAL_E2E_CHANNEL";
        const FIRST:&str="COCO2_ACTIVATION_REAL_E2E_FIRST";
        const SECOND:&str="COCO2_ACTIVATION_REAL_E2E_SECOND";
        const NAME:&str="services::activation::tests::isolated_real_cold_warm_single_instance_two_processes_no_gui";
        if std::env::var(ENABLE).as_deref()!=Ok("1"){return;}
        let channel=std::env::var(CHANNEL).unwrap_or_default();
        if let Ok(child_mode)=std::env::var(CHILD){
            if child_mode=="abort-no-ack"{
                windows_impl::unacknowledged_pipe_client_for_test(&channel).unwrap();
                println!("COCO2_ACTIVATION_E2E_CHILD_OK pid={} mode={child_mode}",
                    std::process::id());
                return;
            }
            if child_mode=="abort-auth-pipe"||child_mode=="abort-after-token" {
                windows_impl::abandoned_pipe_client_for_test(
                    &channel,child_mode=="abort-after-token",
                ).unwrap();
                println!("COCO2_ACTIVATION_E2E_CHILD_OK pid={} mode={child_mode}",
                    std::process::id());
                return;
            }
            let a=std::env::var_os(FIRST).expect("test first file not set");
            let b=std::env::var_os(SECOND).expect("test second file not set");
            let args=match child_mode.as_str(){
                "warm-burst"=>vec![b.clone(),a.clone(),b],
                "warm-repeated"=>vec![a],
                "warm-no-files"=>Vec::new(),
                "warm-reopen-b"=>vec![b],
                "warm-repeat-after-drain"=>vec![a],
                "warm-fifo-24"=>(0..MAX_REQUESTS).map(|index|{
                    Path::new(&a).parent().unwrap().join(format!("Entrega {index:02} 漢字.coco2pack"))
                        .into_os_string()
                }).collect(),
                "warm-after-shutdown"=>vec![b],
                "reject-unc"=>vec![OsString::from(r"\\untrusted-server\share\forged.coco2pack")],
                "reject-relative"=>vec![OsString::from("forged.coco2pack")],
                "reject-unknown"=>vec![OsString::from("--unrecognized")],
                _=>panic!("unsupported synthetic activation child mode"),
            };
            let result=windows_impl::start_isolated_for_test(&channel,args);
            if child_mode.starts_with("reject-")||child_mode=="warm-after-shutdown"{
                assert!(result.is_err(),"activation arguments must fail closed");
            }else{
                assert_eq!(result.unwrap(),false,
                    "warm invocation must hand off and NOT create a second app");
            }
            println!("COCO2_ACTIVATION_E2E_CHILD_OK pid={} mode={child_mode}",
                std::process::id());
            return;
        }
        use std::process::{Command,Stdio};
        use std::time::{Duration,Instant};
        let dir=root();
        let first=dir.join("Inicial 漢字 con espacios.coco2pack");
        let second=dir.join("Segunda 💜 Unicode.coco2pack.zip");
        std::fs::write(&first,b"synthetic only, not a game").unwrap();
        std::fs::write(&second,b"not a ZIP, must never be opened").unwrap();
        let id=format!("{}{}",std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos());
        assert!(windows_impl::start_isolated_for_test(
            &id,vec![first.as_os_str().to_os_string()]).unwrap(),
            "cold process must own the only synthetic mutex and receiver");
        let before=windows_impl::process_cpu_millis_for_test().unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let idle_cpu_ms=windows_impl::process_cpu_millis_for_test().unwrap()
            .saturating_sub(before);
        assert!(idle_cpu_ms<150,
            "Idle pipe/message listener consumed {idle_cpu_ms}ms CPU over 300ms wall time");
        println!("COCO2_ACTIVATION_E2E_START primary_pid={}",std::process::id());
        let mut children=Vec::new();
        let mut invoke=|mode:&str|{
            let mut child=Command::new(std::env::current_exe().unwrap())
                .args(["--exact",NAME,"--nocapture"])
                .env(ENABLE,"1").env(CHILD,mode).env(CHANNEL,&id)
                .env(FIRST,&first).env(SECOND,&second)
                .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped())
                .spawn().unwrap();
            let pid=child.id();
            println!("COCO2_ACTIVATION_E2E_SPAWN pid={pid} mode={mode}");
            assert_ne!(pid,std::process::id(),"warm activation must run in another PID");
            // Only the deliberately closed synthetic primary keeps its mutex
            // alive while removing the endpoint. The secondary must wait out
            // the full 9s bounded startup handshake and then reject; a 9s test
            // watchdog raced that legitimate timeout under Windows load.
            let deadline=Instant::now()+if mode=="warm-after-shutdown"{
                Duration::from_secs(12)
            }else{Duration::from_secs(9)};
            let status=loop{
                if let Some(status)=child.try_wait().unwrap(){break status;}
                if Instant::now()>deadline {
                    let _=child.kill();let _=child.wait();
                    panic!("synthetic warm activation process {pid} timed out");
                }
                std::thread::sleep(Duration::from_millis(25));
            };
            let output=child.wait_with_output().unwrap();
            assert!(status.success(),"warm child {mode} pid={pid} failed: {}",
                String::from_utf8_lossy(&output.stderr));
            assert!(String::from_utf8_lossy(&output.stdout).contains("COCO2_ACTIVATION_E2E_CHILD_OK"),
                "child test did not acknowledge the handoff: {mode}");
            children.push(pid);
        };
        for mode in [
            "reject-unc","reject-relative","reject-unknown",
            "abort-auth-pipe","abort-no-ack","abort-after-token",
            "warm-burst","warm-repeated","warm-no-files"
        ]{
            invoke(mode);
            if mode=="abort-no-ack" {
                // After a verified token transfer without client ACK, the
                // server must revoke that token instead of accumulating
                // one-time capabilities under repeated failed launches.
                let deadline=Instant::now()+Duration::from_millis(1500);
                while windows_impl::outstanding_capabilities_for_test()!=0
                    && Instant::now()<deadline {
                    std::thread::sleep(Duration::from_millis(20));
                }
                assert_eq!(windows_impl::outstanding_capabilities_for_test(),0,
                    "Aborted client left a usable, unacknowledged IPC capability");
            }
        }
        let canonical_second=checked_path(&second.as_os_str().to_os_string()).unwrap();
        assert!(cancel_pending_package_open_request(canonical_second.clone()),
            "User cancellation must withdraw still-pending warm package");
        assert!(!cancel_pending_package_open_request(canonical_second),
            "Cancellation is idempotent and does not affect other requests");
        invoke("warm-reopen-b");
        let delivered=take_pending_package_open_requests();
        assert_eq!(delivered.len(),2,
            "initial cold file plus warm ZIP must be queued exactly once each");
        assert_eq!(delivered[0].source,"cold");
        assert_eq!(delivered[1].source,"warm");
        assert!(delivered[0].path.contains("漢字 con espacios"));
        assert!(delivered[1].path.contains("💜 Unicode"));
        invoke("warm-repeat-after-drain");
        assert!(take_pending_package_open_requests().is_empty());
        // A real secondary process transmits the maximum 24 distinct paths
        // in a single authenticated Win32 handoff. They must survive into the
        // primary queue in their original Explorer argument order (no GUI).
        for index in 0..MAX_REQUESTS {
            std::fs::write(dir.join(format!("Entrega {index:02} 漢字.coco2pack")),
                b"synthetic FIFO path, never opened by activation").unwrap();
        }
        invoke("warm-fifo-24");
        let ordered=take_pending_package_open_requests();
        assert_eq!(ordered.len(),MAX_REQUESTS);
        for (index,item) in ordered.iter().enumerate() {
            assert_eq!(item.source,"warm");
            assert!(item.path.ends_with(&format!("Entrega {index:02} 漢字.coco2pack")),
                "cross-process delivery must preserve all 24 requests FIFO");
        }
        assert!(take_pending_package_open_requests().is_empty());
        assert_eq!(std::fs::read(&first).unwrap(),b"synthetic only, not a game");
        assert_eq!(std::fs::read(&second).unwrap(),b"not a ZIP, must never be opened");
        shutdown_activation().unwrap();
        assert_eq!(windows_impl::listeners_count_for_test(),0);
        assert!(take_pending_package_open_requests().is_empty());
        invoke("warm-after-shutdown");
        println!("COCO2_ACTIVATION_E2E_PASS primary_pid={} warm_pids={:?} cold=1 warm=1 rejected=3 aborted=3 replay=0 cancelled=1 reopened=1 fifo24=1 shutdown=1 idle_cpu_ms={idle_cpu_ms} no_gui=1",std::process::id(),children);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
