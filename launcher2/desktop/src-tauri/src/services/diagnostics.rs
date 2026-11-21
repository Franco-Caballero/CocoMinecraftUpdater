//! What went wrong on a friend's PC, without asking them to find files: Coco keeps a short log
//! of every failure and Windows step, and "Copiar diagnóstico" turns it, plus the facts that
//! usually explain a failure (Windows build, disk space, Steam, ZeroTier, Defender, antivirus,
//! the video decoder's own log), into one file, `coco-diagnostico.txt`, placed on the clipboard
//! as a file to paste in the chat. Never includes tokens, secrets or file contents.
use std::fs::{self,OpenOptions};
use std::io::Write;
use std::path::{Path,PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime,UNIX_EPOCH};

const MAX_LOG_BYTES:u64=512*1024;
const REPORT_LINES:usize=400;
const PLAYER_LINES:usize=60;
static WRITE:Mutex<()>=Mutex::new(());

fn log_dir()->Option<PathBuf>{
    std::env::var_os("LOCALAPPDATA").map(|local|Path::new(&local).join("CocoLauncher2").join("logs"))
}

fn timestamp()->String{
    let seconds=SystemTime::now().duration_since(UNIX_EPOCH).map(|time|time.as_secs()).unwrap_or_default();
    let (days,rest)=(seconds/86_400,seconds%86_400);
    // Civil date from days since 1970 (Howard Hinnant's algorithm), UTC.
    let z=days as i64+719_468;
    let era=z.div_euclid(146_097);
    let doe=z-era*146_097;
    let yoe=(doe-doe/1460+doe/36_524-doe/146_096)/365;
    let doy=doe-(365*yoe+yoe/4-yoe/100);
    let mp=(5*doy+2)/153;
    let day=doy-(153*mp+2)/5+1;
    let month=if mp<10{mp+3}else{mp-9};
    let year=yoe+era*400+i64::from(month<=2);
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}Z",rest/3600,rest%3600/60,rest%60)
}

fn clean(text:&str,limit:usize)->String{
    text.chars().map(|c|if c.is_control(){' '}else{c}).take(limit).collect::<String>().trim().to_string()
}

pub(crate) fn log_in(dir:&Path,area:&str,message:&str){
    let Ok(_guard)=WRITE.lock() else {return};
    if fs::create_dir_all(dir).is_err(){return;}
    let path=dir.join("coco.log");
    if fs::metadata(&path).is_ok_and(|meta|meta.len()>MAX_LOG_BYTES){
        let _=fs::rename(&path,dir.join("coco.old.log"));
    }
    if let Ok(mut file)=OpenOptions::new().create(true).append(true).open(&path){
        let _=writeln!(file,"{} [{}] {}",timestamp(),clean(area,24),clean(message,2000));
    }
}

/// Never fails and never blocks the caller for long: a log must not become a new error.
pub(crate) fn log(area:&str,message:&str){
    if let Some(dir)=log_dir(){log_in(&dir,area,message);}
}

fn tail(dir:&Path,lines:usize)->Vec<String>{
    let mut all=Vec::new();
    for name in ["coco.old.log","coco.log"]{
        if let Ok(text)=fs::read_to_string(dir.join(name)){all.extend(text.lines().map(str::to_string));}
    }
    let skip=all.len().saturating_sub(lines);
    all.split_off(skip)
}

fn gib(bytes:Option<u64>)->String{
    bytes.map(|value|format!("{:.1} GB libres",value as f64/1_073_741_824.0)).unwrap_or_else(||"espacio desconocido".into())
}

fn windows_version()->String{
    #[cfg(windows)]{
        use crate::services::game_prepare::registry::{read,MACHINE};
        let key="SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
        let build=read(MACHINE,key,"CurrentBuild").unwrap_or_default();
        let name=if build.parse::<u32>().unwrap_or(0)>=22_000{"Windows 11".to_string()}
            else{read(MACHINE,key,"ProductName").unwrap_or_else(||"Windows".into())};
        let edition=read(MACHINE,key,"EditionID").unwrap_or_default();
        let release=read(MACHINE,key,"DisplayVersion").unwrap_or_default();
        return format!("{name} {edition} {release} (build {build})");
    }
    #[allow(unreachable_code)]
    "no Windows".into()
}

fn webview_version()->String{
    #[cfg(windows)]{
        use crate::services::game_prepare::registry::{read,MACHINE,USER};
        let client="{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        for (root,key) in [(MACHINE,format!("SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{client}")),
                           (USER,format!("Software\\Microsoft\\EdgeUpdate\\Clients\\{client}"))]{
            if let Some(version)=read(root,&key,"pv"){return version;}
        }
    }
    "no encontrado".into()
}

/// Third-party antivirus products Windows knows about (Security Center), e.g.
/// "Avast Antivirus, Windows Defender". They are the usual reason a bundled DLL
/// does not load.
fn antivirus()->String{
    #[cfg(windows)]{
        use std::os::windows::process::CommandExt;
        let mut exe=std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(||PathBuf::from("C:\\Windows"));
        exe.push("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
        let script="(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object displayName) -join ', '";
        if let Ok(output)=std::process::Command::new(exe).args(["-NoProfile","-NonInteractive","-Command",script])
            .stdin(std::process::Stdio::null()).creation_flags(0x08000000).output(){
            let text=clean(&String::from_utf8_lossy(&output.stdout),300);
            if output.status.success()&&!text.is_empty(){return text;}
        }
    }
    "no se pudo consultar".into()
}

/// The graphics cards and their drivers: a film that will not decode often comes down to them.
fn graphics()->String{
    #[cfg(windows)]{
        use std::os::windows::process::CommandExt;
        let mut exe=std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(||PathBuf::from("C:\\Windows"));
        exe.push("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
        let script="(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { $_.Name + ' (driver ' + $_.DriverVersion + ')' }) -join ', '";
        if let Ok(output)=std::process::Command::new(exe).args(["-NoProfile","-NonInteractive","-Command",script])
            .stdin(std::process::Stdio::null()).creation_flags(0x08000000).output(){
            let text=clean(&String::from_utf8_lossy(&output.stdout),300);
            if output.status.success()&&!text.is_empty(){return text;}
        }
    }
    "no se pudo consultar".into()
}

/// Once per session, so coco.log alone says which PC and Coco version wrote it.
pub(crate) fn log_session_start(version:String){
    std::thread::spawn(move||{
        log("sesión",&format!("Coco Launcher 2 {version} · {} · WebView2 {} · antivirus: {}",windows_version(),webview_version(),antivirus()));
    });
}

#[tauri::command]
pub fn log_event(area:String,message:String){
    log(&format!("ui:{}",clean(&area,16)),&message);
}

#[tauri::command]
pub async fn get_diagnostic_report(app:tauri::AppHandle)->Result<String,String>{build_report(app).await}

async fn build_report(app:tauri::AppHandle)->Result<String,String>{
    let network=crate::services::network::get_network_status().await.ok();
    tauri::async_runtime::spawn_blocking(move||{
        let app_data=std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default();
        let local=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default();
        let games=crate::services::inventory::games_root(&app_data);
        let disk=|path:&Path|{
            let existing=path.ancestors().find(|candidate|candidate.exists()).unwrap_or(path);
            gib(crate::services::install::available_disk_bytes(existing).ok().flatten())
        };
        let defender=fs::read_to_string(local.join("CocoMinecraftUpdater").join("defender-exclusions.json"))
            .map(|text|text.split_whitespace().collect::<Vec<_>>().join(" ")).unwrap_or_else(|_|"sin registro".into());
        let service=network.map(|status|match status.service_installed{Some(true)=>"instalado",Some(false)=>"no instalado",None=>"?"}).unwrap_or("?");
        let membership=crate::services::zerotier_host::local_membership()
            .map(|(joined,detail)|if joined{format!("red unida · {detail}")}else{detail}).unwrap_or_else(||"red: no se pudo consultar".into());
        let zerotier=format!("servicio {service} · {membership}");
        let handoff=fs::read_to_string(local.join("CocoMinecraftUpdater").join("coco2-handoff.json"))
            .map(|text|text.split_whitespace().collect::<Vec<_>>().join(" ")).unwrap_or_else(|_|"no vino del launcher 1".into());
        let mut report=vec![
            format!("Coco Launcher 2 {}",app.package_info().version),
            format!("Windows: {}",windows_version()),
            format!("WebView2: {}",webview_version()),
            format!("Disco de juegos ({}): {}",games.display(),disk(&games)),
            format!("Steam: {}",crate::services::game_prepare::find_steam().map(|path|path.display().to_string()).unwrap_or_else(||"no encontrado".into())),
            format!("ZeroTier: {zerotier}"),
            format!("Defender: {defender}"),
            format!("Antivirus: {}",antivirus()),
            format!("Gráfica: {}",graphics()),
            format!("Traspaso: {handoff}"),
            String::new(),
            "Registro reciente:".into(),
        ];
        match log_dir(){
            Some(dir)=>{let lines=tail(&dir,REPORT_LINES);if lines.is_empty(){report.push("(vacío)".into());}else{report.extend(lines);}}
            None=>report.push("(sin carpeta de registros)".into()),
        }
        // The decoder writes its own reasons here when a film does not open.
        if let Some(text)=log_dir().and_then(|dir|fs::read(dir.join("player.log")).ok()).filter(|t|!t.is_empty()){
            let text=String::from_utf8_lossy(&text).into_owned();
            let lines:Vec<&str>=text.lines().collect();
            report.push(String::new());report.push("Motor de vídeo (player.log):".into());
            report.extend(lines[lines.len().saturating_sub(PLAYER_LINES)..].iter().map(|line|clean(line,500)));
        }
        report.join("\n")
    }).await.map_err(|error|format!("Diagnóstico interrumpido: {error}"))
}

/// Writes the full report to `coco-diagnostico.txt` and puts that file on the
/// clipboard, so a friend pastes it in Discord or WhatsApp as an attachment.
/// Returns the file's path; Err only when the file cannot be written.
#[tauri::command]
pub async fn copy_diagnostic_file(app:tauri::AppHandle,extra:Vec<String>)->Result<DiagnosticFile,String>{
    let report=build_report(app).await?;
    let extra:Vec<String>=extra.iter().take(20).map(|line|clean(line,500)).collect();
    let (head,rest)=report.split_once("\n\n").unwrap_or((report.as_str(),""));
    let text=format!("{head}\n{}\n\n{rest}\n",extra.join("\n"));
    let dir=log_dir().ok_or("Carpeta de registros no disponible")?;
    tauri::async_runtime::spawn_blocking(move||{
        fs::create_dir_all(&dir).map_err(|error|error.to_string())?;
        let path=dir.join("coco-diagnostico.txt");
        fs::write(&path,text.replace('\n',"\r\n")).map_err(|error|format!("No se pudo guardar el diagnóstico: {error}"))?;
        let copied=clipboard::put_file(&path);
        Ok(DiagnosticFile{path:path.display().to_string(),copied})
    }).await.map_err(|error|format!("Diagnóstico interrumpido: {error}"))?
}

#[derive(serde::Serialize)]
pub struct DiagnosticFile{path:String,copied:bool}

/// Opens the log folder with coco.log selected.
#[tauri::command]
pub fn open_log_folder()->Result<(),String>{
    let dir=log_dir().ok_or("Carpeta de registros no disponible")?;
    fs::create_dir_all(&dir).map_err(|error|error.to_string())?;
    let log=dir.join("coco.log");
    let mut command=std::process::Command::new("explorer.exe");
    if log.exists(){command.arg(format!("/select,{}",log.display()));}else{command.arg(&dir);}
    command.spawn().map(|_|()).map_err(|error|error.to_string())
}

#[cfg(windows)]
mod clipboard{
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    #[link(name="user32")]
    extern "system"{
        fn OpenClipboard(owner:isize)->i32;
        fn EmptyClipboard()->i32;
        fn SetClipboardData(format:u32,data:*mut c_void)->*mut c_void;
        fn CloseClipboard()->i32;
    }
    #[link(name="kernel32")]
    extern "system"{
        fn GlobalAlloc(flags:u32,bytes:usize)->*mut c_void;
        fn GlobalLock(memory:*mut c_void)->*mut c_void;
        fn GlobalUnlock(memory:*mut c_void)->i32;
        fn GlobalFree(memory:*mut c_void)->*mut c_void;
    }
    const CF_HDROP:u32=15;
    /// CF_HDROP: a DROPFILES header (20 bytes, wide names) and a double-NUL list.
    pub fn put_file(path:&Path)->bool{
        let mut names:Vec<u16>=path.as_os_str().encode_wide().collect();
        names.extend([0,0]);
        let bytes=20+names.len()*2;
        unsafe{
            let memory=GlobalAlloc(0x0042,bytes); // GMEM_MOVEABLE | GMEM_ZEROINIT
            if memory.is_null(){return false;}
            let target=GlobalLock(memory) as *mut u8;
            if target.is_null(){GlobalFree(memory);return false;}
            (target as *mut u32).write_unaligned(20);
            (target.add(16) as *mut i32).write_unaligned(1);
            std::ptr::copy_nonoverlapping(names.as_ptr() as *const u8,target.add(20),names.len()*2);
            GlobalUnlock(memory);
            // Another program may hold the clipboard for a moment.
            let mut open=false;
            for _ in 0..10{if OpenClipboard(0)!=0{open=true;break;}std::thread::sleep(std::time::Duration::from_millis(50));}
            if !open{GlobalFree(memory);return false;}
            EmptyClipboard();
            let placed=!SetClipboardData(CF_HDROP,memory).is_null();
            CloseClipboard();
            if !placed{GlobalFree(memory);}
            placed
        }
    }
}
#[cfg(not(windows))]
mod clipboard{pub fn put_file(_:&std::path::Path)->bool{false}}

#[cfg(test)]
mod tests{
    use super::*;

    /// Touches the real clipboard; check afterwards with
    /// `Get-Clipboard -Format FileDropList`.
    #[test]
    #[ignore]
    fn the_report_file_goes_on_the_clipboard_as_a_file(){
        let path=std::env::temp_dir().join("coco-diagnostico-prueba.txt");
        fs::write(&path,"prueba").unwrap();
        assert!(clipboard::put_file(&path));
        assert!(!antivirus().is_empty());
    }

    #[test]
    fn the_log_rotates_and_the_report_tail_keeps_order_without_control_characters(){
        let dir=std::env::temp_dir().join(format!("coco-diagnostics-{}",std::process::id()));
        let _=fs::remove_dir_all(&dir);
        log_in(&dir,"install","primero\r\nsegundo");
        fs::write(dir.join("coco.log"),vec![b'x';(MAX_LOG_BYTES+1) as usize]).unwrap();
        log_in(&dir,"launch","después de rotar");
        assert!(dir.join("coco.old.log").exists());
        let lines=tail(&dir,1);
        assert_eq!(lines.len(),1);
        assert!(lines[0].ends_with("[launch] después de rotar"),"{lines:?}");
        assert!(!fs::read_to_string(dir.join("coco.log")).unwrap().contains('\r'));
        assert!(timestamp().ends_with('Z')&&timestamp().len()==20);
        let _=fs::remove_dir_all(&dir);
    }
}
