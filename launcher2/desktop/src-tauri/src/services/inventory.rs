use crate::services::catalog;
use serde::Serialize;
use serde_json::{Map, Value};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstancePresence {
    id: String,
    state: &'static str,
    location: &'static str,
}

fn directory_state(path: &Path) -> &'static str {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => "folder-present",
        Ok(_) => "unknown",
        Err(error) if error.kind() == ErrorKind::NotFound => "not-found",
        Err(_) => "unknown",
    }
}

pub(crate) fn custom_locations(local_app_data: &Path) -> Result<Map<String, Value>, String> {
    let path = local_app_data.join("CocoMinecraftUpdater").join("instance-locations.json");
    let size = match fs::metadata(&path) {
        Ok(metadata) => metadata.len(),
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Map::new()),
        Err(error) => return Err(format!("Cannot inspect location map: {error}")),
    };
    if size > 1024 * 1024 {
        return Err("Instance location map is too large".into());
    }
    let json = fs::read_to_string(&path).map_err(|error| format!("Cannot read instance location map: {error}"))?;
    let parsed: Value = serde_json::from_str(&json).map_err(|error| format!("Invalid instance location map: {error}"))?;
    parsed.as_object().cloned().ok_or_else(|| "Invalid instance location map structure".into())
}

pub(crate) fn custom_path<'a>(locations: &'a Map<String, Value>, instance_id: &str, id: &str) -> Option<&'a str> {
    locations.get(instance_id).or_else(|| locations.get(id))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|path| !path.is_empty())
}

pub(crate) fn games_root(app_data: &Path) -> PathBuf {
    app_data.join("CocoLauncher2").join("games")
}

pub(crate) fn legacy_root(app_data: &Path) -> PathBuf {
    app_data.join("CocoMinecraft").join("experiences")
}

/// New games go under Coco Launcher 2's own name. A game already installed under the old
/// name stays there until the player moves it, and Minecraft packs belong to Launcher 1.
pub(crate) fn default_instance_root(app_data: &Path, instance_id: &str, workflow: &str) -> PathBuf {
    let legacy = legacy_root(app_data).join(instance_id);
    if workflow != "coco-standalone" || legacy.exists() { legacy } else { games_root(app_data).join(instance_id) }
}

pub(crate) fn resolve_instance_root(
    entry: &catalog::Experience,
    app_data: &Path,
    locations: &Map<String, Value>,
) -> PathBuf {
    match custom_path(locations, &entry.instance_id, &entry.id) {
        Some(value) => PathBuf::from(value),
        None => default_instance_root(app_data, &entry.instance_id, &entry.workflow),
    }
}

pub fn inspect_catalog(app_data: &Path, local_app_data: &Path) -> Result<Vec<InstancePresence>, String> {
    let locations = custom_locations(local_app_data)?;
    let entries = catalog::read_catalog()?;
    Ok(entries.into_iter().map(|entry| {
        if entry.workflow != "coco-managed" && entry.workflow != "coco-standalone" {
            return InstancePresence { id: entry.id, state: "unmanaged", location: "none" };
        }
        let location = if custom_path(&locations, &entry.instance_id, &entry.id).is_some() {"custom"} else {"default"};
        let path = resolve_instance_root(&entry, app_data, &locations);
        // A UNC share can block for a long time; do not probe a remote custom path in UI discovery.
        let state = if !path.is_absolute() || path.to_string_lossy().starts_with("\\\\") { "unknown" }
                    else { directory_state(&path) };
        InstancePresence { id: entry.id, state, location }
    }).collect())
}

#[tauri::command]
pub async fn get_local_instances() -> Result<Vec<InstancePresence>, String> {
    tauri::async_runtime::spawn_blocking(read_local_instances)
        .await.map_err(|error| format!("Instance read interrupted: {error}"))?
}

fn read_local_instances() -> Result<Vec<InstancePresence>, String> {
    let app_data = std::env::var_os("APPDATA")
        .map(PathBuf::from).ok_or_else(|| "APPDATA unavailable".to_string())?;
    let local_app_data = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from).ok_or_else(|| "LOCALAPPDATA unavailable".to_string())?;
    inspect_catalog(&app_data, &local_app_data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_games_use_the_new_folder_and_installed_ones_stay_until_moved() {
        let app_data = std::env::temp_dir().join(format!("coco-default-root-{}", std::process::id()));
        let _ = fs::remove_dir_all(&app_data);
        assert_eq!(default_instance_root(&app_data, "demo", "coco-standalone"), app_data.join("CocoLauncher2").join("games").join("demo"));
        assert_eq!(default_instance_root(&app_data, "pack", "coco-managed"), app_data.join("CocoMinecraft").join("experiences").join("pack"), "Minecraft packs stay with Launcher 1");
        fs::create_dir_all(legacy_root(&app_data).join("demo")).unwrap();
        assert_eq!(default_instance_root(&app_data, "demo", "coco-standalone"), legacy_root(&app_data).join("demo"));
        assert_eq!(default_instance_root(&app_data, "other", "coco-standalone"), games_root(&app_data).join("other"));
        let _ = fs::remove_dir_all(&app_data);
    }

    #[test]
    fn unwritten_default_directory_is_not_an_installed_game() {
        let never_exists = std::env::temp_dir().join("coco-launcher-2-no-instance-9b1f60e0");
        assert_eq!(directory_state(&never_exists), "not-found");
    }

    #[test]
    fn custom_location_prefers_instance_id_and_does_not_guess_a_path() {
        let mut map = Map::new();
        map.insert("game".into(), Value::String("C:\\Games\\Game".into()));
        map.insert("game-2".into(), Value::String("D:\\Game2".into()));
        assert_eq!(custom_path(&map,"game-2","game"), Some("D:\\Game2"));
        assert_eq!(custom_path(&map,"not-found","unknown"), None);
    }
}
