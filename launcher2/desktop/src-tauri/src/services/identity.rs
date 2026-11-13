//! Local/offline Minecraft identity. The existing identity.json is shared with Coco Launcher 1.
//! Never derive a Minecraft username from the Windows account or generate one implicitly:
//! changing the name changes the player's offline UUID and can detach game progress.

use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_IDENTITY_BYTES: u64 = 16 * 1024;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LocalIdentity {
    pub configured: bool,
    pub username: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SavedIdentity {
    schema_version: u32,
    mode: String,
    username: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OfflineIdentity<'a> {
    schema_version: u32,
    mode: &'static str,
    username: &'a str,
    uuid: &'static str,
    decision_source: &'static str,
    configured_at_utc: String,
}

/// A Minecraft offline name is an exact ASCII match; invalid characters are never stripped.
pub fn valid_minecraft_username(username: &str) -> bool {
    let bytes = username.as_bytes();
    (3..=16).contains(&bytes.len())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
}

pub fn identity_path_from_local_app_data(local_app_data: &Path) -> PathBuf {
    local_app_data
        .join("CocoMinecraftUpdater")
        .join("launcher")
        .join("identity.json")
}

fn live_identity_path() -> Result<PathBuf, String> {
    let local_app_data = std::env::var_os("LOCALAPPDATA")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "LOCALAPPDATA is unavailable".to_string())?;
    Ok(identity_path_from_local_app_data(Path::new(&local_app_data)))
}

/// Refuse filesystem redirection in any existing ancestor, including Windows junctions.
/// This also applies to the destination and to temporary files before replacement.
fn check_path(path: &Path) -> Result<(), String> {
    if !path.is_absolute() || path.components().any(|part| matches!(part, Component::ParentDir | Component::CurDir)) {
        return Err("Identity path must be absolute and contain no traversal".into());
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err("Identity path contains a symbolic link".into());
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    // FILE_ATTRIBUTE_REPARSE_POINT includes NTFS junctions.
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err("Identity path contains a reparse point".into());
                    }
                }
                if ancestor != path && !metadata.is_dir() {
                    return Err("Identity path has a non-directory ancestor".into());
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(error) => return Err(format!("Cannot inspect identity path: {error}")),
        }
    }
    Ok(())
}

fn read_existing_identity(path: &Path) -> Result<Option<SavedIdentity>, String> {
    check_path(path)?;
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("Cannot inspect identity file: {error}")),
    };
    if !metadata.is_file() || metadata.len() > MAX_IDENTITY_BYTES {
        return Err("Identity file is not a valid small regular file".into());
    }
    let bytes = fs::read(path).map_err(|error| format!("Cannot read identity file: {error}"))?;
    if bytes.len() as u64 > MAX_IDENTITY_BYTES {
        return Err("Identity file exceeds its size limit".into());
    }
    let saved: SavedIdentity =
        serde_json::from_slice(&bytes).map_err(|error| format!("Invalid identity JSON: {error}"))?;
    if saved.schema_version != 1 || !matches!(saved.mode.as_str(), "offline" | "microsoft") {
        return Err("Unsupported identity schema or mode".into());
    }
    if !valid_minecraft_username(&saved.username) {
        return Err("Saved identity has an invalid Minecraft username".into());
    }
    // Old versions stored a Microsoft mode. Reusing its valid display name
    // protects the player's name; no credentials or tokens are copied.
    Ok(Some(saved))
}

/// Read a specifically supplied path (suitable for sandboxed tests).
/// Corrupt or redirected identity state fails closed, rather than looking unconfigured.
pub fn get_local_identity_at_path(path: &Path) -> Result<LocalIdentity, String> {
    Ok(match read_existing_identity(path)? {
        Some(saved) => LocalIdentity {
            configured: true,
            username: Some(saved.username),
        },
        None => LocalIdentity {
            configured: false,
            username: None,
        },
    })
}

#[tauri::command]
pub async fn get_local_identity() -> Result<LocalIdentity, String> {
    tauri::async_runtime::spawn_blocking(|| get_local_identity_at_path(&live_identity_path()?))
        .await.map_err(|error| format!("Identity read interrupted: {error}"))?
}

fn utc_now() -> Result<String, String> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("Cannot determine UTC time: {error}"))?;
    let seconds = duration.as_secs();
    let (year, month, day) = civil_date((seconds / 86_400) as i64);
    let time = seconds % 86_400;
    Ok(format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        time / 3600,
        (time / 60) % 60,
        time % 60,
        duration.subsec_millis()
    ))
}

// Civil date from days since Unix epoch (proleptic Gregorian).
fn civil_date(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    if month <= 2 {
        year += 1;
    }
    (year, month, day)
}

struct RemoveTemp(PathBuf);
impl Drop for RemoveTemp {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[cfg(windows)]
pub(crate) fn atomic_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::iter::once;
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "Kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, target: *const u16, flags: u32) -> i32;
    }
    let source = source.as_os_str().encode_wide().chain(once(0)).collect::<Vec<_>>();
    let destination = destination.as_os_str().encode_wide().chain(once(0)).collect::<Vec<_>>();
    // Same-directory rename with replacement and write-through; Windows std::fs::rename
    // does not replace existing files consistently across supported configurations.
    let success = unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), 0x1 | 0x8) };
    if success == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
pub(crate) fn atomic_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

/// Create or reuse the existing identity. To change a name, call the separate
/// confirmation operation with the exact currently saved name.
pub fn set_local_identity_at_path(path: &Path, username: &str) -> Result<LocalIdentity, String> {
    write_local_identity_at_path(path, username, None)
}

/// The caller must show an explicit confirmation to the player before calling this
/// operation. Requiring the prior name prevents stale dialogs from overwriting it.
pub fn confirm_local_identity_change_at_path(
    path: &Path,
    username: &str,
    confirmed_previous_username: &str,
) -> Result<LocalIdentity, String> {
    if !valid_minecraft_username(confirmed_previous_username) {
        return Err("Confirmation must include the current valid username".into());
    }
    write_local_identity_at_path(path, username, Some(confirmed_previous_username))
}

fn write_local_identity_at_path(
    path: &Path,
    username: &str,
    confirmed_previous_username: Option<&str>,
) -> Result<LocalIdentity, String> {
    if !valid_minecraft_username(username) {
        return Err("Minecraft username must be 3-16 ASCII letters, digits or underscore".into());
    }
    let existing = read_existing_identity(path)?;
    match existing.as_ref() {
        Some(saved) if saved.username == username => {
            // Preserve all original state and its timestamp when nothing changed.
            return Ok(LocalIdentity { configured: true, username: Some(saved.username.clone()) });
        }
        Some(saved) if confirmed_previous_username != Some(saved.username.as_str()) => {
            return Err("Identity change requires explicit confirmation of the saved username".into());
        }
        None if confirmed_previous_username.is_some() => {
            return Err("Saved identity changed while confirming; reload it".into());
        }
        _ => {}
    }

    let parent = path.parent().ok_or_else(|| "Identity file has no parent directory".to_string())?;
    fs::create_dir_all(parent).map_err(|error| format!("Cannot create identity directory: {error}"))?;
    check_path(path)?;
    let state = OfflineIdentity {
        schema_version: 1,
        mode: "offline",
        username,
        uuid: "",
        decision_source: "user-confirmed",
        configured_at_utc: utc_now()?,
    };
    let payload = serde_json::to_vec(&state).map_err(|error| format!("Cannot serialize identity: {error}"))?;
    let id = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temp = parent.join(format!(".identity.json.tmp-{}-{id}", std::process::id()));
    check_path(&temp)?;
    let cleanup = RemoveTemp(temp.clone());
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|error| format!("Cannot open temporary identity file: {error}"))?;
    file.write_all(&payload)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("Cannot write temporary identity file: {error}"))?;
    drop(file);
    // Recheck redirection and the precondition immediately before the rename.
    check_path(path)?;
    let latest = read_existing_identity(path)?;
    if latest.as_ref().map(|saved| saved.username.as_str())
        != existing.as_ref().map(|saved| saved.username.as_str())
    {
        return Err("Identity changed during save; reload and confirm again".into());
    }
    atomic_replace(&temp, path).map_err(|error| format!("Cannot atomically replace identity: {error}"))?;
    drop(cleanup);
    get_local_identity_at_path(path)
}

#[tauri::command]
pub fn set_local_identity(username: String) -> Result<LocalIdentity, String> {
    set_local_identity_at_path(&live_identity_path()?, &username)
}

/// Register this as a separate Tauri command and only invoke it from a confirmed
/// identity-change dialog; the previous name must match the persisted one.
#[tauri::command]
pub fn confirm_local_identity_change(
    username: String,
    confirmed_previous_username: String,
) -> Result<LocalIdentity, String> {
    confirm_local_identity_change_at_path(
        &live_identity_path()?,
        &username,
        &confirmed_previous_username,
    )
}

const AVATAR_PREFIX: &str = "data:image/webp;base64,";
const MAX_AVATAR_BYTES: usize = 256 * 1024;

fn live_avatar_path() -> Result<PathBuf, String> {
    Ok(live_identity_path()?.with_file_name("avatar.webp"))
}

/// The picture is decoded and shrunk to a small WebP by the page, so only that exact
/// format is stored here. Anything else was not produced by Coco and is refused.
fn decode_avatar(data_url: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    let encoded = data_url.strip_prefix(AVATAR_PREFIX).ok_or("La foto debe ser WebP")?;
    if encoded.len() > MAX_AVATAR_BYTES / 3 * 4 + 4 {
        return Err("La foto es demasiado grande".into());
    }
    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)
        .map_err(|_| "La foto no se pudo leer".to_string())?;
    if bytes.len() > MAX_AVATAR_BYTES {
        return Err("La foto es demasiado grande".into());
    }
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WEBP" {
        return Err("La foto debe ser WebP".into());
    }
    Ok(bytes)
}

fn write_avatar_at_path(path: &Path, data_url: &str) -> Result<(), String> {
    let bytes = decode_avatar(data_url)?;
    let parent = path.parent().ok_or_else(|| "Avatar file has no parent directory".to_string())?;
    fs::create_dir_all(parent).map_err(|error| format!("Cannot create profile directory: {error}"))?;
    check_path(path)?;
    let id = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temp = parent.join(format!(".avatar.webp.tmp-{}-{id}", std::process::id()));
    let cleanup = RemoveTemp(temp.clone());
    let mut file = OpenOptions::new().write(true).create_new(true).open(&temp)
        .map_err(|error| format!("Cannot open temporary avatar file: {error}"))?;
    file.write_all(&bytes).and_then(|_| file.sync_all())
        .map_err(|error| format!("Cannot write avatar: {error}"))?;
    drop(file);
    atomic_replace(&temp, path).map_err(|error| format!("Cannot replace avatar: {error}"))?;
    drop(cleanup);
    Ok(())
}

fn read_avatar_at_path(path: &Path) -> Result<Option<String>, String> {
    use base64::Engine;
    check_path(path)?;
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("Cannot read avatar: {error}")),
    };
    let encoded = format!("{AVATAR_PREFIX}{}", base64::engine::general_purpose::STANDARD.encode(bytes));
    // A file changed by hand simply reads as no picture.
    Ok(decode_avatar(&encoded).ok().map(|_| encoded))
}

#[tauri::command]
pub async fn get_profile_avatar() -> Result<Option<String>, String> {
    tauri::async_runtime::spawn_blocking(|| read_avatar_at_path(&live_avatar_path()?))
        .await.map_err(|error| format!("Avatar read interrupted: {error}"))?
}

#[tauri::command]
pub async fn set_profile_avatar(data_url: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || write_avatar_at_path(&live_avatar_path()?, &data_url))
        .await.map_err(|error| format!("Avatar save interrupted: {error}"))?
}

#[tauri::command]
pub async fn remove_profile_avatar() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(|| {
        let path = live_avatar_path()?;
        check_path(&path)?;
        match fs::remove_file(&path) {
            Err(error) if error.kind() != ErrorKind::NotFound => Err(format!("Cannot remove avatar: {error}")),
            _ => Ok(()),
        }
    }).await.map_err(|error| format!("Avatar removal interrupted: {error}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn avatar_round_trips_and_only_a_small_webp_is_stored() {
        use base64::Engine;
        let root = TestRoot::new();
        let path = root.0.join("launcher").join("avatar.webp");
        let url = |bytes: &[u8]| format!("{AVATAR_PREFIX}{}", base64::engine::general_purpose::STANDARD.encode(bytes));
        assert_eq!(read_avatar_at_path(&path).unwrap(), None);
        let mut webp = b"RIFF\0\0\0\0WEBP".to_vec();
        webp.extend_from_slice(&[7; 64]);
        write_avatar_at_path(&path, &url(&webp)).unwrap();
        assert_eq!(read_avatar_at_path(&path).unwrap(), Some(url(&webp)));
        assert!(write_avatar_at_path(&path, &url(b"<svg onload=alert(1)>........")).is_err(), "not a WebP");
        assert!(write_avatar_at_path(&path, "data:text/html;base64,AAAA").is_err());
        let mut huge = webp.clone();
        huge.resize(MAX_AVATAR_BYTES + 1, 0);
        assert!(write_avatar_at_path(&path, &url(&huge)).is_err());
        assert_eq!(read_avatar_at_path(&path).unwrap(), Some(url(&webp)), "a refused picture keeps the previous one");
        fs::write(&path, b"garbage").unwrap();
        assert_eq!(read_avatar_at_path(&path).unwrap(), None);
    }
    use std::sync::atomic::{AtomicU64, Ordering};
    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct TestRoot(PathBuf);
    impl TestRoot {
        fn new() -> Self {
            let id = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "coco-launcher-identity-test-{}-{id}", std::process::id()
            ));
            fs::create_dir(&path).expect("isolated test directory");
            Self(path)
        }
        fn identity(&self) -> PathBuf {
            identity_path_from_local_app_data(&self.0)
        }
    }
    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn only_exact_ascii_username_is_allowed() {
        for good in ["abc", "Player_42", "0123456789abcdef"] {
            assert!(valid_minecraft_username(good), "{good}");
        }
        for bad in ["", "ab", "abcdefghijklmnopq", "ab!c", "foo bar", "ábc", "abc\n", "x/y"] {
            assert!(!valid_minecraft_username(bad), "{bad:?}");
        }
    }

    #[test]
    fn creating_and_reusing_identity_is_safe_and_compatible() {
        let root = TestRoot::new();
        let path = root.identity();
        assert_eq!(get_local_identity_at_path(&path).unwrap(), LocalIdentity {
            configured: false, username: None
        });
        assert_eq!(set_local_identity_at_path(&path, "Player_42").unwrap().username.as_deref(), Some("Player_42"));
        let bytes = fs::read(&path).unwrap();
        let record: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(record["schemaVersion"], 1);
        assert_eq!(record["mode"], "offline");
        assert_eq!(record["uuid"], "");
        assert_eq!(record["decisionSource"], "user-confirmed");
        assert!(record["configuredAtUtc"].as_str().unwrap().ends_with('Z'));
        set_local_identity_at_path(&path, "Player_42").unwrap();
        assert_eq!(bytes, fs::read(&path).unwrap(), "idempotent save must not rewrite identity");
    }

    #[test]
    fn changing_name_requires_confirmation_of_current_identity() {
        let root = TestRoot::new();
        let path = root.identity();
        set_local_identity_at_path(&path, "Original").unwrap();
        let before = fs::read(&path).unwrap();
        assert!(set_local_identity_at_path(&path, "Different").is_err());
        assert!(confirm_local_identity_change_at_path(&path, "Different", "Other").is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
        confirm_local_identity_change_at_path(&path, "Different", "Original").unwrap();
        assert_eq!(get_local_identity_at_path(&path).unwrap().username.as_deref(), Some("Different"));
        assert!(confirm_local_identity_change_at_path(&path, "Original", "Original").is_err());
    }

    #[test]
    fn invalid_existing_state_is_not_silently_overwritten() {
        let root = TestRoot::new();
        let path = root.identity();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, br#"{"schemaVersion":1,"mode":"offline","username":"ab!c"}"#).unwrap();
        let original = fs::read(&path).unwrap();
        assert!(get_local_identity_at_path(&path).is_err());
        assert!(set_local_identity_at_path(&path, "ValidName").is_err());
        assert_eq!(fs::read(&path).unwrap(), original);
    }

    #[test]
    fn legacy_microsoft_name_is_reused_without_guessing_or_copying_credentials() {
        let root = TestRoot::new();
        let path = root.identity();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, br#"{"schemaVersion":1,"mode":"microsoft","username":"Legacy","uuid":"1234","token":"secret"}"#).unwrap();
        assert_eq!(get_local_identity_at_path(&path).unwrap().username.as_deref(), Some("Legacy"));
        assert!(set_local_identity_at_path(&path, "Changed").is_err());
        assert!(fs::read_to_string(&path).unwrap().contains("secret"));
    }

    #[cfg(unix)]
    #[test]
    fn symlink_parent_and_identity_file_are_rejected() {
        use std::os::unix::fs::symlink;
        let root = TestRoot::new();
        let outside = root.0.join("outside");
        fs::create_dir(&outside).unwrap();
        let linked = root.0.join("linked");
        symlink(&outside, &linked).unwrap();
        let path = linked.join("identity.json");
        assert!(get_local_identity_at_path(&path).is_err());
        assert!(set_local_identity_at_path(&path, "Player").is_err());
        let target = root.0.join("real.json");
        fs::write(&target, "{}").unwrap();
        let leaf = outside.join("identity.json");
        symlink(&target, &leaf).unwrap();
        assert!(get_local_identity_at_path(&leaf).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn windows_reparse_parent_is_rejected_when_symlinks_are_available() {
        use std::os::windows::fs::symlink_dir;
        let root = TestRoot::new();
        let real = root.0.join("real");
        fs::create_dir(&real).unwrap();
        let redirected = root.0.join("redirected");
        // Creating symbolic links may require Developer Mode or elevated permissions.
        // A machine without that ability must not create a weaker substitute.
        if symlink_dir(&real, &redirected).is_err() {
            return;
        }
        let identity = redirected.join("identity.json");
        assert!(get_local_identity_at_path(&identity).is_err());
        assert!(set_local_identity_at_path(&identity, "Player_42").is_err());
        assert!(!real.join("identity.json").exists());
    }

    #[test]
    fn civil_date_matches_known_utc_dates() {
        assert_eq!(civil_date(0), (1970, 1, 1));
        assert_eq!(civil_date(10_957), (2000, 1, 1));
        assert_eq!(civil_date(20_000), (2024, 10, 4));
    }
}
