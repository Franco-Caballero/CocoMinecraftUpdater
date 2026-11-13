//! Offline, content-addressed Host Studio distribution packages. Preparing a
//! package never changes a live source catalog, installed game or release.
use super::*;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandalonePublishPreview {
    pub id: String,
    pub mode: String,
    pub old_version: Option<String>,
    pub new_version: String,
    pub source_catalog_sha256: String,
    pub archive_sha256: String,
    pub archive_size: u64,
    pub preview_sha256: String,
    pub changed_fields: Vec<String>,
    pub catalog_diff: String,
    pub status: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandalonePublishArtifact {
    pub id: String,
    pub mode: String,
    pub artifact_path: String,
    pub archive_path: String,
    pub manifest_path: String,
    pub catalog_path: String,
    pub lock_path: String,
    pub cover_path: String,
    pub archive_sha256: String,
    pub artifact_sha256: String,
    pub status: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortablePublishArtifact {
    pub id: String,
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub status: &'static str,
}

// Fixed package members; never add files recursively from a user-controlled
// folder. The output is a transport envelope, not an installable executable.
const PORTABLE_PARTS: &[&str] = &[
    "publish-manifest.json", "catalog.template.json", "catalog-candidate.json",
    "source-lock.json", "coco2-client-entry.json", "coco2-install-manifest.json",
];

fn portable_member_options(is_game_zip:bool)->zip::write::SimpleFileOptions {
    // A reviewed source ZIP may be as large as 128 GiB. The outer transport
    // member must declare ZIP64 BEFORE streaming its first byte, otherwise
    // zip::ZipWriter aborts after 4 GiB with "Large file option has not been set".
    // Small JSON/cover members keep ordinary headers for compatibility.
    zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .large_file(is_game_zip)
}

// File names such as CON.coco2pack look ordinary to Path::file_name, but Win32
// interprets DOS device names even when they have an extension. Reject these
// before staging, while preserving Unicode/spaces in legitimate Save As names.
fn windows_device_filename(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or("").trim_end_matches(' ')
        .to_ascii_uppercase();
    matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$")
        || ["COM", "LPT"].iter().any(|prefix| {
            stem.strip_prefix(prefix).is_some_and(|number| {
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³"]
                    .contains(&number)
            })
        })
}

// Pin every renameable ancestor of the Save As directory while writing and
// committing. Without this, a different process could rename an ancestor and
// replace the validated directory with a junction between canonicalize() and
// MoveFileW, redirecting the final package into an unintended location.
#[cfg(windows)]
struct PortableParentPin(Vec<(PathBuf, File)>);
#[cfg(windows)]
impl PortableParentPin {
    fn check(&self) -> Result<(), String> {
        use std::os::windows::fs::MetadataExt;
        for (path, handle) in &self.0 {
            let pinned = handle.metadata().map_err(|_| "Cannot inspect pinned Save As directory")?;
            if !pinned.is_dir() || pinned.file_attributes() & 0x400 != 0
                || fs::metadata(path).is_err() {
                return Err("Save As directory moved or became a reparse point".into());
            }
            no_links(path)?;
        }
        Ok(())
    }
}

#[cfg(windows)]
fn pin_portable_parent(parent: &Path) -> Result<PortableParentPin, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_SHARE_READ_WRITE: u32 = 0x0000_0003; // DENY DELETE / rename
    let mut held = Vec::new();
    // Volume roots cannot be renamed; hold all other ancestors from root down
    // so a rename between two opens cannot silently retarget a later handle.
    let renameable: Vec<_> = parent.ancestors()
        .filter(|part| part.parent().is_some()).collect();
    for path in renameable.into_iter().rev() {
        no_links(path)?;
        let mut opts = OpenOptions::new();
        opts.read(true).share_mode(FILE_SHARE_READ_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
        let handle = opts.open(path)
            .map_err(|e| format!("Cannot pin Save As directory against rename: {e}"))?;
        let info = handle.metadata()
            .map_err(|_| "Cannot inspect Save As directory handle")?;
        if !info.is_dir() || info.file_attributes() & 0x400 != 0 {
            return Err("Save As path includes a reparse point or non-directory".into());
        }
        held.push((path.to_owned(), handle));
    }
    let guard = PortableParentPin(held);
    guard.check()?;
    Ok(guard)
}

#[cfg(not(windows))]
struct PortableParentPin(PathBuf);
#[cfg(not(windows))]
impl PortableParentPin {
    fn check(&self) -> Result<(), String> { no_links(&self.0) }
}
#[cfg(not(windows))]
fn pin_portable_parent(parent: &Path) -> Result<PortableParentPin, String> {
    no_links(parent)?;
    Ok(PortableParentPin(parent.to_owned()))
}

fn open_staged_portable_for_verification(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)] {
        use std::os::windows::fs::OpenOptionsExt;
        // Keep the verified output protected against writers until MoveFileW
        // finishes. FILE_SHARE_DELETE permits that final rename while open.
        options.share_mode(0x0000_0001 | 0x0000_0004);
    }
    options.open(path).map_err(|_| "Cannot reopen portable stage for verification".into())
}

// DraftStage removes its exact private staging directory once on drop. On
// Windows a short-lived AV/indexer read handle without FILE_SHARE_DELETE can
// make that one removal fail, leaving potentially gigabytes of incomplete ZIP
// content in the user's Save As folder. Retry only this exporter-owned stage,
// for a short bounded time, after all other stage handles have been dropped.
struct PortableStageCleanup(PathBuf);
impl Drop for PortableStageCleanup {
    fn drop(&mut self) {
        for attempt in 0..12 {
            if no_links(&self.0).is_err() {break;}
            match fs::remove_dir_all(&self.0) {
                Ok(()) => break,
                Err(error) if error.kind()==std::io::ErrorKind::NotFound => break,
                Err(_) if attempt<11 => std::thread::sleep(std::time::Duration::from_millis(35)),
                Err(_) => break,
            }
        }
    }
}

/// The extension is intentionally exclusive to Coco 2. Older `.coco2pack.zip`
/// files remain supported by the CLIENT importer and the file picker, not by
/// the OS association (which must never claim the general `.zip` extension).
fn portable_destination(default_parent:&Path,directory:&str,
    selected:Option<&str>)->Result<(PathBuf,PortableParentPin),String>{
    let Some(selected)=selected else {
        let pinned=pin_portable_parent(default_parent)?;
        return Ok((default_parent.join(format!("{directory}.coco2pack")),pinned));
    };
    #[cfg(windows)]
    if selected.starts_with(r"\\") || selected.starts_with("//") {
        return Err("Portable export requires a local file, not UNC/device paths".into());
    }
    if selected.is_empty() || selected.contains("://") {
        return Err("Portable export needs an absolute local Save As path".into());
    }
    let original=Path::new(selected);
    if !original.is_absolute() || original.components().any(|component|
        matches!(component,std::path::Component::ParentDir|std::path::Component::CurDir)){
        return Err("Portable destination must be an absolute normalized path".into());
    }
    let name=original.file_name().and_then(|name|name.to_str())
        .ok_or("Portable destination filename is invalid")?;
    if !name.to_ascii_lowercase().ends_with(".coco2pack")
        || name.len()<"x.coco2pack".len()
        || name.contains([':', '\\', '/', '"', '*', '?', '<', '>', '|'])
        || name.chars().any(char::is_control)
        || name.ends_with(' ') || name.ends_with('.') || windows_device_filename(name) {
        return Err("Save As must use a safe filename ending in .coco2pack".into());
    }
    no_links(original)?;
    let parent=original.parent().ok_or("Portable destination has no parent")?;
    no_links(parent)?;
    // Pin the as-selected path before canonicalization. Each ancestor handle
    // denies FILE_SHARE_DELETE, preventing rename/reparent while exporting.
    let pinned=pin_portable_parent(parent)?;
    let physical=parent.canonicalize().map_err(|_|"Portable export directory does not exist")?;
    no_links(&physical)?;
    if !physical.is_dir(){return Err("Portable export parent is not a directory".into());}
    let dest=physical.join(name);
    no_links(&dest)?;
    if fs::symlink_metadata(&dest).is_ok(){
        return Err("Portable export target already exists; never overwrite".into());
    }
    Ok((dest,pinned))
}

fn portable_file(root: &Path, id: &str, sealed: &Path, destination_path:Option<&str>)
    -> Result<PortablePublishArtifact, String>
{
    portable_file_with_commit_hook(root,id,sealed,destination_path,||{})
}

// A no-op in production; the synthetic test can deterministically introduce a
// competing destination exactly after the package has been verified and staged.
fn portable_file_with_commit_hook(root: &Path, id: &str, sealed: &Path,
    destination_path:Option<&str>, before_commit:impl FnOnce())
    -> Result<PortablePublishArtifact, String>
{
    if !valid_id(id) { return Err("Invalid portable publication ID".into()); }
    let packages=root.join("publish-packages");
    no_links(&packages)?;
    no_links(sealed)?;
    let package=sealed.canonicalize().map_err(|_|"Sealed source package missing")?;
    let trusted_parent=packages.canonicalize().map_err(|_|"Host package root missing")?;
    if package.parent()!=Some(trusted_parent.as_path()) || !package.is_dir() {
        return Err("Portable export must use an existing Host Studio package".into());
    }
    let directory=package.file_name().and_then(|s|s.to_str()).ok_or("Invalid package directory")?;
    let manifest_bytes=bounded_file(&package.join("publish-manifest.json"),MAX_JSON_BYTES)?;
    let meta:Value=serde_json::from_slice(&manifest_bytes)
        .map_err(|_|"Invalid sealed package metadata")?;
    // Stage identity is fixed by the original reviewed preview hash. A caller
    // must not rename any other directory under publish-packages to `id-*`
    // and gain the already-reviewed package's authority during Save As.
    let preview_hash=meta["previewSha256"].as_str()
        .ok_or("Missing sealed package preview identity")?;
    if !valid_sha(preview_hash)
        || directory!=format!("{id}-{}",&preview_hash[..24]) {
        return Err("Sealed directory does not match reviewed preview identity".into());
    }
    // A directory name and its JSON manifest can both be renamed/re-written.
    // Reconstruct the EXACT fingerprint used by prepare_inputs at human review
    // time instead of trusting two matching, unverified pieces of metadata.
    // This is internal consistency, NOT proof of signature or official origin.
    let fingerprint_fields=["sourceCatalogSha256","candidateSha256", "resultCatalogSha256",
        "lockSha256","coverSha256","archiveSha256"];
    if fingerprint_fields.iter().any(|field|
        meta[*field].as_str().is_none_or(|value|!valid_sha(value)))
        || !matches!(meta["mode"].as_str(),Some("new"|"update"))
        || meta["newVersion"].as_str().is_none_or(str::is_empty)
        || !(meta["oldVersion"].is_null()||meta["oldVersion"].is_string())
    {
        return Err("Invalid sealed package review fingerprint fields".into());
    }
    let fingerprint=serde_json::json!({
        "id":id,"mode":meta["mode"],"oldVersion":meta["oldVersion"],
        "version":meta["newVersion"],
        "sourceCatalogSha256":meta["sourceCatalogSha256"],
        "candidateSha256":meta["candidateSha256"],
        "resultCatalogSha256":meta["resultCatalogSha256"],
        "lockSha256":meta["lockSha256"],"coverSha256":meta["coverSha256"],
        "archiveSha256":meta["archiveSha256"],"archiveSize":meta["archiveSize"],
    });
    let actual_preview_sha=sha_bytes(&serde_json::to_vec(&fingerprint)
        .map_err(|_|"Cannot verify sealed publish review identity")?);
    if preview_hash!=actual_preview_sha {
        return Err("Sealed package no longer matches its human-reviewed preview".into());
    }
    // A sealed manifest is a file map, not just a set of unrelated SHA fields.
    // The exporter always emits these exact flat names; shipping a manifest
    // pointing elsewhere would yield a portable the receiver cannot import.
    if meta["archiveFile"]!="game.zip" || meta["catalogFile"]!="catalog.template.json"
        || meta["lockFile"]!="source-lock.json" {
        return Err("Sealed package manifest refers to unexpected member paths".into());
    }
    if meta["schemaVersion"]!=1 || meta["packageKind"]!="coco2-host-publish-offline"
        || meta["id"]!=id || meta["reviewedRights"]!=true || meta["uploaded"]!=false
        || meta["published"]!=false || meta["installationsUpdated"]!=false {
        return Err("Untrusted Host Studio package metadata".into());
    }
    let archive_size=meta["archiveSize"].as_u64().ok_or("Invalid package ZIP size")?;
    let archive_sha=meta["archiveSha256"].as_str().ok_or("Missing package ZIP hash")?;
    if !valid_sha(archive_sha) || archive_size==0 || archive_size>MAX_ARCHIVE_BYTES {
        return Err("Untrusted Host Studio ZIP metadata".into());
    }
    let cover_name=meta["coverFile"].as_str().ok_or("Missing package cover")?;
    if !matches!(cover_name,"cover.png"|"cover.jpg"|"cover.jpeg"|"cover.webp") {
        return Err("Unexpected cover member in publication".into());
    }
    let file_shas=[
        ("catalog.template.json","resultCatalogSha256"),
        ("catalog-candidate.json","candidateSha256"),
        ("source-lock.json","lockSha256"),
        ("coco2-client-entry.json","clientPreviewSha256"),
        ("coco2-install-manifest.json","installPreviewSha256"),
        (cover_name,"coverSha256"),
    ];
    for (name,field) in file_shas {
        let expected=meta[field].as_str().ok_or("Missing package member provenance")?;
        if !valid_sha(expected) {return Err("Invalid package member provenance".into());}
        let member=package.join(name);
        no_links(&member)?;
        // Source JSON and cover are each bounded and verified before sealing.
        let limit=if name.starts_with("cover."){MAX_COVER_BYTES}else{MAX_JSON_BYTES};
        if sha_bytes(&bounded_file(&member,limit)?)!=expected {
            return Err(format!("Package member changed since sealing: {name}"));
        }
    }
    // No reparse point from the original input can escape the immutable
    // package. Hold the ZIP read handle with FILE_SHARE_READ only on Windows.
    let zip_path=package.join("game.zip");
    no_links(&zip_path)?;
    let mut archive=open_local_source(&zip_path)?;
    if archive.metadata().map_err(|e|e.to_string())?.len()!=archive_size {
        return Err("Sealed archive size changed".into());
    }
    let mut archive_digest=Sha256::new();
    let mut buffer=vec![0u8;COPY_CHUNK_BYTES];
    let mut counted=0u64;
    loop {
        let n=archive.read(&mut buffer).map_err(|e|e.to_string())?;
        if n==0{break;}
        counted=counted.checked_add(n as u64).ok_or("ZIP byte overflow")?;
        if counted>MAX_ARCHIVE_BYTES{return Err("ZIP exceeds size bound".into());}
        archive_digest.update(&buffer[..n]);
    }
    if counted!=archive_size || format!("{:x}",archive_digest.finalize())!=archive_sha {
        return Err("Sealed archive content changed".into());
    }
    archive.seek(SeekFrom::Start(0)).map_err(|e|e.to_string())?;
    // An exclusive `.coco2pack` extension is distinct from `.zip` and retains
    // ZIP bytes. Existing `.coco2pack.zip` transfers remain importable.
    let (dest,pinned_parent)=portable_destination(&trusted_parent,directory,destination_path)?;
    if dest.starts_with(&package){return Err("Cannot export inside a sealed source package".into());}
    no_links(&dest)?;
    if fs::symlink_metadata(&dest).is_ok() {
        return Err("Portable package already exported; never overwrite existing delivery".into());
    }
    // Reserve a private stage on the requested destination volume. Final
    // MoveFileW (without REPLACE_EXISTING) is atomic and fail-closed if a
    // second writer has reserved the same filename.
    let destination_parent=dest.parent().ok_or("Portable destination has no parent")?;
    no_links(destination_parent)?;
    let stage=create_stage(destination_parent,id)?;
    let _retry_cleanup=PortableStageCleanup(stage.0.clone());
    // An attacker cannot swap/rename the newly-created stage directory while
    // its verified file is reopened and moved by pathname into the destination.
    let pinned_stage=pin_portable_parent(&stage.0)?;
    let temp=stage.0.join("delivery.coco2pack.zip");
    let output=OpenOptions::new().create_new(true).write(true).open(&temp)
        .map_err(|e|format!("Cannot stage portable package: {e}"))?;
    let mut writer=zip::ZipWriter::new(output);
    let opts=portable_member_options(false);
    for name in PORTABLE_PARTS.iter().copied().chain(std::iter::once(cover_name)) {
        let member=package.join(name);
        no_links(&member)?;
        let mut file=open_local_source(&member)?;
        writer.start_file(name,opts).map_err(|e|format!("ZIP header refused: {e}"))?;
        let expected=if name=="publish-manifest.json"{sha_bytes(&manifest_bytes)}else {
            let field=match name {
                "catalog.template.json"=>"resultCatalogSha256",
                "catalog-candidate.json"=>"candidateSha256",
                "source-lock.json"=>"lockSha256",
                "coco2-client-entry.json"=>"clientPreviewSha256",
                "coco2-install-manifest.json"=>"installPreviewSha256",
                _=>"coverSha256",
            };
            meta[field].as_str().ok_or("Sealed portable member hash absent")?.to_owned()
        };
        let mut actual=Sha256::new();let mut checked=0u64;
        loop {
            let n=file.read(&mut buffer).map_err(|e|format!("Cannot read sealed member: {e}"))?;
            if n==0{break;}
            checked=checked.checked_add(n as u64).ok_or("Member size overflow")?;
            if checked>MAX_JSON_BYTES.max(MAX_COVER_BYTES){return Err("Metadata member exceeds export size limit".into());}
            actual.update(&buffer[..n]);
            writer.write_all(&buffer[..n]).map_err(|e|format!("Cannot export metadata: {e}"))?;
        }
        if format!("{:x}",actual.finalize())!=expected{
            return Err(format!("Member changed during portable export: {name}"));
        }
    }
    writer.start_file("game.zip",portable_member_options(true))
        .map_err(|e|format!("ZIP archive header refused: {e}"))?;
    let mut actual=Sha256::new();let mut copied=0u64;
    loop {
        let n=archive.read(&mut buffer).map_err(|e|format!("Cannot read sealed ZIP: {e}"))?;
        if n==0{break;}
        copied=copied.checked_add(n as u64).ok_or("ZIP copy size overflow")?;
        if copied>MAX_ARCHIVE_BYTES{return Err("ZIP copy exceeds size limit".into());}
        actual.update(&buffer[..n]);
        writer.write_all(&buffer[..n]).map_err(|e|format!("Cannot write portable ZIP: {e}"))?;
    }
    if copied!=archive_size||format!("{:x}",actual.finalize())!=archive_sha{
        return Err("Sealed archive changed during portable export".into());
    }
    let output=writer.finish().map_err(|e|format!("Cannot finish portable ZIP: {e}"))?;
    output.sync_all().map_err(|e|format!("Cannot flush portable package: {e}"))?;
    drop(output);
    let mut delivered=open_staged_portable_for_verification(&temp)?;
    let mut digest=Sha256::new();let mut size=0u64;
    loop {let n=delivered.read(&mut buffer).map_err(|e|e.to_string())?;
        if n==0{break;} size=size.checked_add(n as u64).ok_or("Portable size overflow")?;
        if size>MAX_ARCHIVE_BYTES+64*1024*1024{return Err("Portable export exceeds bound".into());}
        digest.update(&buffer[..n]);
    }
    let checksum=format!("{:x}",digest.finalize());
    before_commit();
    pinned_parent.check()?;
    pinned_stage.check()?;
    no_links(destination_parent)?;no_links(&dest)?;
    rename_no_replace(&temp,&dest)?;
    drop(delivered);
    Ok(PortablePublishArtifact{id:id.to_owned(),path:dest.display().to_string(),
        size,sha256:checksum,status:"exported-local-untrusted-unpublished"})
}

pub(super) fn export_portable(root:&Path,id:&str,artifact_path:&str)
    -> Result<PortablePublishArtifact,String>
{
    portable_file(root,id,Path::new(artifact_path),None)
}

pub(super) fn export_portable_to(root:&Path,id:&str,artifact_path:&str,
    destination_path:Option<&str>)->Result<PortablePublishArtifact,String>{
    portable_file(root,id,Path::new(artifact_path),destination_path)
}

pub(super) const PROGRESS_EVENT: &str = "coco2://host-publish-progress";
const COPY_CHUNK_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandalonePublishProgress {
    pub id: String,
    pub phase: &'static str,
    pub processed_bytes: u64,
    pub total_bytes: u64,
    pub percent: Option<f64>,
}

impl StandalonePublishProgress {
    fn measured(id: &str, phase: &'static str, processed_bytes: u64, total_bytes: u64) -> Self {
        Self {
            id: id.to_owned(), phase, processed_bytes, total_bytes,
            percent: (total_bytes > 0).then(|| 100.0 * processed_bytes as f64 / total_bytes as f64),
        }
    }

    pub(super) fn unknown(id: &str, phase: &'static str) -> Self {
        Self { id: id.to_owned(), phase, processed_bytes: 0, total_bytes: 0, percent: None }
    }
}

struct PublishPrepared {
    preview: StandalonePublishPreview,
    candidate: Value,
    promotion: PromotionPrepared,
    cover_extension: String,
    source_zip: PathBuf,
}

fn scan_secrets(bytes: &[u8]) -> Result<(), String> {
    // This is an additional conservative screen, not a guarantee that binaries
    // or encrypted files contain no embedded credentials.
    let value = String::from_utf8_lossy(bytes).to_ascii_lowercase();
    for marker in [
        "-----begin rsa private key-----", "-----begin openssh private key-----",
        "-----begin private key-----", "-----begin ec private key-----",
        "github_pat_", "ghp_", "gho_", "ghu_", "ghs_",
        "zerotier_authtoken", "identity.secret", "x-api-key:",
        "authorization: bearer ", "\"private_key\":", "\"client_secret\":",
    ] {
        if value.contains(marker) { return Err("Possible credential in publish input".into()); }
    }
    Ok(())
}

fn inspect_archive_secrets(file: &mut File) -> Result<(), String> {
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| "Invalid archive during secret preflight")?;
    let mut examined = 0u64;
    for index in 0..zip.len() {
        let mut item = zip.by_index(index).map_err(|_| "Cannot read ZIP metadata")?;
        let path = safe_path(item.name(), item.is_dir())?;
        let lower = path.to_ascii_lowercase();
        let segments: Vec<_> = lower.split('/').collect();
        if segments.iter().any(|part| matches!(*part,
            ".env" | ".git" | ".ssh" | "secrets" | "credentials"
            | "id_rsa" | "id_ed25519" | "identity.secret" | "authtoken.secret"
        )) || lower.ends_with(".pem") || lower.ends_with(".pfx")
            || lower.ends_with(".key") || lower.ends_with(".p12")
        {
            return Err(format!("Publish input includes a likely secret file: {path}"));
        }
        // Examine small, relevant textual config files; cap work and fail
        // closed when a package has too much config to meaningfully screen.
        if !item.is_dir() && [".json", ".ini", ".yaml", ".yml", ".toml",
            ".config", ".cfg", ".properties", ".txt"].iter().any(|ext| lower.ends_with(ext))
        {
            if item.size() > 64 * 1024 * 1024 {
                return Err(format!("Text configuration exceeds credential-screen budget: {path}"));
            }
            examined = examined.checked_add(item.size()).ok_or("Secret screen overflow")?;
            if examined > 128 * 1024 * 1024 {
                return Err("ZIP contains too much configuration to screen safely".into());
            }
            // Scan all bytes with a bounded buffer. Keep overlap so a marker
            // split across reads cannot evade the credential check.
            let mut bytes = vec![0u8; 64 * 1024 + 128];
            let mut retained = 0;
            loop {
                let count = item.read(&mut bytes[retained..]).map_err(|_| "Cannot screen ZIP text")?;
                if count == 0 { break; }
                let end = retained + count;
                scan_secrets(&bytes[..end])?;
                retained = end.min(128);
                bytes.copy_within(end - retained..end, 0);
            }
        }
    }
    Ok(())
}

fn changed_fields(prefix: &str, old: &Value, new: &Value, fields: &mut Vec<String>) {
    if old == new || fields.len() >= 128 { return; }
    if let (Some(a), Some(b)) = (old.as_object(), new.as_object()) {
        let mut keys = a.keys().chain(b.keys()).collect::<Vec<_>>();
        keys.sort();
        keys.dedup();
        for key in keys {
            if fields.len() >= 128 { break; }
            changed_fields(&format!("{prefix}/{key}"),
                a.get(key).unwrap_or(&Value::Null), b.get(key).unwrap_or(&Value::Null), fields);
        }
    } else {
        fields.push(prefix.to_owned());
    }
}

fn source_catalog(root: &Path) -> Result<(Value, Vec<u8>), String> {
    let bytes = bounded_file(&root.parent().ok_or("Missing source repo")?
        .join("launcher/catalog.template.json"), MAX_JSON_BYTES)?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "Invalid source catalog")?;
    if value["schemaVersion"] != 1 { return Err("Unsupported catalog schema".into()); }
    Ok((value, bytes))
}

fn prepare_inputs(root: &Path, id: &str, original_zip_path: &str) -> Result<PublishPrepared, String> {
    if !valid_id(id) { return Err("Invalid publish experience ID".into()); }
    let (catalog, catalog_bytes) = source_catalog(root)?;
    let entries = catalog["experiences"].as_array().ok_or("Missing experiences list")?;
    let old = entries.iter().find(|entry| entry["id"] == id);
    let mode = if old.is_some() { "update" } else { "new" };
    let promotion = prepare_promotion_mode(root, id, original_zip_path, old.is_some())?;
    let candidate_path = root.join(if old.is_some() { "update-drafts" } else { "drafts" })
        .join(id).join("catalog-candidate.json");
    let candidate_bytes = bounded_file(&candidate_path, 2 * 1024 * 1024)?;
    let candidate: Value = serde_json::from_slice(&candidate_bytes)
        .map_err(|_| "Invalid publish candidate")?;
    let cover_extension = Path::new(&promotion.review.cover_target)
        .extension().and_then(|s| s.to_str()).ok_or("Missing cover extension")?.to_string();
    // Reopen the actual local archive for the credential preflight. Both the
    // stage and the source archive are independently verified before sealing.
    let source_zip = canonical_file(original_zip_path, "Original ZIP")?;
    let mut source = open_local_source(&source_zip)?;
    inspect_archive_secrets(&mut source)?;
    drop(source);
    scan_secrets(&candidate_bytes)?;
    scan_secrets(&promotion.lock)?;
    let mut fields = Vec::new();
    changed_fields("", old.unwrap_or(&Value::Null), &candidate, &mut fields);
    if fields.is_empty() { return Err("Publish package makes no catalog changes".into()); }
    let old_version = old.and_then(|entry| entry["pack"]["version"].as_str()).map(str::to_owned);
    let new_version = required_string(&candidate["pack"], "version")?.to_owned();
    let status = if old.is_some() {
        "review-required-existing-installations-unchanged"
    } else { "review-required-not-published" };
    let summary = serde_json::json!({
        "mode":mode, "id":id, "oldVersion":old_version,
        "newVersion":new_version, "changedFields":fields,
        "before":old, "after":candidate
    });
    let catalog_diff = serde_json::to_string_pretty(&summary)
        .map_err(|_| "Cannot render publish diff")?;
    let preview_fingerprint = serde_json::json!({
        "id":id, "mode":mode, "oldVersion":old_version, "version":new_version,
        "sourceCatalogSha256":sha_bytes(&catalog_bytes),
        "candidateSha256":sha_bytes(&candidate_bytes),
        "resultCatalogSha256":sha_bytes(&promotion.catalog_after),
        "lockSha256":sha_bytes(&promotion.lock), "coverSha256":sha_bytes(&promotion.cover),
        "archiveSha256":promotion.review.archive_sha256,
        "archiveSize":promotion.review.archive_size
    });
    let preview_sha256 = sha_bytes(&serde_json::to_vec(&preview_fingerprint)
        .map_err(|_| "Cannot encode publish fingerprint")?);
    Ok(PublishPrepared {
        preview: StandalonePublishPreview {
            id:id.to_owned(), mode:mode.to_owned(), old_version, new_version,
            source_catalog_sha256:promotion.review.catalog_sha256.clone(),
            archive_sha256:promotion.review.archive_sha256.clone(),
            archive_size:promotion.review.archive_size, preview_sha256,
            changed_fields:fields, catalog_diff, status:status.to_owned(),
        },
        candidate, promotion, cover_extension, source_zip
    })
}

pub(super) fn preview(root: &Path, id: &str, original_zip_path: &str)
    -> Result<StandalonePublishPreview, String>
{
    prepare_inputs(root, id, original_zip_path).map(|p| p.preview)
}

fn client_entry(candidate: &Value) -> Value {
    let id = candidate["id"].as_str().unwrap_or("");
    let image_path = candidate["ui"]["imagePath"].as_str().unwrap_or("");
    let image_file = image_path.rsplit('/').next().unwrap_or("");
    serde_json::json!({
        "id":id, "instanceId":candidate["instanceId"], "name":candidate["name"],
        "image":format!("/covers/{image_file}.webp"),
        "description":candidate["description"], "workflow":"coco-standalone",
        "minecraftVersion":"", "loader":"",
        "requiredFiles":candidate["runtime"]["requiredFiles"].as_array().unwrap_or(&vec![])
            .iter().map(|item| serde_json::json!({
                "path":item["path"],"sha256":item["sha256"],"size":item["size"]
            })).collect::<Vec<_>>(),
        "executable":candidate["runtime"]["executable"],
        "launchArguments":[], "hostingMode":"p2p"
    })
}

fn install_manifest(candidate: &Value) -> Value {
    serde_json::json!({
        "id":candidate["id"], "instanceId":candidate["instanceId"],
        "workflow":"coco-standalone", "version":candidate["pack"]["version"],
        "archives":candidate["pack"]["archives"].as_array().unwrap_or(&vec![])
            .iter().map(|item| serde_json::json!({
                "url":item["archiveUrl"], "sha256":item["sha256"], "size":item["size"]
            })).collect::<Vec<_>>(),
        "requiredFiles":client_entry(candidate)["requiredFiles"],
        "extraFiles":[]
    })
}

fn write_json_new(path: &Path, value: &Value) -> Result<Vec<u8>, String> {
    let mut encoded = serde_json::to_vec_pretty(value).map_err(|_| "Cannot encode publish JSON")?;
    encoded.push(b'\n');
    write_new(path, &encoded)?;
    Ok(encoded)
}

fn copy_verified_archive(
    source: &Path, target: &Path, expected_size: u64, expected_sha: &str,
    id: &str, notify: &mut impl FnMut(StandalonePublishProgress),
) -> Result<(), String> {
    let mut input = open_local_source(source)?;
    if input.metadata().map_err(|_| "Cannot stat ZIP")?.len() != expected_size {
        return Err("Original ZIP changed since preview".into());
    }
    let mut output = OpenOptions::new().write(true).create_new(true).open(target)
        .map_err(|_| "Cannot create private archive artifact")?;
    let mut digest = Sha256::new();
    let mut copied = 0u64;
    // Hash verification below uses another large buffer; allocate this one
    // on the heap to stay within Windows Rust test thread stack limits.
    let mut buffer = vec![0u8; COPY_CHUNK_BYTES];
    notify(StandalonePublishProgress::measured(id, "copying", 0, expected_size));
    loop {
        let count = input.read(&mut buffer).map_err(|_| "Cannot read original ZIP")?;
        if count == 0 { break; }
        copied = copied.checked_add(count as u64).ok_or("Archive byte count overflow")?;
        if copied > MAX_ARCHIVE_BYTES { return Err("Archive exceeds size budget".into()); }
        output.write_all(&buffer[..count]).map_err(|_| "Cannot persist staged ZIP")?;
        digest.update(&buffer[..count]);
        notify(StandalonePublishProgress::measured(id, "copying", copied, expected_size));
    }
    output.sync_all().map_err(|_| "Cannot flush ZIP artifact")?;
    if copied != expected_size || format!("{:x}", digest.finalize()) != expected_sha {
        return Err("Archive changed while copying; artifact rejected".into());
    }
    drop(output);
    let mut staged = File::open(target).map_err(|_| "Cannot reopen ZIP artifact")?;
    let mut verifier = Sha256::new();
    let mut verified = 0u64;
    notify(StandalonePublishProgress::measured(id, "verifying", 0, expected_size));
    loop {
        let count = staged.read(&mut buffer).map_err(|_| "Cannot verify staged ZIP")?;
        if count == 0 { break; }
        verified = verified.checked_add(count as u64).ok_or("Verification byte count overflow")?;
        if verified > MAX_ARCHIVE_BYTES {
            return Err("Staged ZIP exceeds size budget".into());
        }
        verifier.update(&buffer[..count]);
        notify(StandalonePublishProgress::measured(id, "verifying", verified, expected_size));
    }
    if format!("{:x}", verifier.finalize()) != expected_sha || verified != expected_size {
        return Err("Staged ZIP hash verification failed".into());
    }
    Ok(())
}

fn prepare_with_hook(root: &Path, id: &str, original_zip_path: &str,
                     expected_preview_sha256: &str, before_commit: impl FnOnce(),
                     mut notify: impl FnMut(StandalonePublishProgress))
    -> Result<StandalonePublishArtifact, String>
{
    notify(StandalonePublishProgress::unknown(id, "preflight"));
    if !valid_sha(expected_preview_sha256) { return Err("Invalid expected preview SHA256".into()); }
    let _guard = PROMOTION_MUTEX.get_or_init(|| Mutex::new(()))
        .lock().map_err(|_| "Host Studio publish mutex poisoned")?;
    let _kernel_lock = NativePromotionLock::new(root)?;
    let prepared = prepare_inputs(root, id, original_zip_path)?;
    if prepared.preview.preview_sha256 != expected_preview_sha256 {
        return Err("Publish preview became stale: review again".into());
    }
    let packages = root.join("publish-packages");
    no_links(&packages)?;
    fs::create_dir_all(&packages).map_err(|_| "Cannot create publish package directory")?;
    no_links(&packages)?;
    let destination = packages.join(format!("{}-{}", id, &prepared.preview.preview_sha256[..24]));
    no_links(&destination)?;
    if fs::symlink_metadata(&destination).is_ok() {
        return Err("Immutable publish package already exists; inspect the prior artifact".into());
    }
    let stage = create_stage(&packages, id)?;
    no_links(&stage.0)?;
    let archive = stage.0.join("game.zip");
    copy_verified_archive(&prepared.source_zip, &archive,
        prepared.preview.archive_size, &prepared.preview.archive_sha256, id, &mut notify)?;
    let catalog = stage.0.join("catalog.template.json");
    write_new(&catalog, &prepared.promotion.catalog_after)?;
    let lock = stage.0.join("source-lock.json");
    write_new(&lock, &prepared.promotion.lock)?;
    let candidate = stage.0.join("catalog-candidate.json");
    write_json_new(&candidate, &prepared.candidate)?;
    let cover_name = format!("cover.{}", prepared.cover_extension);
    let cover = stage.0.join(&cover_name);
    write_new(&cover, &prepared.promotion.cover)?;
    let consumer = client_entry(&prepared.candidate);
    let install = install_manifest(&prepared.candidate);
    let client_bytes = write_json_new(&stage.0.join("coco2-client-entry.json"), &consumer)?;
    let install_bytes = write_json_new(&stage.0.join("coco2-install-manifest.json"), &install)?;
    let manifest = serde_json::json!({
        "schemaVersion":1, "packageKind":"coco2-host-publish-offline",
        "id":id, "mode":prepared.preview.mode, "oldVersion":prepared.preview.old_version,
        "newVersion":prepared.preview.new_version,
        "sourceCatalogSha256":prepared.preview.source_catalog_sha256,
        "resultCatalogSha256":sha_bytes(&prepared.promotion.catalog_after),
        "clientPreviewSha256":sha_bytes(&client_bytes),
        "installPreviewSha256":sha_bytes(&install_bytes),
        "previewSha256":prepared.preview.preview_sha256,
        "archiveSha256":prepared.preview.archive_sha256,
        "archiveSize":prepared.preview.archive_size,
        "archiveUrl":prepared.promotion.review.source_archive_url,
        "archiveFile":"game.zip", "catalogFile":"catalog.template.json",
        "lockFile":"source-lock.json", "coverFile":cover_name,
        "lockSha256":sha_bytes(&prepared.promotion.lock),
        "coverSha256":sha_bytes(&prepared.promotion.cover),
        "candidateSha256":sha_bytes(&fs::read(&candidate).map_err(|_| "Cannot read staged candidate")?),
        "reviewedRights":true,
        "installationsUpdated":false, "uploaded":false, "published":false,
        "nextAction":"Review rights and exact content; deliver the offline package locally, or stage a signed dynamic GitHub channel after the listed remote ZIP assets exist. Do not publish or claim authenticity before a verified detached signature. No Coco2 application rebuild is required for trusted dynamic catalogs. Existing games require separate verified upgrade."
    });
    let manifest_bytes = write_json_new(&stage.0.join("publish-manifest.json"), &manifest)?;
    // This digest identifies the manifest; its referenced SHA256 values cover
    // the archive and every packaged source/derived metadata component.
    let artifact_sha256 = sha_bytes(&manifest_bytes);
    // Verify source and catalog have not changed while copying (possible
    // multi-gigabyte archives). An update must be reviewed again if they did.
    before_commit();
    notify(StandalonePublishProgress::unknown(id, "rechecking"));
    let rereview = prepare_inputs(root, id, original_zip_path)?;
    if rereview.preview.preview_sha256 != expected_preview_sha256 {
        return Err("Source catalog, draft, cover or ZIP changed while staging; package discarded".into());
    }
    no_links(&packages)?;
    no_links(&destination)?;
    notify(StandalonePublishProgress::unknown(id, "sealing"));
    rename_no_replace(&stage.0, &destination)?;
    notify(StandalonePublishProgress::measured(id, "complete",
        prepared.preview.archive_size, prepared.preview.archive_size));
    Ok(StandalonePublishArtifact {
        id:id.to_owned(), mode:prepared.preview.mode,
        artifact_path:destination.display().to_string(),
        archive_path:destination.join("game.zip").display().to_string(),
        manifest_path:destination.join("publish-manifest.json").display().to_string(),
        catalog_path:destination.join("catalog.template.json").display().to_string(),
        lock_path:destination.join("source-lock.json").display().to_string(),
        cover_path:destination.join(cover_name).display().to_string(),
        archive_sha256:prepared.preview.archive_sha256,
        artifact_sha256,
        status:"prepared-offline-review-only".into(),
    })
}

pub(super) fn prepare(root: &Path, id: &str, original_zip_path: &str,
                      expected_preview_sha256: &str,
                      notify: impl FnMut(StandalonePublishProgress)) -> Result<StandalonePublishArtifact, String> {
    prepare_with_hook(root, id, original_zip_path, expected_preview_sha256, || {}, notify)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use zip::write::SimpleFileOptions;
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    // Synthesize >4 GiB of ZIP output using only a counting seekable sink.
    // No games, network traffic, or multi-gigabyte TEMP files are created.
    #[derive(Default,Debug)]
    struct VirtualZipSink { offset:u64, length:u64 }
    impl Write for VirtualZipSink {
        fn write(&mut self, buf:&[u8])->std::io::Result<usize>{
            self.offset=self.offset.checked_add(buf.len() as u64)
                .ok_or(std::io::Error::other("Synthetic ZIP offset overflow"))?;
            self.length=self.length.max(self.offset);
            Ok(buf.len())
        }
        fn flush(&mut self)->std::io::Result<()> {Ok(())}
    }
    impl Seek for VirtualZipSink {
        fn seek(&mut self,from:SeekFrom)->std::io::Result<u64>{
            let next=match from {
                SeekFrom::Start(value)=>value as i128,
                SeekFrom::Current(value)=>self.offset as i128+value as i128,
                SeekFrom::End(value)=>self.length as i128+value as i128,
            };
            if next<0||next>u64::MAX as i128 {
                return Err(std::io::Error::other("Invalid synthetic ZIP seek"));
            }
            self.offset=next as u64;
            Ok(self.offset)
        }
    }

    #[test]
    fn portable_outer_game_zip_supports_zip64_past_four_gib_without_real_disk_usage(){
        let mut writer=zip::ZipWriter::new(VirtualZipSink::default());
        let opts=portable_member_options(true);
        writer.start_file("game.zip",opts).unwrap();
        let chunk=vec![0x44u8;COPY_CHUNK_BYTES];
        for _ in 0..4_097 {writer.write_all(&chunk).unwrap();}
        let result=writer.finish();
        assert!(result.is_ok(),"Portable ZIP rejected its documented >4 GiB source: {result:?}");
        assert!(result.unwrap().length>u32::MAX as u64);
    }

    #[cfg(windows)]
    #[test]
    fn transient_reader_lock_does_not_leave_partial_portable_stage(){
        use std::os::windows::fs::OpenOptionsExt;
        let fix=TestRepo::new();
        let output=fix.repo.join("export transient locks");
        fs::create_dir(&output).unwrap();
        let stage=create_stage(&output,"my-game").unwrap();
        let stage_path=stage.0.clone();
        let cleanup=PortableStageCleanup(stage_path.clone());
        let partial=stage_path.join("delivery.coco2pack.zip");
        fs::write(&partial,b"incomplete synthetic portable data").unwrap();
        // A scanner/indexer still holding a read handle denies delete for a
        // brief interval, just as a real Defender sharing violation does.
        let locked=OpenOptions::new().read(true).share_mode(0x1)
            .open(&partial).unwrap();
        let release=std::thread::spawn(move||{
            std::thread::sleep(std::time::Duration::from_millis(130));
            drop(locked);
        });
        drop(stage);
        drop(cleanup);
        release.join().unwrap();
        assert!(!stage_path.exists(),
            "a transient sharing violation left a potentially huge .stage after cancellation");
        assert_eq!(fs::read_dir(output).unwrap().count(),0);
    }

    struct TestRepo { repo: PathBuf }
    impl TestRepo {
        fn new() -> Self {
            let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
            let repo = std::env::temp_dir().join(format!("coco-publish-test-{}-{stamp}-{}",
                std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            for relative in ["launcher2", "launcher/experiences", "assets/experiences"] {
                fs::create_dir_all(repo.join(relative)).unwrap();
            }
            fs::write(repo.join("launcher/catalog.template.json"),
                br#"{"schemaVersion":1,"experiences":[{"id":"existing-unrelated","description":"preserve"}]}"#).unwrap();
            fs::write(repo.join("cover.png"), b"\x89PNG\r\n\x1a\nvalid123").unwrap();
            Self { repo }
        }
        fn root(&self) -> PathBuf { self.repo.join("launcher2") }
        fn source(&self) -> PathBuf { self.repo.join("launcher/catalog.template.json") }
        fn zip(&self, files: &[(&str, &[u8])]) -> PathBuf {
            let path = self.repo.join("game.zip");
            let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
            for &(name, bytes) in files {
                writer.start_file(name, SimpleFileOptions::default()).unwrap();
                writer.write_all(bytes).unwrap();
            }
            writer.finish().unwrap();
            path
        }
        fn draft(&self, path: &Path, version: &str, update: bool) {
            draft_with_root_mode(&self.root(), &path.display().to_string(), "my-game",
                "My Game", version,
                "https://github.com/owner/repo/releases/download/v2/game.zip",
                &self.repo.join("cover.png").display().to_string(),
                "Game.exe", None, update).unwrap();
        }
        fn promoted(&self) {
            let zip = self.zip(&[("Game.exe", b"old-game"), ("config/game.ini", b"fullscreen=true")]);
            self.draft(&zip, "1.2.0", false);
            promote_with_root(&self.root(), "my-game", true, &zip.display().to_string()).unwrap();
        }
    }
    impl Drop for TestRepo {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.repo); }
    }

    #[test]
    fn offline_new_package_seals_verified_zip_and_coco2_consumer_metadata() {
        let fix = TestRepo::new();
        let zip = fix.zip(&[("Game.exe", b"verified"), ("UnityPlayer.dll", b"dll"),
            ("docs/readme.txt", b"documentation")]);
        fix.draft(&zip, "1.0.0", false);
        let original = fs::read(fix.source()).unwrap();
        let before = preview(&fix.root(), "my-game", &zip.display().to_string()).unwrap();
        assert_eq!(before.mode, "new");
        assert!(before.changed_fields.contains(&"".to_owned()));
        assert!(!fix.root().join("publish-packages").exists());
        assert_eq!(fs::read(fix.source()).unwrap(), original);
        let mut progress = Vec::new();
        let sealed = prepare(&fix.root(), "my-game", &zip.display().to_string(),
            &before.preview_sha256, |item| progress.push(item)).unwrap();
        assert_eq!(progress.first().unwrap().phase, "preflight");
        assert!(progress.iter().any(|p| p.phase == "copying"));
        assert!(progress.iter().any(|p| p.phase == "verifying"));
        assert!(progress.iter().any(|p| p.phase == "rechecking"));
        assert!(progress.iter().any(|p| p.phase == "sealing"));
        assert_eq!(progress.last().unwrap().phase, "complete");
        assert_eq!(progress.last().unwrap().percent, Some(100.0));
        assert_eq!(sealed.status, "prepared-offline-review-only");
        assert_eq!(fs::read(&sealed.archive_path).unwrap(), fs::read(&zip).unwrap());
        assert_eq!(sha_bytes(&fs::read(&sealed.archive_path).unwrap()), before.archive_sha256);
        assert_eq!(fs::read(fix.source()).unwrap(), original);
        let manifest: Value = serde_json::from_slice(&fs::read(&sealed.manifest_path).unwrap()).unwrap();
        let consumer: Value = serde_json::from_slice(&fs::read(PathBuf::from(&sealed.artifact_path)
            .join("coco2-client-entry.json")).unwrap()).unwrap();
        let install: Value = serde_json::from_slice(&fs::read(PathBuf::from(&sealed.artifact_path)
            .join("coco2-install-manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest["published"], false);
        assert_eq!(manifest["archiveSha256"], before.archive_sha256);
        assert_eq!(consumer["workflow"], "coco-standalone");
        assert_eq!(consumer["requiredFiles"].as_array().unwrap().len(), 2);
        let typed_consumer: crate::services::catalog::Experience =
            serde_json::from_value(consumer.clone()).unwrap();
        assert_eq!(typed_consumer.executable, "Game.exe");
        assert_eq!(typed_consumer.image, "/covers/my-game.png.webp");
        assert_eq!(install["archives"][0]["sha256"], before.archive_sha256);
        assert_eq!(install["requiredFiles"][0].as_object().unwrap().len(), 3);
        assert_eq!(manifest["clientPreviewSha256"],
            sha_bytes(&fs::read(PathBuf::from(&sealed.artifact_path)
                .join("coco2-client-entry.json")).unwrap()));
        assert_eq!(manifest["installPreviewSha256"],
            sha_bytes(&fs::read(PathBuf::from(&sealed.artifact_path)
                .join("coco2-install-manifest.json")).unwrap()));
        let catalog: Value = serde_json::from_slice(&fs::read(&sealed.catalog_path).unwrap()).unwrap();
        assert_eq!(catalog["experiences"].as_array().unwrap().len(), 2);
        assert!(prepare(&fix.root(), "my-game", &zip.display().to_string(),
            &before.preview_sha256, |_| {}).is_err(), "sealed immutable path cannot be overwritten");
    }

    #[test]
    fn portable_export_contains_only_verified_review_package_and_never_overwrites() {
        let fix=TestRepo::new();
        let zip=fix.zip(&[("Game.exe",b"synthetic-test-exe"),
            ("UnityPlayer.dll",b"synthetic-dll")]);
        fix.draft(&zip,"1.0.0",false);
        let review=preview(&fix.root(),"my-game",&zip.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&zip.display().to_string(),
            &review.preview_sha256,|_|{}).unwrap();
        let exported=export_portable(&fix.root(),"my-game",&sealed.artifact_path).unwrap();
        assert!(exported.path.ends_with(".coco2pack"));
        assert_eq!(exported.status,"exported-local-untrusted-unpublished");
        let before=fs::read(&exported.path).unwrap();
        assert_eq!(sha_bytes(&before),exported.sha256);
        let mut archive=zip::ZipArchive::new(File::open(&exported.path).unwrap()).unwrap();
        assert_eq!(archive.len(),PORTABLE_PARTS.len()+2);
        for name in PORTABLE_PARTS.iter().copied().chain(["cover.png","game.zip"]){
            assert!(archive.by_name(name).is_ok(),"Missing portable member {name}");
        }
        let mut inner=Vec::new();
        archive.by_name("game.zip").unwrap().read_to_end(&mut inner).unwrap();
        assert_eq!(inner,fs::read(&sealed.archive_path).unwrap());
        assert!(export_portable(&fix.root(),"my-game",&sealed.artifact_path).is_err());
        assert_eq!(fs::read(&exported.path).unwrap(),before);
        // Even if an old sealed package is later tampered with, a second
        // export under another ID cannot bypass package provenance.
        assert!(export_portable(&fix.root(),"other-game",&sealed.artifact_path).is_err());
        assert!(export_portable(&fix.root(),"my-game",&fix.repo.display().to_string()).is_err());
    }

    #[test]
    fn v16_portable_export_rejects_renamed_sealed_package_identity(){
        let fix=TestRepo::new();
        let original=fix.zip(&[("Game.exe",b"synthetic only")]);
        fix.draft(&original,"1.0.0",false);
        let preview=preview(&fix.root(),"my-game",&original.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&original.display().to_string(),
            &preview.preview_sha256,|_|{}).unwrap();
        let old=PathBuf::from(&sealed.artifact_path);
        let original_manifest=fs::read(old.join("publish-manifest.json")).unwrap();
        let renamed=old.parent().unwrap().join(format!("my-game-{}", "e".repeat(24)));
        fs::rename(&old,&renamed).unwrap();
        assert!(export_portable(&fix.root(),"my-game",&renamed.to_string_lossy()).is_err(),
            "forged/renamed sealed directory must not inherit reviewed package identity");
        assert_eq!(fs::read(renamed.join("publish-manifest.json")).unwrap(),original_manifest,
            "read-only export failure must preserve the renamed package bytes");
    }

    #[test]
    fn v19_forged_preview_sha_with_matching_renamed_folder_never_exports(){
        let fix=TestRepo::new();
        let original=fix.zip(&[("Game.exe",b"synthetic-game")]);
        fix.draft(&original,"1.0.0",false);
        let review=preview(&fix.root(),"my-game",&original.to_string_lossy()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&original.to_string_lossy(),
            &review.preview_sha256,|_|{}).unwrap();
        let original_folder=PathBuf::from(&sealed.artifact_path);
        let manifest_file=original_folder.join("publish-manifest.json");
        let mut manifest:Value=serde_json::from_slice(&fs::read(&manifest_file).unwrap()).unwrap();
        let forged_sha="e".repeat(64);
        assert_ne!(review.preview_sha256,forged_sha);
        manifest["previewSha256"]=Value::String(forged_sha.clone());
        fs::write(&manifest_file,serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
        let disguised=original_folder.parent().unwrap().join(format!("my-game-{}",&forged_sha[..24]));
        fs::rename(&original_folder,&disguised).unwrap();
        let output=fix.repo.join("forged-identity.coco2pack");
        assert!(export_portable_to(&fix.root(),"my-game",&disguised.to_string_lossy(),
            Some(&output.to_string_lossy())).is_err(),
            "rewriting previewSha256 and renaming the stage must not forge an approved review identity");
        assert!(!output.exists(),"failed export never produces a portable destination");
        assert_eq!(fs::read(&disguised.join("publish-manifest.json")).unwrap(),
            serde_json::to_vec_pretty(&manifest).unwrap(),"source bytes are immutable on failure");
    }

    #[test]
    fn v19_inconsistent_sealed_manifest_member_names_rejected_before_friend_delivery(){
        let fix=TestRepo::new();
        let original=fix.zip(&[("Game.exe",b"synthetic-game")]);
        fix.draft(&original,"1.0.0",false);
        let review=preview(&fix.root(),"my-game",&original.to_string_lossy()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&original.to_string_lossy(),
            &review.preview_sha256,|_|{}).unwrap();
        let folder=PathBuf::from(&sealed.artifact_path);
        let manifest_file=folder.join("publish-manifest.json");
        let mut manifest:Value=serde_json::from_slice(&fs::read(&manifest_file).unwrap()).unwrap();
        manifest["archiveFile"]=Value::String("wrong-game.zip".into());
        manifest["catalogFile"]=Value::String("wrong-catalog.json".into());
        fs::write(&manifest_file,serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
        let output=fix.repo.join("bad-member-map.coco2pack");
        assert!(export_portable_to(&fix.root(),"my-game",&folder.to_string_lossy(),
            Some(&output.to_string_lossy())).is_err(),
            "a portable with manifest pointing to absent files will be rejected by recipient; reject at export");
        assert!(!output.exists(),"broken metadata must not become a shareable .coco2pack");
    }

    #[test]
    fn portable_custom_save_as_is_local_atomic_and_never_overwrites_other_files(){
        let fix=TestRepo::new();
        let archive=fix.zip(&[("Game.exe",b"synthetic-Windows-test-exe"),
            ("UnityPlayer.dll",b"synthetic-runtime")]);
        fix.draft(&archive,"1.0.0",false);
        let reviewed=preview(&fix.root(),"my-game",&archive.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&archive.display().to_string(),
            &reviewed.preview_sha256,|_|{}).unwrap();
        let export_dir=fix.repo.join("chosen-output");
        fs::create_dir(&export_dir).unwrap();
        let dest=export_dir.join("my-game-a.coco2pack");
        let exported=export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(&dest.display().to_string())).unwrap();
        assert_eq!(PathBuf::from(&exported.path),dest.canonicalize().unwrap());
        assert!(exported.path.ends_with(".coco2pack"));
        assert_eq!(sha_bytes(&fs::read(&dest).unwrap()),exported.sha256);
        let zip=zip::ZipArchive::new(File::open(&dest).unwrap()).unwrap();
        assert_eq!(zip.len(),PORTABLE_PARTS.len()+2);
        let preserved=fs::read(&dest).unwrap();
        assert!(export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(&dest.display().to_string())).is_err());
        assert_eq!(fs::read(&dest).unwrap(),preserved,
            "existing user package must never be replaced, even by valid exporter");
        for bad in ["../escape.coco2pack","wrong.zip","not-a-path", r"..\..\escape.coco2pack"]{
            let candidate=if bad.starts_with("..") {export_dir.join(bad).display().to_string()}
                else{bad.to_owned()};
            assert!(export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
                Some(&candidate)).is_err(),"Save As path should fail closed: {candidate}");
        }
        #[cfg(windows)]
        assert!(export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(r"\\server\share\example.coco2pack")).is_err());
        let missing_dir=fix.repo.join("no-such-save-as-parent").join("file.coco2pack");
        assert!(export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(&missing_dir.display().to_string())).is_err());
        let protected=PathBuf::from(&sealed.artifact_path).join("intruder.coco2pack");
        assert!(export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(&protected.display().to_string())).is_err());
        assert!(!protected.exists());
        assert_eq!(fs::read(&dest).unwrap(),preserved);
    }

    #[test]
    fn portable_save_as_rejects_windows_devices_and_preserves_unicode_names() {
        let fix=TestRepo::new();
        let target=fix.repo.join("SAVE AS - Unicode 漢字 💜");
        fs::create_dir(&target).unwrap();
        for name in ["CON.coco2pack","AUX.coco2pack","NUL.coco2pack",
            "PRN.coco2pack","CON .coco2pack","LPT1.coco2pack",
            "COM9.coco2pack","COM¹.coco2pack","LPT³.coco2pack",
            "CONIN$.coco2pack","CONOUT$.coco2pack"] {
            let path=target.join(name).to_string_lossy().into_owned();
            assert!(portable_destination(&target,"example",Some(&path)).is_err(),
                "A reserved Windows device cannot be a Save As target: {name}");
        }
        let good=target.join("Entrega Áé 💜 漢字 con espacios.coco2pack");
        let (validated,pin)=portable_destination(&target,"example",
            Some(&good.to_string_lossy())).unwrap();
        pin.check().unwrap();
        assert_eq!(validated,target.canonicalize().unwrap().join(good.file_name().unwrap()));
        assert!(!good.exists(),"validating a Save As path never creates the file");
    }

    #[test]
    fn portable_export_detects_late_competing_writer_cleans_stage_and_can_retry() {
        let fix=TestRepo::new();
        let zip=fix.zip(&[("Game.exe",b"synthetic-test-only")]);
        fix.draft(&zip,"1.0.0",false);
        let reviewed=preview(&fix.root(),"my-game",&zip.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&zip.display().to_string(),
            &reviewed.preview_sha256,|_|{}).unwrap();
        let export_dir=fix.repo.join("export directory 漢字");
        fs::create_dir(&export_dir).unwrap();
        let collision=export_dir.join("Paquete con espacios 💜.coco2pack");
        let selected=collision.to_string_lossy().into_owned();
        let result=portable_file_with_commit_hook(&fix.root(),"my-game",
            Path::new(&sealed.artifact_path),Some(&selected),||{
                // Synthetic competing writer inserts destination AFTER checks
                // and AFTER staging, just before MoveFileW/hard_link commit.
                fs::write(&collision,b"competing user file: do not overwrite").unwrap();
            });
        assert!(result.is_err(),"late competing destination must abort export");
        assert_eq!(fs::read(&collision).unwrap(),b"competing user file: do not overwrite");
        let mut contents=fs::read_dir(&export_dir).unwrap();
        assert_eq!(contents.next().unwrap().unwrap().path(),collision);
        assert!(contents.next().is_none(),"failed export must remove only its own stage");

        let retry=export_dir.join("Entrega FINAL 漢字 💜.coco2pack");
        let exported=export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(&retry.to_string_lossy())).unwrap();
        assert_eq!(PathBuf::from(&exported.path),retry.canonicalize().unwrap());
        assert_eq!(sha_bytes(&fs::read(&retry).unwrap()),exported.sha256);
        assert_eq!(fs::read(&collision).unwrap(),b"competing user file: do not overwrite");
        assert_eq!(zip::ZipArchive::new(File::open(&retry).unwrap()).unwrap().len(),
            PORTABLE_PARTS.len()+2);
    }

    #[cfg(windows)]
    #[test]
    fn portable_parent_and_verified_stage_handles_block_rename_and_writers() {
        let fix=TestRepo::new();
        let path=fix.repo.join("Pública - 漢字");
        let moved=fix.repo.join("Moved - 漢字");
        fs::create_dir(&path).unwrap();
        let pin=pin_portable_parent(&path).unwrap();
        assert!(fs::rename(&path,&moved).is_err(),
            "a pinned parent must not be renamed during a transfer");
        pin.check().unwrap();
        drop(pin);
        fs::rename(&path,&moved).unwrap();

        let stage=moved.join("bytes.coco2pack");
        fs::write(&stage,b"synthetic ZIP payload").unwrap();
        let handle=open_staged_portable_for_verification(&stage).unwrap();
        assert!(OpenOptions::new().write(true).open(&stage).is_err(),
            "verified staged data must not be modified while the handle is held");
        drop(handle);
        OpenOptions::new().append(true).open(&stage).unwrap().write_all(b"!").unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn portable_save_as_rejects_unc_device_and_reparse_aliases() {
        let fix=TestRepo::new();
        for remote in [r"\\server\share\game.coco2pack",
            r"\\?\C:\Windows\game.coco2pack",
            "//server/share/game.coco2pack"] {
            assert!(portable_destination(&fix.repo,"example",Some(remote)).is_err(),
                "UNC and device namespaces are not local Save As locations: {remote}");
        }
        // Symlink creation is unavailable on some managed Windows accounts;
        // a successful local alias creation must always be rejected. Every
        // path stays within the fixture and requires no registry/settings.
        let real=fix.repo.join("real local directory");
        let alias=fix.repo.join("linked alias");
        fs::create_dir(&real).unwrap();
        match std::os::windows::fs::symlink_dir(&real,&alias) {
            Ok(()) => {
                let dest=alias.join("Package 漢字.coco2pack");
                assert!(portable_destination(&fix.repo,"example",
                    Some(&dest.to_string_lossy())).is_err(),
                    "reparse-point parent cannot redirect a portable export");
                assert!(!real.join("Package 漢字.coco2pack").exists());
                eprintln!("synthetic reparse parent: rejected");
            }
            Err(error) => eprintln!("synthetic reparse parent: unavailable ({error})"),
        }
    }

    #[test]
    fn portable_export_detects_post_seal_metadata_mutation_without_file_creation() {
        let fix=TestRepo::new();
        let zip=fix.zip(&[("Game.exe",b"safe-test")]);
        fix.draft(&zip,"1.0.0",false);
        let reviewed=preview(&fix.root(),"my-game",&zip.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&zip.display().to_string(),
            &reviewed.preview_sha256,|_|{}).unwrap();
        fs::write(&sealed.cover_path,b"tampered-cover").unwrap();
        assert!(export_portable(&fix.root(),"my-game",&sealed.artifact_path).is_err());
        let packages=Path::new(&sealed.artifact_path).parent().unwrap();
        assert_eq!(fs::read_dir(packages).unwrap().count(),1);
    }

    #[test]
    fn portable_export_rejects_same_size_zip_mutation_without_destination_or_staging(){
        let fix=TestRepo::new();
        let zip=fix.zip(&[("Game.exe",b"original test payload")]);
        fix.draft(&zip,"1.0.0",false);
        let reviewed=preview(&fix.root(),"my-game",&zip.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&zip.display().to_string(),
            &reviewed.preview_sha256,|_|{}).unwrap();
        let mut bytes=fs::read(&sealed.archive_path).unwrap();
        let original_len=bytes.len();
        let offset=bytes.len()/2;
        bytes[offset]^=0x01;
        fs::write(&sealed.archive_path,&bytes).unwrap();
        assert_eq!(fs::metadata(&sealed.archive_path).unwrap().len(),original_len as u64);
        let destination=fix.repo.join("tampered should never export.coco2pack");
        let outcome=export_portable_to(&fix.root(),"my-game",&sealed.artifact_path,
            Some(&destination.to_string_lossy()));
        assert!(outcome.unwrap_err().contains("Sealed archive content changed"));
        assert!(!destination.exists());
        assert_eq!(fs::read(&sealed.archive_path).unwrap(),bytes,
            "a failing export must not rewrite the changed source ZIP");
        assert_eq!(fs::read_dir(fix.repo.join("launcher2/publish-packages")).unwrap().count(),1);
    }

    #[test]
    fn two_concurrent_save_as_writers_commit_once_and_preserve_other_artifacts(){
        let fix=TestRepo::new();
        let zip=fix.zip(&[("Game.exe",b"offline-executable-placeholder"),
            ("UnityPlayer.dll",b"offline-support-placeholder")]);
        fix.draft(&zip,"1.0.0",false);
        let reviewed=preview(&fix.root(),"my-game",&zip.display().to_string()).unwrap();
        let sealed=prepare(&fix.root(),"my-game",&zip.display().to_string(),
            &reviewed.preview_sha256,|_|{}).unwrap();
        let output=fix.repo.join("SAVE AS simultáneo Áé 💜");
        fs::create_dir(&output).unwrap();
        let target=output.join("Comparten nombre 漢字.coco2pack");
        let sealed_path=sealed.artifact_path.clone();
        let repo_root=fix.root();
        let selected=target.to_string_lossy().into_owned();
        let gate=Arc::new(std::sync::Barrier::new(3));
        let workers=(0..2).map(|_|{
            let gate=gate.clone();
            let sealed_path=sealed_path.clone();
            let repo_root=repo_root.clone();
            let selected=selected.clone();
            std::thread::spawn(move||{
                gate.wait();
                export_portable_to(&repo_root,"my-game",&sealed_path,Some(&selected))
            })
        }).collect::<Vec<_>>();
        gate.wait();
        let results=workers.into_iter().map(|worker|worker.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result|result.is_ok()).count(),1,
            "exactly one simultaneous Save As may create the shared target");
        assert_eq!(results.iter().filter(|result|result.is_err()).count(),1);
        let winner=results.into_iter().find_map(Result::ok).unwrap();
        let contents=fs::read(&target).unwrap();
        assert_eq!(sha_bytes(&contents),winner.sha256);
        let mut archived=zip::ZipArchive::new(std::io::Cursor::new(contents)).unwrap();
        assert!(archived.by_name("game.zip").is_ok(),"winning portable must be self contained");
        assert_eq!(fs::read_dir(&output).unwrap().count(),1,
            "losing writer must clean its own stage and keep winning delivery");
        assert_eq!(fs::read(&sealed.archive_path).unwrap(),fs::read(&zip).unwrap(),
            "simultaneous exports must never mutate input ZIP or its sealed copy");
    }

    #[test]
    fn actual_host_publisher_portable_to_independent_client_native_catalog_import() {
        let host=TestRepo::new();
        let original=host.zip(&[("Game.exe",b"synthetic-native-game"),
            ("UnityPlayer.dll",b"synthetic-support")]);
        host.draft(&original,"1.0.0",false);
        let preview=preview(&host.root(),"my-game",&original.display().to_string()).unwrap();
        let sealed=prepare(&host.root(),"my-game",&original.display().to_string(),
            &preview.preview_sha256,|_|{}).unwrap();
        let exported=export_portable(&host.root(),"my-game",&sealed.artifact_path).unwrap();

        // Separate client home, cache and private native catalog. This fixture
        // simulates File Explorer extracting a trusted transfer archive; the
        // real client then runs review+explicit consent+import unmodified.
        let client=TestRepo::new();
        let received=client.repo.join("received");
        fs::create_dir(&received).unwrap();
        let mut archive=zip::ZipArchive::new(File::open(exported.path).unwrap()).unwrap();
        for index in 0..archive.len(){
            let mut item=archive.by_index(index).unwrap();
            assert!(!item.is_dir());
            let safe=safe_path(item.name(),false).unwrap();
            assert!(!safe.contains('/'),"portable archive must be flat");
            let mut out=File::create(received.join(safe)).unwrap();
            std::io::copy(&mut item,&mut out).unwrap();
        }
        let profile=client.repo.join("client-profile/catalog");
        let cache=client.repo.join("client-profile/downloads/standalone-packs");
        let review=crate::services::catalog::test_api::review(&profile,&received).unwrap();
        assert_eq!(review.id,"my-game");
        assert_eq!(review.new_version,"1.0.0");
        assert!(crate::services::catalog::test_api::import(&profile,&cache,&received,
            &"0".repeat(64)).is_err(),"unreviewed import is forbidden");
        let accepted=crate::services::catalog::test_api::import(&profile,&cache,&received,
            &review.review_token).unwrap();
        assert_eq!(accepted.status,"updated");
        assert_eq!(accepted.local_entries,1);
        let manifest=crate::services::catalog::test_api::manifest(&profile,"my-game",None)
            .unwrap().unwrap();
        let data:Value=serde_json::from_str(&manifest).unwrap();
        assert_eq!(data["version"],"1.0.0");
        let cached=cache.join(format!("{}.zip",review.archive_sha256));
        assert_eq!(sha_bytes(&fs::read(cached).unwrap()),review.archive_sha256);
        let origin=crate::services::catalog::test_api::provenance(&profile).unwrap();
        assert!(origin.iter().any(|p|p.id=="my-game"&&p.source=="local"));
    }

    #[test]
    fn v16_friend_optional_cover_unicode_save_as_review_token_and_idempotent_direct_import(){
        let host=TestRepo::new();
        let original=host.zip(&[("Game.exe",b"fixture executable placeholder"),
            ("UnityPlayer.dll",b"fixture support placeholder")]);
        let source_sha=scan_path(&original.to_string_lossy()).unwrap().inspection.sha256;
        let url="https://github.com/owner/repo/releases/download/v1/test-game.zip";
        let draft=draft_with_root_mode(&host.root(),&original.to_string_lossy(),
            "friend-game","Friend Game","1.0.0",url,"","Game.exe",Some(&source_sha),false)
            .unwrap();
        assert!(Path::new(&draft.cover_path).is_file());
        assert_eq!(fs::read(&draft.cover_path).unwrap(),neutral_cover_png());
        let preview=preview(&host.root(),"friend-game",&original.to_string_lossy()).unwrap();
        let sealed=prepare(&host.root(),"friend-game",&original.to_string_lossy(),
            &preview.preview_sha256,|_|{}).unwrap();
        let save_dir=host.repo.join("Enviar a amistad Áé 漢字 💜");
        fs::create_dir(&save_dir).unwrap();
        let save_as=save_dir.join("Juego entre amigos 💜.coco2pack");
        let saved=export_portable_to(&host.root(),"friend-game",&sealed.artifact_path,
            Some(&save_as.to_string_lossy())).unwrap();
        assert_eq!(saved.status,"exported-local-untrusted-unpublished");
        assert_eq!(fs::read(&save_as).unwrap().len() as u64,saved.size);
        assert_eq!(sha_bytes(&fs::read(&save_as).unwrap()),saved.sha256);
        assert!(export_portable_to(&host.root(),"friend-game",&sealed.artifact_path,
            Some(&save_as.to_string_lossy())).is_err(),"Save As cannot overwrite a delivery");

        let friend=TestRepo::new();
        let profile=friend.repo.join("friend profile/catalog");
        let cache=friend.repo.join("friend profile/archives");
        let review=crate::services::catalog::test_api::review(&profile,&save_as).unwrap();
        assert_eq!(review.id,"friend-game");
        assert_eq!(review.executable,"Game.exe");
        assert_eq!(review.archive_sha256,source_sha);
        assert_eq!(review.portable_sha256.as_deref(),Some(saved.sha256.as_str()));
        assert!(review.cover_data_url.starts_with("data:image/png;base64,"));
        assert!(!profile.join("current.json").exists(),
            "portable review never automatically imports a friend's package");
        assert!(crate::services::catalog::test_api::import(&profile,&cache,&save_as,
            &"0".repeat(64)).is_err(),"unreviewed token cannot write local catalog");
        assert!(!profile.join("current.json").exists());
        let first=crate::services::catalog::test_api::import(&profile,&cache,&save_as,
            &review.review_token).unwrap();
        assert_eq!(first.status,"updated");
        assert_eq!(first.local_entries,1);
        let pointer=fs::read(profile.join("current.json")).unwrap();
        assert_eq!(crate::services::catalog::test_api::import(&profile,&cache,&save_as,
            &review.review_token).unwrap().status,"unchanged");
        let again=crate::services::catalog::test_api::review(&profile,&save_as).unwrap();
        assert_eq!(again.status,"unchanged");
        assert_eq!(crate::services::catalog::test_api::import(&profile,&cache,&save_as,
            &again.review_token).unwrap().status,"unchanged");
        assert_eq!(fs::read(profile.join("current.json")).unwrap(),pointer,
            "repeat consent and import must not rewrite snapshot or provenance");
        assert_eq!(sha_bytes(&fs::read(cache.join(format!("{source_sha}.zip"))).unwrap()),source_sha);
        let origin=crate::services::catalog::test_api::provenance(&profile).unwrap();
        assert!(origin.iter().any(|entry|entry.id=="friend-game"&&entry.source=="local"));
        assert_eq!(fs::read(&save_as).unwrap().len() as u64,saved.size,
            "a friend's import must never mutate delivered portable bytes");
        println!("COCO2_FRIEND_PATH_V16_PASS optional_cover=1 unicode_save_as=1 token=1 idempotent=1 local_provenance=1");
    }

    #[test]
    fn existing_game_has_monotonic_review_only_update_and_originals_remain() {
        let fix = TestRepo::new();
        fix.promoted();
        let catalog_before = fs::read(fix.source()).unwrap();
        let installed_lock = fs::read(fix.repo.join("launcher/experiences/my-game.lock.json")).unwrap();
        let installed_cover = fs::read(fix.repo.join("assets/experiences/my-game.png")).unwrap();
        let zip = fix.zip(&[("Game.exe", b"new-game-v2"), ("UnityPlayer.dll", b"updated-support")]);
        // Old immutable new-game draft exists; updates use their own directory.
        fix.draft(&zip, "1.3.0", true);
        assert!(fix.root().join("drafts/my-game").is_dir());
        assert!(fix.root().join("update-drafts/my-game").is_dir());
        let review = preview(&fix.root(), "my-game", &zip.display().to_string()).unwrap();
        assert_eq!(review.mode, "update");
        assert_eq!(review.old_version.as_deref(), Some("1.2.0"));
        assert_eq!(review.new_version, "1.3.0");
        assert!(review.changed_fields.iter().any(|s| s.contains("pack")));
        let result = prepare(&fix.root(), "my-game", &zip.display().to_string(),
            &review.preview_sha256, |_| {}).unwrap();
        let merged: Value = serde_json::from_slice(&fs::read(result.catalog_path).unwrap()).unwrap();
        assert_eq!(merged["experiences"].as_array().unwrap().len(), 2);
        assert_eq!(merged["experiences"][1]["pack"]["version"], "1.3.0");
        assert_eq!(fs::read(fix.source()).unwrap(), catalog_before);
        assert_eq!(fs::read(fix.repo.join("launcher/experiences/my-game.lock.json")).unwrap(), installed_lock);
        assert_eq!(fs::read(fix.repo.join("assets/experiences/my-game.png")).unwrap(), installed_cover);
        assert!(check_standalone_update(&merged["experiences"][1], "my-game", "1.2.0").is_err());
        assert!(check_standalone_update(&merged["experiences"][1], "my-game", "1.3.0").is_err());
    }

    #[test]
    fn reject_archive_credentials_unsafe_paths_and_mutated_original() {
        let fix = TestRepo::new();
        let secret = fix.zip(&[("Game.exe", b"exe"),
            ("settings/config.json", br#"{"private_key":"test"}"#)]);
        fix.draft(&secret, "1.0", false);
        assert!(preview(&fix.root(), "my-game", &secret.display().to_string()).is_err());
        let harmless = fix.zip(&[("Game.exe", b"exe"), ("notes.txt", b"normal")]);
        let old_draft = fix.root().join("drafts/my-game");
        let draft_sha = fs::read(old_draft.join("catalog-candidate.json")).unwrap();
        assert!(preview(&fix.root(), "my-game", &harmless.display().to_string()).is_err(),
            "source ZIP must still match immutable draft digest");
        assert_eq!(fs::read(old_draft.join("catalog-candidate.json")).unwrap(), draft_sha);
        let other = TestRepo::new();
        let zip = other.zip(&[("Game.exe", b"good"), ("id_rsa", b"unsafe")]);
        other.draft(&zip, "1.0.0", false);
        assert!(preview(&other.root(), "my-game", &zip.display().to_string()).is_err());
    }

    #[test]
    fn credential_screen_handles_large_text_and_chunk_boundaries() {
        let fix = TestRepo::new();
        let clean = vec![b'a'; 3 * 1024 * 1024];
        let zip = fix.zip(&[("Game.exe", b"exe"), ("words.txt", &clean)]);
        inspect_archive_secrets(&mut File::open(&zip).unwrap()).unwrap();
        let mut secret = vec![b'a'; 64 * 1024 - 4];
        secret.extend_from_slice(b"github_pat_example");
        let zip = fix.zip(&[("Game.exe", b"exe"), ("words.txt", &secret)]);
        assert!(inspect_archive_secrets(&mut File::open(&zip).unwrap()).is_err());
    }

    #[test]
    fn stale_preview_and_catalog_cas_abort_without_leaving_package() {
        let fix = TestRepo::new();
        let zip = fix.zip(&[("Game.exe", b"verified")]);
        fix.draft(&zip, "1.0.0", false);
        let review = preview(&fix.root(), "my-game", &zip.display().to_string()).unwrap();
        assert!(prepare(&fix.root(), "my-game", &zip.display().to_string(),
            &"0".repeat(64), |_| {}).is_err());
        let catalog = fix.source();
        let result = prepare_with_hook(&fix.root(), "my-game", &zip.display().to_string(),
            &review.preview_sha256, || {
                OpenOptions::new().append(true).open(&catalog).unwrap().write_all(b" ").unwrap();
            }, |_| {});
        assert!(result.unwrap_err().contains("changed while staging"));
        let packages = fix.root().join("publish-packages");
        assert_eq!(fs::read_dir(packages).unwrap().count(), 0, "staging was removed");
        assert!(fs::read(catalog).unwrap().ends_with(b" "));
    }

    #[test]
    fn native_copy_reports_exact_chunk_bytes_and_verifies_without_buffering_whole_file() {
        let fix = TestRepo::new();
        let src = fix.repo.join("chunk-fixture.zip");
        let dst = fix.repo.join("sealed-fixture.zip");
        // At least two complete blocks plus an uneven final block.
        let content = vec![0x5Au8; COPY_CHUNK_BYTES * 2 + 137];
        fs::write(&src, &content).unwrap();
        let sha = sha_bytes(&content);
        let total = content.len() as u64;
        let mut events = Vec::new();
        copy_verified_archive(&src, &dst, total, &sha, "my-game", &mut |event| {
            events.push(event);
        }).unwrap();
        assert_eq!(fs::read(&dst).unwrap(), content);
        for phase in ["copying", "verifying"] {
            let bytes: Vec<u64> = events.iter().filter(|p| p.phase == phase)
                .map(|p| {
                    assert_eq!(p.id, "my-game");
                    assert_eq!(p.total_bytes, total);
                    assert_eq!(p.percent, Some(p.processed_bytes as f64 * 100.0 / total as f64));
                    p.processed_bytes
                }).collect();
            assert_eq!(bytes, vec![
                0, COPY_CHUNK_BYTES as u64, (COPY_CHUNK_BYTES * 2) as u64, total
            ]);
        }
        assert_eq!(events.first().unwrap().phase, "copying");
        assert_eq!(events.last().unwrap().phase, "verifying");
        assert_eq!(events.last().unwrap().percent, Some(100.0));
        let unknown = StandalonePublishProgress::unknown("my-game", "sealing");
        assert_eq!((unknown.processed_bytes, unknown.total_bytes, unknown.percent), (0, 0, None));
    }
}
