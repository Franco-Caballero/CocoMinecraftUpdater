//! User-scoped, content-addressed catalog snapshots and offline/Ed25519 channel intake.
//! Snapshots are verified on every read; old snapshots form a hash-linked
//! immutable history for transactional installation of earlier pack versions.
use super::{Experience, RequiredFile};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap,HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
#[path="catalog_portable.rs"]
mod portable;

const MAX_METADATA: u64 = 3 * 1024 * 1024;
const MAX_COVER: u64 = 4 * 1024 * 1024;
const MAX_SNAPSHOT: u64 = 32 * 1024 * 1024;
const MAX_ENTRIES: usize = 100;
const MAX_ARCHIVE: u64 = 128 * 1024 * 1024 * 1024;
const OFFICIAL_CATALOG: &str = "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/coco2-channel/coco2-catalog-channel.json";
const OFFICIAL_SIGNATURE: &str = "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/coco2-channel/coco2-catalog-channel.json.sig";
static CATALOG_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalPublishReview {
    pub id: String,
    pub mode: String,
    pub old_version: Option<String>,
    pub new_version: String,
    pub archive_sha256: String,
    pub manifest_sha256: String,
    pub review_token: String,
    pub source_path: String,
    pub status: &'static str,
    pub name: String,
    pub description: String,
    pub cover_data_url: String,
    pub executable: String,
    pub required_files_count: usize,
    pub changed_fields: Vec<String>,
    #[serde(skip_serializing_if="Option::is_none")]
    pub portable_sha256: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogChannelStatus {
    pub status: &'static str,
    pub revision: u64,
    pub local_entries: usize,
    pub remote_entries: usize,
    pub remote_sequence: u64,
    pub message: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UnsignedCatalogChannelDraft {
    pub id: String,
    pub sequence: u64,
    pub entries: usize,
    pub channel_draft_path: String,
    pub signature_path: String,
    pub channel_sha256: String,
    pub source_manifest_sha256: String,
    pub release_catalog_url: String,
    pub release_signature_url: String,
    pub status: &'static str,
    pub review_note: String,
    pub publication_assets: Vec<PublicationAsset>,
    pub ready_for_signature: bool,
    pub archive_path: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicationAsset {
    pub name: String,
    pub local_path: String,
    pub expected_url: String,
    pub sha256: String,
    pub size: u64,
    pub uploaded: bool,
}

/// A read-only, evidence-based delivery report. The offline command never
/// connects to GitHub, and a present signature is not necessarily trusted.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelDeliveryReview {
    pub id: String,
    pub sequence: u64,
    pub draft_path: String,
    pub channel_sha256: String,
    pub source_snapshot_sha256: Option<String>,
    pub provenance: String,
    pub status: &'static str,
    pub signature_trusted: bool,
    pub ready_for_signature: bool,
    pub ready_for_upload: bool,
    pub all_remote_verified: bool,
    pub remote_checked: bool,
    pub assets: Vec<DeliveryAssetReview>,
    pub issues: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryAssetReview {
    pub name: String,
    pub expected_url: String,
    pub expected_sha256: Option<String>,
    pub expected_size: Option<u64>,
    pub present_local: bool,
    pub verified_local: bool,
    pub remote_available: bool,
    pub message: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeliveryLock {
    schema_version: u32,
    id: String,
    sequence: u64,
    source_snapshot_sha256: Option<String>,
    channel_sha256: String,
    channel_size: u64,
    archive_name: String,
    archive_sha256: String,
    archive_size: u64,
    archive_url: String,
    source_manifest_sha256: String,
    cover_sha256: String,
    entry_count: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogProvenance {
    pub id: String,
    pub source: &'static str,
    pub version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Accepted {
    source: String,
    version: String,
    entry: Experience,
    manifest: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    schema_version: u32,
    revision: u64,
    previous_sha256: Option<String>,
    remote_sequence: u64,
    #[serde(default)]
    remote_digest: Option<String>,
    entries: Vec<Accepted>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Pointer { schema_version: u32, sha256: String }

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemoteChannel {
    schema_version: u32,
    sequence: u64,
    entries: Vec<Accepted>,
    #[serde(default)]
    promotions: Vec<SignedPromotion>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SignedPromotion {
    id: String,
    previous_local_version: String,
    new_remote_version: String,
    previous_local_manifest_sha256: String,
    previous_local_entry_sha256: String,
}

fn hash(bytes: &[u8]) -> String { format!("{:x}", Sha256::digest(bytes)) }
fn valid_sha(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}
fn valid_id(s: &str) -> bool {
    (2..=48).contains(&s.len()) && s.as_bytes()[0].is_ascii_lowercase()
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !s.ends_with('-')
}
fn guarded_path(path: &Path) -> Result<(), String> {
    for part in path.ancestors() {
        match fs::symlink_metadata(part) {
            Ok(meta) => {
                if meta.file_type().is_symlink() { return Err("Symbolic-link catalog path refused".into()); }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if meta.file_attributes() & 0x400 != 0 {
                        return Err("Windows reparse-point catalog path refused".into());
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("Cannot inspect catalog path: {e}")),
        }
    }
    Ok(())
}
fn read_bounded(path: &Path, max: u64) -> Result<Vec<u8>, String> {
    guarded_path(path)?;
    let source = File::open(path).map_err(|e| format!("Cannot open {}: {e}",path.display()))?;
    if source.metadata().map_err(|e| e.to_string())?.len() > max {
        return Err("Catalog content exceeds size limit".into());
    }
    let mut data = Vec::new();
    source.take(max + 1).read_to_end(&mut data).map_err(|e| e.to_string())?;
    if data.len() as u64 > max { return Err("Catalog content exceeds size limit".into()); }
    Ok(data)
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    guarded_path(path)?;
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)
        .map_err(|e| format!("Cannot create immutable catalog file {}: {e}",path.display()))?;
    file.write_all(bytes).and_then(|_| file.sync_all()).map_err(|e| e.to_string())
}
fn cache_dir() -> Result<PathBuf, String> {
    let base = std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA unavailable")?;
    let base = PathBuf::from(base);
    if !base.is_absolute() { return Err("Invalid user cache root".into()); }
    Ok(base.join("CocoLauncher2").join("catalog-channel"))
}
fn package_cache() -> Result<PathBuf,String> {
    let base = std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA unavailable")?;
    Ok(PathBuf::from(base).join("CocoMinecraftUpdater")
        .join("downloads").join("standalone-packs"))
}
fn snapshot_path(dir: &Path, sha: &str) -> PathBuf { dir.join(format!("snapshot-{sha}.json")) }

fn empty() -> Snapshot {
    Snapshot { schema_version:1, revision:0, previous_sha256:None, remote_sequence:0, remote_digest:None, entries:vec![] }
}

fn valid_relative_file(value: &str) -> bool {
    !value.is_empty() && value.len() <= 1024 && !value.starts_with('/')
        && !value.contains(['\\', ':']) && value.split('/').all(|part|
            !part.is_empty() && part != "." && part != ".." && !part.ends_with('.')
            && !part.ends_with(' ') && !part.chars().any(|c| c.is_control() || "<>\"|?*".contains(c))
            && !matches!(part.to_ascii_lowercase().as_str(),
                "saves"|"playerdata"|"advancements"|"stats"|"distanthorizons"|"dh")
            && {
                let stem=part.split('.').next().unwrap_or("").to_ascii_uppercase();
                !matches!(stem.as_str(),"CON"|"PRN"|"AUX"|"NUL")
                    && !(stem.len()==4 && (stem.starts_with("COM")||stem.starts_with("LPT"))
                        && matches!(stem.as_bytes()[3],b'1'..=b'9'))
            })
}

fn version_parts(value: &str) -> Result<Vec<u64>,String> {
    if value.is_empty() || value.len()>96 {return Err("Invalid version".into());}
    let parts:Vec<_>=value.split('.').collect();
    if parts.len()>8 || parts.iter().any(|p|p.is_empty()||p.len()>18||!p.bytes().all(|b|b.is_ascii_digit())) {
        return Err("Unorderable version: use numeric dotted versions".into());
    }
    parts.iter().map(|v|v.parse::<u64>().map_err(|_|"Version overflow".into())).collect()
}
fn strictly_newer(next: &str, prior: &str) -> Result<bool,String> {
    let a=version_parts(next)?;
    let b=version_parts(prior)?;
    Ok((0..a.len().max(b.len())).map(|i|
        a.get(i).copied().unwrap_or(0).cmp(&b.get(i).copied().unwrap_or(0))
    ).find(|x|*x!=std::cmp::Ordering::Equal)==Some(std::cmp::Ordering::Greater))
}
fn safe_official_archive_url(value: &str) -> bool {
    let Ok(url)=reqwest::Url::parse(value) else{return false};
    if url.scheme()!="https" || url.port_or_known_default()!=Some(443)
        || !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some()
        || !url.path().to_ascii_lowercase().ends_with(".zip") {return false;}
    match url.host_str() {
        Some("github.com") => {
            let components:Vec<_>=url.path().split('/').filter(|p|!p.is_empty()).collect();
            components.len()>=6 && components[2]=="releases" && components[3]=="download"
                && components[..2].iter().all(|p|p.bytes().all(|c|
                    c.is_ascii_alphanumeric() || c==b'-' || c==b'_' || c==b'.'))
        },
        _=>false,
    }
}
fn owned_official_archive_url(value: &str) -> bool {
    let Ok(url)=reqwest::Url::parse(value) else{return false};
    safe_official_archive_url(value)
        && url.host_str()==Some("github.com")
        && url.path().starts_with("/Franco-Caballero/CocoMinecraftUpdater/releases/download/")
}
fn previous_promotion(old:&Accepted,new:&Accepted)->Result<SignedPromotion,String>{
    if old.source!="local" || new.source!="remote" || old.entry.id!=new.entry.id
        || old.entry.instance_id!=new.entry.instance_id
        || !(old.version==new.version || strictly_newer(&new.version,&old.version)?) {
        return Err("Local-to-official transition has invalid identity or version".into());
    }
    if old.version==new.version && (old.entry!=new.entry || old.manifest!=new.manifest) {
        return Err("Signed promotion at same version must preserve exact local content".into());
    }
    Ok(SignedPromotion {
        id:old.entry.id.clone(),previous_local_version:old.version.clone(),
        new_remote_version:new.version.clone(),
        previous_local_manifest_sha256:hash(&serde_json::to_vec(&old.manifest).map_err(|e|e.to_string())?),
        previous_local_entry_sha256:hash(&serde_json::to_vec(&old.entry).map_err(|e|e.to_string())?),
    })
}
fn verify_entry(accepted: &Accepted) -> Result<(),String> {
    let e=&accepted.entry;
    if !matches!(accepted.source.as_str(),"local"|"remote")
        || !valid_id(&e.id) || !valid_id(&e.instance_id) || e.instance_id!=e.id
        || e.name.trim().is_empty() || e.name.len()>120 || e.name.chars().any(char::is_control)
        || e.description.len()>10000
        || e.workflow!="coco-standalone" || e.hosting_mode!="p2p"
        || !e.minecraft_version.is_empty() || !e.loader.is_empty()
        || !e.launch_arguments.is_empty() || !valid_relative_file(&e.executable)
        || !e.executable.to_ascii_lowercase().ends_with(".exe") {
        return Err("Invalid standalone catalog entry or workflow".into());
    }
    let prefix = if e.image.starts_with("data:image/png;base64,") { "data:image/png;base64," }
        else if e.image.starts_with("data:image/jpeg;base64,") { "data:image/jpeg;base64," }
        else if e.image.starts_with("data:image/webp;base64,") { "data:image/webp;base64," }
        else { return Err("Dynamic cover must be embedded as a safe image".into()); };
    if e.image.len()>MAX_COVER as usize*4/3+100 {return Err("Cover exceeds size budget".into());}
    let cover=STANDARD.decode(&e.image[prefix.len()..]).map_err(|_| "Invalid cover encoding")?;
    if cover.is_empty() || cover.len() as u64>MAX_COVER {return Err("Invalid cover bytes".into());}
    let valid=if prefix.contains("png") {cover.starts_with(b"\x89PNG\r\n\x1a\n")}
        else if prefix.contains("jpeg"){cover.starts_with(&[0xFF,0xD8,0xFF])}
        else {cover.starts_with(b"RIFF")&&cover.get(8..12)==Some(b"WEBP")};
    if !valid {return Err("Cover bytes disagree with media type".into());}
    let m=&accepted.manifest;
    if m["id"]!=e.id || m["instanceId"]!=e.id || m["workflow"]!="coco-standalone"
        || m["version"].as_str()!=Some(accepted.version.as_str())
        || m["requiredFiles"].as_array().is_none_or(Vec::is_empty)
        || m["archives"].as_array().is_none_or(|x|x.is_empty() || x.len()>128)
        || m["extraFiles"]!=serde_json::json!([])
    {return Err("Dynamic installer manifest differs from catalog".into());}
    let archives=m["archives"].as_array().ok_or("Missing archives")?;
    let mut archive_urls=HashSet::new();
    let mut archive_hashes=HashSet::new();
    for a in archives {
    if !safe_official_archive_url(a["url"].as_str().unwrap_or(""))
        || accepted.source=="remote" && !owned_official_archive_url(a["url"].as_str().unwrap_or(""))
        || !a["sha256"].as_str().is_some_and(valid_sha)
        || a["size"].as_u64().is_none_or(|v|v==0 || v>MAX_ARCHIVE)
        || !archive_urls.insert(a["url"].as_str().unwrap_or(""))
        || !archive_hashes.insert(a["sha256"].as_str().unwrap_or(""))
    {return Err("Unsafe or incomplete official archive reference".into());}
    }
    let required=m["requiredFiles"].as_array().ok_or("Missing required files")?;
    if required.len()!=e.required_files.len() || required.len()>128 {return Err("Required file count mismatch".into());}
    let mut seen=HashSet::new();
    for (index, file) in required.iter().enumerate() {
        let spec:RequiredFile=serde_json::from_value(file.clone())
            .map_err(|_|"Invalid installer required file schema")?;
        if spec!=e.required_files[index] || !valid_relative_file(&spec.path)
            || !seen.insert(spec.path.to_ascii_lowercase()) || !valid_sha(&spec.sha256)
            || spec.size==0 || spec.size>MAX_ARCHIVE
        {return Err("Untrusted required file metadata".into());}
    }
    if !seen.contains(&e.executable.to_ascii_lowercase()) {
        return Err("Required executable missing".into());
    }
    Ok(())
}
fn verify_snapshot(snapshot: &Snapshot) -> Result<(),String> {
    if snapshot.schema_version!=1 || snapshot.entries.len()>MAX_ENTRIES
        || snapshot.previous_sha256.as_deref().is_some_and(|v|!valid_sha(v))
        || snapshot.revision==0 && snapshot.previous_sha256.is_some()
        || snapshot.remote_digest.as_deref().is_some_and(|s|!valid_sha(s))
        || snapshot.remote_sequence==0 && snapshot.remote_digest.is_some()
    {return Err("Invalid snapshot schema or ancestry".into());}
    let mut seen=HashSet::new();
    for entry in &snapshot.entries {
        verify_entry(entry)?;
        if entry.source=="local" && embedded_id(&entry.entry.id)? {
            return Err("Local snapshot attempts to replace protected embedded official ID".into());
        }
        if !seen.insert(entry.entry.id.to_ascii_lowercase()) {
            return Err("Duplicate dynamic experience".into());
        }
    }
    Ok(())
}
fn embedded_id(id:&str)->Result<bool,String>{
    let baseline:Vec<Experience>=serde_json::from_str(include_str!("../../resources/catalog.json"))
        .map_err(|_|"Invalid embedded catalog")?;
    Ok(baseline.iter().any(|record|record.id==id))
}
fn load_sha(dir: &Path, sha: &str) -> Result<Snapshot,String> {
    if !valid_sha(sha) {return Err("Invalid snapshot digest".into());}
    let bytes=read_bounded(&snapshot_path(dir,sha),MAX_SNAPSHOT)?;
    if hash(&bytes)!=sha {return Err("Cached catalog SHA256 mismatch".into());}
    let s:Snapshot=serde_json::from_slice(&bytes).map_err(|_|"Invalid cached catalog JSON")?;
    verify_snapshot(&s)?;
    Ok(s)
}
fn load(dir: &Path) -> Result<(Snapshot,Option<String>),String> {
    let ptr=dir.join("current.json");
    guarded_path(&ptr)?;
    if !ptr.exists(){return Ok((empty(),None));}
    let pointer:Pointer=serde_json::from_slice(&read_bounded(&ptr,1024)?)
        .map_err(|_|"Invalid active catalog pointer")?;
    if pointer.schema_version!=1 {return Err("Unsupported pointer schema".into());}
    Ok((load_sha(dir,&pointer.sha256)?,Some(pointer.sha256)))
}
fn active(dir: &Path) -> Result<Snapshot,String> {load(dir).map(|x|x.0)}

#[cfg(windows)]
fn replace_atomic(stage:&Path,target:&Path,backup:&Path)->Result<(),String>{
    use std::os::windows::ffi::OsStrExt;
    #[link(name="kernel32")]
    extern "system" {
        fn ReplaceFileW(a:*const u16,b:*const u16,c:*const u16,flags:u32,d:*const std::ffi::c_void,e:*const std::ffi::c_void)->i32;
        fn MoveFileW(a:*const u16,b:*const u16)->i32;
    }
    let wide=|p:&Path|p.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let a=wide(target);let b=wide(stage);let c=wide(backup);
    let result=unsafe{if target.exists(){ReplaceFileW(a.as_ptr(),b.as_ptr(),c.as_ptr(),0,std::ptr::null(),std::ptr::null())}
        else{MoveFileW(b.as_ptr(),a.as_ptr())}};
    if result==0 {return Err(format!("Atomic catalog pointer swap refused: {}",std::io::Error::last_os_error()));}
    Ok(())
}
#[cfg(not(windows))]
fn replace_atomic(stage:&Path,target:&Path,_backup:&Path)->Result<(),String>{
    fs::rename(stage,target).map_err(|e|e.to_string())
}
fn commit(dir:&Path, mut next:Snapshot, prior_sha:Option<String>)->Result<(),String>{
    guarded_path(dir)?;
    fs::create_dir_all(dir).map_err(|e|e.to_string())?;
    guarded_path(dir)?;
    let (_,current)=load(dir)?;
    if current!=prior_sha{return Err("Catalog changed during review (CAS)".into());}
    next.schema_version=1;
    next.previous_sha256=prior_sha.clone();
    next.revision=next.revision.checked_add(1).ok_or("Catalog revision overflow")?;
    verify_snapshot(&next)?;
    let bytes=serde_json::to_vec(&next).map_err(|_|"Cannot serialize catalog")?;
    if bytes.len() as u64>MAX_SNAPSHOT{return Err("Dynamic catalog cache exceeds size limit".into());}
    let sha=hash(&bytes);
    let target=snapshot_path(dir,&sha);
    if !target.exists(){write_new(&target,&bytes)?;} else if read_bounded(&target,MAX_SNAPSHOT)?!=bytes{
        return Err("Conflicting immutable catalog snapshot".into());
    }
    let pointer=serde_json::to_vec(&Pointer{schema_version:1,sha256:sha})
        .map_err(|_|"Cannot serialize pointer")?;
    // A process can crash after reserving a pointer stage but before swapping
    // it. The old PID+revision filename then blocks a legitimate retry with
    // the same revision forever. Use a fresh per-attempt sibling instead,
    // while preserving legacy crash files for deliberate owner inspection.
    let (stage,backup)=unique_pointer_paths(dir,next.revision)?;
    let _stage_cleanup=UncommittedPointerStage(stage.clone());
    write_new(&stage,&pointer)?;
    if let Err(e)=replace_atomic(&stage,&dir.join("current.json"),&backup){
        return Err(e);
    }
    // Leave backup for forensic recovery if deleting it fails. Snapshots are
    // never deleted and retain prior manifests for upgrading old installations.
    let _=fs::remove_file(&backup);
    Ok(())
}

struct UncommittedPointerStage(PathBuf);
impl Drop for UncommittedPointerStage {
    fn drop(&mut self) {
        // Delete only this call's exclusively reserved stage. Never recurse
        // into arbitrary paths, follow a junction, or delete a legacy stage.
        if guarded_path(&self.0).is_ok() {let _=fs::remove_file(&self.0);}
    }
}
fn unique_pointer_paths(dir:&Path, revision:u64)->Result<(PathBuf,PathBuf),String>{
    use std::time::{SystemTime,UNIX_EPOCH};
    for retry in 0..16u8 {
        let stamp=SystemTime::now().duration_since(UNIX_EPOCH)
            .map_err(|_|"Clock unavailable during catalog pointer commit")?.as_nanos();
        let name=format!(".current-{}-{revision}-{stamp}-{retry}",std::process::id());
        let stage=dir.join(format!("{name}.stage"));
        let backup=dir.join(format!("{name}.bak"));
        guarded_path(&stage)?;
        guarded_path(&backup)?;
        if !stage.exists() && !backup.exists() {return Ok((stage,backup));}
    }
    Err("No unused atomic pointer stage available for catalog retry".into())
}
#[cfg(windows)]
struct OsLock(isize);
#[cfg(windows)]
impl OsLock {
    fn new(dir:&Path)->Result<Self,String>{
        use std::os::windows::ffi::OsStrExt;
        #[link(name="kernel32")]
        extern "system" {
            fn CreateMutexW(a:*const std::ffi::c_void,owner:i32,name:*const u16)->isize;
            fn WaitForSingleObject(handle:isize,timeout:u32)->u32;
            fn CloseHandle(handle:isize)->i32;
        }
        let name=format!("Local\\Coco2Catalog-{}", &hash(dir.to_string_lossy().to_ascii_lowercase().as_bytes())[..24]);
        let wide=std::ffi::OsStr::new(&name).encode_wide().chain(Some(0)).collect::<Vec<_>>();
        let handle=unsafe{CreateMutexW(std::ptr::null(),0,wide.as_ptr())};
        if handle==0{return Err("Unable to acquire catalog OS mutex".into());}
        let rc=unsafe{WaitForSingleObject(handle,0)};
        if rc!=0 && rc!=0x80 {unsafe{CloseHandle(handle)};return Err("Catalog writer already active".into());}
        Ok(Self(handle))
    }
}
#[cfg(windows)]
impl Drop for OsLock {
    fn drop(&mut self){
        #[link(name="kernel32")]
        extern "system" {fn ReleaseMutex(handle:isize)->i32;fn CloseHandle(handle:isize)->i32;}
        unsafe {ReleaseMutex(self.0);CloseHandle(self.0);}
    }
}
#[cfg(not(windows))]
struct OsLock;
#[cfg(not(windows))]
impl OsLock{fn new(_: &Path)->Result<Self,String>{Ok(Self)}}

fn embedded_manifest(id:&str,version:Option<&str>)->Result<Option<String>,String>{
    let data:Vec<Value>=serde_json::from_str(include_str!("../../resources/install-manifests.json"))
        .map_err(|_|"Invalid embedded installer manifest")?;
    for v in data {
        if v["id"]==id && version.is_none_or(|x|v["version"]==x) {
            return serde_json::to_string(&v).map(Some).map_err(|e|e.to_string());
        }
    }
    Ok(None)
}
fn current_manifest(snapshot:&Snapshot,id:&str,version:Option<&str>,client_only:bool)
    ->Result<Option<String>,String>{
    if let Some(record)=snapshot.entries.iter().find(|r|(!client_only || r.source=="remote")
        && r.entry.id==id
        && version.is_none_or(|v|r.version==v)){
        verify_entry(record)?;
        return serde_json::to_string(&record.manifest).map(Some).map_err(|e|e.to_string());
    }
    Ok(None)
}
fn manifest_at_scoped(dir:&Path,id:&str,version:Option<&str>,client_only:bool)
    ->Result<Option<String>,String>{
    let (mut snapshot, _sha)=load(dir)?;
    if let Some(raw)=current_manifest(&snapshot,id,version,client_only)? {return Ok(Some(raw));}
    // For history requests include only the authenticated SHA chain beginning
    // at the current pointer. Never scan arbitrary orphaned files.
    if version.is_some(){
        let mut visited=HashSet::new();
        for _ in 0..1000 {
            let Some(previous)=snapshot.previous_sha256.take() else{break};
            if !visited.insert(previous.clone()){return Err("Catalog snapshot history loop".into());}
            snapshot=load_sha(dir,&previous)?;
            if let Some(raw)=current_manifest(&snapshot,id,version,client_only)? {return Ok(Some(raw));}
        }
    }
    embedded_manifest(id,version)
}
fn manifest_at(dir:&Path,id:&str,version:Option<&str>)->Result<Option<String>,String>{
    manifest_at_scoped(dir,id,version,false)
}
// Client-facing seam: unlike the offline host test fixture, distributed
// clients must never receive a manifest authorized only by a local package.
fn client_manifest_at(dir:&Path,id:&str,version:Option<&str>)->Result<Option<String>,String>{
    manifest_at_scoped(dir,id,version,true)
}
pub(super) fn manifest_for(id:&str,version:Option<&str>)->Result<Option<String>,String>{
    if !valid_id(id) {return Ok(None);}
    let root=cache_dir()?;
    // Never silently serve a new manifest from corrupt cache; embedded data
    // continues to work, but dynamic IDs fail closed.
    client_manifest_at(&root,id,version).or_else(|_|embedded_manifest(id,version))
}

fn merged_catalog_at(root:&Path,mut baseline:Vec<Experience>)->Vec<Experience>{
    let Ok(snapshot)=active(root) else{return baseline};
    for record in snapshot.entries {
        if record.source=="local" && baseline.iter().any(|e|e.id==record.entry.id){
            continue; // legacy cache cannot replace an embedded official ID
        }
        if let Some(old)=baseline.iter_mut().find(|e|e.id==record.entry.id) {
            *old=record.entry;
        } else {baseline.push(record.entry);}
    }
    baseline
}
fn client_catalog_view(root:&Path,baseline:Vec<Experience>)->Vec<Experience>{
    let Ok(snapshot)=active(root) else{return baseline};
    let mut visible=baseline;
    for record in snapshot.entries {
        // Source=local is a historical self-consistent SHA record, NOT a
        // signature or approval from the host. Never offer it to friends.
        if record.source!="remote"{continue;}
        if let Some(previous)=visible.iter_mut().find(|e|e.id==record.entry.id){
            *previous=record.entry;
        }else{visible.push(record.entry);}
    }
    visible
}
pub(super) fn merged_catalog(baseline:Vec<Experience>)->Vec<Experience>{
    match cache_dir(){Ok(root)=>client_catalog_view(&root,baseline),Err(_)=>baseline}
}
fn provenance_at(root:&Path)->Result<Vec<CatalogProvenance>,String>{
    let baseline:Vec<Experience>=serde_json::from_str(include_str!("../../resources/catalog.json"))
        .map_err(|_|"Invalid embedded catalog")?;
    let manifests:Vec<Value>=serde_json::from_str(include_str!("../../resources/install-manifests.json"))
        .map_err(|_|"Invalid embedded manifests")?;
    let mut result=baseline.into_iter().map(|entry|CatalogProvenance{
        version:manifests.iter().find(|m|m["id"]==entry.id)
            .and_then(|m|m["version"].as_str()).unwrap_or("").to_owned(),
        id:entry.id,source:"embedded"
    }).collect::<Vec<_>>();
    if let Ok(snap)=active(root){
        for entry in snap.entries {
            let source=if entry.source=="remote"{"official"}else{"local"};
            if source=="local" && result.iter().any(|p|p.id==entry.entry.id){continue;}
            if let Some(item)=result.iter_mut().find(|p|p.id==entry.entry.id){
                item.source=source;item.version=entry.version;
            } else {result.push(CatalogProvenance{id:entry.entry.id,source,version:entry.version});}
        }
    }
    Ok(result)
}
fn client_provenance_view(root:&Path)->Result<Vec<CatalogProvenance>,String>{
    Ok(provenance_at(root)?.into_iter().filter(|entry|entry.source!="local").collect())
}
pub(super) fn provenance()->Result<Vec<CatalogProvenance>,String>{
    client_provenance_view(&cache_dir()?)
}
fn status(root:&Path,state:&'static str,message:String)->CatalogChannelStatus{
    match active(root) {
        Ok(s)=>CatalogChannelStatus {
            status:state,revision:s.revision,remote_sequence:s.remote_sequence,
            local_entries:s.entries.iter().filter(|e|e.source=="local").count(),
            remote_entries:s.entries.iter().filter(|e|e.source=="remote").count(),message,
        },
        Err(e)=>CatalogChannelStatus {
            status:"degraded",revision:0,remote_sequence:0,local_entries:0,remote_entries:0,
            message:format!("{message}: {e}"),
        },
    }
}
pub fn get_catalog_channel_status()->CatalogChannelStatus{
    match cache_dir(){
        Ok(root)=>{
            let state=if root.join("current.json").exists(){"cached"}else{"embedded"};
            status(&root,state,"Validated local channel snapshot or embedded fallback".into())
        }
        Err(e)=>CatalogChannelStatus {status:"degraded",revision:0,local_entries:0,
            remote_entries:0,remote_sequence:0,message:e}
    }
}

fn merge_entry(snapshot:&mut Snapshot,new:Accepted)->Result<(),String>{
    verify_entry(&new)?;
    if new.source=="local" && embedded_id(&new.entry.id)? {
        return Err("Local publication cannot override an official embedded experience".into());
    }
    if let Some(previous)=snapshot.entries.iter_mut().find(|e|e.entry.id==new.entry.id){
        if previous.source=="remote" && new.source=="local" {
            return Err("Local package cannot impersonate a signed official release".into());
        }
        if previous.source=="local" && new.source=="remote" {
            return Err("Signed local-to-official promotion requires an explicit verified promotion record".into());
        }
        if previous.version==new.version {
            if *previous==new {return Ok(());}
            return Err("Conflicting catalog entry at identical version".into());
        }
        if !strictly_newer(&new.version,&previous.version)? {
            return Err("Catalog update would roll back installed metadata version".into());
        }
        *previous=new;
    }else{
        // Embedded versions form the trusted floor even for a previously
        // untracked dynamic entry. Non-numeric legacy labels fail closed.
        let baseline:Vec<Experience>=serde_json::from_str(include_str!("../../resources/catalog.json"))
            .map_err(|_|"Invalid embedded catalog")?;
        if baseline.iter().any(|entry|entry.id==new.entry.id) {
            let original:Vec<Value>=serde_json::from_str(include_str!("../../resources/install-manifests.json"))
                .map_err(|_|"Invalid embedded installer catalog")?;
            let version=original.iter().find(|v|v["id"]==new.entry.id)
                .and_then(|v|v["version"].as_str())
                .ok_or("Embedded experience is not an eligible standalone")?;
            if !strictly_newer(&new.version,version)?{
                return Err("Update must exceed embedded experience version".into());
            }
        }
        if snapshot.entries.len()>=MAX_ENTRIES{return Err("Dynamic catalog entry limit".into());}
        snapshot.entries.push(new);
    }
    Ok(())
}

fn absolute_package(path:&str)->Result<PathBuf,String>{
    let p=PathBuf::from(path);
    if !p.is_absolute(){return Err("Choose an absolute local package directory".into());}
    #[cfg(windows)]
    if path.starts_with(r"\\"){return Err("UNC/network publication packages are not accepted".into());}
    guarded_path(&p)?;
    let canonical=p.canonicalize().map_err(|_|"Package directory missing")?;
    guarded_path(&canonical)?;
    if !canonical.is_dir(){return Err("Publish package must be a directory".into());}
    Ok(canonical)
}
fn manifest_string<'a>(v:&'a Value,key:&str)->Result<&'a str,String>{
    v[key].as_str().ok_or_else(||format!("Invalid publish manifest field: {key}"))
}
fn package_file(dir:&Path,static_name:&str,max:u64,sha:&str)->Result<Vec<u8>,String>{
    if !valid_sha(sha){return Err("Invalid publish component SHA".into());}
    let bytes=read_bounded(&dir.join(static_name),max)?;
    if hash(&bytes)!=sha{return Err(format!("Publish component changed: {static_name}"));}
    Ok(bytes)
}
fn stream_hash(path:&Path,expected:&str,size:u64)->Result<(),String>{
    guarded_path(path)?;
    let mut file=File::open(path).map_err(|e|e.to_string())?;
    if file.metadata().map_err(|e|e.to_string())?.len()!=size || size==0 || size>MAX_ARCHIVE {
        return Err("Publish ZIP size mismatch".into());
    }
    let mut digest=Sha256::new();let mut read=0u64;
    let mut buf=vec![0u8;1024*1024];
    loop {
        let n=file.read(&mut buf).map_err(|e|e.to_string())?;
        if n==0 {break;}
        read=read.checked_add(n as u64).ok_or("Archive length overflow")?;
        if read>size{return Err("ZIP grew while reading".into());}
        digest.update(&buf[..n]);
    }
    if read!=size || format!("{:x}",digest.finalize())!=expected {
        return Err("Local package ZIP failed SHA256 verification".into());
    }
    Ok(())
}
fn validate_package_zip(path:&Path,required:&[RequiredFile])->Result<(),String>{
    guarded_path(path)?;
    let file=File::open(path).map_err(|e|e.to_string())?;
    let mut zip=zip::ZipArchive::new(file).map_err(|_|"Offline archive is not a ZIP")?;
    if zip.len()==0 || zip.len()>150_000 {return Err("ZIP entry budget exceeded".into());}
    let mut seen=HashSet::new();
    let mut names=HashSet::new();
    let mut files=HashSet::new();
    let mut directories=HashMap::<String,String>::new();
    for i in 0..zip.len(){
        let item=zip.by_index(i).map_err(|_|"Cannot inspect ZIP entry")?;
        let name=item.name().trim_end_matches('/');
        if !valid_relative_file(name) || !seen.insert(name.to_ascii_lowercase()){
            return Err("Unsafe or duplicate ZIP path".into());
        }
        let mode=item.unix_mode().unwrap_or(0)&0o170000;
        if !matches!(mode,0|0o040000|0o100000)
            || item.is_dir()&&mode==0o100000 || !item.is_dir()&&mode==0o040000 {
            return Err("ZIP contains symbolic link or special file".into());
        }
        if !item.is_dir(){
            files.insert(name.to_ascii_lowercase());
        }
        if item.is_dir(){
            let key=name.to_ascii_lowercase();
            if let Some(old)=directories.insert(key,name.to_string()){
                if old!=name{return Err("ZIP has conflicting directory capitalization".into());}
            }
        }
        let mut segment=name;
        while let Some((parent,_))=segment.rsplit_once('/'){
            names.insert(parent.to_ascii_lowercase());
            let key=parent.to_ascii_lowercase();
            if let Some(old)=directories.insert(key,parent.to_string()){
                if old!=parent{return Err("ZIP has conflicting parent directory casing".into());}
            }
            segment=parent;
        }
    }
    if files.iter().any(|f|names.contains(f)){
        return Err("ZIP has file/directory collision".into());
    }
    for required_file in required {
        let key=required_file.path.to_ascii_lowercase();
        if !files.contains(&key) {return Err("ZIP missing required game file".into());}
    }
    Ok(())
}
fn verify_package(dir:&Path,root:&Path)->Result<(LocalPublishReview,Accepted,PathBuf),String>{
    verify_package_inner(dir,root,false)
}
fn verify_package_inner(dir:&Path,root:&Path,for_official_draft:bool)->Result<(LocalPublishReview,Accepted,PathBuf),String>{
    guarded_path(dir)?;
    let canonical_dir=dir.canonicalize().map_err(|_|"Package path cannot be canonicalized")?;
    guarded_path(&canonical_dir)?;
    let dir=canonical_dir.as_path();
    let bytes=read_bounded(&dir.join("publish-manifest.json"),MAX_METADATA)?;
    let manifest:Value=serde_json::from_slice(&bytes).map_err(|_|"Invalid offline publish manifest")?;
    if manifest["schemaVersion"]!=1 || manifest["packageKind"]!="coco2-host-publish-offline"
        || manifest["reviewedRights"]!=true || manifest["published"]!=false
        || manifest["uploaded"]!=false || manifest["installationsUpdated"]!=false
    {return Err("Unsupported or unreviewed offline package".into());}
    let id=manifest_string(&manifest,"id")?;
    if !valid_id(id){return Err("Invalid publish package ID".into());}
    let archive_hash=manifest_string(&manifest,"archiveSha256")?;
    if !valid_sha(archive_hash){return Err("Invalid ZIP SHA".into());}
    let archive_size=manifest["archiveSize"].as_u64().ok_or("Missing archive size")?;
    let zip=dir.join("game.zip");
    if manifest["archiveFile"]!="game.zip" || manifest["catalogFile"]!="catalog.template.json"
        || manifest["lockFile"]!="source-lock.json"
    {return Err("Publish package redirects fixed component paths".into());}
    stream_hash(&zip,archive_hash,archive_size)?;
    let src=package_file(dir,"catalog.template.json",MAX_METADATA,
        manifest_string(&manifest,"resultCatalogSha256")?)?;
    let cat:Value=serde_json::from_slice(&src).map_err(|_|"Invalid prepared source catalog")?;
    if cat["schemaVersion"]!=1 || cat["experiences"].as_array().is_none(){
        return Err("Invalid prepared source catalog schema".into());
    }
    let candidate=package_file(dir,"catalog-candidate.json",MAX_METADATA,
        manifest_string(&manifest,"candidateSha256")?)?;
    let candidate:Value=serde_json::from_slice(&candidate).map_err(|_|"Invalid catalog candidate")?;
    if candidate["id"]!=id || cat["experiences"].as_array()
        .and_then(|list|list.iter().find(|entry|entry["id"]==id))!=Some(&candidate){
        return Err("Package catalog source and candidate differ".into());
    }
    let lock=package_file(dir,"source-lock.json",MAX_METADATA,
        manifest_string(&manifest,"lockSha256")?)?;
    let lock:Value=serde_json::from_slice(&lock).map_err(|_|"Invalid source lock")?;
    if lock["schemaVersion"]!=1 || lock["experienceId"]!=id
        || lock["archive"]["sha256"]!=archive_hash
        || lock["archive"]["size"]!=archive_size
    {return Err("Archive differs from source lock".into());}
    let cover_name=manifest_string(&manifest,"coverFile")?;
    let mime=match cover_name{
        "cover.png"=>"image/png","cover.jpg"|"cover.jpeg"=>"image/jpeg","cover.webp"=>"image/webp",
        _=>return Err("Unexpected cover filename".into())
    };
    let cover=package_file(dir,cover_name,MAX_COVER,manifest_string(&manifest,"coverSha256")?)?;
    let entry_bytes=package_file(dir,"coco2-client-entry.json",MAX_METADATA,
        manifest_string(&manifest,"clientPreviewSha256")?)?;
    let mut entry:Experience=serde_json::from_slice(&entry_bytes)
        .map_err(|_|"Invalid Coco2 client catalog entry")?;
    if entry.id!=id || entry.instance_id!=id{return Err("Catalog entry identity mismatch".into());}
    entry.image=format!("data:{mime};base64,{}",STANDARD.encode(&cover));
    let install=package_file(dir,"coco2-install-manifest.json",MAX_METADATA,
        manifest_string(&manifest,"installPreviewSha256")?)?;
    let manifest_install:Value=serde_json::from_slice(&install).map_err(|_|"Invalid Coco2 install manifest")?;
    let version=manifest_string(&manifest,"newVersion")?;
    let accepted=Accepted{source:"local".into(),version:version.into(),entry,manifest:manifest_install};
    verify_entry(&accepted)?;
    validate_package_zip(&zip,&accepted.entry.required_files)?;
    if accepted.manifest["archives"].as_array().is_none_or(|parts|parts.len()!=1)
        || accepted.manifest["archives"][0]["sha256"]!=archive_hash
        || accepted.manifest["archives"][0]["size"]!=archive_size
        || accepted.manifest["archives"][0]["url"]!=lock["archive"]["url"]
        || accepted.manifest["archives"][0]["url"]!=candidate["pack"]["archives"][0]["archiveUrl"]
        || candidate["pack"]["version"]!=version
        || candidate["runtime"]["executable"]!=accepted.entry.executable
        || candidate["name"]!=accepted.entry.name
    {return Err("Publish candidate and installer data mismatch".into());}
    // Fresh snapshot rules may change while a dialog is open. Include current
    // pointer SHA in the review token and check again under the writer mutex.
    let (snapshot,sha)=load(root)?;
    let old_version=if let Some(previous)=snapshot.entries.iter().find(|entry|entry.entry.id==id) {
        Some(previous.version.clone())
    } else {
        let baseline:Vec<Value>=serde_json::from_str(include_str!("../../resources/install-manifests.json"))
            .map_err(|_|"Invalid embedded manifests")?;
        baseline.iter().find(|item|item["id"]==id).and_then(|item|item["version"].as_str()).map(str::to_owned)
    };
    let mut proposed=snapshot;
    let identical=proposed.entries.iter().any(|old|
        old.entry.id==accepted.entry.id && *old==accepted);
    if for_official_draft {
        let official=Accepted{source:"remote".into(),..accepted.clone()};
        if let Some(existing)=proposed.entries.iter_mut()
            .find(|record|record.entry.id==official.entry.id && record.source=="local") {
            previous_promotion(existing,&official)?;
            *existing=official;
        } else {
            merge_entry(&mut proposed,official)?;
        }
    } else if !identical {
        merge_entry(&mut proposed,accepted.clone())?;
    }
    let mode=if old_version.is_some(){"update"}else{"new"};
    let manifest_sha=hash(&bytes);
    let name=accepted.entry.name.clone();
    let description=accepted.entry.description.clone();
    let cover_data_url=accepted.entry.image.clone();
    let executable=accepted.entry.executable.clone();
    let required_files_count=accepted.entry.required_files.len();
    let mut changed_fields=Vec::new();
    if old_version.as_deref()!=Some(version){changed_fields.push("version".into());}
    if !identical {changed_fields.push("catalog-entry-and-archive".into());}
    let review_token=hash(format!("coco2-review-v1\n{}\n{}\n{}\n{}",
        dir.display(),manifest_sha,archive_hash,sha.unwrap_or_default()).as_bytes());
    Ok((LocalPublishReview{id:id.into(),mode:mode.into(),old_version,new_version:version.into(),
        archive_sha256:archive_hash.into(),manifest_sha256:manifest_sha,review_token,
        source_path:dir.display().to_string(),status:if identical {"unchanged"} else {"ready-for-review"},
        name,description,cover_data_url,executable,required_files_count,changed_fields,
        portable_sha256:None},accepted,zip))
}
#[cfg(windows)]
fn publish_cache_noreplace(source:&Path,target:&Path)->Result<(),String>{
    use std::os::windows::ffi::OsStrExt;
    #[link(name="kernel32")]
    extern "system" {fn MoveFileW(a:*const u16,b:*const u16)->i32;}
    // std::fs supports extended-length paths, but raw MoveFileW does not add
    // the prefix itself. A long selected workspace otherwise fails only at
    // the final publish after the verified stage was successfully written.
    let source=fs::canonicalize(source).map_err(|e|format!("Cannot resolve verified cache stage: {e}"))?;
    let parent=target.parent().ok_or("Cache destination has no parent")?;
    let filename=target.file_name().ok_or("Cache destination has no filename")?;
    let target=fs::canonicalize(parent).map_err(|e|format!("Cannot resolve cache directory: {e}"))?.join(filename);
    let a=source.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let b=target.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
    if unsafe{MoveFileW(a.as_ptr(),b.as_ptr())}==0 {
        return Err(format!("Verified cache destination appeared: {}",std::io::Error::last_os_error()));
    }
    Ok(())
}
#[cfg(not(windows))]
fn publish_cache_noreplace(source:&Path,target:&Path)->Result<(),String>{
    fs::hard_link(source,target).map_err(|e|format!("Verified cache destination appeared: {e}"))?;
    fs::remove_file(source).map_err(|e|e.to_string())
}
fn seed_cache_with_hook(from:&Path,sha:&str,size:u64,cache:&Path,
                        before_publish:impl FnOnce(&Path,&Path))->Result<(),String>{
    guarded_path(cache)?;
    fs::create_dir_all(cache).map_err(|e|e.to_string())?;
    guarded_path(cache)?;
    let target=cache.join(format!("{sha}.zip"));
    guarded_path(&target)?;
    if target.exists(){return stream_hash(&target,sha,size);}
    // Never expose a partial archive as the installer's trusted <sha>.zip.
    // A stale private .part after a crash is inert and may be inspected later.
    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_|"System time unavailable")?.as_nanos();
    let stage=cache.join(format!(".{sha}.{}-{stamp}.import-part",std::process::id()));
    guarded_path(&stage)?;
    #[cfg(not(windows))]
    let mut input=File::open(from).map_err(|e|e.to_string())?;
    #[cfg(windows)]
    let mut input={
        // SOURCE local copy cannot be changed during read by another process.
        use std::os::windows::fs::OpenOptionsExt;
        OpenOptions::new().read(true).share_mode(1)
            .open(from).map_err(|_|"Cannot lock input ZIP during cache import")?
    };
    let mut output=OpenOptions::new().write(true).create_new(true).open(&stage)
        .map_err(|_|"Cannot reserve private cache stage")?;
    let mut digest=Sha256::new();let mut copied=0u64;
    let mut buf=vec![0u8;1024*1024];
    let result=(||->Result<(),String>{
        loop{
            let n=input.read(&mut buf).map_err(|e|e.to_string())?;
            if n==0 {break;}
            copied=copied.checked_add(n as u64).ok_or("Cache copy overflow")?;
            if copied>size{return Err("ZIP grew during cache copy".into());}
            output.write_all(&buf[..n]).map_err(|e|e.to_string())?;
            digest.update(&buf[..n]);
        }
        output.sync_all().map_err(|e|e.to_string())?;
        if copied!=size || format!("{:x}",digest.finalize())!=sha{
            return Err("Cached ZIP bytes do not match reviewed package".into());
        }
        Ok(())
    })();
    drop(output);
    if let Err(error)=result{
        let _=fs::remove_file(&stage);
        return Err(error);
    }
    // Seal the *same* staged ZIP across the final verification and atomic
    // rename. The old sequence closed the writer, verified by path, then
    // left a window where a competing writer could alter the verified file
    // before MoveFileW, poisoning the content-addressed cache indefinitely.
    // FILE_SHARE_DELETE is essential: it allows MoveFileW while our read-only
    // handle prevents mutation, truncation and a competing rename.
    #[cfg(windows)]
    let _sealed_stage={
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ_DELETE:u32=0x0000_0005;
        match OpenOptions::new().read(true).share_mode(FILE_SHARE_READ_DELETE).open(&stage){
            Ok(file)=>file,
            Err(error)=>{
                let _=fs::remove_file(&stage);
                return Err(format!("Cannot seal verified archive stage against a concurrent writer: {error}"));
            }
        }
    };
    if let Err(error)=stream_hash(&stage,sha,size) {
        let _=fs::remove_file(&stage);
        return Err(error);
    }
    before_publish(&stage,&target);
    if target.exists() {
        let _=fs::remove_file(&stage);
        return stream_hash(&target,sha,size);
    }
    if let Err(error)=publish_cache_noreplace(&stage,&target){
        let _=fs::remove_file(&stage);
        if target.exists() && stream_hash(&target,sha,size).is_ok(){return Ok(());}
        return Err(error);
    }
    stream_hash(&target,sha,size)
}
fn seed_cache(from:&Path,sha:&str,size:u64,cache:&Path)->Result<(),String>{
    seed_cache_with_hook(from,sha,size,cache,|_,_|{})
}
fn with_publish_source<T>(
    path:&str,root:&Path,action:impl FnOnce(LocalPublishReview,Accepted,PathBuf,Option<&portable::PortablePackage>)
        ->Result<T,String>,
) -> Result<T,String> {
    if portable::is_portable(Path::new(path)) {
        let pack=portable::unpack(path,&root.join("portable-staging"))?;
        let (mut review,accepted,zip)=verify_package(&pack.root,root)?;
        let (_,current_sha)=load(root)?;
        review.review_token=portable::review_token(&pack,current_sha.as_deref());
        review.source_path=pack.source.display().to_string();
        review.portable_sha256=Some(pack.sha256.clone());
        action(review,accepted,zip,Some(&pack))
    } else {
        let source=absolute_package(path)?;
        let (review,accepted,zip)=verify_package(&source,root)?;
        action(review,accepted,zip,None)
    }
}
fn import_at(dir:&Path,path:&str,token:&str,confirmed:bool,archives:&Path)->Result<CatalogChannelStatus,String>{
    if !confirmed{return Err("Explicit local publish-package consent is required".into());}
    let _guard=CATALOG_LOCK.get_or_init(||Mutex::new(())).lock().map_err(|_|"Catalog mutex poisoned")?;
    let _os=OsLock::new(dir)?;
    with_publish_source(path,dir,|review,entry,zip,pack|{
        let (mut snap,sha)=load(dir)?;
        let identical=snap.entries.iter().any(|old|old==&entry);
        let previous_token=if identical {
            if let Some(pack)=pack {
                Some(portable::review_token(pack,snap.previous_sha256.as_deref()))
            } else {
                let source=absolute_package(path)?;
                Some(hash(format!("coco2-review-v1\n{}\n{}\n{}\n{}",
                    source.display(),review.manifest_sha256,review.archive_sha256,
                    snap.previous_sha256.as_deref().unwrap_or_default()).as_bytes()))
            }
        } else {None};
        if review.review_token!=token && previous_token.as_deref()!=Some(token) {
            return Err("Publish review is stale or unauthorized".into());
        }
        if identical {
            // Repeated imports are metadata no-ops, but may safely repair an
            // absent content-addressed install cache. Existing corrupt cache
            // files are conflicts and are never replaced or deleted.
            let zip_size=fs::metadata(&zip).map_err(|e|e.to_string())?.len();
            seed_cache(&zip,&review.archive_sha256,zip_size,archives)?;
            return Ok(status(dir,"unchanged",
                "Identical trusted catalog unchanged; archive cache verified or restored".into()));
        }
        merge_entry(&mut snap,entry)?;
        let zip_size=fs::metadata(&zip).map_err(|e|e.to_string())?.len();
        seed_cache(&zip,&review.archive_sha256,zip_size,archives)?;
        commit(dir,snap,sha)?;
        Ok(status(dir,"updated","Locally reviewed package accepted; no running game modified".into()))
    })
}
fn host_curated_client_guard()->Result<(),String>{
    // No GUI consent, file picker, token, SHA or portable package can grant
    // friends permission to publish a catalog entry. Test-only host fixtures
    // use import_at directly and remain isolated from this public Tauri gate.
    Err("Solo el catálogo del host (embebido o Ed25519 firmado) puede ofrecer juegos; importación local deshabilitada".into())
}
pub async fn review_local_publish_package(path:String)->Result<LocalPublishReview,String>{
    host_curated_client_guard()?;
    tauri::async_runtime::spawn_blocking(move||{
        let dir=cache_dir()?;
        with_publish_source(&path,&dir,|review,_,_,_|Ok(review))
    }).await.map_err(|e|format!("Review interrupted: {e}"))?
}
pub async fn import_local_publish_package(path:String,review_token:String,confirmed:bool)
    ->Result<CatalogChannelStatus,String>{
    host_curated_client_guard()?;
    tauri::async_runtime::spawn_blocking(move||import_at(&cache_dir()?,&path,
        &review_token,confirmed,&package_cache()?))
        .await.map_err(|e|format!("Catalog import interrupted: {e}"))?
}

fn minisign_key_from_config(config:&str)->Result<[u8;32],String>{
    let json:Value=serde_json::from_str(config).map_err(|_|"Invalid signed updater config")?;
    let encoded=json["plugins"]["updater"]["pubkey"].as_str().ok_or("Updater public key missing")?;
    let decoded=STANDARD.decode(encoded).map_err(|_|"Invalid updater public key encoding")?;
    let text=std::str::from_utf8(&decoded).map_err(|_|"Invalid updater minisign key text")?;
    let line=text.lines().find(|v|v.starts_with("RW")).ok_or("Updater minisign public key missing")?;
    let raw=STANDARD.decode(line.trim()).map_err(|_|"Invalid inner minisign public key")?;
    if raw.len()!=42 || &raw[..2]!=b"Ed"{return Err("Unsupported updater minisign Ed25519 public key".into());}
    let mut key=[0u8;32];key.copy_from_slice(&raw[10..42]);Ok(key)
}
fn embedded_key()->Result<[u8;32],String>{
    minisign_key_from_config(include_str!("../../tauri.conf.json"))
}
fn verify_signed_channel(json:&[u8],detached_sig:&[u8],key:&[u8;32])
    ->Result<RemoteChannel,String>{
    if json.len() as u64>MAX_SNAPSHOT || detached_sig.len()>512 {return Err("Channel response oversized".into());}
    let text=std::str::from_utf8(detached_sig).map_err(|_|"Signature must be base64 text")?;
    let sig=STANDARD.decode(text.trim()).map_err(|_|"Invalid Ed25519 channel signature")?;
    if sig.len()!=64{return Err("Signed channel requires a 64-byte detached Ed25519 signature".into());}
    UnparsedPublicKey::new(&ED25519,key).verify(json,&sig)
        .map_err(|_|"Channel signature does not match embedded updater public key")?;
    decode_channel(json)
}
fn decode_channel(json:&[u8])->Result<RemoteChannel,String>{
    if json.len() as u64>MAX_SNAPSHOT{return Err("Channel JSON exceeds limit".into());}
    let result:RemoteChannel=serde_json::from_slice(json).map_err(|_|"Invalid signed channel JSON")?;
    if result.schema_version!=1 || result.sequence==0 || result.entries.len()>MAX_ENTRIES {
        return Err("Unsupported signed channel schema or sequence".into());
    }
    let mut ids=HashSet::new();
    for entry in &result.entries {
        if entry.source!="remote"{return Err("Signed channel entry has wrong origin".into());}
        verify_entry(entry)?;
        if !ids.insert(entry.entry.id.to_ascii_lowercase()){return Err("Duplicate signed channel ID".into());}
    }
    if result.promotions.len()>MAX_ENTRIES{return Err("Too many signed promotions".into());}
    let mut promotions=HashSet::new();
    for promotion in &result.promotions {
        if !valid_id(&promotion.id) || !valid_sha(&promotion.previous_local_manifest_sha256)
            || !valid_sha(&promotion.previous_local_entry_sha256)
            || !promotions.insert(promotion.id.to_ascii_lowercase())
            || !result.entries.iter().any(|e|e.entry.id==promotion.id
                && e.version==promotion.new_remote_version) {
            return Err("Invalid or unbound signed promotion".into());
        }
    }
    Ok(result)
}
fn allowed_http_redirect(url:&reqwest::Url)->bool{
    if url.scheme()!="https" || url.port_or_known_default()!=Some(443)
        || !url.username().is_empty() || url.password().is_some(){return false;}
    match url.host_str(){
        Some("github.com") => url.path().starts_with("/Franco-Caballero/CocoMinecraftUpdater/releases/"),
        Some("release-assets.githubusercontent.com") => true,
        Some("objects.githubusercontent.com")=>true,
        _=>false,
    }
}
fn http_client()->Result<reqwest::blocking::Client,String>{
    reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt|{
            if attempt.previous().len()>=5 || !allowed_http_redirect(attempt.url()) {
                attempt.error("Untrusted catalog release redirect")
            } else {attempt.follow()}
        }))
        .timeout(Duration::from_secs(25))
        .build().map_err(|e|format!("Cannot create signed channel HTTP client: {e}"))
}
fn fetch_bounded(client:&reqwest::blocking::Client,url:&str,max:u64)->Result<Vec<u8>,String>{
    let parsed=reqwest::Url::parse(url).map_err(|_|"Invalid official channel URL")?;
    if !allowed_http_redirect(&parsed) {return Err("Nonofficial catalog endpoint".into());}
    let resp=client.get(parsed).send().map_err(|e|format!("Official catalog request failed: {e}"))?
        .error_for_status().map_err(|e|format!("Official release unavailable: {e}"))?;
    if resp.content_length().is_some_and(|n|n>max) {
        return Err("Signed channel response exceeds bound".into());
    }
    let mut bytes=Vec::new();
    resp.take(max+1).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
    if bytes.len() as u64>max {return Err("Signed channel response exceeds bound".into());}
    Ok(bytes)
}
fn apply_signed_at(dir:&Path,body:&[u8],sig:&[u8],key:&[u8;32])->Result<CatalogChannelStatus,String>{
    apply_signed_at_scoped(dir,body,sig,key,false)
}
fn client_apply_signed_at(dir:&Path,body:&[u8],sig:&[u8],key:&[u8;32])
    ->Result<CatalogChannelStatus,String>{
    apply_signed_at_scoped(dir,body,sig,key,true)
}
fn apply_signed_at_scoped(dir:&Path,body:&[u8],sig:&[u8],key:&[u8;32],client_only:bool)
    ->Result<CatalogChannelStatus,String>{
    let channel=verify_signed_channel(body,sig,key)?;
    let _lock=CATALOG_LOCK.get_or_init(||Mutex::new(())).lock().map_err(|_|"Catalog mutex poisoned")?;
    let _os=OsLock::new(dir)?;
    let (mut snap,sha)=load(dir)?;
    let digest=hash(body);
    if channel.sequence==snap.remote_sequence {
        let legacy_exact_replay=snap.remote_digest.is_none()
            && channel.entries.iter().all(|signed|snap.entries.iter().any(|saved|saved==signed));
        if snap.remote_digest.as_deref()==Some(digest.as_str()) || legacy_exact_replay {
            return Ok(status(dir,"unchanged","This signed official channel is already installed".into()));
        }
        return Err("Signed channel sequence conflict: different bytes at existing sequence".into());
    }
    if channel.sequence<snap.remote_sequence {
        return Err("Signed channel sequence rollback rejected".into());
    }
    for record in channel.entries {
        if let Some(old)=snap.entries.iter().find(|e|e.entry.id==record.entry.id && e.source=="local") {
            if !client_only {
                // Host-only offline test fixtures still require a deliberate
                // cryptographic promotion of their locally reviewed content.
                let signed=channel.promotions.iter().find(|p|p.id==record.entry.id)
                    .ok_or("Signed channel conflicts with local package: explicit promotion required")?;
                let expected=previous_promotion(old,&record)?;
                if *signed!=expected {
                    return Err("Signed promotion does not match installed local identity and hashes".into());
                }
            }
            // In a distributed client any legacy local record is inert,
            // including a forged higher version. A newly VERIFIED official
            // signature can replace it without requiring its cooperation.
            let index=snap.entries.iter().position(|e|e.entry.id==record.entry.id)
                .ok_or("Signed promotion entry disappeared")?;
            snap.entries[index]=record;
        } else {
            merge_entry(&mut snap,record)?;
        }
    }
    snap.remote_sequence=channel.sequence;
    snap.remote_digest=Some(digest);
    commit(dir,snap,sha)?;
    Ok(status(dir,"updated","Verified official Ed25519 channel snapshot accepted".into()))
}
pub async fn sync_catalog_channel()->Result<CatalogChannelStatus,String>{
    tauri::async_runtime::spawn_blocking(move||{
        let root=cache_dir()?;
        let key=embedded_key()?;
        let client=http_client()?;
        // Lack of connectivity is a normal first-run state. Only transport
        // unavailability is treated as offline; invalid signatures still fail.
        let body=match fetch_bounded(&client,OFFICIAL_CATALOG,MAX_SNAPSHOT) {
            Ok(data)=>data,
            Err(error) if error.starts_with("Official catalog request failed:")
                || error.starts_with("Official release unavailable:") =>
                    return Ok(status(&root,"offline",format!("Official channel unavailable; trusted cache retained: {error}"))),
            Err(error)=>return Err(error),
        };
        let sig=match fetch_bounded(&client,OFFICIAL_SIGNATURE,512){
            Ok(data)=>data,
            Err(error) if error.starts_with("Official catalog request failed:")
                || error.starts_with("Official release unavailable:") =>
                    return Ok(status(&root,"offline",format!("Official signature unavailable; trusted cache retained: {error}"))),
            Err(error)=>return Err(error),
        };
        client_apply_signed_at(&root,&body,&sig,&key)
    }).await.map_err(|e|format!("Channel synchronization interrupted: {e}"))?
}

struct NewDraftFolder(PathBuf);
impl Drop for NewDraftFolder {
    fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}
}
fn prepare_catalog_channel_at(package:&Path,source_cache:&Path,
                              drafts:&Path)->Result<UnsignedCatalogChannelDraft,String>{
    let (review,new,zip)=verify_package_inner(package,source_cache,true)?;
    let url=new.manifest["archives"][0]["url"].as_str()
        .ok_or("Publication archive URL missing")?.to_owned();
    if !owned_official_archive_url(&url) {
        return Err("Host signed publication requires ZIP URL owned by the official GitHub repository".into());
    }
    let (current,source_sha)=load(source_cache)?;
    let official=Accepted{source:"remote".into(),..new};
    verify_entry(&official)?;
    let cover_encoded=official.entry.image.split_once(',')
        .map(|(_,content)|content).ok_or("Missing official cover encoding")?;
    let cover_digest=hash(&STANDARD.decode(cover_encoded).map_err(|_|"Invalid official cover")?);
    let mut promotions=Vec::new();
    if let Some(old)=current.entries.iter().find(|r|r.entry.id==official.entry.id && r.source=="local") {
        promotions.push(previous_promotion(old,&official)?);
    }
    // Exclude unrelated local entries from the official publication draft.
    let mut publication=Snapshot{
        entries:current.entries.iter().filter(|r|r.source=="remote").cloned().collect(),
        ..empty()
    };
    merge_entry(&mut publication,official)?;
    let next_sequence=current.remote_sequence.checked_add(1).ok_or("Channel sequence overflow")?;
    let payload=serde_json::json!({
        "schemaVersion":1,
        "sequence":next_sequence,
        "entries":publication.entries,
        "promotions":promotions,
    });
    let bytes=serde_json::to_vec_pretty(&payload).map_err(|_|"Cannot encode unsigned channel")?;
    if bytes.len() as u64>MAX_SNAPSHOT{return Err("Unsigned channel exceeds size limit".into());}
    guarded_path(drafts)?;
    fs::create_dir_all(drafts).map_err(|e|e.to_string())?;
    guarded_path(drafts)?;
    let sha=hash(&bytes);
    let target=drafts.join(format!("{}-s{}-{}",review.id,next_sequence,&sha[..16]));
    guarded_path(&target)?;
    if target.exists(){return Err("Immutable channel draft already exists".into());}
    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_|"System clock unavailable")?.as_nanos();
    let temp=NewDraftFolder(drafts.join(format!(".channel-{}-{stamp}.stage",std::process::id())));
    fs::create_dir(&temp.0).map_err(|_|"Cannot reserve channel staging directory")?;
    let draft=temp.0.join("coco2-catalog-channel.json");
    write_new(&draft,&bytes)?;
    let original_manifest=read_bounded(&package.join("publish-manifest.json"),MAX_METADATA)?;
    if hash(&original_manifest)!=review.manifest_sha256 {
        return Err("Host package manifest changed between validation and staging".into());
    }
    write_new(&temp.0.join("source-package-manifest.json"),&original_manifest)?;
    let archive_sha=&review.archive_sha256;
    let archive_size=fs::metadata(&zip).map_err(|e|e.to_string())?.len();
    let archive_asset=reqwest::Url::parse(&url)
        .map_err(|_|"Publication URL cannot be parsed")?
        .path_segments().and_then(|mut parts|parts.next_back().map(str::to_owned))
        .ok_or("Official ZIP asset filename missing")?;
    if archive_asset.len()>128 || archive_asset.contains('/')
        || !valid_relative_file(&archive_asset) || !archive_asset.to_ascii_lowercase().ends_with(".zip") {
        return Err("Official ZIP asset must have a safe ZIP filename".into());
    }
    seed_cache(&zip,archive_sha,archive_size,&temp.0)?;
    fs::rename(temp.0.join(format!("{archive_sha}.zip")),temp.0.join(&archive_asset))
        .map_err(|e|format!("Cannot seal channel ZIP review asset: {e}"))?;
    let sig_name="coco2-catalog-channel.json.sig";
    let checklist=vec![
        PublicationAsset{name:archive_asset.clone(),local_path:temp.0.join(&archive_asset).display().to_string(),
            expected_url:url.clone(),sha256:archive_sha.clone(),size:archive_size,uploaded:false},
        PublicationAsset{name:"coco2-catalog-channel.json".into(),local_path:draft.display().to_string(),
            expected_url:OFFICIAL_CATALOG.into(),sha256:sha.clone(),size:bytes.len() as u64,uploaded:false},
        PublicationAsset{name:sig_name.into(),local_path:temp.0.join(sig_name).display().to_string(),
            expected_url:OFFICIAL_SIGNATURE.into(),sha256:String::new(),size:0,uploaded:false},
    ];
    let lock=DeliveryLock {
        schema_version:1,id:review.id.clone(),sequence:next_sequence,
        source_snapshot_sha256:source_sha,
        channel_sha256:sha.clone(),channel_size:bytes.len() as u64,
        archive_name:archive_asset.clone(),archive_sha256:archive_sha.clone(),
        archive_size,archive_url:url.clone(),source_manifest_sha256:review.manifest_sha256.clone(),
        cover_sha256:cover_digest,entry_count:payload["entries"].as_array().map_or(0,Vec::len),
    };
    write_new(&temp.0.join("delivery-lock.json"),
        &serde_json::to_vec_pretty(&lock).map_err(|_|"Cannot encode delivery integrity lock")?)?;
    let note=format!(
        "REVIEW ONLY; NOT SIGNED OR UPLOADED.\n\nChannel sequence: {next_sequence}\nJSON SHA256: {sha}\n+        Verify all entry versions, SHA256, covers and distribution rights before signing.\n+        Sign the EXACT JSON file with the private Ed25519 key corresponding to the Coco2 Tauri updater public key.\n+        Required signature file is raw 64-byte Ed25519 signature, STANDARD base64 encoded text (not a minisign comment envelope).\n+        Release assets: coco2-catalog-channel.json, coco2-catalog-channel.json.sig.\n+        Both must be uploaded to the official Franco-Caballero/CocoMinecraftUpdater GitHub latest release.\n+        Publish each referenced archive URL only after comparing the uploaded ZIP with its SHA256.\n+        No credentials or signing actions are performed by Host Studio.\n"
    );
    let note=format!(
        "STAGED ONLY. ARCHIVE IS NOT UPLOADED. SIGNATURE DOES NOT EXIST.\n+        Required upload: {archive_asset} ({archive_size} bytes; SHA256 {archive_sha}).\n+        Expected owner/release asset URL: {url}\n+        Verify GitHub repository ownership, rights, and exact upstream uploaded ZIP SHA256 before relying on this draft.\n+        Upload channel JSON and detached signature to their official URLs only after authorized signing and review.\n+        All checklist uploaded flags are FALSE.\n\n{note}"
    );
    let note=note.replace("\n+        ","\n");
    write_new(&temp.0.join("REVIEW.txt"),note.as_bytes())?;
    #[cfg(windows)]
    publish_cache_noreplace(&temp.0,&target)?;
    #[cfg(not(windows))]
    fs::rename(&temp.0,&target).map_err(|e|e.to_string())?;
    let staged_assets=checklist.into_iter().map(|mut asset|{
        if let Some(name)=Path::new(&asset.local_path).file_name(){
            asset.local_path=target.join(name).display().to_string();
        }
        asset
    }).collect();
    Ok(UnsignedCatalogChannelDraft {
        id:review.id,sequence:next_sequence,entries:payload["entries"].as_array().map_or(0,Vec::len),
        channel_draft_path:target.join("coco2-catalog-channel.json").display().to_string(),
        signature_path:target.join("coco2-catalog-channel.json.sig").display().to_string(),
        channel_sha256:sha,source_manifest_sha256:review.manifest_sha256,
        release_catalog_url:OFFICIAL_CATALOG.into(),release_signature_url:OFFICIAL_SIGNATURE.into(),
        status:"staged-assets-upload-required",
        review_note:note,
        publication_assets:staged_assets,ready_for_signature:false,
        archive_path:target.join(&archive_asset).display().to_string(),
    })
}
pub async fn prepare_catalog_channel(package_path:String)
    ->Result<UnsignedCatalogChannelDraft,String>{
    tauri::async_runtime::spawn_blocking(move||{
        if !crate::services::r#import::host_studio_available() {
            return Err("Channel authoring requires Host Studio on owner's checkout".into());
        }
        let package=absolute_package(&package_path)?;
        let root=Path::new(env!("CARGO_MANIFEST_DIR")).parent()
            .and_then(Path::parent).ok_or("Launcher2 workspace missing")?;
        let drafts=root.join("channel-drafts");
        prepare_catalog_channel_at(&package,&cache_dir()?,&drafts)
    }).await.map_err(|e|format!("Channel preparation interrupted: {e}"))?
}

const MAX_DELIVERY_ZIP_GET: u64 = 256 * 1024 * 1024;

fn delivery_path(path:&Path)->Result<PathBuf,String>{
    if !path.is_absolute(){return Err("Select an absolute channel draft path".into());}
    guarded_path(path)?;
    let file=if path.is_dir(){path.join("coco2-catalog-channel.json")}else{path.to_path_buf()};
    if file.file_name().and_then(|s|s.to_str())!=Some("coco2-catalog-channel.json"){
        return Err("Only an exact Host Studio channel JSON draft can be reviewed".into());
    }
    let parent=file.parent().ok_or("Channel draft directory missing")?;
    if parent.parent().and_then(|p|p.file_name()).and_then(|s|s.to_str())!=Some("channel-drafts"){
        return Err("Channel draft must be located in a Host Studio channel-drafts directory".into());
    }
    guarded_path(parent)?;
    let canonical=parent.canonicalize().map_err(|_|"Channel draft directory unavailable")?;
    guarded_path(&canonical)?;
    if !canonical.is_dir(){return Err("Channel draft is not a directory".into());}
    Ok(canonical)
}

fn check_local_asset(directory:&Path,name:&str,url:&str,sha:Option<&str>,size:Option<u64>)
    ->DeliveryAssetReview{
    let mut result=DeliveryAssetReview {
        name:name.to_owned(),expected_url:url.to_owned(),
        expected_sha256:sha.map(str::to_owned),expected_size:size,
        present_local:false,verified_local:false,remote_available:false,
        message:"Local asset missing; no remote check was performed".into(),
    };
    if !valid_relative_file(name)||name.contains('/') {
        result.message="Unsafe local asset name".into();
        return result;
    }
    let path=directory.join(name);
    if guarded_path(&path).is_err(){
        result.message="Symlink or reparse point in local delivery path".into();
        return result;
    }
    match fs::symlink_metadata(&path) {
        Ok(metadata)=>{
            result.present_local=true;
            if !metadata.is_file(){
                result.message="Asset is not a regular file".into();
                return result;
            }
            if sha.is_none()||size.is_none(){
                result.message="No pinned SHA256/size: file is present but not verified".into();
                return result;
            }
            if let (Some(sha),Some(size))=(sha,size){
                if !valid_sha(sha)||size==0||size>MAX_ARCHIVE||metadata.len()!=size {
                    result.message="Asset SHA256/size metadata mismatch".into();
                } else {
                    match stream_hash(&path,sha,size) {
                        Ok(())=>{result.verified_local=true;result.message="Local size and SHA256 verified".into();}
                        Err(e)=>result.message=format!("Local hash verification failed: {e}"),
                    }
                }
            }
        }
        Err(e) if e.kind()==std::io::ErrorKind::NotFound=>{}
        Err(_)=>result.message="Cannot safely stat local delivery asset".into(),
    }
    result
}

fn check_remote_asset(client:&reqwest::blocking::Client,asset:&DeliveryAssetReview)->Result<bool,String>{
    let sha=asset.expected_sha256.as_deref().ok_or("Remote expected SHA256 missing")?;
    let size=asset.expected_size.ok_or("Remote expected size missing")?;
    if !asset.verified_local {return Ok(false);}
    let url=&asset.expected_url;
    if url!=OFFICIAL_CATALOG && url!=OFFICIAL_SIGNATURE && !owned_official_archive_url(url){
        return Err("Remote verification refuses nonofficial release URL".into());
    }
    // A multi-GiB game ZIP is never downloaded by a readiness click. HEAD or
    // Content-Length alone cannot prove SHA256, so it remains unverified.
    let max=if url==OFFICIAL_SIGNATURE {512} else if url==OFFICIAL_CATALOG {
        MAX_SNAPSHOT
    } else {MAX_DELIVERY_ZIP_GET};
    if size>max{return Err("Remote asset exceeds safe full-SHA verification budget".into());}
    let parsed=reqwest::Url::parse(url).map_err(|_|"Invalid remote release URL")?;
    let response=client.get(parsed).send().map_err(|e|format!("Offline or remote request failed: {e}"))?
        .error_for_status().map_err(|e|format!("Remote release response unavailable: {e}"))?;
    if response.content_length().is_some_and(|n|n!=size){
        return Err("Remote content length differs from pinned asset".into());
    }
    let mut source=response.take(max+1);
    let mut digest=Sha256::new();
    let mut total=0u64;
    let mut buffer=vec![0u8;1024*1024];
    loop {
        let n=source.read(&mut buffer).map_err(|e|format!("Remote streaming verification failed: {e}"))?;
        if n==0 {break;}
        total=total.checked_add(n as u64).ok_or("Remote size overflow")?;
        if total>max||total>size{return Err("Remote asset exceeded verified bounds".into());}
        digest.update(&buffer[..n]);
    }
    Ok(total==size && format!("{:x}",digest.finalize())==sha)
}

fn review_channel_delivery_at(
    path:&Path,profile:&Path,key:&[u8;32],
    mut remote_probe:Option<&mut dyn FnMut(&DeliveryAssetReview)->Result<bool,String>>,
)->Result<ChannelDeliveryReview,String>{
    let folder=delivery_path(path)?;
    let draft=folder.join("coco2-catalog-channel.json");
    let mut report=ChannelDeliveryReview {
        id:String::new(),sequence:0,draft_path:draft.display().to_string(),
        channel_sha256:String::new(),source_snapshot_sha256:None,
        provenance:"unverified-draft".into(),status:"invalid",
        signature_trusted:false,ready_for_signature:false,ready_for_upload:false,
        all_remote_verified:false,remote_checked:remote_probe.is_some(),
        assets:Vec::new(),issues:Vec::new(),
    };
    let lock_bytes=match read_bounded(&folder.join("delivery-lock.json"),MAX_METADATA){
        Ok(bytes)=>bytes,
        Err(_)=>{
            report.issues.push("Missing/unreadable delivery-lock.json: old draft has no full-digest pin; regenerate it".into());
            return Ok(report);
        }
    };
    let lock:DeliveryLock=match serde_json::from_slice(&lock_bytes){
        Ok(lock)=>lock,
        Err(_)=>{
            report.issues.push("Invalid delivery integrity lock".into());
            return Ok(report);
        }
    };
    report.id=lock.id.clone();
    report.sequence=lock.sequence;
    report.source_snapshot_sha256=lock.source_snapshot_sha256.clone();
    report.channel_sha256=lock.channel_sha256.clone();
    if lock.schema_version!=1||!valid_id(&lock.id)||lock.sequence==0
        || !valid_sha(&lock.channel_sha256)||!valid_sha(&lock.archive_sha256)
        || !valid_sha(&lock.source_manifest_sha256)||!valid_sha(&lock.cover_sha256)
        || lock.channel_size==0||lock.channel_size>MAX_SNAPSHOT
        || lock.archive_size==0||lock.archive_size>MAX_ARCHIVE
        || lock.entry_count==0||lock.entry_count>MAX_ENTRIES
        || lock.source_snapshot_sha256.as_deref().is_some_and(|v|!valid_sha(v))
        || !owned_official_archive_url(&lock.archive_url)
        || !valid_relative_file(&lock.archive_name)||lock.archive_name.contains('/')
        || !lock.archive_name.to_ascii_lowercase().ends_with(".zip") {
        report.issues.push("Unsafe delivery-lock metadata or official archive ownership".into());
        return Ok(report);
    }
    match read_bounded(&folder.join("source-package-manifest.json"),MAX_METADATA) {
        Ok(source_bytes) if hash(&source_bytes)==lock.source_manifest_sha256=>{
            match serde_json::from_slice::<Value>(&source_bytes) {
                Ok(source) if source["schemaVersion"]==1
                    && source["packageKind"]=="coco2-host-publish-offline"
                    && source["id"]==lock.id
                    && source["archiveSha256"]==lock.archive_sha256
                    && source["archiveSize"]==lock.archive_size
                    && source["archiveUrl"]==lock.archive_url
                    && source["coverSha256"]==lock.cover_sha256
                    && source["published"]==false && source["uploaded"]==false =>
                        {report.provenance="verified-host-package-manifest".into();}
                _=>report.issues.push("Host publish manifest provenance conflicts with pinned delivery lock".into()),
            }
        }
        _=>report.issues.push("Original Host Studio publication manifest missing or SHA256 changed".into()),
    }
    let expected_name=format!("{}-s{}-{}",lock.id,lock.sequence,&lock.channel_sha256[..16]);
    if folder.file_name().and_then(|s|s.to_str())!=Some(&expected_name) {
        report.issues.push("Draft folder identity/sequence/hashed prefix does not match pinned metadata".into());
    }
    let expected_basename=reqwest::Url::parse(&lock.archive_url).ok()
        .and_then(|url|url.path_segments().and_then(|mut segments|segments.next_back().map(str::to_owned)));
    if expected_basename.as_deref()!=Some(lock.archive_name.as_str()){
        report.issues.push("ZIP filename differs from its official release URL".into());
    }
    let channel=check_local_asset(&folder,"coco2-catalog-channel.json",OFFICIAL_CATALOG,
        Some(&lock.channel_sha256),Some(lock.channel_size));
    let archive=check_local_asset(&folder,&lock.archive_name,&lock.archive_url,
        Some(&lock.archive_sha256),Some(lock.archive_size));
    report.assets.push(channel);
    report.assets.push(archive);
    let sig_path=folder.join("coco2-catalog-channel.json.sig");
    let sig_content=if guarded_path(&sig_path).is_ok() {
        read_bounded(&sig_path,512).ok()
    } else {None};
    let sig_sha=sig_content.as_ref().map(|bytes|hash(bytes));
    let sig_len=sig_content.as_ref().map(|bytes|bytes.len() as u64);
    let mut signature=check_local_asset(&folder,"coco2-catalog-channel.json.sig",OFFICIAL_SIGNATURE,
        sig_sha.as_deref(),sig_len);
    // Presence/size alone does not grant authority to a detached signature.
    signature.verified_local=false;
    signature.message=if sig_content.is_some() {
        "Detached signature present; official public-key verification pending".into()
    } else {"Detached signature absent or unreadable; this is not a signed release".into()};
    let signature_present=signature.present_local;
    report.assets.push(signature);

    let mut stale=false;
    match load(profile) {
        Ok((snapshot,current_sha))=>{
            if current_sha!=lock.source_snapshot_sha256 {
                stale=true;
                report.issues.push("Host source catalog snapshot changed since this draft was prepared".into());
            }
            if lock.sequence<=snapshot.remote_sequence {
                stale=true;
                report.issues.push("Draft signed sequence is not newer than trusted channel history".into());
            }
        }
        Err(error)=>{
            stale=true;
            report.issues.push(format!("Cannot verify source catalog history: {error}"));
        }
    }
    if !report.assets[0].verified_local {
        report.issues.push("Channel JSON bytes differ from pinned size/SHA256 or are missing".into());
    }
    if !report.assets[1].verified_local {
        report.issues.push("Staged game archive is missing or no longer matches SHA256/size".into());
    }
    let parsed=if report.assets[0].verified_local {
        match read_bounded(&draft,MAX_SNAPSHOT).and_then(|bytes|decode_channel(&bytes).map(|channel|(bytes,channel))) {
            Ok(pair)=>Some(pair),
            Err(e)=>{report.issues.push(format!("Channel schema/provenance invalid: {e}"));None}
        }
    } else {None};
    if let Some((ref bytes,ref channel))=parsed {
        if channel.sequence!=lock.sequence||channel.entries.len()!=lock.entry_count {
            report.issues.push("Channel sequence or entry count differs from sealed draft".into());
        }
        let target=channel.entries.iter().find(|entry|entry.entry.id==lock.id);
        if let Some(target)=target {
            let archive=&target.manifest["archives"][0];
            if archive["url"]!=lock.archive_url||archive["sha256"]!=lock.archive_sha256
                ||archive["size"]!=lock.archive_size{
                report.issues.push("Staged archive URL/hash/size disagree with signed channel entry".into());
            }
            let cover=target.entry.image.split_once(',').and_then(|(_,b)|STANDARD.decode(b).ok());
            if cover.as_deref().map(hash).as_deref()!=Some(lock.cover_sha256.as_str()){
                report.issues.push("Signed channel cover bytes differ from sealed cover metadata".into());
            }
            report.provenance="official-pending-signature".into();
        } else {
            report.issues.push("Draft does not include its pinned experience ID".into());
        }
        if let Some(ref signature_bytes)=sig_content {
            if verify_signed_channel(bytes,signature_bytes,key).is_ok(){
                report.signature_trusted=true;
                report.provenance="official-signature-verified".into();
                report.assets[2].verified_local=true;
                report.assets[2].message="Detached signature verified against trusted Ed25519 public key".into();
            } else {
                report.issues.push("Detached signature is not trusted by the embedded official public key".into());
                report.assets[2].message="Signature mismatch or invalid official key".into();
            }
        }
    }
    let correct=report.issues.is_empty()&&report.assets[0].verified_local&&report.assets[1].verified_local;
    report.ready_for_signature=correct&&!signature_present;
    report.ready_for_upload=correct&&report.signature_trusted;
    report.status=if stale {"stale"} else if !correct {
        if signature_present&&!report.signature_trusted {"signature-invalid"}else{"invalid"}
    } else if !signature_present {"unsigned"} else if report.signature_trusted {"signed-local"}
        else {"signature-invalid"};
    if report.ready_for_upload {
        if let Some(ref mut probe)=remote_probe{
            for asset in &mut report.assets {
                if asset.verified_local {
                    match probe(asset) {
                        Ok(true)=>{asset.remote_available=true;asset.message="Remote bytes verified against pinned SHA256 and size".into();}
                        Ok(false)=>asset.message="Remote content did not match full SHA256/size".into(),
                        Err(e)=>asset.message=format!("Remote unverified (not evidence of publication): {e}"),
                    }
                }
            }
            report.all_remote_verified=report.assets.iter().all(|asset|asset.remote_available);
            if report.all_remote_verified {report.status="remote-verified";}
        }
    }
    Ok(report)
}
pub async fn review_channel_delivery(draft_path:String)->Result<ChannelDeliveryReview,String>{
    tauri::async_runtime::spawn_blocking(move||{
        let path=PathBuf::from(draft_path);
        review_channel_delivery_at(&path,&cache_dir()?,&embedded_key()?,None)
    }).await.map_err(|e|format!("Offline delivery review interrupted: {e}"))?
}
pub async fn verify_channel_delivery_online(draft_path:String)->Result<ChannelDeliveryReview,String>{
    // Invoked only by explicit UI action; no background polling or signing.
    tauri::async_runtime::spawn_blocking(move||{
        let client=http_client()?;
        let mut probe=|asset:&DeliveryAssetReview|check_remote_asset(&client,asset);
        review_channel_delivery_at(&PathBuf::from(draft_path),
            &cache_dir()?,&embedded_key()?,Some(&mut probe))
    }).await.map_err(|e|format!("Explicit delivery verification interrupted: {e}"))?
}

/// Test-only profile adapters exercise the same production intake and read
/// paths while providing explicit, isolated profile roots. No process-global
/// LOCALAPPDATA mutation, network request or production cache access.
#[cfg(test)]
pub(crate) mod test_api {
    use super::*;
    pub fn review(profile:&Path,package:&Path)->Result<LocalPublishReview,String>{
        with_publish_source(&package.display().to_string(),profile,|review,_,_,_|Ok(review))
    }
    pub fn import(profile:&Path,archive_cache:&Path,package:&Path,token:&str)->Result<CatalogChannelStatus,String>{
        import_at(profile,&package.display().to_string(),token,true,archive_cache)
    }
    pub fn channel_draft(package:&Path,profile:&Path,output:&Path)->Result<UnsignedCatalogChannelDraft,String>{
        prepare_catalog_channel_at(package,profile,output)
    }
    pub fn apply_signed(profile:&Path,body:&[u8],sig:&[u8],key:&[u8;32])->Result<CatalogChannelStatus,String>{
        apply_signed_at(profile,body,sig,key)
    }
    pub fn manifest(profile:&Path,id:&str,version:Option<&str>)->Result<Option<String>,String>{
        manifest_at(profile,id,version)
    }
    pub fn catalog(profile:&Path)->Vec<Experience>{
        let baseline:Vec<Experience>=serde_json::from_str(include_str!("../../resources/catalog.json"))
            .expect("bundled catalog");
        merged_catalog_at(profile,baseline)
    }
    pub fn provenance(profile:&Path)->Result<Vec<CatalogProvenance>,String>{
        provenance_at(profile)
    }
    pub fn delivery(draft:&Path,profile:&Path,key:&[u8;32])->Result<ChannelDeliveryReview,String>{
        review_channel_delivery_at(draft,profile,key,None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair,KeyPair};
    use std::sync::atomic::{AtomicU64,Ordering};
    use std::time::{SystemTime,UNIX_EPOCH};
    use zip::write::SimpleFileOptions;
    static SEQ:AtomicU64=AtomicU64::new(0);
    struct TestFixture{root:PathBuf}
    impl TestFixture{
        fn new()->Self{
            let stamp=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
            let root=std::env::temp_dir().join(format!("coco2-channel-{}-{stamp}-{}",
                std::process::id(),SEQ.fetch_add(1,Ordering::Relaxed)));
            fs::create_dir_all(&root).unwrap();
            Self{root}
        }
        fn snapshots(&self)->PathBuf{self.root.join("channel")}
        fn archive_cache(&self)->PathBuf{self.root.join("zip-cache")}
        fn package(&self,version:&str)->PathBuf{
            self.package_named("test-game",version)
        }
        fn portable(&self,version:&str)->PathBuf {
            let directory=self.package(version);
            self.portable_from(&directory,&format!("game-{version}.coco2pack.zip"),None,None)
        }
        fn portable_from(&self,directory:&Path,filename:&str,
            override_part:Option<(&str,&str)>,method:Option<zip::CompressionMethod>)->PathBuf {
            let output=self.root.join(filename);
            let mut writer=zip::ZipWriter::new(File::create(&output).unwrap());
            let opts=SimpleFileOptions::default()
                .compression_method(method.unwrap_or(zip::CompressionMethod::Stored));
            let manifest:Value=serde_json::from_slice(&fs::read(directory.join("publish-manifest.json")).unwrap()).unwrap();
            let cover=manifest["coverFile"].as_str().unwrap();
            let names=[
                "publish-manifest.json","catalog.template.json","catalog-candidate.json",
                "source-lock.json","coco2-client-entry.json","coco2-install-manifest.json",
                cover,"game.zip"
            ];
            for name in names {
                let archived=override_part.and_then(|(old,new)|if name==old{Some(new)}else{None})
                    .unwrap_or(name);
                writer.start_file(archived,opts).unwrap();
                writer.write_all(&fs::read(directory.join(name)).unwrap()).unwrap();
            }
            writer.finish().unwrap();
            output
        }
        fn package_named(&self,id:&str,version:&str)->PathBuf{
            let dir=self.root.join(format!("package-{}-{}",id,version.replace('.',"x")));
            fs::create_dir_all(&dir).unwrap();
            let zip_path=dir.join("game.zip");
            let data=format!("Game version {version}");
            let mut writer=zip::ZipWriter::new(File::create(&zip_path).unwrap());
            writer.start_file("Game.exe",SimpleFileOptions::default()).unwrap();
            writer.write_all(data.as_bytes()).unwrap();
            writer.finish().unwrap();
            let zip=fs::read(&zip_path).unwrap();
            let zipsha=hash(&zip);
            let cover=b"\x89PNG\r\n\x1a\nimage-bytes";
            let url="https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/game.zip";
            let exe_sha=hash(data.as_bytes());
            let required=serde_json::json!([{"path":"Game.exe","size":data.len(),"sha256":exe_sha}]);
            let candidate=serde_json::json!({
                "id":id,"name":"Test Game","instanceId":id,
                "runtime":{"executable":"Game.exe","requiredFiles":required},
                "pack":{"version":version,"archives":[{"archiveUrl":url,"sha256":zipsha,"size":zip.len()}]}
            });
            let source=serde_json::json!({"schemaVersion":1,"experiences":[candidate]});
            let lock=serde_json::json!({"schemaVersion":1,"experienceId":id,
                "archive":{"url":url,"sha256":zipsha,"size":zip.len()}});
            let client=serde_json::json!({
                "id":id,"instanceId":id,"name":"Test Game",
                "image":format!("/covers/{id}.png.webp"),"description":"Offline package",
                "workflow":"coco-standalone","minecraftVersion":"","loader":"",
                "requiredFiles":required,"executable":"Game.exe","launchArguments":[],"hostingMode":"p2p"
            });
            let installer=serde_json::json!({
                "id":id,"instanceId":id,"workflow":"coco-standalone",
                "version":version,"archives":[{"url":url,"sha256":zipsha,"size":zip.len()}],
                "requiredFiles":required,"extraFiles":[]
            });
            let encoded=|value:Value|serde_json::to_vec(&value).unwrap();
            let catalog=encoded(source);
            let candidate=encoded(candidate);
            let lock=encoded(lock);
            let client=encoded(client);
            let installer=encoded(installer);
            fs::write(dir.join("catalog.template.json"),&catalog).unwrap();
            fs::write(dir.join("catalog-candidate.json"),&candidate).unwrap();
            fs::write(dir.join("source-lock.json"),&lock).unwrap();
            fs::write(dir.join("cover.png"),cover).unwrap();
            fs::write(dir.join("coco2-client-entry.json"),&client).unwrap();
            fs::write(dir.join("coco2-install-manifest.json"),&installer).unwrap();
            let meta=serde_json::json!({
                "schemaVersion":1,"packageKind":"coco2-host-publish-offline",
                "id":id,"mode":"new","reviewedRights":true,
                "uploaded":false,"published":false,"installationsUpdated":false,
                "newVersion":version,"archiveSha256":zipsha,"archiveSize":zip.len(),
                "archiveUrl":url,
                "archiveFile":"game.zip","catalogFile":"catalog.template.json",
                "lockFile":"source-lock.json","coverFile":"cover.png",
                "resultCatalogSha256":hash(&catalog),
                "candidateSha256":hash(&candidate),"lockSha256":hash(&lock),
                "coverSha256":hash(cover),"clientPreviewSha256":hash(&client),
                "installPreviewSha256":hash(&installer)
            });
            fs::write(dir.join("publish-manifest.json"),encoded(meta)).unwrap();
            dir
        }
        fn accepted(&self,version:&str)->Accepted{
            let dir=self.package(version);
            verify_package(&dir,&self.root.join("isolated-entry-inspection")).unwrap().1
        }
    }
    impl Drop for TestFixture{fn drop(&mut self){let _=fs::remove_dir_all(&self.root);}}

    #[test]
    fn remote_manifest_accepts_distinct_verified_parts_and_rejects_unsafe_parts() {
        let fixture=TestFixture::new();
        let mut entry=fixture.accepted("1.0.0");
        entry.source="remote".into();
        let first=entry.manifest["archives"][0].clone();
        let mut second=first.clone();
        second["url"]=serde_json::json!("https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/game-part2.zip");
        second["sha256"]=serde_json::json!("b".repeat(64));
        entry.manifest["archives"].as_array_mut().unwrap().push(second);
        assert!(verify_entry(&entry).is_ok());
        entry.manifest["archives"][1]["url"]=first["url"].clone();
        assert!(verify_entry(&entry).is_err());
        entry.manifest["archives"][1]["url"]=serde_json::json!("https://example.com/game.zip");
        assert!(verify_entry(&entry).is_err());
        entry.manifest["archives"][1]["url"]=serde_json::json!("https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/game-part2.zip");
        entry.manifest["archives"][1]["sha256"]=first["sha256"].clone();
        assert!(verify_entry(&entry).is_err());
    }

    #[test]
    fn v31_distributed_client_blocks_unsigned_local_snapshot_in_current_catalog_and_manifest(){
        assert!(host_curated_client_guard().is_err(),
            "distributed Tauri command must never authorize a local package by consent alone");
        let f=TestFixture::new();
        let package=f.package_named("friend-picked-game","0.1.0");
        let review=test_api::review(&f.snapshots(),&package).unwrap();
        let status=test_api::import(&f.snapshots(),&f.archive_cache(),&package,&review.review_token).unwrap();
        assert_eq!(status.local_entries,1,"isolated host fixture retains offline import support");
        assert!(test_api::catalog(&f.snapshots()).iter().any(|e|e.id=="friend-picked-game"),
            "legacy host fixture must remain functional for offline tests");
        assert!(test_api::manifest(&f.snapshots(),"friend-picked-game",None).unwrap().is_some());
        let embedded:Vec<Experience>=serde_json::from_str(include_str!("../../resources/catalog.json")).unwrap();
        assert!(!client_catalog_view(&f.snapshots(),embedded.clone()).iter()
            .any(|e|e.id=="friend-picked-game"),
            "unsigned local package cannot add a game to distributed client catalog");
        assert!(client_manifest_at(&f.snapshots(),"friend-picked-game",None).unwrap().is_none(),
            "unsigned local package cannot supply an installable manifest");
        assert!(client_manifest_at(&f.snapshots(),"friend-picked-game",Some("0.1.0")).unwrap().is_none(),
            "legacy local snapshot versions cannot authorize installing or rollback");
        assert!(!client_provenance_view(&f.snapshots()).unwrap().iter()
            .any(|p|p.id=="friend-picked-game"),
            "friends must not see local unsigned IDs in available provenance");
        assert!(client_catalog_view(&f.snapshots(),embedded).iter()
            .any(|e|e.id=="coco-original"),"embedded baseline must be retained");
        assert!(client_manifest_at(&f.snapshots(),"big-walk",None).unwrap().is_some(),
            "embedded standalone manifest must remain installable");
    }

    #[test]
    fn v31_distributed_client_blocks_legacy_local_history_but_preserves_signed_and_embedded(){
        let f=TestFixture::new();
        let legacy=f.package_named("friend-legacy","0.1.0");
        let review=test_api::review(&f.snapshots(),&legacy).unwrap();
        test_api::import(&f.snapshots(),&f.archive_cache(),&legacy,&review.review_token).unwrap();

        let signing=Ed25519KeyPair::from_seed_unchecked(&[67u8;32]).unwrap();
        let mut key=[0u8;32];key.copy_from_slice(signing.public_key().as_ref());
        let official=Accepted{source:"remote".into(),..f.accepted("1.0.0")};
        let body=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":1,"sequence":1,"entries":[official]
        })).unwrap();
        let detached=STANDARD.encode(signing.sign(&body).as_ref());
        assert_eq!(test_api::apply_signed(&f.snapshots(),&body,detached.as_bytes(),&key)
            .unwrap().remote_sequence,1);

        let newer=f.package_named("friend-legacy","0.2.0");
        let review=test_api::review(&f.snapshots(),&newer).unwrap();
        test_api::import(&f.snapshots(),&f.archive_cache(),&newer,&review.review_token).unwrap();
        assert!(test_api::manifest(&f.snapshots(),"friend-legacy",Some("0.1.0")).unwrap().is_some(),
            "offline host fixture still has historic local snapshots");
        assert!(client_manifest_at(&f.snapshots(),"friend-legacy",Some("0.1.0")).unwrap().is_none(),
            "SHA-linked legacy history is not Ed25519 authorization");
        assert!(client_manifest_at(&f.snapshots(),"friend-legacy",Some("0.2.0")).unwrap().is_none());
        assert!(client_manifest_at(&f.snapshots(),"test-game",Some("1.0.0")).unwrap().is_some(),
            "a verified remote manifest remains available even after local snapshot revisions");
        assert!(client_manifest_at(&f.snapshots(),"big-walk",None).unwrap().is_some());
        let baseline:Vec<Experience>=serde_json::from_str(include_str!("../../resources/catalog.json")).unwrap();
        let client=client_catalog_view(&f.snapshots(),baseline);
        assert!(client.iter().any(|e|e.id=="test-game"));
        assert!(!client.iter().any(|e|e.id=="friend-legacy"));
        let provenance=client_provenance_view(&f.snapshots()).unwrap();
        assert!(provenance.iter().any(|p|p.id=="test-game"&&p.source=="official"));
        assert!(!provenance.iter().any(|p|p.id=="friend-legacy"));
        assert!(test_api::apply_signed(&f.snapshots(),&[body.as_slice(),b" "].concat(),
            detached.as_bytes(),&key).is_err(),"altered signed bytes must never be trusted");
    }

    #[test]
    fn v31_client_signed_official_channel_supersedes_legacy_local_collision(){
        let f=TestFixture::new();
        // Before 0.6.15 any friend could have imported an unsigned title and
        // arbitrarily high version. It cannot veto a legitimate signed host ID.
        let legacy=f.package("999.0.0");
        let review=test_api::review(&f.snapshots(),&legacy).unwrap();
        test_api::import(&f.snapshots(),&f.archive_cache(),&legacy,&review.review_token).unwrap();
        let signing=Ed25519KeyPair::from_seed_unchecked(&[93u8;32]).unwrap();
        let mut key=[0u8;32];key.copy_from_slice(signing.public_key().as_ref());
        let official=Accepted{source:"remote".into(),..f.accepted("1.0.0")};
        let body=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":1,"sequence":1,"entries":[official]
        })).unwrap();
        let signature=STANDARD.encode(signing.sign(&body).as_ref());
        assert!(test_api::apply_signed(&f.snapshots(),&body,signature.as_bytes(),&key).is_err(),
            "host test fixture retains explicit local-to-signed promotion rules");
        let status=client_apply_signed_at(&f.snapshots(),&body,signature.as_bytes(),&key).unwrap();
        assert_eq!(status.remote_sequence,1);
        assert_eq!(status.remote_entries,1);
        assert_eq!(status.local_entries,0);
        let catalog=client_catalog_view(&f.snapshots(),serde_json::from_str(
            include_str!("../../resources/catalog.json")).unwrap());
        assert!(catalog.iter().any(|e|e.id=="test-game"));
        assert_eq!(active(&f.snapshots()).unwrap().entries.iter()
            .find(|e|e.entry.id=="test-game").unwrap().source,"remote");
        assert!(client_manifest_at(&f.snapshots(),"test-game",None).unwrap().unwrap()
            .contains("\"version\":\"1.0.0\""));
        assert!(client_manifest_at(&f.snapshots(),"test-game",Some("999.0.0")).unwrap().is_none(),
            "old forged local version stays inert even in the signed chain's history");
    }

    #[test]
    fn local_review_requires_consent_streams_cache_and_retains_version_history(){
        let f=TestFixture::new();
        let first=f.package("1.0.0");
        let path=first.display().to_string();
        let (review,_,_)=verify_package(&first,&f.snapshots()).unwrap();
        assert_eq!(review.mode,"new");
        assert!(import_at(&f.snapshots(),&path,&review.review_token,false,&f.archive_cache()).is_err());
        assert!(!f.snapshots().exists());
        assert!(import_at(&f.snapshots(),&path,&"0".repeat(64),true,&f.archive_cache()).is_err());
        let result=import_at(&f.snapshots(),&path,&review.review_token,true,&f.archive_cache()).unwrap();
        assert_eq!(result.status,"updated");
        assert_eq!(result.local_entries,1);
        let cached=f.archive_cache().join(format!("{}.zip",review.archive_sha256));
        assert_eq!(fs::read(&cached).unwrap(),fs::read(first.join("game.zip")).unwrap());
        assert_eq!(manifest_at(&f.snapshots(),"test-game",None).unwrap().unwrap()
            .contains("\"version\":\"1.0.0\""),true);
        let second=f.package("1.2.0");
        let next=verify_package(&second,&f.snapshots()).unwrap().0;
        assert_eq!(next.old_version.as_deref(),Some("1.0.0"));
        assert_eq!(next.mode,"update");
        let done=import_at(&f.snapshots(),&second.display().to_string(),
            &next.review_token,true,&f.archive_cache()).unwrap();
        assert_eq!(done.revision,2);
        assert!(manifest_at(&f.snapshots(),"test-game",None).unwrap().unwrap()
            .contains("\"version\":\"1.2.0\""));
        assert!(manifest_at(&f.snapshots(),"test-game",Some("1.0.0")).unwrap().unwrap()
            .contains("\"version\":\"1.0.0\""));
        assert!(manifest_at(&f.snapshots(),"test-game",Some("0.0.1")).unwrap().is_none());
        assert!(verify_package(&first,&f.snapshots()).is_err(),"older package rollback rejected");
    }
    #[test]
    fn corrupt_cache_or_pointer_falls_back_and_never_overwrites_user_data(){
        let f=TestFixture::new();
        let first=f.package("1.0.0");
        let review=verify_package(&first,&f.snapshots()).unwrap().0;
        let archived=f.archive_cache().join(format!("{}.zip",review.archive_sha256));
        fs::create_dir_all(f.archive_cache()).unwrap();
        fs::write(&archived,b"not the verified pack").unwrap();
        assert!(import_at(&f.snapshots(),&first.display().to_string(),
            &review.review_token,true,&f.archive_cache()).is_err());
        assert_eq!(fs::read(archived).unwrap(),b"not the verified pack");
        assert!(f.snapshots().join("current.json").exists()==false);
        fs::create_dir_all(f.snapshots()).unwrap();
        fs::write(f.snapshots().join("current.json"),b"{\"invalid\":true}").unwrap();
        assert!(load(&f.snapshots()).is_err());
    }
    #[test]
    fn cache_archive_is_invisible_until_verified_and_never_replaces_concurrent_file(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let review=verify_package(&package,&f.snapshots()).unwrap().0;
        let source=package.join("game.zip");
        let expected=fs::metadata(&source).unwrap().len();
        let cache=f.archive_cache();
        seed_cache_with_hook(&source,&review.archive_sha256,expected,&cache,|stage,target|{
            assert!(stage.is_file());
            assert!(!target.exists(),"installer cannot observe partial final archive");
            assert!(stage.file_name().unwrap().to_string_lossy().ends_with(".import-part"));
        }).unwrap();
        let final_path=cache.join(format!("{}.zip",review.archive_sha256));
        assert_eq!(fs::read(final_path).unwrap(),fs::read(&source).unwrap());
        let other=f.root.join("other-cache");
        let result=seed_cache_with_hook(&source,&review.archive_sha256,expected,&other,|stage,target|{
            assert!(stage.exists());
            assert!(!target.exists());
            fs::write(target,b"concurrent-corrupt-user-cache").unwrap();
        });
        assert!(result.is_err());
        assert_eq!(fs::read(other.join(format!("{}.zip",review.archive_sha256))).unwrap(),
            b"concurrent-corrupt-user-cache");
        assert_eq!(fs::read_dir(other).unwrap().count(),1,"private staging cleaned after conflict");
    }
    #[cfg(windows)]
    #[test]
    fn verified_cache_publication_supports_long_workspace_paths(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let review=verify_package(&package,&f.snapshots()).unwrap().0;
        let source=package.join("game.zip");
        let size=fs::metadata(&source).unwrap().len();
        let cache=f.root.join("long-workspace-".repeat(12)).join("download-cache");
        assert!(cache.join(format!("{}.zip",review.archive_sha256)).as_os_str().len()>260);
        seed_cache(&source,&review.archive_sha256,size,&cache).unwrap();
        let published=cache.join(format!("{}.zip",review.archive_sha256));
        assert_eq!(fs::read(&published).unwrap(),fs::read(&source).unwrap());
        let collision_cache=cache.join("collision");
        assert!(seed_cache_with_hook(&source,&review.archive_sha256,size,&collision_cache,|_,target|{
            fs::write(target,b"keep concurrent bytes").unwrap();
        }).is_err());
        assert_eq!(fs::read(collision_cache.join(format!("{}.zip",review.archive_sha256))).unwrap(),b"keep concurrent bytes");
    }
    #[cfg(windows)]
    #[test]
    fn verified_cache_stage_refuses_concurrent_writer_until_atomic_publish(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let review=verify_package(&package,&f.snapshots()).unwrap().0;
        let source=package.join("game.zip");
        let size=fs::metadata(&source).unwrap().len();
        let cache=f.root.join("sealed-cache");
        let mut denied=false;
        seed_cache_with_hook(&source,&review.archive_sha256,size,&cache,|stage,target|{
            assert!(!target.exists(),"verified cache must not appear before rename");
            assert!(stage.exists());
            denied=OpenOptions::new().write(true).open(stage).is_err();
            assert!(denied,"Win32 verified stage must deny writers before MoveFileW");
        }).unwrap();
        assert!(denied);
        let final_path=cache.join(format!("{}.zip",review.archive_sha256));
        assert_eq!(fs::read(&final_path).unwrap(),fs::read(&source).unwrap());
        assert_eq!(fs::read_dir(&cache).unwrap().count(),1,"no orphaned stage after publication");
        // An identical confirmed import is a cache no-op, not a rewrite.
        seed_cache(&source,&review.archive_sha256,size,&cache).unwrap();
        assert_eq!(fs::read_dir(cache).unwrap().count(),1);
    }

    #[test]
    fn pointer_commit_recovers_from_legacy_crash_stage_without_deleting_foreign_files(){
        let f=TestFixture::new();
        let dir=f.snapshots();
        fs::create_dir_all(&dir).unwrap();
        let stale=dir.join(format!(".current-{}-1.stage",std::process::id()));
        let stale_backup=dir.join(format!(".current-{}-1.bak",std::process::id()));
        fs::write(&stale,b"crash stage - preserve for owner diagnostics").unwrap();
        fs::write(&stale_backup,b"old crash backup - do not overwrite").unwrap();
        let mut candidate=empty();candidate.remote_sequence=1;
        commit(&dir,candidate,None).unwrap();
        assert_eq!(active(&dir).unwrap().revision,1);
        assert_eq!(fs::read(&stale).unwrap(),b"crash stage - preserve for owner diagnostics");
        assert_eq!(fs::read(&stale_backup).unwrap(),b"old crash backup - do not overwrite");
        assert!(dir.join("current.json").exists());
        let stages=fs::read_dir(&dir).unwrap().filter_map(Result::ok)
            .filter(|f|f.file_name().to_string_lossy().ends_with(".stage"))
            .map(|f|f.path()).collect::<Vec<_>>();
        assert_eq!(stages,vec![stale],"successful pointer retry must clean only its new stage");
        let (snapshot,sha)=load(&dir).unwrap();
        assert_eq!(snapshot.remote_sequence,1);
        let mut next=snapshot;next.remote_sequence=2;
        commit(&dir,next,sha).unwrap();
        assert_eq!(active(&dir).unwrap().revision,2);
    }

    #[test]
    fn simultaneous_confirmed_local_imports_commit_only_one_snapshot_and_cache_zip(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let snapshot_dir=f.snapshots();
        let archive_cache=f.archive_cache();
        let review=verify_package(&package,&snapshot_dir).unwrap().0;
        let source=package.display().to_string();
        let mut workers=Vec::new();
        for _ in 0..2 {
            let (dir,cache,path,token)=(snapshot_dir.clone(),archive_cache.clone(),
                source.clone(),review.review_token.clone());
            workers.push(std::thread::spawn(move||import_at(&dir,&path,&token,true,&cache)));
        }
        let mut status=workers.into_iter().map(|thread|thread.join().unwrap()
            .expect("one confirmed import may update; second must be idempotent"))
            .map(|result|result.status).collect::<Vec<_>>();
        status.sort();
        assert_eq!(status,vec!["unchanged","updated"]);
        let current=active(&snapshot_dir).unwrap();
        assert_eq!(current.revision,1);
        assert_eq!(current.entries.len(),1);
        assert_eq!(current.entries[0].version,"1.0.0");
        let cached=archive_cache.join(format!("{}.zip",review.archive_sha256));
        assert_eq!(fs::read(&cached).unwrap(),fs::read(package.join("game.zip")).unwrap());
        assert_eq!(fs::read_dir(&archive_cache).unwrap().count(),1,
            "concurrent confirmed imports must leave no temporary ZIPs");
    }
    #[test]
    fn local_package_rejects_tampering_symlink_traversal_and_stale_review(){
        let f=TestFixture::new();
        let first=f.package("1.0.0");
        let review=verify_package(&first,&f.snapshots()).unwrap().0;
        let client=first.join("coco2-client-entry.json");
        let original=fs::read(&client).unwrap();
        fs::write(&client,b"{}").unwrap();
        assert!(verify_package(&first,&f.snapshots()).is_err());
        fs::write(&client,original).unwrap();
        #[cfg(windows)]{
            use std::os::windows::fs::symlink_file;
            let link=first.join("source-lock.json");
            let renamed=first.join("source-lock.original");
            fs::rename(&link,&renamed).unwrap();
            if symlink_file(&renamed,&link).is_ok(){
                assert!(verify_package(&first,&f.snapshots()).is_err());
                fs::remove_file(&link).unwrap();
            }
            fs::rename(renamed,link).unwrap();
        }
        let bad=f.root.join("bad.zip");
        let mut writer=zip::ZipWriter::new(File::create(&bad).unwrap());
        writer.start_file("../escape.exe",SimpleFileOptions::default()).unwrap();
        writer.write_all(b"malicious").unwrap();writer.finish().unwrap();
        assert!(validate_package_zip(&bad,&[]).is_err());
        let mut changed=empty();changed.remote_sequence=2;
        commit(&f.snapshots(),changed,None).unwrap();
        assert!(import_at(&f.snapshots(),&first.display().to_string(),
            &review.review_token,true,&f.archive_cache()).is_err(),"review token bound to prior snapshot");
    }
    #[test]
    fn ed25519_channel_enforces_embedded_key_format_exact_signature_and_sequence(){
        let f=TestFixture::new();
        let actual=embedded_key().expect("Tauri updater public key has minisign raw Ed25519 format");
        assert_eq!(actual.len(),32);
        let signing=Ed25519KeyPair::from_seed_unchecked(&[5u8;32]).unwrap();
        let mut key=[0u8;32];key.copy_from_slice(signing.public_key().as_ref());
        let entry=f.accepted("2.0.0");
        let remote=Accepted{source:"remote".into(),..entry};
        let body=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":1,"sequence":1,"entries":[remote]
        })).unwrap();
        let signature=STANDARD.encode(signing.sign(&body).as_ref());
        assert!(verify_signed_channel(&body,signature.as_bytes(),&key).is_ok());
        assert!(verify_signed_channel(&body,b"dW5zaWduZWQ=",&key).is_err());
        assert!(verify_signed_channel(&body,signature.as_bytes(),&actual).is_err());
        let accepted=apply_signed_at(&f.snapshots(),&body,signature.as_bytes(),&key).unwrap();
        assert_eq!(accepted.remote_sequence,1);
        assert_eq!(accepted.remote_entries,1);
        let repeated=apply_signed_at(&f.snapshots(),&body,signature.as_bytes(),&key).unwrap();
        assert_eq!(repeated.status,"unchanged");
        assert_eq!(repeated.revision,accepted.revision);
        let changed=body.iter().copied().chain(b" ".iter().copied()).collect::<Vec<_>>();
        assert!(verify_signed_channel(&changed,signature.as_bytes(),&key).is_err());
        assert!(!allowed_http_redirect(&reqwest::Url::parse("https://evil.example/a").unwrap()));
        assert!(!allowed_http_redirect(&reqwest::Url::parse("http://github.com/a").unwrap()));
        assert!(allowed_http_redirect(&reqwest::Url::parse(OFFICIAL_CATALOG).unwrap()));
        assert!(allowed_http_redirect(&reqwest::Url::parse("https://release-assets.githubusercontent.com/a?token=abc").unwrap()));
    }
    #[test]
    fn host_channel_draft_is_immutable_unsigned_and_compatible_with_signed_sync(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let drafts=f.root.join("channel-drafts");
        let draft=prepare_catalog_channel_at(&package,&f.snapshots(),&drafts).unwrap();
        assert_eq!(draft.id,"test-game");
        assert_eq!(draft.sequence,1);
        assert_eq!(draft.entries,1);
        assert_eq!(draft.status,"staged-assets-upload-required");
        assert!(!draft.ready_for_signature);
        assert_eq!(draft.publication_assets.len(),3);
        assert!(draft.publication_assets.iter().all(|a|!a.uploaded));
        assert_eq!(hash(&fs::read(&draft.archive_path).unwrap()),
            draft.publication_assets[0].sha256);
        assert!(draft.review_note.contains("NOT SIGNED OR UPLOADED"));
        assert!(!PathBuf::from(&draft.signature_path).exists());
        let bytes=fs::read(&draft.channel_draft_path).unwrap();
        assert_eq!(hash(&bytes),draft.channel_sha256);
        let channel:Value=serde_json::from_slice(&bytes).unwrap();
        assert_eq!(channel["entries"][0]["source"],"remote");
        assert!(channel["entries"][0]["entry"]["image"].as_str().unwrap()
            .starts_with("data:image/png;base64,"));
        assert!(prepare_catalog_channel_at(&package,&f.snapshots(),&drafts).is_err());
        let signing=Ed25519KeyPair::from_seed_unchecked(&[19u8;32]).unwrap();
        let mut key=[0u8;32];key.copy_from_slice(signing.public_key().as_ref());
        let signature=STANDARD.encode(signing.sign(&bytes).as_ref());
        assert!(verify_signed_channel(&bytes,signature.as_bytes(),&key).is_ok());
        let status=apply_signed_at(&f.snapshots(),&bytes,signature.as_bytes(),&key).unwrap();
        assert_eq!(status.remote_entries,1);
    }

    #[test]
    fn trust_boundaries_reject_local_official_impersonation_and_require_signed_promotion(){
        let f=TestFixture::new();
        // This ID is already shipped by the trusted Coco2 installer; a
        // higher version in an unsigned package confers no official authority.
        let embedded=f.package_named("big-walk","999.0.0");
        assert!(verify_package(&embedded,&f.snapshots()).unwrap_err()
            .contains("official embedded"));
        let local=f.package("1.0.0");
        let review=test_api::review(&f.snapshots(),&local).unwrap();
        test_api::import(&f.snapshots(),&f.archive_cache(),&local,&review.review_token).unwrap();
        let signing=Ed25519KeyPair::from_seed_unchecked(&[7u8;32]).unwrap();
        let mut key=[0u8;32];key.copy_from_slice(signing.public_key().as_ref());
        let remote=Accepted{source:"remote".into(),..f.accepted("1.2.0")};
        let unsigned=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":1,"sequence":1,"entries":[remote]
        })).unwrap();
        let unsigned_signature=STANDARD.encode(signing.sign(&unsigned).as_ref());
        assert!(apply_signed_at(&f.snapshots(),&unsigned,unsigned_signature.as_bytes(),&key)
            .unwrap_err().contains("promotion required"));
        let valid_local=active(&f.snapshots()).unwrap().entries.into_iter().next().unwrap();
        let remote=Accepted{source:"remote".into(),..f.accepted("1.2.0")};
        let mut promotion=previous_promotion(&valid_local,&remote).unwrap();
        promotion.previous_local_manifest_sha256="0".repeat(64);
        let tampered=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":1,"sequence":1,"entries":[remote],"promotions":[promotion]
        })).unwrap();
        let signed=STANDARD.encode(signing.sign(&tampered).as_ref());
        assert!(apply_signed_at(&f.snapshots(),&tampered,signed.as_bytes(),&key)
            .unwrap_err().contains("identity and hashes"));
        assert_eq!(active(&f.snapshots()).unwrap().remote_sequence,0);
        let safe=Accepted{source:"remote".into(),..f.accepted("1.2.0")};
        let promotion=previous_promotion(&valid_local,&safe).unwrap();
        let bytes=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":1,"sequence":1,"entries":[safe],"promotions":[promotion]
        })).unwrap();
        let signed=STANDARD.encode(signing.sign(&bytes).as_ref());
        apply_signed_at(&f.snapshots(),&bytes,signed.as_bytes(),&key).unwrap();
        assert_eq!(active(&f.snapshots()).unwrap().entries[0].source,"remote");
        let higher=f.package("3.0.0");
        assert!(verify_package(&higher,&f.snapshots()).unwrap_err().contains("signed official release"));
        // A legacy snapshot can never restore a locally forged official ID.
        let mut legacy=empty();
        let forged=Accepted{source:"local".into(),..f.accepted("999.1.0")};
        let mut spoof=forged;
        spoof.entry.id="big-walk".into();
        spoof.entry.instance_id="big-walk".into();
        spoof.manifest["id"]="big-walk".into();
        spoof.manifest["instanceId"]="big-walk".into();
        legacy.entries.push(spoof);
        assert!(verify_snapshot(&legacy).unwrap_err().contains("protected"));
    }

    #[test]
    fn isolated_native_host_client_signed_e2e_retains_local_and_history_without_env_changes(){
        let f=TestFixture::new();
        let host=f.root.join("host/LOCALAPPDATA/CocoLauncher2/catalog-channel");
        let client=f.root.join("client/LOCALAPPDATA/CocoLauncher2/catalog-channel");
        let host_archive=f.root.join("host/LOCALAPPDATA/CocoMinecraftUpdater/downloads/standalone-packs");
        let client_archive=f.root.join("client/LOCALAPPDATA/CocoMinecraftUpdater/downloads/standalone-packs");
        let host_drafts=f.root.join("host/channel-drafts");
        let signer=Ed25519KeyPair::from_seed_unchecked(&[41u8;32]).unwrap();
        let mut key=[0u8;32];key.copy_from_slice(signer.public_key().as_ref());
        let first=f.package("1.0.0");
        let host_review=test_api::review(&host,&first).unwrap();
        let client_review=test_api::review(&client,&first).unwrap();
        test_api::import(&host,&host_archive,&first,&host_review.review_token).unwrap();
        test_api::import(&client,&client_archive,&first,&client_review.review_token).unwrap();
        let unrelated=f.package_named("my-private-game","0.1.0");
        let review=test_api::review(&client,&unrelated).unwrap();
        test_api::import(&client,&client_archive,&unrelated,&review.review_token).unwrap();
        let publication=test_api::channel_draft(&first,&host,&host_drafts).unwrap();
        let offline=test_api::delivery(&PathBuf::from(&publication.channel_draft_path),&host,
            &embedded_key().unwrap()).unwrap();
        assert_eq!(offline.status,"unsigned");
        assert!(offline.ready_for_signature);
        assert!(!offline.ready_for_upload);
        assert!(!offline.remote_checked);
        assert!(offline.assets.iter().all(|asset|!asset.remote_available));
        assert!(!publication.ready_for_signature);
        assert!(publication.publication_assets.iter().all(|a|!a.uploaded));
        assert_eq!(publication.entries,1,"private client packages must not leak into official channel");
        let body=fs::read(&publication.channel_draft_path).unwrap();
        let channel:Value=serde_json::from_slice(&body).unwrap();
        assert_eq!(channel["promotions"].as_array().unwrap().len(),1);
        let signature=STANDARD.encode(signer.sign(&body).as_ref());
        let outcome=test_api::apply_signed(&client,&body,signature.as_bytes(),&key).unwrap();
        assert_eq!(outcome.remote_sequence,1);
        assert_eq!(outcome.local_entries,1);
        assert_eq!(outcome.remote_entries,1);
        assert_eq!(test_api::apply_signed(&client,&body,signature.as_bytes(),&key).unwrap().status,"unchanged");
        let catalog=test_api::catalog(&client);
        assert!(catalog.iter().any(|e|e.id=="test-game"&&e.image.starts_with("data:image/png;base64,")));
        assert!(catalog.iter().any(|e|e.id=="my-private-game"));
        let provenance=test_api::provenance(&client).unwrap();
        assert!(provenance.iter().any(|e|e.id=="test-game"&&e.source=="official"));
        assert!(provenance.iter().any(|e|e.id=="my-private-game"&&e.source=="local"));
        assert!(provenance.iter().any(|e|e.id=="coco-original"&&e.source=="embedded"));
        assert!(test_api::manifest(&client,"test-game",None).unwrap().unwrap().contains("\"1.0.0\""));
        assert!(test_api::manifest(&client,"big-walk",None).unwrap().is_some());
        let mut forged_body=body.clone();
        forged_body.push(b' ');
        assert!(test_api::apply_signed(&client,&forged_body,signature.as_bytes(),&key).is_err());
        assert_eq!(active(&client).unwrap().remote_sequence,1);
        // Host separately accepts its own signed release before producing s2.
        test_api::apply_signed(&host,&body,signature.as_bytes(),&key).unwrap();
        let second=f.package("1.2.0");
        let revision_two=test_api::channel_draft(&second,&host,&host_drafts).unwrap();
        assert_eq!(revision_two.sequence,2);
        let bytes=fs::read(&revision_two.channel_draft_path).unwrap();
        let second_sig=STANDARD.encode(signer.sign(&bytes).as_ref());
        assert_eq!(test_api::apply_signed(&client,&bytes,second_sig.as_bytes(),&key)
            .unwrap().remote_sequence,2);
        assert!(test_api::manifest(&client,"test-game",None).unwrap().unwrap().contains("\"1.2.0\""));
        assert!(test_api::manifest(&client,"test-game",Some("1.0.0")).unwrap().unwrap()
            .contains("\"1.0.0\""));
        assert!(test_api::manifest(&client,"my-private-game",None).unwrap().is_some());
        let (current,sha)=load(&client).unwrap();
        assert_eq!(current.remote_sequence,2);
        let snapshot_path=snapshot_path(&client,&sha.unwrap());
        fs::write(&snapshot_path,b"tampered").unwrap();
        assert!(!test_api::catalog(&client).iter().any(|e|e.id=="test-game"));
        assert!(test_api::manifest(&client,"test-game",None).is_err());
        assert!(test_api::catalog(&host).iter().any(|e|e.id=="test-game"));
    }

    #[test]
    fn delivery_review_unsigned_is_read_only_and_full_sha_lock_catches_prefix_collision(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let draft=prepare_catalog_channel_at(&package,&f.snapshots(),&f.root.join("channel-drafts")).unwrap();
        let path=PathBuf::from(&draft.channel_draft_path);
        let key=embedded_key().unwrap();
        let first=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(first.status,"unsigned");
        assert!(first.ready_for_signature);
        assert!(!first.ready_for_upload);
        assert!(!first.signature_trusted);
        assert_eq!(first.assets.len(),3);
        assert!(first.assets[0].present_local&&first.assets[0].verified_local);
        assert!(first.assets[1].present_local&&first.assets[1].verified_local);
        assert!(!first.assets[2].present_local&&!first.assets[2].verified_local);
        assert!(first.assets.iter().all(|asset|!asset.remote_available));
        assert_eq!(first.assets[0].expected_url,OFFICIAL_CATALOG);
        assert_eq!(first.assets[1].expected_sha256.as_deref(),Some(draft.publication_assets[0].sha256.as_str()));
        assert_eq!(first.assets[2].expected_url,OFFICIAL_SIGNATURE);
        assert!(!path.with_file_name("coco2-catalog-channel.json.sig").exists());
        let second=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(second.status,first.status);
        assert_eq!(fs::read(&path).unwrap(),fs::read(&draft.channel_draft_path).unwrap());
        let lock_path=path.with_file_name("delivery-lock.json");
        let original=fs::read(&lock_path).unwrap();
        let mut lock:Value=serde_json::from_slice(&original).unwrap();
        let expected=lock["channelSha256"].as_str().unwrap().to_string();
        let fake_suffix=if expected.ends_with('a'){'b'}else{'a'};
        lock["channelSha256"]=format!("{}{}",&expected[..16],fake_suffix.to_string().repeat(48)).into();
        fs::write(&lock_path,serde_json::to_vec(&lock).unwrap()).unwrap();
        let collision=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(collision.status,"invalid");
        assert!(collision.issues.iter().any(|i|i.contains("SHA256")));
        fs::write(lock_path,original).unwrap();
    }

    #[test]
    fn delivery_review_detects_zip_replacement_missing_files_bad_url_and_history(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let draft=prepare_catalog_channel_at(&package,&f.snapshots(),&f.root.join("channel-drafts")).unwrap();
        let path=PathBuf::from(&draft.channel_draft_path);
        let key=embedded_key().unwrap();
        let archive=PathBuf::from(&draft.archive_path);
        let original=fs::read(&archive).unwrap();
        let mut modified=original.clone();modified[0]^=0x12;
        fs::write(&archive,modified).unwrap();
        let invalid=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(invalid.status,"invalid");
        assert!(invalid.assets[1].present_local&&!invalid.assets[1].verified_local);
        fs::remove_file(&archive).unwrap();
        let missing=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert!(!missing.assets[1].present_local);
        assert!(!missing.ready_for_upload);
        fs::write(&archive,original).unwrap();
        let locked=path.with_file_name("delivery-lock.json");
        let original_lock=fs::read(&locked).unwrap();
        let mut lock:Value=serde_json::from_slice(&original_lock).unwrap();
        lock["archiveUrl"]="https://evil.example/releases/download/v1/game.zip".into();
        fs::write(&locked,serde_json::to_vec(&lock).unwrap()).unwrap();
        let bad=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(bad.status,"invalid");
        assert!(bad.issues.iter().any(|issue|issue.contains("ownership")));
        fs::write(&locked,&original_lock).unwrap();
        let mut new_state=empty();new_state.remote_sequence=1;
        commit(&f.snapshots(),new_state,None).unwrap();
        let stale=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(stale.status,"stale");
        assert!(!stale.ready_for_signature);
        assert!(stale.issues.iter().any(|issue|issue.contains("sequence")));
        let (saved,sha)=load(&f.snapshots()).unwrap();
        assert_eq!(saved.remote_sequence,1);
        fs::write(snapshot_path(&f.snapshots(),&sha.unwrap()),b"broken snapshot").unwrap();
        let corrupted=review_channel_delivery_at(&path,&f.snapshots(),&key,None).unwrap();
        assert_eq!(corrupted.status,"stale");
        assert!(corrupted.issues.iter().any(|i|i.contains("history")));
    }

    #[test]
    fn delivery_review_signature_must_match_embedded_key_and_remote_stays_unverified_offline(){
        let f=TestFixture::new();
        let package=f.package("1.0.0");
        let draft=prepare_catalog_channel_at(&package,&f.snapshots(),&f.root.join("channel-drafts")).unwrap();
        let path=PathBuf::from(&draft.channel_draft_path);
        let signing=Ed25519KeyPair::from_seed_unchecked(&[57u8;32]).unwrap();
        let mut synthetic=[0u8;32];synthetic.copy_from_slice(signing.public_key().as_ref());
        let sig=STANDARD.encode(signing.sign(&fs::read(&path).unwrap()).as_ref());
        fs::write(&draft.signature_path,sig.as_bytes()).unwrap();
        let rejected=review_channel_delivery_at(&path,&f.snapshots(),&embedded_key().unwrap(),None).unwrap();
        assert_eq!(rejected.status,"signature-invalid");
        assert!(!rejected.signature_trusted);
        assert!(!rejected.ready_for_upload);
        assert!(rejected.assets[2].present_local&&!rejected.assets[2].verified_local);
        let accepted=review_channel_delivery_at(&path,&f.snapshots(),&synthetic,None).unwrap();
        assert_eq!(accepted.status,"signed-local");
        assert!(accepted.signature_trusted&&accepted.ready_for_upload);
        assert!(!accepted.all_remote_verified&&!accepted.remote_checked);
        assert!(accepted.assets.iter().all(|asset|!asset.remote_available));
        let mut denied=|_asset:&DeliveryAssetReview|->Result<bool,String>{Err("offline".into())};
        let offline=review_channel_delivery_at(&path,&f.snapshots(),&synthetic,Some(&mut denied)).unwrap();
        assert!(offline.remote_checked);
        assert!(!offline.all_remote_verified);
        assert!(offline.assets.iter().all(|asset|!asset.remote_available));
        assert_eq!(offline.status,"signed-local");
        let mut synthetic_remote=|asset:&DeliveryAssetReview|->Result<bool,String>{
            // Synthetic server response: hash the locally pinned fixtures as
            // remote exact bytes. No HTTP requests are made by this test.
            let bytes=fs::read(path.with_file_name(&asset.name)).unwrap();
            Ok(asset.expected_size==Some(bytes.len() as u64)
                && asset.expected_sha256.as_deref()==Some(hash(&bytes).as_str()))
        };
        let verified=review_channel_delivery_at(&path,&f.snapshots(),&synthetic,
            Some(&mut synthetic_remote)).unwrap();
        assert!(verified.remote_checked&&verified.all_remote_verified);
        assert_eq!(verified.status,"remote-verified");
        assert!(verified.assets.iter().all(|asset|asset.remote_available));
        let mut signature=fs::read(&draft.signature_path).unwrap();
        signature[4]=if signature[4]==b'A'{b'B'}else{b'A'};
        fs::write(&draft.signature_path,signature).unwrap();
        let corrupt=review_channel_delivery_at(&path,&f.snapshots(),&synthetic,None).unwrap();
        assert_eq!(corrupt.status,"signature-invalid");
        assert!(!corrupt.signature_trusted);
        assert!(!corrupt.ready_for_upload);
    }

    #[test]
    fn portable_store_envelope_review_import_repeat_and_upgrade_are_idempotent(){
        let f=TestFixture::new();
        let first=f.portable("1.0.0");
        let path=first.display().to_string();
        let root=f.snapshots();
        let inspect=|p:&str|with_publish_source(p,&root,|review,entry,zip,pack|{
            assert_eq!(entry.entry.id,"test-game");
            assert!(zip.ancestors().any(|parent|parent.file_name()
                .is_some_and(|name|name=="portable-staging")));
            assert!(pack.is_some());
            Ok(review)
        });
        let review=inspect(&path).unwrap();
        assert_eq!(review.id,"test-game");
        assert_eq!(review.status,"ready-for-review");
        assert_eq!(review.name,"Test Game");
        assert_eq!(review.executable,"Game.exe");
        assert_eq!(review.required_files_count,1);
        assert!(review.cover_data_url.starts_with("data:image/png;base64,"));
        assert_eq!(review.portable_sha256.as_deref(),Some(hash(&fs::read(&first).unwrap()).as_str()));
        assert!(review.changed_fields.iter().any(|field|field=="catalog-entry-and-archive"));
        assert!(import_at(&root,&path,&review.review_token,false,&f.archive_cache()).is_err());
        assert!(import_at(&root,&path,&"0".repeat(64),true,&f.archive_cache()).is_err());
        assert_eq!(import_at(&root,&path,&review.review_token,true,&f.archive_cache()).unwrap().status,"updated");
        let cache=f.archive_cache().join(format!("{}.zip",review.archive_sha256));
        let first_zip=f.root.join("package-test-game-1x0x0").join("game.zip");
        assert_eq!(fs::read(&cache).unwrap(),fs::read(&first_zip).unwrap());
        let pointer_before=fs::read(root.join("current.json")).unwrap();
        // A replay of the exact reviewed token and source is an unchanged,
        // verified no-op; it never publishes/re-writes the snapshot.
        assert_eq!(import_at(&root,&path,&review.review_token,true,&f.archive_cache()).unwrap().status,"unchanged");
        let again=inspect(&path).unwrap();
        assert_eq!(again.status,"unchanged");
        assert_eq!(import_at(&root,&path,&again.review_token,true,&f.archive_cache()).unwrap().status,"unchanged");
        assert_eq!(fs::read(root.join("current.json")).unwrap(),pointer_before);
        // Missing user download cache may be restored, without publishing a
        // new catalog revision or overwriting any existing corrupted file.
        fs::remove_file(&cache).unwrap();
        assert_eq!(import_at(&root,&path,&review.review_token,true,&f.archive_cache()).unwrap().status,"unchanged");
        assert_eq!(fs::read(&cache).unwrap(),fs::read(&first_zip).unwrap());
        fs::write(&cache,b"corrupt-user-cache").unwrap();
        assert!(import_at(&root,&path,&review.review_token,true,&f.archive_cache()).is_err());
        assert_eq!(fs::read(&cache).unwrap(),b"corrupt-user-cache");
        assert_eq!(fs::read(root.join("current.json")).unwrap(),pointer_before);
        fs::write(&cache,fs::read(&first_zip).unwrap()).unwrap();
        let second=f.portable("1.2.0");
        let next=inspect(&second.display().to_string()).unwrap();
        assert_eq!(next.new_version,"1.2.0");
        assert_eq!(next.old_version.as_deref(),Some("1.0.0"));
        assert_eq!(import_at(&root,&next.source_path,&next.review_token,true,&f.archive_cache()).unwrap().status,"updated");
        assert!(manifest_at(&root,"test-game",None).unwrap().unwrap().contains("\"1.2.0\""));
        assert!(manifest_at(&root,"test-game",Some("1.0.0")).unwrap().unwrap().contains("\"1.0.0\""));
        assert!(import_at(&root,&path,&review.review_token,true,&f.archive_cache()).is_err(),"rollback refused");
    }

    #[test]
    fn portable_zip_rejects_duplicate_traversal_unknown_member_and_compression(){
        let f=TestFixture::new();
        let original=f.package("1.0.0");
        for (file,old,new,method) in [
            ("traversal.coco2pack.zip","catalog.template.json","../escape.json",None),
            ("unlisted.coco2pack.zip","catalog.template.json","extra.json",None),
            ("wrongcase.coco2pack.zip","catalog.template.json","CATALOG.template.JSON",None),
            ("compressed.coco2pack.zip","","",Some(zip::CompressionMethod::Deflated)),
        ] {
            let changed=if old.is_empty(){None}else{Some((old,new))};
            let zip=f.portable_from(&original,file,changed,method);
            assert!(with_publish_source(&zip.display().to_string(),&f.snapshots(),|r,_,_,_|Ok(r)).is_err(),
                "Unexpectedly accepted malicious portable {file}");
        }
        let valid=f.portable_from(&original,"good.coco2pack.zip",None,None);
        let mut duplicate=fs::read(valid).unwrap();
        let old=b"catalog.template.json";
        let new=b"publish-manifest.json";
        assert_eq!(old.len(),new.len());
        let mut replacements=0;
        for index in 0..=duplicate.len()-old.len(){
            if &duplicate[index..index+old.len()]==old {
                duplicate[index..index+old.len()].copy_from_slice(new);
                replacements+=1;
            }
        }
        assert!(replacements>=2);
        let bad_duplicate=f.root.join("duplicate.coco2pack.zip");
        fs::write(&bad_duplicate,duplicate).unwrap();
        assert!(portable::unpack(&bad_duplicate.display().to_string(),&f.snapshots()).is_err());
        let evil=f.root.join("extra-member.coco2pack.zip");
        let mut writer=zip::ZipWriter::new(File::create(&evil).unwrap());
        let opts=SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for name in ["publish-manifest.json","catalog.template.json","catalog-candidate.json",
            "source-lock.json","coco2-client-entry.json","coco2-install-manifest.json",
            "cover.png","game.zip","extra.json"]{
            writer.start_file(name,opts).unwrap();writer.write_all(b"x").unwrap();
        }
        writer.finish().unwrap();
        assert!(portable::unpack(&evil.display().to_string(),&f.snapshots()).is_err());
        assert!(!f.snapshots().join("current.json").exists());
    }

    #[test]
    fn portable_source_whole_sha_binds_review_token_and_corrupt_portable_never_commits(){
        let f=TestFixture::new();
        let portable=f.portable("1.0.0");
        let path=portable.display().to_string();
        let reviewed=with_publish_source(&path,&f.snapshots(),|r,_,_,_|Ok(r)).unwrap();
        let pristine=fs::read(&portable).unwrap();
        let mut altered=pristine.clone();altered.extend_from_slice(b"appended-untrusted-envelope-data");
        fs::write(&portable,&altered).unwrap();
        assert!(import_at(&f.snapshots(),&path,&reviewed.review_token,true,&f.archive_cache()).is_err());
        assert!(!f.snapshots().join("current.json").exists());
        fs::write(&portable,&pristine).unwrap();
        let review=with_publish_source(&path,&f.snapshots(),|r,_,_,_|Ok(r)).unwrap();
        assert_eq!(review.review_token,reviewed.review_token);
        let raw=f.root.join("corrupt-content.coco2pack.zip");
        let mut damaged=pristine.clone();
        if let Some(position)=damaged.windows(b"schemaVersion".len()).position(|window|window==b"schemaVersion") {
            damaged[position]^=0x40;
        } else {panic!("Synthetic portable fixture missing expected JSON bytes");}
        fs::write(&raw,damaged).unwrap();
        assert!(portable::unpack(&raw.display().to_string(),&f.snapshots()).is_err(),"ZIP CRC or SHA mismatch must refuse");
        assert!(import_at(&f.snapshots(),&path,&review.review_token,true,&f.archive_cache()).is_ok());
        assert_eq!(active(&f.snapshots()).unwrap().entries[0].source,"local");
    }

    #[test]
    fn portable_encrypted_symlink_and_private_stage_fail_closed(){
        let f=TestFixture::new();
        let good=f.portable("1.0.0");
        let raw=fs::read(&good).unwrap();
        let mut encrypted=raw.clone();
        let mut local_flags=0;let mut central_flags=0;
        for index in 0..encrypted.len().saturating_sub(12) {
            if &encrypted[index..index+4]==b"PK\x03\x04" {
                encrypted[index+6]|=1;local_flags+=1;
            }
            if &encrypted[index..index+4]==b"PK\x01\x02" {
                encrypted[index+8]|=1;central_flags+=1;
            }
        }
        // Nested game.zip can itself contain the same marker bytes. Even
        // when that happens, at least all eight outer entries are flagged.
        assert!(local_flags>=8);
        assert!(central_flags>=8);
        let encrypted_path=f.root.join("encrypted.coco2pack.zip");
        fs::write(&encrypted_path,encrypted).unwrap();
        assert!(portable::unpack(&encrypted_path.display().to_string(),&f.snapshots()).is_err());
        #[cfg(windows)]{
            use std::os::windows::fs::symlink_file;
            let alias=f.root.join("linked.coco2pack.zip");
            if symlink_file(&good,&alias).is_ok(){
                assert!(portable::unpack(&alias.display().to_string(),&f.snapshots()).is_err());
                fs::remove_file(alias).unwrap();
            }
        }
        let package=f.root.join("package-test-game-1x0x0");
        let symlink=f.root.join("symlink-member.coco2pack.zip");
        let mut writer=zip::ZipWriter::new(File::create(&symlink).unwrap());
        let opts=SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        let manifest:Value=serde_json::from_slice(&fs::read(package.join("publish-manifest.json")).unwrap()).unwrap();
        let cover=manifest["coverFile"].as_str().unwrap();
        for name in ["publish-manifest.json","catalog.template.json","catalog-candidate.json",
            "source-lock.json","coco2-client-entry.json","coco2-install-manifest.json",
            cover,"game.zip"]{
            if name==cover {
                writer.add_symlink(name,"../../outside",opts).unwrap();
            } else {
                writer.start_file(name,opts).unwrap();
                writer.write_all(&fs::read(package.join(name)).unwrap()).unwrap();
            }
        }
        writer.finish().unwrap();
        assert!(portable::unpack(&symlink.display().to_string(),&f.snapshots()).is_err());
        let valid=with_publish_source(&good.display().to_string(),&f.snapshots(),|r,_,_,_|Ok(r)).unwrap();
        let stage=f.snapshots().join("portable-staging");
        assert_eq!(fs::read_dir(stage).unwrap().count(),0,
            "No extraction stage should remain after a completed review");
        assert!(!f.snapshots().join("current.json").exists());
        assert_eq!(valid.id,"test-game");
        assert_eq!(fs::read(&good).unwrap(),raw,"Never modify the source portable package");
    }
}
