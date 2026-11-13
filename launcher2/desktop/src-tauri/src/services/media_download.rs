//! Verified, resumable local media downloads. URLs/paths are resolved ONLY
//! from the embedded private media manifest, never from frontend arguments.
//! Final media files in the user's Downloads folder are never overwritten.
use super::media::{self, PrivateEpisode, PrivateMedia};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tauri::Emitter;

const CHUNK: u64 = 32 * 1024 * 1024;
const MAX_VIDEO: u64 = 32 * 1024 * 1024 * 1024;
const MIN_DISK_MARGIN: u64 = 64 * 1024 * 1024;
const RETRIES: u8 = 3;
const MAX_STATE: u64 = 16 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(90);
static VERIFIED_CACHE: OnceLock<Mutex<HashMap<PathBuf,(FileFingerprint,String)>>> = OnceLock::new();

#[derive(Clone,Debug,PartialEq,Eq)]
struct FileFingerprint {
    size:u64,
    modified:Option<std::time::SystemTime>,
    created:Option<std::time::SystemTime>,
    identity:Option<(u64,u64)>,
    links:u64,
}
fn cache()->&'static Mutex<HashMap<PathBuf,(FileFingerprint,String)>> {
    VERIFIED_CACHE.get_or_init(||Mutex::new(HashMap::new()))
}
fn file_fingerprint(file:&File)->Result<FileFingerprint,String>{
    let metadata=file.metadata().map_err(|_|"Cannot inspect media identity")?;
    #[cfg(windows)]
    let (identity,links)={
        use std::os::windows::io::AsRawHandle;
        #[repr(C)]
        struct FileTime{low:u32,high:u32}
        #[repr(C)]
        struct Info {
            attrs:u32,creation:FileTime,access:FileTime,write:FileTime,
            volume:u32,size_high:u32,size_low:u32,links:u32,
            index_high:u32,index_low:u32,
        }
        #[link(name="kernel32")]
        extern "system"{
            fn GetFileInformationByHandle(handle:isize,info:*mut Info)->i32;
        }
        let mut info=std::mem::MaybeUninit::<Info>::uninit();
        if unsafe{GetFileInformationByHandle(file.as_raw_handle() as isize,info.as_mut_ptr())}==0{
            return Err("Cannot identify verified Windows media file".into());
        }
        let info=unsafe{info.assume_init()};
        (Some((info.volume as u64,
            ((info.index_high as u64)<<32)|(info.index_low as u64))),info.links as u64)
    };
    #[cfg(unix)]
    let (identity,links)={
        use std::os::unix::fs::MetadataExt;
        (Some((metadata.dev(),metadata.ino())),metadata.nlink())
    };
    #[cfg(not(any(unix,windows)))]
    let (identity,links)=(None,1);
    Ok(FileFingerprint {
        size:metadata.len(),
        modified:metadata.modified().ok(),
        created:metadata.created().ok(),
        identity,
        links,
    })
}

#[derive(Default)]
pub struct MediaDownloadState {
    active: Mutex<HashMap<(String, String), Arc<AtomicBool>>>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MediaDownloadStatus {
    pub id: String,
    pub episode_id: String,
    pub state: &'static str,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub path: Option<String>,
    pub reason: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaDownloadProgress {
    pub id: String,
    pub episode_id: String,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub percent: f64,
    pub phase: &'static str,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PartialState {
    schema_version: u8,
    id: String,
    episode_id: String,
    sha256: String,
    total_bytes: u64,
    verified_bytes: u64,
    prefix_sha256: String,
}

#[derive(Clone)]
struct Target {
    id: String,
    episode_id: String,
    path: PathBuf,
    partial: PathBuf,
    state: PathBuf,
    #[cfg(not(windows))]
    lock: PathBuf,
    url: reqwest::Url,
    expected: u64,
    sha256: String,
}

// Legacy Coco1 folder names come from launcher/catalog.template.json
// content.downloadFolderName; the bundled PRIVATE media-manifests.json does
// not currently embed this field. Explicit known names preserve compatibility
// without trusting an arbitrary frontend-selected destination.
fn legacy_folder(id: &str) -> &str {
    match id {
        "heart-signal" => "heart signal",
        "love-island-us" => "love island us",
        "the-drama-2026" => "the drama",
        "leviticus-2026" => "leviticus",
        "mickey-17-2025" => "mickey 17",
        _ => id,
    }
}

pub(super) fn safe_file_name(name: &str) -> bool {
    if name.is_empty() || name.len() > 240 || name.starts_with('.') ||
        (name.ends_with(' ') || name.ends_with('.')) || name.chars().any(char::is_control) ||
        name.chars().any(|c| "\\/:*?\"<>|".contains(c)) { return false; }
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    !matches!(stem.as_str(),"CON"|"PRN"|"AUX"|"NUL"|"COM1"|"COM2"|"COM3"|"COM4"|
        "COM5"|"COM6"|"COM7"|"COM8"|"COM9"|"LPT1"|"LPT2"|"LPT3"|
        "LPT4"|"LPT5"|"LPT6"|"LPT7"|"LPT8"|"LPT9")
}

fn no_links(path: &Path) -> Result<(), String> {
    for parent in path.ancestors() {
        match fs::symlink_metadata(parent) {
            Ok(meta) => {
                if meta.file_type().is_symlink() { return Err("Media symlink path is blocked".into()); }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if meta.file_attributes() & 0x400 != 0 {
                        return Err("Media junction/reparse path is blocked".into());
                    }
                }
                if parent == path && !meta.is_dir() && !meta.is_file() {
                    return Err("Unsupported media filesystem entry".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Cannot inspect media filesystem path".into()),
        }
    }
    Ok(())
}

fn user_downloads() -> Result<PathBuf, String> {
    #[cfg(windows)]
    let home = std::env::var_os("USERPROFILE").ok_or("USERPROFILE is unavailable")?;
    #[cfg(not(windows))]
    let home = std::env::var_os("HOME").ok_or("Home directory is unavailable")?;
    let home = PathBuf::from(home);
    if !home.is_absolute() { return Err("Invalid user home path".into()); }
    let downloads = home.join("Downloads");
    no_links(&downloads)?;
    Ok(downloads)
}

fn target_from(
    entries: &[PrivateMedia], id: &str, episode_id: &str,
    downloads: &Path, local_fixture: bool,
) -> Result<Target, String> {
    let entry = entries.iter().find(|item| item.id == id).ok_or("Unknown media title")?;
    let ep = entry.episodes.iter().find(|item| item.id == episode_id)
        .ok_or("Unknown media episode")?;
    if !safe_file_name(&ep.file_name) || !safe_file_name(legacy_folder(id)) {
        return Err("Unsafe media destination name".into());
    }
    if ep.sha256.len() != 64 || !ep.sha256.bytes().all(|c| c.is_ascii_hexdigit()) ||
        ep.size == 0 || ep.size > MAX_VIDEO {
        return Err("Media must have pinned SHA256 and size for local download".into());
    }
    let source = if ep.source_url.is_empty() { &ep.stream_url } else { &ep.source_url };
    let url = reqwest::Url::parse(source).map_err(|_| "Invalid embedded media source URL")?;
    if !media::upstream_allowed(&url, local_fixture) {
        return Err("Untrusted embedded media source URL".into());
    }
    let dir = downloads.join(legacy_folder(id));
    let path = dir.join(&ep.file_name);
    let partial = dir.join(format!("{}.partial",ep.file_name));
    let state = dir.join(format!("{}.partial.state",ep.file_name));
    for item in [&dir, &path, &partial, &state] { no_links(item)?; }
    #[cfg(not(windows))]
    let lock=dir.join(format!("{}.partial.lock",ep.file_name));
    #[cfg(not(windows))]
    no_links(&lock)?;
    Ok(Target {
        id:id.to_owned(), episode_id:episode_id.to_owned(),
        path, partial, state,
        #[cfg(not(windows))]
        lock,
        url, expected:ep.size, sha256:ep.sha256.to_ascii_lowercase(),
    })
}

fn target_private() -> Result<(Vec<PrivateMedia>, PathBuf),String> {
    let entries=media::private_catalog()?;
    let downloads=user_downloads()?;
    Ok((entries, downloads))
}

#[cfg(windows)]
fn read_file(path: &Path) -> Result<File,String> {
    use std::os::windows::fs::OpenOptionsExt;
    no_links(path)?;
    OpenOptions::new().read(true).share_mode(1).open(path)
        .map_err(|_| "Cannot open media file read-only".into())
}
#[cfg(not(windows))]
fn read_file(path: &Path) -> Result<File,String> {
    no_links(path)?;
    File::open(path).map_err(|_| "Cannot open media file".into())
}

fn hash_file(file: &mut File, cap: u64) -> Result<(String,u64), String> {
    file.seek(SeekFrom::Start(0)).map_err(|_| "Cannot seek media file")?;
    let mut hash=Sha256::new();
    let mut buffer=[0u8;1024*1024];
    let mut size=0u64;
    loop {
        let n=file.read(&mut buffer).map_err(|_| "Cannot read media file")?;
        if n==0 { break; }
        size=size.checked_add(n as u64).ok_or("Media size overflow")?;
        if size>cap { return Err("Media file exceeds manifest limit".into()); }
        hash.update(&buffer[..n]);
    }
    Ok((format!("{:x}",hash.finalize()),size))
}

// A caller must hold the returned handle for the ENTIRE playback lifetime so
// Windows cannot replace/modify the verified bytes after hashing.
fn open_verified(target:&Target) -> Result<Option<File>,String> {
    no_links(&target.path)?;
    if !target.path.exists() { return Ok(None); }
    let mut file=read_file(&target.path)?;
    let fingerprint=file_fingerprint(&file)?;
    if fingerprint.size!=target.expected {
        return Err("Existing media conflicts with pinned size; it will not be overwritten".into());
    }
    let cached=cache().lock().ok()
        .and_then(|entries|entries.get(&target.path).cloned());
    if cached.as_ref().is_none_or(|(old,hash)|old!=&fingerprint || hash!=&target.sha256){
        let (hash,len)=hash_file(&mut file,target.expected)?;
        if len!=target.expected || hash!=target.sha256 {
            if let Ok(mut entries)=cache().lock(){entries.remove(&target.path);}
            return Err("Existing media conflicts with pinned SHA256; it will not be overwritten".into());
        }
        // Identity (volume+file index), creation and modified timestamps must
        // still match after the verification read. Holding the Windows handle
        // with FILE_SHARE_READ prevents writes/replacements during streaming.
        if file_fingerprint(&file)? != fingerprint {
            return Err("Media identity changed during SHA verification".into());
        }
        if let Ok(mut entries)=cache().lock(){
            if entries.len()>64 {entries.clear();}
            entries.insert(target.path.clone(),(fingerprint,target.sha256.clone()));
        }
    }
    file.seek(SeekFrom::Start(0)).map_err(|_| "Cannot rewind verified media")?;
    Ok(Some(file))
}

pub(super) fn verified_for_episode(
    entry:&PrivateMedia, ep:&PrivateEpisode,
) -> Result<Option<File>,String> {
    if ep.sha256.len()!=64 || ep.size==0 {return Ok(None);}
    let downloads=user_downloads()?;
    let target=target_from(std::slice::from_ref(entry),&entry.id,&ep.id,&downloads,false)?;
    open_verified(&target)
}

fn read_state_at(target:&Target,path:&Path) -> Result<Option<PartialState>,String> {
    no_links(path)?;
    if !path.exists() { return Ok(None); }
    let mut file=read_file(path)?;
    if file.metadata().map_err(|_| "Cannot stat media state")?.len()>MAX_STATE {
        return Err("Media partial state too large".into());
    }
    let mut bytes=Vec::new();
    file.read_to_end(&mut bytes).map_err(|_| "Cannot read media state")?;
    let state:PartialState=serde_json::from_slice(&bytes)
        .map_err(|_| "Unrecognized media partial state; no file will be removed")?;
    if state.schema_version!=1 || state.id!=target.id || state.episode_id!=target.episode_id ||
        state.sha256!=target.sha256 || state.total_bytes!=target.expected ||
        state.verified_bytes>target.expected ||
        state.prefix_sha256.len()!=64 || !state.prefix_sha256.bytes().all(|b|b.is_ascii_hexdigit()) {
        return Err("Media partial belongs to another source or has invalid state".into());
    }
    Ok(Some(state))
}

fn state_stage(path:&Path)->PathBuf {path.with_extension("state.new")}

/// A hard Windows crash skips the cleanup code after fsync of .state.new.
/// This file is ours only when it has the pinned identity AND the current
/// partial bytes prove its exact prefix SHA-256. Never delete an unknown
/// staged state or accept a stage that moves the checkpoint backwards.
fn read_state(target:&Target) -> Result<Option<PartialState>,String> {
    let committed=read_state_at(target,&target.state)?;
    let staged_path=state_stage(&target.state);
    let Some(staged)=read_state_at(target,&staged_path)? else{return Ok(committed);};
    if committed.as_ref().is_some_and(|old|staged.verified_bytes<old.verified_bytes){
        return Err("Media staged checkpoint predates committed state; preserved for review".into());
    }
    let mut file=read_file(&target.partial)?;
    let len=file.metadata().map_err(|_|"Cannot inspect staged media partial")?.len();
    if len<staged.verified_bytes || len>target.expected {
        return Err("Staged media checkpoint length conflicts with partial".into());
    }
    let mut limited=(&mut file).take(staged.verified_bytes);
    let mut digest=Sha256::new();
    // Keep the staged checkpoint reader on heap: transfer uses a large SHA
    // buffer too and Windows Rust worker threads have a small default stack.
    let mut buffer=vec![0u8;64*1024];
    let mut total=0u64;
    loop {
        let count=limited.read(&mut buffer)
            .map_err(|_|"Cannot read staged checkpoint prefix")?;
        if count==0 {break;}
        digest.update(&buffer[..count]);
        total+=count as u64;
    }
    if total!=staged.verified_bytes ||
        format!("{:x}",digest.finalize())!=staged.prefix_sha256 {
        return Err("Staged media checkpoint SHA conflict; preserved for review".into());
    }
    Ok(Some(staged))
}

fn recover_staged_state(target:&Target)->Result<(),String>{
    let staged=state_stage(&target.state);
    if !staged.exists(){return Ok(());}
    // This validates both the stage's manifest identity and its actual bytes.
    // The only existing destination we ever replace is our own validated
    // internal .partial.state, never a finished video or unrelated user file.
    read_state(target)?;
    no_links(&staged)?;no_links(&target.state)?;
    fs::rename(&staged,&target.state)
        .map_err(|_|"Cannot recover fsynced media checkpoint; retry after releasing state lock".into())
}

fn inspect(target:&Target) -> Result<MediaDownloadStatus,String> {
    if target.path.exists() {
        return match open_verified(target) {
            Ok(Some(_)) => Ok(status(target,"verified",target.expected,"downloaded-and-verified")),
            Ok(None) => unreachable!(),
            Err(_) => Ok(status(target,"conflict",0,"existing-file-not-verified")),
        };
    }
    let state=read_state(target)?;
    let partial_exists=target.partial.exists();
    if partial_exists!=state.is_some() {
        return Ok(status(target,"conflict",0,"unrecognized-partial-file"));
    }
    if let Some(state)=state {
        no_links(&target.partial)?;
        let len=fs::metadata(&target.partial).map_err(|_| "Cannot stat media partial")?.len();
        if len<state.verified_bytes || len>target.expected {
            return Ok(status(target,"conflict",len,"partial-size-conflict"));
        }
        return Ok(status(target,"partial",state.verified_bytes,"resumable"));
    }
    Ok(status(target,"missing",0,"not-downloaded"))
}

fn status(target:&Target, state:&'static str, downloaded_bytes:u64, reason:&'static str)
    -> MediaDownloadStatus {
    MediaDownloadStatus {
        id:target.id.clone(), episode_id:target.episode_id.clone(), state,
        downloaded_bytes,total_bytes:target.expected,
        path: if state=="verified" {Some(target.path.display().to_string())} else {None},
        reason,
    }
}

#[cfg(windows)]
fn disk_available(dir:&Path) -> Result<u64,String> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name="kernel32")]
    extern "system" {
        fn GetDiskFreeSpaceExW(path:*const u16, available:*mut u64, total:*mut u64, total_free:*mut u64)->i32;
    }
    let wide:Vec<u16>=dir.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut free=0u64;
    if unsafe {GetDiskFreeSpaceExW(wide.as_ptr(),&mut free,std::ptr::null_mut(),std::ptr::null_mut())}==0 {
        return Err("Cannot verify available disk space".into());
    }
    Ok(free)
}
#[cfg(not(windows))]
fn disk_available(_dir:&Path)->Result<u64,String>{Ok(u64::MAX)}

fn save_state(path:&Path, state:&PartialState) -> Result<(),String> {
    let value=serde_json::to_vec(state).map_err(|_| "Cannot encode media state")?;
    if value.len() as u64 >MAX_STATE{return Err("Media state too large".into());}
    // State is rewritten only inside our private, verified .partial workflow.
    // A staged same-volume rename prevents partially serialized JSON.
    let stage=state_stage(path);
    no_links(&stage)?;
    if stage.exists() {return Err("Foreign media state stage exists".into());}
    {
        let mut file=OpenOptions::new().write(true).create_new(true).open(&stage)
            .map_err(|_| "Cannot create media state stage")?;
        file.write_all(&value).and_then(|_|file.sync_all())
            .map_err(|_| "Cannot persist media state")?;
    }
    // A sharing violation/AV lock can stop this final rename after a durable
    // write. Preserve the stage so a later process can validate/promote it.
    fs::rename(&stage,path).map_err(|_| "Cannot replace media state; verified stage preserved".to_string())
}

#[cfg(not(windows))]
struct DownloadLock {path:PathBuf}
#[cfg(not(windows))]
impl Drop for DownloadLock {
    fn drop(&mut self) {
        let _=fs::remove_file(&self.path); // only our create_new lock
    }
}
#[cfg(not(windows))]
fn create_lock(path:&Path)->Result<DownloadLock,String>{
    no_links(path)?;
    let mut f=OpenOptions::new().write(true).create_new(true).open(path)
        .map_err(|_| "Media download is already locked or has a stale lock")?;
    f.write_all(b"Coco media download lock\n").map_err(|_| "Cannot persist media download lock")?;
    f.sync_all().map_err(|_| "Cannot sync media download lock")?;
    Ok(DownloadLock{path:path.to_path_buf()})
}

#[cfg(windows)]
fn open_partial(path:&Path,existing:bool)->Result<File,String>{
    use std::os::windows::fs::OpenOptionsExt;
    no_links(path)?;
    let mut options=OpenOptions::new();
    options.read(true).write(true).share_mode(0); // kernel lock, auto-released on process exit
    if !existing{options.create_new(true);}
    options.open(path).map_err(|_|"Media partial is locked or unavailable".into())
}
#[cfg(not(windows))]
fn open_partial(path:&Path,existing:bool)->Result<File,String>{
    no_links(path)?;
    let mut options=OpenOptions::new();
    options.read(true).write(true);
    if !existing{options.create_new(true);}
    options.open(path).map_err(|_|"Media partial is locked or unavailable".into())
}

fn make_client(local_fixture:bool)->Result<reqwest::blocking::Client,String>{
    let redirect=reqwest::redirect::Policy::custom(move |attempt|{
        if attempt.previous().len()>=5 || !media::upstream_allowed(attempt.url(),local_fixture){
            attempt.stop()
        }else{attempt.follow()}
    });
    reqwest::blocking::Client::builder().redirect(redirect)
        .connect_timeout(CONNECT_TIMEOUT).timeout(REQUEST_TIMEOUT)
        .pool_max_idle_per_host(0)
        .build().map_err(|_| "Cannot initialize media download TLS client".into())
}

fn retry_wait_ms(attempt:u8,retry_after:Option<&str>,now:time::OffsetDateTime)->u64 {
    let fallback=200u64.saturating_mul(1u64 << attempt.saturating_sub(1).min(3));
    retry_after.and_then(|raw|{
        let raw=raw.trim();
        if let Ok(seconds)=raw.parse::<u64>(){
            return Some(seconds.saturating_mul(1000));
        }
        let deadline=time::OffsetDateTime::parse(raw,&time::format_description::well_known::Rfc2822).ok()?;
        Some((deadline-now).whole_milliseconds().clamp(0,2000) as u64)
    }).unwrap_or(fallback).min(2000)
}

fn retry_wait(attempt:u8,retry_after:Option<&str>,cancel:&AtomicBool)->Result<(),String>{
    let total=retry_wait_ms(attempt,retry_after,time::OffsetDateTime::now_utc());
    let mut waited=0u64;
    while waited<total {
        if cancel.load(Ordering::Acquire){return Err("cancelled".into());}
        let slice=(total-waited).min(50);
        std::thread::sleep(Duration::from_millis(slice));
        waited+=slice;
    }
    if cancel.load(Ordering::Acquire){return Err("cancelled".into());}
    Ok(())
}

#[cfg(test)]
std::thread_local! {
    static TEST_CHUNK_LIMIT:std::cell::Cell<Option<u64>>=const {std::cell::Cell::new(None)};
}
fn media_chunk_size()->u64{
    #[cfg(test)]
    if let Some(size)=TEST_CHUNK_LIMIT.with(|slot|slot.get()){return size;}
    CHUNK
}

fn progress(target:&Target,bytes:u64,phase:&'static str,report:&mut dyn FnMut(MediaDownloadProgress)){
    report(MediaDownloadProgress{
        id:target.id.clone(),episode_id:target.episode_id.clone(),
        downloaded_bytes:bytes,total_bytes:target.expected,
        percent:100.0*(bytes as f64)/(target.expected as f64),phase
    });
}

fn transfer(
    target:&Target, downloads:&Path, cancel:&AtomicBool,
    local_fixture:bool, report:&mut dyn FnMut(MediaDownloadProgress),
) -> Result<MediaDownloadStatus,String> {
    no_links(downloads)?;
    if !downloads.is_dir(){return Err("User Downloads folder does not exist".into());}
    let dir=target.path.parent().ok_or("Invalid media folder")?;
    no_links(dir)?;
    fs::create_dir(dir).or_else(|error|if error.kind()==std::io::ErrorKind::AlreadyExists {Ok(())}else{Err(error)})
        .map_err(|_| "Cannot create media download folder")?;
    no_links(dir)?;
    // On Windows the .partial itself is opened FILE_SHARE_NONE below. This
    // cross-process kernel lock disappears on crash, enabling clean resumes
    // without an orphan .lock file that users would need to remove manually.
    #[cfg(not(windows))]
    let _lock=create_lock(&target.lock)?;
    recover_staged_state(target)?;
    match inspect(target)? {
        value if value.state=="verified" => return Ok(value),
        value if value.state=="conflict" => return Err("Existing media/partial conflicts; refusing overwrite".into()),
        _ => {}
    };
    let mut previous=read_state(target)?;
    let committed=previous.as_ref().map_or(0,|s|s.verified_bytes);
    if disk_available(dir)? < target.expected.saturating_sub(committed).saturating_add(MIN_DISK_MARGIN) {
        return Err("Insufficient free space for verified media download".into());
    }
    let mut partial=open_partial(&target.partial,previous.is_some())?;
    // The partial is mutable and may be truncated during crash recovery. An
    // NTFS hardlink is not a reparse point, so no_links alone cannot prevent
    // these writes from changing a separate, unrelated file. Inspect the
    // opened handle (held exclusively for the entire transfer on Windows).
    if file_fingerprint(&partial)?.links!=1 {
        return Err("Media partial hardlink is shared with another file; refusing writes".into());
    }
    let mut digest=Sha256::new();
    if let Some(state)=&previous {
        let len=partial.metadata().map_err(|_| "Cannot inspect partial")?.len();
        if len<state.verified_bytes || len>target.expected { return Err("Invalid partial size".into()); }
        partial.seek(SeekFrom::Start(0)).map_err(|_| "Cannot read partial prefix")?;
        let mut take=(&mut partial).take(state.verified_bytes);
        let mut buffer=[0u8;1024*1024];
        loop {
            let n=take.read(&mut buffer).map_err(|_| "Cannot verify partial prefix")?;
            if n==0{break;}
            digest.update(&buffer[..n]);
        }
        if format!("{:x}",digest.clone().finalize())!=state.prefix_sha256 {
            return Err("Existing media partial SHA prefix conflict; preserved for review".into());
        }
        if len>state.verified_bytes {
            // Roll back only incomplete bytes of our owned .partial,
            // not any existing completed/user video.
            partial.set_len(state.verified_bytes).map_err(|_| "Cannot roll back unfinished chunk")?;
            partial.sync_all().map_err(|_| "Cannot sync partial rollback")?;
        }
        if state.verified_bytes==target.expected &&
            format!("{:x}",digest.clone().finalize())!=target.sha256 {
            // An HTTP object may have had the correct size and a durable
            // prefix checkpoint yet the WRONG full SHA. Previous releases
            // would retry forever without sending another byte. Only this
            // manifest-owned .partial with a matching prefix may be reset.
            // Commit the zero checkpoint FIRST: a crash before truncation is
            // safely handled by the existing len>verified_bytes rollback.
            let initial=PartialState{
                verified_bytes:0,
                prefix_sha256:format!("{:x}",Sha256::digest([])),
                ..state.clone()
            };
            save_state(&target.state,&initial)?;
            partial.set_len(0).map_err(|_|"Cannot reset bad fully-verified media partial")?;
            partial.sync_all().map_err(|_|"Cannot sync reset media partial")?;
            digest=Sha256::new();
            previous=Some(initial);
        }
    }else{
        let state=PartialState{
            schema_version:1,id:target.id.clone(),episode_id:target.episode_id.clone(),
            sha256:target.sha256.clone(),total_bytes:target.expected,
            verified_bytes:0,prefix_sha256:format!("{:x}",digest.clone().finalize()),
        };
        save_state(&target.state,&state)?;
        previous=Some(state);
    }
    let mut state=previous.ok_or("Media state initialization failed")?;
    let client=make_client(local_fixture)?;
    let mut strong_etag:Option<String>=None;
    progress(target,state.verified_bytes,"downloading",report);
    while state.verified_bytes<target.expected {
        if cancel.load(Ordering::Acquire) {
            progress(target,state.verified_bytes,"cancelled",report);
            return Ok(status(target,"partial",state.verified_bytes,"cancelled"));
        }
        let start=state.verified_bytes;
        let end=(start+media_chunk_size()-1).min(target.expected-1);
        let chunk=end-start+1;
        let mut succeeded=false;
        for attempt in 0..RETRIES {
            if cancel.load(Ordering::Acquire){ break; }
            let request=client.get(target.url.clone())
                .header(reqwest::header::ACCEPT_ENCODING,"identity")
                .header(reqwest::header::RANGE,format!("bytes={start}-{end}"));
            let request=if let Some(ref tag)=strong_etag{
                request.header(reqwest::header::IF_RANGE,tag.as_str())
            }else{request};
            let response=request.send();
            let Ok(mut body)=response else {
                if attempt+1<RETRIES && retry_wait(attempt+1,None,cancel).is_err(){break;}
                continue;
            };
            if !media::upstream_allowed(body.url(),local_fixture) {
                return Err("Media redirect left the trusted HTTPS origin allowlist".into());
            }
            if body.status().is_server_error() ||
                body.status()==reqwest::StatusCode::TOO_MANY_REQUESTS ||
                body.status()==reqwest::StatusCode::REQUEST_TIMEOUT {
                let after=body.headers().get(reqwest::header::RETRY_AFTER)
                    .and_then(|header|header.to_str().ok()).map(str::to_owned);
                drop(body);
                if attempt+1<RETRIES &&
                    retry_wait(attempt+1,after.as_deref(),cancel).is_err(){break;}
                continue;
            }
            // HTTP origins can return repeated Content-Encoding headers. The
            // first "identity" does not make a later "gzip" safe for raw
            // Range bytes. Reject before persisting or publishing any video.
            if body.headers().get(reqwest::header::CONTENT_ENCODING)
                .is_some_and(|header|!header.as_bytes().eq_ignore_ascii_case(b"identity"))
                || body.headers().get_all(reqwest::header::CONTENT_ENCODING).iter()
                    .skip(1).any(|header|!header.as_bytes().eq_ignore_ascii_case(b"identity")){
                return Err("Media Range response used encoded/compressed body".into());
            }
            if body.status()!=reqwest::StatusCode::PARTIAL_CONTENT ||
                body.headers().get(reqwest::header::CONTENT_LENGTH)
                    .and_then(|v|v.to_str().ok()).and_then(|v|v.parse::<u64>().ok())!=Some(chunk) ||
                body.headers().get(reqwest::header::CONTENT_RANGE)
                    .and_then(|v|v.to_str().ok())!=Some(format!("bytes {start}-{end}/{}",target.expected).as_str()){
                return Err("Upstream did not honor exact pinned media byte range".into());
            }
            let tag=body.headers().get(reqwest::header::ETAG)
                .and_then(|value|value.to_str().ok()).map(str::to_owned);
            if let Some(ref prior)=strong_etag {
                if tag.as_ref()!=Some(prior){
                    return Err("Media ETag changed or disappeared between chunks; no publication".into());
                }
            }
            partial.seek(SeekFrom::Start(start)).map_err(|_| "Cannot seek media partial")?;
            let mut n=0u64;
            let mut buffer=[0u8;256*1024];
            let mut next_hash=digest.clone();
            let mut failed=false;
            while n<chunk {
                if cancel.load(Ordering::Acquire) {failed=true;break;}
                let amount=((chunk-n) as usize).min(buffer.len());
                match body.read(&mut buffer[..amount]) {
                    Ok(0)|Err(_) => {failed=true;break;}
                    Ok(count)=>{
                        partial.write_all(&buffer[..count]).map_err(|_| "Cannot write media partial")?;
                        next_hash.update(&buffer[..count]);
                        n+=count as u64;
                    }
                }
            }
            if failed || n!=chunk {
                partial.set_len(start).map_err(|_| "Cannot rewind failed media chunk")?;
                partial.sync_all().map_err(|_| "Cannot sync failed media chunk")?;
                if !cancel.load(Ordering::Acquire)&&attempt+1<RETRIES {
                    if retry_wait(attempt+1,None,cancel).is_err(){break;}
                }
                continue;
            }
            partial.sync_all().map_err(|_| "Cannot sync media chunk")?;
            state.verified_bytes=end+1;
            state.prefix_sha256=format!("{:x}",next_hash.clone().finalize());
            save_state(&target.state,&state)?;
            digest=next_hash;
            // Header inspection alone is not evidence of a completed chunk:
            // an abruptly terminated 206 may carry an obsolete ETag. Pin the
            // strong validator only after durable bytes and checkpoint state.
            if strong_etag.is_none() {
                if let Some(candidate)=tag {
                    if !candidate.starts_with("W/"){strong_etag=Some(candidate);}
                }
            }
            progress(target,state.verified_bytes,"downloading",report);
            succeeded=true;
            break;
        }
        if !succeeded {
            if cancel.load(Ordering::Acquire) {
                progress(target,state.verified_bytes,"cancelled",report);
                return Ok(status(target,"partial",state.verified_bytes,"cancelled"));
            }
            return Err("Media download failed after bounded retries; verified partial preserved".into());
        }
    }
    progress(target,state.verified_bytes,"verifying",report);
    let final_sha=format!("{:x}",digest.finalize());
    if final_sha!=target.sha256 {
        return Err("Full media SHA256 does not match private manifest; partial preserved".into());
    }
    if cancel.load(Ordering::Acquire) {
        progress(target,state.verified_bytes,"cancelled",report);
        return Ok(status(target,"partial",state.verified_bytes,"cancelled"));
    }
    partial.sync_all().map_err(|_| "Cannot sync verified media")?;
    drop(partial);
    no_links(&target.path)?;
    // Hardlink from *same directory* atomically refuses an existing user file
    // on both Windows and Unix, unlike fs::rename on Unix.
    fs::hard_link(&target.partial,&target.path)
        .map_err(|_| "Verified media cannot be committed without overwriting existing user data")?;
    let _=fs::remove_file(&target.partial); // Only this managed .partial is removed.
    let _=fs::remove_file(&target.state);
    progress(target,target.expected,"complete",report);
    Ok(status(target,"verified",target.expected,"downloaded-and-verified"))
}

#[tauri::command]
pub async fn get_media_download_status(
    id:String, episode_id:String,
) -> Result<MediaDownloadStatus,String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (entries,downloads)=target_private()?;
        let target=target_from(&entries,&id,&episode_id,&downloads,false)?;
        inspect(&target)
    }).await.map_err(|_| "Media download status interrupted".to_string())?
}

#[tauri::command]
pub async fn download_media_episode(
    id:String,episode_id:String,app:tauri::AppHandle,state:tauri::State<'_,MediaDownloadState>,
) -> Result<MediaDownloadStatus,String> {
    let key=(id.clone(),episode_id.clone());
    let cancelled=Arc::new(AtomicBool::new(false));
    {
        let mut active=state.active.lock().map_err(|_|"Media downloads unavailable")?;
        if active.contains_key(&key){return Err("Media episode download already running".into());}
        active.insert(key.clone(),Arc::clone(&cancelled));
    }
    let finished=tauri::async_runtime::spawn_blocking(move ||{
        let (entries,downloads)=target_private()?;
        let target=target_from(&entries,&id,&episode_id,&downloads,false)?;
        transfer(&target,&downloads,&cancelled,false,&mut |event| {
            let _=app.emit("coco2://media-download-progress",event);
        })
    }).await;
    if let Ok(mut active)=state.active.lock(){active.remove(&key);}
    finished.map_err(|_|"Media download worker interrupted".to_string())?
}

#[tauri::command]
pub fn cancel_media_download(
    id:String,episode_id:String,state:tauri::State<'_,MediaDownloadState>,
) -> bool {
    let Ok(active)=state.active.lock()else{return false};
    if let Some(flag)=active.get(&(id,episode_id)) {
        flag.store(true,Ordering::Release);
        true
    }else{false}
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize,Ordering};
    use std::thread;
    use std::time::{Duration,Instant,SystemTime,UNIX_EPOCH};
    static SERIAL:AtomicUsize=AtomicUsize::new(0);

    struct Fixture {root:PathBuf}
    impl Fixture {
        fn new()->Self {
            let marker=format!("coco-media-test-{}-{}-{}",
                std::process::id(),
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(),
                SERIAL.fetch_add(1,Ordering::Relaxed));
            let root=std::env::temp_dir().join(marker);
            fs::create_dir(&root).unwrap();
            Self{root}
        }
        fn target(&self,origin:&str,bytes:&[u8])->Target {
            self.target_named(origin,bytes,"episode.mp4")
        }
        fn target_named(&self,origin:&str,bytes:&[u8],file_name:&str)->Target {
            let json=serde_json::json!([{
                "id":"fixture","name":"Fixture","type":"movie",
                "episodes":[{"id":"one","title":"One","fileName":file_name,
                    "streamUrl":origin,"sourceUrl":origin,
                    "size":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))}]
            }]);
            let entries:Vec<PrivateMedia>=serde_json::from_value(json).unwrap();
            target_from(&entries,"fixture","one",&self.root,true).unwrap()
        }
    }
    impl Drop for Fixture{
        fn drop(&mut self){
            // Tests own only this unique directory under std::env::temp_dir.
            let _=fs::remove_dir_all(&self.root);
        }
    }

    fn local_http(bytes:Vec<u8>, malformed:bool) -> (String,Arc<AtomicBool>,Arc<Mutex<Vec<String>>>,thread::JoinHandle<()>) {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let origin=format!("http://127.0.0.1:{}/fixture",listener.local_addr().unwrap().port());
        let stop=Arc::new(AtomicBool::new(false));
        let seen=Arc::new(Mutex::new(Vec::new()));
        let stop_worker=Arc::clone(&stop);
        let seen_worker=Arc::clone(&seen);
        let handle=thread::spawn(move ||{
            let started=Instant::now();
            while !stop_worker.load(Ordering::Acquire) && started.elapsed()<Duration::from_secs(6){
                match listener.accept() {
                    Ok((mut socket,_))=>{
                        let _=socket.set_read_timeout(Some(Duration::from_millis(500)));
                        let mut raw=Vec::new();
                        let mut byte=[0u8;1];
                        while raw.len()<8192 && !raw.ends_with(b"\r\n\r\n") {
                            if socket.read_exact(&mut byte).is_err(){break;}
                            raw.push(byte[0]);
                        }
                        let request=String::from_utf8_lossy(&raw);
                        let range=request.lines().find(|l|l.to_ascii_lowercase().starts_with("range:"))
                            .and_then(|s|s.split_once(':')).map(|(_,s)|s.trim().to_string());
                        if let Some(range)=range.as_ref(){seen_worker.lock().unwrap().push(range.clone());}
                        let Some(range)=range else{continue};
                        let Some((a,b))=range.strip_prefix("bytes=").and_then(|r|r.split_once('-'))else{continue};
                        let Ok(start)=a.parse::<usize>()else{continue};
                        let Ok(end)=b.parse::<usize>()else{continue};
                        if start>=bytes.len() || end>=bytes.len()||end<start{continue;}
                        let part=&bytes[start..=end];
                        let status=if malformed{200}else{206};
                        let header=format!(
                            "HTTP/1.1 {status} TEST\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nConnection: close\r\n\r\n",
                            part.len(),bytes.len());
                        let _=socket.write_all(header.as_bytes());
                        let _=socket.write_all(part);
                    }
                    Err(error) if error.kind()==std::io::ErrorKind::WouldBlock =>
                        thread::sleep(Duration::from_millis(5)),
                    Err(_)=>break,
                }
            }
        });
        (origin,stop,seen,handle)
    }

    fn with_test_chunk<T>(bytes:u64,run:impl FnOnce()->T)->T {
        TEST_CHUNK_LIMIT.with(|slot|slot.set(Some(bytes)));
        struct Reset;
        impl Drop for Reset {
            fn drop(&mut self){TEST_CHUNK_LIMIT.with(|slot|slot.set(None));}
        }
        let _reset=Reset;
        run()
    }

    /// Deterministic bounded local HTTP server; no real video or external host.
    /// Responses simulate 429/503, changed ETag, wrong bytes, or abrupt TCP EOF.
    fn local_v13_http(bytes:Vec<u8>,mode:&'static str,bad:Arc<AtomicBool>)
        ->(String,Arc<AtomicBool>,Arc<Mutex<Vec<String>>>,thread::JoinHandle<()>){
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url=format!("http://127.0.0.1:{}/v13",listener.local_addr().unwrap().port());
        let stop=Arc::new(AtomicBool::new(false));
        let seen=Arc::new(Mutex::new(Vec::new()));
        let stopped=Arc::clone(&stop);
        let requests=Arc::clone(&seen);
        let worker=thread::spawn(move||{
            let started=Instant::now();
            while !stopped.load(Ordering::Acquire)&&started.elapsed()<Duration::from_secs(12) {
                let (mut socket,_)=match listener.accept(){
                    Ok(value)=>value,
                    Err(error) if error.kind()==std::io::ErrorKind::WouldBlock=>{
                        thread::sleep(Duration::from_millis(5));continue;
                    },
                    Err(error)=>panic!("v13 loopback listener: {error}"),
                };
                socket.set_nonblocking(false).unwrap();
                socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut headers=Vec::new();
                while !headers.windows(4).any(|window|window==b"\r\n\r\n"){
                    let mut chunk=[0u8;1024];
                    let n=socket.read(&mut chunk).unwrap();
                    assert!(n>0&&headers.len()<8192,"complete local Range request required");
                    headers.extend_from_slice(&chunk[..n]);
                }
                let request=String::from_utf8(headers).unwrap();
                let range=request.lines().find(|line|line.to_ascii_lowercase().starts_with("range:"))
                    .and_then(|line|line.split_once(':')).map(|(_,value)|value.trim().to_string())
                    .expect("real HTTP Range must be present");
                let (start,end)=range.strip_prefix("bytes=").unwrap().split_once('-').unwrap();
                let start=start.parse::<usize>().unwrap();
                let end=end.parse::<usize>().unwrap();
                let ordinal={
                    let mut log=requests.lock().unwrap();
                    log.push(request.clone());
                    log.len()
                };
                if mode=="retry"&&ordinal<=2 {
                    let status=if ordinal==1{"429 Too Many Requests"}else{"503 Service Unavailable"};
                    let message=format!("HTTP/1.1 {status}\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    socket.write_all(message.as_bytes()).unwrap();
                    continue;
                }
                if mode=="always-416" {
                    socket.write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                    continue;
                }
                assert!(end<bytes.len()&&start<=end);
                let mut content=bytes[start..=end].to_vec();
                if mode=="bad-then-good"&&bad.load(Ordering::Acquire) {
                    content[0]^=0x55;
                }
                let etag=if mode=="etag-switch"&&ordinal>1{"\"changed\""}
                    else if mode=="truncated-etag-before-checkpoint"&&ordinal==1{"\"stale\""}
                    else{"\"stable\""};
                let encoding=if mode=="duplicate-content-encoding-v29"{
                    "Content-Encoding: identity\r\nContent-Encoding: gzip\r\n"
                }else{""};
                let message=format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\n{encoding}ETag: {etag}\r\nConnection: close\r\n\r\n",
                    content.len(),bytes.len());
                socket.write_all(message.as_bytes()).unwrap();
                if (mode=="reset-once"||mode=="truncated-etag-before-checkpoint")&&ordinal==1 {
                    let _=socket.write_all(&content[..content.len()/2]);
                }else{
                    let _=socket.write_all(&content);
                }
            }
        });
        (url,stop,seen,worker)
    }

    #[test]
    fn crash_between_state_sync_and_rename_recovers_verified_unicode_checkpoint(){
        let bytes=b"this is verified test-owned offline media content".to_vec();
        let (url,stop,requests,server)=local_v13_http(bytes.clone(),"normal",
            Arc::new(AtomicBool::new(false)));
        let f=Fixture::new();
        let target=f.target_named(&url,&bytes,"vídeo 漢字.mp4");
        fs::create_dir(target.path.parent().unwrap()).unwrap();
        fs::write(&target.partial,&bytes[..15]).unwrap();
        let initial=PartialState{
            schema_version:1,id:target.id.clone(),episode_id:target.episode_id.clone(),
            sha256:target.sha256.clone(),total_bytes:bytes.len() as u64,
            verified_bytes:0,prefix_sha256:format!("{:x}",Sha256::digest([])),
        };
        save_state(&target.state,&initial).unwrap();
        let advanced=PartialState{
            verified_bytes:15,
            prefix_sha256:format!("{:x}",Sha256::digest(&bytes[..15])),
            ..initial.clone()
        };
        // Simulates hard-crash AFTER fsync of next state, BEFORE atomic rename.
        let staged=state_stage(&target.state);
        fs::write(&staged,serde_json::to_vec(&advanced).unwrap()).unwrap();
        OpenOptions::new().read(true).write(true).open(&staged).unwrap().sync_all().unwrap();
        assert_eq!(inspect(&target).unwrap().downloaded_bytes,15,
            "read-only status must recognize a verified durable staged checkpoint");
        let status=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}).unwrap();
        assert_eq!(status.state,"verified");
        assert_eq!(fs::read(&target.path).unwrap(),bytes);
        assert!(!staged.exists());
        assert_eq!(requests.lock().unwrap().len(),1);
        assert!(requests.lock().unwrap()[0].to_ascii_lowercase().contains("range: bytes=15-"));
        stop.store(true,Ordering::Release);
        server.join().unwrap();
    }

    #[test]
    fn foreign_or_tampered_state_stage_never_overwrites_committed_state_or_media(){
        let bytes=b"private verified media bytes".to_vec();
        let f=Fixture::new();
        let target=f.target("http://127.0.0.1:44555/no-contact",&bytes);
        fs::create_dir(target.path.parent().unwrap()).unwrap();
        fs::write(&target.partial,&bytes[..8]).unwrap();
        let original=PartialState{
            schema_version:1,id:target.id.clone(),episode_id:target.episode_id.clone(),
            sha256:target.sha256.clone(),total_bytes:bytes.len() as u64,
            verified_bytes:0,prefix_sha256:format!("{:x}",Sha256::digest([])),
        };
        save_state(&target.state,&original).unwrap();
        let old=fs::read(&target.state).unwrap();
        let foreign=PartialState{verified_bytes:8,prefix_sha256:"0".repeat(64),..original};
        let staged=state_stage(&target.state);
        fs::write(&staged,serde_json::to_vec(&foreign).unwrap()).unwrap();
        assert!(transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}).is_err());
        assert_eq!(fs::read(&target.state).unwrap(),old);
        assert!(staged.exists(),"foreign stage must not be removed");
        assert_eq!(fs::read(&target.partial).unwrap(),bytes[..8]);
        assert!(!target.path.exists());
    }

    #[test]
    fn fully_checkpointed_wrong_sha_recovers_next_invocation_without_user_overwrite(){
        let bytes=b"verified media bytes for complete offline episode".to_vec();
        let bad=Arc::new(AtomicBool::new(true));
        let (url,stop,requests,server)=local_v13_http(bytes.clone(),"bad-then-good",Arc::clone(&bad));
        let f=Fixture::new();
        let target=f.target(&url,&bytes);
        let first=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{});
        assert!(first.unwrap_err().contains("Full media SHA256"));
        assert!(!target.path.exists());
        assert_eq!(fs::metadata(&target.partial).unwrap().len(),bytes.len() as u64);
        assert_eq!(read_state(&target).unwrap().unwrap().verified_bytes,bytes.len() as u64);
        bad.store(false,Ordering::Release);
        let second=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}).unwrap();
        assert_eq!(second.state,"verified");
        assert_eq!(fs::read(&target.path).unwrap(),bytes);
        assert!(requests.lock().unwrap().iter()
            .filter(|request|request.to_ascii_lowercase().contains("range: bytes=0-")).count()>=2,
            "retry must actually redownload from byte zero instead of reusing bad full SHA");
        stop.store(true,Ordering::Release);
        server.join().unwrap();
    }

    #[test]
    fn rate_limits_retries_then_etag_switch_and_connection_reset_fail_safe(){
        let bytes=b"HTTP v13 bounded retry with different ETags and reset".to_vec();
        assert_eq!(retry_wait_ms(1,Some("2"),time::OffsetDateTime::now_utc()),2000);
        let now=time::OffsetDateTime::from_unix_timestamp(1_900_000_000).unwrap();
        let future=(now+time::Duration::seconds(8))
            .format(&time::format_description::well_known::Rfc2822).unwrap();
        assert_eq!(retry_wait_ms(1,Some(&future),now),2000);
        assert_eq!(retry_wait_ms(1,Some("0"),now),0);
        assert_eq!(retry_wait_ms(2,Some("garbled"),now),400);
        assert_eq!(retry_wait(1,Some("2"),&AtomicBool::new(true)).unwrap_err(),"cancelled");
        for mode in ["retry","etag-switch","reset-once","always-416"] {
            let (url,stop,requests,server)=local_v13_http(bytes.clone(),mode,
                Arc::new(AtomicBool::new(false)));
            let f=Fixture::new();
            let target=f.target(&url,&bytes);
            let result=with_test_chunk(15,||transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}));
            let req=requests.lock().unwrap().clone();
            stop.store(true,Ordering::Release);
            server.join().unwrap();
            if mode=="etag-switch" {
                assert!(result.unwrap_err().contains("ETag changed"));
                assert!(!target.path.exists());
                assert_eq!(read_state(&target).unwrap().unwrap().verified_bytes,15);
                assert!(req[1].contains("if-range: \"stable\"")||
                    req[1].contains("If-Range: \"stable\""),"must send prior strong ETag");
            }else if mode=="always-416" {
                assert!(result.is_err());
                assert!(!target.path.exists());
                assert_eq!(req.len(),1,"HTTP 416 must not be retried as a transient error");
            }else{
                assert_eq!(result.unwrap().state,"verified","{mode}");
                assert_eq!(fs::read(&target.path).unwrap(),bytes);
                assert!(req.len()>=2,"{mode} expected multiple loopback Range requests");
            }
            if mode=="retry" {assert!(req.len()>=5,"429 and 503 must retry boundedly");}
            if mode=="reset-once" {assert!(req.len()>3,"TCP reset must retry the missing first chunk");}
        }
    }

    #[test]
    fn interrupted_first_chunk_does_not_pin_uncommitted_etag_on_retry(){
        let bytes=b"Pinned offline media with a short first 206 and valid retry".to_vec();
        let (url,stop,requests,server)=local_v13_http(bytes.clone(),
            "truncated-etag-before-checkpoint",Arc::new(AtomicBool::new(false)));
        let f=Fixture::new();
        let target=f.target(&url,&bytes);
        let result=with_test_chunk(17,||transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}));
        let seen=requests.lock().unwrap().clone();
        stop.store(true,Ordering::Release);
        server.join().unwrap();
        assert_eq!(result.unwrap().state,"verified");
        assert_eq!(fs::read(&target.path).unwrap(),bytes);
        assert!(seen.len()>=3);
        assert!(seen[0].to_ascii_lowercase().contains("range: bytes=0-16"));
        assert!(seen[1].to_ascii_lowercase().contains("range: bytes=0-16"));
        assert!(!seen[1].to_ascii_lowercase().contains("if-range:"),
            "no completed chunk means no trusted ETag to send on retry");
        assert!(seen[2].to_ascii_lowercase().contains("if-range: \"stable\""),
            "the first durable checkpoint may pin its strong ETag");
    }

    #[test]
    fn v29_duplicate_content_encoding_must_not_publish_offline_video(){
        let bytes=b"v29 offline playback bytes must never pass a contradictory encoded 206".to_vec();
        let (url,stop,requests,server)=local_v13_http(bytes.clone(),
            "duplicate-content-encoding-v29",Arc::new(AtomicBool::new(false)));
        let f=Fixture::new();
        let target=f.target_named(&url,&bytes,"media 漢字.mp4");
        let result=with_test_chunk(bytes.len() as u64,||
            transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}));
        let seen=requests.lock().unwrap().clone();
        stop.store(true,Ordering::Release);
        server.join().unwrap();
        assert!(result.as_ref().is_err_and(|error|error.contains("encoded/compressed")),
            "first identity and second gzip must be rejected before SHA publication: {result:?}");
        assert_eq!(seen.len(),1,"contradictory 206 must be rejected without retry");
        assert!(!target.path.exists(),"no final offline video may be published");
        assert_eq!(fs::metadata(&target.partial).unwrap().len(),0,
            "no bytes of an invalid HTTP representation may reach .partial");
        assert_eq!(read_state(&target).unwrap().unwrap().verified_bytes,0);
    }

    #[test]
    fn unsafe_names_and_untrusted_sources_fail_closed() {
        for name in ["../escape.mp4","../a","a/b.mp4","a\\b.mp4","con.mp4",
            "COM1.mkv","file.mp4.","file.mp4 ",".hidden.mp4","foo:stream.mp4",
            "x\n.mp4",""] {
            assert!(!safe_file_name(name),"accepted: {name}");
        }
        for name in ["My Movie - 1.mp4","episode_2.webm","file.mkv","mickey 17"] {
            assert!(safe_file_name(name));
        }
        let f=Fixture::new();
        let target=f.target("http://127.0.0.1:44000/test",b"video");
        assert_eq!(target.path.file_name().unwrap(),"episode.mp4");
        assert!(target.path.starts_with(&f.root));
        let bad=serde_json::json!([{
            "id":"demo","name":"Demo","type":"movie",
            "episodes":[{"id":"p1","title":"p","fileName":"a.mp4",
                "streamUrl":"https://evil.example/media.mp4",
                "size":5,"sha256":"a".repeat(64)}]
        }]);
        let entries:Vec<PrivateMedia>=serde_json::from_value(bad).unwrap();
        assert!(target_from(&entries,"demo","p1",&f.root,false).is_err());
    }

    #[test]
    fn fixture_download_cancellation_and_resume_with_sha_and_ranges() {
        let bytes=vec![b'x';400*1024];
        let (url,stop,requests,server)=local_http(bytes.clone(),false);
        let f=Fixture::new();
        let target=f.target(&url,&bytes);
        let dir=target.path.parent().unwrap();
        let cancel=AtomicBool::new(true);
        let mut events=Vec::new();
        let first=transfer(&target,&f.root,&cancel,true,&mut |ev|events.push(ev)).unwrap();
        assert_eq!(first.state,"partial");
        assert!(target.partial.exists() && target.state.exists());
        assert!(!target.path.exists());
        assert_eq!(first.downloaded_bytes,0);
        cancel.store(false,Ordering::Release);
        let resumed=transfer(&target,&f.root,&cancel,true,&mut |ev|events.push(ev)).unwrap();
        assert_eq!(resumed.state,"verified");
        assert_eq!(fs::read(&target.path).unwrap(),bytes);
        assert!(!target.partial.exists());
        assert_eq!(requests.lock().unwrap().as_slice(),["bytes=0-409599"]);
        assert_eq!(inspect(&target).unwrap().state,"verified");
        assert!(events.iter().any(|e|e.phase=="complete" && e.percent==100.0));
        stop.store(true,Ordering::Release);
        server.join().unwrap();
        assert!(dir.exists());
    }

    #[test]
    fn verified_partial_resumes_exact_suffix_and_preserves_corrupt_user_file() {
        let bytes=b"abcdefghijklmnopqrstuvwx".to_vec();
        let (url,stop,requests,server)=local_http(bytes.clone(),false);
        let f=Fixture::new();
        let target=f.target(&url,&bytes);
        fs::create_dir(target.path.parent().unwrap()).unwrap();
        fs::write(&target.partial,&bytes[..10]).unwrap();
        let state=PartialState{
            schema_version:1,id:target.id.clone(),episode_id:target.episode_id.clone(),
            sha256:target.sha256.clone(),total_bytes:bytes.len() as u64,
            verified_bytes:10,prefix_sha256:format!("{:x}",Sha256::digest(&bytes[..10])),
        };
        save_state(&target.state,&state).unwrap();
        let result=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}).unwrap();
        assert_eq!(result.state,"verified");
        assert_eq!(requests.lock().unwrap().as_slice(),["bytes=10-23"]);
        fs::write(&target.path,b"corrupted").unwrap();
        assert_eq!(inspect(&target).unwrap().state,"conflict");
        assert!(transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}).is_err());
        assert_eq!(fs::read(&target.path).unwrap(),b"corrupted");
        stop.store(true,Ordering::Release);
        server.join().unwrap();
    }

    #[test]
    fn wrong_partial_digest_and_forged_range_preserve_all_user_data() {
        let bytes=b"real legitimate media payload".to_vec();
        let f=Fixture::new();
        let target=f.target("http://127.0.0.1:44000/fake",&bytes);
        fs::create_dir(target.path.parent().unwrap()).unwrap();
        fs::write(&target.partial,b"WRONG").unwrap();
        save_state(&target.state,&PartialState {
            schema_version:1,id:target.id.clone(),episode_id:target.episode_id.clone(),
            sha256:target.sha256.clone(),total_bytes:bytes.len() as u64,
            verified_bytes:5,prefix_sha256:format!("{:x}",Sha256::digest(b"right")),
        }).unwrap();
        assert!(transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{}).is_err());
        assert_eq!(fs::read(&target.partial).unwrap(),b"WRONG");
        assert!(!target.path.exists());
        let (url,stop,requests,server)=local_http(bytes.clone(),true);
        let f2=Fixture::new();
        let target2=f2.target(&url,&bytes);
        assert!(transfer(&target2,&f2.root,&AtomicBool::new(false),true,&mut |_|{}).is_err());
        assert!(target2.partial.exists() && target2.state.exists());
        assert!(!target2.path.exists());
        assert!(!requests.lock().unwrap().is_empty());
        stop.store(true,Ordering::Release);
        server.join().unwrap();
    }

    #[test]
    fn existing_target_is_never_overwritten_even_if_download_is_ready() {
        let f=Fixture::new();
        let target=f.target("http://127.0.0.1:44000/fixture",b"correct");
        fs::create_dir(target.path.parent().unwrap()).unwrap();
        fs::write(&target.path,b"unrelated existing file").unwrap();
        let result=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{});
        assert!(result.is_err());
        assert_eq!(fs::read(&target.path).unwrap(),b"unrelated existing file");
        assert!(!target.partial.exists());
    }

    #[test]
    fn hardlinked_partial_never_truncates_unrelated_file_or_publishes_it() {
        for fully_checkpointed in [false,true] {
            let bytes=b"test-owned private media payload";
            let f=Fixture::new();
            let target=f.target("http://127.0.0.1:44555/no-contact",bytes);
            fs::create_dir(target.path.parent().unwrap()).unwrap();
            let unrelated=f.root.join("unrelated-original.bin");
            fs::write(&unrelated,bytes).unwrap();
            // An NTFS hardlink is not a reparse point. The partial path still
            // looks like a normal file but writes/truncation affect this file.
            fs::hard_link(&unrelated,&target.partial).unwrap();
            let verified=if fully_checkpointed{bytes.len() as u64}else{0};
            save_state(&target.state,&PartialState {
                schema_version:1,id:target.id.clone(),episode_id:target.episode_id.clone(),
                sha256:target.sha256.clone(),total_bytes:bytes.len() as u64,
                verified_bytes:verified,
                prefix_sha256:format!("{:x}",Sha256::digest(&bytes[..verified as usize])),
            }).unwrap();
            let result=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{});
            assert_eq!(fs::read(&unrelated).unwrap(),bytes,
                "unrelated file content must be untouched");
            assert_eq!(fs::read(&target.partial).unwrap(),bytes);
            assert!(!target.path.exists());
            assert!(result.as_ref().is_err_and(|error|error.contains("hardlink")),
                "reject shared .partial before truncation, downloading or publication: {result:?}");
        }
    }

    #[test]
    fn different_full_payload_with_correct_range_and_length_fails_sha() {
        let expected=b"the real pinned content".to_vec();
        let forged=b"the real pinned contenT".to_vec();
        assert_eq!(expected.len(),forged.len());
        let (url,stop,requests,server)=local_http(forged,false);
        let f=Fixture::new();
        let target=f.target(&url,&expected);
        let result=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{});
        assert!(result.unwrap_err().contains("SHA256"));
        assert!(!target.path.exists());
        assert_eq!(fs::read(&target.partial).unwrap(),b"the real pinned contenT");
        assert_eq!(requests.lock().unwrap().len(),1);
        stop.store(true,Ordering::Release);
        server.join().unwrap();
    }

    #[test]
    fn redirect_to_untrusted_origin_never_follows_or_commits() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url=format!("http://127.0.0.1:{}/fixture",listener.local_addr().unwrap().port());
        let handler=thread::spawn(move ||{
            let started=Instant::now();
            while started.elapsed()<Duration::from_secs(2){
                match listener.accept(){
                    Ok((mut socket,_))=>{
                        let mut buf=[0u8;4096];
                        let _=socket.set_read_timeout(Some(Duration::from_secs(1)));
                        let _=socket.read(&mut buf);
                        let _=socket.write_all(
                            b"HTTP/1.1 302 Found\r\nLocation: http://evil.invalid/media.mp4\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        break;
                    }
                    Err(e)if e.kind()==std::io::ErrorKind::WouldBlock=>
                        thread::sleep(Duration::from_millis(5)),
                    Err(_)=>break
                }
            }
        });
        let f=Fixture::new();
        let target=f.target(&url,b"expected bytes");
        let result=transfer(&target,&f.root,&AtomicBool::new(false),true,&mut |_|{});
        assert!(result.is_err());
        assert!(!target.path.exists());
        assert!(target.partial.exists());
        handler.join().unwrap();
    }
}
