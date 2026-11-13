use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineStatus {
    pub phase: &'static str,
    pub installation_enabled: bool,
    pub launch_enabled: bool,
    pub network_enabled: bool,
}

#[tauri::command]
pub fn get_engine_status() -> EngineStatus {
    EngineStatus {
        phase: "preview",
        installation_enabled: false,
        launch_enabled: false,
        network_enabled: false,
    }
}
