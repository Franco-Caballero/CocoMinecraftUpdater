//! Native standalone pack intake. No PowerShell, networking, installs or game execution.
//! ZIP and cover come from a frontend file-picker; all reads remain local and read-only.
//! Drafts are immutable proposals under launcher2/drafts/<id>, never catalog mutations.
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[path = "host_publish.rs"]
mod host_publish;
pub use host_publish::{StandalonePublishPreview, StandalonePublishArtifact,PortablePublishArtifact};

const MAX_ARCHIVE_BYTES: u64 = 128 * 1024 * 1024 * 1024;
const MAX_EXPANDED_BYTES: u64 = 128 * 1024 * 1024 * 1024;
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024 * 1024;
const MAX_ENTRIES: usize = 150_000;
const MAX_REQUIRED: usize = 128;
const MAX_COVER_BYTES: u64 = 20 * 1024 * 1024;
const MAX_JSON_BYTES: u64 = 12 * 1024 * 1024;

const SUPPORT_NAMES: &[&str] = &[
    "unityplayer.dll", "gameassembly.dll", "winmm.dll", "onlinefix.dll",
    "onlinefix64.dll", "steam_api.dll", "steam_api64.dll",
    "eossdk-win64-shipping.dll", "eossdk-win32-shipping.dll",
    "custom.dll", "unitycrashhandler64.exe",
];

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandaloneArchiveInspection {
    pub suggested_id: String,
    pub suggested_name: String,
    pub executables: Vec<String>,
    pub files_count: usize,
    pub uncompressed_bytes: u64,
    pub archive_size: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandaloneDraft {
    pub id: String,
    pub draft_path: String,
    pub catalog_candidate_path: String,
    pub source_lock_path: String,
    pub cover_path: String,
    pub required_files_count: usize,
    pub archive_sha256: String,
    pub next_action: String,
}

/// Review data is read-only. A positive review does not upload an archive or
/// prove copyright/redistribution rights; that decision belongs to the host.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandalonePromotionReview {
    pub id: String,
    pub name: String,
    pub version: String,
    pub catalog_sha256: String,
    pub archive_sha256: String,
    pub archive_size: u64,
    pub required_files_count: usize,
    pub source_zip_path: String,
    pub source_archive_url: String,
    pub cover_target: String,
    pub lock_target: String,
    pub catalog_target: String,
    pub status: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandalonePromotionResult {
    pub id: String,
    pub status: &'static str,
    pub catalog_sha256_before: String,
    pub catalog_sha256_after: String,
    pub catalog_path: String,
    pub source_lock_path: String,
    pub cover_path: String,
}

static PROMOTION_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Debug)]
struct ArchiveEntry {
    index: usize,
    path: String,
    size: u64,
    directory: bool,
}

struct Scanned {
    inspection: StandaloneArchiveInspection,
    entries: Vec<ArchiveEntry>,
}

fn valid_id(id: &str) -> bool {
    (2..=48).contains(&id.len())
        && id.bytes().next().is_some_and(|c| c.is_ascii_lowercase())
        && id.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
        && !id.ends_with('-')
}

fn safe_path(path: &str, directory: bool) -> Result<String, String> {
    if path.is_empty() || path.len() > 1024 || path.starts_with('/')
        || path.contains('\\') || path.contains(':') || path.chars().any(char::is_control)
        || directory != path.ends_with('/')
    {
        return Err(format!("Unsafe ZIP destination: {path}"));
    }
    let name = if directory { &path[..path.len() - 1] } else { path };
    let parts: Vec<_> = name.split('/').collect();
    for part in &parts {
        if part.is_empty() || matches!(*part, "." | "..") || part.ends_with('.')
            || part.ends_with(' ')
            || part.chars().any(|c| "<>\"|?*".contains(c))
        {
            return Err(format!("Unsafe ZIP path component: {path}"));
        }
        let stem = part.split('.').next().unwrap_or("").trim_end_matches(' ')
            .to_ascii_uppercase();
        // Win32 also reserves superscript one/two/three variants, even in
        // Unicode ZIP members and even when followed by an extension.
        // Allowing them at review time creates unextractable or ambiguous
        // paths on the eventual Windows client.
        if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$")
            || ["COM","LPT"].iter().any(|prefix|{
                stem.strip_prefix(prefix).is_some_and(|number|
                    ["1","2","3","4","5","6","7","8","9","¹","²","³"].contains(&number))
            })
        {
            return Err(format!("Reserved Windows file: {path}"));
        }
        if matches!(part.to_ascii_lowercase().as_str(),
            "saves" | "playerdata" | "advancements" | "stats"
            | "distanthorizons" | "distant_horizons" | "dh")
        {
            return Err(format!("Persisted player data in ZIP: {path}"));
        }
    }
    if parts.first().is_some_and(|p| p.eq_ignore_ascii_case(".coco")) {
        return Err("ZIP contains installer-owned metadata".into());
    }
    Ok(name.to_owned())
}

fn no_links(path: &Path) -> Result<(), String> {
    for current in path.ancestors() {
        match fs::symlink_metadata(current) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err("A symbolic link in a file path is not allowed".into());
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err("A Windows reparse-point path is not allowed".into());
                    }
                }
                if current == path && !metadata.is_file() && !metadata.is_dir() {
                    return Err("Unsupported path type".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Unable to inspect file path".into()),
        }
    }
    Ok(())
}

// A canonicalized path is not a stable destination by itself: an unrelated
// process can rename its directory and substitute a junction between the
// reparse check and ZIP read / draft staging / promotion. Keep read-only
// handles to *every* renameable ancestor for the duration of those operations.
// FILE_SHARE_READ | FILE_SHARE_WRITE permits normal writes within a directory,
// but excludes delete sharing, so Win32 denies rename/reparent of the pinned
// directory. Never follow a reparse point while acquiring a handle.
#[cfg(windows)]
struct SourceParentPin(Vec<(PathBuf, File)>);
#[cfg(windows)]
impl SourceParentPin {
    fn check(&self) -> Result<(), String> {
        use std::os::windows::fs::MetadataExt;
        for (path, handle) in &self.0 {
            let meta = handle.metadata().map_err(|_| "Cannot inspect pinned source parent")?;
            if !meta.is_dir() || meta.file_attributes() & 0x400 != 0 {
                return Err("Source or destination parent became a reparse point".into());
            }
            no_links(path)?;
        }
        Ok(())
    }
}
#[cfg(windows)]
fn pin_source_parent(path: &Path) -> Result<SourceParentPin, String> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    const FILE_SHARE_READ_WRITE: u32 = 0x0000_0003;
    let parent = path.parent().ok_or("Source or destination has no parent")?;
    let ancestors = parent.ancestors().filter(|item| item.parent().is_some())
        .collect::<Vec<_>>();
    let mut held = Vec::with_capacity(ancestors.len());
    for part in ancestors.into_iter().rev() {
        no_links(part)?;
        let mut options = OpenOptions::new();
        options.read(true).share_mode(FILE_SHARE_READ_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
        let handle = options.open(part)
            .map_err(|e| format!("Cannot pin source/destination parent against rename: {e}"))?;
        let meta = handle.metadata().map_err(|_| "Cannot inspect pinned parent handle")?;
        if !meta.is_dir() || meta.file_attributes() & 0x400 != 0 {
            return Err("Source or destination parent includes a reparse point".into());
        }
        held.push((part.to_owned(), handle));
    }
    let guard = SourceParentPin(held);
    guard.check()?;
    Ok(guard)
}
#[cfg(not(windows))]
struct SourceParentPin(PathBuf);
#[cfg(not(windows))]
impl SourceParentPin {
    fn check(&self) -> Result<(), String> { no_links(&self.0) }
}
#[cfg(not(windows))]
fn pin_source_parent(path: &Path) -> Result<SourceParentPin, String> {
    let guard = SourceParentPin(path.parent().ok_or("Source has no parent")?.to_owned());
    guard.check()?;
    Ok(guard)
}

fn canonical_file(value: &str, kind: &str) -> Result<PathBuf, String> {
    if value.is_empty() || value.contains("://") {
        return Err(format!("{kind}: select an existing local file"));
    }
    #[cfg(windows)]
    if value.starts_with(r"\\") {
        // These are inputs selected as LOCAL packs, not remote SMB/UNC downloads.
        return Err(format!("{kind}: network shares and device paths are not local ZIP sources"));
    }
    let input = Path::new(value);
    if !input.is_absolute() {
        return Err(format!("{kind}: an absolute file-picker path is required"));
    }
    no_links(input)?;
    let path = input.canonicalize().map_err(|_| format!("{kind}: local file not found"))?;
    no_links(&path)?;
    if !fs::metadata(&path).map_err(|_| format!("{kind}: inaccessible"))?.is_file() {
        return Err(format!("{kind}: expected a regular file"));
    }
    Ok(path)
}

fn hash_reader(reader: &mut impl Read, max: u64) -> Result<(String, u64), String> {
    let mut hasher = Sha256::new();
    let mut size = 0u64;
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = reader.read(&mut buffer).map_err(|_| "Cannot read or decompress source file")?;
        if count == 0 { break; }
        size = size.checked_add(count as u64).ok_or("Source size overflow")?;
        if size > max { return Err("Source exceeds allowed size budget".into()); }
        hasher.update(&buffer[..count]);
    }
    Ok((format!("{:x}", hasher.finalize()), size))
}

fn read_zip(file: &mut File, archive_name: &str) -> Result<Scanned, String> {
    let archive_size = file.metadata().map_err(|_| "Cannot read archive metadata")?.len();
    if !(22..=MAX_ARCHIVE_BYTES).contains(&archive_size) {
        return Err("Archive is empty or exceeds size budget".into());
    }
    file.seek(SeekFrom::Start(0)).map_err(|_| "Cannot seek archive")?;
    let (sha256, actual) = hash_reader(file, MAX_ARCHIVE_BYTES)?;
    if actual != archive_size { return Err("Archive changed during inspection".into()); }
    file.seek(SeekFrom::Start(0)).map_err(|_| "Cannot reopen archive")?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| "Invalid ZIP archive")?;
    if zip.len() == 0 || zip.len() > MAX_ENTRIES {
        return Err("Invalid ZIP entry count".into());
    }
    let mut seen = HashSet::new();
    let mut spellings = HashMap::<String, String>::new();
    let mut entries = Vec::with_capacity(zip.len());
    let mut expanded = 0u64;
    let mut files_count = 0usize;
    let mut executables = Vec::new();
    for index in 0..zip.len() {
        let item = zip.by_index(index).map_err(|_| "Cannot read ZIP entry")?;
        let directory = item.is_dir();
        let path = safe_path(item.name(), directory)?;
        let key = path.to_lowercase();
        if !seen.insert(key.clone()) {
            return Err(format!("Duplicate ZIP path on Windows: {path}"));
        }
        if directory {
            if let Some(other) = spellings.insert(key, path.clone()) {
                if other != path {
                    return Err(format!("ZIP directory casing conflict: {path}"));
                }
            }
        }
        let mode = item.unix_mode().unwrap_or(0);
        let file_type = mode & 0o170000;
        if !matches!(file_type, 0 | 0o040000 | 0o100000)
            || (directory && file_type == 0o100000)
            || (!directory && file_type == 0o040000)
        {
            return Err(format!("ZIP link or special file is not supported: {path}"));
        }
        if item.size() > MAX_FILE_BYTES { return Err("ZIP entry exceeds file budget".into()); }
        if !directory && item.size() > 64 * 1024 * 1024
            && (item.compressed_size() == 0
                || item.size() / item.compressed_size().max(1) > 1000)
        {
            return Err(format!("ZIP expansion ratio is unsafe: {path}"));
        }
        let segments: Vec<&str> = path.split('/').collect();
        let mut parent = String::new();
        for segment in segments.iter().take(segments.len().saturating_sub(1)) {
            if !parent.is_empty() { parent.push('/'); }
            parent.push_str(segment);
            let lookup = parent.to_lowercase();
            if let Some(other) = spellings.insert(lookup, parent.clone()) {
                if other != parent {
                    return Err(format!("ZIP directory casing conflict: {parent}"));
                }
            }
        }
        if !directory {
            files_count += 1;
            expanded = expanded.checked_add(item.size()).ok_or("Uncompressed byte count overflow")?;
            if expanded > MAX_EXPANDED_BYTES { return Err("ZIP exceeds uncompressed size budget".into()); }
            if path.to_ascii_lowercase().ends_with(".exe") {
                executables.push(path.clone());
            }
        }
        entries.push(ArchiveEntry { index, path, size: item.size(), directory });
    }
    let all_file_keys: HashSet<String> = entries.iter()
        .filter(|entry| !entry.directory).map(|entry| entry.path.to_lowercase()).collect();
    for entry in &entries {
        let mut name = entry.path.as_str();
        while let Some((parent, _)) = name.rsplit_once('/') {
            if all_file_keys.contains(&parent.to_lowercase()) {
                return Err(format!("File used as ZIP directory: {parent}"));
            }
            name = parent;
        }
    }
    executables.sort();
    let suggested_name = archive_name.rsplit_once('.').map(|(stem, _)| stem)
        .unwrap_or(archive_name).replace(['-', '_', '.'], " ");
    let mut suggested_name = suggested_name.trim().chars().take(120).collect::<String>();
    if suggested_name.is_empty() { suggested_name = "New Standalone".into(); }
    let mut suggested_id = String::new();
    for ch in suggested_name.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            suggested_id.push(ch);
        } else if !suggested_id.is_empty() && !suggested_id.ends_with('-') {
            suggested_id.push('-');
        }
        if suggested_id.len() >= 48 { break; }
    }
    while suggested_id.ends_with('-') { suggested_id.pop(); }
    if !valid_id(&suggested_id) { suggested_id = "new-standalone".into(); }
    Ok(Scanned {
        inspection: StandaloneArchiveInspection {
            suggested_id, suggested_name, executables, files_count,
            uncompressed_bytes: expanded, archive_size, sha256,
        },
        entries,
    })
}

fn scan_path(zip_path: &str) -> Result<Scanned, String> {
    let archive = canonical_file(zip_path, "ZIP")?;
    if archive.extension().and_then(|s| s.to_str()).map(|v| v.eq_ignore_ascii_case("zip")) != Some(true) {
        return Err("Select a local .zip file".into());
    }
    let _stable_parent = pin_source_parent(&archive)?;
    no_links(&archive)?;
    let mut file = open_local_source(&archive)?;
    let name = archive.file_name().and_then(|v| v.to_str()).unwrap_or("New Game.zip");
    read_zip(&mut file, name)
}

/// Deny concurrent writers on Windows for the entire inspection. This avoids a
/// second full hash of multi-gigabyte ZIPs while guaranteeing stable bytes on NTFS.
/// On other platforms we rehash after extracting the selected required files.
fn open_local_source(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(0x00000001); // FILE_SHARE_READ; no writers or rename/delete
    }
    options.open(path).map_err(|_| "Cannot open local source for read-only inspection".into())
}

fn cover_kind(path: &Path) -> Result<&'static str, String> {
    let ext = path.extension().and_then(|v| v.to_str()).unwrap_or("").to_ascii_lowercase();
    let file = File::open(path).map_err(|_| "Cannot read selected cover")?;
    let size = file.metadata().map_err(|_| "Cannot stat cover")?.len();
    if !(12..=MAX_COVER_BYTES).contains(&size) { return Err("Cover has invalid size".into()); }
    let mut header = [0u8; 12];
    let mut reader = file;
    reader.read_exact(&mut header).map_err(|_| "Cannot identify cover")?;
    let valid = match ext.as_str() {
        "png" if header.starts_with(b"\x89PNG\r\n\x1a\n") => Some("png"),
        "jpg" | "jpeg" if header.starts_with(&[0xff, 0xd8, 0xff]) => Some("jpg"),
        "webp" if &header[..4] == b"RIFF" && &header[8..12] == b"WEBP" => Some("webp"),
        _ => None,
    };
    valid.ok_or_else(|| "Cover format does not match PNG, JPEG or WebP signature".into())
}

/// Original, neutral Coco 2 placeholder artwork, drawn entirely in memory.
/// No remote assets, game artwork, fonts, user paths, licenses or external
/// encoders are involved. PNG RGB8 + deterministic zlib STORED blocks make
/// these bytes decode on every supported Windows WebView without adding a
/// compressor dependency or allowing unbounded allocations.
fn neutral_cover_png() -> Vec<u8> {
    const WIDTH: usize = 320;
    const HEIGHT: usize = 180;
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(data);
        let mut crc = !0u32;
        for byte in kind.iter().chain(data) {
            crc ^= u32::from(*byte);
            for _ in 0..8 {
                crc = if crc & 1 != 0 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
            }
        }
        out.extend_from_slice(&(!crc).to_be_bytes());
    }
    let mut pixels = Vec::with_capacity(HEIGHT * (WIDTH * 3 + 1));
    for y in 0..HEIGHT {
        pixels.push(0); // PNG filter None, one byte per scanline
        for x in 0..WIDTH {
            let dx = (x as i32 - WIDTH as i32 / 2).abs();
            let dy = (y as i32 - HEIGHT as i32 / 2).abs();
            let ring = dx * 3 + dy * 5;
            // Abstract geometric emblem, not a screenshot or brand claim.
            let rgb = if (176..=188).contains(&ring) {
                [145, 168, 207]
            } else if ring < 176 {
                [50 + (y / 20) as u8, 61 + (x / 24) as u8, 101]
            } else {
                [22 + (x / 30) as u8, 25 + (y / 22) as u8,
                    42 + ((WIDTH - 1 - x) / 16) as u8]
            };
            pixels.extend_from_slice(&rgb);
        }
    }
    let mut zlib = Vec::with_capacity(pixels.len() + pixels.len() / 65535 * 5 + 12);
    zlib.extend_from_slice(&[0x78, 0x01]); // RFC 1950 zlib, no compression
    for (index, block) in pixels.chunks(u16::MAX as usize).enumerate() {
        zlib.push(u8::from((index + 1) * u16::MAX as usize >= pixels.len()));
        let len = block.len() as u16;
        zlib.extend_from_slice(&len.to_le_bytes());
        zlib.extend_from_slice(&(!len).to_le_bytes());
        zlib.extend_from_slice(block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for byte in &pixels {
        a = (a + u32::from(*byte)) % 65521;
        b = (b + a) % 65521;
    }
    zlib.extend_from_slice(&((b << 16) | a).to_be_bytes());
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&(WIDTH as u32).to_be_bytes());
    ihdr.extend_from_slice(&(HEIGHT as u32).to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // RGB8, standard non-interlaced
    chunk(&mut png, b"IHDR", &ihdr);
    chunk(&mut png, b"IDAT", &zlib);
    chunk(&mut png, b"IEND", &[]);
    debug_assert!(png.len() as u64 <= MAX_COVER_BYTES);
    png
}

fn validate_archive_url(value: &str) -> Result<(), String> {
    let url = reqwest::Url::parse(value).map_err(|_| "Invalid ZIP archive URL")?;
    if url.scheme() != "https" || url.host_str().is_none() || url.port_or_known_default() != Some(443)
        || !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some()
        || !url.path().to_ascii_lowercase().ends_with(".zip")
    {
        return Err("Archive URL must point to a direct HTTPS ZIP without credentials or query".into());
    }
    Ok(())
}

fn launcher2_root() -> Result<PathBuf, String> {
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().and_then(Path::parent)
        .map(Path::to_path_buf).ok_or_else(|| "Cannot locate launcher2 workspace".into())
}

/// Only expose the source-authoring flow on the owner's development PC.
/// Installed clients without this checkout never receive authoring controls.
#[tauri::command]
pub fn host_studio_available() -> bool {
    let root = match launcher2_root() { Ok(root) => root, Err(_) => return false };
    let repo = match root.parent() { Some(repo) => repo, None => return false };
    repo.join("launcher/catalog.template.json").is_file()
        && root.join("desktop/src-tauri/tauri.conf.json").is_file()
        && root.join("drafts").parent().is_some()
}

fn check_catalog_id(repo: &Path, id: &str) -> Result<(), String> {
    let original = repo.join("launcher/catalog.template.json");
    let bytes = fs::read(&original).map_err(|_| "Cannot read original catalog")?;
    if bytes.len() > MAX_JSON_BYTES as usize { return Err("Source catalog exceeds size limit".into()); }
    let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| "Invalid source catalog")?;
    if value["schemaVersion"] != 1 || !value["experiences"].is_array() {
        return Err("Unsupported source catalog schema".into());
    }
    if value["experiences"].as_array().unwrap().iter()
        .any(|entry| entry["id"].as_str().is_some_and(|existing| existing.eq_ignore_ascii_case(id)))
    {
        return Err("Experience ID is already in the source catalog".into());
    }
    Ok(())
}

fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)
        .map_err(|_| "Cannot create new draft file")?;
    file.write_all(bytes).and_then(|_| file.sync_all())
        .map_err(|_| "Cannot persist new draft file".into())
}

fn write_json(path: &Path, value: &serde_json::Value) -> Result<(), String> {
    let mut text = serde_json::to_vec_pretty(value).map_err(|_| "Cannot encode draft JSON")?;
    text.push(b'\n');
    write_new(path, &text)
}

struct DraftStage(PathBuf);
impl Drop for DraftStage {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

fn create_stage(root: &Path, id: &str) -> Result<DraftStage, String> {
    for count in 0..12u8 {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH)
            .map_err(|_| "System clock unavailable")?.as_nanos();
        let name = format!(".{id}-{}-{nanos}-{count}.stage", std::process::id());
        let path = root.join(name);
        match fs::create_dir(&path) {
            Ok(()) => return Ok(DraftStage(path)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err("Cannot create private draft stage".into()),
        }
    }
    Err("No available private draft stage".into())
}

fn required_files(file: &mut File, entries: &[ArchiveEntry], executable: &str, archive_sha256: &str)
    -> Result<Vec<serde_json::Value>, String>
{
    let mut candidates = Vec::new();
    for entry in entries {
        if entry.directory { continue; }
        let file_name = entry.path.rsplit('/').next().unwrap_or("").to_ascii_lowercase();
        if entry.path.eq_ignore_ascii_case(executable) || SUPPORT_NAMES.contains(&file_name.as_str()) {
            candidates.push(entry);
        }
    }
    if !candidates.iter().any(|entry| entry.path.eq_ignore_ascii_case(executable)) {
        return Err("Selected executable is not present in the ZIP".into());
    }
    if candidates.len() > MAX_REQUIRED {
        return Err("Too many potential required executable/support files".into());
    }
    file.seek(SeekFrom::Start(0)).map_err(|_| "Cannot reopen ZIP")?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| "Cannot inspect ZIP file data")?;
    let mut required = Vec::with_capacity(candidates.len());
    for entry in candidates {
        if entry.size == 0 { return Err(format!("Required file is empty: {}", entry.path)); }
        let mut stream = zip.by_index(entry.index).map_err(|_| "Cannot open required ZIP entry")?;
        let (sha, size) = hash_reader(&mut stream, entry.size)?;
        if size != entry.size { return Err(format!("Required file is truncated: {}", entry.path)); }
        required.push(serde_json::json!({
            "path":entry.path,"sha256":sha,"size":size,
            "archiveSha256":archive_sha256
        }));
    }
    required.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    Ok(required)
}

fn draft_with_root(
    root: &Path, zip_path: &str, id: &str, name: &str, version: &str,
    archive_url: &str, cover_path: &str, executable: &str, expected_sha256: Option<&str>,
) -> Result<StandaloneDraft, String> {
    draft_with_root_mode(root, zip_path, id, name, version, archive_url,
        cover_path, executable, expected_sha256, false)
}

fn draft_with_root_mode(
    root: &Path, zip_path: &str, id: &str, name: &str, version: &str,
    archive_url: &str, cover_path: &str, executable: &str, expected_sha256: Option<&str>,
    update_existing: bool,
) -> Result<StandaloneDraft, String> {
    if !valid_id(id) || name.trim().is_empty() || name.trim().len() > 120
        || name.chars().any(char::is_control) || version.trim().is_empty()
        || version.len() > 100 || version.chars().any(char::is_control)
    {
        return Err("Invalid experience identifier, name or version".into());
    }
    let exe = safe_path(executable, false)?;
    if !exe.to_ascii_lowercase().ends_with(".exe") { return Err("Executable must be an .exe".into()); }
    validate_archive_url(archive_url)?;
    let repo = root.parent().ok_or("Cannot locate source repository")?;
    if update_existing {
        let catalog = bounded_file(&repo.join("launcher/catalog.template.json"), MAX_JSON_BYTES)?;
        let source: Value = serde_json::from_slice(&catalog).map_err(|_| "Invalid source catalog")?;
        let current = source["experiences"].as_array()
            .and_then(|entries| entries.iter().find(|entry| entry["id"] == id))
            .ok_or("Experience to update is not present in catalog")?;
        check_standalone_update(current, id, version)?;
    } else {
        check_catalog_id(repo, id)?;
    }
    let zip = canonical_file(zip_path, "ZIP")?;
    if zip.extension().and_then(|v| v.to_str()).map(|v| v.eq_ignore_ascii_case("zip")) != Some(true) {
        return Err("ZIP input must end in .zip".into());
    }
    // An exactly empty coverPath requests our original neutral PNG. Any
    // non-empty value (including whitespace, UNC, invalid MIME or traversal)
    // stays on the existing fail-closed external-file validation path.
    let explicit_cover = if cover_path.is_empty() {
        None
    } else {
        Some(canonical_file(cover_path, "cover")?)
    };
    let ext = match &explicit_cover {
        Some(cover) => cover_kind(cover)?,
        None => "png",
    };
    // Updates have their own immutable proposal namespace: the original new
    // game draft may still be retained after its earlier promotion.
    let drafts = root.join(if update_existing { "update-drafts" } else { "drafts" });
    let output = drafts.join(id);
    no_links(&drafts)?;
    no_links(&output)?;
    if output.exists() { return Err("Draft already exists; refusing to overwrite".into()); }

    let _source_parent = pin_source_parent(&zip)?;
    no_links(&zip)?;
    let mut zip_file = open_local_source(&zip)?;
    let archive_name = zip.file_name().and_then(|v| v.to_str()).unwrap_or("game.zip");
    let scanned = read_zip(&mut zip_file, archive_name)?;
    if let Some(expected) = expected_sha256 {
        if expected.len()!=64 || !expected.bytes().all(|b| b.is_ascii_hexdigit())
            || !expected.eq_ignore_ascii_case(&scanned.inspection.sha256)
        {
            return Err("El ZIP cambió desde la inspección: vuelve a seleccionarlo".into());
        }
    }
    let required = required_files(&mut zip_file, &scanned.entries, &exe, &scanned.inspection.sha256)?;
    // On Windows FILE_SHARE_READ prevents any concurrent update until this
    // handle closes; avoid hashing a large game archive twice. On Unix, rehash.
    #[cfg(not(windows))]
    {
        zip_file.seek(SeekFrom::Start(0)).map_err(|_| "Cannot verify source ZIP twice")?;
        let (second_hash, second_size) = hash_reader(&mut zip_file, MAX_ARCHIVE_BYTES)?;
        if second_hash != scanned.inspection.sha256 || second_size != scanned.inspection.archive_size {
            return Err("Source ZIP changed during inspection".into());
        }
    }
    drop(zip_file);
    let expected = &scanned.inspection;
    let cover_name = format!("cover.{ext}");
    let cover_catalog = format!("assets/experiences/{id}.{ext}");
    let candidate = serde_json::json!({
        "id":id, "name":name.trim(), "ui":{"imagePath":cover_catalog},
        "description":"Borrador de juego standalone: revisar licencia, origen y multijugador antes de publicar.",
        "instanceId":id, "managementMode":"managed",
        "runtime":{"type":"standalone","executable":exe,"requiredFiles":required},
        "pack":{"packId":format!("standalone-{id}"),
            "lockPath":format!("launcher/experiences/{id}.lock.json"),
            "version":version,
            "sha256":expected.sha256,"size":expected.archive_size,
            "archives":[{"archiveUrl":archive_url,"sha256":expected.sha256,"size":expected.archive_size}]},
        "hosting":{"mode":"p2p"},
        "launch":{"workflow":"coco-standalone","arguments":[],"autoJoin":false,
                  "serverName":format!("Coco - {}",name.trim())},
        "files":[]
    });
    let lock = serde_json::json!({
        "schemaVersion":1, "experienceId":id, "type":"standalone", "files":[],
        "archive":{"url":archive_url,"sha256":expected.sha256,"size":expected.archive_size}
    });
    if candidate["runtime"]["requiredFiles"].as_array().map_or(true, Vec::is_empty)
        || candidate["pack"]["archives"][0]["sha256"] != expected.sha256
    {
        return Err("Invalid proposed source catalog structure".into());
    }
    // Existing launcher2 directories must be real, not redirected by a junction.
    no_links(root)?;
    fs::create_dir_all(&drafts).map_err(|_| "Cannot create drafts directory")?;
    no_links(&drafts)?;
    let _draft_parent = pin_source_parent(&output)?;
    _draft_parent.check()?;
    if output.exists() { return Err("Draft already exists".into()); }
    let stage = create_stage(&drafts, id)?;
    write_json(&stage.0.join("catalog-candidate.json"), &candidate)?;
    write_json(&stage.0.join("source-lock.json"), &lock)?;
    let target_cover = stage.0.join(&cover_name);
    if let Some(cover) = explicit_cover {
        let _cover_parent = pin_source_parent(&cover)?;
        no_links(&cover)?;
        let mut input = open_local_source(&cover)?;
        let mut bytes = Vec::new();
        Read::by_ref(&mut input).take(MAX_COVER_BYTES + 1).read_to_end(&mut bytes)
            .map_err(|_| "Cannot read draft cover")?;
        if !(12..=MAX_COVER_BYTES as usize).contains(&bytes.len()) {
            return Err("Cover changed or exceeded size budget".into());
        }
        let valid = match ext {
            "png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "jpg" => bytes.starts_with(&[0xff, 0xd8, 0xff]),
            "webp" => bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP",
            _ => false,
        };
        if !valid { return Err("Cover changed during validation".into()); }
        write_new(&target_cover, &bytes)?;
    } else {
        // Generated bytes belong only to this exclusively-created staging
        // directory. No filesystem source is opened and existing assets are
        // never overwritten; final rename retains normal draft ownership.
        let image = neutral_cover_png();
        if image.len() as u64 > MAX_COVER_BYTES {
            return Err("Generated neutral cover exceeds size budget".into());
        }
        write_new(&target_cover, &image)?;
        if cover_kind(&target_cover)? != "png" {
            return Err("Generated neutral cover failed PNG preflight".into());
        }
    }
    let review = format!(
        "Coco Launcher 2 standalone proposal: {id}\n\n+        The source ZIP is LOCAL and was NOT uploaded or published.\n+        SHA256: {}\n+        Archive URL is declarative and has NOT been checked online.\n+        Verify that the eventually hosted ZIP has exactly this SHA256.\n+        Multiplayer mode p2p is a proposal; confirm gameplay, network, rights and licenses.\n\n+        1. Copy {cover_name} to assets/experiences/{id}.{ext}\n+        2. Copy source-lock.json to launcher/experiences/{id}.lock.json\n+        3. Review and merge catalog-candidate.json into launcher/catalog.template.json experiences[].\n+        4. Run source catalog validations. No publishing happened.\n",
        expected.sha256
    );
    write_new(&stage.0.join("REVIEW.txt"), review.as_bytes())?;
    _draft_parent.check()?;
    no_links(&output)?;
    // Same-volume rename is a single commit. Never remove/replace an existing draft.
    fs::rename(&stage.0, &output)
        .map_err(|_| "Cannot finalize immutable draft (possibly already exists)")?;
    let result = StandaloneDraft {
        id:id.into(),
        draft_path:output.display().to_string(),
        catalog_candidate_path:output.join("catalog-candidate.json").display().to_string(),
        source_lock_path:output.join("source-lock.json").display().to_string(),
        cover_path:output.join(&cover_name).display().to_string(),
        required_files_count:required.len(),
        archive_sha256:expected.sha256.clone(),
        next_action:"Review REVIEW.txt, copy the cover/lock, and merge catalog-candidate.json manually into the source catalog. The ZIP has not been uploaded.".into(),
    };
    Ok(result)
}

/// A version is orderable only when all components are numeric. Reject ambiguous
/// labels rather than guessing whether e.g. '1.2-beta' is newer.
fn version_parts(value: &str) -> Result<Vec<u64>, String> {
    if value.is_empty() || value.len() > 100 {
        return Err("Version must be a nonempty numeric dotted version".into());
    }
    let parts: Vec<&str> = value.split('.').collect();
    if parts.is_empty() || parts.len() > 8 || parts.iter().any(|p|
        p.is_empty() || p.len() > 18 || !p.bytes().all(|c| c.is_ascii_digit()))
    {
        return Err("Cannot safely order versions: use numeric components (e.g. 1.2.3)".into());
    }
    parts.iter().map(|p| p.parse::<u64>().map_err(|_| "Version component overflow".into())).collect()
}

fn check_standalone_update(current: &Value, id: &str, next: &str) -> Result<(), String> {
    if current["id"] != id || current["instanceId"] != id
        || current["managementMode"] != "managed"
        || current["runtime"]["type"] != "standalone"
        || current["launch"]["workflow"] != "coco-standalone"
        || current["pack"]["packId"] != format!("standalone-{id}")
        || current["pack"]["lockPath"] != format!("launcher/experiences/{id}.lock.json")
    {
        return Err("Existing experience is incompatible with standalone update contract".into());
    }
    let previous = current["pack"]["version"].as_str()
        .ok_or("Existing standalone has no version")?;
    let a = version_parts(previous)?;
    let b = version_parts(next)?;
    let width = a.len().max(b.len());
    let strictly_newer = (0..width).map(|i|
        b.get(i).copied().unwrap_or(0).cmp(&a.get(i).copied().unwrap_or(0))
    ).find(|c| *c != std::cmp::Ordering::Equal);
    if strictly_newer != Some(std::cmp::Ordering::Greater) {
        return Err(format!("New version {next} must be strictly greater than installed catalog version {previous}"));
    }
    Ok(())
}

#[tauri::command]
pub async fn inspect_standalone_archive(zip_path: String) -> Result<StandaloneArchiveInspection, String> {
    tauri::async_runtime::spawn_blocking(move || scan_path(&zip_path).map(|item| item.inspection))
        .await.map_err(|_| "Archive inspection interrupted".to_string())?
}

#[tauri::command]
pub async fn create_standalone_draft(
    zip_path: String, id: String, name: String, version: String,
    archive_url: String, cover_path: String, executable: String, expected_sha256: String,
) -> Result<StandaloneDraft, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if !host_studio_available(){return Err("Host Studio solo está disponible en el workspace del host".into());}
        let root = launcher2_root()?;
        draft_with_root(&root, &zip_path, &id, &name, &version, &archive_url, &cover_path, &executable,Some(&expected_sha256))
    }).await.map_err(|_| "Draft creation interrupted".to_string())?
}

#[tauri::command]
pub async fn create_standalone_update_draft(
    zip_path: String, id: String, name: String, version: String,
    archive_url: String, cover_path: String, executable: String, expected_sha256: String,
) -> Result<StandaloneDraft, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if !host_studio_available() { return Err("Host Studio is unavailable".into()); }
        let root = launcher2_root()?;
        draft_with_root_mode(&root, &zip_path, &id, &name, &version, &archive_url,
            &cover_path, &executable, Some(&expected_sha256), true)
    }).await.map_err(|e| format!("Update draft creation interrupted: {e}"))?
}

struct PromotionPrepared {
    review: StandalonePromotionReview,
    catalog_after: Vec<u8>,
    lock: Vec<u8>,
    cover: Vec<u8>,
}

fn sha_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn bounded_file(path: &Path, max: u64) -> Result<Vec<u8>, String> {
    no_links(path)?;
    let meta = fs::metadata(path).map_err(|_| format!("Missing source file: {}", path.display()))?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > max {
        return Err(format!("Invalid file size or type: {}", path.display()));
    }
    let mut bytes = Vec::new();
    File::open(path).map_err(|e| e.to_string())?
        .take(max + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.is_empty() || bytes.len() as u64 > max || bytes.len() as u64 != meta.len() {
        return Err("Source file changed or exceeded limit".into());
    }
    Ok(bytes)
}

fn strict_fields(value: &Value, fields: &[&str], label: &str) -> Result<(), String> {
    let object = value.as_object().ok_or_else(|| format!("{label}: object expected"))?;
    if object.len() != fields.len() || fields.iter().any(|field| !object.contains_key(*field)) {
        return Err(format!("{label}: missing or unexpected fields"));
    }
    Ok(())
}

fn required_string<'a>(value: &'a Value, name: &str) -> Result<&'a str, String> {
    value.get(name).and_then(Value::as_str).ok_or_else(|| format!("Expected string: {name}"))
}

fn valid_sha(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|c| c.is_ascii_hexdigit())
}

fn valid_catalog_catalog(bytes: &[u8], id: &str) -> Result<usize, String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| "Invalid source catalog JSON")?;
    if !value.is_object() || value["schemaVersion"] != 1 {
        return Err("Invalid source catalog schema".into());
    }
    let entries = value["experiences"].as_array().ok_or("Source catalog experiences is not an array")?;
    let mut ids = HashSet::new();
    for entry in entries {
        let entry_id = entry.get("id").and_then(Value::as_str).ok_or("Catalog entry missing ID")?;
        if !ids.insert(entry_id.to_ascii_lowercase()) {
            return Err("Duplicate source catalog ID".into());
        }
        if entry_id.eq_ignore_ascii_case(id) {
            return Err("Experience ID already exists in original source catalog".into());
        }
    }
    Ok(entries.len())
}

/// Locate only the top-level experiences array while honoring JSON quoting,
/// escape sequences, and nested objects; never serialize the whole catalog.
fn experiences_end(input: &str) -> Result<(usize, usize), String> {
    let bytes = input.as_bytes();
    let mut depth = 0usize;
    let mut index = 0usize;
    let mut key: Option<(usize, String)> = None;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => {
                let begin = index;
                index += 1;
                let mut escaped = false;
                while index < bytes.len() {
                    let ch = bytes[index];
                    if escaped { escaped = false; index += 1; continue; }
                    if ch == b'\\' { escaped = true; index += 1; continue; }
                    if ch == b'"' { break; }
                    index += 1;
                }
                if index >= bytes.len() { return Err("Unterminated catalog string".into()); }
                if depth == 1 {
                    let raw = &input[begin..=index];
                    if let Ok(value) = serde_json::from_str::<String>(raw) {
                        key = Some((index + 1, value));
                    }
                }
            }
            b'{' | b'[' => depth += 1,
            b'}' | b']' => depth = depth.checked_sub(1).ok_or("Unbalanced catalog JSON")?,
            _ => {}
        }
        if let Some((end, name)) = &key {
            if *end == index + 1 && name == "experiences" && depth == 1 {
                let mut cursor = index + 1;
                while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() { cursor += 1; }
                if cursor >= bytes.len() || bytes[cursor] != b':' { key = None; index += 1; continue; }
                cursor += 1;
                while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() { cursor += 1; }
                if cursor >= bytes.len() || bytes[cursor] != b'[' { return Err("experiences is not an array".into()); }
                let start = cursor;
                let mut nesting = 1usize;
                let mut quoted = false;
                let mut slash = false;
                cursor += 1;
                while cursor < bytes.len() {
                    let c = bytes[cursor];
                    if quoted {
                        if slash { slash = false; }
                        else if c == b'\\' { slash = true; }
                        else if c == b'"' { quoted = false; }
                    } else if c == b'"' { quoted = true; }
                    else if c == b'[' { nesting += 1; }
                    else if c == b']' {
                        nesting -= 1;
                        if nesting == 0 { return Ok((start, cursor)); }
                    }
                    cursor += 1;
                }
                return Err("Unterminated experiences array".into());
            }
        }
        index += 1;
    }
    Err("Top-level experiences array missing".into())
}

fn append_candidate(original: &[u8], candidate: &[u8], old_count: usize) -> Result<Vec<u8>, String> {
    let before = std::str::from_utf8(original).map_err(|_| "Catalog is not UTF-8")?;
    let candidate = std::str::from_utf8(candidate).map_err(|_| "Candidate is not UTF-8")?.trim();
    let (start, end) = experiences_end(before)?;
    let mut prior = end;
    while prior > start + 1 && before.as_bytes()[prior - 1].is_ascii_whitespace() { prior -= 1; }
    let newline = if before.contains("\r\n") { "\r\n" } else { "\n" };
    let candidate_formatted = candidate.lines().map(|line| format!("        {line}"))
        .collect::<Vec<_>>().join(newline);
    let insertion = format!("{}{newline}{candidate_formatted}", if old_count > 0 { "," } else { "" });
    let mut result = Vec::with_capacity(original.len() + insertion.len());
    result.extend_from_slice(&original[..prior]);
    result.extend_from_slice(insertion.as_bytes());
    result.extend_from_slice(&original[prior..]);
    if result.len() as u64 > MAX_JSON_BYTES {
        return Err("Merged catalog exceeds source size limit".into());
    }
    let merged: Value = serde_json::from_slice(&result).map_err(|_| "Merged source catalog invalid")?;
    if merged["experiences"].as_array().map(Vec::len) != Some(old_count + 1) {
        return Err("Merged catalog failed to append exactly one experience".into());
    }
    Ok(result)
}

fn prepare_promotion(root: &Path, id: &str, original_zip_path: &str) -> Result<PromotionPrepared, String> {
    prepare_promotion_mode(root, id, original_zip_path, false)
}

fn prepare_promotion_mode(root: &Path, id: &str, original_zip_path: &str,
                          update_existing: bool) -> Result<PromotionPrepared, String> {
    if !valid_id(id) { return Err("Invalid standalone draft ID".into()); }
    let repo = root.parent().ok_or("Missing repository parent")?;
    let draft = root.join(if update_existing { "update-drafts" } else { "drafts" }).join(id);
    let catalog = repo.join("launcher/catalog.template.json");
    let asset_dir = repo.join("assets/experiences");
    let locks_dir = repo.join("launcher/experiences");
    for path in [root, repo, &draft, &catalog, &asset_dir, &locks_dir] { no_links(path)?; }
    if !draft.is_dir() || !asset_dir.is_dir() || !locks_dir.is_dir() {
        return Err("Draft or source output directories not available".into());
    }
    let catalog_before = bounded_file(&catalog, MAX_JSON_BYTES)?;
    let old_count = valid_catalog_catalog(&catalog_before,
        if update_existing { "__coco_publish_check_unique_ids__" } else { id })?;
    let catalog_value: Value = serde_json::from_slice(&catalog_before)
        .map_err(|_| "Invalid catalog structure")?;
    let existing = catalog_value["experiences"].as_array()
        .and_then(|entries| entries.iter().find(|entry| entry["id"] == id));
    if update_existing && existing.is_none() {
        return Err("Existing experience is missing from source catalog".into());
    }
    let catalog_sha256 = sha_bytes(&catalog_before);
    let candidate_path = draft.join("catalog-candidate.json");
    let lock_path = draft.join("source-lock.json");
    let candidate_bytes = bounded_file(&candidate_path, 2 * 1024 * 1024)?;
    let lock_bytes = bounded_file(&lock_path, 2 * 1024 * 1024)?;
    let candidate: Value = serde_json::from_slice(&candidate_bytes).map_err(|_| "Invalid candidate JSON")?;
    let lock: Value = serde_json::from_slice(&lock_bytes).map_err(|_| "Invalid draft source-lock JSON")?;
    strict_fields(&candidate, &["id","name","ui","description","instanceId","managementMode","runtime","pack","hosting","launch","files"], "candidate")?;
    strict_fields(&candidate["ui"], &["imagePath"], "candidate.ui")?;
    strict_fields(&candidate["runtime"], &["type","executable","requiredFiles"], "candidate.runtime")?;
    strict_fields(&candidate["pack"], &["packId","lockPath","version","sha256","size","archives"], "candidate.pack")?;
    strict_fields(&candidate["hosting"], &["mode"], "candidate.hosting")?;
    strict_fields(&candidate["launch"], &["workflow","arguments","autoJoin","serverName"], "candidate.launch")?;
    strict_fields(&lock, &["schemaVersion","experienceId","type","files","archive"], "source-lock")?;
    strict_fields(&lock["archive"], &["url","sha256","size"], "source-lock.archive")?;
    if candidate["id"] != id || candidate["instanceId"] != id
        || candidate["managementMode"] != "managed" || candidate["runtime"]["type"] != "standalone"
        || candidate["hosting"]["mode"] != "p2p" || candidate["launch"]["workflow"] != "coco-standalone"
        || candidate["launch"]["autoJoin"] != false || candidate["launch"]["arguments"] != serde_json::json!([])
        || candidate["files"] != serde_json::json!([])
        || candidate["pack"]["packId"] != format!("standalone-{id}")
        || candidate["pack"]["lockPath"] != format!("launcher/experiences/{id}.lock.json")
        || lock["schemaVersion"] != 1 || lock["experienceId"] != id
        || lock["type"] != "standalone" || lock["files"] != serde_json::json!([])
    { return Err("Candidate or source-lock identity/workflow mismatch".into()); }
    let name = required_string(&candidate, "name")?;
    let version = required_string(&candidate["pack"], "version")?;
    if update_existing {
        check_standalone_update(existing.ok_or("Existing entry missing")?, id, version)?;
    }
    let description = required_string(&candidate, "description")?;
    let server = required_string(&candidate["launch"], "serverName")?;
    if name.trim().is_empty() || name.len() > 120 || name.chars().any(char::is_control)
        || version.trim().is_empty() || version.len() > 100 || version.chars().any(char::is_control)
        || description.trim().is_empty() || description.chars().any(char::is_control)
        || server.trim().is_empty() || server.chars().any(char::is_control)
    { return Err("Invalid candidate name/version/description/server".into()); }
    let exe = required_string(&candidate["runtime"], "executable")?;
    let exe = safe_path(exe, false)?;
    if !exe.to_ascii_lowercase().ends_with(".exe") { return Err("Executable is not .exe".into()); }
    let archives = candidate["pack"]["archives"].as_array().ok_or("pack.archives is not array")?;
    if archives.len() != 1 { return Err("Draft must contain exactly one ZIP archive".into()); }
    strict_fields(&archives[0], &["archiveUrl","sha256","size"], "pack.archives[0]")?;
    let url = required_string(&archives[0], "archiveUrl")?;
    validate_archive_url(url)?;
    let pinned_hash = required_string(&candidate["pack"], "sha256")?;
    let archive_hash = required_string(&archives[0], "sha256")?;
    let archive_size = candidate["pack"]["size"].as_u64().ok_or("Invalid pack size")?;
    if !valid_sha(pinned_hash) || archive_hash != pinned_hash || archive_size < 22
        || archive_size > MAX_ARCHIVE_BYTES || archives[0]["size"].as_u64() != Some(archive_size)
        || lock["archive"]["url"] != url || lock["archive"]["sha256"] != pinned_hash
        || lock["archive"]["size"].as_u64() != Some(archive_size)
    { return Err("ZIP hash, size or URL mismatch between candidate and source lock".into()); }
    let source = canonical_file(original_zip_path, "Original ZIP")?;
    if source.extension().and_then(|v| v.to_str()).is_none_or(|e| !e.eq_ignore_ascii_case("zip")) {
        return Err("Original archive must be .zip".into());
    }
    let _source_parent = pin_source_parent(&source)?;
    no_links(&source)?;
    let mut source_handle = open_local_source(&source)?;
    let scan = read_zip(&mut source_handle, source.file_name().and_then(|s| s.to_str()).unwrap_or("archive.zip"))?;
    if scan.inspection.archive_size != archive_size || scan.inspection.sha256 != pinned_hash {
        return Err("ORIGINAL ZIP bytes/size mismatch against immutable draft".into());
    }
    let expected_required = required_files(&mut source_handle, &scan.entries, &exe, pinned_hash)?;
    let required = candidate["runtime"]["requiredFiles"].as_array().ok_or("requiredFiles not array")?;
    if required.is_empty() || required.len() > MAX_REQUIRED || required.len() != expected_required.len() {
        return Err("Required files missing or unexpected".into());
    }
    let mut seen = HashSet::new();
    for file in required {
        strict_fields(file, &["path","sha256","size","archiveSha256"], "requiredFile")?;
        let path = safe_path(required_string(file, "path")?, false)?;
        let sha = required_string(file, "sha256")?;
        if !seen.insert(path.to_lowercase()) || !valid_sha(sha) || file["archiveSha256"] != pinned_hash
            || file["size"].as_u64().is_none_or(|size| size == 0 || size > MAX_FILE_BYTES)
        { return Err("Invalid required file/path/hash".into()); }
        if !expected_required.iter().any(|expected| expected == file) {
            return Err(format!("Required file differs from ORIGINAL ZIP bytes: {path}"));
        }
    }
    if !seen.contains(&exe.to_lowercase()) { return Err("Executable missing from required files".into()); }
    // On Windows the opened ZIP handle denies concurrent writer/delete shares.
    drop(source_handle);
    let available: Vec<_> = ["png", "jpg", "webp"].iter()
        .filter(|ext| draft.join(format!("cover.{ext}")).exists())
        .copied().collect();
    if available.len() != 1 { return Err("Exactly one draft cover is required".into()); }
    let ext = available[0];
    let cover_path = draft.join(format!("cover.{ext}"));
    if candidate["ui"]["imagePath"] != format!("assets/experiences/{id}.{ext}") {
        return Err("Cover filename differs from candidate imagePath".into());
    }
    let cover = bounded_file(&cover_path, MAX_COVER_BYTES)?;
    cover_kind(&cover_path)?;
    let signature_ok = match ext {
        "png" => cover.starts_with(b"\x89PNG\r\n\x1a\n"),
        "jpg" => cover.starts_with(&[0xff, 0xd8, 0xff]),
        "webp" => cover.starts_with(b"RIFF") && &cover[8..12] == b"WEBP",
        _ => false,
    };
    if !signature_ok {
        return Err("Draft cover bytes do not match its image signature".into());
    }
    let asset = asset_dir.join(format!("{id}.{ext}"));
    let target_lock = locks_dir.join(format!("{id}.lock.json"));
    for path in [&asset, &target_lock] {
        no_links(path)?;
        if !update_existing && fs::symlink_metadata(path).is_ok() {
            return Err("Cover or lock target already exists".into());
        }
    }
    let catalog_after = if update_existing {
        let mut updated = catalog_value.clone();
        let entries = updated["experiences"].as_array_mut().ok_or("Invalid catalog experiences")?;
        let matches: Vec<_> = entries.iter().enumerate().filter_map(|(index, entry)|
            (entry["id"] == id).then_some(index)).collect();
        if matches.len() != 1 { return Err("Update ID must match exactly one existing entry".into()); }
        entries[matches[0]] = candidate.clone();
        let mut encoded = serde_json::to_vec_pretty(&updated)
            .map_err(|_| "Cannot prepare update catalog")?;
        encoded.push(b'\n');
        if encoded.len() as u64 > MAX_JSON_BYTES {
            return Err("Update catalog exceeds size limit".into());
        }
        encoded
    } else {
        append_candidate(&catalog_before, &candidate_bytes, old_count)?
    };
    let merged: Value = serde_json::from_slice(&catalog_after).map_err(|_| "Invalid appended catalog JSON")?;
    if !update_existing && merged["experiences"][old_count]["id"] != id {
        return Err("Appended candidate ID differs".into());
    }
    Ok(PromotionPrepared {
        review: StandalonePromotionReview {
            id: id.into(), name: name.into(), version: version.into(),
            catalog_sha256, archive_sha256: pinned_hash.into(),
            archive_size, required_files_count: required.len(),
            source_zip_path: source.display().to_string(), source_archive_url: url.into(),
            cover_target: asset.display().to_string(), lock_target: target_lock.display().to_string(),
            catalog_target: catalog.display().to_string(), status: if update_existing {
                "ready-for-offline-update-review"
            } else { "ready-for-reviewed-rights" },
        },
        catalog_after, lock: lock_bytes, cover,
    })
}

#[cfg(windows)]
struct NativePromotionLock(isize);

#[cfg(windows)]
impl NativePromotionLock {
    fn new(root: &Path) -> Result<Self, String> {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        extern "system" {
            fn CreateMutexW(attributes: *const std::ffi::c_void, initial_owner: i32, name: *const u16) -> isize;
            fn WaitForSingleObject(handle: isize, timeout: u32) -> u32;
            fn CloseHandle(handle: isize) -> i32;
        }
        let label = format!("Local\\CocoStandalonePromotion-{}",
            &sha_bytes(root.to_string_lossy().to_ascii_lowercase().as_bytes())[..24]);
        let wide: Vec<_> = std::ffi::OsStr::new(&label).encode_wide().chain(Some(0)).collect();
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, wide.as_ptr()) };
        if handle == 0 { return Err("Cannot acquire promotion OS mutex".into()); }
        let wait = unsafe { WaitForSingleObject(handle, 0) };
        if wait != 0 && wait != 0x80 {
            unsafe { CloseHandle(handle); }
            return Err("Another standalone promotion is already active".into());
        }
        Ok(Self(handle))
    }
}

#[cfg(windows)]
impl Drop for NativePromotionLock {
    fn drop(&mut self) {
        #[link(name = "kernel32")]
        extern "system" {
            fn ReleaseMutex(handle: isize) -> i32;
            fn CloseHandle(handle: isize) -> i32;
        }
        unsafe { ReleaseMutex(self.0); CloseHandle(self.0); }
    }
}

#[cfg(not(windows))]
struct NativePromotionLock;
#[cfg(not(windows))]
impl NativePromotionLock {
    fn new(_root: &Path) -> Result<Self, String> { Ok(Self) }
}

fn new_sibling(path: &Path, kind: &str) -> Result<PathBuf, String> {
    let parent = path.parent().ok_or("Target has no parent")?;
    for number in 0..12u8 {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)
            .map_err(|_| "System time unavailable")?.as_nanos();
        let candidate = parent.join(format!(".coco2-{}-{}-{stamp}-{number}.tmp",
            kind, std::process::id()));
        if fs::symlink_metadata(&candidate).is_err() { return Ok(candidate); }
    }
    Err("Cannot reserve promotion stage name".into())
}

#[cfg(windows)]
fn rename_no_replace(from: &Path, to: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" { fn MoveFileW(old_name: *const u16, new_name: *const u16) -> i32; }
    let old: Vec<_> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let new: Vec<_> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe { MoveFileW(old.as_ptr(), new.as_ptr()) } == 0 {
        return Err(format!("Target appeared or cannot publish new file: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn rename_no_replace(from: &Path, to: &Path) -> Result<(), String> {
    fs::hard_link(from, to).map_err(|e| format!("Target appeared or cannot publish file: {e}"))?;
    fs::remove_file(from).map_err(|e| e.to_string())
}

#[cfg(windows)]
fn replace_catalog(staged: &Path, catalog: &Path, backup: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn ReplaceFileW(target: *const u16, replacement: *const u16, backup: *const u16,
            flags: u32, excluded: *const std::ffi::c_void, reserved: *const std::ffi::c_void) -> i32;
    }
    let a: Vec<_> = catalog.as_os_str().encode_wide().chain(Some(0)).collect();
    let b: Vec<_> = staged.as_os_str().encode_wide().chain(Some(0)).collect();
    let c: Vec<_> = backup.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe { ReplaceFileW(a.as_ptr(), b.as_ptr(), c.as_ptr(), 0,
        std::ptr::null(), std::ptr::null()) } == 0
    {
        return Err(format!("Atomic Windows catalog ReplaceFileW failed: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_catalog(staged: &Path, catalog: &Path, backup: &Path) -> Result<(), String> {
    // Test/Unix fallback: backup via copy, then same-volume rename. Windows
    // production uses ReplaceFileW's native backup and atomic replacement.
    fs::copy(catalog, backup).map_err(|e| e.to_string())?;
    fs::rename(staged, catalog).map_err(|e| e.to_string())
}

struct TempPromotionFiles(Vec<PathBuf>);
impl Drop for TempPromotionFiles {
    fn drop(&mut self) {
        for path in &self.0 { let _ = fs::remove_file(path); }
    }
}

fn safely_undo_new(path: &Path, original_sha: &str) {
    if no_links(path).is_ok() {
        if let Ok(bytes) = bounded_file(path, MAX_COVER_BYTES.max(2 * 1024 * 1024)) {
            if sha_bytes(&bytes) == original_sha { let _ = fs::remove_file(path); }
        }
    }
}

fn publish_promotion_with_hook(root: &Path, prepared: PromotionPrepared,
                               before_final_cas: impl FnOnce()) -> Result<StandalonePromotionResult, String> {
    let catalog = PathBuf::from(&prepared.review.catalog_target);
    let target_lock = PathBuf::from(&prepared.review.lock_target);
    let target_cover = PathBuf::from(&prepared.review.cover_target);
    let catalog_stage = new_sibling(&catalog, "catalog")?;
    let catalog_backup = new_sibling(&catalog, "backup")?;
    let lock_stage = new_sibling(&target_lock, "lock")?;
    let cover_stage = new_sibling(&target_cover, "cover")?;
    let _temporary = TempPromotionFiles(vec![
        catalog_stage.clone(), lock_stage.clone(), cover_stage.clone(),
    ]);
    // Every file is fully written and fsynced BEFORE making any target visible.
    write_new(&catalog_stage, &prepared.catalog_after)?;
    write_new(&lock_stage, &prepared.lock)?;
    write_new(&cover_stage, &prepared.cover)?;
    let original_hash = prepared.review.catalog_sha256.as_str();
    let new_hash = sha_bytes(&prepared.catalog_after);
    let lock_hash = sha_bytes(&prepared.lock);
    let cover_hash = sha_bytes(&prepared.cover);
    let mut lock_visible = false;
    let mut cover_visible = false;
    let mut committed = false;
    let action: Result<(), String> = (|| {
        for path in [root, &catalog, &target_lock, &target_cover] {
            no_links(path)?;
        }
        if fs::symlink_metadata(&target_lock).is_ok() || fs::symlink_metadata(&target_cover).is_ok() {
            return Err("Cover/lock destination appeared during staging".into());
        }
        if sha_bytes(&bounded_file(&catalog, MAX_JSON_BYTES)?) != original_hash {
            return Err("Source catalog changed during staging; CAS refused".into());
        }
        rename_no_replace(&lock_stage, &target_lock)?;
        lock_visible = true;
        rename_no_replace(&cover_stage, &target_cover)?;
        cover_visible = true;
        before_final_cas();
        // A lock or cover changed after review/staging must never be published
        // with an otherwise valid catalog. Open read-only with deny-write and
        // deny-delete sharing on Windows and KEEP both handles until after
        // ReplaceFileW, preventing a late writer/rename after these hashes.
        // The hook models an unrelated concurrent writer exactly here.
        for path in [&target_lock, &target_cover] { no_links(path)?; }
        let mut verified_lock = open_local_source(&target_lock)?;
        let mut verified_cover = open_local_source(&target_cover)?;
        let (actual_lock_hash, actual_lock_size) = hash_reader(&mut verified_lock, 2 * 1024 * 1024)?;
        let (actual_cover_hash, actual_cover_size) = hash_reader(&mut verified_cover, MAX_COVER_BYTES)?;
        if actual_lock_hash != lock_hash || actual_lock_size != prepared.lock.len() as u64
            || actual_cover_hash != cover_hash || actual_cover_size != prepared.cover.len() as u64 {
            return Err("Published cover or lock changed before catalog commit; recovery required".into());
        }
        if sha_bytes(&bounded_file(&catalog, MAX_JSON_BYTES)?) != original_hash {
            return Err("Source catalog changed after creating lock/cover; CAS refused".into());
        }
        replace_catalog(&catalog_stage, &catalog, &catalog_backup)?;
        committed = true;
        if sha_bytes(&bounded_file(&catalog, MAX_JSON_BYTES)?) != new_hash {
            return Err("Published catalog does not match staged bytes".into());
        }
        Ok(())
    })();
    if let Err(error) = action {
        if committed && catalog_backup.exists() {
            // Only restore the backup when our replacement remains identical:
            // never overwrite a different concurrent catalog change.
            if bounded_file(&catalog, MAX_JSON_BYTES)
                .is_ok_and(|bytes| sha_bytes(&bytes) == new_hash)
            {
                let restore = new_sibling(&catalog, "restore")?;
                fs::copy(&catalog_backup, &restore)
                    .map_err(|e| format!("{error}; backup recovery copy failed: {e}"))?;
                if let Err(e) = replace_catalog(&restore, &catalog, &new_sibling(&catalog, "replaced")?) {
                    return Err(format!("{error}; catalog recovery failed: {e}; inspect {catalog_backup:?}"));
                }
            }
        }
        let source_bytes = bounded_file(&catalog, MAX_JSON_BYTES).ok();
        let unchanged = source_bytes.as_ref().is_some_and(|bytes| sha_bytes(bytes) == original_hash);
        let no_promoted_id = !committed && source_bytes.as_ref().is_some_and(|bytes|
            valid_catalog_catalog(bytes, &prepared.review.id).is_ok());
        if unchanged || no_promoted_id {
            if cover_visible { safely_undo_new(&target_cover, &cover_hash); }
            if lock_visible { safely_undo_new(&target_lock, &lock_hash); }
            if (cover_visible && fs::symlink_metadata(&target_cover).is_ok())
                || (lock_visible && fs::symlink_metadata(&target_lock).is_ok()) {
                // An unrelated writer replaced one of our published targets.
                // Its bytes are NOT ours to delete. Tell the owner exactly
                // why a retry may conflict, instead of silently orphaning it.
                return Err(format!("{error}; changed cover/lock preserved for manual inspection (no unreviewed overwrite or rollback)"));
            }
        } else {
            return Err(format!("{error}; catalog may be committed or concurrently modified; keep cover/lock and inspect backup at {catalog_backup:?}"));
        }
        return Err(error);
    }
    // Keep the source backup if deletion fails; never invalidate a successful
    // publication because of backup maintenance.
    let _ = fs::remove_file(&catalog_backup);
    Ok(StandalonePromotionResult {
        id: prepared.review.id, status: "promoted",
        catalog_sha256_before: original_hash.to_string(),
        catalog_sha256_after: new_hash,
        catalog_path: catalog.display().to_string(),
        source_lock_path: target_lock.display().to_string(),
        cover_path: target_cover.display().to_string(),
    })
}

fn publish_promotion(root: &Path, prepared: PromotionPrepared) -> Result<StandalonePromotionResult, String> {
    publish_promotion_with_hook(root, prepared, || {})
}

fn promote_with_root(root: &Path, id: &str, reviewed_rights: bool,
                     original_zip_path: &str) -> Result<StandalonePromotionResult, String> {
    if !reviewed_rights {
        return Err("License, source and redistribution rights must be reviewed explicitly before promotion".into());
    }
    // An in-process mutex plus a named Windows kernel mutex coordinate this
    // promoter with other instances. Other editors are protected by the
    // before-commit SHA CAS, but do not participate in the mutex.
    let _guard = PROMOTION_MUTEX.get_or_init(|| Mutex::new(()))
        .lock().map_err(|_| "Native promotion mutex poisoned")?;
    let _kernel_lock = NativePromotionLock::new(root)?;
    let repo = root.parent().ok_or("Missing promotion repository parent")?;
    let draft = root.join("drafts").join(id);
    let _catalog_parent = pin_source_parent(&repo.join("launcher/catalog.template.json"))?;
    let _lock_parent = pin_source_parent(&repo.join(format!("launcher/experiences/{id}.lock.json")))?;
    let _cover_parent = pin_source_parent(&repo.join(format!("assets/experiences/{id}.png")))?;
    let _draft_parent = pin_source_parent(&draft.join("source-lock.json"))?;
    let prepared = prepare_promotion(root, id, original_zip_path)?;
    _catalog_parent.check()?;
    _lock_parent.check()?;
    _cover_parent.check()?;
    _draft_parent.check()?;
    publish_promotion(root, prepared)
}

#[tauri::command]
pub async fn review_standalone_draft(id: String, original_zip_path: String)
    -> Result<StandalonePromotionReview, String>
{
    tauri::async_runtime::spawn_blocking(move || {
        if !host_studio_available() { return Err("Host Studio is not available on this host".into()); }
        let root = launcher2_root()?;
        prepare_promotion(&root, &id, &original_zip_path).map(|prepared| prepared.review)
    }).await.map_err(|e| format!("Standalone draft review interrupted: {e}"))?
}

#[tauri::command]
pub async fn promote_standalone_draft(id: String, reviewed_rights: bool,
                                      original_zip_path: String) -> Result<StandalonePromotionResult, String>
{
    if !reviewed_rights {
        return Err("Explicitly review and approve license/redistribution rights before promotion".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        if !host_studio_available() { return Err("Host Studio is not available on this host".into()); }
        let root = launcher2_root()?;
        promote_with_root(&root, &id, reviewed_rights, &original_zip_path)
    }).await.map_err(|e| format!("Standalone draft promotion interrupted: {e}"))?
}

#[tauri::command]
pub async fn preview_standalone_publish(id: String, original_zip_path: String)
    -> Result<StandalonePublishPreview, String>
{
    tauri::async_runtime::spawn_blocking(move || {
        if !host_studio_available() { return Err("Host Studio is unavailable".into()); }
        host_publish::preview(&launcher2_root()?, &id, &original_zip_path)
    }).await.map_err(|e| format!("Publish preview interrupted: {e}"))?
}

#[tauri::command]
pub async fn prepare_standalone_publish(app: tauri::AppHandle, id: String, original_zip_path: String,
                                         expected_preview_sha256: String, reviewed_rights: bool)
    -> Result<StandalonePublishArtifact, String>
{
    use tauri::Emitter;
    if !reviewed_rights { return Err("Review source and redistribution rights before packaging".into()); }
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = (|| {
            if !host_studio_available() { return Err("Host Studio is unavailable".into()); }
            host_publish::prepare(&launcher2_root()?, &id, &original_zip_path,
                &expected_preview_sha256, |progress| {
                    let _ = app.emit(host_publish::PROGRESS_EVENT, progress);
                })
        })();
        if outcome.is_err() {
            let _ = app.emit(host_publish::PROGRESS_EVENT,
                host_publish::StandalonePublishProgress::unknown(&id, "error"));
        }
        outcome
    }).await.map_err(|e| format!("Publish preparation interrupted: {e}"))?
}

/// Portable transfer envelope for a reviewed local package. It is NEVER a
/// signed official channel or an automatically executable installer.
#[tauri::command]
pub async fn export_portable_standalone_package(id:String,artifact_path:String,
    destination_path:Option<String>)
    ->Result<PortablePublishArtifact,String>
{
    tauri::async_runtime::spawn_blocking(move||{
        if !host_studio_available(){return Err("Host Studio is unavailable".into());}
        host_publish::export_portable_to(&launcher2_root()?,&id,&artifact_path,
            destination_path.as_deref())
    }).await.map_err(|e|format!("Portable export interrupted: {e}"))?
}

/// Native E2E adapter: exercises the exact draft -> Host Studio preview ->
/// sealed publish -> portable-export production functions, but binds every
/// filesystem argument to the synthetic test repository. Does not touch the
/// real checkout, any game, a Windows profile or the network.
#[cfg(test)]
pub(crate) fn test_host_studio_portable(
    root:&Path,id:&str,version:&str,archive:&Path,cover:&Path,update:bool,
) -> Result<(PathBuf,PathBuf),String>{
    let archive_path=archive.display().to_string();
    let url=format!("https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/test-{version}/{id}.zip");
    draft_with_root_mode(root,&archive_path,id,"Synthetic Windows E2E",version,
        &url,&cover.display().to_string(),"game.exe",None,update)?;
    let review=host_publish::preview(root,id,&archive_path)?;
    if review.new_version!=version || review.mode!=(if update{"update"}else{"new"}){
        return Err("Host Studio published unexpected version or mode".into());
    }
    let sealed=host_publish::prepare(root,id,&archive_path,&review.preview_sha256,|_|{})?;
    let exported=host_publish::export_portable(root,id,&sealed.artifact_path)?;
    if exported.status!="exported-local-untrusted-unpublished" {
        return Err("Host Studio improperly claimed package publication".into());
    }
    Ok((PathBuf::from(exported.path),PathBuf::from(sealed.catalog_path)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use zip::write::SimpleFileOptions;
    static SEQUENCE: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn v16_reject_windows_reserved_superscript_and_console_device_zip_members(){
        for name in ["COM¹.exe","COM².exe","COM³.exe","LPT¹.dll","LPT².txt",
            "LPT³.exe","CONIN$.exe","CONOUT$.txt","Data/COM¹.exe","Game/CONOUT$.cfg"] {
            assert!(safe_path(name,false).is_err(),
                "Win32 reserved device syntax was accepted as a ZIP member: {name}");
        }
        for name in ["COM-1.exe","LPT-ten.dll","Game.exe","Unicode 漢字 💜/Play.exe"] {
            assert!(safe_path(name,false).is_ok(),"ordinary ZIP path was rejected: {name}");
        }
        let fix=Fixture::new();
        let invalid=fix.zip(&[("Game.exe",b"synthetic executable"),("COM¹.exe",b"device")]);
        assert!(scan_path(&invalid.to_string_lossy()).is_err(),
            "full ZIP inspection must reject a device member before a draft is created");
    }

    #[test]
    fn v16_same_size_same_mtime_replaced_zip_and_invalid_executable_fail_closed(){
        let fix=Fixture::new();
        let first=fix.zip(&[("Game.exe",b"SYNTHETIC-A"),("config/options.ini",b"v1")]);
        let first_bytes=fs::read(&first).unwrap();
        let first_time=fs::metadata(&first).unwrap().modified().unwrap();
        let reviewed=scan_path(&first.to_string_lossy()).unwrap().inspection.sha256;
        let second=fix.zip(&[("Game.exe",b"SYNTHETIC-B"),("config/options.ini",b"v1")]);
        assert_eq!(fs::read(&second).unwrap().len(),first_bytes.len());
        assert_ne!(sha_bytes(&fs::read(&second).unwrap()),reviewed);
        let file=OpenOptions::new().write(true).open(&second).unwrap();
        file.set_times(std::fs::FileTimes::new().set_modified(first_time)).unwrap();
        drop(file); // Close our synthetic writer before production's deny-write ZIP open.
        assert_eq!(fs::metadata(&second).unwrap().modified().unwrap(),first_time,
            "the replacement ZIP must preserve both size and modified time");
        let root=fix.root.join("launcher2");
        let zip=second.to_string_lossy().into_owned();
        let url="https://github.com/owner/repo/releases/download/v1/game.zip";
        let outcome=draft_with_root_mode(&root,&zip,"friend-swap","Friend Swap","1.0.0",
            url,"","Game.exe",Some(&reviewed),false);
        let reason=outcome.unwrap_err();
        assert!(reason.contains("ZIP cambió"),
            "same-size/same-mtime replacement must invalidate prior inspection by SHA; got {reason}");
        assert!(!root.join("drafts/friend-swap").exists());
        let invalid_exe=draft_with_root_mode(&root,&zip,"friend-invalid","Friend Invalid","1.0.0",
            url,"","Missing.exe",None,false);
        assert!(invalid_exe.is_err(),"selecting an executable not in ZIP must fail");
        assert!(!root.join("drafts/friend-invalid").exists());
    }

    struct Fixture { root: PathBuf }
    impl Fixture {
        fn new() -> Self {
            let n = SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let name = format!("coco2-import-test-{}-{}-{n}", std::process::id(),
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos());
            let root = std::env::temp_dir().join(name);
            fs::create_dir_all(root.join("launcher2")).unwrap();
            fs::create_dir_all(root.join("launcher")).unwrap();
            fs::write(root.join("launcher/catalog.template.json"),
                r#"{"schemaVersion":1,"experiences":[{"id":"existing-game"}]}"#).unwrap();
            fs::write(root.join("cover.png"), b"\x89PNG\r\n\x1a\n12345678").unwrap();
            Self {root}
        }
        fn zip(&self, entries: &[(&str, &[u8])]) -> PathBuf {
            let path = self.root.join("fixture-game.zip");
            let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
            for (name, bytes) in entries {
                writer.start_file(*name, SimpleFileOptions::default()).unwrap();
                writer.write_all(bytes).unwrap();
            }
            writer.finish().unwrap();
            path
        }
        fn create(&self, zip: &Path, id: &str) -> Result<StandaloneDraft, String> {
            draft_with_root(&self.root.join("launcher2"), &zip.display().to_string(),
                id,"My Game","1.2","https://github.com/owner/repo/releases/download/v1/game.zip",
                &self.root.join("cover.png").display().to_string(),"Game.exe",None)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.root); }
    }

    #[test]
    fn neutral_cover_is_deterministic_decodable_rgb_png_with_valid_checksums() {
        let image = neutral_cover_png();
        assert_eq!(image, neutral_cover_png(), "neutral cover bytes must be reproducible");
        assert!(image.len() >= 1024 && (image.len() as u64) < MAX_COVER_BYTES);
        assert!(image.starts_with(b"\x89PNG\r\n\x1a\n"));
        let mut offset = 8usize;
        let mut image_data = Vec::new();
        let mut saw_header = false;
        let mut saw_end = false;
        while offset < image.len() {
            assert!(offset + 12 <= image.len());
            let size = u32::from_be_bytes(image[offset..offset + 4].try_into().unwrap()) as usize;
            let kind = &image[offset + 4..offset + 8];
            let start = offset + 8;
            let end = start + size;
            assert!(end + 4 <= image.len());
            let stored_crc = u32::from_be_bytes(image[end..end + 4].try_into().unwrap());
            let mut crc = !0u32;
            for byte in image[offset + 4..end].iter() {
                crc ^= u32::from(*byte);
                for _ in 0..8 {
                    crc = if crc & 1 == 1 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
                }
            }
            assert_eq!(stored_crc, !crc, "PNG chunk CRC must match bytes");
            match kind {
                b"IHDR" => {
                    assert!(!saw_header && size == 13);
                    assert_eq!(&image[start..start + 4], &(320u32).to_be_bytes());
                    assert_eq!(&image[start + 4..start + 8], &(180u32).to_be_bytes());
                    assert_eq!(&image[start + 8..end], &[8, 2, 0, 0, 0]);
                    saw_header = true;
                }
                b"IDAT" => image_data.extend_from_slice(&image[start..end]),
                b"IEND" => { assert_eq!(size, 0); saw_end = true; },
                _ => panic!("unexpected PNG chunk"),
            }
            offset = end + 4;
        }
        assert!(saw_header && saw_end && offset == image.len());
        assert!(image_data.starts_with(&[0x78, 0x01]));
        let mut cursor = 2;
        let mut raw = Vec::new();
        loop {
            assert!(cursor + 5 < image_data.len());
            let flags = image_data[cursor];
            assert_eq!(flags & 0xfe, 0, "only RFC 1951 STORED blocks are allowed");
            let last = flags & 1 != 0;
            let len = u16::from_le_bytes(image_data[cursor + 1..cursor + 3].try_into().unwrap());
            let complement = u16::from_le_bytes(image_data[cursor + 3..cursor + 5].try_into().unwrap());
            assert_eq!(len, !complement);
            cursor += 5;
            let end = cursor + len as usize;
            assert!(end <= image_data.len() - 4);
            raw.extend_from_slice(&image_data[cursor..end]);
            cursor = end;
            if last { break; }
        }
        assert_eq!(cursor, image_data.len() - 4);
        assert_eq!(raw.len(), 180 * (320 * 3 + 1));
        assert!(raw.chunks_exact(320 * 3 + 1).all(|row| row[0] == 0));
        let (mut a, mut b) = (1u32, 0u32);
        for byte in &raw { a = (a + u32::from(*byte)) % 65521; b = (b + a) % 65521; }
        assert_eq!(&image_data[cursor..], &((b << 16) | a).to_be_bytes());
        let first_pixel = &raw[1..4];
        let middle_pixel = &raw[(180 / 2) * (320 * 3 + 1) + 1 + (320 / 2) * 3..
            (180 / 2) * (320 * 3 + 1) + 4 + (320 / 2) * 3];
        assert_ne!(first_pixel, middle_pixel, "placeholder should not be a blank 1px icon");
    }

    #[test]
    fn no_cover_unicode_draft_seals_self_contained_portable_with_original_png_hash() {
        let fix = Fixture::new();
        let source_folder = fix.root.join("Juegos 漢字 con espacios");
        fs::create_dir(&source_folder).unwrap();
        let zip = source_folder.join("Juego con espacios.zip");
        let mut writer = zip::ZipWriter::new(File::create(&zip).unwrap());
        for (name, bytes) in [("Game.exe", b"synthetic game".as_slice()),
            ("UnityPlayer.dll", b"synthetic dependency".as_slice())] {
            writer.start_file(name, SimpleFileOptions::default()).unwrap();
            writer.write_all(bytes).unwrap();
        }
        writer.finish().unwrap();
        let source_zip = fs::read(&zip).unwrap();
        let catalog_before = fs::read(fix.root.join("launcher/catalog.template.json")).unwrap();
        let root = fix.root.join("launcher2");
        let proposed = draft_with_root(&root, &zip.display().to_string(), "neutral-demo",
            "Juego Unicode - test", "1.0.0",
            "https://github.com/owner/repo/releases/download/v1/game.zip",
            "", "Game.exe", None).unwrap();
        let draft = PathBuf::from(&proposed.draft_path);
        let cover = fs::read(draft.join("cover.png")).unwrap();
        assert_eq!(cover, neutral_cover_png());
        assert_eq!(cover_kind(&draft.join("cover.png")).unwrap(), "png");
        let candidate: Value = serde_json::from_slice(&fs::read(&proposed.catalog_candidate_path).unwrap()).unwrap();
        assert_eq!(candidate["ui"]["imagePath"], "assets/experiences/neutral-demo.png");
        assert_eq!(candidate["pack"]["version"], "1.0.0");
        assert_eq!(candidate["pack"]["sha256"], proposed.archive_sha256);
        // The E2E authoring workspace has these output folders, but the
        // smaller Fixture deliberately does not create them by default.
        fs::create_dir_all(fix.root.join("assets/experiences")).unwrap();
        fs::create_dir_all(fix.root.join("launcher/experiences")).unwrap();
        let preview = host_publish::preview(&root, "neutral-demo", &zip.display().to_string()).unwrap();
        let sealed = host_publish::prepare(&root, "neutral-demo", &zip.display().to_string(),
            &preview.preview_sha256, |_| {}).unwrap();
        assert_eq!(sealed.status, "prepared-offline-review-only");
        let sealed_cover = fs::read(Path::new(&sealed.artifact_path).join("cover.png")).unwrap();
        assert_eq!(sealed_cover, cover);
        let manifest: Value = serde_json::from_slice(&fs::read(&sealed.manifest_path).unwrap()).unwrap();
        assert_eq!(manifest["coverFile"], "cover.png");
        assert_eq!(manifest["coverSha256"], sha_bytes(&cover));
        let exported = host_publish::export_portable(&root, "neutral-demo", &sealed.artifact_path).unwrap();
        assert_eq!(exported.status, "exported-local-untrusted-unpublished");
        let mut package = zip::ZipArchive::new(File::open(&exported.path).unwrap()).unwrap();
        let mut portable_cover = Vec::new();
        package.by_name("cover.png").unwrap().read_to_end(&mut portable_cover).unwrap();
        assert_eq!(portable_cover, cover);
        assert!(package.by_name("game.zip").is_ok());
        assert_eq!(fs::read(&zip).unwrap(), source_zip);
        assert_eq!(fs::read(fix.root.join("launcher/catalog.template.json")).unwrap(), catalog_before);
        assert!(!fix.root.join("assets/experiences/neutral-demo.png").exists());
        assert!(!fix.root.join("launcher/experiences/neutral-demo.lock.json").exists());
        assert!(host_publish::export_portable(&root, "neutral-demo", &sealed.artifact_path).is_err(),
            "no replacement of an already exported portable package");
    }

    #[test]
    fn no_cover_update_draft_preserves_schema_and_expected_version_gate() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Game.exe", b"update binary"), ("UnityPlayer.dll", b"dll")]);
        let root = fix.root.join("launcher2");
        let link = "https://github.com/owner/repo/releases/download/v1/game.zip";
        draft_with_root(&root, &zip.display().to_string(), "update-demo",
            "Game", "1.0.0", link, "", "Game.exe", None).unwrap();
        let original_candidate = fs::read(root.join("drafts/update-demo/catalog-candidate.json")).unwrap();
        let previous: Value = serde_json::from_slice(&original_candidate).unwrap();
        fs::write(fix.root.join("launcher/catalog.template.json"),
            serde_json::to_vec(&serde_json::json!({"schemaVersion":1,"experiences":[previous]})).unwrap()).unwrap();
        let original_source = fs::read(fix.root.join("launcher/catalog.template.json")).unwrap();
        let next = draft_with_root_mode(&root, &zip.display().to_string(), "update-demo",
            "Game (update)", "1.1.0", link, "", "Game.exe", None, true).unwrap();
        assert!(next.draft_path.contains("update-drafts"));
        assert_eq!(fs::read(&next.cover_path).unwrap(), neutral_cover_png());
        fs::create_dir_all(fix.root.join("assets/experiences")).unwrap();
        fs::create_dir_all(fix.root.join("launcher/experiences")).unwrap();
        let preview = host_publish::preview(&root, "update-demo", &zip.display().to_string()).unwrap();
        assert_eq!(preview.mode, "update");
        let sealed = host_publish::prepare(&root, "update-demo", &zip.display().to_string(),
            &preview.preview_sha256, |_| {}).unwrap();
        let exported = host_publish::export_portable(&root, "update-demo", &sealed.artifact_path).unwrap();
        let mut zip_output = zip::ZipArchive::new(File::open(&exported.path).unwrap()).unwrap();
        assert!(zip_output.by_name("cover.png").is_ok());
        assert_eq!(fs::read(fix.root.join("launcher/catalog.template.json")).unwrap(), original_source);
        assert!(draft_with_root_mode(&root, &zip.display().to_string(), "update-demo",
            "Game (update)", "1.1.0", link, "", "Game.exe", None, true).is_err());
    }

    #[test]
    fn cover_path_requires_exact_empty_and_never_downgrades_unsafe_explicit_input() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Game.exe", b"game")]);
        let root = fix.root.join("launcher2");
        let link = "https://github.com/owner/repo/releases/download/v1/game.zip";
        for bad in [" ", ".", "../cover.png", "./cover.png",
            "not-an-actual-file.png", "https://example.com/cover.png", "C:\\not-a-local-cover.png"] {
            let id = "deny-bad-cover";
            assert!(draft_with_root(&root, &zip.display().to_string(), id, "Game",
                "1.0.0", link, bad, "Game.exe", None).is_err(),
                "non-empty input must never become a generated cover: {bad}");
            assert!(!root.join("drafts").join(id).exists());
        }
        let bad_cover = fix.root.join("malicious.png");
        fs::write(&bad_cover, b"<svg onclick=\"alert(1)\">not PNG</svg>").unwrap();
        assert!(draft_with_root(&root, &zip.display().to_string(), "wrong-mime",
            "Game", "1.0.0", link, &bad_cover.display().to_string(),
            "Game.exe", None).is_err());
        assert!(!root.join("drafts/wrong-mime").exists());
        let valid_cover = fix.root.join("explicit valid portada.png");
        let explicit = neutral_cover_png();
        fs::write(&valid_cover, &explicit).unwrap();
        let created = draft_with_root(&root, &zip.display().to_string(), "explicit-valid",
            "Game", "1.0.0", link, &valid_cover.display().to_string(),
            "Game.exe", None).unwrap();
        assert_eq!(fs::read(&created.cover_path).unwrap(), explicit);
        assert_eq!(fs::read(&valid_cover).unwrap(), explicit);
        assert!(draft_with_root(&root, &zip.display().to_string(), "explicit-valid",
            "Game", "1.0.0", link, &valid_cover.display().to_string(),
            "Game.exe", None).is_err());
        assert_eq!(fs::read(&created.cover_path).unwrap(), explicit);
    }

    #[test]
    fn simultaneous_coverless_drafts_have_exactly_one_immutable_winner() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Game.exe", b"shared source executable"),
            ("UnityPlayer.dll", b"safe dependency")]);
        let src = zip.display().to_string();
        let root = fix.root.join("launcher2");
        let run = || draft_with_root(&root, &src, "parallel-neutral",
            "Synthetic parallel", "1.0.0",
            "https://github.com/owner/repo/releases/download/v1/game.zip",
            "", "Game.exe", None);
        let (a, b) = std::thread::scope(|scope| {
            let a = scope.spawn(&run);
            let b = scope.spawn(&run);
            (a.join().unwrap(), b.join().unwrap())
        });
        assert_eq!(usize::from(a.is_ok()) + usize::from(b.is_ok()), 1,
            "two concurrent requests must never both commit the same immutable draft");
        let cover = root.join("drafts/parallel-neutral/cover.png");
        assert_eq!(fs::read(&cover).unwrap(), neutral_cover_png());
        let candidate: Value = serde_json::from_slice(
            &fs::read(root.join("drafts/parallel-neutral/catalog-candidate.json")).unwrap()).unwrap();
        assert_eq!(candidate["ui"]["imagePath"], "assets/experiences/parallel-neutral.png");
        assert_eq!(fs::read_dir(root.join("drafts")).unwrap().count(), 1,
            "losing staging request must not leave an orphan or alter winner");
    }

    #[test]
    fn rejects_archive_changed_between_inspection_and_draft() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Game.exe", b"valid binary")]);
        let result = draft_with_root(&fix.root.join("launcher2"), &zip.display().to_string(),
            "changed-game", "Changed", "1.0.0",
            "https://github.com/owner/repo/releases/download/v1/game.zip",
            &fix.root.join("cover.png").display().to_string(), "Game.exe",
            Some(&"0".repeat(64)));
        assert!(result.unwrap_err().contains("cambió"));
        assert!(!fix.root.join("launcher2/drafts/changed-game").exists());
    }

    #[cfg(windows)]
    #[test]
    fn native_parent_pin_rejects_unicode_directory_rename_and_reparse_swap() {
        let fix = Fixture::new();
        let parent = fix.root.join("Paquetes 漢字 con espacios 💜");
        fs::create_dir(&parent).unwrap();
        let zip = parent.join("juego local.coco2pack.zip");
        fs::write(&zip, b"synthetic path marker, not a ZIP").unwrap();
        let alternative = fix.root.join("renamed synthetic directory");
        let pin = pin_source_parent(&zip).unwrap();
        pin.check().unwrap();
        assert!(fs::rename(&parent, &alternative).is_err(),
            "Win32 must block directory moves while its ancestor is pinned without FILE_SHARE_DELETE");
        assert_eq!(fs::read(&zip).unwrap(), b"synthetic path marker, not a ZIP");
        drop(pin);
        fs::rename(&parent, &alternative).unwrap();
        assert!(!parent.exists());
        assert!(pin_source_parent(&parent.join("juego local.coco2pack.zip")).is_err());
        // Developer Mode may grant this privilege, but many CI hosts do not.
        // Either way, the test never creates a junction outside its own TEMP.
        if std::os::windows::fs::symlink_dir(&alternative, &parent).is_ok() {
            assert!(pin_source_parent(&parent.join("juego local.coco2pack.zip")).is_err());
            fs::remove_dir(&parent).unwrap();
        }
    }

    #[test]
    fn reviewed_zip_replaced_by_valid_same_size_zip_cannot_be_promoted() {
        let (fix, original_zip) = promotion_fixture();
        let root = fix.root.join("launcher2");
        let catalog = fix.root.join("launcher/catalog.template.json");
        let catalog_before = fs::read(&catalog).unwrap();
        let examined = prepare_promotion(&root, "promotion-demo", &original_zip.display().to_string()).unwrap();
        let original_bytes = fs::read(&original_zip).unwrap();
        // Different archive, still valid ZIP with same size and filenames.
        // Timestamp and file-length checks alone would not catch this.
        let changed = fix.zip(&[("Game.exe", b"tampered-executable"),
            ("UnityPlayer.dll", b"verified-unity"), ("docs/readme.txt", b"user files not touched")]);
        assert_eq!(fs::metadata(&changed).unwrap().len(), examined.review.archive_size);
        assert_ne!(sha_bytes(&fs::read(&changed).unwrap()), examined.review.archive_sha256);
        let error = promote_with_root(&root, "promotion-demo", true, &changed.display().to_string()).unwrap_err();
        assert!(error.contains("ORIGINAL ZIP bytes/size mismatch"), "{error}");
        assert_eq!(fs::read(&catalog).unwrap(), catalog_before);
        assert!(!fix.root.join("launcher/experiences/promotion-demo.lock.json").exists());
        assert!(!fix.root.join("assets/experiences/promotion-demo.png").exists());
        // A later explicit retry with the *original* reviewed ZIP succeeds.
        fs::write(&original_zip, original_bytes).unwrap();
        assert_eq!(promote_with_root(&root, "promotion-demo", true,
            &original_zip.display().to_string()).unwrap().status, "promoted");
    }

    #[test]
    fn late_cover_or_lock_mutation_refuses_catalog_commit_and_preserves_other_writer() {
        for target in ["lock", "cover"] {
            let (fix, archive) = promotion_fixture();
            let root = fix.root.join("launcher2");
            let catalog = fix.root.join("launcher/catalog.template.json");
            let initial = fs::read(&catalog).unwrap();
            let prepared = prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).unwrap();
            let changed = match target {
                "lock" => fix.root.join("launcher/experiences/promotion-demo.lock.json"),
                _ => fix.root.join("assets/experiences/promotion-demo.png"),
            };
            let third_party = format!("{target}:synthetic-concurrent-owner").into_bytes();
            let result = publish_promotion_with_hook(&root, prepared, || {
                // The lock/cover have already moved into public target names,
                // but the catalog has NOT committed yet. Mutate bytes without
                // modifying the catalog or any personal user files.
                fs::write(&changed, &third_party).unwrap();
            });
            let error = result.unwrap_err();
            assert!(error.contains("Published cover or lock changed"), "{error}");
            assert!(error.contains("preserved for manual inspection"), "{error}");
            assert_eq!(fs::read(&catalog).unwrap(), initial,
                "staged catalog cannot commit after lock/cover TOCTOU");
            assert_eq!(fs::read(&changed).unwrap(), third_party,
                "another writer's changed file must never be erased during rollback");
            for folder in [fix.root.join("launcher"), fix.root.join("launcher/experiences"),
                fix.root.join("assets/experiences")] {
                for entry in fs::read_dir(folder).unwrap() {
                    let entry = entry.unwrap();
                    assert!(!entry.file_name().to_string_lossy().starts_with(".coco2-"),
                        "failed commit left an owned .tmp stage");
                }
            }
            // Explicit cleanup of the synthetic writer's file permits safe
            // recovery; production must not auto-overwrite that conflict.
            fs::remove_file(&changed).unwrap();
            assert_eq!(promote_with_root(&root, "promotion-demo", true,
                &archive.display().to_string()).unwrap().status, "promoted");
        }
    }

    #[test]
    fn inspection_is_read_only_with_streaming_sha() {
        let fix = Fixture::new();
        let path = fix.zip(&[("Game.exe",b"launch"), ("UnityPlayer.dll",b"lib"),("readme.txt",b"hi")]);
        let before = fs::read(&path).unwrap();
        let scan = scan_path(&path.display().to_string()).unwrap();
        assert_eq!(scan.inspection.executables, vec!["Game.exe"]);
        assert_eq!(scan.inspection.files_count, 3);
        assert_eq!(scan.inspection.uncompressed_bytes, 11);
        assert_eq!(scan.inspection.sha256, format!("{:x}",Sha256::digest(&before)));
        assert_eq!(fs::read(&path).unwrap(), before);
        assert!(!fix.root.join("launcher2/drafts").exists());
    }

    #[test]
    fn native_draft_is_schema_compatible_and_never_overwrites() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Game.exe",b"launch"),("UnityPlayer.dll",b"unity"),("save.txt",b"other")]);
        let original = fs::read(fix.root.join("launcher/catalog.template.json")).unwrap();
        let result = fix.create(&zip, "fresh-game").unwrap();
        let output = PathBuf::from(&result.draft_path);
        let proposed: serde_json::Value = serde_json::from_slice(
            &fs::read(output.join("catalog-candidate.json")).unwrap()).unwrap();
        let lock: serde_json::Value = serde_json::from_slice(
            &fs::read(output.join("source-lock.json")).unwrap()).unwrap();
        assert_eq!(proposed["launch"]["workflow"],"coco-standalone");
        assert_eq!(proposed["runtime"]["executable"],"Game.exe");
        assert_eq!(proposed["hosting"]["mode"],"p2p");
        assert_eq!(proposed["runtime"]["requiredFiles"].as_array().unwrap().len(),2);
        assert_eq!(proposed["pack"]["archives"][0]["sha256"],result.archive_sha256);
        assert_eq!(proposed["runtime"]["requiredFiles"][0]["archiveSha256"],result.archive_sha256);
        assert_eq!(lock["type"],"standalone");
        assert_eq!(lock["archive"]["sha256"],result.archive_sha256);
        assert_eq!(fs::read(output.join("cover.png")).unwrap(),fs::read(fix.root.join("cover.png")).unwrap());
        let first = fs::read(output.join("catalog-candidate.json")).unwrap();
        assert!(fix.create(&zip,"fresh-game").is_err());
        assert_eq!(fs::read(output.join("catalog-candidate.json")).unwrap(),first);
        assert_eq!(fs::read(fix.root.join("launcher/catalog.template.json")).unwrap(),original);
        assert!(fix.create(&zip,"existing-game").is_err());
    }

    #[test]
    fn reject_path_traversal_case_alias_file_parent_and_saved_data() {
        for path in ["../evil.exe", "/root/file", "C:/evil.exe", "a\\foo", "a/../b",
            "a//b","data/con.txt","saves/world","Mods/playerdata/a","distanthorizons/x",
            "a/.coco/../b","a/aux.dll","a/file.","a/file ", "bad:ads"]
        {
            assert!(safe_path(path,false).is_err(), "accepted: {path}");
        }
        let fix = Fixture::new();
        for entries in [
            vec![("Game.exe",b"a".as_slice()),("game.EXE",b"b".as_slice())],
            vec![("Game.exe",b"a".as_slice()),("Data",b"b".as_slice()),
                 ("Data/a.txt",b"c".as_slice())],
            vec![("Game.exe",b"a".as_slice()),("saves/level.dat",b"b".as_slice())],
        ] {
            let zip = fix.zip(&entries);
            assert!(scan_path(&zip.display().to_string()).is_err());
        }
    }

    #[test]
    fn reject_https_credentials_and_relative_sources() {
        for url in ["http://example.com/game.zip", "https://a:b@example.com/a.zip",
            "https://example.com/game.zip?token=secret", "https://example.com/game.rar",
            "file:///C:/game.zip"]
        {
            assert!(validate_archive_url(url).is_err(), "{url}");
        }
        let fix = Fixture::new();
        assert!(scan_path("https://example.com/game.zip").is_err());
        assert!(!fix.root.join("launcher2/drafts").exists());
    }

    #[test]
    fn malicious_zip_symlink_cannot_become_a_game_file() {
        let fix = Fixture::new();
        let path = fix.root.join("fixture-game.zip");
        let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
        writer.start_file("Game.exe", SimpleFileOptions::default()).unwrap();
        writer.write_all(b"valid").unwrap();
        writer.add_symlink("data/evil.dll", "../../outside.dll",
            SimpleFileOptions::default()).unwrap();
        writer.finish().unwrap();
        assert!(scan_path(&path.display().to_string()).is_err());
        assert!(!fix.root.join("launcher2/drafts").exists());
    }

    #[test]
    fn invalid_cover_or_missing_executable_never_creates_a_draft() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Readme.txt",b"text"),("UnityPlayer.dll",b"lib")]);
        assert!(fix.create(&zip, "proposed-game").is_err());
        assert!(!fix.root.join("launcher2/drafts/proposed-game").exists());
        fix.zip(&[("Game.exe",b"binary")]);
        fs::write(fix.root.join("cover.png"), b"twelve bytes!").unwrap();
        assert!(fix.create(&zip, "proposed-game").is_err());
        assert!(!fix.root.join("launcher2/drafts/proposed-game").exists());
    }

    #[test]
    fn rejects_empty_existing_and_untrusted_draft_paths() {
        let fix = Fixture::new();
        let zip = fix.zip(&[("Game.exe",b"game")]);
        for id in ["a", "Upper-case", "with_underscore", "ends-with-"] {
            assert!(fix.create(&zip, id).is_err(), "accepted bad id: {id}");
        }
        let existing = fix.root.join("launcher2/drafts/prepared-game");
        fs::create_dir_all(&existing).unwrap();
        fs::write(existing.join("do-not-touch.txt"), b"existing").unwrap();
        assert!(fix.create(&zip, "prepared-game").is_err());
        assert_eq!(fs::read(existing.join("do-not-touch.txt")).unwrap(),b"existing");
        assert!(!existing.join("catalog-candidate.json").exists());
    }

    #[cfg(windows)]
    #[test]
    fn linked_input_and_linked_drafts_are_rejected_when_allowed() {
        use std::os::windows::fs::symlink_file;
        let fix = Fixture::new();
        let real = fix.zip(&[("Game.exe",b"valid")]);
        let link = fix.root.join("linked.zip");
        if symlink_file(&real, &link).is_ok() {
            assert!(scan_path(&link.display().to_string()).is_err());
        }
    }

    fn promotion_fixture() -> (Fixture, PathBuf) {
        let fix = Fixture::new();
        fs::create_dir_all(fix.root.join("assets/experiences")).unwrap();
        fs::create_dir_all(fix.root.join("launcher/experiences")).unwrap();
        let archive = fix.zip(&[("Game.exe", b"verified-executable"),
            ("UnityPlayer.dll", b"verified-unity"), ("docs/readme.txt", b"user files not touched")]);
        fix.create(&archive, "promotion-demo").unwrap();
        // Check byte preservation of unrelated catalog fields and CRLF. The
        // promotion must insert one entry, not reserialize existing JSON.
        let catalog = fix.root.join("launcher/catalog.template.json");
        let original = r#"{
    "schemaVersion": 1,
    "notes": {"other": "keep and experiences"},
    "experiences": [
        {"id": "existing-game", "name": "Existing"}
    ]
}
"#.replace("\n", "\r\n");
        fs::write(catalog, original.as_bytes()).unwrap();
        (fix, archive)
    }

    #[test]
    fn reviewed_native_promotion_preserves_original_catalog_format_and_publishes_verified_bytes() {
        let (fix, archive) = promotion_fixture();
        let root = fix.root.join("launcher2");
        let catalog_path = fix.root.join("launcher/catalog.template.json");
        let original = fs::read(&catalog_path).unwrap();
        let examined = prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).unwrap();
        assert_eq!(examined.review.status, "ready-for-reviewed-rights");
        assert_eq!(examined.review.archive_size, fs::metadata(&archive).unwrap().len());
        assert_eq!(examined.review.required_files_count, 2);
        assert_eq!(fs::read(&catalog_path).unwrap(), original);
        assert!(!fix.root.join("assets/experiences/promotion-demo.png").exists());
        assert!(!fix.root.join("launcher/experiences/promotion-demo.lock.json").exists());
        assert!(promote_with_root(&root, "promotion-demo", false, &archive.display().to_string()).is_err());
        assert_eq!(fs::read(&catalog_path).unwrap(), original);
        let outcome = promote_with_root(&root, "promotion-demo", true, &archive.display().to_string()).unwrap();
        assert_eq!(outcome.status, "promoted");
        let merged = fs::read(&catalog_path).unwrap();
        let as_text = std::str::from_utf8(&merged).unwrap();
        assert!(as_text.starts_with("{\r\n    \"schemaVersion\": 1,\r\n    \"notes\": {\"other\": \"keep"));
        assert!(as_text.contains("\"name\": \"Existing\"}"));
        assert!(as_text.contains("\r\n"));
        let new_catalog: Value = serde_json::from_slice(&merged).unwrap();
        let experiences = new_catalog["experiences"].as_array().unwrap();
        assert_eq!(experiences.len(), 2);
        assert_eq!(experiences[1]["id"], "promotion-demo");
        assert_eq!(fs::read(fix.root.join("assets/experiences/promotion-demo.png")).unwrap(),
                   fs::read(fix.root.join("launcher2/drafts/promotion-demo/cover.png")).unwrap());
        assert_eq!(fs::read(fix.root.join("launcher/experiences/promotion-demo.lock.json")).unwrap(),
                   fs::read(fix.root.join("launcher2/drafts/promotion-demo/source-lock.json")).unwrap());
        assert!(promote_with_root(&root, "promotion-demo", true, &archive.display().to_string()).is_err(),
            "duplicate ID cannot overwrite promoted files");
        assert_eq!(fs::read(&catalog_path).unwrap(), merged);
    }

    #[test]
    fn native_promotion_rejects_unreviewed_rights_mutated_draft_source_zip_and_conflicts() {
        let (fix, archive) = promotion_fixture();
        let root = fix.root.join("launcher2");
        let catalog = fix.root.join("launcher/catalog.template.json");
        let original = fs::read(&catalog).unwrap();
        let candidate_path = root.join("drafts/promotion-demo/catalog-candidate.json");
        let baseline = fs::read(&candidate_path).unwrap();
        let lock = root.join("drafts/promotion-demo/source-lock.json");
        let original_lock = fs::read(&lock).unwrap();
        assert!(promote_with_root(&root, "promotion-demo", false, "not even a local path").is_err());
        assert_eq!(fs::read(&catalog).unwrap(), original);
        fs::write(&archive, b"not a zip anymore").unwrap();
        assert!(prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).is_err());
        assert_eq!(fs::read(&catalog).unwrap(), original);
        fix.zip(&[("Game.exe", b"verified-executable"),
            ("UnityPlayer.dll", b"verified-unity"), ("docs/readme.txt", b"user files not touched")]);
        let mut proposal: Value = serde_json::from_slice(&baseline).unwrap();
        proposal["runtime"]["requiredFiles"][0]["path"] = serde_json::json!("../forged.exe");
        fs::write(&candidate_path, serde_json::to_vec(&proposal).unwrap()).unwrap();
        assert!(prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).is_err());
        fs::write(&candidate_path, &baseline).unwrap();
        proposal = serde_json::from_slice(&baseline).unwrap();
        proposal["unexpectedAdditionalPermissions"] = serde_json::json!(true);
        fs::write(&candidate_path, serde_json::to_vec(&proposal).unwrap()).unwrap();
        assert!(prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).is_err());
        fs::write(&candidate_path, &baseline).unwrap();
        let mut lock_value: Value = serde_json::from_slice(&original_lock).unwrap();
        lock_value["archive"]["sha256"] = serde_json::json!("0".repeat(64));
        fs::write(&lock, serde_json::to_vec(&lock_value).unwrap()).unwrap();
        assert!(prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).is_err());
        fs::write(&lock, &original_lock).unwrap();
        fs::write(fix.root.join("assets/experiences/promotion-demo.png"), b"owned-by-another-user").unwrap();
        assert!(prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).is_err());
        assert_eq!(fs::read(fix.root.join("assets/experiences/promotion-demo.png")).unwrap(),
                   b"owned-by-another-user");
        assert!(!fix.root.join("launcher/experiences/promotion-demo.lock.json").exists());
        assert_eq!(fs::read(&catalog).unwrap(), original);
    }

    #[test]
    fn catalog_cas_change_after_staged_cover_and_lock_rolls_back_only_own_files() {
        let (fix, archive) = promotion_fixture();
        let root = fix.root.join("launcher2");
        let catalog = fix.root.join("launcher/catalog.template.json");
        let prepared = prepare_promotion(&root, "promotion-demo", &archive.display().to_string()).unwrap();
        let mutation = b" \r\n".as_slice();
        let before = fs::read(&catalog).unwrap();
        let result = publish_promotion_with_hook(&root, prepared, || {
            OpenOptions::new().append(true).open(&catalog).unwrap().write_all(mutation).unwrap();
        });
        assert!(result.unwrap_err().contains("CAS refused"));
        let mut expected = before.clone();
        expected.extend_from_slice(mutation);
        assert_eq!(fs::read(&catalog).unwrap(), expected, "concurrent catalog text preserved exactly");
        assert!(!fix.root.join("launcher/experiences/promotion-demo.lock.json").exists());
        assert!(!fix.root.join("assets/experiences/promotion-demo.png").exists());
    }

    #[test]
    fn native_promotion_rejects_existing_lock_and_invalid_cover_before_changes() {
        let (fix, archive) = promotion_fixture();
        let root = fix.root.join("launcher2");
        let catalog = fix.root.join("launcher/catalog.template.json");
        let original = fs::read(&catalog).unwrap();
        let lock = fix.root.join("launcher/experiences/promotion-demo.lock.json");
        fs::write(&lock, b"preserve lock").unwrap();
        assert!(promote_with_root(&root, "promotion-demo", true, &archive.display().to_string()).is_err());
        assert_eq!(fs::read(&lock).unwrap(), b"preserve lock");
        fs::remove_file(&lock).unwrap();
        fs::write(root.join("drafts/promotion-demo/cover.png"), b"spoofed cover bytes").unwrap();
        assert!(promote_with_root(&root, "promotion-demo", true, &archive.display().to_string()).is_err());
        assert_eq!(fs::read(&catalog).unwrap(), original);
        assert!(!fix.root.join("assets/experiences/promotion-demo.png").exists());
        assert!(!lock.exists());
    }
}
