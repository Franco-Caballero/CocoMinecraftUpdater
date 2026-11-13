//! Standalone installation without PowerShell, shell commands or game execution.
//! The private embedded manifest is the sole source for download and file paths.
//! Installed Coco2 instances may be repaired with an on-volume, durable journal;
//! user-owned worlds, configs, mods and unrelated files remain outside its scope.
#[path = "repair_transaction.rs"]
mod repair_transaction;
#[cfg(all(test,windows))]
#[path = "native_lifecycle_e2e.rs"]
mod native_lifecycle_e2e;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

const MAX_ZIP_ENTRIES: usize = 150_000;
const MAX_UNCOMPRESSED_BYTES: u64 = 128 * 1024 * 1024 * 1024;
const MAX_SINGLE_ENTRY_BYTES: u64 = 64 * 1024 * 1024 * 1024;
const PROGRESS_EVENT: &str = "coco2://standalone-install-progress";
// A stalled HTTP response must never pin the install worker for six hours.
// Each HTTP request covers only one bounded Range, with its own hard timeout.
const HTTP_CHUNK_BYTES: u64 = 32 * 1024 * 1024;
const HTTP_CHUNK_TIMEOUT: Duration = Duration::from_secs(120);
const HTTP_ATTEMPTS: usize = 4;
// A server can repeatedly close an exact HTTP Range mid-body while making
// useful forward progress. Four consecutive NO-PROGRESS failures still abort;
// cap advancing short responses too, so one-byte trickles cannot loop forever.
const HTTP_ADVANCING_TRUNCATIONS: usize = 16;

/// Production accepts HTTPS only. Unit tests may use an ephemeral loopback
/// HTTP server to test real Range/ETag/timeout behavior without internet.
fn synthetic_http_fixture(url:&reqwest::Url)->bool{
    #[cfg(test)]{
        return url.scheme()=="http"&&url.host_str()==Some("127.0.0.1")
            &&url.port().is_some()&&url.username().is_empty()&&url.password().is_none()
            &&url.fragment().is_none();
    }
    #[cfg(not(test))]{let _=url;false}
}

/// Validate the NEXT hop before reqwest can transmit a request. Checking only
/// response.url() afterwards was too late: Policy::limited followed HTTPS ->
/// plaintext HTTP and contacted the downgraded host before rejecting the ZIP.
/// Keep HTTPS CDN redirects supported. Unit tests may follow only localhost
/// synthetic HTTP -> localhost synthetic HTTP, never an external test URL.
fn safe_archive_redirect()->reqwest::redirect::Policy{
    reqwest::redirect::Policy::custom(|attempt|{
        if attempt.previous().len()>=8 {return attempt.stop();}
        let secure=attempt.url().scheme()=="https" &&
            attempt.previous().iter().all(|url|url.scheme()=="https");
        let synthetic=synthetic_http_fixture(attempt.url()) &&
            attempt.previous().iter().all(synthetic_http_fixture);
        if secure||synthetic {attempt.follow()} else {attempt.stop()}
    })
}
const MIN_FREE_HEADROOM_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    id: String,
    instance_id: String,
    workflow: String,
    version: String,
    archives: Vec<ArchiveSpec>,
    required_files: Vec<FileSpec>,
    #[serde(default)]
    executable: String,
    #[serde(default)]
    files: Vec<serde_json::Value>,
    #[serde(default)]
    extras: Vec<serde_json::Value>,
    #[serde(default)]
    extra_files: Vec<ExtraSpec>,
    #[serde(default)]
    has_extras: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ArchiveSpec {
    url: String,
    sha256: String,
    size: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct FileSpec {
    path: String,
    sha256: String,
    size: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ExtraSpec {
    path: String,
    source_url: String,
    size: u64,
    sha256: String,
    role: String,
    policy: String,
}

fn supported_extra(extra: &ExtraSpec) -> bool {
    extra.role == "all" && extra.policy == "replace"
        && extra.path.to_ascii_lowercase().ends_with(".zip")
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallPlan {
    id: String,
    status: &'static str,
    message: String,
    instance_path: String,
    archive_count: usize,
    total_download_bytes: u64,
    required_file_count: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallOutcome {
    id: String,
    status: &'static str,
    instance_path: String,
    message: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallProgress {
    id: String,
    phase: &'static str,
    file: String,
    downloaded_bytes: u64,
    total_bytes: u64,
    percent: u8,
}

/// An observed state, not authorization to replace anything. Hashing only the
/// pinned essentials is NOT proof that an unknown legacy installation is ours.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepairPlan {
    id: String,
    status: &'static str,
    message: String,
    instance_path: String,
    required_file_count: usize,
    verified_files: usize,
    missing_files: usize,
    corrupt_files: usize,
    verified_extras: usize,
    missing_extras: usize,
    corrupt_extras: usize,
    receipt: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepairRecoveryStatus {
    id:String,
    pending:bool,
    cleanup_pending:bool,
    message:String,
}

/// Read-only startup notice; a pending operation never implies it is safe to
/// recover while an external game process may still be running.
#[derive(Clone,Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct PendingStandaloneOperation {
    id:String, instance_path:String, kind:&'static str, status:&'static str,
    from_version:Option<String>,to_version:Option<String>,message:String,
}

fn pending_operations_at(entries:&[crate::services::catalog::Experience],
    app_data:&Path,local_data:&Path)->Vec<PendingStandaloneOperation>{
    let mut found=Vec::new();
    let mut seen=HashSet::new();
    for entry in entries.iter().filter(|e|e.workflow=="coco-standalone"){
        let discovered=(||->Result<(PathBuf,Vec<(&'static str,String,String,String)>),String>{
            if !valid_id(&entry.id)||!valid_id(&entry.instance_id){return Err("ID de catálogo inválido".into());}
            let locations=crate::services::inventory::custom_locations(local_data)?;
            let target=if let Some(custom)=crate::services::inventory::custom_path(
                &locations,&entry.instance_id,&entry.id){PathBuf::from(custom)}
                else{crate::services::inventory::default_instance_root(app_data,&entry.instance_id,&entry.workflow)};
            if !target.is_absolute()||target.to_string_lossy().starts_with("\\\\")
                ||target.components().any(|p|matches!(p,Component::ParentDir|Component::CurDir)){
                return Err("Ubicación registrada no es local segura".into());
            }
            assert_no_links(&target)?;
            if !target.is_dir(){return Ok((target,Vec::new()));}
            let canonical=fs::canonicalize(&target).map_err(|e|e.to_string())?;
            if !seen.insert(canonical){return Err("Instancias de catálogo solapadas o duplicadas".into());}
            Ok((target.clone(),repair_transaction::inspect_pending(&target,&entry.id,&entry.instance_id)?))
        })();
        match discovered{
            Ok((target,journals))=>for (kind,phase,from,to) in journals{
                found.push(PendingStandaloneOperation{id:entry.id.clone(),
                    instance_path:target.display().to_string(),kind,
                    status:if kind=="cleanup"{"cleanup-pending"}else{"recovery-required"},
                    from_version:if from.is_empty(){None}else{Some(from)},
                    to_version:if to.is_empty(){None}else{Some(to)},
                    message:format!("Journal {kind} ({phase}) detectado; comprobar procesos antes de recuperar manualmente"),
                });
            },
            Err(e)=>found.push(PendingStandaloneOperation{id:entry.id.clone(),
                instance_path:"".into(),kind:"unknown",status:"blocked-unsafe",
                from_version:None,to_version:None,message:e}),
        }
    }
    found
}

/// Scan ONLY catalog-registered Coco standalone instance roots. No automatic
/// rollback, no download, no user-folder recursion and no active-game claim.
#[tauri::command]
pub async fn recover_pending_standalone_operations()->Result<Vec<PendingStandaloneOperation>,String>{
    let entries=crate::services::catalog::read_catalog()?;
    let (app_data,local_data)=roots()?;
    tauri::async_runtime::spawn_blocking(move||pending_operations_at(&entries,&app_data,&local_data))
        .await.map_err(|e|format!("Inspección de journals interrumpida: {e}"))
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all="camelCase")]
pub struct UpgradePlan {
    id:String, status:&'static str, from_version:Option<String>, to_version:String,
    needed_bytes:u64, instance_path:String, message:String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all="camelCase")]
pub struct UpgradeOutcome {
    id:String, status:&'static str, from_version:String, to_version:String,
    needed_bytes:u64, instance_path:String, message:String,
}

#[derive(Default)]
pub struct InstallState {
    active: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

struct ActiveGuard {
    id: String,
    active: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

impl Drop for ActiveGuard {
    fn drop(&mut self) {
        if let Ok(mut active) = self.active.lock() {
            active.remove(&self.id);
        }
    }
}

struct StageGuard(PathBuf);
impl Drop for StageGuard {
    fn drop(&mut self) {
        if self.0.exists() {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}

/// The legacy .partial and earlier checkpoints can belong to another process.
/// Save only NEW progress using a create-new hard link to the private work
/// file. Checkpoints are immutable: even concurrent/restarted attempts never
/// mutate or remove a path that another writer may own.
struct PartialResumeGuard {
    work:PathBuf, canonical:PathBuf, checkpoint:PathBuf,
    previous_len:u64, complete:bool,
}
impl Drop for PartialResumeGuard {
    fn drop(&mut self){
        if self.complete { return; }
        if let Ok(meta)=fs::symlink_metadata(&self.work){
            if meta.is_file() && meta.len()>self.previous_len {
                // sync_all is best-effort during unwinding/cancellation; never
                // risk removing a pre-existing partial on checkpoint failure.
                if let Ok(file)=OpenOptions::new().read(true).write(true).open(&self.work) {
                    let _=file.sync_all();
                }
                if fs::hard_link(&self.work,&self.canonical).is_err(){
                    let _=fs::hard_link(&self.work,&self.checkpoint);
                }
            }
        }
    }
}

/// Private staging is normally removed by StageGuard. A hard process crash
/// bypasses Drop, however, leaving the downloaded bytes stranded. New stages
/// include an identity marker, written before any payload, so only a matching
/// orphan can be considered for an eventual full-SHA verification.
fn mark_download_stage(stage:&Path,hash:&str,size:u64)->Result<(),String>{
    let marker=stage.join("archive.identity.v13");
    assert_no_links(&marker)?;
    let mut file=OpenOptions::new().write(true).create_new(true).open(marker)
        .map_err(|e|format!("No se pudo identificar staging privado: {e}"))?;
    file.write_all(format!("{hash}:{size}").as_bytes())
        .and_then(|_|file.sync_all())
        .map_err(|e|format!("No se pudo persistir identidad de descarga: {e}"))
}

/// Reuse the most advanced immutable checkpoint or a marked crash orphan
/// without trusting its bytes: the final full SHA-256 remains mandatory.
fn resumable_checkpoint(cache:&Path, hash:&str, expected:u64, token:&AtomicBool)
    -> Result<Option<(PathBuf,u64)>,String>
{
    let canonical=cache.join(format!("{hash}.zip.partial"));
    let mut best=None;
    let mut best_bytes=0u64;
    let prefix=format!("{hash}.zip.partial.v11.");
    let stage_identity=format!("{hash}:{expected}");
    let mut paths=vec![canonical];
    for entry in fs::read_dir(cache).map_err(|e|format!("No se puede leer caché de descargas: {e}"))? {
        cancelled(token)?;
        let entry=entry.map_err(|e|e.to_string())?;
        let name=entry.file_name();
        let name=name.to_string_lossy();
        if name.starts_with(&prefix) {
            paths.push(entry.path());
        }else if name.starts_with(".coco2-stage-"){
            let stage=entry.path();
            assert_no_links(&stage)?;
            if !stage.is_dir(){continue;}
            let marker=stage.join("archive.identity.v13");
            if is_link(&marker)?{return Err("Identidad de staging enlazada o insegura".into());}
            if fs::metadata(&marker).is_ok_and(|metadata|metadata.is_file()&&metadata.len()<=90)
                && fs::read_to_string(&marker).is_ok_and(|content|content==stage_identity){
                let work=stage.join("payload.partial");
                if is_link(&work)?{return Err("Payload de staging enlazado o inseguro".into());}
                if work.is_file(){paths.push(work);}
            }
        }
        if paths.len()>4096 {return Err("Demasiados checkpoints de descarga; revisar caché".into());}
    }
    for path in paths {
        cancelled(token)?;
        if is_link(&path)?{return Err("Checkpoint de descarga contiene enlace no permitido".into());}
        let meta=match fs::metadata(&path){
            Ok(meta)=>meta,
            Err(e) if e.kind()==std::io::ErrorKind::NotFound=>continue,
            Err(e)=>return Err(format!("No se pudo leer checkpoint de descarga: {e}")),
        };
        if !meta.is_file(){return Err("Checkpoint de descarga no es un archivo".into());}
        if meta.len()>expected {
            return Err("Descarga parcial mayor al tamaño esperado; preservada sin cambios".into());
        }
        if meta.len()==expected {
            // A complete checkpoint may have been left immediately before
            // publication. Prefer only one whose FULL hash matches; a corrupt
            // completed prefix must not hide a shorter usable checkpoint.
            if matches_digest(&path,expected,hash,token)? {
                return Ok(Some((path,expected)));
            }
            continue;
        }
        if meta.len()>best_bytes {
            best_bytes=meta.len();
            best=Some((path,meta.len()));
        }
    }
    Ok(best)
}

fn retryable_http_status(status:u16)->bool{
    matches!(status,408|429|500|502|503|504)
}

// Retry-After may be delta-seconds OR an HTTP-date (RFC 2822). The previous
// parser silently treated valid dates as absent and hammered rate-limited
// mirrors with a 200 ms fallback. Bound both forms to two seconds so a
// malicious origin cannot hold the install worker indefinitely.
fn retry_after_delay_ms(attempt:usize,retry_after:Option<&str>,now:time::OffsetDateTime)->u64{
    let fallback=200u64.saturating_mul(1u64 << (attempt.saturating_sub(1).min(3)));
    retry_after.and_then(|value|{
        let value=value.trim();
        if let Ok(seconds)=value.parse::<u64>() {
            return Some(seconds.saturating_mul(1000));
        }
        let date=time::OffsetDateTime::parse(value,&time::format_description::well_known::Rfc2822)
            .ok()?;
        Some((date-now).whole_milliseconds().clamp(0,2000) as u64)
    }).unwrap_or(fallback).min(2000)
}

fn retry_http_delay(attempt:usize,retry_after:Option<&str>,token:&AtomicBool)->Result<(),String>{
    let millis=retry_after_delay_ms(attempt,retry_after,time::OffsetDateTime::now_utc());
    let mut elapsed=0u64;
    while elapsed<millis {
        cancelled(token)?;
        let slice=(millis-elapsed).min(100);
        std::thread::sleep(Duration::from_millis(slice));
        elapsed+=slice;
    }
    cancelled(token)
}

/// Both winners of a concurrent SHA cache race can reuse the same verified
/// ZIP; a differently sized/hashed file remains an explicit conflict. This
/// never replaces, truncates or removes the competing writer's entry.
fn publish_verified_archive(work:&Path,archive:&Path,spec:&ArchiveSpec,token:&AtomicBool)
    -> Result<(),String>
{
    match fs::hard_link(work,archive){
        Ok(())=>Ok(()),
        Err(error) if error.kind()==std::io::ErrorKind::AlreadyExists=>{
            if matches_digest(archive,spec.size,&spec.sha256,token)? {Ok(())}
            else {Err("Conflicto: otro proceso publicó un ZIP con SHA-256/tamaño diferente".into())}
        },
        Err(error)=>Err(format!("ZIP inaccesible (permiso, bloqueo o disco): {error}")),
    }
}

fn valid_id(id: &str) -> bool {
    (2..=48).contains(&id.len())
        && id.as_bytes()[0].is_ascii_lowercase()
        && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn valid_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

fn normal_path(value: &str) -> Result<String, String> {
    if value.is_empty() || value.starts_with('/') || value.starts_with('\\') || value.contains(':') {
        return Err(format!("Ruta de archivo insegura: {value}"));
    }
    let normalized = value.replace('\\', "/");
    if normalized.ends_with('/') {
        return Err(format!("Ruta de archivo insegura: {value}"));
    }
    let mut parts = Vec::new();
    for part in normalized.split('/') {
        if part.is_empty() || part == "." || part == ".." || part.ends_with('.') || part.ends_with(' ')
            || part.chars().any(|c| c.is_control() || "<>\"|?*".contains(c))
        {
            return Err(format!("Componente de ruta inseguro: {value}"));
        }
        let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
            || ((stem.starts_with("COM") || stem.starts_with("LPT"))
                && stem.len() == 4
                && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        {
            return Err(format!("Nombre reservado de Windows: {value}"));
        }
        parts.push(part);
    }
    // No package may spoof the launcher's private receipt metadata.
    if parts[0].eq_ignore_ascii_case(".coco") {
        return Err("El paquete intenta escribir metadatos reservados del instalador".into());
    }
    // All user-owned game data remain outside the installer's write contract.
    if parts.iter().any(|p| matches!(p.to_ascii_lowercase().as_str(),
        "saves" | "playerdata" | "advancements" | "stats" | "distanthorizons"))
    {
        return Err(format!("El paquete contiene datos persistentes: {value}"));
    }
    Ok(parts.join("/"))
}

// Rust Unicode lowercasing is NOT Windows ordinal file-name equivalence.
// For example, it folds the Kelvin sign (K) into ASCII k, yet Win32 keeps
// K.bin and K.bin as two distinct files. Conversely ASCII-only matching
// misses non-ASCII case variants such as É/é in split-archive basenames.
// Use the same ordinal comparison implemented by Windows, only among likely
// case-folded candidates; this avoids quadratic comparisons for large ZIPs.
fn windows_path_case_equal(left:&str,right:&str)->bool{
    // Common ZIP paths and repeated parent directories must not allocate
    // UTF-16 buffers or call Win32 for every unchanged ASCII component.
    if left==right{return true;}
    if left.is_ascii()&&right.is_ascii(){return left.eq_ignore_ascii_case(right);}
    #[cfg(windows)]
    {
        #[link(name="kernel32")]
        extern "system" {
            fn CompareStringOrdinal(a:*const u16,a_count:i32,b:*const u16,b_count:i32,ignore_case:i32)->i32;
        }
        let a:Vec<u16>=left.encode_utf16().collect();
        let b:Vec<u16>=right.encode_utf16().collect();
        let comparison=unsafe{CompareStringOrdinal(a.as_ptr(),a.len() as i32,
            b.as_ptr(),b.len() as i32,1)};
        return comparison==2 || (comparison==0 && left.to_lowercase()==right.to_lowercase());
    }
    #[cfg(not(windows))]
    {left.to_lowercase()==right.to_lowercase()}
}

fn validate_manifest(m: &Manifest) -> Result<(), String> {
    if !valid_id(&m.id) || !valid_id(&m.instance_id) || m.workflow != "coco-standalone"
        || m.version.trim().is_empty() || m.archives.is_empty() || m.required_files.is_empty()
    {
        return Err(format!("Contrato standalone incompleto: {}", m.id));
    }
    let mut hashes = HashMap::<String, u64>::new();
    for archive in &m.archives {
        if archive.size == 0 || !valid_hash(&archive.sha256) {
            return Err(format!("Parte ZIP sin tamaño/hash válido: {}", m.id));
        }
        let url = reqwest::Url::parse(&archive.url).map_err(|_| "URL de ZIP inválida")?;
        if url.scheme() != "https" && url.scheme() != "file" {
            return Err("Los paquetes solo admiten HTTPS o archivo local fijado".into());
        }
        if url.scheme() == "https" && url.host_str().is_none() {
            return Err("Host HTTPS inválido".into());
        }
        if url.scheme() == "file" && url.to_file_path().is_err() {
            return Err("Ruta local de paquete inválida".into());
        }
        if let Some(old) = hashes.insert(archive.sha256.to_ascii_lowercase(), archive.size) {
            if old != archive.size { return Err("Un mismo SHA declara tamaños distintos".into()); }
        }
    }
    let mut paths = HashSet::new();
    for file in &m.required_files {
        let path = normal_path(&file.path)?;
        if !paths.insert(path.to_lowercase()) || !valid_hash(&file.sha256) || file.size == 0 {
            return Err(format!("Archivo requerido duplicado o inválido: {}", file.path));
        }
    }
    if !m.executable.is_empty() {
        let executable = normal_path(&m.executable)?;
        if !paths.contains(&executable.to_lowercase()) {
            return Err("El ejecutable debe figurar en requiredFiles".into());
        }
    }
    let mut extra_names = HashSet::new();
    for extra in &m.extra_files {
        let name = normal_path(&extra.path)?;
        if !extra_names.insert(name.to_lowercase()) || !valid_hash(&extra.sha256) || extra.size == 0 {
            return Err(format!("Extra inválido o repetido: {}", extra.path));
        }
        let url = reqwest::Url::parse(&extra.source_url).map_err(|_| "URL de extra inválida")?;
        if !matches!(url.scheme(), "https" | "file") {
            return Err(format!("El extra requiere HTTPS: {}", extra.path));
        }
        if url.scheme() == "https" && url.host_str().is_none() {
            return Err(format!("URL del extra sin host: {}", extra.path));
        }
    }
    Ok(())
}

fn read_manifest(id: &str) -> Result<Manifest, String> {
    if !valid_id(id) { return Err("ID de instalador inválido".into()); }
    if let Some(raw) = crate::services::catalog::read_install_manifest(id)? {
        let m: Manifest = serde_json::from_str(&raw)
            .map_err(|e|format!("Manifiesto dinámico no válido: {e}"))?;
        validate_manifest(&m)?;
        if m.id != id { return Err("Manifiesto dinámico no corresponde al ID solicitado".into()); }
        return Ok(m);
    }
    read_embedded_manifest(id)
}

fn read_embedded_manifest(id: &str) -> Result<Manifest, String> {
    let raw = include_str!("../../resources/install-manifests.json");
    let entries: Vec<Manifest> = serde_json::from_str(raw)
        .map_err(|e| format!("Manifiesto de instalación privado inválido: {e}"))?;
    let mut ids = HashSet::new();
    for item in &entries {
        validate_manifest(item)?;
        if !ids.insert(item.id.to_ascii_lowercase()) {
            return Err("El manifiesto contiene IDs duplicados".into());
        }
    }
    entries.into_iter().find(|m| m.id == id)
        .ok_or_else(|| "Esta experiencia no tiene instalador nativo".to_string())
}

fn trusted_manifest_version(id:&str,version:&str)->Result<Option<Manifest>,String>{
    #[cfg(test)]
    if let Some(snapshot) = TEST_AUTHORIZED_BASELINES.with(|history|
        history.borrow().get(&(id.to_owned(),version.to_owned())).cloned()){
        return Ok(Some(snapshot));
    }
    if let Some(raw)=crate::services::catalog::read_install_manifest_version(id,version)? {
        let m:Manifest=serde_json::from_str(&raw).map_err(|e|format!("Historial de manifiesto inválido: {e}"))?;
        validate_manifest(&m)?;
        if m.id!=id||m.version!=version {return Err("El manifiesto histórico no coincide con ID/version".into());}
        return Ok(Some(m));
    }
    match read_embedded_manifest(id) {
        Ok(m) if m.version==version=>Ok(Some(m)),
        _=>Ok(None),
    }
}

// Test-only thread-local trust fixture: never mutates catalog provider state,
// user environment or shared profiles. Outside unit tests, only authenticated
// catalog history and the embedded baseline can authorize a version A.
#[cfg(test)]
std::thread_local!{
    static TEST_AUTHORIZED_BASELINES:std::cell::RefCell<HashMap<(String,String),Manifest>>
        = std::cell::RefCell::new(HashMap::new());
}

#[cfg(test)]
fn test_with_authorized_baseline<T>(baseline:&Manifest,action:impl FnOnce()->T)->T{
    let key=(baseline.id.clone(),baseline.version.clone());
    TEST_AUTHORIZED_BASELINES.with(|store|{store.borrow_mut().insert(key.clone(),baseline.clone());});
    struct Reset((String,String));
    impl Drop for Reset{fn drop(&mut self){
        TEST_AUTHORIZED_BASELINES.with(|store|{store.borrow_mut().remove(&self.0);});
    }}
    let _reset=Reset(key);
    action()
}

fn read_owned_receipt(target:&Path)->Result<serde_json::Value,String>{
    let path=target.join(".coco").join("standalone-install-v1.json");
    assert_no_links(&path)?;
    let metadata=fs::metadata(&path).map_err(|e|format!("Recibo Coco2 ausente: {e}"))?;
    if !metadata.is_file()||metadata.len()>1024*1024{return Err("Recibo Coco2 inseguro".into());}
    serde_json::from_slice(&fs::read(&path).map_err(|e|e.to_string())?)
        .map_err(|e|format!("Recibo Coco2 ilegible: {e}"))
}

fn authoritative_baseline(m_new:&Manifest,target:&Path)->Result<(Manifest,serde_json::Value),String>{
    assert_no_links(target)?;
    if !target.is_dir(){return Err("No existe una instancia instalada".into());}
    let receipt=read_owned_receipt(target)?;
    let from=receipt.get("version").and_then(|v|v.as_str()).ok_or("Recibo sin versión")?;
    let old=trusted_manifest_version(&m_new.id,from)?
        .ok_or("Versión antigua no consta en historial confiable; no se sobrescribirá")?;
    if old.instance_id!=m_new.instance_id || old.workflow!=m_new.workflow {
        return Err("La identidad del recibo no coincide con el manifiesto anterior autorizado".into());
    }
    validate_receipt_baseline(&old,&receipt)?;
    Ok((old,receipt))
}

/// A user may defer upgrading without losing the ability to launch the fully
/// verified old A. The launcher must never take executable paths solely from
/// the writable receipt; they come from the independently trusted A manifest.
pub(crate) fn trusted_installed_launch_entry(
    entry:&crate::services::catalog::Experience,target:&Path)
    ->Result<Option<crate::services::catalog::Experience>,String>{
    let receipt_path=target.join(".coco").join("standalone-install-v1.json");
    assert_no_links(&receipt_path)?;
    if !receipt_path.exists(){return Ok(None);}
    let latest=read_manifest(&entry.id)?;
    if entry.instance_id!=latest.instance_id||entry.workflow!=latest.workflow{
        return Err("Catálogo público e instalador firmado no corresponden a la misma instancia".into());
    }
    let receipt=read_owned_receipt(target)?;
    if receipt.get("version").and_then(|v|v.as_str())==Some(latest.version.as_str()){
        return Ok(None);
    }
    let (old,_)=authoritative_baseline(&latest,target)?;
    trusted_launch_from_baseline(entry,&latest,&old,target).map(Some)
}

fn trusted_launch_from_baseline(
    entry:&crate::services::catalog::Experience,current:&Manifest,old:&Manifest,target:&Path)
    ->Result<crate::services::catalog::Experience,String>{
    if upgrade_direction(&old.version,&current.version)?!="upgrade-ready"{
        return Err("Fallback permitido solo para versión antigua A, nunca downgrade".into());
    }
    if entry.id!=old.id||entry.instance_id!=old.instance_id||entry.workflow!="coco-standalone"
        ||entry.hosting_mode!="p2p"||old.executable.is_empty(){
        return Err("Versión antigua no posee ejecutable e identidad confiables".into());
    }
    if !entry.launch_arguments.is_empty(){
        return Err("No se dispone de argumentos de arranque históricos autorizados para A".into());
    }
    if repair_transaction::upgrade_recovery_versions(target)?.is_some(){
        return Err("Hay actualización pendiente de recuperación; lanzamiento bloqueado".into());
    }
    let mut fallback=entry.clone();
    fallback.executable=normal_path(&old.executable)?;
    fallback.required_files=old.required_files.iter().map(|file|crate::services::catalog::RequiredFile{
        path:file.path.clone(),sha256:file.sha256.clone(),size:file.size,
    }).collect();
    Ok(fallback)
}

fn validate_receipt_baseline(old:&Manifest,receipt:&serde_json::Value)->Result<(),String>{
    if receipt.get("schemaVersion").and_then(|v|v.as_u64())!=Some(1)
        ||receipt.get("type").and_then(|v|v.as_str())!=Some("coco2-standalone-install")
        ||receipt.get("complete").and_then(|v|v.as_bool())!=Some(true)
        ||receipt.get("id").and_then(|v|v.as_str())!=Some(old.id.as_str())
        ||receipt.get("instanceId").and_then(|v|v.as_str())!=Some(old.instance_id.as_str())
        ||receipt.get("workflow").and_then(|v|v.as_str())!=Some(old.workflow.as_str())
        ||receipt.get("version").and_then(|v|v.as_str())!=Some(old.version.as_str()){
        return Err("Recibo no tiene identidad o versión Coco2 válidas".into());
    }
    let expected_archives:Vec<String>=old.archives.iter().map(|archive|archive.sha256.to_ascii_lowercase()).collect();
    if receipt.get("archiveShas")!=Some(&serde_json::json!(expected_archives)){
        return Err("SHA de ZIP del recibo no corresponden a la versión histórica".into());
    }
    let pinned_old:Vec<serde_json::Value>=old.required_files.iter()
        .map(|file|serde_json::to_value(file).unwrap_or_default()).collect();
    if receipt.get("requiredFiles").and_then(|v|v.as_array())!=Some(&pinned_old){
        return Err("Los archivos declarados por el recibo no coinciden con el baseline histórico autorizado".into());
    }
    // A local receipt is NOT a publisher signature. The signer-approved old
    // manifest must independently match archive hashes, paths, version and ID.
    if !old.extra_files.is_empty(){
        let declared=serde_json::to_value(&old.extra_files).map_err(|e|e.to_string())?;
        if receipt.get("extraFileArchives")!=Some(&declared){
            return Err("Extras originales del recibo no corresponden al manifiesto anterior".into());
        }
    }
    Ok(())
}

fn version_parts(version:&str)->Option<[u64;3]>{
    let mut numbers=[0;3];let mut iter=version.split('.');
    for x in &mut numbers {let value=iter.next()?;
        if value.is_empty()||value.len()>10||!value.bytes().all(|b|b.is_ascii_digit())
            ||(value.len()>1&&value.starts_with('0')){return None;}
        *x=value.parse().ok()?;
    }
    if iter.next().is_some(){return None;}
    Some(numbers)
}

fn upgrade_direction(from:&str,to:&str)->Result<&'static str,String>{
    let a=version_parts(from).ok_or("Versión instalada no es SemVer estable X.Y.Z")?;
    let b=version_parts(to).ok_or("Nueva versión no es SemVer estable X.Y.Z")?;
    Ok(if b>a{"upgrade-ready"}else if b==a{"already-current"}else{"downgrade-blocked"})
}

fn upgrade_plan(m:&Manifest,target:&Path,cache:&Path)->UpgradePlan{
    let mut plan=UpgradePlan{id:m.id.clone(),status:"untrusted-existing",
        from_version:None,to_version:m.version.clone(),needed_bytes:0,
        instance_path:target.display().to_string(),message:String::new()};
    if !target.exists(){plan.status="not-installed";plan.message="Primero instala el juego".into();return plan;}
    match repair_transaction::upgrade_recovery_versions(target){
        Ok(Some((from,to)))=>{
            plan.status="recovery-required";
            plan.from_version=Some(from);
            plan.to_version=to;
            plan.message="Actualización interrumpida; recuperar journal antes de cualquier descarga".into();
            return plan;
        }
        Err(e)=>{
            plan.status="recovery-blocked";
            plan.message=format!("Journal de actualización inseguro; intervención necesaria: {e}");
            return plan;
        }
        Ok(None)=>{},
    }
    if has_unsupported_extras(m){plan.status="unsupported-extras";
        plan.message="La versión publicada tiene extras no admitidos".into();return plan;}
    match authoritative_baseline(m,target){
        Ok((old,_))=>{
            plan.from_version=Some(old.version.clone());
            match upgrade_direction(&old.version,&m.version){
                Ok(status)=>{
                    plan.status=status;
                    plan.message=match status{
                        "upgrade-ready"=>"Versión A autorizada; actualización B disponible",
                        "already-current"=>"Ya corresponde a la versión publicada; usar Reparar si está dañada",
                        _=>"Actualización rechazada: no se permite degradar la versión",
                    }.into();
                    if status=="upgrade-ready"{
                        for archive in m.archives.iter().map(|a|(a.sha256.as_str(),a.size))
                            .chain(m.extra_files.iter().map(|a|(a.sha256.as_str(),a.size))){
                            let filename=cache.join(format!("{}.zip",archive.0.to_ascii_lowercase()));
                            // This is a fast size-based estimate only. The
                            // actual SHA-256 is always checked before reuse.
                            if fs::metadata(&filename).map(|meta|!meta.is_file()||meta.len()!=archive.1)
                                .unwrap_or(true){
                                plan.needed_bytes=plan.needed_bytes.saturating_add(archive.1);
                            }
                        }
                    }
                }
                Err(e)=>plan.message=e,
            }
        }
        Err(e)=>plan.message=e,
    }
    plan
}

#[tauri::command]
pub async fn plan_standalone_upgrade(id:String)->Result<UpgradePlan,String>{
    let m=read_manifest(&id)?;
    let (app_data,local_data)=roots()?;
    let target=instance_path(&m,&app_data,&local_data)?;
    let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    tauri::async_runtime::spawn_blocking(move||upgrade_plan(&m,&target,&cache))
        .await.map_err(|e|format!("No se pudo revisar actualización: {e}"))
}

fn has_unsupported_extras(m: &Manifest) -> bool {
    m.has_extras || !m.files.is_empty() || !m.extras.is_empty()
        || m.extra_files.iter().any(|extra| !supported_extra(extra))
}

fn roots() -> Result<(PathBuf, PathBuf), String> {
    Ok((
        PathBuf::from(std::env::var_os("APPDATA").ok_or("APPDATA no disponible")?),
        PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA no disponible")?),
    ))
}

fn instance_path(m: &Manifest, app_data: &Path, local_data: &Path) -> Result<PathBuf, String> {
    let locations = crate::services::inventory::custom_locations(local_data)?;
    let path = if let Some(custom) = crate::services::inventory::custom_path(&locations, &m.instance_id, &m.id) {
        PathBuf::from(custom)
    } else {
        crate::services::inventory::default_instance_root(app_data, &m.instance_id, &m.workflow)
    };
    if !path.is_absolute() || path.to_string_lossy().starts_with("\\\\")
        || path.parent().is_none() || path.parent() == Some(path.as_path())
    {
        return Err("Ubicación standalone local inválida".into());
    }
    if path.components().any(|part| matches!(part, Component::ParentDir | Component::CurDir)) {
        return Err("La ubicación contiene componentes no permitidos".into());
    }
    Ok(path)
}

fn plan(m: &Manifest, target: &Path) -> InstallPlan {
    let status = if target.exists() { "needs-repair" }
        else if has_unsupported_extras(m) { "unsupported-extras" }
        else { "ready" };
    let message = match status {
        // This cheap plan only checks for a folder. It does NOT assert actual
        // corruption; plan_standalone_repair performs the SHA-256 diagnosis.
        "needs-repair" => "Ya existe una instancia (integridad aún desconocida); usa la comprobación de reparación SHA-256 antes de decidir",
        "unsupported-extras" => "La experiencia declara archivos adicionales que aún no instala el motor nativo",
        _ => "Instalación nueva lista para preparar y verificar",
    }.to_string();
    InstallPlan {
        id: m.id.clone(), status, message,
        instance_path: target.display().to_string(),
        archive_count: m.archives.len() + m.extra_files.len(),
        total_download_bytes: m.archives.iter().fold(0u64, |total, part| total.saturating_add(part.size))
            .saturating_add(m.extra_files.iter().fold(0u64, |total, part| total.saturating_add(part.size))),
        required_file_count: m.required_files.len(),
    }
}

#[tauri::command]
pub async fn plan_standalone_install(id: String) -> Result<InstallPlan, String> {
    tauri::async_runtime::spawn_blocking(move || read_install_plan(&id))
        .await.map_err(|error| format!("Install plan interrupted: {error}"))?
}

fn read_install_plan(id: &str) -> Result<InstallPlan, String> {
    let m = read_manifest(id)?;
    let (app_data, local_data) = roots()?;
    let target = instance_path(&m, &app_data, &local_data)?;
    let mut initial=plan(&m,&target);
    if target.exists() {
        let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
        let upgrade=upgrade_plan(&m,&target,&cache);
        if upgrade.status=="upgrade-ready" {
            initial.status="upgrade-available";
            initial.message=format!("Actualización {} → {} disponible: {}",upgrade.from_version.unwrap_or_default(),
                upgrade.to_version,upgrade.message);
        } else if matches!(upgrade.status,"untrusted-existing"|"downgrade-blocked"|"recovery-required"|"recovery-blocked") {
            initial.status=upgrade.status;
            initial.message=upgrade.message;
        }
    }
    Ok(initial)
}

fn cancelled(token: &AtomicBool) -> Result<(), String> {
    if token.load(Ordering::Relaxed) { Err("cancelled".into()) } else { Ok(()) }
}

fn file_digest(path: &Path, token: &AtomicBool) -> Result<(u64, String), String> {
    let mut input = File::open(path).map_err(|e| format!("No se puede abrir {}: {e}", path.display()))?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    let mut bytes = 0u64;
    loop {
        cancelled(token)?;
        let count = input.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 { break; }
        hash.update(&buffer[..count]);
        bytes += count as u64;
    }
    Ok((bytes, format!("{:x}", hash.finalize())))
}

fn matches_digest(path: &Path, size: u64, hash: &str, token: &AtomicBool) -> Result<bool, String> {
    assert_no_links(path)?;
    if !path.is_file() { return Ok(false); }
    if fs::metadata(path).map_err(|e| e.to_string())?.len() != size { return Ok(false); }
    let (_, actual) = file_digest(path, token)?;
    Ok(actual.eq_ignore_ascii_case(hash))
}

// download_one() verifies a content-addressed ZIP, but the cache is shared.
// A different process could replace/mutate it before inspect_all_archives()
// or extract_archive() reopens it; requiredFile hashes do not cover every
// other game asset. Hold verified read-only handles THROUGH all extraction and
// commit preparation, denying Win32 writers and file replacement (DELETE).
// Pin parents too: otherwise renaming a cache directory into a junction
// could redirect those subsequent path-based ZIP opens.
struct PinnedArchiveSources {
    _archives: Vec<File>,
    #[cfg(windows)]
    _parents: Vec<File>,
}

fn pin_verified_archives(paths: &[PathBuf], specs: &[ArchiveSpec], token: &AtomicBool)
    -> Result<PinnedArchiveSources, String>
{
    if paths.len() != specs.len() || paths.is_empty() {
        return Err("La lista de ZIP cambió respecto al manifiesto autorizado".into());
    }
    #[cfg(windows)]
    let mut held_parents = Vec::new();
    #[cfg(windows)]
    {
        use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
        const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        const SHARE_READ_WRITE: u32 = 0x0000_0003; // no FILE_SHARE_DELETE
        let mut seen = HashSet::new();
        for path in paths {
            let parent = path.parent().ok_or("ZIP sin carpeta padre")?;
            let folders: Vec<_> = parent.ancestors()
                .filter(|dir| dir.parent().is_some()).collect();
            for folder in folders.into_iter().rev() {
                if !seen.insert(folder.to_path_buf()) { continue; }
                cancelled(token)?;
                assert_no_links(folder)?;
                let mut options = OpenOptions::new();
                options.read(true).share_mode(SHARE_READ_WRITE)
                    .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
                let file = options.open(folder)
                    .map_err(|e| format!("Carpeta de ZIP cambió o está ocupada: {e}"))?;
                let meta = file.metadata().map_err(|e| e.to_string())?;
                if !meta.is_dir() || meta.file_attributes() & 0x400 != 0 {
                    return Err("Carpeta de ZIP contiene reparse point o no es directorio".into());
                }
                held_parents.push(file);
            }
        }
    }
    let mut archives = Vec::with_capacity(paths.len());
    for (path, spec) in paths.iter().zip(specs) {
        cancelled(token)?;
        assert_no_links(path)?;
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(0x0000_0001); // FILE_SHARE_READ: deny writes + delete/rename
        }
        let mut file = options.open(path)
            .map_err(|e| format!("ZIP de caché bloqueado o cambiado por otro proceso: {e}"))?;
        let metadata = file.metadata().map_err(|e| e.to_string())?;
        if !metadata.is_file() || metadata.len() != spec.size {
            return Err("ZIP cambió de tipo o tamaño después de la descarga".into());
        }
        let mut sha = Sha256::new();
        let mut size = 0u64;
        let mut buf = [0u8; 1024 * 1024];
        loop {
            cancelled(token)?;
            let count = file.read(&mut buf).map_err(|e| e.to_string())?;
            if count == 0 { break; }
            size = size.checked_add(count as u64).ok_or("ZIP excede tamaño seguro")?;
            if size > spec.size { return Err("ZIP creció después de verificarlo".into()); }
            sha.update(&buf[..count]);
        }
        if size != spec.size || !format!("{:x}", sha.finalize()).eq_ignore_ascii_case(&spec.sha256) {
            return Err("ZIP de caché cambió tras SHA-256; instalación no confirmada".into());
        }
        archives.push(file);
    }
    Ok(PinnedArchiveSources {
        _archives: archives,
        #[cfg(windows)]
        _parents: held_parents,
    })
}

fn expected_zip_sources(m: &Manifest) -> Vec<ArchiveSpec> {
    m.archives.iter().cloned().chain(m.extra_files.iter().map(|extra| ArchiveSpec {
        url: extra.source_url.clone(), size: extra.size, sha256: extra.sha256.clone(),
    })).collect()
}

// The v1 receipt is informative and local, not a publisher signature. Check it
// strictly against our embedded manifest before calling an instance Coco2-owned.
fn inspect_receipt(m: &Manifest, target: &Path) -> &'static str {
    let path = target.join(".coco").join("standalone-install-v1.json");
    if assert_no_links(&path).is_err() { return "unsafe"; }
    let meta = match fs::metadata(&path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return "absent",
        Err(_) => return "unsafe",
    };
    if !meta.is_file() || meta.len() > 1024 * 1024 { return "unsafe"; }
    let Ok(bytes) = fs::read(&path) else { return "unsafe"; };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else { return "unrecognized"; };
    if value.get("schemaVersion").and_then(|v| v.as_u64()) != Some(1)
        || value.get("complete").and_then(|v| v.as_bool()) != Some(true)
        || value.get("type").and_then(|v| v.as_str()) != Some("coco2-standalone-install")
        || value.get("id").and_then(|v| v.as_str()) != Some(m.id.as_str())
        || value.get("instanceId").and_then(|v| v.as_str()) != Some(m.instance_id.as_str())
    {
        return "unrecognized";
    }
    if value.get("version").and_then(|v| v.as_str()) != Some(m.version.as_str()) {
        return "different-version";
    }
    let Some(sha) = value.get("archiveShas").and_then(|v| v.as_array()) else { return "unrecognized" };
    if sha.len() != m.archives.len()
        || !sha.iter().zip(&m.archives).all(|(old, expected)| {
            old.as_str().is_some_and(|old| old.eq_ignore_ascii_case(&expected.sha256))
        })
    {
        return "different-version";
    }
    if !m.extra_files.is_empty() {
        let Some(pinned) = value.get("extraFileArchives").and_then(|v| v.as_array()) else {
            return "unrecognized";
        };
        if pinned.len() != m.extra_files.len()
            || !pinned.iter().zip(&m.extra_files).all(|(old, expected)| {
                serde_json::from_value::<ExtraSpec>(old.clone()).ok().is_some_and(|v|
                    v.path == expected.path && v.size == expected.size
                    && v.sha256.eq_ignore_ascii_case(&expected.sha256)
                    && v.role == expected.role && v.policy == expected.policy)
            })
        {
            return "different-version";
        }
        if !value.get("extraFiles").and_then(|v| v.as_array())
            .is_some_and(|files| !files.is_empty())
        {
            // The exact contents of an extra ZIP are unknown until verified.
            // An empty/missing list must not masquerade as a complete install.
            return "unrecognized";
        }
    }
    "matching"
}

fn recorded_immutable_extras(target: &Path) -> Result<Vec<FileSpec>, String> {
    let path = target.join(".coco").join("standalone-install-v1.json");
    assert_no_links(&path)?;
    let data = fs::read(&path).map_err(|e| e.to_string())?;
    if data.len() > 1024 * 1024 { return Err("Recibo demasiado grande".into()); }
    let receipt: serde_json::Value = serde_json::from_slice(&data).map_err(|e| e.to_string())?;
    let list = receipt.get("extraFiles").and_then(|v| v.as_array()).ok_or("Recibo sin lista de extras")?;
    let mut seen = HashSet::new();
    list.iter().map(|v| {
        let file: FileSpec = serde_json::from_value(v.clone()).map_err(|e| e.to_string())?;
        let normalized = normal_path(&file.path)?;
        if !seen.insert(normalized.to_ascii_lowercase()) || !valid_hash(&file.sha256) {
            return Err("Recibo con archivo extra inválido o duplicado".into());
        }
        Ok(file)
    }).collect()
}

fn inspect_existing(m: &Manifest, target: &Path, token: &AtomicBool) -> Result<RepairPlan, String> {
    let response = |status, message: &str, verified_files, missing_files, corrupt_files,
                    verified_extras, missing_extras, corrupt_extras, receipt| RepairPlan {
        id: m.id.clone(), status, message: message.to_string(),
        instance_path: target.display().to_string(),
        required_file_count: m.required_files.len(),
        verified_files, missing_files, corrupt_files,
        verified_extras, missing_extras, corrupt_extras, receipt,
    };
    cancelled(token)?;
    assert_no_links(target)?;
    if !target.exists() {
        return Ok(response("not-installed", "No existe una instancia para reparar", 0, 0, 0, 0, 0, 0, "absent"));
    }
    if !fs::metadata(target).map_err(|e| e.to_string())?.is_dir() {
        return Ok(response("unsafe-existing", "La ruta de instancia existe, pero no es un directorio", 0, 0, 0, 0, 0, 0, "unsafe"));
    }
    let receipt = inspect_receipt(m, target);
    // Corrupt/unknown receipts could belong to another application or instance;
    // never treat this as authorization to repair in place.
    if receipt == "unsafe" || receipt == "unrecognized" {
        return Ok(response("unsafe-existing", "Los metadatos locales son desconocidos o inseguros", 0, 0, 0, 0, 0, 0, receipt));
    }
    let mut verified = 0;
    let mut missing = 0;
    let mut corrupt = 0;
    for file in &m.required_files {
        cancelled(token)?;
        let path = target.join(normal_path(&file.path)?);
        assert_no_links(&path)?;
        if !path.exists() { missing += 1; }
        else if matches_digest(&path, file.size, &file.sha256, token)? { verified += 1; }
        else { corrupt += 1; }
    }
    let mut verified_extras = 0;
    let mut missing_extras = 0;
    let mut corrupt_extras = 0;
    if !m.extra_files.is_empty() && receipt == "matching" {
        for file in recorded_immutable_extras(target)? {
            cancelled(token)?;
            let path = target.join(normal_path(&file.path)?);
            assert_no_links(&path)?;
            if !path.exists() { missing_extras += 1; }
            else if matches_digest(&path, file.size, &file.sha256, token)? { verified_extras += 1; }
            else { corrupt_extras += 1; }
        }
    }
    if verified == m.required_files.len() && missing_extras == 0 && corrupt_extras == 0
        && receipt != "different-version" && (m.extra_files.is_empty() || receipt == "matching")
    {
        let message = if receipt == "matching" {
            "Archivos esenciales y extras inmutables registrados SHA-256 verificados"
        } else {
            "Archivos esenciales verificados, pero la instalación no tiene un recibo Coco2 vigente"
        };
        return Ok(response("already-verified", message, verified, missing, corrupt,
            verified_extras, missing_extras, corrupt_extras, receipt));
    }
    Ok(response("needs-repair", "Archivos/version/extras no verificados; no se modificará ningún dato del juego",
        verified, missing, corrupt, verified_extras, missing_extras, corrupt_extras, receipt))
}

/// SHA-256 may cover many GB. Run this command off the UI thread. This is an
/// accurate diagnostic complement to the cheap existence-only install plan.
#[tauri::command]
pub async fn plan_standalone_repair(id: String) -> Result<RepairPlan, String> {
    let m = read_manifest(&id)?;
    let (app_data, local_data) = roots()?;
    let target = instance_path(&m, &app_data, &local_data)?;
    tauri::async_runtime::spawn_blocking(move || inspect_existing(&m, &target, &AtomicBool::new(false)))
        .await.map_err(|e| format!("No se pudo comprobar la instalación: {e}"))?
}

pub(crate) fn emit_progress(app: &AppHandle, id: &str, phase: &'static str, file: &str,
                 done: u64, total: u64) {
    let percent = if total == 0 { 0 } else { (done.saturating_mul(100) / total).min(100) as u8 };
    let _ = app.emit(PROGRESS_EVENT, InstallProgress {
        id: id.to_string(), phase, file: file.to_string(),
        downloaded_bytes: done, total_bytes: total, percent,
    });
}

fn download_one(spec: &ArchiveSpec, cache: &Path, client: &reqwest::blocking::Client,
                token: &AtomicBool, mut progress: impl FnMut(u64)) -> Result<PathBuf, String> {
    assert_no_links(cache)?;
    fs::create_dir_all(cache).map_err(|e| e.to_string())?;
    assert_no_links(cache)?;
    let hash = spec.sha256.to_ascii_lowercase();
    let archive = cache.join(format!("{hash}.zip"));
    if is_link(&archive)? { return Err("La caché ZIP es un enlace no permitido".into()); }
    if matches_digest(&archive, spec.size, &hash, token)? {
        progress(spec.size);
        return Ok(archive);
    }
    // The SHA-named cache is shared across sessions and may be owned by an
    // unrelated writer. A corrupt/existing entry is a conflict, not consent
    // to delete and replace it. Never touch even a zero-byte foreign file.
    if fs::symlink_metadata(&archive).is_ok() {
        return Err("Conflicto: ZIP existente en caché no coincide con SHA-256/tamaño; no se sobrescribió".into());
    }
    let partial = cache.join(format!("{hash}.zip.partial"));
    let resume = resumable_checkpoint(cache,&hash,spec.size,token)?;
    if let Some((path,bytes))=&resume{
        if *bytes==spec.size && matches_digest(path,spec.size,&hash,token)?{
            publish_verified_archive(path,&archive,spec,token)?;
            progress(spec.size);
            return Ok(archive);
        }
    }
    // Keep the original partial and all earlier checkpoints immutable. Copy
    // the longest incomplete one into a uniquely owned work file.
    ensure_free_space(cache, spec.size)?;
    let attempt=create_stage(&cache.join("download-ephemeral"))?;
    mark_download_stage(&attempt.0,&hash,spec.size)?;
    let working=attempt.0.join("payload.partial");
    let checkpoint=cache.join(format!("{hash}.zip.partial.v11.{}",
        attempt.0.file_name().ok_or("Stage sin nombre")?.to_string_lossy()));
    let previous_len=resume.as_ref().map(|(_,bytes)|*bytes).filter(|bytes|*bytes<spec.size).unwrap_or(0);
    let mut resume_guard=PartialResumeGuard{work:working.clone(),canonical:partial.clone(),
        checkpoint,previous_len,complete:false};
    if let Some((path,bytes))=&resume{
        if *bytes>0 && *bytes<spec.size {
            assert_no_links(path)?;
            fs::copy(path,&working).map_err(|e|format!("No se pudo copiar parcial sin modificarla: {e}"))?;
            if fs::metadata(&working).map_err(|e|e.to_string())?.len()!=*bytes {
                return Err("Descarga parcial cambió durante la copia".into());
            }
        }
    }
    let source = reqwest::Url::parse(&spec.url).map_err(|e| e.to_string())?;
    if source.scheme()!="https" && source.scheme()!="file" && !synthetic_http_fixture(&source){
        return Err("Fuente de ZIP no es HTTPS o archivo local autorizado".into());
    }
    let mut restarted_after_stale_partial=false;
    let mut restarted_after_rejected_range=false;
    loop {
    if source.scheme() == "file" {
        let from = source.to_file_path().map_err(|_| "Archivo local inválido")?;
        assert_no_links(&from)?;
        let mut reader = File::open(from).map_err(|e| e.to_string())?;
        let mut output = OpenOptions::new().write(true).create(true).truncate(true).open(&working)
            .map_err(|e|e.to_string())?;
        copy_stream(&mut reader, &mut output, 0, spec.size, token, &mut progress)?;
    } else {
        let mut attempts = 0usize;
        let mut advancing_truncations=0usize;
        let mut etag:Option<String>=None;
        loop {
            cancelled(token)?;
            let start = fs::metadata(&working).map(|m| m.len()).unwrap_or(0);
            if start == spec.size { break; }
            if start > spec.size { return Err("Descarga privada excede tamaño fijado".into()); }
            let chunk_size=if synthetic_http_fixture(&source){32*1024}else{HTTP_CHUNK_BYTES};
            let end = start.saturating_add(chunk_size - 1).min(spec.size - 1);
            let request = client.get(source.clone())
                .header(reqwest::header::RANGE, format!("bytes={start}-{end}"))
                .header(reqwest::header::ACCEPT_ENCODING, "identity");
            let request=if let Some(ref prior)=etag {
                request.header(reqwest::header::IF_RANGE,prior.as_str())
            }else{request};
            let response = request.send();
            let mut response = match response {
                Ok(response) => response,
                Err(e) => {
                    attempts += 1;
                    if attempts >= HTTP_ATTEMPTS { return Err(format!("Descarga fallida tras {attempts} intentos: {e}")); }
                    retry_http_delay(attempts,None,token)?;
                    continue;
                }
            };
            // Redirects are permitted for release assets, but not HTTPS downgrade.
            if response.url().scheme() != "https" && !synthetic_http_fixture(response.url()) {
                return Err("El servidor redirigió el paquete a una conexión no cifrada".into());
            }
            let status = response.status().as_u16();
            if retryable_http_status(status) {
                let after=response.headers().get(reqwest::header::RETRY_AFTER)
                    .and_then(|value|value.to_str().ok()).map(str::to_owned);
                attempts+=1;
                if attempts>=HTTP_ATTEMPTS {
                    return Err(format!("Origen respondió HTTP {status} tras {attempts} intentos; parcial conservada"));
                }
                drop(response);
                retry_http_delay(attempts,after.as_deref(),token)?;
                continue;
            }
            // A previous run OR this same transfer may have an incomplete
            // prefix rejected after a changed mirror/content object. Retry
            // from zero ONCE in our PRIVATE staging file; all legacy partials
            // and immutable checkpoints remain untouched.
            // A repeated 416 or ignored Range still fails closed.
            let legacy_range_rejected=previous_len>0 && start>0 && !restarted_after_rejected_range;
            let fresh_range_rejected=previous_len==0 && start>0 && !restarted_after_rejected_range;
            if (legacy_range_rejected||fresh_range_rejected)
                && matches!(status,200|416){
                drop(response);
                let cleared=OpenOptions::new().write(true).truncate(true).open(&working)
                    .map_err(|e|format!("No se pudo reiniciar descarga privada tras Range: {e}"))?;
                cleared.sync_all().map_err(|e|e.to_string())?;
                restarted_after_rejected_range=true;
                restarted_after_stale_partial=true;
                resume_guard.previous_len=0;
                etag=None;
                attempts=0;
                advancing_truncations=0;
                progress(0);
                continue;
            }
            if status == 416 {
                return Err("Origen rechazó rango; descarga parcial preservada".into());
            }
            // Gate every Content-Encoding line. HTTP permits repeated field
            // lines; get() inspects only one and could authorize raw ZIP bytes
            // from a 206 that also advertises gzip or another encoded layer.
            if response.headers().get_all(reqwest::header::CONTENT_ENCODING).iter()
                .any(|v|!v.as_bytes().eq_ignore_ascii_case(b"identity")) {
                return Err("El servidor comprimió los bytes ZIP; respuesta insegura para Range".into());
            }
            let chunk_length = validate_remote_chunk(
                status,
                response.headers().get(reqwest::header::CONTENT_RANGE).and_then(|v| v.to_str().ok()),
                response.content_length(), start, end, spec.size,
            )?;
            let validator=response.headers().get(reqwest::header::ETAG)
                .and_then(|v|v.to_str().ok()).map(str::to_owned);
            if let Some(ref prior)=etag{
                if validator.as_ref()!=Some(prior){
                    // A CDN origin can switch object generations between two
                    // valid 206 replies. Continuing would mix content, but a
                    // single clean restart against the now-stable generation
                    // can recover safely. Never truncate inherited checkpoints.
                    if restarted_after_rejected_range {
                        return Err("ETag cambió nuevamente entre partes del ZIP; sin publicar".into());
                    }
                    drop(response);
                    let cleared=OpenOptions::new().write(true).truncate(true).open(&working)
                        .map_err(|e|format!("No se pudo reiniciar copia privada tras ETag: {e}"))?;
                    cleared.sync_all().map_err(|e|e.to_string())?;
                    restarted_after_rejected_range=true;
                    restarted_after_stale_partial=true;
                    resume_guard.previous_len=0;
                    etag=None;
                    attempts=0;
                    advancing_truncations=0;
                    progress(0);
                    continue;
                }
            }
            let mut output = OpenOptions::new().create(true).write(true).append(start > 0)
                .truncate(start == 0).open(&working).map_err(|e| e.to_string())?;
            progress(start);
            let copy = copy_stream(&mut response, &mut output, start, start + chunk_length, token, &mut progress);
            match copy {
                Ok(()) => {
                    // Never retry forever after each successful bounded chunk.
                    output.sync_all().map_err(|e|
                        format!("No se pudo persistir fragmento ZIP completo: {e}"))?;
                    // Only trust a strong ETag after its bytes are durable.
                    // A 206 may advertise a validator yet close before
                    // delivering even one byte; that failed response must
                    // not consume the sole genuine mirror-rotation restart.
                    if etag.is_none() && validator.as_ref()
                        .is_some_and(|value|!value.starts_with("W/")) {
                        etag=validator.clone();
                    }
                    attempts = 0;
                    advancing_truncations=0;
                }
                Err(e) if e == "cancelled" => return Err(e),
                Err(e) => {
                    let after=output.metadata().map_err(|error|
                        format!("No se pudo medir descarga parcial tras error HTTP: {error}"))?.len();
                    if after>start {
                        // The next request starts at the actually written
                        // offset, but trust those bytes only if durable. Full
                        // SHA-256 is still required before any publication.
                        output.sync_all().map_err(|error|
                            format!("No se pudo persistir progreso ZIP parcial: {error}"))?;
                        // A truncated chunk can still contribute a durable
                        // prefix. Keep its validator so the next Range
                        // cannot mix generations without a clean restart.
                        if etag.is_none() && validator.as_ref()
                            .is_some_and(|value|!value.starts_with("W/")) {
                            etag=validator.clone();
                        }
                        advancing_truncations+=1;
                        if advancing_truncations>=HTTP_ADVANCING_TRUNCATIONS {
                            return Err(format!(
                                "Origen interrumpe fragmentos con progreso repetidamente ({advancing_truncations}); parcial preservada sin publicar: {e}"
                            ));
                        }
                        attempts=0;
                        retry_http_delay(1,None,token)?;
                    }else{
                        attempts+=1;
                        if attempts>=HTTP_ATTEMPTS { return Err(e); }
                        retry_http_delay(attempts,None,token)?;
                    }
                }
            }
        }
    }
    cancelled(token)?;
    if matches_digest(&working, spec.size, &hash, token)? { break; }
    // A legacy partial OR a fresh mirror may deliver the wrong *complete*
    // object despite syntactically valid HTTP 206/ETag. One clean private
    // redownload can recover a temporary poisoned CDN edge. The full SHA
    // always gates publication; a second mismatch fails closed. Never
    // truncate the canonical partial or any immutable checkpoint.
    // Keep the legacy partial-recovery condition explicit: earlier releases
    // require the same behavior for existing checkpoints, while v16 extends
    // the exact same one-retry budget to a fresh mirror's first bad full SHA.
    let may_restart_after_bad_sha=if previous_len>0 && !restarted_after_stale_partial {
        true
    }else{
        previous_len==0 && !restarted_after_stale_partial
    };
    if may_restart_after_bad_sha && source.scheme()!="file" {
        let cleared=OpenOptions::new().write(true).truncate(true).open(&working)
            .map_err(|e|format!("No se pudo reiniciar copia privada: {e}"))?;
        cleared.sync_all().map_err(|e|e.to_string())?;
        restarted_after_stale_partial=true;
        resume_guard.previous_len=0;
        progress(0);
        continue;
    }
    return Err("La descarga no coincide con SHA-256/tamaño; parcial preservada sin publicar".into());
    }
    // Hard-link is create-new rather than Windows MoveFileEx(REPLACE_EXISTING):
    // another cache writer winning the race must never have its file replaced.
    publish_verified_archive(&working,&archive,spec,token)?;
    resume_guard.complete=true;
    progress(spec.size);
    Ok(archive)
}

fn validate_remote_chunk(status: u16, content_range: Option<&str>, length: Option<u64>,
                         start: u64, end: u64, total: u64) -> Result<u64, String> {
    if total == 0 || start > end || end >= total {
        return Err("Rango de descarga fuera del archivo".into());
    }
    let expected = end - start + 1;
    let delivered = match status {
        206 => {
            let header = content_range.ok_or("Falta Content-Range HTTP")?;
            let (prefix, remote_total) = header.strip_prefix("bytes ")
                .and_then(|r| r.split_once('/')).ok_or("Content-Range HTTP inválido")?;
            let (first, last) = prefix.split_once('-').ok_or("Content-Range HTTP inválido")?;
            let (first, last, remote_total) = (
                first.parse::<u64>().map_err(|_| "Content-Range inicial inválido")?,
                last.parse::<u64>().map_err(|_| "Content-Range final inválido")?,
                remote_total.parse::<u64>().map_err(|_| "Content-Range tamaño inválido")?,
            );
            // A gateway can cap a requested Range to a smaller valid 206.
            // Require its start to match exactly, its last byte to stay
            // within the requested limit, and the pinned total to match.
            // The caller resumes at the *delivered* byte boundary.
            if first != start || last < first || last > end || remote_total != total {
                return Err("El servidor devolvió un rango distinto del solicitado".into());
            }
            last - first + 1
        }
        // A server may ignore Range only for a small entire ZIP, never a multi-GB asset.
        200 if start == 0 && end == total - 1 => expected,
        200 => return Err("El servidor no soporta las descargas parciales requeridas".into()),
        _ => return Err(format!("Servidor respondió HTTP {status}")),
    };
    if length.is_some_and(|value| value != delivered) {
        return Err("Content-Length del fragmento no coincide".into());
    }
    Ok(delivered)
}

fn copy_stream(input: &mut impl Read, output: &mut impl Write, start: u64, expected: u64,
               token: &AtomicBool, progress: &mut impl FnMut(u64)) -> Result<(), String> {
    let mut current = start;
    let mut buffer = [0u8; 256 * 1024];
    while current < expected {
        cancelled(token)?;
        let count = input.read(&mut buffer).map_err(|e| format!("Descarga interrumpida: {e}"))?;
        if count == 0 { return Err("El origen terminó antes del tamaño esperado".into()); }
        current = current.checked_add(count as u64).ok_or("Tamaño de descarga inválido")?;
        if current > expected { return Err("El origen superó el tamaño fijado".into()); }
        output.write_all(&buffer[..count]).map_err(|e| e.to_string())?;
        progress(current);
    }
    output.flush().map_err(|e| e.to_string())?;
    Ok(())
}

#[derive(Clone)]
struct ZipEntrySpec {
    index: usize,
    name: String,
    directory: bool,
    size: u64,
}

fn inspect_zip(archive: &mut zip::ZipArchive<File>) -> Result<Vec<ZipEntrySpec>, String> {
    if archive.len() > MAX_ZIP_ENTRIES { return Err("ZIP con demasiadas entradas".into()); }
    let mut seen = HashMap::<String,Vec<String>>::new();
    let mut entries = Vec::new();
    let mut uncompressed = 0u64;
    for index in 0..archive.len() {
        let file = archive.by_index(index).map_err(|e| e.to_string())?;
        let directory = file.is_dir();
        let name = if directory {
            normal_path(file.name().trim_end_matches(&['/', '\\'][..]))?
        } else { normal_path(file.name())? };
        let bucket=seen.entry(name.to_lowercase()).or_default();
        if bucket.iter().any(|prior|windows_path_case_equal(prior,&name)) {
            return Err(format!("Ruta duplicada dentro del ZIP: {name}"));
        }
        bucket.push(name.clone());
        if let Some(mode) = file.unix_mode() {
            let kind = mode & 0o170000;
            if kind != 0 && kind != 0o100000 && kind != 0o040000 {
                return Err(format!("Enlace o archivo especial ZIP prohibido: {name}"));
            }
        }
        if file.size() > MAX_SINGLE_ENTRY_BYTES { return Err(format!("Entrada ZIP demasiado grande: {name}")); }
        if !directory && file.size() > 100 * 1024 * 1024
            && (file.compressed_size() == 0 || file.size() / file.compressed_size().max(1) > 1000)
        { return Err(format!("Expansión ZIP anómala: {name}")); }
        uncompressed = uncompressed.checked_add(file.size()).ok_or("ZIP excede el tamaño permitido")?;
        if uncompressed > MAX_UNCOMPRESSED_BYTES { return Err("ZIP excede la cuota de extracción".into()); }
        entries.push(ZipEntrySpec { index, name, directory, size: file.size() });
    }
    let mut file_paths=HashMap::<String,Vec<String>>::new();
    for entry in entries.iter().filter(|e| !e.directory){
        file_paths.entry(entry.name.to_lowercase()).or_default().push(entry.name.clone());
    }
    for entry in &entries {
        let mut parts = entry.name.split('/').peekable();
        let mut parent = String::new();
        while parts.peek().is_some() {
            let segment = parts.next().unwrap_or("");
            if parts.peek().is_none() { break; }
            if !parent.is_empty() { parent.push('/'); }
            parent.push_str(segment);
            if file_paths.get(&parent.to_lowercase()).is_some_and(|files|
                files.iter().any(|file|windows_path_case_equal(file,&parent))) {
                return Err(format!("Conflicto entre archivo y directorio ZIP: {}", entry.name));
            }
        }
    }
    Ok(entries)
}

/// Check every archive before staging: case-insensitive collisions between
/// parts are unsafe on Windows. Exact-name file overlays preserve pack order.
/// Conservatively estimate disk usage before creating the target instance.
fn inspect_all_archives(paths: &[PathBuf], token: &AtomicBool) -> Result<u64, String> {
    let mut seen = HashMap::<String,Vec<(String,bool)>>::new();
    let mut parent_spellings = HashMap::<String,Vec<String>>::new();
    let mut bytes = 0u64;
    let mut count = 0usize;
    for path in paths {
        cancelled(token)?;
        assert_no_links(path)?;
        let mut zip = zip::ZipArchive::new(File::open(path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        for entry in inspect_zip(&mut zip)? {
            count = count.checked_add(1).ok_or("Demasiadas entradas ZIP")?;
            if count > MAX_ZIP_ENTRIES { return Err("Paquete compuesto con demasiadas entradas ZIP".into()); }
            bytes = bytes.checked_add(entry.size).ok_or("Paquete ZIP demasiado grande")?;
            if bytes > MAX_UNCOMPRESSED_BYTES { return Err("Paquete excede la cuota de extracción total".into()); }
            let key = entry.name.to_lowercase();
            let mut parent = String::new();
            let segments: Vec<&str> = entry.name.split('/').collect();
            for segment in segments.iter().take(segments.len().saturating_sub(1)) {
                if !parent.is_empty() { parent.push('/'); }
                parent.push_str(segment);
                let case_key = parent.to_lowercase();
                let spellings=parent_spellings.entry(case_key).or_default();
                if let Some(original)=spellings.iter().find(|name|
                    windows_path_case_equal(name,&parent)) {
                    if original!=&parent {
                        return Err(format!("Directorio escrito con distinta capitalización entre ZIP: {parent}"));
                    }
                }else{
                    spellings.push(parent.clone());
                }
            }
            let candidates=seen.entry(key).or_default();
            if let Some((spelling, directory))=candidates.iter().find(|(spelling,_)|
                windows_path_case_equal(spelling,&entry.name)) {
                if spelling != &entry.name || *directory != entry.directory {
                    return Err(format!("Conflicto de rutas entre partes ZIP: {}", entry.name));
                }
            }else{
                candidates.push((entry.name.clone(),entry.directory));
            }
        }
    }
    let files:HashMap<String,Vec<String>>=seen.into_iter().map(|(key,entries)|{
        (key,entries.into_iter().filter_map(|(name,directory)|
            if directory{None}else{Some(name)}).collect())
    }).collect();
    for bucket in files.values(){
        for file in bucket {
            let mut parent=file.as_str();
            while let Some((prefix,_))=parent.rsplit_once('/'){
                if files.get(&prefix.to_lowercase()).is_some_and(|names|
                    names.iter().any(|candidate|windows_path_case_equal(candidate,prefix))){
                    return Err(format!("Conflicto entre archivo y directorio en ZIP: {file}"));
                }
                parent=prefix;
            }
        }
    }
    Ok(bytes)
}

/// Reassembling .part1/.part2 or .001/.002 keeps every extracted piece on disk
/// while writing a SECOND complete joined file. The older disk preflight
/// counted only ZIP expansion, which could underestimate space by tens of GB.
/// All group sizes come from ZIP central directories, not the network body.
fn split_reassembly_scratch_bytes(paths:&[PathBuf],token:&AtomicBool)->Result<u64,String>{
    let mut groups=HashMap::<(String,bool),Vec<(String,HashMap<usize,u64>)>>::new();
    for path in paths {
        cancelled(token)?;
        assert_no_links(path)?;
        let mut zip=zip::ZipArchive::new(File::open(path).map_err(|e|e.to_string())?)
            .map_err(|e|e.to_string())?;
        for entry in inspect_zip(&mut zip)? {
            if entry.directory {continue;}
            let Some((base,suffix))=entry.name.rsplit_once('.') else {continue};
            if base.is_empty(){continue;}
            let suffix_lower=suffix.to_ascii_lowercase();
            let (style,number)=if let Some(rest)=suffix_lower.strip_prefix("part") {
                (true,rest.parse::<usize>().ok())
            }else if suffix.len()==3&&suffix.bytes().all(|c|c.is_ascii_digit()){
                (false,suffix.parse::<usize>().ok())
            }else{continue};
            let Some(number)=number.filter(|n|*n>=1&&*n<=999) else{continue};
            let candidates=groups.entry((base.to_lowercase(),style)).or_default();
            if let Some((_,parts))=candidates.iter_mut().find(|(name,_)|
                windows_path_case_equal(name,base)){
                parts.insert(number,entry.size);
            }else{
                let mut parts=HashMap::new();parts.insert(number,entry.size);
                candidates.push((base.to_owned(),parts));
            }
        }
    }
    let mut peak=0u64;
    for (_,parts) in groups.into_values().flatten() {
        if parts.len()<2||!parts.contains_key(&1){continue;}
        let total=parts.values().try_fold(0u64,|acc,size|acc.checked_add(*size))
            .ok_or("Tamaño de reensamblado ZIP desbordado")?;
        if total>MAX_SINGLE_ENTRY_BYTES {
            return Err("Archivo reensamblado supera el límite seguro".into());
        }
        peak=peak.max(total);
    }
    Ok(peak)
}

fn required_extraction_space(paths:&[PathBuf],expanded:u64,token:&AtomicBool)->Result<u64,String>{
    expanded.checked_add(split_reassembly_scratch_bytes(paths,token)?)
        .ok_or("Espacio de extracción y reensamblado desbordado".into())
}

#[cfg(windows)]
pub(crate) fn available_disk_bytes(path: &Path) -> Result<Option<u64>, String> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn GetDiskFreeSpaceExW(
            root: *const u16, available: *mut u64,
            capacity: *mut u64, total_free: *mut u64,
        ) -> i32;
    }
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut available = 0u64;
    let result = unsafe {
        GetDiskFreeSpaceExW(wide.as_ptr(), &mut available, std::ptr::null_mut(), std::ptr::null_mut())
    };
    if result == 0 {
        return Err(format!("No se pudo consultar espacio libre en {}: {}", path.display(),
            std::io::Error::last_os_error()));
    }
    Ok(Some(available))
}

#[cfg(not(windows))]
pub(crate) fn available_disk_bytes(_path: &Path) -> Result<Option<u64>, String> { Ok(None) }

pub(crate) fn ensure_free_space(path: &Path, bytes: u64) -> Result<(), String> {
    if let Some(available) = available_disk_bytes(path)? {
        let required = bytes.checked_add(MIN_FREE_HEADROOM_BYTES)
            .ok_or("Tamaño de instalación fuera de rango")?;
        if available < required {
            return Err(format!(
                "Espacio insuficiente en {}: requiere al menos {} MiB libres, disponibles {} MiB",
                path.display(), required.div_ceil(1024 * 1024), available / (1024 * 1024),
            ));
        }
    }
    Ok(())
}

#[cfg(windows)]
fn is_link(path: &Path) -> Result<bool, String> {
    use std::os::windows::fs::MetadataExt;
    match fs::symlink_metadata(path) {
        Ok(m) => Ok(m.file_type().is_symlink() || (m.file_attributes() & 0x400) != 0),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(not(windows))]
fn is_link(path: &Path) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(m) => Ok(m.file_type().is_symlink()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.to_string()),
    }
}

pub(crate) fn assert_no_links(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        if is_link(ancestor)? { return Err(format!("Ubicación enlazada insegura: {}", ancestor.display())); }
    }
    Ok(())
}

fn extract_archive(source: &Path, stage: &Path, token: &AtomicBool,
                   mut on_bytes: impl FnMut(&str, u64)) -> Result<u64, String> {
    let input = File::open(source).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(input).map_err(|e| e.to_string())?;
    // Validate the complete central directory before touching a single entry.
    let entries = inspect_zip(&mut zip)?;
    let mut extracted = 0u64;
    for entry in entries {
        cancelled(token)?;
        let destination = stage.join(&entry.name);
        assert_no_links(&destination)?;
        if entry.directory {
            fs::create_dir_all(&destination).map_err(|e| e.to_string())?;
            continue;
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            assert_no_links(parent)?;
        }
        if destination.is_dir() { return Err(format!("Conflicto de directorio: {}", entry.name)); }
        if destination.exists() { fs::remove_file(&destination).map_err(|e| e.to_string())?; }
        let mut output = OpenOptions::new().write(true).create_new(true).open(&destination)
            .map_err(|e| format!("No se puede crear {}: {e}", entry.name))?;
        let mut input = zip.by_index(entry.index).map_err(|e| e.to_string())?;
        let mut copied = 0u64;
        let mut buffer = [0u8; 1024 * 1024];
        loop {
            cancelled(token)?;
            let n = input.read(&mut buffer).map_err(|e| e.to_string())?;
            if n == 0 { break; }
            copied = copied.checked_add(n as u64).ok_or("ZIP desbordado")?;
            if copied > entry.size { return Err("ZIP expandió más bytes de los declarados".into()); }
            output.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
            extracted = extracted.checked_add(n as u64).ok_or("ZIP expandido desbordado")?;
            // This counts bytes actually written, not ZIP index or compressed
            // source bytes. A large one-file archive no longer sits at 0%.
            on_bytes(&entry.name, extracted);
        }
        if copied != entry.size { return Err(format!("Archivo ZIP incompleto: {}", entry.name)); }
    }
    Ok(extracted)
}

fn extract_archives_with_progress(
    archives: &[PathBuf], stage: &Path, expected_bytes: u64, token: &AtomicBool,
    phase: &'static str, mut progress: impl FnMut(&'static str, &str, u64, u64),
) -> Result<(), String> {
    if archives.is_empty() { return Err("No hay ZIP autorizados para extraer".into()); }
    let mut completed = 0u64;
    let mut last_bucket = None;
    progress(phase, "", 0, expected_bytes);
    for archive in archives {
        cancelled(token)?;
        let prior = completed;
        let advanced = extract_archive(archive, stage, token, |filename, copied| {
            let done = prior.saturating_add(copied);
            let bucket = if expected_bytes == 0 { 0 }
                else { done.saturating_mul(1000) / expected_bytes };
            // Emit only when 0.1% changes, instead of every 1 MiB for huge
            // archives. All emitted counts are real decompressed bytes written.
            if last_bucket != Some(bucket) || done == expected_bytes {
                last_bucket = Some(bucket);
                progress(phase, filename, done, expected_bytes);
            }
        })?;
        completed = completed.checked_add(advanced).ok_or("ZIP expandido desbordado")?;
        if completed > expected_bytes { return Err("Extracción excedió el total prevalidado".into()); }
    }
    cancelled(token)?;
    if completed != expected_bytes {
        return Err("Los bytes extraídos no coinciden con el preflight ZIP".into());
    }
    progress(phase, "", completed, expected_bytes);
    Ok(())
}

// Some standalone publishers ship large files split as file.part1 / file.part2
// or file.001 / file.002 inside different ZIP parts. Reassemble only in staging.
fn reassemble_splits(stage: &Path, token: &AtomicBool) -> Result<(), String> {
    let mut directories = vec![stage.to_path_buf()];
    while let Some(directory) = directories.pop() {
        cancelled(token)?;
        assert_no_links(&directory)?;
        let children: Vec<_> = fs::read_dir(&directory).map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
        for child in &children {
            if child.file_type().map_err(|e| e.to_string())?.is_dir() {
                directories.push(child.path());
            }
        }
        for child in children {
            let name = child.file_name().to_string_lossy().into_owned();
            let Some((base, suffix)) = name.rsplit_once('.') else { continue };
            let style = if suffix.eq_ignore_ascii_case("part1") { Some(true) }
                        else if suffix == "001" { Some(false) } else { None };
            let Some(named_parts) = style else { continue };
            if base.is_empty() { continue; }
            let mut pieces = Vec::<(usize, PathBuf)>::new();
            let mut used = HashSet::new();
            for entry in fs::read_dir(&directory).map_err(|e| e.to_string())? {
                let entry = entry.map_err(|e| e.to_string())?;
                if !entry.file_type().map_err(|e| e.to_string())?.is_file() { continue; }
                let file_name = entry.file_name().to_string_lossy().into_owned();
                let Some((prefix, ending)) = file_name.rsplit_once('.') else { continue };
                if !windows_path_case_equal(prefix,base) { continue; }
                let number = if named_parts {
                    ending.to_ascii_lowercase().strip_prefix("part")
                        .and_then(|s| s.parse::<usize>().ok())
                } else if ending.len() == 3 && ending.bytes().all(|b| b.is_ascii_digit()) {
                    ending.parse::<usize>().ok()
                } else { None };
                if let Some(number) = number {
                    if number == 0 || number > 999 || !used.insert(number) {
                        return Err(format!("Partes divididas ambiguas: {base}"));
                    }
                    pieces.push((number, entry.path()));
                }
            }
            if pieces.len() <= 1 { continue; }
            pieces.sort_by_key(|(number, _)| *number);
            for (index, (number, _)) in pieces.iter().enumerate() {
                if *number != index + 1 {
                    return Err(format!("Falta una parte del archivo dividido: {base}"));
                }
            }
            let target = directory.join(base);
            if target.exists() || is_link(&target)? {
                return Err(format!("La salida del archivo dividido ya existe: {base}"));
            }
            let temporary = directory.join(format!("{base}.coco2-assembling"));
            let extra=pieces.iter().try_fold(0u64,|total,(_,piece)|{
                if assert_no_links(piece).is_err(){return None;}
                total.checked_add(fs::metadata(piece).ok()?.len())
            }).ok_or("No se pudo reservar espacio para reensamblar partes")?;
            if extra>MAX_SINGLE_ENTRY_BYTES{
                return Err("Archivo dividido supera tamaño máximo".into());
            }
            ensure_free_space(&directory,extra)?;
            let mut output = OpenOptions::new().write(true).create_new(true).open(&temporary)
                .map_err(|e| format!("No se pudo preparar archivo dividido {base}: {e}"))?;
            let mut total = 0u64;
            for (_, piece) in &pieces {
                cancelled(token)?;
                let mut input = File::open(piece).map_err(|e| e.to_string())?;
                let mut buffer = [0u8; 1024 * 1024];
                loop {
                    cancelled(token)?;
                    let count = input.read(&mut buffer).map_err(|e| e.to_string())?;
                    if count == 0 { break; }
                    total = total.checked_add(count as u64).ok_or("Archivo dividido demasiado grande")?;
                    if total > MAX_SINGLE_ENTRY_BYTES { return Err("Archivo dividido demasiado grande".into()); }
                    output.write_all(&buffer[..count]).map_err(|e| e.to_string())?;
                }
            }
            output.sync_all().map_err(|e| e.to_string())?;
            drop(output);
            publish_reassembled_file(&temporary,&target)?;
            for (_, piece) in pieces { fs::remove_file(piece).map_err(|e| e.to_string())?; }
        }
    }
    Ok(())
}

/// Same-volume hard-link is create-only on Windows. An unrelated file created
/// after target.exists() must never be overwritten by fs::rename.
fn publish_reassembled_file(temporary:&Path,target:&Path)->Result<(),String>{
    assert_no_links(temporary)?;
    assert_no_links(target)?;
    fs::hard_link(temporary,target)
        .map_err(|e|format!("Salida dividida existente/bloqueada, sin sobrescribir: {e}"))?;
    fs::remove_file(temporary).map_err(|e|format!("No se pudo liberar temporal reensamblado: {e}"))
}

fn verify_staged_files(stage: &Path, files: &[FileSpec], token: &AtomicBool) -> Result<(), String> {
    for entry in files {
        cancelled(token)?;
        let relative = normal_path(&entry.path)?;
        let path = stage.join(relative);
        assert_no_links(&path)?;
        if !matches_digest(&path, entry.size, &entry.sha256, token)? {
            return Err(format!("Archivo requerido ausente o alterado: {}", entry.path));
        }
    }
    Ok(())
}

fn immutable_extra_files(stage: &Path, archives: &[PathBuf], token: &AtomicBool) -> Result<Vec<FileSpec>, String> {
    let mut paths = HashSet::<String>::new();
    for archive in archives {
        cancelled(token)?;
        let mut zip = zip::ZipArchive::new(File::open(archive).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        for entry in inspect_zip(&mut zip)? {
            if entry.directory { continue; }
            // User-editable BepInEx configs are intentionally NOT immutable.
            if entry.name.to_ascii_lowercase().starts_with("bepinex/config/") { continue; }
            paths.insert(entry.name);
        }
    }
    let mut files = Vec::with_capacity(paths.len());
    for relative in paths {
        cancelled(token)?;
        let path = stage.join(&relative);
        assert_no_links(&path)?;
        let (size, sha256) = file_digest(&path, token)?;
        files.push(FileSpec { path: relative, size, sha256 });
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn create_stage(target: &Path) -> Result<StageGuard, String> {
    let parent = target.parent().ok_or("La instancia no tiene directorio padre")?;
    assert_no_links(parent)?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    assert_no_links(parent)?;
    for attempt in 0..10 {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
        let name = format!(".coco2-stage-{}-{nanos}-{attempt}", std::process::id());
        let path = parent.join(name);
        match fs::create_dir(&path) {
            Ok(()) => return Ok(StageGuard(path)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("No se pudo preparar área temporal: {e}")),
        }
    }
    Err("No se pudo reservar un directorio temporal exclusivo".into())
}

/// Receipt lives inside the staged instance before commit. It is deliberately
/// NOT the legacy standalone-state.json v2: the private manifest has no pack
/// checksum or role, and inventing those would make old repairs unreliable.
fn write_install_receipt(stage: &Path, manifest: &Manifest, installed_extras: &[FileSpec]) -> Result<(), String> {
    let metadata = stage.join(".coco");
    if metadata.exists() { return Err("El paquete intentó ocupar el directorio reservado .coco".into()); }
    fs::create_dir(&metadata).map_err(|e| e.to_string())?;
    let destination = metadata.join("standalone-install-v1.json");
    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?.as_secs();
    let receipt = serde_json::json!({
        "schemaVersion": 1,
        "type": "coco2-standalone-install",
        "complete": true,
        "id": manifest.id,
        "instanceId": manifest.instance_id,
        "workflow": manifest.workflow,
        "version": manifest.version,
        "installedAtUnixSeconds": timestamp,
        "archiveShas": manifest.archives.iter().map(|a| a.sha256.to_ascii_lowercase()).collect::<Vec<_>>(),
        "requiredFiles": manifest.required_files,
        "extraFileArchives": manifest.extra_files,
        "extraFiles": installed_extras,
    });
    let mut file = OpenOptions::new().write(true).create_new(true).open(destination)
        .map_err(|e| e.to_string())?;
    serde_json::to_writer_pretty(&mut file, &receipt).map_err(|e| e.to_string())?;
    file.write_all(b"\n").map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| format!("No se pudo asegurar recibo de instalación: {e}"))?;
    Ok(())
}

/// Windows MoveFileW does not replace an existing destination directory;
/// std::fs::rename could overwrite a directory on other platforms.
#[cfg(windows)]
fn publish_stage(stage: &Path, target: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn MoveFileW(old_name: *const u16, new_name: *const u16) -> i32;
    }
    let old: Vec<u16> = stage.as_os_str().encode_wide().chain(Some(0)).collect();
    let new: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe { MoveFileW(old.as_ptr(), new.as_ptr()) } == 0 {
        return Err(format!("No se pudo publicar la instancia sin reemplazarla: {}",
            std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn publish_stage(stage: &Path, target: &Path) -> Result<(), String> {
    if target.exists() { return Err("La instancia apareció antes del commit".into()); }
    fs::rename(stage, target).map_err(|e| e.to_string())
}

fn install_new(m: &Manifest, target: &Path, cache: &Path, token: &AtomicBool,
               mut progress: impl FnMut(&'static str, &str, u64, u64)) -> Result<InstallOutcome, String> {
    let outcome = |status, message: &str| InstallOutcome {
        id: m.id.clone(), status, instance_path: target.display().to_string(), message: message.into(),
    };
    if target.exists() { return Ok(outcome("needs-repair", "Instancia existente: la instalación nueva no sobrescribe archivos")); }
    if has_unsupported_extras(m) { return Ok(outcome("unsupported-extras", "Los extras declarados aún no tienen instalador nativo")); }
    cancelled(token)?;
    assert_no_links(target)?;
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .timeout(HTTP_CHUNK_TIMEOUT)
        .redirect(safe_archive_redirect())
        .build().map_err(|e| e.to_string())?;
    let archive_bytes = m.archives.iter().try_fold(0u64, |sum, a| sum.checked_add(a.size)
        .ok_or("Tamaño total inválido"))?;
    let total = m.extra_files.iter().try_fold(archive_bytes, |sum, a| sum.checked_add(a.size)
        .ok_or("Tamaño total inválido"))?;
    let mut obtained = 0u64;
    let mut zip_paths = Vec::new();
    let mut last_download_bucket = None;
    for part in &m.archives {
        cancelled(token)?;
        let path = download_one(part, cache, &client, token, |bytes| {
            let done = obtained.saturating_add(bytes);
            let bucket = if total == 0 { 0 } else { (done.saturating_mul(1000) / total).min(1000) };
            // Bound expensive cross-process progress events to 0.1% steps,
            // while keeping the original byte counters and stage transitions.
            if last_download_bucket != Some(bucket) || done == total {
                last_download_bucket = Some(bucket);
                progress("downloading", &part.sha256, done, total);
            }
        })?;
        obtained = obtained.saturating_add(part.size);
        zip_paths.push(path);
    }
    let mut extra_paths = Vec::new();
    for extra in &m.extra_files {
        cancelled(token)?;
        let source = ArchiveSpec {
            url: extra.source_url.clone(), size: extra.size, sha256: extra.sha256.clone(),
        };
        let path = download_one(&source, cache, &client, token, |bytes| {
            let done = obtained.saturating_add(bytes);
            let bucket = if total == 0 { 0 } else { (done.saturating_mul(1000) / total).min(1000) };
            if last_download_bucket != Some(bucket) || done == total {
                last_download_bucket = Some(bucket);
                progress("downloading", &extra.path, done, total);
            }
        })?;
        obtained = obtained.saturating_add(extra.size);
        extra_paths.push(path);
    }
    if target.exists() { return Ok(outcome("needs-repair", "La instancia apareció durante la descarga")); }
    let mut all_archives = zip_paths.clone();
    all_archives.extend(extra_paths.iter().cloned());
    // Pin + fully rehash the shared cache ZIPs after download (not merely
    // before it), and hold the Win32 handles until the final stage commit.
    let _pinned_archives = pin_verified_archives(&all_archives, &expected_zip_sources(m), token)?;
    let expected_uncompressed = inspect_all_archives(&all_archives, token)?;
    let target_parent = target.parent().ok_or("La instancia no tiene directorio padre")?;
    assert_no_links(target_parent)?;
    fs::create_dir_all(target_parent).map_err(|e| e.to_string())?;
    ensure_free_space(target_parent, required_extraction_space(&all_archives,expected_uncompressed,token)?)?;
    let stage = create_stage(target)?;
    extract_archives_with_progress(&all_archives,&stage.0,expected_uncompressed,token,
        "extracting",&mut progress)?;
    reassemble_splits(&stage.0, token)?;
    progress("verifying", "requiredFiles", 0, m.required_files.len() as u64);
    verify_staged_files(&stage.0, &m.required_files, token)?;
    let expanded_extras = immutable_extra_files(&stage.0, &extra_paths, token)?;
    write_install_receipt(&stage.0, m, &expanded_extras)?;
    cancelled(token)?;
    if target.exists() { return Ok(outcome("needs-repair", "La instancia apareció durante la preparación")); }
    assert_no_links(target)?;
    // Same-volume rename is the commit point; the live instance was never opened for writing.
    publish_stage(&stage.0, target)?;
    progress("completed", "", 1, 1);
    Ok(outcome("installed", "Instalación nueva verificada y consolidada"))
}

/// Rebuilds the desired distribution in a private temporary folder under the
/// verified SHA cache. Intentionally does NOT commit the replacement. An
/// in-place transaction cannot yet guarantee consistent saves/configuration
/// while unrelated processes can edit or create files in the live game tree.
/// We cannot safely swap two Windows directories atomically or ensure recovery
/// from a crash between two renames. Returning a distinct prepared status is
/// therefore safer than silently replacing a live installation.
fn prepare_repair(m: &Manifest, target: &Path, cache: &Path, token: &AtomicBool,
                  progress: impl FnMut(&'static str, &str, u64, u64))
    -> Result<InstallOutcome, String>
{
    repair_internal(m,target,cache,token,false,&||Ok(()),progress)
}

fn repair_internal(m: &Manifest, target: &Path, cache: &Path, token: &AtomicBool,
                  commit:bool,game_guard:&dyn Fn()->Result<(),String>,
                  mut progress: impl FnMut(&'static str, &str, u64, u64))
    -> Result<InstallOutcome, String>
{
    let outcome = |status, message: &str| InstallOutcome {
        id: m.id.clone(), status, instance_path: target.display().to_string(),
        message: message.to_string(),
    };
    let current = inspect_existing(m, target, token)?;
    if current.status == "not-installed" {
        return Ok(outcome("not-installed", "No hay juego instalado; utiliza instalación nueva"));
    }
    if current.status == "unsafe-existing" {
        return Ok(outcome("unsafe-existing", "Ruta o recibo de instalación inseguro; no se tocarán sus archivos"));
    }
    if current.status == "already-verified" {
        return Ok(outcome("already-verified", "Archivos esenciales íntegros; no hay reparación pendiente"));
    }
    if commit && current.receipt != "matching" {
        return Ok(outcome("repair-ownership-unverified",
            "Reparación real exige recibo Coco2 coincidente; conserva intacta la instalación heredada"));
    }
    if has_unsupported_extras(m) {
        return Ok(outcome("unsupported-extras", "Extras no compatibles; no se prepara una reparación incompleta"));
    }
    cancelled(token)?;
    assert_no_links(cache)?;
    fs::create_dir_all(cache).map_err(|e| e.to_string())?;
    assert_no_links(cache)?;
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .timeout(HTTP_CHUNK_TIMEOUT)
        .redirect(safe_archive_redirect())
        .build().map_err(|e| e.to_string())?;
    let total = m.archives.iter().map(|a| a.size).chain(m.extra_files.iter().map(|a| a.size))
        .try_fold(0u64, |sum, bytes| sum.checked_add(bytes).ok_or("Tamaño de reparación fuera de rango"))?;
    let mut obtained = 0u64;
    let mut sources = Vec::with_capacity(m.archives.len() + m.extra_files.len());
    for a in &m.archives {
        cancelled(token)?;
        sources.push(download_one(a, cache, &client, token,
            |bytes| progress("repair-downloading", &a.sha256, obtained.saturating_add(bytes), total))?);
        obtained = obtained.saturating_add(a.size);
    }
    let mut extra_sources = Vec::new();
    for extra in &m.extra_files {
        cancelled(token)?;
        let a = ArchiveSpec { url: extra.source_url.clone(), sha256: extra.sha256.clone(), size: extra.size };
        let path = download_one(&a, cache, &client, token,
            |bytes| progress("repair-downloading", &extra.path, obtained.saturating_add(bytes), total))?;
        sources.push(path.clone());
        extra_sources.push(path);
        obtained = obtained.saturating_add(a.size);
    }
    // Staging is in our download cache (not a sibling of the user's game).
    // StageGuard deletes it on success, failure, or cancellation.
    let _pinned_archives = pin_verified_archives(&sources, &expected_zip_sources(m), token)?;
    let bytes = inspect_all_archives(&sources, token)?;
    ensure_free_space(cache, required_extraction_space(&sources,bytes,token)?)?;
    let stage = create_stage(&cache.join("repair-ephemeral-staging"))?;
    extract_archives_with_progress(&sources,&stage.0,bytes,token,
        "repair-extracting",&mut progress)?;
    reassemble_splits(&stage.0, token)?;
    progress("repair-verifying", "requiredFiles", 0, m.required_files.len() as u64);
    verify_staged_files(&stage.0, &m.required_files, token)?;
    let _ = immutable_extra_files(&stage.0, &extra_sources, token)?;
    cancelled(token)?;
    // Verify live status once more, but NEVER mutate it. Another program may
    // continue changing it while we operate; this is why commit is disabled.
    if !target.exists() {
        return Ok(outcome("instance-changed", "La instancia desapareció; caché ZIP verificada conservada"));
    }
    assert_no_links(target)?;
    if commit {
        game_guard()?;
        let result=repair_transaction::commit(m,target,&stage.0,token,game_guard,&mut progress)?;
        return Ok(outcome(result,match result {
            "repaired"=>"Componentes dañados recuperados desde archivos SHA-256 verificados; journal finalizado",
            _=>"No se encontraron componentes que requieran reemplazo",
        }));
    }
    progress("repair-prepared", "", 1, 1);
    Ok(outcome("repair-prepared-no-commit",
        "ZIP y archivos esenciales verificados en caché; no se reemplazó ningún archivo del juego. Falta transacción segura contra procesos activos y caídas."))
}

fn upgrade_internal(m:&Manifest,target:&Path,cache:&Path,token:&AtomicBool,
                    game_guard:&dyn Fn()->Result<(),String>,
                    mut progress:impl FnMut(&'static str,&str,u64,u64)) -> Result<UpgradeOutcome,String>{
    let initial=upgrade_plan(m,target,cache);
    let from_version=initial.from_version.clone().unwrap_or_default();
    let outcome=|status,message:&str| UpgradeOutcome{id:m.id.clone(),status,
        from_version:from_version.clone(),to_version:m.version.clone(),
        needed_bytes:initial.needed_bytes,instance_path:target.display().to_string(),message:message.into()};
    if initial.status!="upgrade-ready"{return Ok(outcome(initial.status,&initial.message));}
    let (old,_)=authoritative_baseline(m,target)?;
    cancelled(token)?;game_guard()?;assert_no_links(cache)?;
    fs::create_dir_all(cache).map_err(|e|e.to_string())?;
    assert_no_links(cache)?;
    let client=reqwest::blocking::Client::builder().connect_timeout(Duration::from_secs(30))
        .timeout(HTTP_CHUNK_TIMEOUT).redirect(safe_archive_redirect())
        .build().map_err(|e|e.to_string())?;
    let total=m.archives.iter().map(|a|a.size).chain(m.extra_files.iter().map(|a|a.size))
        .try_fold(0u64,|sum,n|sum.checked_add(n).ok_or("Tamaño total de actualización inválido"))?;
    let mut acquired=0u64;
    let mut sources=Vec::new();
    for archive in &m.archives{
        cancelled(token)?;
        sources.push(download_one(archive,cache,&client,token,|bytes|
            progress("upgrade-downloading",&archive.sha256,acquired.saturating_add(bytes),total))?);
        acquired=acquired.saturating_add(archive.size);
    }
    let mut extras=Vec::new();
    for extra in &m.extra_files{
        cancelled(token)?;
        let archive=ArchiveSpec{url:extra.source_url.clone(),sha256:extra.sha256.clone(),size:extra.size};
        let path=download_one(&archive,cache,&client,token,|bytes|
            progress("upgrade-downloading",&extra.path,acquired.saturating_add(bytes),total))?;
        sources.push(path.clone());extras.push(path);
        acquired=acquired.saturating_add(extra.size);
    }
    let _pinned_archives=pin_verified_archives(&sources,&expected_zip_sources(m),token)?;
    let expanded=inspect_all_archives(&sources,token)?;
    ensure_free_space(cache,required_extraction_space(&sources,expanded,token)?)?;
    let stage=create_stage(&cache.join("upgrade-ephemeral-staging"))?;
    extract_archives_with_progress(&sources,&stage.0,expanded,token,
        "upgrade-extracting",&mut progress)?;
    reassemble_splits(&stage.0,token)?;
    progress("upgrade-verifying","requiredFiles",0,m.required_files.len() as u64);
    verify_staged_files(&stage.0,&m.required_files,token)?;
    let immutable_extras=immutable_extra_files(&stage.0,&extras,token)?;
    write_install_receipt(&stage.0,m,&immutable_extras)?;
    cancelled(token)?;game_guard()?;
    let result=repair_transaction::upgrade(&old,m,target,&stage.0,&immutable_extras,token,
        game_guard,&mut progress)?;
    Ok(outcome(result,"Versión B instalada con SHA-256, respaldo transaccional y recibo actualizado"))
}

#[tauri::command]
pub async fn upgrade_standalone(id:String,app:AppHandle,state:State<'_,InstallState>)
    ->Result<UpgradeOutcome,String>{
    let manifest=read_manifest(&id)?;
    let (app_data,local_data)=roots()?;
    let target=instance_path(&manifest,&app_data,&local_data)?;
    let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    let active=Arc::clone(&state.active);
    let token=Arc::new(AtomicBool::new(false));
    {
        let mut jobs=active.lock().map_err(|_|"Motor de instalación ocupado")?;
        if !jobs.is_empty(){return Err("Otro juego está en instalación, reparación o actualización".into());}
        jobs.insert(id,Arc::clone(&token));
    }
    tauri::async_runtime::spawn_blocking(move||{
        let _guard=ActiveGuard{id:manifest.id.clone(),active};
        let guard=||guard_game_processes(&app);
        guard()?;
        let outcome=upgrade_internal(&manifest,&target,&cache,&token,&guard,|phase,file,done,total|{
            emit_progress(&app,&manifest.id,phase,file,done,total);
        })?;
        if outcome.status=="upgraded"{remove_cached_archives(&manifest.id);}
        Ok(outcome)
    }).await.map_err(|e|format!("Upgrade interrumpido: {e}"))?
}

#[tauri::command]
pub async fn recover_standalone_upgrade(id:String,app:AppHandle,state:State<'_,InstallState>)
    ->Result<UpgradeOutcome,String>{
    let current=read_manifest(&id)?;
    let (app_data,local_data)=roots()?;
    let target=instance_path(&current,&app_data,&local_data)?;
    let active=Arc::clone(&state.active);
    {
        let mut jobs=active.lock().map_err(|_|"Motor de recuperación ocupado")?;
        if !jobs.is_empty(){return Err("Hay otra operación en ejecución".into());}
        jobs.insert(id,Arc::new(AtomicBool::new(false)));
    }
    tauri::async_runtime::spawn_blocking(move||{
        let _guard=ActiveGuard{id:current.id.clone(),active};
        let guard=||guard_game_processes(&app);
        guard()?;
        let from=repair_transaction::upgrade_recovery_versions(&target)?;
        let (old_version,to_version)=from.unwrap_or_else(||(String::new(),current.version.clone()));
        let pinned=if to_version==current.version{current.clone()}else{
            trusted_manifest_version(&current.id,&to_version)?
                .ok_or("La versión B de journal ya no está autorizada en historial confiable")?
        };
        let status=repair_transaction::recover_upgrade(&pinned,&target,&guard,&mut |phase,file,done,total|{
            emit_progress(&app,&current.id,phase,file,done,total);
        })?;
        emit_progress(&app,&current.id,"upgrade-recovered","",1,1);
        Ok(UpgradeOutcome{id:current.id,status,from_version:old_version,to_version,
            needed_bytes:0,instance_path:target.display().to_string(),
            message:"Recuperación verificada contra journal y baseline histórico autorizado".into()})
    }).await.map_err(|e|format!("Recovery de upgrade interrumpido: {e}"))?
}

/// Safe unattended preparation, not a destructive reinstall. The existing
/// cancellation command uses this same InstallState and job token.
#[tauri::command]
pub async fn prepare_standalone_repair(id: String, app: AppHandle, state: State<'_, InstallState>)
    -> Result<InstallOutcome, String>
{
    let m = read_manifest(&id)?;
    let (app_data, local_data) = roots()?;
    let target = instance_path(&m, &app_data, &local_data)?;
    let active = Arc::clone(&state.active);
    let token = Arc::new(AtomicBool::new(false));
    {
        let mut jobs = active.lock().map_err(|_| "Motor de instalación ocupado")?;
        if !jobs.is_empty() { return Err("Ya existe otra instalación o preparación en ejecución".into()); }
        jobs.insert(id.clone(), Arc::clone(&token));
    }
    let cache = local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = ActiveGuard { id: m.id.clone(), active };
        let result = prepare_repair(&m, &target, &cache, &token, |phase, file, done, total| {
            emit_progress(&app, &m.id, phase, file, done, total);
        });
        match result {
            Err(e) if e == "cancelled" => {
                emit_progress(&app, &m.id, "cancelled", "", 0, 0);
                Ok(InstallOutcome { id: m.id.clone(), status: "cancelled",
                    instance_path: target.display().to_string(),
                    message: "Preparación cancelada; instancia original intacta".into() })
            }
            Err(e) => {
                emit_progress(&app, &m.id, "failed", "", 0, 0);
                Err(e)
            }
            result => result,
        }
    }).await.map_err(|e| format!("Preparación interrumpida: {e}"))?
}

/// Fail closed on observed external games (including JVM/managed Minecraft) and
/// any process-enumeration uncertainty. Repeated before each actual file rename.
fn guard_game_processes(app:&AppHandle)->Result<(),String>{
    let report=tauri::async_runtime::block_on(
        crate::services::standalone::get_active_game_processes(
            app.state::<crate::services::standalone::RuntimeState>()))
        .map_err(|_|"No fue posible comprobar los juegos activos")?;
    if report.status!="none" || !report.safe_to_update {
        return Err("Hay un juego activo o procesos no identificados; reparación bloqueada".into());
    }
    Ok(())
}

/// One-click repair: verified cached/downloaded sources -> private extraction ->
/// journal and backups -> guarded replacements -> verify SHA -> commit marker.
/// Cancellation is honored until the journal exists, then safely deferred.
#[tauri::command]
pub async fn commit_standalone_repair(id:String,app:AppHandle,state:State<'_,InstallState>)
    ->Result<InstallOutcome,String>
{
    let manifest=read_manifest(&id)?;
    let (app_data,local_data)=roots()?;
    let target=instance_path(&manifest,&app_data,&local_data)?;
    let token=Arc::new(AtomicBool::new(false));
    let active=Arc::clone(&state.active);
    {
        let mut jobs=active.lock().map_err(|_|"Motor de reparación ocupado")?;
        if !jobs.is_empty(){return Err("Existe otra instalación o reparación en ejecución".into());}
        jobs.insert(id.clone(),Arc::clone(&token));
    }
    let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    tauri::async_runtime::spawn_blocking(move||{
        let _guard=ActiveGuard{id:manifest.id.clone(),active};
        guard_game_processes(&app)?;
        let tx=target.join(".coco").join("repair-transaction-v1");
        assert_no_links(&tx)?;
        if tx.exists(){return Err("Hay reparación interrumpida: usa Recuperar antes de continuar".into());}
        let guard=||guard_game_processes(&app);
        repair_internal(&manifest,&target,&cache,&token,true,&guard,|phase,file,done,total|{
            emit_progress(&app,&manifest.id,phase,file,done,total);
        })
    }).await.map_err(|e|format!("Reparación interrumpida: {e}"))?
}

/// Restores the exact previous files from durable same-volume backups if a
/// commit was interrupted; committed transactions merely finish cleanup.
#[tauri::command]
pub async fn recover_standalone_repair(id:String,app:AppHandle,state:State<'_,InstallState>)
    ->Result<InstallOutcome,String>
{
    let manifest=read_manifest(&id)?;
    let (app_data,local_data)=roots()?;
    let target=instance_path(&manifest,&app_data,&local_data)?;
    let active=Arc::clone(&state.active);
    {
        let mut jobs=active.lock().map_err(|_|"Motor de recuperación ocupado")?;
        if !jobs.is_empty(){return Err("Existe otra instalación o reparación en ejecución".into());}
        jobs.insert(id.clone(),Arc::new(AtomicBool::new(false)));
    }
    tauri::async_runtime::spawn_blocking(move||{
        let _guard=ActiveGuard{id:manifest.id.clone(),active};
        let guard=||guard_game_processes(&app);
        let recovered=repair_transaction::recover(&manifest,&target,&guard,&mut |phase,file,done,total|{
            emit_progress(&app,&manifest.id,phase,file,done,total);
        })?;
        emit_progress(&app,&manifest.id,"repair-recovered","",1,1);
        Ok(InstallOutcome{id:manifest.id,status:recovered,
            instance_path:target.display().to_string(),
            message:if recovered=="no-recovery-needed"{"No hay una reparación interrumpida"}
                    else{"Recuperación del journal finalizada con originales preservados"}.into()})
    }).await.map_err(|e|format!("Recuperación interrumpida: {e}"))?
}

/// Read-only indicator so the UI can offer recovery immediately after a
/// restart, before any expensive hash checks or downloads are attempted.
#[tauri::command]
pub async fn get_standalone_repair_recovery_status(id:String)->Result<RepairRecoveryStatus,String>{
    let m=read_manifest(&id)?;
    let (app_data,local_data)=roots()?;
    let target=instance_path(&m,&app_data,&local_data)?;
    tauri::async_runtime::spawn_blocking(move||{
        assert_no_links(&target)?;
        let root=target.join(".coco").join("repair-transaction-v1");
        let cleanup=target.join(".coco").join("repair-cleanup-v1");
        assert_no_links(&root)?;assert_no_links(&cleanup)?;
        let pending=root.exists();
        let cleanup_pending=cleanup.exists();
        Ok(RepairRecoveryStatus{id:m.id,pending,cleanup_pending,
            message:if pending {"Reparación interrumpida; recuperar los archivos anteriores"}
                    else if cleanup_pending {"Reparación terminada; falta limpiar journal"}
                    else {"Sin reparación pendiente"}.into()})
    }).await.map_err(|e|format!("No se pudo inspeccionar el journal: {e}"))?
}

#[tauri::command]
pub async fn install_standalone(id: String, app: AppHandle, state: State<'_, InstallState>)
    -> Result<InstallOutcome, String>
{
    let m = read_manifest(&id)?;
    let (app_data, local_data) = roots()?;
    let target = instance_path(&m, &app_data, &local_data)?;
    let preliminary = plan(&m, &target);
    if preliminary.status != "ready" {
        return Ok(InstallOutcome { id, status: preliminary.status,
            instance_path: preliminary.instance_path, message: preliminary.message });
    }
    let active = Arc::clone(&state.active);
    let token = Arc::new(AtomicBool::new(false));
    {
        let mut jobs = active.lock().map_err(|_| "Motor de instalación ocupado")?;
        // Serializes shared SHA caches and protects against overlapping installs.
        if !jobs.is_empty() { return Err("Ya existe otra instalación standalone en ejecución".into()); }
        jobs.insert(id.clone(), Arc::clone(&token));
    }
    let cache = local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = ActiveGuard { id: m.id.clone(), active };
        // Before any byte arrives: Defender removes Online-Fix files as they unpack.
        crate::services::defender::ensure_for_new_folder(&app, &target);
        let result = install_new(&m, &target, &cache, &token, |phase, file, done, total| {
            emit_progress(&app, &m.id, phase, file, done, total);
        });
        match result {
            Err(error) if error == "cancelled" => {
                emit_progress(&app, &m.id, "cancelled", "", 0, 0);
                Ok(InstallOutcome { id: m.id.clone(), status: "cancelled",
                    instance_path: target.display().to_string(), message: "Instalación cancelada; lo descargado se conserva mientras Coco siga abierto".into() })
            }
            Err(error) => {
                emit_progress(&app, &m.id, "failed", "", 0, 0);
                Err(error)
            }
            Ok(outcome) => {
                if outcome.status == "installed" {
                    // Saves set aside under the old default folder come along too.
                    crate::services::location::follow_kept_saves(
                        &crate::services::inventory::legacy_root(&app_data).join(&m.instance_id), &target, &m.instance_id);
                    crate::services::uninstall::restore_kept_saves(&target, &m.instance_id);
                    // Installed and verified: the ZIP would only double the game's space on disk.
                    remove_cached_archives(&m.id);
                }
                Ok(outcome)
            }
        }
    }).await.map_err(|e| format!("Motor de instalación interrumpido: {e}"))?
}

/// Holds the single install slot, so no install or update can start during a removal.
pub(crate) fn reserve_exclusive(id:&str,state:&InstallState)->Result<(impl Drop+Send+'static,Arc<AtomicBool>),String>{
    let active=Arc::clone(&state.active);
    let mut jobs=active.lock().map_err(|_|"Motor de instalación ocupado")?;
    if !jobs.is_empty(){return Err("Espera a que termine la instalación en curso.".into());}
    let token=Arc::new(AtomicBool::new(false));
    jobs.insert(id.to_string(),Arc::clone(&token));
    drop(jobs);
    Ok((ActiveGuard{id:id.to_string(),active},token))
}

pub(crate) fn assert_can_remove(target:&Path,id:&str,instance_id:&str)->Result<(),String>{
    assert_no_links(target)?;
    if repair_transaction::inspect_pending(target,id,instance_id)?.is_empty(){Ok(())}
    else{Err("Hay una operación interrumpida en este juego. Recupérala antes de desinstalarlo.".into())}
}

/// A paused or cancelled download only resumes while Coco stays open, and a finished ZIP is only
/// needed until it is unpacked; a repair downloads again. Run when Coco opens and when it closes,
/// with no install running, so nothing the player is not using stays on disk.
pub(crate) fn sweep_download_cache(local_data:&Path){
    let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    if is_link(&cache).unwrap_or(true){return;}
    let Ok(entries)=fs::read_dir(&cache) else {return};
    for entry in entries.flatten(){
        let Ok(meta)=fs::symlink_metadata(entry.path()) else {continue};
        if is_link(&entry.path()).unwrap_or(true){continue;}
        let name=entry.file_name().to_string_lossy().to_ascii_lowercase();
        if meta.is_dir(){
            // Private work folders of interrupted downloads, repairs and updates.
            if matches!(name.as_str(),"download-ephemeral"|"repair-ephemeral-staging"|"upgrade-ephemeral-staging")
                ||name.starts_with(".coco2-stage-"){
                let _=fs::remove_dir_all(entry.path());
            }
            continue;
        }
        if !(name.ends_with(".zip")||name.contains(".zip.partial")){continue;}
        let hex=name.split('.').next().unwrap_or("");
        if hex.len()!=64||!hex.bytes().all(|b|b.is_ascii_hexdigit()){continue;}
        let _=fs::remove_file(entry.path());
    }
}

/// On exit: stop what is downloading so its files are released, then clear the cache.
pub(crate) fn discard_pending_downloads(state:&InstallState){
    if let Ok(jobs)=state.active.lock(){
        for token in jobs.values(){token.store(true,Ordering::Relaxed);}
    }
    // A cancelled transfer notices within one chunk read; whatever it still holds goes next start.
    std::thread::sleep(Duration::from_millis(400));
    if let Some(local_data)=std::env::var_os("LOCALAPPDATA"){sweep_download_cache(Path::new(&local_data));}
}

/// Downloads kept only for this game; without this the disk would barely free up.
pub(crate) fn remove_cached_archives(id:&str){
    let (Ok(manifest),Ok((_,local_data)))=(read_manifest(id),roots()) else {return};
    let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
    for sha in manifest.archives.iter().map(|part|&part.sha256).chain(manifest.extra_files.iter().map(|part|&part.sha256)){
        let _=fs::remove_file(cache.join(format!("{}.zip",sha.to_ascii_lowercase())));
    }
}

#[tauri::command]
pub fn cancel_standalone_install(id: String, state: State<'_, InstallState>) -> Result<bool, String> {
    let jobs = state.active.lock().map_err(|_| "Motor de instalación ocupado")?;
    if let Some(token) = jobs.get(&id) {
        token.store(true, Ordering::Relaxed);
        Ok(true)
    } else { Ok(false) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn python314_streamed_zstandard_zip_uses_the_native_installer(){
        let root=temp_root("python314-zstd");
        let archive=root.join("stream.zip");
        fs::write(&archive,include_bytes!("../../../tests/fixtures/python314-zstd-stream.zip")).unwrap();
        let token=AtomicBool::new(false);
        let expanded=inspect_all_archives(&[archive.clone()],&token).unwrap();
        assert_eq!(expanded,1024);
        let stage=root.join("stage");fs::create_dir(&stage).unwrap();
        extract_archives_with_progress(&[archive],&stage,expanded,&token,"extracting",|_,_,_,_|{}).unwrap();
        assert_eq!(fs::read(stage.join("probe.bin")).unwrap(),(0..1024).map(|i|(i%256) as u8).collect::<Vec<_>>());
        let _=fs::remove_dir_all(root);
    }

    /// Opt-in host validation of real multipart assets through the production installer.
    /// Keeps the resulting installation for the host; never overwrites an existing target.
    #[test]
    #[ignore = "requires explicitly selected host package, empty destination and verified local ZIP cache"]
    fn host_package_install_smoke(){
        let id=std::env::var("COCO2_HOST_SMOKE_ID").expect("select catalog id");
        let target=PathBuf::from(std::env::var_os("COCO2_HOST_SMOKE_TARGET").expect("select destination"));
        let cache=PathBuf::from(std::env::var_os("COCO2_HOST_SMOKE_CACHE").expect("select cache"));
        assert!(target.is_absolute()&&cache.is_absolute()&&!target.exists());
        assert_no_links(&target).unwrap();assert_no_links(&cache).unwrap();
        let manifest=read_manifest(&id).unwrap();
        for source in expected_zip_sources(&manifest){
            let path=cache.join(format!("{}.zip",source.sha256));
            assert!(path.is_file(),"prepopulate every ZIP: {}",path.display());
            assert_eq!(fs::metadata(&path).unwrap().len(),source.size);
        }
        let result=install_new(&manifest,&target,&cache,&AtomicBool::new(false),|phase,file,done,total|{
            if done==total {println!("{phase}: {file} {done}/{total}");}
        }).unwrap();
        assert_eq!(result.status,"installed");
        verify_staged_files(&target,&manifest.required_files,&AtomicBool::new(false)).unwrap();
    }

    #[test]
    fn leftover_downloads_never_outlive_the_session_but_foreign_files_stay(){
        let root=std::env::temp_dir().join(format!("coco-sweep-{}",std::process::id()));
        let cache=root.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
        fs::create_dir_all(cache.join("download-ephemeral").join(".coco2-stage-1")).unwrap();
        fs::create_dir_all(cache.join("keep-me")).unwrap();
        let sha=|c:char|c.to_string().repeat(64);
        let write=|name:String|{let path=cache.join(name);fs::write(&path,b"x").unwrap();path};
        let finished=write(format!("{}.zip",sha('a')));
        let partial=write(format!("{}.zip.partial",sha('c')));
        let checkpoint=write(format!("{}.zip.partial.v11..coco2-stage-9",sha('d')));
        let foreign=write("notes.zip".into());
        fs::write(cache.join("download-ephemeral").join(".coco2-stage-1").join("payload.partial"),b"x").unwrap();
        sweep_download_cache(&root);
        assert!(!finished.exists()&&!partial.exists()&&!checkpoint.exists());
        assert!(!cache.join("download-ephemeral").exists());
        assert!(foreign.exists()&&cache.join("keep-me").exists());
        let _=fs::remove_dir_all(&root);
    }

    #[test]
    fn split_part_assembly_disk_preflight_counts_transient_second_copy(){
        let root=temp_root("split-space-v14-漢字");
        let archive_a=root.join("split-a.zip");
        let archive_b=root.join("split-b.zip");
        let left=vec![0x18u8;128*1024+3];
        let right=vec![0x23u8;256*1024+7];
        make_zip(&archive_a,&[
            ("assets/film 漢字.bin.part1",&left),
            ("assets/note.txt",b"not split"),
        ]);
        make_zip(&archive_b,&[("assets/film 漢字.bin.part2",&right)]);
        let paths=vec![archive_a,archive_b];
        let token=AtomicBool::new(false);
        let expanded=inspect_all_archives(&paths,&token).unwrap();
        assert_eq!(expanded,left.len() as u64+right.len() as u64+9);
        let scratch=split_reassembly_scratch_bytes(&paths,&token).unwrap();
        assert_eq!(scratch,(left.len()+right.len()) as u64);
        let required=required_extraction_space(&paths,expanded,&token).unwrap();
        assert_eq!(required,expanded+scratch);
        assert!(required>expanded,"old preflight undercounted this exact scratch size");
        let stage=create_stage(&root.join("new-instance")).unwrap();
        extract_archives_with_progress(&paths,&stage.0,expanded,&token,"extracting",|_,_,_,_|{}).unwrap();
        reassemble_splits(&stage.0,&token).unwrap();
        let assembled=stage.0.join("assets/film 漢字.bin");
        let expected=[left,right].concat();
        assert_eq!(fs::read(assembled).unwrap(),expected);
        assert!(!stage.0.join("assets/film 漢字.bin.part1").exists());
        assert!(!stage.0.join("assets/film 漢字.bin.part2").exists());
        drop(stage);
        let plain=root.join("plain.zip");
        make_zip(&plain,&[("game.exe",b"safe")]);
        assert_eq!(split_reassembly_scratch_bytes(&[plain],&token).unwrap(),0,
            "normal ZIPs must not demand 2x disk space unnecessarily");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn split_publish_foreign_collision_preserves_destination(){
        let root=temp_root("split-publish-race-v14");
        let staging=root.join("joined 漢字.coco2-assembling");
        let target=root.join("joined 漢字");
        let user=root.join("saves/world/player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();
        fs::write(&user,b"world-owned-by-user").unwrap();
        fs::write(&staging,b"verified-joined-content").unwrap();
        fs::write(&target,b"foreign-file-created-after-preflight").unwrap();
        let err=publish_reassembled_file(&staging,&target).unwrap_err();
        assert!(err.contains("sin sobrescribir"),"{err}");
        assert_eq!(fs::read(&staging).unwrap(),b"verified-joined-content");
        assert_eq!(fs::read(&target).unwrap(),b"foreign-file-created-after-preflight");
        assert_eq!(fs::read(&user).unwrap(),b"world-owned-by-user");
        // Only this test owns the foreign-file fixture; remove it explicitly
        // to verify the create-new success path without touching real assets.
        fs::remove_file(&target).unwrap();
        publish_reassembled_file(&staging,&target).unwrap();
        assert!(!staging.exists());
        assert_eq!(fs::read(&target).unwrap(),b"verified-joined-content");
        assert_eq!(fs::read(&user).unwrap(),b"world-owned-by-user");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn redirect_policy_blocks_untrusted_http_before_following_location(){
        use std::net::TcpListener;
        use std::thread;
        let first=TcpListener::bind("127.0.0.1:0").unwrap();
        let untrusted=TcpListener::bind("127.0.0.1:0").unwrap();
        untrusted.set_nonblocking(true).unwrap();
        let target_port=untrusted.local_addr().unwrap().port();
        let from=format!("http://127.0.0.1:{}/source",first.local_addr().unwrap().port());
        let server=thread::spawn(move||{
            let (mut socket,_)=first.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let mut headers=Vec::new();
            while !headers.windows(4).any(|part|part==b"\r\n\r\n"){
                let mut buf=[0u8;512];
                let n=socket.read(&mut buf).unwrap();
                assert!(n>0&&headers.len()<8192);
                headers.extend_from_slice(&buf[..n]);
            }
            let location=format!("http://localhost:{target_port}/bad-redirect");
            socket.write_all(format!(
                "HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            ).as_bytes()).unwrap();
        });
        let client=reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(3))
            .redirect(safe_archive_redirect()).build().unwrap();
        let response=client.get(from).send().unwrap();
        assert_eq!(response.status(),reqwest::StatusCode::FOUND,
            "redirect must stop before an untrusted plaintext HTTP request");
        server.join().unwrap();
        assert!(untrusted.accept().is_err(),
            "redirect destination was NOT contacted even once");
        // An explicitly recognized loopback fixture may still redirect on
        // localhost during tests. Production never permits plaintext HTTP.
        let accepted=TcpListener::bind("127.0.0.1:0").unwrap();
        let address=accepted.local_addr().unwrap();
        let server=thread::spawn(move||{
            for index in 0..2 {
                let (mut stream,_)=accepted.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut headers=Vec::new();
                while !headers.windows(4).any(|p|p==b"\r\n\r\n"){
                    let mut part=[0u8;1024];
                    let n=stream.read(&mut part).unwrap();
                    assert!(n>0&&headers.len()<8192);
                    headers.extend_from_slice(&part[..n]);
                }
                if index==0 {
                    stream.write_all(b"HTTP/1.1 302 Found\r\nLocation: /verified\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                }else{
                    stream.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\nContent-Range: bytes 0-2/3\r\nConnection: close\r\n\r\nabc").unwrap();
                }
            }
        });
        let client=reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(3))
            .redirect(safe_archive_redirect()).build().unwrap();
        let response=client.get(format!("http://127.0.0.1:{}/start",address.port()))
            .header(reqwest::header::RANGE,"bytes=0-2").send().unwrap();
        assert_eq!(response.status(),reqwest::StatusCode::PARTIAL_CONTENT);
        assert_eq!(response.bytes().unwrap().as_ref(),b"abc");
        server.join().unwrap();
    }

    /// Real local HTTP, no internet or game process. Every accepted request
    /// contains an explicit bounded Range. The server can emulate a mirror
    /// rejecting only resumed offsets or a broken mirror rejecting all Range.
    fn local_range_server_v13(bytes:Vec<u8>,mode:&'static str)
        ->(String,Arc<AtomicBool>,std::thread::JoinHandle<Vec<u64>>){
        use std::net::TcpListener;
        use std::thread;
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port=listener.local_addr().unwrap().port();
        let shutdown=Arc::new(AtomicBool::new(false));
        let done=Arc::clone(&shutdown);
        let handle=thread::spawn(move||{
            let mut starts=Vec::new();
            while !done.load(Ordering::Relaxed){
                let (mut stream,_)=match listener.accept(){
                    Ok(pair)=>pair,
                    Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>{
                        thread::sleep(Duration::from_millis(5));continue;
                    },
                    Err(e)=>panic!("loopback accept failed: {e}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                let mut headers=Vec::new();
                while !headers.windows(4).any(|chunk|chunk==b"\r\n\r\n"){
                    let mut buf=[0u8;1024];
                    let n=stream.read(&mut buf).unwrap();
                    assert!(n>0&&headers.len()<8192);
                    headers.extend_from_slice(&buf[..n]);
                }
                let request=String::from_utf8(headers).unwrap();
                let range=request.lines().filter_map(|line|line.split_once(':'))
                    .find(|(name,_)|name.eq_ignore_ascii_case("Range"))
                    .map(|(_,value)|value.trim()).unwrap();
                let (first,last)=range.strip_prefix("bytes=").unwrap().split_once('-').unwrap();
                let start=first.parse::<u64>().unwrap();
                let end=last.parse::<u64>().unwrap();
                starts.push(start);
                if mode=="always-416"
                    ||(start>0&&mode=="reject-resume"&&starts.len()==1)
                    ||(start>0&&mode=="late-416"&&starts.len()==2)
                    ||(start>0&&mode=="repeated-late-416"){
                    let response="HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    stream.write_all(response.as_bytes()).unwrap();
                    continue;
                }
                if mode=="ignore-resume"&&start>0&&starts.len()==1{
                    let response=format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",bytes.len());
                    stream.write_all(response.as_bytes()).unwrap();
                    // The safe client rejects this 200 and closes immediately.
                    // A broken pipe on this local test server is expected.
                    let _=stream.write_all(&bytes);
                    continue;
                }
                // Some CDN gateways cap individual 206 spans below the
                // requested Range. They still return valid partial responses
                // and expect clients to advance from the delivered boundary.
                // A different adversarial mode deliberately exceeds the
                // requested end and must never be accepted.
                let end=if mode=="capped-206-v21" {
                    end.min(start.saturating_add(8191))
                }else if mode=="overlong-206-v21" {
                    end.saturating_add(1).min(bytes.len() as u64-1)
                }else{end}.min(bytes.len() as u64-1);
                let mut body=bytes[start as usize..=end as usize].to_vec();
                if (mode=="poison-first-pass"&&starts.len()==1) ||
                    mode=="poison-always" {
                    body[0]^=0x5a;
                }
                let validator=if mode=="uncommitted-etag-then-rotate-v25" {
                    // First 206 has an ETag but transmits NO payload. The
                    // second and third are the first confirmed generation;
                    // the fourth switches once after durable checkpoints.
                    if starts.len()==1 {"v25-discarded"}
                    else if starts.len()<=3 {"v25-first"}
                    else {"v25-second"}
                }else if mode=="etag-rotate-once" {
                    if starts.len()==1 {"v16-old"}else{"v16-new"}
                }else if mode=="etag-flapping" {
                    if start==0 {"v16-old"}else{"v16-new"}
                }else{"v13-stable"};
                let content_encoding=if mode=="duplicate-encoding-v27" {
                    // A gateway may emit multiple field lines. Checking only
                    // HeaderMap::get first misses the second encoded layer.
                    "Content-Encoding: identity\r\nContent-Encoding: gzip\r\n"
                }else{""};
                let response=format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{}\r\nContent-Length: {}\r\n{content_encoding}ETag: \"{validator}\"\r\nConnection: close\r\n\r\n",bytes.len(),body.len());
                stream.write_all(response.as_bytes()).unwrap();
                if mode=="uncommitted-etag-then-rotate-v25"&&starts.len()==1 {
                    // Truncated 206: Content-Length promises the range, but
                    // zero bytes reach the downloader before TCP EOF.
                }else if mode=="always-short"{
                    stream.write_all(&body[..1]).unwrap();
                }else if mode=="short-then-full"&&starts.len()<=6{
                    // A real origin may close after making useful forward
                    // progress repeatedly; its Content-Length still promised
                    // the entire requested Range.
                    stream.write_all(&body[..body.len().min(8192)]).unwrap();
                }else if mode=="reset-once"&&starts.len()==1{
                    stream.write_all(&body[..body.len()/2]).unwrap();
                }else{
                    stream.write_all(&body).unwrap();
                }
            }
            starts
        });
        (format!("http://127.0.0.1:{port}/v13-archive.zip"),shutdown,handle)
    }

    #[test]
    fn capped_206_ranges_advance_actual_bytes_and_reconstruct_full_sha_v21(){
        let root=temp_root("capped-http-206-v21-漢字");
        let cache=root.join("caché");
        let user=root.join("saves/world/player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();
        fs::write(&user,b"immutable-user-save").unwrap();
        let data=(0..93_017usize).map(|i|(i%251) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data.clone(),"capped-206-v21");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&data)),
            size:data.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let downloaded=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        let path=downloaded.expect("a valid 206 capped below requested end should resume");
        assert_eq!(fs::read(path).unwrap(),data,"full SHA-256 protects every bounded 206 segment");
        assert_eq!(&starts[..4],&[0,8192,16384,24576],
            "client must request from the actual returned end, not the requested end");
        assert_eq!(fs::read(user).unwrap(),b"immutable-user-save");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn overlong_206_range_must_fail_closed_without_partial_or_archive_v21(){
        let root=temp_root("overlong-http-206-v21");
        let cache=root.join("cache");
        let data=(0..98_101usize).map(|i|(i%233) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data,"overlong-206-v21");
        let spec=ArchiveSpec{url,sha256:"a".repeat(64),size:98_101};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert!(result.unwrap_err().contains("rango"),
            "server bytes beyond requested Range are not permitted");
        assert_eq!(starts,&[0],"do not fetch more bytes after invalid Content-Range");
        assert!(!cache.join(format!("{}.zip",spec.sha256)).exists());
        assert!(!cache.join(format!("{}.zip.partial",spec.sha256)).exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn etag_rotation_mid_fresh_download_restarts_once_without_publishing_mixed_mirrors_v16(){
        let root=temp_root("etag-rotate-v16-漢字");
        let cache=root.join("caché");
        let data=(0..82_007usize).map(|index|(index%233) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data.clone(),"etag-rotate-once");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&data)),
            size:data.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        let archive=result.expect("a single ETag rotation must recover with a clean private copy");
        assert_eq!(&starts[..4],&[0,32*1024,0,32*1024],
            "recovery must discard mismatched ETag bytes and retry only from offset zero");
        assert_eq!(fs::read(archive).unwrap(),data);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn uncommitted_http_etag_does_not_exhaust_single_real_rotation_v25(){
        let root=temp_root("etag-truncated-then-rotate-v25-漢字");
        let cache=root.join("caché");
        let save=root.join("saves/世界/player.dat");
        fs::create_dir_all(save.parent().unwrap()).unwrap();
        fs::write(&save,b"user save is immutable").unwrap();
        let data=(0..95_003usize).map(|n|(n%233) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data.clone(),"uncommitted-etag-then-rotate-v25");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&data)),
            size:data.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        let archive=result.unwrap_or_else(|error|panic!(
            "an ETag from a zero-byte failed 206 must not spend the only meaningful restart: {error}; starts={starts:?}"));
        assert_eq!(fs::read(&archive).unwrap(),data);
        assert_eq!(starts,&[0,0,32*1024,64*1024,0,32*1024,64*1024],
            "first short reply has no checkpoint; one subsequent valid generation switch should restart once");
        assert_eq!(fs::read(save).unwrap(),b"user save is immutable");
        assert!(!cache.join(format!("{}.zip.partial",spec.sha256)).exists(),
            "successful SHA publication must not leave an unowned partial");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn duplicate_content_encoding_does_not_publish_untrusted_206_v27(){
        let root=temp_root("duplicate-encoding-v27-漢字");
        let cache=root.join("caché");
        let user_save=root.join("saves/世界/player.dat");
        fs::create_dir_all(user_save.parent().unwrap()).unwrap();
        fs::write(&user_save,b"never overwrite playerdata").unwrap();
        let bytes=(0..16_137usize).map(|n|(n%251) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(bytes.clone(),"duplicate-encoding-v27");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&bytes)),
            size:bytes.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let requests=server.join().unwrap();
        assert!(result.as_ref().is_err_and(|e|e.contains("comprimió")),
            "duplicate Content-Encoding must be rejected before publication: {result:?}");
        assert_eq!(requests,&[0],"reject encoded Range before any retry or bytes");
        assert!(!cache.join(format!("{}.zip",spec.sha256)).exists(),
            "even matching source SHA cannot authorize contradicting HTTP encoding metadata");
        assert_eq!(fs::read(user_save).unwrap(),b"never overwrite playerdata");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persistently_flapping_etag_fails_bounded_with_checkpoint_preserved_v16(){
        let root=temp_root("etag-flapping-v16");
        let cache=root.join("caché");
        let data=(0..78_011usize).map(|index|(index%223) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data.clone(),"etag-flapping");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&data)),
            size:data.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert!(result.is_err(),"ETag that changes every second Range cannot publish");
        assert_eq!(starts,&[0,32*1024,0,32*1024],
            "one and only one clean restart is allowed for oscillating ETags");
        assert!(!cache.join(format!("{}.zip",spec.sha256)).exists());
        let partial=cache.join(format!("{}.zip.partial",spec.sha256));
        assert_eq!(fs::read(partial).unwrap(),data[..32*1024],
            "checkpoint must record only actual prefix; final SHA remains mandatory");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn first_fresh_mirror_full_sha_poison_recovers_without_user_retry_v16(){
        let root=temp_root("poison-first-pass-v16");
        let cache=root.join("cache");
        let user=root.join("saves/único/player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();
        fs::write(&user,b"saved-user-file").unwrap();
        let data=(0..16_019usize).map(|index|(index%211) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data.clone(),"poison-first-pass");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&data)),
            size:data.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert_eq!(starts,&[0,0],
            "untrusted first full body must be redownloaded once before publication");
        assert_eq!(fs::read(result.expect("fresh poison must recover only after clean SHA")).unwrap(),data);
        assert_eq!(fs::read(user).unwrap(),b"saved-user-file");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn repeated_fresh_mirror_full_sha_poison_refuses_publish_v16(){
        let root=temp_root("poison-always-v16");
        let cache=root.join("cache");
        let data=(0..16_123usize).map(|index|(index%197) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(data.clone(),"poison-always");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&data)),
            size:data.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert!(result.is_err(),"permanently poisoned mirror must fail closed");
        assert_eq!(starts,&[0,0],"do not loop indefinitely on full SHA-256 mismatch");
        assert!(!cache.join(format!("{}.zip",spec.sha256)).exists());
        let partial=cache.join(format!("{}.zip.partial",spec.sha256));
        assert_eq!(fs::metadata(partial).unwrap().len(),spec.size);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn mid_transfer_416_once_restarts_private_copy_even_without_legacy_partial_v15(){
        let root=temp_root("late-416-after-valid-206-v15-漢字");
        let cache=root.join("caché");
        let user_save=root.join("saves/world/player.dat");
        fs::create_dir_all(user_save.parent().unwrap()).unwrap();
        fs::write(&user_save,b"user-owned-save-do-not-change").unwrap();
        let bytes=(0..112_003usize).map(|n|(n%251) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(bytes.clone(),"late-416");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&bytes)),
            size:bytes.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        let archive=result.expect("fresh download should recover a one-time 416 after progress");
        assert_eq!(&starts[..3],&[0,32*1024,0],
            "416 after one successful chunk requires exactly one restart from zero");
        assert_eq!(fs::read(archive).unwrap(),bytes);
        assert_eq!(fs::read(user_save).unwrap(),b"user-owned-save-do-not-change");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persistent_mid_transfer_416_fails_bounded_and_preserves_partial_v15(){
        let root=temp_root("persistent-late-416-v15");
        let bytes=(0..100_000usize).map(|n|(n%233) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(bytes.clone(),"repeated-late-416");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&bytes)),
            size:bytes.len() as u64};
        let cache=root.join("cache");
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert!(result.is_err(),"persistent invalid ranges must never publish");
        assert_eq!(starts,&[0,32*1024,0,32*1024],
            "only ONE clean restart may be attempted");
        assert!(!cache.join(format!("{}.zip",spec.sha256)).exists());
        let saved=cache.join(format!("{}.zip.partial",spec.sha256));
        assert_eq!(fs::read(saved).unwrap(),bytes[..32*1024],
            "save only known forward bytes for a future SHA-checked retry");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn repeated_short_range_bodies_with_progress_resume_to_sha_v15(){
        let root=temp_root("repeated-truncation-v15");
        let cache=root.join("cache");
        let bytes=(0..121_003usize).map(|n|(n%223) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(bytes.clone(),"short-then-full");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&bytes)),
            size:bytes.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert_eq!(fs::read(result.expect("repeated byte-progress should recover")).unwrap(),bytes);
        assert_eq!(&starts[..7],&[0,8192,16384,24576,32768,40960,49152],
            "short-bodied connections must continue from the durable byte offset");
        assert!(!cache.join(format!("{}.zip.partial",spec.sha256)).exists(),
            "successful SHA-backed publication must not claim an unfinished checkpoint");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn one_byte_range_trickles_are_bounded_and_preserved_for_later_recovery_v15(){
        let root=temp_root("bounded-drip-v15");
        let cache=root.join("cache");
        let bytes=(0..100_003usize).map(|n|(n%213) as u8).collect::<Vec<_>>();
        let (url,stop,server)=local_range_server_v13(bytes.clone(),"always-short");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&bytes)),
            size:bytes.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4))
            .redirect(safe_archive_redirect()).build().unwrap();
        let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
        stop.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        let error=result.unwrap_err();
        assert!(error.contains("progreso repetidamente"),"{error}");
        assert_eq!(starts.len(),HTTP_ADVANCING_TRUNCATIONS,
            "one-byte-per-connection origin must not hold the worker forever");
        assert_eq!(starts, (0..HTTP_ADVANCING_TRUNCATIONS as u64).collect::<Vec<_>>());
        assert!(!cache.join(format!("{}.zip",spec.sha256)).exists());
        let checkpoint=cache.join(format!("{}.zip.partial",spec.sha256));
        assert_eq!(fs::read(checkpoint).unwrap(),bytes[..HTTP_ADVANCING_TRUNCATIONS],
            "only actual bytes may survive as a SHA-gated immutable checkpoint");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size(){
        let root=temp_root("crash-orphan-v13-漢字");
        let cache=root.join("caché 漢字");
        fs::create_dir_all(&cache).unwrap();
        let bytes=(0..103_007usize).map(|n|(n%233) as u8).collect::<Vec<_>>();
        let hash=format!("{:x}",Sha256::digest(&bytes));
        let spec=ArchiveSpec{url:String::new(),sha256:hash.clone(),size:bytes.len() as u64};
        let orphan=create_stage(&cache.join("download-ephemeral")).unwrap();
        mark_download_stage(&orphan.0,&hash,spec.size).unwrap();
        let orphan_path=orphan.0.join("payload.partial");
        fs::write(&orphan_path,&bytes[..32*1024]).unwrap();
        // The real crash bypasses both PartialResumeGuard and StageGuard Drop.
        std::mem::forget(orphan);
        let unrelated=create_stage(&cache.join("download-ephemeral")).unwrap();
        mark_download_stage(&unrelated.0,&"f".repeat(64),spec.size).unwrap();
        let unrelated_path=unrelated.0.join("payload.partial");
        fs::write(&unrelated_path,vec![4u8;64*1024]).unwrap();
        std::mem::forget(unrelated);
        assert_eq!(resumable_checkpoint(&cache,&hash,spec.size,&AtomicBool::new(false))
            .unwrap().unwrap().0,orphan_path);
        let (url,shutdown,server)=local_range_server_v13(bytes.clone(),"normal");
        let spec=ArchiveSpec{url,..spec};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4)).build().unwrap();
        let downloaded=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{}).unwrap();
        shutdown.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert_eq!(starts.first(),Some(&(32*1024)),"orphan crash bytes must be reused as Range offset");
        assert_eq!(fs::read(downloaded).unwrap(),bytes);
        assert_eq!(fs::read(orphan_path).unwrap(),bytes[..32*1024]);
        assert_eq!(fs::read(unrelated_path).unwrap(),vec![4u8;64*1024]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejected_resume_range_416_and_200_restart_once_without_touching_partial(){
        let root=temp_root("rejected-range-v13");
        let bytes=(0..90_003usize).map(|n|(n%239) as u8).collect::<Vec<_>>();
        let sha256=format!("{:x}",Sha256::digest(&bytes));
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4)).build().unwrap();
        for mode in ["reject-resume","ignore-resume","always-416"] {
            let cache=root.join(mode);
            fs::create_dir_all(&cache).unwrap();
            let partial=cache.join(format!("{sha256}.zip.partial"));
            fs::write(&partial,&bytes[..32*1024]).unwrap();
            let (url,shutdown,server)=local_range_server_v13(bytes.clone(),mode);
            let spec=ArchiveSpec{url,sha256:sha256.clone(),size:bytes.len() as u64};
            let result=download_one(&spec,&cache,&client,&AtomicBool::new(false),|_|{});
            shutdown.store(true,Ordering::Relaxed);
            let starts=server.join().unwrap();
            assert_eq!(&starts[..2],&[32*1024,0],"{mode} must restart once from zero");
            assert_eq!(fs::read(&partial).unwrap(),bytes[..32*1024],
                "{mode} must preserve the original partial");
            if mode=="always-416"{
                assert!(result.is_err(),"repeated Range rejection must fail closed");
                assert_eq!(starts.len(),2,"must never retry the same rejected Range indefinitely");
                assert!(!cache.join(format!("{sha256}.zip")).exists());
            }else{
                assert_eq!(fs::read(result.unwrap()).unwrap(),bytes);
            }
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn retry_after_http_date_and_delta_seconds_are_parsed_and_bounded(){
        let now=time::OffsetDateTime::from_unix_timestamp(1_900_000_000).unwrap();
        let future=(now+time::Duration::seconds(5))
            .format(&time::format_description::well_known::Rfc2822).unwrap();
        let past=(now-time::Duration::seconds(5))
            .format(&time::format_description::well_known::Rfc2822).unwrap();
        assert_eq!(retry_after_delay_ms(1,Some(&future),now),2000);
        assert_eq!(retry_after_delay_ms(1,Some(&past),now),0);
        assert_eq!(retry_after_delay_ms(1,Some("1"),now),1000);
        assert_eq!(retry_after_delay_ms(1,Some("3600"),now),2000);
        assert_eq!(retry_after_delay_ms(2,Some("invalid-date"),now),400);
        let token=AtomicBool::new(true);
        assert_eq!(retry_http_delay(1,Some(&future),&token).unwrap_err(),"cancelled");
    }

    #[test]
    fn connection_reset_mid_chunk_resumes_at_actual_bytes_and_checks_final_sha(){
        let root=temp_root("connection-reset-v13");
        let bytes=(0..96_001usize).map(|n|(n%229) as u8).collect::<Vec<_>>();
        let (url,shutdown,server)=local_range_server_v13(bytes.clone(),"reset-once");
        let spec=ArchiveSpec{url,sha256:format!("{:x}",Sha256::digest(&bytes)),
            size:bytes.len() as u64};
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(4)).build().unwrap();
        let path=download_one(&spec,&root.join("cache"),&client,&AtomicBool::new(false),|_|{}).unwrap();
        shutdown.store(true,Ordering::Relaxed);
        let starts=server.join().unwrap();
        assert_eq!(starts.first(),Some(&0));
        assert_eq!(starts.get(1),Some(&(16*1024)),
            "restart after short HTTP body must request only missing bytes");
        assert_eq!(fs::read(path).unwrap(),bytes);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn interrupted_unicode_download_checkpoints_advance_without_touching_foreign_partial() {
        let root=temp_root("resumable-漢字 with spaces");
        let cache=root.join("caché with 漢字");
        fs::create_dir_all(&cache).unwrap();
        let bytes=(0..97u8).collect::<Vec<_>>();
        let hash=format!("{:x}",Sha256::digest(&bytes));
        let canonical=cache.join(format!("{hash}.zip.partial"));
        fs::write(&canonical,&bytes[..5]).unwrap();
        let token=AtomicBool::new(false);
        for (expected_before,after) in [(5,23),(23,61),(61,97)] {
            let (candidate,existing)=resumable_checkpoint(&cache,&hash,97,&token)
                .unwrap().unwrap();
            assert_eq!(existing,expected_before);
            let stage=create_stage(&cache.join("attempt")).unwrap();
            let work=stage.0.join("payload.partial");
            fs::copy(&candidate,&work).unwrap();
            let checkpoint=cache.join(format!("{hash}.zip.partial.v11.{}",
                stage.0.file_name().unwrap().to_string_lossy()));
            let guard=PartialResumeGuard{work:work.clone(),canonical:canonical.clone(),
                checkpoint,previous_len:existing,complete:false};
            OpenOptions::new().append(true).open(&work).unwrap()
                .write_all(&bytes[existing as usize..after]).unwrap();
            drop(guard);drop(stage);
            assert_eq!(fs::read(&canonical).unwrap(),bytes[..5],
                "resuming must never mutate or replace preexisting partial");
            assert_eq!(resumable_checkpoint(&cache,&hash,97,&token).unwrap().unwrap().1,after as u64);
        }
        // A process can publish an already finished checkpoint, even after the
        // original source vanishes; immutable SHA validation still gates it.
        let spec=ArchiveSpec{url:"file:///nonexistent.zip".into(),size:97,sha256:hash.clone()};
        let client=reqwest::blocking::Client::builder().build().unwrap();
        let final_path=download_one(&spec,&cache,&client,&token,|_|{}).unwrap();
        assert_eq!(fs::read(final_path).unwrap(),bytes);
        assert_eq!(fs::read(&canonical).unwrap(),bytes[..5]);
        let alternate=root.join("completed-foreign");
        fs::create_dir(&alternate).unwrap();
        let bad_full=alternate.join(format!("{hash}.zip.partial"));
        fs::write(&bad_full,vec![255u8;97]).unwrap();
        let good_checkpoint=alternate.join(format!("{hash}.zip.partial.v11.verified"));
        fs::write(&good_checkpoint,&bytes).unwrap();
        assert_eq!(resumable_checkpoint(&alternate,&hash,97,&token).unwrap().unwrap().0,
            good_checkpoint);
        assert_eq!(fs::read(download_one(&spec,&alternate,&client,&token,|_|{}).unwrap()).unwrap(),
            bytes,"valid completed checkpoint must beat a corrupt full canonical partial");
        assert_eq!(fs::read(bad_full).unwrap(),vec![255u8;97]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn transient_http_503_and_429_retry_with_bounded_ranges_and_verified_sha() {
        use std::net::TcpListener;
        use std::thread;
        let root=temp_root("http-transient-漢字");
        let bytes=(0..108_000usize).map(|n|(n%241) as u8).collect::<Vec<_>>();
        let server=TcpListener::bind("127.0.0.1:0").unwrap();
        server.set_nonblocking(true).unwrap();
        let port=server.local_addr().unwrap().port();
        let done=Arc::new(AtomicBool::new(false));
        let closing=Arc::clone(&done);
        let served=thread::spawn(move||{
            let mut starts=Vec::new();
            while !closing.load(Ordering::Relaxed){
                let (mut stream,_)=match server.accept(){
                    Ok(pair)=>pair,
                    Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>{
                        thread::sleep(Duration::from_millis(5));continue;
                    },
                    Err(e)=>panic!("local test accept failed: {e}"),
                };
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut header=Vec::new();
                while !header.windows(4).any(|part|part==b"\r\n\r\n"){
                    let mut buf=[0u8;1024];
                    let n=stream.read(&mut buf).unwrap();
                    assert!(n>0 && header.len()<8192);
                    header.extend_from_slice(&buf[..n]);
                }
                let request=String::from_utf8(header).unwrap();
                let range=request.lines().filter_map(|line|line.split_once(':'))
                    .find(|(key,_)|key.eq_ignore_ascii_case("range"))
                    .map(|(_,value)|value.trim()).unwrap();
                let (start,end)=range.strip_prefix("bytes=").unwrap()
                    .split_once('-').unwrap();
                let start=start.parse::<usize>().unwrap();
                let end=end.parse::<usize>().unwrap();
                starts.push(start);
                if starts.len()<=2 {
                    let status=if starts.len()==1{"503 Service Unavailable"}else{"429 Too Many Requests"};
                    stream.write_all(format!(
                        "HTTP/1.1 {status}\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    ).as_bytes()).unwrap();
                } else {
                    let end=end.min(bytes.len()-1);
                    let body=&bytes[start..=end];
                    stream.write_all(format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{}\r\nContent-Length: {}\r\nETag: \"stable\"\r\nConnection: close\r\n\r\n",
                        bytes.len(),body.len(),
                    ).as_bytes()).unwrap();
                    stream.write_all(body).unwrap();
                }
            }
            starts
        });
        let client=reqwest::blocking::Client::builder().timeout(Duration::from_secs(3))
            .build().unwrap();
        let spec=ArchiveSpec{url:format!("http://127.0.0.1:{port}/fixture.zip"),
            sha256:format!("{:x}",Sha256::digest(
                &(0..108_000usize).map(|n|(n%241) as u8).collect::<Vec<_>>()
            )),size:108_000};
        let mut updates=Vec::new();
        let result=download_one(&spec,&root.join("cache"),&client,&AtomicBool::new(false),
            |bytes|updates.push(bytes)).unwrap();
        // A pre-existing prefix with the right LENGTH but wrong CONTENT used
        // to poison every reattempt. The first pass necessarily fails SHA,
        // then a private clean download can succeed without deleting it.
        let stale_cache=root.join("stale-cache-漢字");
        fs::create_dir_all(&stale_cache).unwrap();
        let stale_path=stale_cache.join(format!("{}.zip.partial",spec.sha256));
        let stale_bytes=vec![255u8;32*1024];
        fs::write(&stale_path,&stale_bytes).unwrap();
        let clean=download_one(&spec,&stale_cache,&client,&AtomicBool::new(false),|_|{}).unwrap();
        assert_eq!(fs::read(&stale_path).unwrap(),stale_bytes);
        assert_eq!(fs::read(clean).unwrap(),
            (0..108_000usize).map(|n|(n%241) as u8).collect::<Vec<_>>());
        done.store(true,Ordering::Relaxed);
        let starts=served.join().unwrap();
        assert_eq!(&starts[..3],&[0,0,0],"retryable HTTP status must not advance offset");
        assert!(starts.iter().any(|start|*start==32*1024),"bounded HTTP Range must advance");
        assert!(starts.windows(2).any(|pair|pair[0]>0&&pair[1]==0),
            "a corrupt resumed prefix must restart from byte zero exactly once");
        assert_eq!(fs::metadata(result).unwrap().len(),108_000);
        assert_eq!(updates.last(),Some(&108_000));
        assert!(updates.windows(2).all(|w|w[0]<=w[1]));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn retry_wait_is_cancelable_and_oversized_partial_fails_closed(){
        let token=AtomicBool::new(true);
        assert_eq!(retry_http_delay(1,Some("3600"),&token).unwrap_err(),"cancelled");
        assert!(retryable_http_status(429)&&retryable_http_status(503));
        assert!(!retryable_http_status(404)&&!retryable_http_status(416));
        let root=temp_root("partial-oversized");
        let hash="a".repeat(64);
        fs::write(root.join(format!("{hash}.zip.partial")),b"one byte too many").unwrap();
        let error=resumable_checkpoint(&root,&hash,1,&AtomicBool::new(false)).unwrap_err();
        assert!(error.contains("mayor al tamaño esperado"),"{error}");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved(){
        let root=temp_root("cache-winner-漢字");
        let private=root.join("private.zip");
        let archive=root.join("shared.zip");
        let data=b"identical-verified-bytes";
        fs::write(&private,data).unwrap();
        let spec=ArchiveSpec{url:"file:///not-needed".into(),size:data.len() as u64,
            sha256:format!("{:x}",Sha256::digest(data))};
        let token=AtomicBool::new(false);
        fs::write(&archive,data).unwrap();
        publish_verified_archive(&private,&archive,&spec,&token).unwrap();
        assert_eq!(fs::read(&archive).unwrap(),data);
        fs::write(&archive,b"corrupt foreign cache").unwrap();
        let error=publish_verified_archive(&private,&archive,&spec,&token).unwrap_err();
        assert!(error.contains("Conflicto"),"{error}");
        assert_eq!(fs::read(&archive).unwrap(),b"corrupt foreign cache");
        fs::remove_file(&archive).unwrap();
        publish_verified_archive(&private,&archive,&spec,&token).unwrap();
        assert!(matches_digest(&archive,spec.size,&spec.sha256,&token).unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn upgrade_plan_requires_trusted_embedded_baseline_and_blocks_downgrade(){
        let root=temp_root("upgrade-plan-authoritative");
        let target=root.join("installed");
        let old=read_embedded_manifest("big-walk").unwrap();
        let mut new=old.clone();new.version="1.0.1".into();
        fs::create_dir_all(&target).unwrap();
        write_install_receipt(&target,&old,&[]).unwrap();
        let ready=upgrade_plan(&new,&target,&root.join("cache"));
        assert_eq!(ready.status,"upgrade-ready");
        assert_eq!(ready.from_version.as_deref(),Some("1.0.0"));
        assert!(ready.needed_bytes>0);
        assert_eq!(upgrade_plan(&old,&target,&root.join("cache")).status,"already-current");
        new.version="0.9.9".into();
        assert_eq!(upgrade_plan(&new,&target,&root.join("cache")).status,"downgrade-blocked");
        new.version="1.0.1".into();
        let receipt=target.join(".coco/standalone-install-v1.json");
        let mut forged=read_owned_receipt(&target).unwrap();
        forged["requiredFiles"][0]["sha256"]=serde_json::json!("f".repeat(64));
        fs::write(&receipt,forged.to_string()).unwrap();
        assert_eq!(upgrade_plan(&new,&target,&root.join("cache")).status,"untrusted-existing");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn verified_zip_cache_is_reused_without_source_and_bad_cache_never_commits(){
        let root=temp_root("upgrade-cache-reuse");
        let zip_path=root.join("source.zip");
        make_zip(&zip_path,&[("game.exe",b"new-binary")]);
        let m=fixture_manifest(&zip_path,b"new-binary");
        fs::create_dir_all(root.join("cache")).unwrap();
        let cache=root.join("cache");
        let client=reqwest::blocking::Client::builder().build().unwrap();
        let token=AtomicBool::new(false);
        let spec=&m.archives[0];
        let once=download_one(spec,&cache,&client,&token,|_|{}).unwrap();
        assert!(matches_digest(&once,spec.size,&spec.sha256,&token).unwrap());
        fs::remove_file(&zip_path).unwrap();
        assert_eq!(download_one(spec,&cache,&client,&token,|_|{}).unwrap(),once,
            "no network or old source required for verified cache hit");
        fs::write(&once,b"wrong-cached-sha").unwrap();
        assert!(download_one(spec,&cache,&client,&token,|_|{}).is_err(),
            "invalid cache plus unavailable source fails before mutation");
        assert!(!root.join("installed").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn pinned_unicode_zip_cache_denies_concurrent_writes_rename_and_same_size_asset_spoof(){
        let root=temp_root("cache-pin-漢字 con espacios");
        let cache=root.join("caché 漢字");
        fs::create_dir_all(&cache).unwrap();
        let original=root.join("original.zip");
        let substitute=root.join("substitute.zip");
        make_zip(&original,&[("game.exe",b"pinned-exe"),("data/scene.bin",b"trusted-assets")]);
        make_zip(&substitute,&[("game.exe",b"pinned-exe"),("data/scene.bin",b"changed-assets")]);
        let m=fixture_manifest(&original,b"pinned-exe");
        assert_eq!(fs::metadata(&original).unwrap().len(),fs::metadata(&substitute).unwrap().len(),
            "adversary preserves ZIP length, game.exe and required-file hash");
        let cached=cache.join(format!("{}.zip",m.archives[0].sha256));
        fs::copy(&original,&cached).unwrap();
        let paths=vec![cached.clone()];
        let token=AtomicBool::new(false);
        let pins=pin_verified_archives(&paths,&expected_zip_sources(&m),&token).unwrap();
        assert!(OpenOptions::new().write(true).open(&cached).is_err(),
            "another process cannot mutate the verified shared ZIP");
        assert!(fs::rename(&cached,cache.join("replaced.zip")).is_err(),
            "Win32 must refuse ZIP rename/delete while a verified read handle exists");
        assert!(fs::rename(&cache,root.join("renamed-cache")).is_err(),
            "parent pin protects subsequent pathname-based extraction from junction swap");
        let expanded=inspect_all_archives(&paths,&token).unwrap();
        let stage=create_stage(&root.join("instance")).unwrap();
        extract_archives_with_progress(&paths,&stage.0,expanded,&token,
            "extracting",|_,_,_,_|{}).unwrap();
        assert_eq!(fs::read(stage.0.join("data/scene.bin")).unwrap(),b"trusted-assets");
        drop(stage);
        drop(pins);
        // A later same-length ZIP retaining the pinned EXE but modifying an
        // unlisted asset must fail the full ZIP hash BEFORE live commit.
        fs::copy(&substitute,&cached).unwrap();
        let error=pin_verified_archives(&paths,&expected_zip_sources(&m),&token).err()
            .expect("tampered ZIP must not become a trusted install source");
        assert!(error.contains("ZIP de caché cambió tras SHA-256"),"{error}");
        assert!(!root.join("instance").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn extraction_progress_counts_real_uncompressed_bytes_and_can_cancel_in_single_file(){
        let root=temp_root("extract-real-progress-漢字");
        let archive=root.join("uncompressed large Unicode.zip");
        let large=vec![0x5au8; 2*1024*1024+73];
        make_zip(&archive,&[("game.exe",b"small"),("assets/largo 漢字.bin",&large)]);
        let paths=vec![archive];
        let token=AtomicBool::new(false);
        let expected=inspect_all_archives(&paths,&token).unwrap();
        assert_eq!(expected,large.len() as u64+5);
        let stage=create_stage(&root.join("target")).unwrap();
        let mut updates=Vec::new();
        extract_archives_with_progress(&paths,&stage.0,expected,&token,
            "extracting",|phase,file,done,total|{
                assert_eq!(phase,"extracting");
                assert_eq!(total,expected);
                updates.push((file.to_owned(),done));
            }).unwrap();
        assert_eq!(updates.first().unwrap().1,0);
        assert_eq!(updates.last().unwrap().1,expected);
        assert!(updates.iter().any(|(file,done)|
            file=="assets/largo 漢字.bin" && *done>0 && *done<expected),
            "one large ZIP must report intermediate real-byte extraction, not 0/1 archive index");
        assert!(updates.windows(2).all(|pair|pair[0].1<=pair[1].1),
            "progress cannot go backwards while extracting");
        assert_eq!(fs::read(stage.0.join("assets/largo 漢字.bin")).unwrap(),large);
        drop(stage);
        let stopped=AtomicBool::new(false);
        let canceled_stage=create_stage(&root.join("cancel-target")).unwrap();
        let failed=extract_archives_with_progress(&paths,&canceled_stage.0,expected,&stopped,
            "repair-extracting",|_,_,done,_|{
                if done>0 {stopped.store(true,Ordering::Relaxed);}
            });
        assert_eq!(failed.unwrap_err(),"cancelled",
            "user cancellation during a large single ZIP must stop before publication");
        drop(canceled_stage);
        assert!(!root.join("target").exists());
        assert!(!root.join("cancel-target").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn trusted_old_executable_can_launch_only_with_pinned_baseline_sha(){
        let root=temp_root("upgrade-old-launch");
        let archive=root.join("old.zip");make_zip(&archive,&[("game.exe",b"A-game")]);
        let mut old=fixture_manifest(&archive,b"A-game");old.version="1.0.0".into();
        let mut latest=old.clone();latest.version="1.0.1".into();
        latest.required_files[0].sha256=format!("{:x}",Sha256::digest(b"B-game"));
        let target=root.join("installed");
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("game.exe"),b"A-game").unwrap();
        write_install_receipt(&target,&old,&[]).unwrap();
        let mut entry=crate::services::catalog::read_catalog().unwrap().remove(0);
        entry.id=old.id.clone();entry.instance_id=old.instance_id.clone();
        entry.workflow="coco-standalone".into();entry.hosting_mode="p2p".into();
        entry.executable="game.exe".into();entry.launch_arguments.clear();
        let fallback=trusted_launch_from_baseline(&entry,&latest,&old,&target).unwrap();
        assert_eq!(fallback.executable,"game.exe");
        assert_eq!(fallback.required_files[0].sha256,old.required_files[0].sha256);
        assert!(matches_digest(&target.join(&fallback.executable),fallback.required_files[0].size,
            &fallback.required_files[0].sha256,&AtomicBool::new(false)).unwrap());
        entry.launch_arguments.push("--untrusted-B-argument".into());
        assert!(trusted_launch_from_baseline(&entry,&latest,&old,&target).is_err());
        fs::write(target.join("game.exe"),b"modified-by-user").unwrap();
        assert!(!matches_digest(&target.join(&fallback.executable),fallback.required_files[0].size,
            &fallback.required_files[0].sha256,&AtomicBool::new(false)).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
    use zip::write::SimpleFileOptions;

    fn temp_root(label: &str) -> PathBuf {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let root = std::env::temp_dir().join(format!("coco2-install-{label}-{}-{nanos}", std::process::id()));
        fs::create_dir(&root).unwrap();
        root
    }

    fn make_zip(path: &Path, entries: &[(&str, &[u8])]) {
        let file = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        for (name, bytes) in entries {
            zip.start_file(*name, SimpleFileOptions::default()).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap();
    }

    fn fixture_manifest(archive: &Path, game: &[u8]) -> Manifest {
        let (size, sha256) = file_digest(archive, &AtomicBool::new(false)).unwrap();
        Manifest {
            id: "fixture-game".into(), instance_id: "fixture-game".into(),
            workflow: "coco-standalone".into(), version: "1".into(),
            archives: vec![ArchiveSpec { url: reqwest::Url::from_file_path(archive).unwrap().to_string(), sha256, size }],
            required_files: vec![FileSpec { path: "game.exe".into(), size: game.len() as u64,
                sha256: format!("{:x}", Sha256::digest(game)) }],
            executable: "game.exe".into(), files: Vec::new(), extras: Vec::new(), extra_files: Vec::new(), has_extras: false,
        }
    }

    #[test]
    fn unsafe_paths_and_duplicate_case_are_rejected() {
        for bad in ["../outside", "C:/evil.exe", "con.txt", "foo/./bar", "saves/a", "foo\\playerdata\\x", "bad:ads", "name.", "a//b", "a/<b>"] {
            assert!(normal_path(bad).is_err(), "accepted {bad}");
        }
        let root = temp_root("zip-unsafe");
        let zip_path = root.join("bad.zip");
        make_zip(&zip_path, &[("Game.exe", b"one"), ("game.EXE", b"two")]);
        let mut zip = zip::ZipArchive::new(File::open(&zip_path).unwrap()).unwrap();
        assert!(inspect_zip(&mut zip).is_err());
        drop(zip);
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn v30_windows_distinct_kelvin_and_ascii_zip_entries_install_without_false_case_collision(){
        let root=temp_root("v30-ntfs-distinct-K-漢字");
        let probe=root.join("probe");
        fs::create_dir(&probe).unwrap();
        fs::write(probe.join("K.bin"),b"ascii").unwrap();
        let separate=OpenOptions::new().write(true).create_new(true)
            .open(probe.join("K.bin"));
        assert!(separate.is_ok(),"Windows permits Kelvin sign and ASCII K as distinct file names");
        separate.unwrap().write_all(b"kelvin").unwrap();
        assert_eq!(fs::read(probe.join("K.bin")).unwrap(),b"ascii");
        assert_eq!(fs::read(probe.join("K.bin")).unwrap(),b"kelvin");
        let archive=root.join("release.zip");
        make_zip(&archive,&[("assets/K.bin",b"ascii-asset"),("assets/K.bin",b"kelvin-asset"),
            ("game.exe",b"safe-game")]);
        let mut zip=zip::ZipArchive::new(File::open(&archive).unwrap()).unwrap();
        assert_eq!(inspect_zip(&mut zip).unwrap().len(),3,
            "different real Win32 files must not be rejected by Unicode-to-lowercase preflight");
        drop(zip);
        let token=AtomicBool::new(false);
        let expanded=inspect_all_archives(&[archive.clone()],&token).unwrap();
        let stage=create_stage(&root.join("target")).unwrap();
        extract_archives_with_progress(&[archive],&stage.0,expanded,&token,
            "extracting",|_,_,_,_|{}).unwrap();
        assert_eq!(fs::read(stage.0.join("assets/K.bin")).unwrap(),b"ascii-asset");
        assert_eq!(fs::read(stage.0.join("assets/K.bin")).unwrap(),b"kelvin-asset");
        drop(stage);
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn v30_unicode_case_split_chunks_reassemble_to_sha_pinned_executable(){
        let root=temp_root("v30-unicode-split-É-é-漢字");
        let archive=root.join("split.zip");
        make_zip(&archive,&[("gameÉ.exe.part1",b"byte-one-"),
            ("gameé.exe.part2",b"byte-two")]);
        let token=AtomicBool::new(false);
        let size=inspect_all_archives(&[archive.clone()],&token).unwrap();
        let scratch=split_reassembly_scratch_bytes(&[archive.clone()],&token).unwrap();
        assert_eq!(size,17);
        assert_eq!(scratch,17,"both split parts refer to the same Windows case-insensitive basename");
        let stage=create_stage(&root.join("new-game")).unwrap();
        extract_archives_with_progress(&[archive],&stage.0,size,&token,
            "extracting",|_,_,_,_|{}).unwrap();
        reassemble_splits(&stage.0,&token).unwrap();
        let assembled=stage.0.join("gameÉ.exe");
        let bytes=b"byte-one-byte-two";
        assert_eq!(fs::read(&assembled).unwrap(),bytes,
            "non-ASCII case variants must be matched under Win32 file naming rules");
        assert!(!stage.0.join("gameÉ.exe.part1").exists());
        assert!(!stage.0.join("gameé.exe.part2").exists());
        let required=vec![FileSpec{path:"gameÉ.exe".into(),size:bytes.len() as u64,
            sha256:format!("{:x}",Sha256::digest(bytes))}];
        verify_staged_files(&stage.0,&required,&token).unwrap();
        drop(stage);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn installs_local_fixture_atomically_and_refuses_existing_instance() {
        let root = temp_root("good");
        let zip_path = root.join("pack.zip");
        let expected = b"fixture-game-executable";
        make_zip(&zip_path, &[("game.exe", expected), ("data/content.bin", b"game-data")]);
        let m = fixture_manifest(&zip_path, expected);
        validate_manifest(&m).unwrap();
        let target = root.join("instances").join("fixture-game");
        let cache = root.join("cache");
        let token = AtomicBool::new(false);
        let first = install_new(&m, &target, &cache, &token, |_, _, _, _| {}).unwrap();
        assert_eq!(first.status, "installed");
        assert_eq!(fs::read(target.join("game.exe")).unwrap(), expected);
        let receipt: serde_json::Value = serde_json::from_slice(
            &fs::read(target.join(".coco").join("standalone-install-v1.json")).unwrap()).unwrap();
        assert_eq!(receipt["schemaVersion"], 1);
        assert_eq!(receipt["complete"], true);
        assert_eq!(receipt["id"], "fixture-game");
        assert_eq!(receipt["archiveShas"][0], m.archives[0].sha256.to_ascii_lowercase());
        assert_eq!(receipt["requiredFiles"][0]["sha256"], m.required_files[0].sha256);
        assert!(!target.join(".coco").join("standalone-state.json").exists(),
            "no falsificar el estado heredado, que necesita otros campos");
        let second = install_new(&m, &target, &cache, &token, |_, _, _, _| {}).unwrap();
        assert_eq!(second.status, "needs-repair");
        assert_eq!(fs::read(target.join("game.exe")).unwrap(), expected);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn corrupt_zip_and_cancel_leave_no_instance() {
        let root = temp_root("failure");
        let zip_path = root.join("pack.zip");
        make_zip(&zip_path, &[("game.exe", b"wrong-bytes")]);
        let m = fixture_manifest(&zip_path, b"expected-bytes");
        let target = root.join("instances").join("fixture-game");
        let cache = root.join("cache");
        assert!(install_new(&m, &target, &cache, &AtomicBool::new(false), |_, _, _, _| {}).is_err());
        assert!(!target.exists());
        let token = AtomicBool::new(true);
        assert_eq!(install_new(&m, &target, &cache, &token, |_, _, _, _| {}).unwrap_err(), "cancelled");
        assert!(!target.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn checks_http_ranges_and_rejects_extras() {
        for bad in ["bytes 10-9/100", "bytes */100", "bytes 0-100/100", "bytes 0-1/*"] {
            assert!(validate_remote_chunk(206, Some(bad), None, 0, 9, 100).is_err());
        }
        let root = temp_root("extras");
        let zip_path = root.join("pack.zip");
        make_zip(&zip_path, &[("game.exe", b"game")]);
        let mut m = fixture_manifest(&zip_path, b"game");
        m.files.push(serde_json::json!({"path":"mods.zip"}));
        assert_eq!(plan(&m, &root.join("missing")).status, "unsupported-extras");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_http_chunks_reject_mismatched_ranges_and_whole_large_responses() {
        let size = HTTP_CHUNK_BYTES * 2 + 31;
        assert_eq!(validate_remote_chunk(206, Some(&format!("bytes 0-{}/{}", HTTP_CHUNK_BYTES-1, size)),
                    Some(HTTP_CHUNK_BYTES), 0, HTTP_CHUNK_BYTES-1, size).unwrap(), HTTP_CHUNK_BYTES);
        assert_eq!(validate_remote_chunk(206, Some(&format!("bytes {}-{}/{}", HTTP_CHUNK_BYTES,
                    HTTP_CHUNK_BYTES*2-1, size)), None, HTTP_CHUNK_BYTES,
                    HTTP_CHUNK_BYTES*2-1, size).unwrap(), HTTP_CHUNK_BYTES);
        let end = size - 1;
        assert_eq!(validate_remote_chunk(206, Some(&format!("bytes {}-{end}/{size}", HTTP_CHUNK_BYTES*2)),
                    Some(31), HTTP_CHUNK_BYTES*2, end, size).unwrap(), 31);
        assert!(validate_remote_chunk(200, None, Some(size), 0, HTTP_CHUNK_BYTES-1, size).is_err());
        assert!(validate_remote_chunk(206, Some(&format!("bytes 1-{}/{}", HTTP_CHUNK_BYTES-1, size)),
                    None, 0, HTTP_CHUNK_BYTES-1, size).is_err());
        assert!(validate_remote_chunk(206, Some(&format!("bytes 0-{}/{}", HTTP_CHUNK_BYTES-1, size)),
                    Some(5), 0, HTTP_CHUNK_BYTES-1, size).is_err());
        assert_eq!(validate_remote_chunk(200, None, Some(10), 0, 9, 10).unwrap(), 10);
    }

    #[test]
    fn preflight_rejects_cross_zip_case_aliases_and_file_parent_conflicts() {
        let root = temp_root("parts-cross");
        let first = root.join("first.zip");
        let second = root.join("second.zip");
        make_zip(&first, &[("Game.exe", b"old")]);
        make_zip(&second, &[("game.EXE", b"new")]);
        assert!(inspect_all_archives(&[first.clone(), second.clone()], &AtomicBool::new(false)).is_err());
        make_zip(&second, &[("Game.exe", b"new")]);
        assert!(inspect_all_archives(&[first.clone(), second.clone()], &AtomicBool::new(false)).is_ok(),
            "exact file overlays by archive order remain valid");
        make_zip(&second, &[("Game.exe/child", b"conflict")]);
        assert!(inspect_all_archives(&[first, second], &AtomicBool::new(false)).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cross_zip_directory_alias_does_not_vary_by_case() {
        let root = temp_root("parent-case");
        let first = root.join("first.zip");
        let second = root.join("second.zip");
        make_zip(&first, &[("Plugins/A.dll", b"first")]);
        make_zip(&second, &[("plugins/B.dll", b"second")]);
        assert!(inspect_all_archives(&[first, second], &AtomicBool::new(false)).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn commit_never_replaces_an_instance_created_in_parallel() {
        let root = temp_root("commit-race");
        let stage = root.join("stage");
        let target = root.join("existing");
        fs::create_dir(&stage).unwrap();
        fs::create_dir(&target).unwrap();
        fs::write(target.join("user.save"), b"DO NOT TOUCH").unwrap();
        assert!(publish_stage(&stage, &target).is_err());
        assert_eq!(fs::read(target.join("user.save")).unwrap(), b"DO NOT TOUCH");
        assert!(stage.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn joins_split_files_in_stage_and_preserves_required_hash() {
        let root = temp_root("split");
        let stage = root.join("stage");
        fs::create_dir(&stage).unwrap();
        fs::write(stage.join("game.exe.part1"), b"left-").unwrap();
        fs::write(stage.join("game.exe.part2"), b"right").unwrap();
        reassemble_splits(&stage, &AtomicBool::new(false)).unwrap();
        assert_eq!(fs::read(stage.join("game.exe")).unwrap(), b"left-right");
        assert!(!stage.join("game.exe.part1").exists());
        let required = vec![FileSpec { path: "game.exe".into(), size: 10,
            sha256: format!("{:x}", Sha256::digest(b"left-right")) }];
        verify_staged_files(&stage, &required, &AtomicBool::new(false)).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn embedded_private_manifest_is_complete_and_flags_known_extras() {
        let manifest = read_manifest("big-walk").unwrap();
        assert!(!manifest.archives.is_empty());
        assert!(!manifest.required_files.is_empty());
        assert_eq!(manifest.extra_files.len(), 1);
        assert!(!has_unsupported_extras(&manifest), "role=all replace ZIP extras can be installed safely in staging");
        assert!(supported_extra(&manifest.extra_files[0]));
    }

    #[test]
    fn stage_installs_verified_zip_extras_and_records_immutable_expansion() {
        let root = temp_root("extras-stage");
        let base_zip = root.join("base.zip");
        let extra_zip = root.join("mods.zip");
        make_zip(&base_zip, &[("game.exe", b"game"), ("BepInEx/config/settings.cfg", b"init")]);
        make_zip(&extra_zip, &[("BepInEx/plugins/mod.dll", b"plugin"),
                               ("BepInEx/config/mod.cfg", b"mutable")]);
        let mut manifest = fixture_manifest(&base_zip, b"game");
        let (size, hash) = file_digest(&extra_zip, &AtomicBool::new(false)).unwrap();
        manifest.extra_files.push(ExtraSpec {
            path: "BepInEx/mods/big-walk-mods.zip".into(),
            source_url: reqwest::Url::from_file_path(&extra_zip).unwrap().to_string(),
            size, sha256: hash, role: "all".into(), policy: "replace".into(),
        });
        validate_manifest(&manifest).unwrap();
        let target = root.join("instances").join("fixture-game");
        let outcome = install_new(&manifest, &target, &root.join("cache"), &AtomicBool::new(false),
                                  |_,_,_,_|{}).unwrap();
        assert_eq!(outcome.status, "installed");
        assert_eq!(fs::read(target.join("BepInEx/plugins/mod.dll")).unwrap(), b"plugin");
        let receipt: serde_json::Value = serde_json::from_slice(
            &fs::read(target.join(".coco/standalone-install-v1.json")).unwrap()).unwrap();
        assert_eq!(receipt["extraFileArchives"][0]["sha256"], manifest.extra_files[0].sha256);
        assert_eq!(receipt["extraFiles"].as_array().unwrap().len(), 1);
        assert_eq!(receipt["extraFiles"][0]["path"], "BepInEx/plugins/mod.dll");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unsupported_extra_role_or_policy_remains_explicitly_rejected() {
        let root = temp_root("extra-policy");
        let archive = root.join("source.zip");
        make_zip(&archive, &[("game.exe", b"game")]);
        let mut manifest = fixture_manifest(&archive, b"game");
        let (size, sha256) = file_digest(&archive, &AtomicBool::new(false)).unwrap();
        manifest.extra_files.push(ExtraSpec {
            path: "mods.zip".into(),
            source_url: reqwest::Url::from_file_path(&archive).unwrap().to_string(),
            size, sha256, role: "host".into(), policy: "replace".into(),
        });
        assert_eq!(plan(&manifest, &root.join("missing")).status, "unsupported-extras");
        manifest.extra_files[0].role = "all".into();
        manifest.extra_files[0].policy = "initialize".into();
        assert_eq!(plan(&manifest, &root.join("missing")).status, "unsupported-extras");
        fs::remove_dir_all(root).unwrap();
    }

    fn fixture_user_tree(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
        let files = [
            ("saves/world/player.dat", b"world-untouched".as_slice()),
            ("BepInEx/config/custom.cfg", b"custom-config-untouched".as_slice()),
            ("DistantHorizons/data/world.db", b"dh-untouched".as_slice()),
            ("custom-plugins/MyMod.ini", b"unknown-file-untouched".as_slice()),
        ];
        files.iter().map(|(relative, content)| {
            let path = root.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, content).unwrap();
            (path, content.to_vec())
        }).collect()
    }

    fn assert_preserved_files(snapshot: &[(PathBuf, Vec<u8>)]) {
        for (path, original) in snapshot {
            assert_eq!(&fs::read(path).unwrap(), original, "modified user file {}", path.display());
        }
    }

    #[test]
    fn repair_plan_hashes_actual_required_bytes_not_only_folder_presence() {
        let root = temp_root("repair-plan");
        let archive = root.join("source.zip");
        make_zip(&archive, &[("game.exe", b"pristine")]);
        let m = fixture_manifest(&archive, b"pristine");
        let target = root.join("installed");
        fs::create_dir(&target).unwrap();
        let snapshot = fixture_user_tree(&target);
        fs::write(target.join("game.exe"), b"wrong").unwrap();
        assert_eq!(plan(&m, &target).status, "needs-repair");
        let actual = inspect_existing(&m, &target, &AtomicBool::new(false)).unwrap();
        assert_eq!(actual.status, "needs-repair");
        assert_eq!((actual.verified_files, actual.missing_files, actual.corrupt_files), (0, 0, 1));
        fs::write(target.join("game.exe"), b"pristine").unwrap();
        let healthy = inspect_existing(&m, &target, &AtomicBool::new(false)).unwrap();
        assert_eq!(healthy.status, "already-verified");
        assert_eq!(healthy.receipt, "absent");
        assert_preserved_files(&snapshot);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn offline_repair_preparation_preserves_saves_dh_config_and_old_executable() {
        let root = temp_root("repair-prepared");
        let archive = root.join("source.zip");
        make_zip(&archive, &[("game.exe", b"new-executable"),
                                  ("data/asset.dat", b"verified-asset")]);
        let mut m = fixture_manifest(&archive, b"new-executable");
        m.required_files.push(FileSpec { path: "data/asset.dat".into(), size: 14,
            sha256: format!("{:x}", Sha256::digest(b"verified-asset")) });
        let target = root.join("installed");
        fs::create_dir(&target).unwrap();
        let snapshot = fixture_user_tree(&target);
        let old_executable = b"old-custom-exe";
        fs::write(target.join("game.exe"), old_executable).unwrap();
        let mut phases = Vec::new();
        let result = prepare_repair(&m, &target, &root.join("cache"), &AtomicBool::new(false),
            |phase, _, _, _| phases.push(phase)).unwrap();
        assert_eq!(result.status, "repair-prepared-no-commit");
        assert!(phases.contains(&"repair-verifying"));
        assert_eq!(fs::read(target.join("game.exe")).unwrap(), old_executable);
        assert!(!target.join("data/asset.dat").exists(), "no partial overlay in live game");
        assert!(!target.join(".coco").exists(), "no metadata written to existing game");
        assert_preserved_files(&snapshot);
        let (sha_size, hash) = file_digest(&archive, &AtomicBool::new(false)).unwrap();
        assert_eq!(sha_size, m.archives[0].size);
        assert_eq!(hash, m.archives[0].sha256);
        assert!(root.join("cache").join(format!("{}.zip", hash)).is_file());
        assert!(!fs::read_dir(root.join("cache")).unwrap().any(|entry|
            entry.unwrap().file_name().to_string_lossy().starts_with(".coco2-stage-")),
            "ephemeral verification extraction removed");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn repair_cancellation_removes_stage_and_never_changes_instance() {
        let root = temp_root("repair-cancel");
        let archive = root.join("source.zip");
        make_zip(&archive, &[("game.exe", b"new")]);
        let m = fixture_manifest(&archive, b"new");
        let target = root.join("installed");
        fs::create_dir(&target).unwrap();
        let snapshot = fixture_user_tree(&target);
        fs::write(target.join("game.exe"), b"old").unwrap();
        let token = AtomicBool::new(false);
        let result = prepare_repair(&m, &target, &root.join("cache"), &token,
            |phase, _, _, _| {
                if phase == "repair-extracting" { token.store(true, Ordering::Relaxed); }
            });
        assert_eq!(result.unwrap_err(), "cancelled");
        assert_eq!(fs::read(target.join("game.exe")).unwrap(), b"old");
        assert_preserved_files(&snapshot);
        assert!(!fs::read_dir(root.join("cache")).unwrap().any(|entry|
            entry.unwrap().file_name().to_string_lossy().starts_with(".coco2-stage-")));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unknown_receipt_and_corrupt_source_fail_closed_without_game_changes() {
        let root = temp_root("repair-untrusted");
        let archive = root.join("source.zip");
        make_zip(&archive, &[("game.exe", b"untrusted-source")]);
        let m = fixture_manifest(&archive, b"expected-executable");
        let target = root.join("installed");
        fs::create_dir(&target).unwrap();
        let snapshot = fixture_user_tree(&target);
        fs::write(target.join("game.exe"), b"custom-executable").unwrap();
        fs::create_dir(target.join(".coco")).unwrap();
        fs::write(target.join(".coco/standalone-install-v1.json"), b"{\"id\":\"another-game\"}").unwrap();
        let plan = inspect_existing(&m, &target, &AtomicBool::new(false)).unwrap();
        assert_eq!(plan.status, "unsafe-existing");
        let result = prepare_repair(&m, &target, &root.join("cache"), &AtomicBool::new(false),
            |_, _, _, _| {}).unwrap();
        assert_eq!(result.status, "unsafe-existing");
        assert!(!root.join("cache").exists());
        // Remove only the fixture's unrecognized metadata to inspect the
        // corruption error path, never change a real game.
        fs::remove_dir_all(target.join(".coco")).unwrap();
        assert!(prepare_repair(&m, &target, &root.join("cache"), &AtomicBool::new(false),
            |_, _, _, _| {}).is_err(), "archive cannot satisfy pinned required file");
        assert_eq!(fs::read(target.join("game.exe")).unwrap(), b"custom-executable");
        assert_preserved_files(&snapshot);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn extra_missing_or_corrupt_is_not_mistaken_for_healthy_install() {
        let root = temp_root("repair-extras-plan");
        let base = root.join("base.zip");
        let extras = root.join("extra.zip");
        make_zip(&base, &[("game.exe", b"game")]);
        make_zip(&extras, &[("BepInEx/plugins/mod.dll", b"mod-verified"),
                              ("BepInEx/config/user.cfg", b"config-default")]);
        let mut manifest = fixture_manifest(&base, b"game");
        let (size, sha256) = file_digest(&extras, &AtomicBool::new(false)).unwrap();
        manifest.extra_files.push(ExtraSpec {
            path: "mods/pack.zip".into(),
            source_url: reqwest::Url::from_file_path(&extras).unwrap().to_string(),
            sha256, size, role: "all".into(), policy: "replace".into(),
        });
        let target = root.join("installed");
        assert_eq!(install_new(&manifest, &target, &root.join("cache"), &AtomicBool::new(false),
            |_,_,_,_|{}).unwrap().status, "installed");
        let before = inspect_existing(&manifest, &target, &AtomicBool::new(false)).unwrap();
        assert_eq!(before.status, "already-verified");
        assert_eq!(before.verified_extras, 1);
        let snapshot = fixture_user_tree(&target);
        fs::write(target.join("BepInEx/plugins/mod.dll"), b"modified-plugin").unwrap();
        let changed = inspect_existing(&manifest, &target, &AtomicBool::new(false)).unwrap();
        assert_eq!(changed.status, "needs-repair");
        assert_eq!(changed.corrupt_extras, 1);
        fs::remove_file(target.join("BepInEx/plugins/mod.dll")).unwrap();
        let missing = inspect_existing(&manifest, &target, &AtomicBool::new(false)).unwrap();
        assert_eq!(missing.status, "needs-repair");
        assert_eq!(missing.missing_extras, 1);
        // Mutable user config never enters the pinned immutable list.
        fs::write(target.join("BepInEx/config/user.cfg"), b"user-edited").unwrap();
        assert_preserved_files(&snapshot);
        assert_eq!(prepare_repair(&manifest, &target, &root.join("cache"), &AtomicBool::new(false),
            |_,_,_,_|{}).unwrap().status, "repair-prepared-no-commit");
        assert_eq!(fs::read(target.join("BepInEx/config/user.cfg")).unwrap(), b"user-edited");
        assert!(!target.join("BepInEx/plugins/mod.dll").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
