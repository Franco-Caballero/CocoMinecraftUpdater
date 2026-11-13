//! What went wrong on a friend's PC, without asking them to find files: Coco keeps a short log
//! of every failure and Windows step, and "Copiar diagnóstico" turns it, plus the facts that
//! usually explain a failure (Windows build, disk space, Steam, ZeroTier, Defender), into one
//! text to paste to the host. Never includes tokens, secrets or file contents.
use std::fs::{self,OpenOptions};
use std::io::Write;
use std::path::{Path,PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime,UNIX_EPOCH};

const MAX_LOG_BYTES:u64=512*1024;
const REPORT_LINES:usize=150;
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

#[tauri::command]
pub fn log_event(area:String,message:String){
    log(&format!("ui:{}",clean(&area,16)),&message);
}

#[tauri::command]
pub async fn get_diagnostic_report(app:tauri::AppHandle)->Result<String,String>{
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
            format!("Traspaso: {handoff}"),
            String::new(),
            "Registro reciente:".into(),
        ];
        match log_dir(){
            Some(dir)=>{let lines=tail(&dir,REPORT_LINES);if lines.is_empty(){report.push("(vacío)".into());}else{report.extend(lines);}}
            None=>report.push("(sin carpeta de registros)".into()),
        }
        report.join("\n")
    }).await.map_err(|error|format!("Diagnóstico interrumpido: {error}"))
}

#[tauri::command]
pub fn open_log_folder()->Result<(),String>{
    let dir=log_dir().ok_or("Carpeta de registros no disponible")?;
    fs::create_dir_all(&dir).map_err(|error|error.to_string())?;
    std::process::Command::new("explorer.exe").arg(&dir).spawn().map(|_|()).map_err(|error|error.to_string())
}

#[cfg(test)]
mod tests{
    use super::*;

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
