//! Coco 2 replaces the first launcher completely. Its shortcuts and its own files are retired
//! here, whether the friend arrived through the handoff or installed Coco 2 directly. What
//! Coco 2 shares in the same folder stays: name and avatar (launcher\), game locations,
//! downloads in progress, previews, the Defender record and save backups.
use std::fs;
use std::path::{Path,PathBuf};

const LEGACY_EXE:&str="cocoupdater.exe";
const MAX_SHORTCUT_BYTES:u64=64*1024;

/// Coco 1 only: its executable and engine, its Minecraft downloads, network and session
/// state, logs and copies of old launchers.
const LEGACY_FILES:&[&str]=&["CocoUpdater.exe","CocoUpdater.channel.json","latest.json","target.json","host-preferences.json"];
const LEGACY_FOLDERS:&[&str]=&["engine","network","logs","session","tools","downloads\\jars","downloads\\standalone-files",
    "downloads\\standalone-files-stage","backups\\legacy-launchers","launcher\\session","launcher\\skins"];

fn is_legacy_loose_file(name:&str)->bool{
    let name=name.to_ascii_lowercase();
    (name.starts_with("engine-")&&name.ends_with(".zip"))||(name.starts_with("cocoupdater.")&&name.ends_with(".exe"))
        ||name.starts_with("cocoupdater.exe.coco-old")||(name.starts_with("apply-cocobootstrapupdate")&&name.ends_with(".ps1"))
}

fn is_link(path:&Path)->bool{
    fs::symlink_metadata(path).is_ok_and(|meta|{
        #[cfg(windows)]{use std::os::windows::fs::MetadataExt;if meta.file_attributes()&0x400!=0{return true;}}
        meta.file_type().is_symlink()
    })
}

pub(crate) fn retire_launcher1_files_in(root:&Path)->usize{
    if !root.is_dir()||is_link(root){return 0;}
    let mut removed=0;
    for name in LEGACY_FILES{
        let path=root.join(name);
        if path.is_file()&&!is_link(&path)&&fs::remove_file(&path).is_ok(){removed+=1;}
    }
    for name in LEGACY_FOLDERS{
        let path=root.join(name);
        if path.is_dir()&&!is_link(&path)&&fs::remove_dir_all(&path).is_ok(){removed+=1;}
    }
    for folder in [root.to_path_buf(),root.join("downloads")]{
        let Ok(entries)=fs::read_dir(&folder) else {continue};
        for entry in entries.flatten(){
            let name=entry.file_name().to_string_lossy().to_string();
            let path=entry.path();
            if is_link(&path){continue;}
            let stale_stage=folder.ends_with("downloads")&&name.starts_with("stage-")&&path.is_dir();
            if stale_stage&&fs::remove_dir_all(&path).is_ok(){removed+=1;}
            else if folder==root&&path.is_file()&&is_legacy_loose_file(&name)&&fs::remove_file(&path).is_ok(){removed+=1;}
        }
    }
    removed
}

fn contains_ignore_case(haystack:&str,needle:&str)->bool{haystack.to_ascii_lowercase().contains(needle)}

/// Coco 1 under any of the names friends saved it with: CocoUpdater.exe, «Coco Launcher.exe»,
/// CocoMinecraftUpdater.exe, «CocoUpdater (1).exe»… The same rule Coco 1 itself retires
/// shortcuts by, and never Coco Launcher 2.
pub(crate) fn is_launcher1_exe_name(name:&str)->bool{
    let lower=name.to_ascii_lowercase();
    let Some(stem)=lower.strip_suffix(".exe") else {return false};
    let compact:String=stem.chars().filter(|c|!matches!(c,' '|'.'|'_'|'-'|'('|')')).collect();
    let Some(rest)=compact.strip_prefix("coco") else {return false};
    let rest=rest.strip_prefix("minecraft").unwrap_or(rest);
    let (base,copy)=if let Some(copy)=rest.strip_prefix("updater"){("updater",copy)}
        else if let Some(copy)=rest.strip_prefix("launcher"){("launcher",copy)} else {return false};
    copy.bytes().all(|byte|byte.is_ascii_digit())&&!(base=="launcher"&&copy.starts_with('2'))
}

/// Every executable file name a text mentions.
fn exe_names(text:&str)->Vec<String>{
    let lower=text.to_ascii_lowercase();
    let mut names=Vec::new();
    let mut from=0;
    while let Some(at)=lower[from..].find(".exe"){
        let end=from+at+4;
        let start=lower[..from+at].rfind(|c:char|c=='\\'||c=='/'||c=='"'||c=='\0'||c.is_control()).map_or(0,|at|at+1);
        names.push(text[start..end].to_string());
        from=end;
    }
    names
}

/// A .lnk stores its target both as ANSI and UTF-16; reading both avoids COM for a yes/no answer.
fn points_to_launcher1(bytes:&[u8])->bool{
    let ansi=String::from_utf8_lossy(bytes).to_string();
    let wide:Vec<u16>=bytes.chunks_exact(2).map(|pair|u16::from_le_bytes([pair[0],pair[1]])).collect();
    let wide=String::from_utf16_lossy(&wide);
    let mentions=|needle:&str|contains_ignore_case(&ansi,needle)||contains_ignore_case(&wide,needle);
    if mentions("coco-launcher-2.exe"){return false;}
    mentions(LEGACY_EXE)||exe_names(&ansi).iter().chain(exe_names(&wide).iter()).any(|name|is_launcher1_exe_name(name))
}

pub(crate) fn retire_shortcuts_in(folders:&[(PathBuf,bool)])->usize{
    let mut retired=0;
    for (folder,nested) in folders{
        let Ok(entries)=fs::read_dir(folder) else {continue};
        for entry in entries.flatten(){
            let path=entry.path();
            let Ok(meta)=fs::symlink_metadata(&path) else {continue};
            if meta.is_dir(){
                if *nested{retired+=retire_shortcuts_in(&[(path,false)]);}
                continue;
            }
            let is_link=path.extension().is_some_and(|ext|ext.eq_ignore_ascii_case("lnk"));
            if !is_link||!meta.is_file()||meta.len()>MAX_SHORTCUT_BYTES{continue;}
            if fs::read(&path).is_ok_and(|bytes|points_to_launcher1(&bytes))&&fs::remove_file(&path).is_ok(){
                retired+=1;
                shell_forget(&path);
            }
        }
    }
    retired
}

/// Coco 1 wrote a "CocoUpdater-error-<date>-<time>.txt" on the desktop for every failure.
pub(crate) fn retire_error_reports_in(desktop:&Path)->usize{
    let Ok(entries)=fs::read_dir(desktop) else {return 0};
    entries.flatten().filter(|entry|{
        let name=entry.file_name().to_string_lossy().to_string();
        let stamp=name.strip_prefix("CocoUpdater-error-").and_then(|rest|rest.strip_suffix(".txt")).unwrap_or("");
        stamp.len()==15&&stamp.as_bytes()[8]==b'-'&&stamp.bytes().enumerate().all(|(i,b)|i==8||b.is_ascii_digit())
            &&entry.path().is_file()&&!is_link(&entry.path())
    }).filter(|entry|fs::remove_file(entry.path()).is_ok()).count()
}

/// Tells Explorer the shortcut is gone, so the desktop drops its icon at once.
fn shell_forget(path:&Path){
    #[cfg(windows)]{
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::UI::Shell::{SHChangeNotify,SHCNE_DELETE,SHCNF_PATHW};
        let wide:Vec<u16>=path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        unsafe{SHChangeNotify(SHCNE_DELETE as i32,SHCNF_PATHW,wide.as_ptr().cast(),std::ptr::null())};
    }
    #[cfg(not(windows))]
    let _=path;
}

/// Every folder Windows may be showing as this user's desktop: the registered one, the plain
/// profile folder and OneDrive's, whose name follows the Windows language.
fn desktops()->Vec<PathBuf>{
    let mut found=Vec::new();
    #[cfg(windows)]
    if let Some(path)=crate::services::game_prepare::registry::read(crate::services::game_prepare::registry::USER,
        "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders","Desktop"){
        found.push(PathBuf::from(path));
    }
    let mut homes=Vec::new();
    if let Some(home)=std::env::var_os("USERPROFILE"){
        let home=PathBuf::from(home);
        found.push(home.join("Desktop"));
        found.push(home.join("Escritorio"));
        homes.push(home.join("OneDrive"));
    }
    for variable in ["OneDrive","OneDriveConsumer","OneDriveCommercial"]{
        if let Some(path)=std::env::var_os(variable){homes.push(PathBuf::from(path));}
    }
    for home in homes{found.push(home.join("Desktop"));found.push(home.join("Escritorio"));}
    let mut unique:Vec<PathBuf>=Vec::new();
    for path in found{
        let key=path.to_string_lossy().to_lowercase();
        if path.is_dir()&&!unique.iter().any(|known|known.to_string_lossy().to_lowercase()==key){unique.push(path);}
    }
    unique
}

fn retire_launcher1_shortcuts()->usize{
    let mut folders=Vec::new();
    for desktop in desktops(){
        let reports=retire_error_reports_in(&desktop);
        if reports>0{crate::services::diagnostics::log("handoff",&format!("{reports} informe(s) de error del launcher 1 quitados del escritorio"));}
        folders.push((desktop,false));
    }
    if let Some(app_data)=std::env::var_os("APPDATA"){
        folders.push((Path::new(&app_data).join("Microsoft\\Windows\\Start Menu\\Programs"),true));
    }
    retire_shortcuts_in(&folders)
}

pub fn retire_launcher1_shortcuts_in_background(){
    std::thread::spawn(||{
        let mut retired=retire_launcher1_shortcuts();
        // Coco 1 may still be finishing the handoff that opened this Coco: look again once it is done.
        std::thread::sleep(std::time::Duration::from_secs(20));
        retired+=retire_launcher1_shortcuts();
        if retired>0{crate::services::diagnostics::log("handoff",&format!("{retired} acceso(s) del launcher 1 retirados"));}
        // Never while Coco 1 is running (or its process list is unreadable): its files are in use.
        if crate::services::standalone::process_may_be_running("CocoUpdater.exe"){return;}
        let Some(local)=std::env::var_os("LOCALAPPDATA") else {return};
        let removed=retire_launcher1_files_in(&Path::new(&local).join("CocoMinecraftUpdater"));
        if removed>0{crate::services::diagnostics::log("handoff",&format!("{removed} archivo(s) o carpeta(s) del launcher 1 eliminados"));}
    });
}

#[cfg(test)]
mod tests{
    use super::*;

    #[test]
    fn coco1_is_recognised_under_every_name_friends_saved_it_with(){
        for name in ["CocoUpdater.exe","Coco Launcher.exe","CocoMinecraftUpdater.exe","Coco Updater.exe","CocoUpdater (1).exe","coco-launcher.exe","Coco Launcher (3).exe"]{
            assert!(is_launcher1_exe_name(name),"{name}");
        }
        for name in ["coco-launcher-2.exe","Coco Launcher 2.exe","CocoLauncher2_0.6.39_x64-setup.exe","steam.exe","Cocoa.exe","CocoUpdater.exe.txt"]{
            assert!(!is_launcher1_exe_name(name),"{name}");
        }
        // A shortcut to a copy kept in Downloads is Coco 1's too.
        let wide:Vec<u8>="C:\\Users\\a\\Downloads\\Coco Launcher.exe".encode_utf16().flat_map(|unit|unit.to_le_bytes()).collect();
        assert!(points_to_launcher1(&wide));
        let other:Vec<u8>="C:\\Users\\a\\AppData\\Local\\Coco Launcher 2\\coco-launcher-2.exe".encode_utf16().flat_map(|unit|unit.to_le_bytes()).collect();
        assert!(!points_to_launcher1(&other));
    }

    #[test]
    fn only_coco1_error_reports_leave_the_desktop(){
        let desk=std::env::temp_dir().join(format!("coco-desk-{}",std::process::id()));
        let _=fs::remove_dir_all(&desk);fs::create_dir_all(&desk).unwrap();
        for name in ["CocoUpdater-error-20260822-233113.txt","CocoUpdater-error-20261108-041949.txt","CocoUpdater-error-notes.txt",
            "Coco-SSH-nazorepulgadora.zip","mis notas.txt"]{fs::write(desk.join(name),b"x").unwrap();}
        assert_eq!(retire_error_reports_in(&desk),2);
        assert!(desk.join("CocoUpdater-error-notes.txt").exists()&&desk.join("Coco-SSH-nazorepulgadora.zip").exists()&&desk.join("mis notas.txt").exists());
        let _=fs::remove_dir_all(&desk);
    }

    #[test]
    fn launcher1_files_go_and_everything_coco2_shares_stays(){
        let root=std::env::temp_dir().join(format!("coco-retire-{}",std::process::id()));
        let _=fs::remove_dir_all(&root);
        let file=|rel:&str|{let path=root.join(rel);fs::create_dir_all(path.parent().unwrap()).unwrap();fs::write(&path,b"x").unwrap();path};
        let gone=[file("CocoUpdater.exe"),file("CocoUpdater.channel.json"),file("latest.json"),file("engine-0.5.183.zip"),
            file("CocoUpdater.1234.new.exe"),file("engine\\0.5.183\\CocoUpdater.ps1"),file("downloads\\jars\\mod.jar"),
            file("downloads\\stage-abc\\x"),file("network\\state.json"),file("logs\\updater.log"),
            file("launcher\\skins\\a.png"),file("backups\\legacy-launchers\\old.exe")];
        let kept=[file("launcher\\identity.json"),file("launcher\\avatar.webp"),file("instance-locations.json"),
            file("defender-exclusions.json"),file("coco2-handoff.json"),file("preview-cache\\a.webm"),
            file("downloads\\standalone-packs\\aaaa.zip.partial"),file("backups\\experiences\\pilgrim\\save.dat")];
        assert!(retire_launcher1_files_in(&root)>=10);
        for path in &gone{assert!(!path.exists(),"{} should be gone",path.display());}
        for path in &kept{assert!(path.exists(),"{} must stay",path.display());}
        let _=fs::remove_dir_all(&root);
    }

    fn utf16(text:&str)->Vec<u8>{text.encode_utf16().flat_map(u16::to_le_bytes).collect()}

    #[test]
    fn only_shortcuts_to_the_first_launcher_are_retired(){
        let root=std::env::temp_dir().join(format!("coco-handoff-{}",std::process::id()));
        let menu=root.join("Programs").join("Coco");
        fs::create_dir_all(&menu).unwrap();
        let desktop=root.join("Desktop");
        fs::create_dir_all(&desktop).unwrap();
        let old=desktop.join("Coco Launcher.lnk");
        fs::write(&old,[b"L\0\0\0".as_slice(),&utf16("C:\\Users\\a\\AppData\\Local\\CocoMinecraftUpdater\\CocoUpdater.exe")].concat()).unwrap();
        let ansi=menu.join("Coco.lnk");
        fs::write(&ansi,b"L\0\0\0C:\\Downloads\\COCOUPDATER.EXE\0").unwrap();
        let new=desktop.join("Coco Launcher 2.lnk");
        fs::write(&new,[b"L\0\0\0".as_slice(),&utf16("C:\\Users\\a\\AppData\\Local\\Coco Launcher 2\\coco-launcher-2.exe")].concat()).unwrap();
        let other=desktop.join("Steam.lnk");
        fs::write(&other,utf16("C:\\Program Files (x86)\\Steam\\steam.exe")).unwrap();
        let note=desktop.join("CocoUpdater.exe.txt");
        fs::write(&note,"CocoUpdater.exe").unwrap();
        let retired=retire_shortcuts_in(&[(desktop.clone(),false),(root.join("Programs"),true)]);
        assert_eq!(retired,2);
        assert!(!old.exists()&&!ansi.exists());
        assert!(new.exists()&&other.exists()&&note.exists());
        let _=fs::remove_dir_all(&root);
    }
}
