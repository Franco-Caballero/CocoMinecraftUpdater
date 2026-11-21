//! The window that stands in for Coco while its silent installer replaces it.
//!
//! Windows cannot overwrite a running executable, so Coco has to close for the
//! few seconds the installer needs. Instead of an empty desktop (or the NSIS
//! wizard), a copy of this same executable runs from Coco's data folder in
//! "curtain" mode: one borderless window at the exact position and size of the
//! launcher, showing the same «Actualizando Coco» screen the launcher showed
//! just before closing. It stays on top until the new version has painted its
//! own identical screen, then closes, so the swap is invisible.
//!
//! Coordination is a handful of files in `%LOCALAPPDATA%\CocoLauncher2\update-curtain`:
//! `handoff.json` (version, geometry, install folder, launcher pid), `painted`
//! (the curtain is visible), `ready` (the new launcher is visible) and `cancel`
//! (the update did not start after all).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime};

pub const CURTAIN_FLAG: &str = "--coco-update-curtain";
const CURTAIN_EXE: &str = "coco-actualizando.exe";
const HANDOFF: &str = "handoff.json";
/// A handoff older than this is a leftover, never the update that just ran.
const FRESH: Duration = Duration::from_secs(10 * 60);
/// How long the launcher waits for the curtain to be on screen before installing anyway.
const PAINT_WAIT: Duration = Duration::from_secs(8);
/// Without a relaunch by then, the curtain starts the installed launcher itself.
const RELAUNCH_AFTER: Duration = Duration::from_secs(150);
/// The curtain never outlives this, whatever happens.
const GIVE_UP_AFTER: Duration = Duration::from_secs(240);
/// The launcher still running this long after asking for the curtain: the install never began.
const LAUNCHER_STUCK_AFTER: Duration = Duration::from_secs(90);

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub maximized: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct Handoff {
    version: String,
    geometry: Option<Geometry>,
    install_dir: PathBuf,
    launcher_pid: u32,
}

#[derive(Serialize, Clone, Debug)]
pub struct CurtainArrival {
    version: String,
}

fn folder() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|local| folder_in(Path::new(&local)))
}

fn folder_in(local: &Path) -> PathBuf {
    local.join("CocoLauncher2").join("update-curtain")
}

fn read_handoff(dir: &Path) -> Option<Handoff> {
    serde_json::from_slice(&std::fs::read(dir.join(HANDOFF)).ok()?).ok()
}

fn fresh(path: &Path, now: SystemTime) -> bool {
    std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        // A file written a moment after `now` (or a clock step) is as fresh as it gets.
        .map(|modified| now.duration_since(modified).unwrap_or(Duration::ZERO))
        .is_some_and(|age| age < FRESH)
}

/// The update that just relaunched this launcher, if its curtain is still waiting for it.
fn pending_arrival(dir: &Path, now: SystemTime) -> Option<Handoff> {
    if !fresh(&dir.join(HANDOFF), now) || dir.join("ready").exists() || dir.join("cancel").exists() {
        return None;
    }
    read_handoff(dir)
}

fn touch(path: &Path) -> bool {
    std::fs::write(path, b"1").is_ok()
}

fn wait_for(path: &Path, limit: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < limit {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    false
}

fn process_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, WAIT_TIMEOUT};
    use windows_sys::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
    let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
    if handle.is_null() {
        return false;
    }
    let alive = unsafe { WaitForSingleObject(handle, 0) } == WAIT_TIMEOUT;
    unsafe { CloseHandle(handle) };
    alive
}

// ---------------------------------------------------------------------------
// In the launcher that is about to update
// ---------------------------------------------------------------------------

/// Right before the signed installer starts: copy this executable out of the
/// install folder (the installer is about to overwrite it), open it as the
/// curtain over this window and wait until it is visible. `false` means the
/// update goes on without a curtain.
#[tauri::command]
pub async fn prepare_update_curtain(window: tauri::WebviewWindow, version: String) -> bool {
    let geometry = (|| {
        let maximized = window.is_maximized().unwrap_or(false);
        let position = window.outer_position().ok()?;
        // set_size() restores the inner size, so that is what is kept (the outer one adds the shadow frame).
        let size = window.inner_size().ok()?;
        Some(Geometry { x: position.x, y: position.y, width: size.width, height: size.height, maximized })
    })();
    tauri::async_runtime::spawn_blocking(move || prepare(geometry, version))
        .await
        .unwrap_or(false)
}

fn prepare(geometry: Option<Geometry>, version: String) -> bool {
    let Some(dir) = folder() else { return false };
    let result = (|| -> Result<(), String> {
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        for leftover in ["painted", "ready", "cancel"] {
            let _ = std::fs::remove_file(dir.join(leftover));
        }
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let install_dir = exe.parent().ok_or("sin carpeta de instalación")?.to_path_buf();
        std::fs::copy(&exe, dir.join(CURTAIN_EXE)).map_err(|e| format!("copia: {e}"))?;
        let handoff = Handoff { version, geometry, install_dir, launcher_pid: std::process::id() };
        std::fs::write(dir.join(HANDOFF), serde_json::to_vec(&handoff).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        std::process::Command::new(dir.join(CURTAIN_EXE))
            .arg(CURTAIN_FLAG)
            .current_dir(&dir)
            .spawn()
            .map_err(|e| format!("inicio: {e}"))?;
        if !wait_for(&dir.join("painted"), PAINT_WAIT) {
            return Err("no apareció a tiempo".into());
        }
        Ok(())
    })();
    match result {
        Ok(()) => {
            super::diagnostics::log("update", "pantalla de actualización lista; se instala en silencio");
            true
        }
        Err(error) => {
            super::diagnostics::log("update", &format!("sin pantalla de actualización: {error}"));
            false
        }
    }
}

/// The install did not start (a game opened, a package arrived, an error): close the curtain.
#[tauri::command]
pub fn cancel_update_curtain() {
    if let Some(dir) = folder() {
        touch(&dir.join("cancel"));
    }
}

// ---------------------------------------------------------------------------
// In the freshly installed launcher
// ---------------------------------------------------------------------------

/// Opens the new version exactly where the old window was, under the curtain.
/// `false` when no update is arriving: the caller places the window as usual.
pub fn place_arriving_window(app: &tauri::AppHandle) -> bool {
    use tauri::Manager;
    let Some(dir) = folder() else { return false };
    let Some(handoff) = pending_arrival(&dir, SystemTime::now()) else {
        // Nothing waiting: clear what an earlier update left behind (the curtain exe may still be closing).
        if dir.is_dir() && !fresh(&dir.join(HANDOFF), SystemTime::now()) {
            let _ = std::fs::remove_dir_all(&dir);
        }
        return false;
    };
    let (Some(geometry), Some(window)) = (handoff.geometry, app.get_webview_window("main")) else { return false };
    apply_geometry(&window, geometry);
    true
}

fn apply_geometry<R: tauri::Runtime>(window: &tauri::WebviewWindow<R>, geometry: Geometry) {
    if geometry.width >= 200 && geometry.height >= 200 {
        let _ = window.set_position(tauri::PhysicalPosition::new(geometry.x, geometry.y));
        let _ = window.set_size(tauri::PhysicalSize::new(geometry.width, geometry.height));
    }
    if geometry.maximized {
        let _ = window.maximize();
    }
}

/// The new launcher asks once at startup whether it arrives from an update with a curtain up.
#[tauri::command]
pub fn take_update_curtain() -> Option<CurtainArrival> {
    let dir = folder()?;
    pending_arrival(&dir, SystemTime::now()).map(|handoff| CurtainArrival { version: handoff.version })
}

/// The new launcher has painted its own copy of the curtain: the stand-in can go.
#[tauri::command]
pub fn update_curtain_ready() {
    if let Some(dir) = folder() {
        if touch(&dir.join("ready")) {
            super::diagnostics::log("update", "nueva versión en pantalla; se cierra la pantalla de actualización");
        }
    }
}

// ---------------------------------------------------------------------------
// The curtain process itself
// ---------------------------------------------------------------------------

static CURTAIN_DIR: OnceLock<PathBuf> = OnceLock::new();

pub fn is_curtain_launch() -> bool {
    std::env::args_os().nth(1).is_some_and(|arg| arg == CURTAIN_FLAG)
}

#[tauri::command]
fn update_curtain_painted() {
    if let Some(dir) = CURTAIN_DIR.get() {
        touch(&dir.join("painted"));
    }
}

pub fn run_curtain(mut context: tauri::Context<tauri::Wry>) {
    let Some(dir) = folder() else { return };
    let Some(handoff) = read_handoff(&dir) else { return };
    let _ = CURTAIN_DIR.set(dir.clone());
    // Only the curtain window: none of the launcher's own windows, plugins or services.
    context.config_mut().app.windows.clear();
    let script = format!(
        "window.__COCO_UPDATE_CURTAIN__={};",
        serde_json::json!({ "version": handoff.version })
    );
    let result = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![update_curtain_painted])
        .setup(move |app| {
            let window = tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::App("index.html".into()))
                .title("Coco Launcher 2")
                .inner_size(1280.0, 820.0)
                .decorations(false)
                .shadow(true)
                .visible(false)
                .always_on_top(true)
                .background_color(tauri::webview::Color(11, 10, 15, 255))
                .initialization_script(&script)
                // Its own browser profile: the new launcher must not share a profile that is closing.
                .data_directory(dir.join("webview"))
                .build()?;
            match handoff.geometry {
                Some(geometry) => apply_geometry(&window, geometry),
                None => {
                    let _ = window.center();
                }
            }
            window.show()?;
            let app = app.handle().clone();
            std::thread::spawn(move || watch(&app, &dir, &handoff));
            Ok(())
        })
        .run(context);
    if let Err(error) = result {
        eprintln!("Coco update curtain: {error}");
    }
}

fn watch(app: &tauri::AppHandle, dir: &Path, handoff: &Handoff) {
    let start = Instant::now();
    let mut relaunched = false;
    loop {
        std::thread::sleep(Duration::from_millis(100));
        if dir.join("ready").exists() {
            // Let the new window finish the frame that sits under this one.
            std::thread::sleep(Duration::from_millis(250));
            break;
        }
        if dir.join("cancel").exists() {
            break;
        }
        let elapsed = start.elapsed();
        if elapsed > LAUNCHER_STUCK_AFTER && process_alive(handoff.launcher_pid) {
            break;
        }
        if !relaunched && elapsed > RELAUNCH_AFTER {
            relaunched = true;
            let _ = std::process::Command::new(handoff.install_dir.join("coco-launcher-2.exe")).spawn();
        }
        if elapsed > GIVE_UP_AFTER {
            break;
        }
    }
    app.exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_fresh_unanswered_handoff_counts_as_an_arrival() {
        let local = std::env::temp_dir().join(format!("coco-curtain-{}", std::process::id()));
        let dir = folder_in(&local);
        std::fs::create_dir_all(&dir).unwrap();
        let now = SystemTime::now();
        assert!(pending_arrival(&dir, now).is_none());
        let handoff = Handoff {
            version: "0.6.74".into(),
            geometry: Some(Geometry { x: 10, y: 20, width: 1280, height: 820, maximized: false }),
            install_dir: local.clone(),
            launcher_pid: 1,
        };
        std::fs::write(dir.join(HANDOFF), serde_json::to_vec(&handoff).unwrap()).unwrap();
        assert_eq!(pending_arrival(&dir, now), Some(handoff.clone()));
        assert!(pending_arrival(&dir, now + FRESH + Duration::from_secs(1)).is_none(), "a leftover is not this update");
        touch(&dir.join("ready"));
        assert!(pending_arrival(&dir, now).is_none(), "answered already");
        std::fs::remove_file(dir.join("ready")).unwrap();
        touch(&dir.join("cancel"));
        assert!(pending_arrival(&dir, now).is_none(), "the install never started");
        let _ = std::fs::remove_dir_all(&local);
    }

    #[test]
    fn a_process_that_is_gone_is_not_alive() {
        assert!(process_alive(std::process::id()));
        assert!(!process_alive(0xFFFF_FFF0));
    }
}
