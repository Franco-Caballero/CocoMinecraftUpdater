//! ZeroTier installation from the pinned MSI bundled in the Tauri Setup.
//! The only privileged action is a user-approved Windows UAC prompt.
//! No downloaded executable, PowerShell, command shell or arbitrary URL runs.
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};

const PINNED_BYTES: u64 = 12_003_840;
const PINNED_SHA256: &str = "42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670";
static INSTALL_RUNNING: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkInstallOutcome {
    pub status: &'static str,
    pub windows_exit_code: Option<u32>,
    pub service_installed: bool,
    pub service_running: bool,
    pub needs_restart: bool,
    pub message: &'static str,
}

fn no_reparse_components(path: &Path) -> Result<(), String> {
    let mut segment = Some(path);
    while let Some(current) = segment {
        if let Ok(metadata) = fs::symlink_metadata(current) {
            #[cfg(windows)] {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err("Installer resource uses an untrusted junction or symlink".into());
                }
            }
            if metadata.file_type().is_symlink() {
                return Err("Installer path is a symbolic link".into());
            }
        }
        segment=current.parent();
    }
    Ok(())
}

pub(crate) fn pinned_installer(resource_root: &Path) -> Result<(PathBuf, File), String> {
    let path=resource_root.join("resources").join("ZeroTierOne.msi");
    no_reparse_components(&path)?;
    let source=fs::canonicalize(&path).map_err(|_|"ZeroTier MSI is missing from this Coco Setup")?;
    let root=fs::canonicalize(resource_root).map_err(|_|"Coco resource directory unavailable")?;
    if !source.starts_with(root) {return Err("MSI must be inside Coco resources".into());}
    let mut options=OpenOptions::new();
    options.read(true);
    #[cfg(windows)] {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(0x00000001); // FILE_SHARE_READ denies tampering during UAC
    }
    let mut file=options.open(&source).map_err(|_|"Cannot open bundled ZeroTier MSI")?;
    let size=file.metadata().map_err(|_|"Cannot inspect bundled MSI")?.len();
    if size!=PINNED_BYTES{return Err("Bundled ZeroTier MSI has unexpected size".into());}
    let mut hash=Sha256::new();
    let mut buf=[0u8;128*1024];
    loop {
        let count=file.read(&mut buf).map_err(|_|"Cannot verify ZeroTier installer")?;
        if count==0{break;}
        hash.update(&buf[..count]);
    }
    let actual=format!("{:x}",hash.finalize());
    if actual!=PINNED_SHA256{return Err("Bundled ZeroTier MSI does not match approved SHA-256".into());}
    Ok((source,file))
}

#[cfg(windows)]
fn install_with_windows_uac(msi: &Path, _hold_read_lock: File) -> Result<u32, String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};
    use windows_sys::Win32::UI::Shell::{ShellExecuteExW, SHELLEXECUTEINFOW, SEE_MASK_NOCLOSEPROCESS};

    const WAIT_TIMEOUT: u32=258;
    let mut system=[0u16;32768];
    let n=unsafe{GetSystemDirectoryW(system.as_mut_ptr(),system.len() as u32)} as usize;
    if n==0||n>=system.len(){return Err("Cannot locate Windows System32".into());}
    let base=String::from_utf16(&system[..n]).map_err(|_|"Invalid Windows system path")?;
    let exe=Path::new(&base).join("msiexec.exe");
    if !exe.is_file(){return Err("Windows Installer is not available".into());}
    let wide=|s:&std::ffi::OsStr|s.encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let verb=wide(std::ffi::OsStr::new("runas"));
    let program=wide(exe.as_os_str());
    let arguments=wide(std::ffi::OsStr::new(&format!("/i \"{}\" /qn /norestart",msi.display())));
    let mut info:SHELLEXECUTEINFOW=unsafe{std::mem::zeroed()};
    info.cbSize=std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask=SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb=verb.as_ptr();
    info.lpFile=program.as_ptr();
    info.lpParameters=arguments.as_ptr();
    info.nShow=0; // installer UI suppressed; Windows UAC remains visible
    if unsafe{ShellExecuteExW(&mut info)}==0 {
        let last=unsafe{GetLastError()};
        return Err(if last==1223 {"Windows UAC approval was cancelled".into()}
                   else {format!("Windows Installer launch failed (error {last})")});
    }
    if info.hProcess.is_null(){return Err("Windows did not return installer process handle".into());}
    let handle=info.hProcess;
    let waited=unsafe{WaitForSingleObject(handle,5*60*1000)};
    if waited==WAIT_TIMEOUT {
        unsafe{CloseHandle(handle)};
        return Err("ZeroTier installation is still running; recheck network status shortly".into());
    }
    if waited!=0 {
        unsafe{CloseHandle(handle)};
        return Err("Windows could not wait for the network installer".into());
    }
    let mut code=0u32;
    let ok=unsafe{GetExitCodeProcess(handle,&mut code)};
    unsafe{CloseHandle(handle)};
    if ok==0{return Err("Windows Installer returned no exit status".into());}
    if code!=0&&code!=3010{return Err(format!("ZeroTier MSI installation failed (exit code {code})"));}
    Ok(code)
}

struct BusyGuard;
impl Drop for BusyGuard {fn drop(&mut self){INSTALL_RUNNING.store(false,Ordering::Release);}}

/// One-time installation: verifies a local signed-at-build, SHA-pinned MSI and
/// asks Windows to elevate. No additional downloads or network joins here.
#[tauri::command]
pub async fn install_zerotier_msi(app:AppHandle) -> Result<NetworkInstallOutcome,String> {
    if INSTALL_RUNNING.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).is_err(){
        return Err("Network installation is already in progress".into());
    }
    let _guard=BusyGuard;
    let status=super::network::get_network_status().await?;
    if status.service_installed!=Some(false) {
        return Ok(NetworkInstallOutcome{
            status:if status.service_installed==Some(true){"already-installed"}else{"preflight-unconfirmed"},
            windows_exit_code:None,service_installed:status.service_installed==Some(true),
            service_running:status.service_running==Some(true),needs_restart:false,
            message:"Coco will not replace an existing or unknown ZeroTier installation",
        });
    }
    let resource_root=app.path().resource_dir().map_err(|_|"Cannot locate bundled resources")?;
    let (msi,verified_file)=tauri::async_runtime::spawn_blocking(move||pinned_installer(&resource_root))
        .await.map_err(|_|"MSI verification was interrupted")??;
    #[cfg(windows)]
    let exit=tauri::async_runtime::spawn_blocking(move||install_with_windows_uac(&msi,verified_file))
        .await.map_err(|_|"Windows installer was interrupted")??;
    #[cfg(not(windows))]
    let exit={drop(msi);drop(verified_file);return Err("Windows required".into());};
    let refreshed=super::network::get_network_status().await?;
    Ok(NetworkInstallOutcome{
        status:if refreshed.service_installed==Some(true){"installed"}else{"installation-unconfirmed"},
        windows_exit_code:Some(exit),service_installed:refreshed.service_installed==Some(true),
        service_running:refreshed.service_running==Some(true),needs_restart:exit==3010,
        message:if refreshed.service_installed==Some(true){"ZeroTier installed; recheck Coco network authorization"}else{"Windows setup finished, but ZeroTier service is not yet observable"},
    })
}

#[cfg(test)]
mod tests{
    use super::*;
    #[test]
    fn cannot_use_tampered_or_missing_msi(){
        let base=std::env::temp_dir().join(format!("coco-zero-msi-{}",std::process::id()));
        if base.exists(){let _=fs::remove_dir_all(&base);}
        fs::create_dir_all(base.join("resources")).unwrap();
        assert!(pinned_installer(&base).is_err());
        fs::write(base.join("resources/ZeroTierOne.msi"),b"forged bytes").unwrap();
        assert!(pinned_installer(&base).is_err());
        fs::remove_dir_all(base).unwrap();
    }
}
