//! Embedded trusted baseline with a validated, per-user immutable channel cache.
//! No remote metadata is usable until its Ed25519 signature has been checked.
use serde::{Deserialize, Serialize};

#[path = "catalog_channel.rs"]
mod catalog_channel;
#[cfg(test)]
pub(crate) use catalog_channel::test_api;
pub use catalog_channel::{
    CatalogChannelStatus, LocalPublishReview, UnsignedCatalogChannelDraft, CatalogProvenance,
    ChannelDeliveryReview,
};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Experience {
    pub id: String,
    pub instance_id: String,
    pub name: String,
    pub image: String,
    pub description: String,
    pub workflow: String,
    pub minecraft_version: String,
    pub loader: String,
    pub required_files: Vec<RequiredFile>,
    pub executable: String,
    pub launch_arguments: Vec<String>,
    pub hosting_mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RequiredFile {
    pub path: String,
    pub sha256: String,
    pub size: u64,
}

fn embedded_catalog() -> Result<Vec<Experience>, String> {
    serde_json::from_str(include_str!("../../resources/catalog.json"))
        .map_err(|error| format!("Invalid embedded catalog: {error}"))
}

pub fn read_catalog() -> Result<Vec<Experience>, String> {
    let baseline = embedded_catalog()?;
    Ok(catalog_channel::merged_catalog(baseline))
}

/// Validated source for native installer, including newly accepted local or
/// signed channel entries. Returns None for experiences without installers.
pub fn read_install_manifest(id: &str) -> Result<Option<String>, String> {
    catalog_channel::manifest_for(id, None)
}

/// Historical immutable snapshot lookup for transactional upgrades from
/// receipts pinned to an older manifest. Never substitutes the newest version.
pub fn read_install_manifest_version(id: &str, version: &str) -> Result<Option<String>, String> {
    catalog_channel::manifest_for(id, Some(version))
}

#[tauri::command]
pub async fn get_catalog() -> Result<Vec<Experience>, String> {
    tauri::async_runtime::spawn_blocking(read_catalog)
        .await.map_err(|e|format!("Catalog read interrupted: {e}"))?
}

// Tauri generates private handler symbols in the same module as the command
// macro. Re-exporting a nested command alone does not re-export those symbols.
#[tauri::command]
pub async fn review_local_publish_package(path: String) -> Result<LocalPublishReview,String> {
    catalog_channel::review_local_publish_package(path).await
}
#[tauri::command]
pub async fn import_local_publish_package(path: String,review_token: String,confirmed: bool)
    -> Result<CatalogChannelStatus,String> {
    catalog_channel::import_local_publish_package(path,review_token,confirmed).await
}
#[tauri::command]
pub async fn sync_catalog_channel() -> Result<CatalogChannelStatus,String> {
    catalog_channel::sync_catalog_channel().await
}
#[tauri::command]
pub fn get_catalog_channel_status() -> CatalogChannelStatus {
    catalog_channel::get_catalog_channel_status()
}
#[tauri::command]
pub async fn prepare_catalog_channel(package_path:String)->Result<UnsignedCatalogChannelDraft,String>{
    catalog_channel::prepare_catalog_channel(package_path).await
}
#[tauri::command]
pub async fn review_channel_delivery(draft_path:String)->Result<ChannelDeliveryReview,String>{
    catalog_channel::review_channel_delivery(draft_path).await
}
#[tauri::command]
pub async fn verify_channel_delivery_online(draft_path:String)->Result<ChannelDeliveryReview,String>{
    catalog_channel::verify_channel_delivery_online(draft_path).await
}
#[tauri::command]
pub async fn get_catalog_provenance()->Result<Vec<CatalogProvenance>,String>{
    tauri::async_runtime::spawn_blocking(catalog_channel::provenance)
        .await.map_err(|e|format!("Provenance read interrupted: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn embedded_library_is_well_formed() {
        let catalog = embedded_catalog().expect("embedded catalog must parse");
        assert!(!catalog.is_empty());
        assert!(catalog.iter().any(|experience| experience.id == "coco-original"));
        assert!(catalog.iter().all(|experience| !experience.name.is_empty()));
    }
}
