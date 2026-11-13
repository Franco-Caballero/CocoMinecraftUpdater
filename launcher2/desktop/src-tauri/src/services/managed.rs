//! Read-only managed Minecraft preflight. No downloads, instance repairs or game launch.
//! The manifest is generated at build time; only pinned assets are inspected.
use crate::services::inventory;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

const MAX_MANIFEST_ENTRIES: usize = 200_000;
const HASH_BUFFER_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedManifest {
    id: String,
    instance_id: String,
    workflow: String,
    minecraft_version: String,
    loader: String,
    #[serde(default)]
    loader_version: String,
    assets: Vec<ManagedFile>,
    #[serde(default)]
    extra_files: Vec<ManagedFile>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedFile {
    path: String,
    sha256: String,
    size: u64,
    #[serde(default = "default_role")]
    role: String,
}

fn default_role() -> String {
    "all".into()
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedFileState {
    pub path: String,
    pub source: &'static str,
    pub role: String,
    pub expected_bytes: u64,
    pub actual_bytes: Option<u64>,
    pub status: &'static str,
    pub issue: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedPlan {
    pub id: String,
    pub instance_id: String,
    pub role: String,
    pub minecraft_version: String,
    pub loader: String,
    pub loader_version: String,
    pub location: &'static str,
    pub instance_path: String,
    pub status: &'static str,
    pub total: usize,
    pub present: usize,
    pub verified: usize,
    pub missing: usize,
    pub corrupt: usize,
    pub expected_bytes: u64,
    pub present_bytes: u64,
    pub verified_bytes: u64,
    pub missing_bytes: u64,
    pub corrupt_bytes: u64,
    pub files: Vec<ManagedFileState>,
}

fn valid_identifier(value: &str) -> bool {
    (2..=64).contains(&value.len())
        && value.as_bytes()[0].is_ascii_lowercase()
        && value.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn valid_role(role: &str) -> bool {
    matches!(role, "all" | "host" | "client")
}

fn is_protected_part(part: &str) -> bool {
    matches!(
        part.to_ascii_lowercase().as_str(),
        "saves"
            | "playerdata"
            | "advancements"
            | "stats"
            | "distanthorizons"
            | "distant_horizons"
            | "distant_horizons_server_data"
            | "dh"
    )
}

/// Reject traversal, Windows ADS, UNC, reserved file names, and paths inside user-owned saves.
/// The manifest convention is forward-slash separated relative paths only.
fn safe_managed_path(value: &str) -> Result<PathBuf, String> {
    if value.is_empty()
        || value.starts_with('/')
        || value.contains('\\')
        || value.contains(':')
        || value.len() > 1024
    {
        return Err(format!("Unsafe managed file path: {value}"));
    }
    for part in value.split('/') {
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.ends_with('.')
            || part.ends_with(' ')
            || part.chars().any(|c| c.is_control() || "<>\"|?*".contains(c))
            || is_protected_part(part)
        {
            return Err(format!("Unsafe managed file component: {value}"));
        }
        let device = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        if matches!(device.as_str(), "CON" | "PRN" | "AUX" | "NUL")
            || (device.len() == 4
                && (device.starts_with("COM") || device.starts_with("LPT"))
                && matches!(device.as_bytes()[3], b'1'..=b'9'))
        {
            return Err(format!("Reserved Windows file name: {value}"));
        }
    }
    Ok(PathBuf::from(value))
}

fn validate_manifest(manifest: &ManagedManifest) -> Result<(), String> {
    if !valid_identifier(&manifest.id)
        || !valid_identifier(&manifest.instance_id)
        || manifest.workflow != "coco-managed"
        || manifest.minecraft_version.trim().is_empty()
        || manifest.loader.trim().is_empty()
        || manifest.assets.len() + manifest.extra_files.len() > MAX_MANIFEST_ENTRIES
    {
        return Err(format!("Invalid managed manifest: {}", manifest.id));
    }
    let mut seen = HashMap::<String, (u64, String)>::new();
    for file in manifest.assets.iter().chain(&manifest.extra_files) {
        safe_managed_path(&file.path)?;
        if !valid_role(&file.role)
            || file.sha256.len() != 64
            || !file.sha256.bytes().all(|ch| ch.is_ascii_hexdigit())
        {
            return Err(format!("Invalid role or SHA-256 for {}", file.path));
        }
        // The generated source can repeat identical role-specific assets in both lists.
        // Allow byte-identical destinations, but reject inconsistent size/digest.
        // Windows paths are case-insensitive.
        if let Some((size, hash)) = seen.insert(
            file.path.to_ascii_lowercase(),
            (file.size, file.sha256.to_ascii_lowercase()),
        ) {
            if size != file.size || hash != file.sha256.to_ascii_lowercase() {
                return Err(format!("Conflicting managed destination: {}", file.path));
            }
        }
    }
    Ok(())
}

fn parse_manifests(bytes: &[u8]) -> Result<Vec<ManagedManifest>, String> {
    let manifests: Vec<ManagedManifest> = serde_json::from_slice(bytes)
        .map_err(|error| format!("Invalid managed manifests JSON: {error}"))?;
    let mut seen_ids = HashSet::new();
    for manifest in &manifests {
        validate_manifest(manifest)?;
        if !seen_ids.insert(&manifest.id) {
            return Err(format!("Duplicate managed manifest ID: {}", manifest.id));
        }
    }
    Ok(manifests)
}

fn selected_manifest<'a>(all: &'a [ManagedManifest], id: &str) -> Result<&'a ManagedManifest, String> {
    all.iter().find(|entry| entry.id == id)
        .ok_or_else(|| format!("Unknown managed experience: {id}"))
}

fn local_instance_path(manifest: &ManagedManifest, app_data: &Path, local_data: &Path)
    -> Result<(PathBuf, &'static str), String>
{
    let locations = inventory::custom_locations(local_data)?;
    let custom = inventory::custom_path(&locations, &manifest.instance_id, &manifest.id);
    let (root, location) = match custom {
        Some(value) => (PathBuf::from(value), "custom"),
        None => (
            app_data.join("CocoMinecraft").join("experiences").join(&manifest.instance_id),
            "default",
        ),
    };
    if !root.is_absolute() || root.to_string_lossy().starts_with("\\\\") {
        return Err("Managed instance must be on an absolute local path".into());
    }
    Ok((root, location))
}

/// Do not follow symlinks, junctions or any other Windows reparse point.
/// This applies to each existing path component before a file is opened.
fn ensure_no_redirection(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(format!("Linked path is not trusted: {}", ancestor.display()));
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err(format!("Reparse path is not trusted: {}", ancestor.display()));
                    }
                }
                if ancestor != path && !metadata.is_dir() {
                    return Err(format!("Non-directory parent: {}", ancestor.display()));
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(format!("Cannot inspect path {}: {error}", ancestor.display())),
        }
    }
    Ok(())
}

fn inspect_file(root: &Path, file: &ManagedFile, source: &'static str) -> ManagedFileState {
    let mut state = ManagedFileState {
        path: file.path.clone(),
        source,
        role: file.role.clone(),
        expected_bytes: file.size,
        actual_bytes: None,
        status: "missing",
        issue: None,
    };
    let path = root.join(&file.path);
    // A redirected path must not be hashed, even if it appears to point inside the root.
    if let Err(error) = ensure_no_redirection(&path) {
        state.status = "corrupt";
        state.issue = Some(error);
        return state;
    }
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return state,
        Err(error) => {
            state.status = "corrupt";
            state.issue = Some(format!("Cannot inspect {}: {error}", file.path));
            return state;
        }
    };
    state.actual_bytes = Some(metadata.len());
    if !metadata.is_file() {
        state.status = "corrupt";
        state.issue = Some("Expected a regular file".into());
        return state;
    }
    if metadata.len() != file.size {
        state.status = "corrupt";
        state.issue = Some("File size differs from pinned manifest".into());
        return state;
    }
    let mut source_file = match File::open(&path) {
        Ok(value) => value,
        Err(error) => {
            state.status = "corrupt";
            state.issue = Some(format!("Cannot open {}: {error}", file.path));
            return state;
        }
    };
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; HASH_BUFFER_BYTES];
    let mut counted = 0_u64;
    loop {
        match source_file.read(&mut buffer) {
            Ok(0) => break,
            Ok(amount) => {
                counted += amount as u64;
                if counted > file.size {
                    break;
                }
                hasher.update(&buffer[..amount]);
            }
            Err(error) => {
                state.status = "corrupt";
                state.issue = Some(format!("Cannot hash {}: {error}", file.path));
                return state;
            }
        }
    }
    if counted == file.size && format!("{:x}", hasher.finalize()).eq_ignore_ascii_case(&file.sha256) {
        state.status = "verified";
    } else {
        state.status = "corrupt";
        state.issue = Some("File content differs from pinned SHA-256".into());
    }
    state
}

/// Purely read-only synchronous worker that can be called in tests against fake roots.
fn plan_managed_with_manifests(
    manifests: &[ManagedManifest],
    id: &str,
    role: &str,
    app_data: &Path,
    local_data: &Path,
) -> Result<ManagedPlan, String> {
    if !matches!(role, "host" | "client") {
        return Err("Managed role must be 'host' or 'client'".into());
    }
    let manifest = selected_manifest(manifests, id)?;
    validate_manifest(manifest)?;
    let (root, location) = local_instance_path(manifest, app_data, local_data)?;
    ensure_no_redirection(&root)?;
    let mut result = ManagedPlan {
        id: manifest.id.clone(),
        instance_id: manifest.instance_id.clone(),
        role: role.into(),
        minecraft_version: manifest.minecraft_version.clone(),
        loader: manifest.loader.clone(),
        loader_version: manifest.loader_version.clone(),
        location,
        instance_path: root.to_string_lossy().into_owned(),
        status: "incomplete",
        total: 0,
        present: 0,
        verified: 0,
        missing: 0,
        corrupt: 0,
        expected_bytes: 0,
        present_bytes: 0,
        verified_bytes: 0,
        missing_bytes: 0,
        corrupt_bytes: 0,
        files: Vec::new(),
    };
    let mut selected_destinations = HashSet::new();
    for (files, source) in [
        (manifest.assets.as_slice(), "asset"),
        (manifest.extra_files.as_slice(), "extra"),
    ] {
        for file in files {
            if file.role != "all" && file.role != role {
                continue;
            }
            // Duplicate entries with identical pinned bytes count as one physical
            // destination, avoiding false "missing" and double-counted bytes.
            if !selected_destinations.insert(file.path.to_ascii_lowercase()) {
                continue;
            }
            let inspected = inspect_file(&root, file, source);
            result.total += 1;
            result.expected_bytes = result.expected_bytes.checked_add(file.size)
                .ok_or("Expected managed bytes overflow")?;
            if let Some(bytes) = inspected.actual_bytes {
                result.present += 1;
                result.present_bytes = result.present_bytes.checked_add(bytes)
                    .ok_or("Present managed bytes overflow")?;
            }
            match inspected.status {
                "verified" => {
                    result.verified += 1;
                    result.verified_bytes += file.size;
                }
                "missing" => {
                    result.missing += 1;
                    result.missing_bytes += file.size;
                }
                _ => {
                    result.corrupt += 1;
                    result.corrupt_bytes += file.size;
                }
            }
            result.files.push(inspected);
        }
    }
    result.status = if result.total == 0 {
        "no-files"
    } else if result.verified == result.total {
        "verified"
    } else {
        "incomplete"
    };
    Ok(result)
}

/// Production manifest is emitted by the catalog generator and embedded as a build resource.
/// Keeping it private removes any dependency on untrusted UI-supplied file lists.
fn embedded_manifests() -> Result<Vec<ManagedManifest>, String> {
    parse_manifests(include_bytes!("../../resources/managed-manifests.json"))
}

#[tauri::command]
pub async fn plan_managed(id: String, role: String) -> Result<ManagedPlan, String> {
    let manifests = embedded_manifests()?;
    let app_data = std::env::var_os("APPDATA").map(PathBuf::from)
        .ok_or("APPDATA unavailable")?;
    let local_data = std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
        .ok_or("LOCALAPPDATA unavailable")?;
    tauri::async_runtime::spawn_blocking(move || {
        plan_managed_with_manifests(&manifests, &id, &role, &app_data, &local_data)
    }).await.map_err(|error| format!("Managed preflight interrupted: {error}"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static FIXTURE_INDEX: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let seq = FIXTURE_INDEX.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!("coco2-managed-test-{}-{seq}", std::process::id()));
            fs::create_dir(&root).unwrap();
            Self(root)
        }
        fn app_data(&self) -> PathBuf { self.0.join("AppData") }
        fn local_data(&self) -> PathBuf { self.0.join("LocalAppData") }
        fn game(&self) -> PathBuf {
            self.app_data().join("CocoMinecraft").join("experiences").join("test-game")
        }
        fn put(&self, rel: &str, bytes: &[u8]) {
            let path = self.game().join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, bytes).unwrap();
        }
        fn plan(&self, manifest: &ManagedManifest, role: &str) -> Result<ManagedPlan, String> {
            plan_managed_with_manifests(std::slice::from_ref(manifest), &manifest.id, role,
                &self.app_data(), &self.local_data())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
    }
    fn file(path: &str, bytes: &[u8], role: &str) -> ManagedFile {
        ManagedFile {
            path: path.into(),
            sha256: format!("{:x}", Sha256::digest(bytes)),
            size: bytes.len() as u64,
            role: role.into(),
        }
    }
    fn manifest() -> ManagedManifest {
        ManagedManifest {
            id: "test-game".into(),
            instance_id: "test-game".into(),
            workflow: "coco-managed".into(),
            minecraft_version: "1.20.1".into(),
            loader: "fabric".into(),
            loader_version: "0.16.10".into(),
            assets: vec![file("mods/shared.jar", b"shared", "all"),
                file("mods/host.jar", b"host", "host"),
                file("mods/client.jar", b"client", "client")],
            extra_files: vec![file("config/extra.json", b"extra", "all")],
        }
    }
    #[test]
    fn role_gating_counts_only_relevant_files() {
        let fixture = Fixture::new();
        fixture.put("mods/shared.jar", b"shared");
        fixture.put("mods/host.jar", b"host");
        fixture.put("config/extra.json", b"extra");
        let host = fixture.plan(&manifest(), "host").unwrap();
        assert_eq!((host.total, host.present, host.verified, host.missing, host.corrupt), (3, 3, 3, 0, 0));
        assert_eq!(host.status, "verified");
        assert_eq!(host.expected_bytes, 6 + 4 + 5);
        assert!(host.files.iter().all(|item| item.path != "mods/client.jar"));
        let client = fixture.plan(&manifest(), "client").unwrap();
        assert_eq!((client.total, client.present, client.verified, client.missing), (3, 2, 2, 1));
        assert_eq!(client.status, "incomplete");
        assert_eq!(client.missing_bytes, 6);
        assert!(fixture.plan(&manifest(), "all").is_err());
    }
    #[test]
    fn hash_and_size_mismatch_are_corrupt_not_verified() {
        let fixture = Fixture::new();
        fixture.put("mods/shared.jar", b"SHARED");
        fixture.put("mods/host.jar", b"wrong size");
        let result = fixture.plan(&manifest(), "host").unwrap();
        assert_eq!((result.verified, result.corrupt, result.missing), (0, 2, 1));
        assert_eq!(result.present, 2);
        assert!(result.files.iter().any(|item| item.path == "mods/shared.jar" && item.status == "corrupt"));
        assert_eq!(result.corrupt_bytes, 6 + 4);
    }
    #[test]
    fn traversal_sensitive_directories_invalid_roles_and_hashes_are_rejected() {
        for path in ["../saves/world", "mods/../escape", "/absolute", "C:/escape",
            "mods\\thing.jar", "mods//duplicate", "mods/CON.jar", "saves/level.dat",
            "config/playerdata/x", "distant_horizons/region", "foo/aux.txt"]
        {
            assert!(safe_managed_path(path).is_err(), "{path}");
        }
        let mut m = manifest();
        m.assets[0].role = "server".into();
        assert!(validate_manifest(&m).is_err());
        m.assets[0].role = "all".into();
        m.assets[0].sha256 = "0".repeat(63);
        assert!(validate_manifest(&m).is_err());
        m.assets[0].sha256 = "z".repeat(64);
        assert!(validate_manifest(&m).is_err());
        m = manifest();
        m.extra_files[0].path = "MODS/SHARED.jar".into();
        assert!(validate_manifest(&m).is_err());
    }
    #[test]
    fn custom_location_comes_from_inventory_map_without_modifying_it() {
        let fixture = Fixture::new();
        let local = fixture.local_data();
        let custom = fixture.0.join("MyCustomGame");
        fs::create_dir_all(custom.join("mods")).unwrap();
        fs::write(custom.join("mods/shared.jar"), b"shared").unwrap();
        let locations = local.join("CocoMinecraftUpdater").join("instance-locations.json");
        fs::create_dir_all(locations.parent().unwrap()).unwrap();
        fs::write(&locations,
            serde_json::to_vec(&serde_json::json!({"test-game": custom.to_string_lossy()})).unwrap()
        ).unwrap();
        let before = fs::read(&locations).unwrap();
        let plan = fixture.plan(&manifest(), "client").unwrap();
        assert_eq!(plan.location, "custom");
        assert_eq!(plan.verified, 1);
        assert_eq!(plan.missing, 2);
        assert_eq!(fs::read(&locations).unwrap(), before);
        assert!(!fixture.game().exists());
    }
    #[test]
    fn parsed_manifests_validate_schema_and_unique_ids() {
        let input = serde_json::json!([{
            "id":"test-game", "instanceId":"test-game", "workflow":"coco-managed",
            "minecraftVersion":"1.20.1", "loader":"fabric", "loaderVersion":"0.16.10",
            "assets":[{"path":"mods/shared.jar","sha256":format!("{:x}", Sha256::digest(b"x")),"size":1,"role":"all"}],
            "extraFiles":[]
        }]);
        let records = parse_manifests(&serde_json::to_vec(&input).unwrap()).unwrap();
        assert_eq!(records.len(), 1);
        let duplicated = serde_json::json!([input[0].clone(), input[0].clone()]);
        assert!(parse_manifests(&serde_json::to_vec(&duplicated).unwrap()).is_err());
    }

    #[test]
    fn byte_identical_duplicate_assets_are_counted_only_once() {
        let fixture = Fixture::new();
        fixture.put("mods/host.jar", b"host");
        let mut manifest = manifest();
        manifest.assets.retain(|file| file.path == "mods/host.jar");
        manifest.extra_files = manifest.assets.clone();
        assert!(validate_manifest(&manifest).is_ok());
        let plan = fixture.plan(&manifest, "host").unwrap();
        assert_eq!((plan.total, plan.verified, plan.expected_bytes), (1, 1, 4));
        manifest.extra_files[0].sha256 = "0".repeat(64);
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn embedded_private_manifests_have_valid_roles_and_destinations() {
        let records = embedded_manifests().expect("managed manifests must pass full validation");
        assert!(!records.is_empty());
        assert!(records.iter().all(|record| record.workflow == "coco-managed"));
        assert!(records.iter().all(|record| !record.assets.is_empty()));
    }

    #[test]
    fn no_role_matching_files_is_not_a_verified_installation() {
        let fixture = Fixture::new();
        let mut manifest = manifest();
        manifest.assets.retain(|file| file.role == "host");
        manifest.extra_files.clear();
        let plan = fixture.plan(&manifest, "client").unwrap();
        assert_eq!((plan.total, plan.verified, plan.missing), (0, 0, 0));
        assert_eq!(plan.status, "no-files");
    }
    #[cfg(unix)]
    #[test]
    fn symlink_is_not_hashed_even_if_target_is_valid() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        fixture.put("mods/real.jar", b"shared");
        symlink("real.jar", fixture.game().join("mods/shared.jar")).unwrap();
        let plan = fixture.plan(&manifest(), "host").unwrap();
        assert_eq!(plan.files[0].status, "corrupt");
    }
}
