//! What a game needs right before it starts, carried over from Launcher 1: Online-Fix's
//! credit popup silenced through its ini, its public stats folder, Steam running for P2P,
//! and any remaining popup answered. All of it is best effort and never blocks playing.
use crate::services::catalog::Experience;
use serde::{Deserialize,Serialize};
use std::collections::{BTreeMap,HashMap,HashSet};
use std::fs;
use std::path::{Path,PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;

const FAKE_APP_ID:&str="480";
const WORMS_ID:&str="worms-wmd";
const REPO_ID:&str="repo";
const STEAM_WAIT_SECONDS:u32=60;

#[derive(Deserialize,Clone)]
#[serde(rename_all="camelCase")]
struct GameHashes{real_app_id:String,hash0:String,hash1337:String}

#[derive(Deserialize)]
struct OnlineFixTable{games:HashMap<String,GameHashes>,apps:HashMap<String,GameHashes>}

/// A game's hashes: the shipped table first, then what a signed catalog brought with it.
fn game_hashes(id:&str)->Option<GameHashes>{
    table().games.get(id).cloned().or_else(||crate::services::catalog::online_fix_extra(id)
        .map(|fix|GameHashes{real_app_id:fix.real_app_id,hash0:fix.hash0,hash1337:fix.hash1337}))
}

fn table()->&'static OnlineFixTable{
    static TABLE:OnceLock<OnlineFixTable>=OnceLock::new();
    TABLE.get_or_init(||serde_json::from_str(include_str!("../../resources/online-fix.json")).expect("embedded Online-Fix table"))
}

fn find_named(root:&Path,lower_name:&str)->Vec<PathBuf>{
    let mut found=Vec::new();
    let mut pending=vec![root.to_path_buf()];
    while let Some(dir)=pending.pop(){
        let Ok(entries)=fs::read_dir(&dir) else {continue};
        for entry in entries.flatten(){
            let Ok(metadata)=fs::symlink_metadata(entry.path()) else {continue};
            if crate::services::uninstall::is_link(&metadata){continue;}
            if metadata.is_dir(){pending.push(entry.path());}
            else if entry.file_name().to_string_lossy().eq_ignore_ascii_case(lower_name){found.push(entry.path());}
        }
    }
    found
}

fn real_app_id(content:&str)->Option<String>{
    content.lines().find_map(|line|{
        let (key,value)=line.split_once('=')?;
        if !key.trim().eq_ignore_ascii_case("RealAppId"){return None;}
        let value=value.trim();
        (!value.is_empty()&&value.bytes().all(|byte|byte.is_ascii_digit())).then(||value.to_string())
    })
}

fn existing_1337(content:&str)->Option<String>{
    content.lines().find_map(|line|{
        let (key,value)=line.split_once('=')?;
        let value=value.trim();
        (key.trim()=="1337"&&value.len()==128&&value.bytes().all(|byte|byte.is_ascii_hexdigit())).then(||value.to_string())
    })
}

fn default_ini(hashes:&GameHashes,photon:bool)->String{
    format!("[Main]\r\nRealAppId={}\r\nFakeAppId={FAKE_APP_ID}\r\n\r\n#Language=english\r\nBuildId=0\r\nInstallDir=\r\nUnlockAllDLC=false\r\n\r\n\r\n[Misc]\r\nExtraProtection=false\r\nPhotonIntegration={photon}\r\nEmulateTicket=false\r\n\r\n\r\n[Interfaces]\r\nApps=true\r\nUser=true\r\nUtils=true\r\nStorage=true\r\nUserStats=true\r\nFriends=true\r\nUGC=true\r\nInventory=true\r\nAppTicket=true\r\n\r\n\r\n[Hashes]\r\n0={}\r\n1337={}\r\n",
        hashes.real_app_id,hashes.hash0,hashes.hash1337)
}

/// The hash for this app id wins over the game's own: a pack may carry another game's ini.
fn with_hashes(content:&str,game:Option<&GameHashes>)->Option<String>{
    let content=content.trim_start_matches('\u{feff}');
    let hashes=real_app_id(content).and_then(|id|table().apps.get(&id)).or(game)?;
    let hash1337=if hashes.hash1337.is_empty(){existing_1337(content).unwrap_or_default()}else{hashes.hash1337.clone()};
    let block=if hash1337.is_empty(){format!("0={}\r\n",hashes.hash0)}else{format!("0={}\r\n1337={hash1337}\r\n",hashes.hash0)};
    let mut output=String::new();
    let (mut in_hashes,mut found)=(false,false);
    for line in content.lines(){
        let trimmed=line.trim();
        if trimmed.starts_with('[')&&trimmed.ends_with(']'){
            in_hashes=trimmed.eq_ignore_ascii_case("[Hashes]");
            if in_hashes {
                // Ambiguous duplicate sections are left untouched.
                if found {return None;}
                output.push_str("[Hashes]\r\n");output.push_str(&block);found=true;
                continue;
            }
        }
        if in_hashes && line.split_once('=').is_some_and(|(key,_)|matches!(key.trim(),"0"|"1337")) {continue;}
        output.push_str(line);output.push_str("\r\n");
    }
    if !found {if !output.is_empty()&&!output.ends_with("\r\n\r\n"){output.push_str("\r\n");}output.push_str("[Hashes]\r\n");output.push_str(&block);}
    Some(output)
}

/// Puts this PC's own value in the 1337 line of the [Hashes] section, keeping everything else.
fn set_1337(content:&str,value:&str)->String{
    let line=format!("1337={value}\r\n");
    let mut output=String::new();
    let (mut in_hashes,mut done)=(false,false);
    for current in content.trim_start_matches('\u{feff}').lines(){
        let trimmed=current.trim();
        if trimmed.starts_with('[')&&trimmed.ends_with(']'){
            if in_hashes&&!done{output.push_str(&line);done=true;}
            in_hashes=trimmed.eq_ignore_ascii_case("[Hashes]");
        }else if in_hashes&&current.split_once('=').is_some_and(|(key,_)|key.trim()=="1337"){
            if !done{output.push_str(&line);done=true;}
            continue;
        }
        output.push_str(current);output.push_str("\r\n");
    }
    if !done{
        if !in_hashes{if !output.is_empty()&&!output.ends_with("\r\n\r\n"){output.push_str("\r\n");}output.push_str("[Hashes]\r\n");}
        output.push_str(&line);
    }
    output
}

/// The 1337 hash Online-Fix writes after its popup is valid only on the PC that wrote it: the
/// host's does not silence a friend's game. Coco keeps the one written on this PC for each
/// game folder and restores it before every launch; the shared table is only a first guess.
const TRUST_FILE:&str="online-fix-trust.json";

#[derive(Serialize,Deserialize,Default,Clone,PartialEq,Debug)]
struct TrustedRoot{
    machine:String,
    hashes:BTreeMap<String,String>,
    /// The fix's own DLLs when this PC's hash was taken: an update that replaces them may expect
    /// another hash, so it earns a new first run.
    #[serde(default)]
    loaders:String,
}

/// The DLLs Online-Fix runs from. Their folder is where it reads and writes OnlineFix.ini.
const FIX_LOADERS:&[&str]=&["OnlineFix64.dll","OnlineFix.dll"];
/// Programs shipped next to a game that are not the game.
const NOT_THE_GAME:&[&str]=&["crashhandler","crashreport","crashpad","unins","setup","redist","dxwebsetup","vc_redist","easyanticheat_setup"];

/// Every folder where the fix runs, whatever the engine puts where: next to its DLL, or next to
/// an OnlineFix.ini (a loader built into another DLL still reads one beside it).
pub(crate) fn fix_dirs(root:&Path)->Vec<PathBuf>{
    let unique=|files:Vec<PathBuf>|{
        let mut dirs:Vec<PathBuf>=Vec::new();
        for file in files{
            let Some(dir)=file.parent() else {continue};
            if !dirs.iter().any(|known|known==dir){dirs.push(dir.to_path_buf());}
        }
        dirs
    };
    let loaders=unique(FIX_LOADERS.iter().flat_map(|name|find_named(root,&name.to_ascii_lowercase())).collect());
    // An ini alone only marks the fix when no fix DLL exists anywhere: an Unreal root may hold one
    // written for it while the fix itself runs from Binaries.
    if loaders.is_empty(){unique(find_named(root,"onlinefix.ini"))}else{loaders}
}

/// The program a first run starts in one of those folders: the game itself when it lives there,
/// otherwise the executable beside the fix (an Unreal «-Shipping» build, a bundled runtime…),
/// because a launcher in the root would start it as a second process the first run forbids.
pub(crate) fn first_run_exe(dir:&Path,game_exe:&Path)->Option<PathBuf>{
    if game_exe.parent()==Some(dir){return Some(game_exe.to_path_buf());}
    let mut exes:Vec<PathBuf>=fs::read_dir(dir).ok()?.flatten().map(|entry|entry.path()).filter(|path|{
        let name=path.file_name().map(|name|name.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
        name.ends_with(".exe")&&path.is_file()&&!fs::symlink_metadata(path).is_ok_and(|meta|crate::services::uninstall::is_link(&meta))
            &&!NOT_THE_GAME.iter().any(|skip|name.contains(skip))
    }).collect();
    exes.sort();
    if let Some(shipping)=exes.iter().find(|path|path.to_string_lossy().to_ascii_lowercase().ends_with("-shipping.exe")){
        return Some(shipping.clone());
    }
    if exes.len()==1{return Some(exes.remove(0));}
    // No program beside the fix: only the game itself can load it, and only when it is the leaf process.
    // Unreal may keep the fix under Engine/Binaries/ThirdParty: a catalog-selected Shipping build is the leaf,
    // a root bootstrapper is not (it cannot fork inside the one-process job).
    // Unity may keep it inside its own data folder (Stick Fight: <game>_Data/Plugins, built into steam_api.dll).
    let usable=game_exe.is_file()&&fs::symlink_metadata(game_exe).is_ok_and(|meta|!crate::services::uninstall::is_link(&meta));
    (exes.is_empty()&&usable&&(is_shipping(game_exe)||inside_unity_data(dir,game_exe))).then(||game_exe.to_path_buf())
}

fn is_shipping(exe:&Path)->bool{
    exe.file_name().is_some_and(|name|name.to_string_lossy().to_ascii_lowercase().ends_with("-shipping.exe"))
}

/// The folder lies inside the «<game>_Data» folder Unity keeps beside the game.
pub(crate) fn inside_unity_data(dir:&Path,game_exe:&Path)->bool{
    let (Some(parent),Some(stem))=(game_exe.parent(),game_exe.file_stem()) else {return false};
    dir.starts_with(parent.join(format!("{}_Data",stem.to_string_lossy())))
}

/// The ini of each folder where the fix runs, existing or not yet: a fix that finds none writes one.
pub(crate) fn fix_watch_files(root:&Path)->Vec<PathBuf>{
    fix_dirs(root).into_iter().map(|dir|dir.join("OnlineFix.ini")).collect()
}

/// The [Hashes] section of each file, "" when there is none: any key the fix adds or changes counts.
pub(crate) fn hash_sections(files:&[PathBuf])->Vec<String>{
    files.iter().map(|file|{
        let Ok(bytes)=fs::read(file) else {return String::new()};
        let content=String::from_utf8_lossy(&bytes);
        let mut inside=false;
        let mut section=Vec::new();
        for line in content.lines(){
            let trimmed=line.trim();
            if trimmed.starts_with('[')&&trimmed.ends_with(']'){inside=trimmed.eq_ignore_ascii_case("[Hashes]");continue;}
            if inside&&!trimmed.is_empty(){section.push(trimmed.to_string());}
        }
        section.join("\n")
    }).collect()
}

/// A whole ini, as the fix leaves it once it has written: it empties the file and writes it again,
/// so an empty one, or one without its [Main] id or with a cut 1337, is still being written.
pub(crate) fn ini_complete(content:&str)->bool{
    let content=content.trim_start_matches('\u{feff}');
    let has_id=content.lines().any(|line|line.split_once('=').is_some_and(|(key,_)|key.trim().eq_ignore_ascii_case("RealAppId")));
    let has_hashes=content.lines().any(|line|line.trim().eq_ignore_ascii_case("[Hashes]"));
    let cut_1337=content.lines().filter_map(|line|line.split_once('=')).filter(|(key,_)|key.trim()=="1337")
        .any(|(_,value)|{let value=value.trim();!(value.is_empty()||(value.len()==128&&value.bytes().all(|byte|byte.is_ascii_hexdigit())))});
    has_id&&has_hashes&&!cut_1337
}

/// True when each of these inis that exists is whole.
pub(crate) fn inis_complete(files:&[PathBuf])->bool{
    files.iter().all(|file|match fs::read(file){
        Ok(bytes)=>ini_complete(&String::from_utf8_lossy(&bytes)),
        Err(error)=>error.kind()==std::io::ErrorKind::NotFound,
    })
}

/// Size and date of the fix's DLLs: changes only when the game's fix is replaced.
fn loader_fingerprint(root:&Path)->String{
    let mut parts:Vec<String>=FIX_LOADERS.iter().flat_map(|name|find_named(root,&name.to_ascii_lowercase())).filter_map(|path|{
        let meta=fs::metadata(&path).ok()?;
        let modified=meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
        let relative=path.strip_prefix(root).ok()?.to_string_lossy().to_lowercase();
        Some(format!("{relative}:{}:{modified}",meta.len()))
    }).collect();
    parts.sort();
    parts.join("|")
}

fn trust_store()->Option<PathBuf>{
    std::env::var_os("LOCALAPPDATA").map(|local|PathBuf::from(local).join("CocoMinecraftUpdater").join(TRUST_FILE))
}
fn read_trust(path:&Path)->BTreeMap<String,TrustedRoot>{
    fs::read(path).ok().and_then(|bytes|serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}
fn root_key(root:&Path)->String{root.to_string_lossy().replace('/',"\\").trim_end_matches('\\').to_lowercase()}

/// A copied or restored folder lands on a PC whose hash it does not know.
pub(crate) fn machine_id()->String{
    #[cfg(windows)]{
        return registry::read(registry::MACHINE,"SOFTWARE\\Microsoft\\Cryptography","MachineGuid").unwrap_or_default();
    }
    #[allow(unreachable_code)]
    String::new()
}

/// Every OnlineFix.ini of a game, by path relative to the game folder. Even a pinned one is the
/// fix's to rewrite, so verification only asks that it exists.
fn fix_inis(root:&Path)->Vec<(PathBuf,String)>{
    find_named(root,"OnlineFix.ini").into_iter().filter_map(|ini|{
        let relative=ini.strip_prefix(root).ok()?.to_string_lossy().replace(std::path::MAIN_SEPARATOR,"/").to_lowercase();
        Some((ini,relative))
    }).collect()
}

/// The 1337 value each editable ini holds right now ("" when it has none).
pub(crate) fn current_hashes(_entry:&Experience,root:&Path)->BTreeMap<String,String>{
    fix_inis(root).into_iter().map(|(ini,relative)|{
        let value=fs::read(&ini).ok().and_then(|bytes|existing_1337(&String::from_utf8_lossy(&bytes))).unwrap_or_default();
        (relative,value)
    }).collect()
}

fn trusted_for(store:&Path,root:&Path,machine:&str,loaders:&str)->Option<TrustedRoot>{
    read_trust(store).remove(&root_key(root)).filter(|trusted|!machine.is_empty()&&trusted.machine==machine&&trusted.loaders==loaders)
}

/// True when this PC has never run this game folder through Coco: its hash is still unknown.
pub(crate) fn needs_first_run(_entry:&Experience,root:&Path)->bool{
    let Some(store)=trust_store() else {return false};
    let machine=machine_id();
    !machine.is_empty()&&!fix_dirs(root).is_empty()&&trusted_for(&store,root,&machine,&loader_fingerprint(root)).is_none()
}

/// Records what the inis hold now as this PC's own values.
pub(crate) fn trust_current(entry:&Experience,root:&Path){
    let (Some(store),machine)=(trust_store(),machine_id()) else {return};
    if machine.is_empty(){return;}
    let hashes:BTreeMap<String,String>=current_hashes(entry,root).into_iter().filter(|(_,value)|!value.is_empty()).collect();
    record_trust(&store,root,machine,loader_fingerprint(root),hashes);
}

fn record_trust(store:&Path,root:&Path,machine:String,loaders:String,hashes:BTreeMap<String,String>){
    let mut all=read_trust(store);
    all.insert(root_key(root),TrustedRoot{machine,hashes,loaders});
    if let Some(parent)=store.parent(){let _=fs::create_dir_all(parent);}
    let temp=store.with_extension("tmp");
    if serde_json::to_vec_pretty(&all).ok().is_some_and(|bytes|fs::write(&temp,bytes).is_ok()){let _=fs::rename(&temp,store);}
}

/// After a normal run: a hash the game changed was just written by the fix on this PC.
pub(crate) fn adopt_new_hashes(entry:&Experience,root:&Path,before:&BTreeMap<String,String>){
    let now=current_hashes(entry,root);
    if now.iter().any(|(ini,value)|!value.is_empty()&&before.get(ini)!=Some(value)){trust_current(entry,root);}
}

fn prepare_online_fix(entry:&Experience,root:&Path){
    for url in find_named(root,"OnlineFix.url"){let _=fs::remove_file(url);}
    // Worms W.M.D aborts at start without this file; an empty one opens no browser.
    if entry.id==WORMS_ID{let _=fs::write(root.join("OnlineFix.url"),b"");}
    let game_owned=game_hashes(&entry.id);
    let game=game_owned.as_ref();
    let required:HashSet<String>=entry.required_files.iter().map(|file|file.path.replace('\\',"/").to_lowercase()).collect();
    let is_required=|path:&Path|path.strip_prefix(root).ok()
        .map(|relative|relative.to_string_lossy().replace('\\',"/").to_lowercase())
        .is_some_and(|relative|required.contains(&relative));
    let root_ini=root.join("OnlineFix.ini");
    let root_has_id=fs::read(&root_ini).ok().and_then(|bytes|real_app_id(&String::from_utf8_lossy(&bytes))).is_some();
    if let (false,Some(hashes),false)=(root_has_id,game,is_required(&root_ini)){
        let _=fs::write(&root_ini,default_ini(hashes,entry.id==REPO_ID));
    }
    let trusted=trust_store().and_then(|store|trusted_for(&store,root,&machine_id(),&loader_fingerprint(root)));
    let mut app_ids:HashSet<String>=game.map(|hashes|hashes.real_app_id.clone()).into_iter().collect();
    for ini in find_named(root,"OnlineFix.ini"){
        let Ok(bytes)=fs::read(&ini) else {continue};
        let content=String::from_utf8_lossy(&bytes).to_string();
        app_ids.extend(real_app_id(&content));
        let mut updated=with_hashes(&content,game);
        // This PC's own hash always wins over the table's guess.
        let relative=ini.strip_prefix(root).ok().map(|path|path.to_string_lossy().replace('\\',"/").to_lowercase());
        if let Some(own)=relative.and_then(|relative|trusted.as_ref().and_then(|known|known.hashes.get(&relative).cloned())){
            let base=updated.clone().unwrap_or_else(||content.clone());
            if existing_1337(&base).as_deref()!=Some(own.as_str()){updated=Some(set_1337(&base,&own));}
        }
        if let Some(updated)=updated{
            if updated.as_bytes()!=bytes.as_slice(){let _=fs::write(&ini,updated);}
        }
    }
    let Some(public)=std::env::var_os("PUBLIC").map(PathBuf::from) else {return};
    for app_id in app_ids{prepare_public_stats(&public.join("Documents").join("OnlineFix").join(app_id));}
}

fn prepare_public_stats(base:&Path){
    let stats=base.join("Stats");
    let _=fs::create_dir_all(&stats);
    let _=fs::create_dir_all(base.join("Saves"));
    let (stats_file,achievements)=(stats.join("Stats.ini"),stats.join("Achievements.ini"));
    if !stats_file.exists(){let _=fs::write(stats_file,"[Stats]\r\nLoadedCosmeticsPreviously=1\r\n");}
    if !achievements.exists(){let _=fs::write(achievements,"");}
}

/// A stale address from an old non-P2P setup would send the game to the wrong host.
fn remove_stale_host_files(root:&Path){
    for file in find_named(root,"ip.txt"){let _=fs::remove_file(file);}
}

pub(crate) fn prepare_files(entry:&Experience,root:&Path){
    prepare_online_fix(entry,root);
    remove_stale_host_files(root);
}

#[cfg(windows)]
pub(crate) mod registry{
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::System::Registry::{RegGetValueW,HKEY,HKEY_CLASSES_ROOT,HKEY_CURRENT_USER,HKEY_LOCAL_MACHINE,RRF_RT_REG_DWORD,RRF_RT_REG_SZ};

    pub(crate) const CLASSES:HKEY=HKEY_CLASSES_ROOT;
    pub(crate) const USER:HKEY=HKEY_CURRENT_USER;
    pub(crate) const MACHINE:HKEY=HKEY_LOCAL_MACHINE;

    pub(crate) fn read(root:HKEY,key:&str,value:&str)->Option<String>{
        let wide=|text:&str|std::ffi::OsStr::new(text).encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
        let (key,value)=(wide(key),wide(value));
        let mut buffer=vec![0u16;2048];
        let mut size=(buffer.len()*2) as u32;
        let status=unsafe{RegGetValueW(root,key.as_ptr(),value.as_ptr(),RRF_RT_REG_SZ,std::ptr::null_mut(),buffer.as_mut_ptr().cast(),&mut size)};
        if status!=ERROR_SUCCESS{return None;}
        let length=buffer.iter().position(|unit|*unit==0).unwrap_or(buffer.len());
        String::from_utf16(&buffer[..length]).ok().filter(|text|!text.is_empty())
    }

    pub(super) fn read_number(root:HKEY,key:&str,value:&str)->Option<u32>{
        let wide=|text:&str|std::ffi::OsStr::new(text).encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
        let (key,value)=(wide(key),wide(value));
        let (mut number,mut size)=(0u32,4u32);
        let status=unsafe{RegGetValueW(root,key.as_ptr(),value.as_ptr(),RRF_RT_REG_DWORD,std::ptr::null_mut(),(&mut number as *mut u32).cast(),&mut size)};
        (status==ERROR_SUCCESS).then_some(number)
    }
}

fn quoted_program(command:&str)->Option<PathBuf>{
    command.strip_prefix('"')?.split('"').next().map(PathBuf::from)
}

#[cfg(windows)]
pub(crate) fn find_steam()->Option<PathBuf>{
    use registry::{read,CLASSES,MACHINE,USER};
    let mut candidates=Vec::new();
    candidates.extend(read(CLASSES,"steam\\Shell\\Open\\Command","").as_deref().and_then(quoted_program));
    candidates.extend(read(USER,"Software\\Valve\\Steam","SteamExe").map(PathBuf::from));
    candidates.extend(read(USER,"Software\\Valve\\Steam","SteamPath").map(|path|PathBuf::from(path).join("steam.exe")));
    for key in ["SOFTWARE\\WOW6432Node\\Valve\\Steam","SOFTWARE\\Valve\\Steam"]{
        candidates.extend(read(MACHINE,key,"InstallPath").map(|path|PathBuf::from(path).join("steam.exe")));
    }
    for drive in b'C'..=b'Z'{
        let drive=format!("{}:\\",drive as char);
        if !Path::new(&drive).exists(){continue;}
        for sub in ["Program Files (x86)\\Steam\\steam.exe","Program Files\\Steam\\steam.exe","Steam\\steam.exe","Games\\Steam\\steam.exe","Juegos\\Steam\\steam.exe"]{
            candidates.push(Path::new(&drive).join(sub));
        }
    }
    candidates.into_iter().find(|path|path.is_file())
}

#[cfg(not(windows))]
pub(crate) fn find_steam()->Option<PathBuf>{None}

/// Steam writes the signed-in account here, but the value can outlive a crash, so it only
/// counts next to the web helper, which the client starts once it is really up.
#[cfg(windows)]
fn steam_signed_in()->bool{
    registry::read_number(registry::USER,"Software\\Valve\\Steam\\ActiveProcess","ActiveUser").is_some_and(|user|user!=0)
}

#[cfg(not(windows))]
fn steam_signed_in()->bool{false}

/// Online-Fix talks through the Steam client: without it these games refuse to run. Steam
/// starts minimized and the game waits for it, longer than Launcher 1 did, because a
/// process that exists is not yet a client that answers. Waiting ends so a login window
/// the player has not answered cannot hold the launch forever.
pub(crate) fn ensure_steam(is_running:impl Fn()->bool,is_ready:impl Fn()->bool,on_wait:impl Fn(bool))->Result<(),String>{
    if is_running()&&is_ready(){return Ok(());}
    on_wait(true);
    let result=(||{
        if !is_running(){
            let steam=find_steam().ok_or("Estos juegos necesitan Steam y Coco no lo encontró en este PC. Instala Steam y vuelve a intentarlo.")?;
            Command::new(steam).arg("-silent").spawn()
                .map_err(|_|"Windows no dejó abrir Steam. Ábrelo tú y vuelve a intentarlo.".to_string())?;
        }
        for _ in 0..(STEAM_WAIT_SECONDS*2){
            std::thread::sleep(Duration::from_millis(500));
            if is_running()&&is_ready(){
                // The client answers a moment after it publishes its account.
                std::thread::sleep(Duration::from_millis(2500));
                break;
            }
        }
        Ok(())
    })();
    on_wait(false);
    result
}

pub(crate) fn wait_for_steam(is_process_running:impl Fn(&str)->bool,on_wait:impl Fn(bool))->Result<(),String>{
    ensure_steam(||is_process_running("steam.exe"),||steam_signed_in()&&is_process_running("steamwebhelper.exe"),on_wait)
}

const POPUP_MARKERS:&[&str]=&["online-fix","onlinefix","online fix","credits","créditos","fix made by","the fix is made by","online-fix.me","cs.rin.ru","you will get this message only once","freesteam","steamfix","ofme"];
const POPUP_BUTTONS:&[&str]=&["ok","accept","aceptar","play","play!","start","start game","empezar","begin","enter","entrar","continue","continuar","go","ir","jugar","join","unirse","играть","играть!","войти","начать","старт","принять","продолжить","закрыть","ок"];

/// The credits box names the fix's site: no other program's dialog says that.
fn is_signed_fix_popup(text:&str)->bool{
    let text=text.to_lowercase();
    text.contains("online-fix.me")&&(text.contains("fix is made by")||text.contains("trusted sites"))
}

/// Closes the fix's credits box wherever Windows put it, for a moment after a first run.
pub(crate) fn sweep_fix_popups(duration:Duration){
    let started=std::time::Instant::now();
    while started.elapsed()<duration{
        answer_fix_popups(&HashSet::new());
        std::thread::sleep(Duration::from_millis(40));
    }
}

fn is_fix_popup(text:&str)->bool{
    let text=text.to_lowercase();
    POPUP_MARKERS.iter().any(|marker|text.contains(marker))
}

fn accept_button(labels:&[String])->Option<usize>{
    labels.iter().position(|label|{
        let label=label.replace('&',"").trim().to_lowercase();
        POPUP_BUTTONS.contains(&label.as_str())
    })
}

#[cfg(windows)]
mod popups{
    use super::{accept_button,is_fix_popup,is_signed_fix_popup};
    use std::collections::HashSet;
    use std::ffi::c_void;
    type Hwnd=*mut c_void;
    type EnumProc=unsafe extern "system" fn(Hwnd,isize)->i32;
    const BM_CLICK:u32=0x00F5;
    const WM_CLOSE:u32=0x0010;
    const SW_HIDE:i32=0;
    #[link(name="user32")]
    extern "system"{
        fn EnumWindows(callback:EnumProc,param:isize)->i32;
        fn EnumChildWindows(parent:Hwnd,callback:EnumProc,param:isize)->i32;
        fn GetClassNameW(window:Hwnd,buffer:*mut u16,length:i32)->i32;
        fn GetWindowTextW(window:Hwnd,buffer:*mut u16,length:i32)->i32;
        fn GetWindowThreadProcessId(window:Hwnd,process:*mut u32)->u32;
        fn IsWindowVisible(window:Hwnd)->i32;
        fn PostMessageW(window:Hwnd,message:u32,wparam:usize,lparam:isize)->i32;
        fn ShowWindowAsync(window:Hwnd,command:i32)->i32;
    }
    fn read(window:Hwnd,getter:unsafe extern "system" fn(Hwnd,*mut u16,i32)->i32)->String{
        let mut buffer=[0u16;512];
        let count=unsafe{getter(window,buffer.as_mut_ptr(),buffer.len() as i32)};
        String::from_utf16_lossy(&buffer[..count.max(0) as usize])
    }
    unsafe extern "system" fn collect(window:Hwnd,list:isize)->i32{
        unsafe{(*(list as *mut Vec<usize>)).push(window as usize)};
        1
    }
    /// True when one of the fix's dialogs was answered.
    /// One window: answered when it is a fix dialog of the game's processes, or the credits box,
    /// which Windows shows for the fix outside them and which names the fix's site.
    pub(super) fn answer_window(window:Hwnd,game_pids:&HashSet<u32>)->bool{
        if unsafe{IsWindowVisible(window)}==0||read(window,GetClassNameW)!="#32770"{return false;}
        let mut pid=0;
        unsafe{GetWindowThreadProcessId(window,&mut pid)};
        let mut children:Vec<usize>=Vec::new();
        unsafe{EnumChildWindows(window,collect,&mut children as *mut Vec<usize> as isize)};
        let (mut buttons,mut labels,mut text)=(Vec::new(),Vec::new(),read(window,GetWindowTextW));
        for child in children.into_iter().map(|value|value as Hwnd){
            let label=read(child,GetWindowTextW);
            if read(child,GetClassNameW).eq_ignore_ascii_case("button"){buttons.push(child);labels.push(label);}
            else{text.push(' ');text.push_str(&label);}
        }
        // Only the fix's own dialogs: a question from the game itself stays for the player.
        if !is_fix_popup(&text){return false;}
        if !game_pids.contains(&pid)&&!is_signed_fix_popup(&text){return false;}
        // Out of sight first, then answered: it is gone even before the answer lands.
        unsafe{ShowWindowAsync(window,SW_HIDE)};
        match accept_button(&labels){
            Some(index)=>unsafe{PostMessageW(buttons[index],BM_CLICK,0,0);},
            None=>unsafe{PostMessageW(window,WM_CLOSE,0,0);},
        };
        true
    }
    /// True when one of the fix's dialogs was answered.
    pub(super) fn answer(game_pids:&HashSet<u32>)->bool{
        let mut windows:Vec<usize>=Vec::new();
        unsafe{EnumWindows(collect,&mut windows as *mut Vec<usize> as isize)};
        let mut answered=false;
        for window in windows.into_iter().map(|value|value as Hwnd){answered|=answer_window(window,game_pids);}
        answered
    }
}

/// The credits box as Windows shows it, reported one window at a time.
pub(crate) fn answer_fix_popup_window(window:usize)->bool{
    #[cfg(windows)]{return popups::answer_window(window as _,&HashSet::new());}
    #[allow(unreachable_code)]
    {let _=window;false}
}

/// Answers the fix's dialogs among these processes, on the calling thread's desktop.
pub(crate) fn answer_fix_popups(game_pids:&HashSet<u32>)->bool{
    #[cfg(windows)]{return popups::answer(game_pids);}
    #[allow(unreachable_code)]
    {let _=game_pids;false}
}

/// Watches the game and whatever it starts for as long as it runs, up to ten minutes:
/// these dialogs appear while a game boots, never later.
pub(crate) fn watch_popups(root_pid:u32,process_tree:impl Fn(&mut HashSet<u32>)->bool+Send+'static){
    std::thread::spawn(move||{
        let mut pids=HashSet::from([root_pid]);
        // Five checks a second: should a dialog still appear, it is gone before it is read.
        for _ in 0..(10*60*5){
            if !process_tree(&mut pids){return;}
            answer_fix_popups(&pids);
            std::thread::sleep(Duration::from_millis(200));
        }
    });
}

#[cfg(test)]
mod tests{
    use super::*;
    use crate::services::catalog::RequiredFile;
    use std::sync::atomic::{AtomicU64,Ordering};
    static SEQUENCE:AtomicU64=AtomicU64::new(0);

    struct Root(PathBuf);
    impl Root{
        fn new()->Self{
            let path=std::env::temp_dir().join(format!("coco-prepare-test-{}-{}",std::process::id(),SEQUENCE.fetch_add(1,Ordering::Relaxed)));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Root{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
    fn put(path:&Path,bytes:&[u8]){fs::create_dir_all(path.parent().unwrap()).unwrap();fs::write(path,bytes).unwrap();}
    fn entry(id:&str,required:&[&str])->Experience{
        let mut value=crate::services::catalog::read_catalog().unwrap().into_iter().find(|entry|entry.workflow=="coco-standalone").unwrap();
        value.id=id.to_string();
        value.required_files=required.iter().map(|path|RequiredFile{path:path.to_string(),sha256:String::new(),size:0}).collect();
        value
    }

    #[test]
    fn every_game_with_an_onlinefix_ini_loader_has_its_hashes(){
        let catalog=crate::services::catalog::read_catalog().unwrap();
        for game in catalog.iter().filter(|entry|entry.workflow=="coco-standalone" &&
            entry.required_files.iter().any(|file| matches!(
                file.path.replace('\\',"/").rsplit('/').next().unwrap_or("").to_ascii_lowercase().as_str(),
                "onlinefix.dll" | "onlinefix64.dll"))){
            let hashes=table().games.get(&game.id).unwrap_or_else(||panic!("{} has no Online-Fix hashes",game.id));
            assert_eq!(hashes.hash0.len(),128,"{}",game.id);
            assert!(table().apps.contains_key(&hashes.real_app_id),"{}",game.id);
        }
    }

    #[test]
    fn a_game_without_an_ini_loader_does_not_receive_unrelated_fix_configuration(){
        let root=Root::new();
        prepare_files(&entry("no-ini-loader",&["version.dll"]),&root.0);
        assert!(!root.0.join("OnlineFix.ini").exists());
    }

    #[test]
    fn yapyap_first_launch_prepares_the_observed_fix_hashes() {
        let hashes=&table().apps["3834090"];
        let ini=with_hashes("[Main]\nRealAppId=3834090\nFakeAppId=480\n[Hashes]\n0=old\n",table().games.get("yapyap")).unwrap();
        assert_eq!(hashes.hash1337.len(),128);
        assert!(ini.contains(&format!("0={}",hashes.hash0)));
        assert!(ini.contains(&format!("1337={}",hashes.hash1337)));
    }

    #[test]
    fn updating_fix_hashes_preserves_other_hashes_and_sections() {
        let original="[Main]\nRealAppId=3722330\n[Hashes]\n0=old\n1=keep\n1337=old\n[Other]\nchoice=keep\n";
        let result=with_hashes(original,None).unwrap();
        assert!(result.contains("1=keep\r\n"));
        assert!(result.contains("[Other]\r\nchoice=keep\r\n"));
        assert!(!result.contains("0=old"));
        assert_eq!(with_hashes(&result,None).unwrap(),result);
        assert!(with_hashes(&(original.to_owned()+"[Hashes]\n1=other\n"),None).is_none());
    }

    #[test]
    fn heavenly_bodies_prepares_observed_hash_without_losing_dlc_hash() {
        let ini="[Main]\nRealAppId=1138850\nFakeAppId=480\n[Hashes]\n0=old\n1=keep\n1337=old\n";
        let result=with_hashes(ini,table().games.get("heavenly-bodies")).unwrap();
        assert!(result.contains("1=keep\r\n"));
        assert!(result.contains(&format!("1337={}",table().apps["1138850"].hash1337)));
        assert!(!result.contains("1337=old"));
    }

    #[test]
    fn the_credit_popup_hash_replaces_the_old_block_and_keeps_the_rest(){
        let game=entry("pilgrim",&[]);
        let root=Root::new();
        let nested=root.0.join("Bin/OnlineFix.ini");
        put(&nested,b"\xEF\xBB\xBF[Main]\r\nRealAppId=3722330\r\nFakeAppId=480\r\n\r\n[Hashes]\r\n0=old\r\n");
        put(&root.0.join("Sub/OnlineFix.url"),b"[InternetShortcut]");
        put(&root.0.join("ip.txt"),b"10.0.0.1");
        prepare_files(&game,&root.0);
        let content=fs::read_to_string(&nested).unwrap();
        assert!(content.starts_with("[Main]\r\nRealAppId=3722330"),"{content}");
        assert!(content.contains(&format!("0={}",table().apps["3722330"].hash0)),"the ini's own app id wins");
        assert!(!content.contains("0=old"));
        assert!(!root.0.join("Sub/OnlineFix.url").exists());
        assert!(!root.0.join("ip.txt").exists());
        let root_ini=fs::read_to_string(root.0.join("OnlineFix.ini")).unwrap();
        assert!(root_ini.contains(&format!("RealAppId={}",table().games["pilgrim"].real_app_id)),"a missing root ini is restored");
        let before=fs::read(&nested).unwrap();
        prepare_files(&game,&root.0);
        assert_eq!(fs::read(&nested).unwrap(),before,"running twice changes nothing");
    }

    #[test]
    fn a_pinned_ini_is_still_the_fixs_to_rewrite_and_still_verifies(){
        let game=entry("pilgrim",&["PILGRIM/Binaries/Win64/OnlineFix.ini"]);
        let root=Root::new();
        let pinned=root.0.join("PILGRIM/Binaries/Win64/OnlineFix.ini");
        put(&pinned,b"[Main]\nRealAppId=2965660\n[Hashes]\n0=shipped\n1=dlc\n");
        prepare_files(&game,&root.0);
        let ini=fs::read_to_string(&pinned).unwrap();
        assert!(ini.contains(&format!("0={}",table().apps["2965660"].hash0)));
        assert!(ini.contains("1=dlc"),"other hashes stay");
        assert!(fix_inis(&root.0).iter().any(|(_,relative)|relative=="pilgrim/binaries/win64/onlinefix.ini"),"a pinned ini gets a first run too");
        assert!(crate::services::verify::is_fix_settings("PILGRIM\\Binaries\\Win64\\OnlineFix.ini"));
        assert!(crate::services::verify::is_fix_settings("onlinefix.ini"));
        assert!(!crate::services::verify::is_fix_settings("OnlineFix64.dll"));
    }

    #[test]
    fn a_first_run_starts_the_program_that_loads_the_fix_in_every_layout(){
        // Unity, 64 and 32 bits: the game and the fix side by side.
        let unity=Root::new();
        for file in ["CRACK.exe","UnityCrashHandler64.exe","OnlineFix64.dll","winmm.dll"]{put(&unity.0.join(file),b"x");}
        let game=unity.0.join("CRACK.exe");
        assert_eq!(fix_dirs(&unity.0),vec![unity.0.clone()]);
        assert_eq!(first_run_exe(&unity.0,&game),Some(game.clone()));
        // Unreal: a launcher in the root starts «-Shipping» from Binaries, where the fix runs;
        // the root ini Coco writes does not make the root a fix folder.
        let unreal=Root::new();
        let bin=unreal.0.join("PILGRIM/Binaries/Win64");
        for file in ["PILGRIM.exe","OnlineFix.ini"]{put(&unreal.0.join(file),b"x");}
        for file in ["PILGRIM-Win64-Shipping.exe","CrashReportClient.exe","OnlineFix64.dll","OnlineFix.ini"]{put(&bin.join(file),b"x");}
        assert_eq!(fix_dirs(&unreal.0),vec![bin.clone()]);
        assert_eq!(first_run_exe(&bin,&unreal.0.join("PILGRIM.exe")),Some(bin.join("PILGRIM-Win64-Shipping.exe")));
        assert_eq!(fix_watch_files(&unreal.0),vec![bin.join("OnlineFix.ini")]);
        // Unreal Steamworks: the fix is in Engine, while the selected leaf is in Game/Binaries.
        let external=Root::new();
        let steam=external.0.join("Engine/Binaries/ThirdParty/Steamworks/Win64");
        let shipping=external.0.join("Game/Binaries/Win64/Game-Win64-Shipping.exe");
        put(&steam.join("OnlineFix64.dll"),b"x");put(&shipping,b"x");
        assert_eq!(first_run_exe(&steam,&shipping),Some(shipping));
        assert_eq!(first_run_exe(&steam,&external.0.join("Game.exe")),None,"a bootstrapper cannot fork inside the one-process job");
        // A bundled runtime (Move or Die): the fix sits beside love.exe, with no ini yet.
        let love=Root::new();
        put(&love.0.join("MoveOrDie.exe"),b"x");
        for file in ["love.exe","OnlineFix.dll","steam_api.dll"]{put(&love.0.join("Love/win").join(file),b"x");}
        assert_eq!(first_run_exe(&love.0.join("Love/win"),&love.0.join("MoveOrDie.exe")),Some(love.0.join("Love/win/love.exe")));
        assert_eq!(fix_watch_files(&love.0),vec![love.0.join("Love/win/OnlineFix.ini")],"an ini the fix will create is watched");
        // A fix built into another DLL (Worms): only its ini marks the folder.
        let worms=Root::new();
        for file in ["Worms W.M.D.exe","winmm.dll","OnlineFix.ini"]{put(&worms.0.join(file),b"x");}
        assert_eq!(fix_dirs(&worms.0),vec![worms.0.clone()]);
        // Two candidate programs and none is the game or a Shipping build: no guess.
        let unclear=Root::new();
        for file in ["a.exe","b.exe","OnlineFix64.dll"]{put(&unclear.0.join("sub").join(file),b"x");}
        assert_eq!(first_run_exe(&unclear.0.join("sub"),&unclear.0.join("game.exe")),None);
        // The root bootstrapper exists but still cannot be the leaf of an Unreal build.
        put(&external.0.join("Game.exe"),b"x");
        assert_eq!(first_run_exe(&steam,&external.0.join("Game.exe")),None,"an existing bootstrapper is still not the leaf");
        // A Unity fix built into steam_api.dll inside the data folder (Stick Fight): the game loads it.
        let plugins=Root::new();
        let data=plugins.0.join("StickFightTheGame/StickFight_Data/Plugins");
        let stick=plugins.0.join("StickFightTheGame/StickFight.exe");
        put(&stick,b"x");put(&plugins.0.join("StickFightTheGame/winmm.dll"),b"x");
        for file in ["OnlineFix.ini","steam_api.dll","steam_api_of.dll"]{put(&data.join(file),b"x");}
        assert_eq!(fix_dirs(&plugins.0),vec![data.clone()]);
        assert_eq!(first_run_exe(&data,&stick),Some(stick.clone()));
        assert!(!inside_unity_data(&plugins.0.join("Other_Data"),&stick));
    }

    #[test]
    fn an_ini_the_fix_is_still_rewriting_is_never_taken_as_written(){
        let whole=format!("[Main]\r\nRealAppId=4312190\r\n[Hashes]\r\n0={0}\r\n1337={0}\r\n","c".repeat(128));
        assert!(ini_complete(&whole));
        assert!(!ini_complete(""),"the fix empties the file before writing it");
        assert!(!ini_complete(&whole[..whole.len()-40]),"a 1337 cut halfway");
        assert!(!ini_complete("[Hashes]\r\n0=x\r\n"),"no [Main] yet");
        assert!(!ini_complete("[Main]\r\nRealAppId=1\r\n"),"no [Hashes] yet");
        assert!(ini_complete("[Main]\r\nRealAppId=1\r\n[Hashes]\r\n0=x\r\n"),"a fix that keeps no 1337");
        let root=Root::new();
        assert!(inis_complete(&[root.0.join("not-yet.ini")]),"an ini the fix has not created yet is fine");
        put(&root.0.join("empty.ini"),b"");
        assert!(!inis_complete(&[root.0.join("empty.ini")]));
    }

    #[test]
    fn any_change_in_the_hashes_section_counts_as_written(){
        let root=Root::new();
        let ini=root.0.join("OnlineFix.ini");
        let missing=hash_sections(std::slice::from_ref(&ini));
        assert_eq!(missing,vec![String::new()]);
        put(&ini,b"[Main]\r\nRealAppId=1\r\n[Hashes]\r\n0=zero\r\n1337=old\r\n");
        let before=hash_sections(std::slice::from_ref(&ini));
        assert_ne!(before,missing,"an ini the fix creates is a change");
        put(&ini,b"[Main]\r\nRealAppId=1\r\nBuildId=7\r\n[Hashes]\r\n0=zero\r\n1337=old\r\n");
        assert_eq!(hash_sections(std::slice::from_ref(&ini)),before,"other sections are not the fix's hash");
        put(&ini,b"[Main]\r\nRealAppId=1\r\n[Hashes]\r\n0=zero\r\n1337=old\r\n2=new\r\n");
        assert_ne!(hash_sections(std::slice::from_ref(&ini)),before,"a new key is a change");
    }

    #[test]
    fn this_pcs_hash_replaces_only_the_1337_line(){
        let mine="b".repeat(128);
        let replaced=set_1337("[Main]\r\nRealAppId=1\r\n[Hashes]\r\n0=zero\r\n1337=old\r\n1=dlc\r\n[Other]\r\nx=1\r\n",&mine);
        assert_eq!(replaced,format!("[Main]\r\nRealAppId=1\r\n[Hashes]\r\n0=zero\r\n1337={mine}\r\n1=dlc\r\n[Other]\r\nx=1\r\n"));
        let added=set_1337("[Hashes]\r\n0=zero\r\n[Other]\r\nx=1\r\n",&mine);
        assert_eq!(added,format!("[Hashes]\r\n0=zero\r\n1337={mine}\r\n[Other]\r\nx=1\r\n"));
        assert!(set_1337("[Main]\r\nRealAppId=1\r\n",&mine).ends_with(&format!("[Hashes]\r\n1337={mine}\r\n")));
    }

    #[test]
    fn a_trusted_hash_belongs_to_one_pc_and_one_folder(){
        let root=Root::new();
        let store=root.0.join("trust.json");
        let game=root.0.join("Game");
        record_trust(&store,&game,"machine-a".into(),"fix:1:1".into(),BTreeMap::from([("onlinefix.ini".into(),"a".repeat(128))]));
        assert_eq!(trusted_for(&store,&game,"machine-a","fix:1:1").unwrap().hashes["onlinefix.ini"],"a".repeat(128));
        assert!(trusted_for(&store,&game,"machine-b","fix:1:1").is_none(),"a folder copied to another PC needs its own first run");
        assert!(trusted_for(&store,&root.0.join("Moved"),"machine-a","fix:1:1").is_none(),"a moved folder is checked again");
        assert!(trusted_for(&store,&game,"machine-a","fix:2:2").is_none(),"a game update that replaces the fix is checked again");
        assert!(trusted_for(&store,&game,"","fix:1:1").is_none());
    }

    #[test]
    fn worms_keeps_the_empty_file_it_needs_to_start(){
        let root=Root::new();
        put(&root.0.join("OnlineFix.url"),b"[InternetShortcut]\r\nURL=https://x");
        prepare_files(&entry(WORMS_ID,&[]),&root.0);
        assert_eq!(fs::read(root.0.join("OnlineFix.url")).unwrap(),b"");
    }

    #[test]
    fn only_the_fix_dialogs_are_answered(){
        assert!(is_fix_popup("The fix is made by online-fix.me"));
        assert!(is_fix_popup("CRÉDITOS"));
        assert!(!is_fix_popup("¿Guardar los cambios antes de salir?"));
        assert_eq!(accept_button(&["Cancel".into(),"&OK".into()]),Some(1));
        assert_eq!(accept_button(&["Играть".into()]),Some(0));
        assert_eq!(accept_button(&["Cancel".into()]),None);
    }

    #[test]
    fn the_steam_command_line_gives_its_program(){
        assert_eq!(quoted_program("\"C:\\Steam\\steam.exe\" -- \"%1\""),Some(PathBuf::from("C:\\Steam\\steam.exe")));
        assert_eq!(quoted_program("steam.exe"),None);
    }

    #[test]
    fn a_signed_in_steam_starts_nothing_and_shows_nothing(){
        let shown=std::cell::Cell::new(false);
        assert!(ensure_steam(||true,||true,|_|shown.set(true)).is_ok());
        assert!(!shown.get());
    }

    #[test]
    fn the_wait_is_announced_and_always_cleared(){
        let events=std::cell::RefCell::new(Vec::new());
        let ready=std::cell::Cell::new(false);
        let result=ensure_steam(||true,||{let was=ready.get();ready.set(true);was},|value|events.borrow_mut().push(value));
        assert!(result.is_ok());
        assert_eq!(*events.borrow(),vec![true,false]);
    }

    /// Opens the real Steam of this PC: cargo test steam_really_opens -- --ignored --nocapture
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn steam_really_opens(){
        let running=|name:&str|Command::new("tasklist").args(["/FI",&format!("IMAGENAME eq {name}"),"/NH"]).output()
            .map(|out|String::from_utf8_lossy(&out.stdout).to_lowercase().contains(name)).unwrap_or(false);
        println!("before: steam={} helper={} signed_in={} exe={:?}",running("steam.exe"),running("steamwebhelper.exe"),steam_signed_in(),find_steam());
        let started=std::time::Instant::now();
        wait_for_steam(running,|value|println!("waiting={value} at {:?}",started.elapsed())).unwrap();
        println!("after {:?}: steam={} helper={} signed_in={}",started.elapsed(),running("steam.exe"),running("steamwebhelper.exe"),steam_signed_in());
        assert!(running("steam.exe")&&running("steamwebhelper.exe"));
    }
}
