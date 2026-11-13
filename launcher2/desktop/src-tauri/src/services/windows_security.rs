//! Read-only Windows Security troubleshooting for a verified, registered game.
//! Never creates Defender exclusions, changes preferences, invokes PowerShell,
//! runs elevated, or silently weakens antivirus protection. The user decides
//! whether a *specific trusted file* warrants a manual exception in Windows.
use crate::services::{catalog, inventory};
use serde::Serialize;
use std::{fs, path::{Path, PathBuf}};

#[derive(Debug, Serialize)]
#[serde(rename_all="camelCase")]
pub struct GameSecurityGuide {
    pub id: String,
    pub folder: String,
    pub warning: &'static str,
}

fn safe_game_folder(root:&Path)->Result<PathBuf,String>{
    if !root.is_absolute() || root.to_string_lossy().starts_with(r"\\") {
        return Err("The game must be in an accessible local folder".into());
    }
    let path=fs::canonicalize(root).map_err(|_|"Game folder is unavailable or unverified")?;
    if path.components().count()<4 || !path.is_dir(){
        return Err("Refusing to suggest a broad system or user directory".into());
    }
    // Reject junctions/reparse points both at the game and its ancestors,
    // including the location-map parent; never follow such a path when
    // suggesting a potentially dangerous antivirus exception.
    for ancestor in root.ancestors(){
        let metadata=match fs::symlink_metadata(ancestor){
            Ok(value)=>value,
            Err(error) if error.kind()==std::io::ErrorKind::NotFound=>continue,
            Err(_)=>return Err("Cannot verify game folder parents".into()),
        };
        if metadata.file_type().is_symlink(){return Err("Game path contains a symbolic link".into());}
        #[cfg(windows)]{
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return Err("Game path contains a Windows reparse point".into());
            }
        }
    }
    Ok(path)
}

fn guide_from_paths(id:&str,app_data:&Path,local_app_data:&Path)->Result<GameSecurityGuide,String>{
    let entry=catalog::read_catalog()?.into_iter()
        .find(|entry|entry.id==id&&entry.workflow=="coco-standalone")
        .ok_or("A trusted standalone catalog entry is required")?;
    let locations=inventory::custom_locations(local_app_data)?;
    let registered=inventory::resolve_instance_root(&entry,app_data,&locations);
    let path=safe_game_folder(&registered)?;
    Ok(GameSecurityGuide {
        id:entry.id,
        folder:path.to_string_lossy().to_string(),
        warning:"Windows Defender exclusions reduce malware protection. Inspect Protection history and verify the affected file first. Coco does not change exclusions automatically.",
    })
}

#[tauri::command]
pub async fn get_game_security_guide(id:String)->Result<GameSecurityGuide,String>{
    let app_data=std::env::var_os("APPDATA").map(PathBuf::from).ok_or("APPDATA is unavailable")?;
    let local_app_data=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or("LOCALAPPDATA is unavailable")?;
    tauri::async_runtime::spawn_blocking(move||guide_from_paths(&id,&app_data,&local_app_data))
        .await.map_err(|_|"Cannot inspect game location")?
}

#[tauri::command]
pub fn open_windows_security()->Result<(),String>{
    #[cfg(windows)]{
        use std::{ffi::OsStr,os::windows::ffi::OsStrExt};
        use windows_sys::Win32::UI::Shell::{ShellExecuteExW,SHELLEXECUTEINFOW};
        let wide=|value:&str|OsStr::new(value).encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
        let operation=wide("open");
        // Fixed OS-owned URI: no user path or untrusted manifest data enters
        // ShellExecute. Opens settings only, does not add or remove exclusions.
        let uri=wide("windowsdefender://threatsettings");
        let mut info:SHELLEXECUTEINFOW=unsafe{std::mem::zeroed()};
        info.cbSize=std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
        info.lpVerb=operation.as_ptr();
        info.lpFile=uri.as_ptr();
        info.nShow=1;
        if unsafe{ShellExecuteExW(&mut info)}==0 {
            return Err("Windows Security could not be opened. Open it from the Start menu instead.".into());
        }
        Ok(())
    }
    #[cfg(not(windows))]{Err("Windows Security is available only on Windows".into())}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_nonexistent_broad_or_network_paths_without_modifying_protection(){
        assert!(safe_game_folder(Path::new(r"\\server\share\game")).is_err());
        assert!(safe_game_folder(Path::new("relative/folder")).is_err());
        assert!(safe_game_folder(&std::env::temp_dir().join("coco2-never-exists-v10")).is_err());
        #[cfg(windows)]{
            assert!(safe_game_folder(Path::new(r"C:\")).is_err());
        }
    }
    #[test]
    fn only_registered_catalog_games_can_receive_guidance(){
        let temp=std::env::temp_dir();
        assert!(guide_from_paths("__not_an_installed_game__",&temp,&temp).is_err());
    }
    #[test]
    fn unicode_spaced_game_folder_can_be_inspected_without_touching_security_settings(){
        let serial=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
            .unwrap().as_nanos();
        let owned=std::env::temp_dir().join(format!("coco2-security-v10-{}-{serial}",std::process::id()));
        let game=owned.join("Juegos de amigos").join("Montaña 漢字");
        fs::create_dir_all(&game).unwrap();
        let resolved=safe_game_folder(&game).expect("an existing nested local game path is inspectable");
        assert_eq!(resolved,fs::canonicalize(&game).unwrap());
        // Only remove the unique directory this test created in TEMP.
        fs::remove_dir_all(&owned).unwrap();
    }
}
