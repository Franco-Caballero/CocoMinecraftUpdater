//! Size and removal of an installed standalone game. The folder is renamed first, so
//! the game disappears in one step and a game still running makes the rename fail
//! before anything is touched. Save folders found inside are set aside next to it and
//! return when the game is installed again.
use crate::services::{catalog,install,inventory,location,standalone};
use serde::Serialize;
use std::fs;
use std::path::{Component,Path,PathBuf};
use std::time::{SystemTime,UNIX_EPOCH};
use tauri::State;

const TRASH_PREFIX:&str=".coco-uninstalling-";
const KEPT_DIR:&str=".coco-kept-saves";
const SAVE_DIRS:&[&str]=&["saves","save","savegame","savegames","saved","savedata","playerdata","advancements","stats","distanthorizons"];
const SAVE_EXTENSIONS:&[&str]=&["sav","save"];

#[derive(Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct InstalledSize{id:String,bytes:u64,files:u64}

#[derive(Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct UninstallOutcome{id:String,freed_bytes:u64,kept_files:u64,leftovers:bool}

pub(crate) fn is_link(metadata:&fs::Metadata)->bool{
    #[cfg(windows)]{
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes()&0x400!=0{return true;}
    }
    metadata.file_type().is_symlink()
}

/// Never follows a link or junction: what it points at is not part of the game.
pub(crate) fn measure(root:&Path)->(u64,u64){
    let (mut bytes,mut files)=(0u64,0u64);
    let mut pending=vec![root.to_path_buf()];
    while let Some(dir)=pending.pop(){
        let Ok(entries)=fs::read_dir(&dir) else {continue};
        for entry in entries.flatten(){
            let Ok(metadata)=fs::symlink_metadata(entry.path()) else {continue};
            if is_link(&metadata){continue;}
            if metadata.is_dir(){pending.push(entry.path());}
            else{bytes=bytes.saturating_add(metadata.len());files+=1;}
        }
    }
    (bytes,files)
}

fn is_save_dir(name:&str)->bool{SAVE_DIRS.iter().any(|known|name.eq_ignore_ascii_case(known))}
fn is_save_file(path:&Path)->bool{
    path.extension().and_then(|value|value.to_str())
        .is_some_and(|extension|SAVE_EXTENSIONS.iter().any(|known|extension.eq_ignore_ascii_case(known)))
}

pub(crate) fn unique_suffix()->u128{
    SystemTime::now().duration_since(UNIX_EPOCH).map(|time|time.as_nanos()).unwrap_or_default()
}

/// A destination taken by an older kept copy gets a new name: nothing is overwritten.
fn move_keeping_both(source:&Path,destination:&Path)->std::io::Result<()>{
    if let Some(parent)=destination.parent(){fs::create_dir_all(parent)?;}
    if !destination.exists(){return fs::rename(source,destination);}
    let mut name=destination.file_name().unwrap_or_default().to_os_string();
    name.push(format!(".old-{}",unique_suffix()));
    fs::rename(source,destination.with_file_name(name))
}

/// Set saves aside before the delete. Running it again after a crash is harmless.
fn set_aside_saves(dir:&Path,relative:&Path,kept:&Path,count:&mut u64)->Result<(),String>{
    for entry in fs::read_dir(dir).map_err(|error|error.to_string())?.flatten(){
        let path=entry.path();
        let Ok(metadata)=fs::symlink_metadata(&path) else {continue};
        if is_link(&metadata){continue;}
        let name=entry.file_name();
        if relative.as_os_str().is_empty()&&name.eq_ignore_ascii_case(".coco"){continue;}
        let inner=relative.join(&name);
        if metadata.is_dir(){
            if is_save_dir(&name.to_string_lossy()){
                let files=measure(&path).1;
                if files>0{
                    move_keeping_both(&path,&kept.join(&inner)).map_err(|error|error.to_string())?;
                    *count+=files;
                }
            }else{set_aside_saves(&path,&inner,kept,count)?;}
        }else if is_save_file(&path){
            move_keeping_both(&path,&kept.join(&inner)).map_err(|error|error.to_string())?;
            *count+=1;
        }
    }
    Ok(())
}

pub(crate) fn kept_saves_dir(target:&Path,instance_id:&str)->Option<PathBuf>{
    Some(target.parent()?.join(KEPT_DIR).join(instance_id))
}

/// Saves first: if they cannot be moved, the renamed folder stays for the next sweep.
fn finish_removal(trash:&Path,kept:&Path)->Result<u64,String>{
    let mut count=0;
    set_aside_saves(trash,Path::new(""),kept,&mut count)?;
    fs::remove_dir_all(trash).map_err(|error|error.to_string())?;
    Ok(count)
}

fn resolve(entry:&catalog::Experience)->Result<(PathBuf,bool),String>{
    let app_data=PathBuf::from(std::env::var_os("APPDATA").ok_or("APPDATA no disponible")?);
    let local_data=PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA no disponible")?);
    let locations=inventory::custom_locations(&local_data)?;
    let custom=inventory::custom_path(&locations,&entry.instance_id,&entry.id).is_some();
    Ok((inventory::resolve_instance_root(entry,&app_data,&locations),custom))
}

pub(crate) fn standalone_entry(id:&str)->Result<catalog::Experience,String>{
    catalog::read_catalog()?.into_iter()
        .find(|entry|entry.id==id&&entry.workflow=="coco-standalone")
        .ok_or_else(||"Juego desconocido".to_string())
}

fn local_folder(root:&Path)->bool{
    root.is_absolute()&&!root.to_string_lossy().starts_with("\\\\")&&root.parent().is_some()
        &&!root.components().any(|part|matches!(part,Component::ParentDir|Component::CurDir))
}

/// A custom location is a path the player chose. It counts as this game's folder only
/// if the game's own executable is inside, so a wrong entry can never empty a drive.
pub(crate) fn owns_folder(root:&Path,custom:bool,instance_id:&str,executable:&str)->bool{
    if !local_folder(root)||root.file_name().is_none(){return false;}
    if custom{
        let relative=Path::new(executable);
        return !executable.is_empty()&&relative.is_relative()
            &&!relative.components().any(|part|matches!(part,Component::ParentDir))
            &&root.join(relative).is_file();
    }
    root.file_name().is_some_and(|name|name==instance_id)
}

fn uninstall_at(root:&Path,instance_id:&str)->Result<(u64,u64,bool),String>{
    let parent=root.parent().ok_or("Ubicación inválida")?;
    let freed=measure(root).0;
    let trash=parent.join(format!("{TRASH_PREFIX}{instance_id}-{}",unique_suffix()));
    fs::rename(root,&trash).map_err(|_|"Windows no deja mover la carpeta. Cierra el juego y vuelve a intentarlo.".to_string())?;
    let kept=kept_saves_dir(root,instance_id).ok_or("Ubicación inválida")?;
    let before=measure(&kept).1;
    let leftovers=finish_removal(&trash,&kept).is_err();
    Ok((freed,measure(&kept).1.saturating_sub(before),leftovers))
}

fn restore_at(target:&Path,kept:&Path,relative:&Path)->Result<(),String>{
    for entry in fs::read_dir(kept).map_err(|error|error.to_string())?.flatten(){
        let path=entry.path();
        let Ok(metadata)=fs::symlink_metadata(&path) else {continue};
        if is_link(&metadata){continue;}
        let inner=relative.join(entry.file_name());
        if metadata.is_dir(){
            restore_at(target,&path,&inner)?;
            let _=fs::remove_dir(&path);
        }else if !target.join(&inner).exists(){
            if let Some(parent)=target.join(&inner).parent(){fs::create_dir_all(parent).map_err(|error|error.to_string())?;}
            fs::rename(&path,target.join(&inner)).map_err(|error|error.to_string())?;
        }
    }
    Ok(())
}

/// Called after a successful install. A name the game already ships stays as shipped,
/// so verified files never change; the kept copy simply remains set aside.
pub(crate) fn restore_kept_saves(target:&Path,instance_id:&str){
    let Some(kept)=kept_saves_dir(target,instance_id) else {return};
    if kept.is_dir()&&restore_at(target,&kept,Path::new("")).is_ok(){
        let _=fs::remove_dir(&kept);
        if let Some(parent)=kept.parent(){let _=fs::remove_dir(parent);}
    }
}

/// Finish removals and moves a crash or a locked file left behind.
fn sweep_trash(experiences:&Path){
    let Ok(entries)=fs::read_dir(experiences) else {return};
    for entry in entries.flatten(){
        let name=entry.file_name().to_string_lossy().to_string();
        if name.starts_with(location::MOVED_PREFIX)||name.starts_with(location::MOVE_STAGE_PREFIX){
            if fs::symlink_metadata(entry.path()).map(|metadata|!is_link(&metadata)&&metadata.is_dir()).unwrap_or(false){
                let _=fs::remove_dir_all(entry.path());
            }
            continue;
        }
        let Some(instance)=name.strip_prefix(TRASH_PREFIX).and_then(|rest|rest.rsplit_once('-')).map(|parts|parts.0) else {continue};
        let path=entry.path();
        if fs::symlink_metadata(&path).map(|metadata|is_link(&metadata)||!metadata.is_dir()).unwrap_or(true){continue;}
        let _=finish_removal(&path,&experiences.join(KEPT_DIR).join(instance));
    }
}

pub fn sweep_in_background(){
    let Some(app_data)=std::env::var_os("APPDATA") else {return};
    let local_data=std::env::var_os("LOCALAPPDATA");
    std::thread::spawn(move||{
        sweep_trash(&inventory::games_root(Path::new(&app_data)));
        sweep_trash(&inventory::legacy_root(Path::new(&app_data)));
        let Some(local_data)=local_data else {return};
        // Games the player placed elsewhere leave theirs next to them.
        let Ok(locations)=inventory::custom_locations(Path::new(&local_data)) else {return};
        for path in locations.values().filter_map(|value|value.as_str()).map(Path::new).filter(|path|local_folder(path)){
            if let Some(parent)=path.parent(){sweep_trash(parent);}
        }
    });
}

#[tauri::command]
pub async fn get_installed_size(id:String)->Result<InstalledSize,String>{
    tauri::async_runtime::spawn_blocking(move||{
        let entry=standalone_entry(&id)?;
        let (root,_)=resolve(&entry)?;
        if !local_folder(&root)||fs::symlink_metadata(&root).map(|metadata|is_link(&metadata)).unwrap_or(true){
            return Err("La carpeta del juego no se puede medir".to_string());
        }
        let (bytes,files)=measure(&root);
        Ok(InstalledSize{id,bytes,files})
    }).await.map_err(|error|format!("Medición interrumpida: {error}"))?
}

#[tauri::command]
pub async fn uninstall_standalone(id:String,runtime:State<'_,standalone::RuntimeState>,
    install_state:State<'_,install::InstallState>)->Result<UninstallOutcome,String>{
    let entry=standalone_entry(&id)?;
    if standalone::is_game_active(&id,&runtime).await{
        return Err("Cierra el juego antes de desinstalarlo.".into());
    }
    let (reservation,_)=install::reserve_exclusive(&id,&install_state)?;
    tauri::async_runtime::spawn_blocking(move||{
        let _reservation=reservation;
        let (root,custom)=resolve(&entry)?;
        if !owns_folder(&root,custom,&entry.instance_id,&entry.executable){
            return Err("Esa carpeta no parece ser de este juego, así que Coco no la borró.".to_string());
        }
        if !root.is_dir(){return Err("El juego ya no está instalado.".to_string());}
        install::assert_can_remove(&root,&entry.id,&entry.instance_id)?;
        let (freed_bytes,kept_files,leftovers)=uninstall_at(&root,&entry.instance_id)?;
        install::remove_cached_archives(&entry.id);
        Ok(UninstallOutcome{id:entry.id.clone(),freed_bytes,kept_files,leftovers})
    }).await.map_err(|error|format!("Desinstalación interrumpida: {error}"))?
}

#[cfg(test)]
mod tests{
    use super::*;
    use std::sync::atomic::{AtomicU64,Ordering};
    static SEQUENCE:AtomicU64=AtomicU64::new(0);

    struct Root(PathBuf);
    impl Root{
        fn new()->Self{
            let path=std::env::temp_dir().join(format!("coco-uninstall-test-{}-{}",std::process::id(),SEQUENCE.fetch_add(1,Ordering::Relaxed)));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Root{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
    fn put(path:&Path,bytes:&[u8]){fs::create_dir_all(path.parent().unwrap()).unwrap();fs::write(path,bytes).unwrap();}

    fn game(root:&Root)->PathBuf{
        let game=root.0.join("experiences").join("demo");
        put(&game.join("game.exe"),&[1;100]);
        put(&game.join("Data/level.bin"),&[2;50]);
        put(&game.join(".coco/standalone-install-v1.json"),b"{}");
        put(&game.join("Game/Saved/SaveGames/slot1.bin"),b"mine");
        put(&game.join("loose.sav"),b"loose");
        game
    }

    #[test]
    fn removes_the_game_and_sets_saves_aside_for_reinstall(){
        let root=Root::new();
        let target=game(&root);
        let (freed,kept,leftovers)=uninstall_at(&target,"demo").unwrap();
        assert_eq!((freed,kept,leftovers),(161,2,false));
        assert!(!target.exists());
        let parent=target.parent().unwrap();
        assert!(!fs::read_dir(parent).unwrap().flatten().any(|entry|entry.file_name().to_string_lossy().starts_with(TRASH_PREFIX)));
        assert_eq!(fs::read(parent.join(KEPT_DIR).join("demo/Game/Saved/SaveGames/slot1.bin")).unwrap(),b"mine");
        // A reinstall gets them back without replacing anything the game ships.
        put(&target.join("game.exe"),&[9;9]);
        put(&target.join("loose.sav"),b"shipped");
        restore_kept_saves(&target,"demo");
        assert_eq!(fs::read(target.join("Game/Saved/SaveGames/slot1.bin")).unwrap(),b"mine");
        assert_eq!(fs::read(target.join("loose.sav")).unwrap(),b"shipped");
        assert_eq!(fs::read(parent.join(KEPT_DIR).join("demo/loose.sav")).unwrap(),b"loose","a collision is kept, not lost");
    }

    #[test]
    fn an_older_kept_copy_is_never_overwritten(){
        let root=Root::new();
        let target=game(&root);
        put(&root.0.join("experiences").join(KEPT_DIR).join("demo/loose.sav"),b"older");
        uninstall_at(&target,"demo").unwrap();
        let kept=root.0.join("experiences").join(KEPT_DIR).join("demo");
        assert_eq!(fs::read(kept.join("loose.sav")).unwrap(),b"older");
        assert!(fs::read_dir(&kept).unwrap().flatten().any(|entry|entry.file_name().to_string_lossy().starts_with("loose.sav.old-")));
    }

    #[test]
    fn a_crash_after_the_rename_finishes_on_the_next_launch(){
        let root=Root::new();
        let experiences=root.0.join("experiences");
        let trash=experiences.join(format!("{TRASH_PREFIX}my-game-123"));
        put(&trash.join("game.exe"),&[1;10]);
        put(&trash.join("saves/world.dat"),b"world");
        sweep_trash(&experiences);
        assert!(!trash.exists());
        assert_eq!(fs::read(experiences.join(KEPT_DIR).join("my-game/saves/world.dat")).unwrap(),b"world");
    }

    #[test]
    fn only_the_games_own_folder_can_be_removed(){
        let root=Root::new();
        let target=game(&root);
        assert!(owns_folder(&target,false,"demo","game.exe"));
        assert!(!owns_folder(&target,false,"other","game.exe"),"default folder must carry the instance name");
        let elsewhere=root.0.join("Games");
        fs::create_dir_all(&elsewhere).unwrap();
        assert!(!owns_folder(&elsewhere,true,"demo","game.exe"),"a custom path without the game is not the game");
        assert!(owns_folder(&target,true,"demo","game.exe"));
        assert!(!owns_folder(&target,true,"demo","../game.exe"));
        assert!(!owns_folder(&target,true,"demo",""));
        assert!(!owns_folder(Path::new("relative/demo"),false,"demo","game.exe"));
        #[cfg(windows)]assert!(!owns_folder(Path::new("C:\\"),true,"demo","game.exe"),"never a drive root");
    }

    #[cfg(windows)]
    #[test]
    fn a_junction_inside_the_game_is_not_followed(){
        let root=Root::new();
        let target=game(&root);
        let outside=root.0.join("outside");
        put(&outside.join("precious.txt"),b"keep");
        let status=std::process::Command::new("cmd").args(["/C","mklink","/J"])
            .arg(target.join("link")).arg(&outside).output().unwrap();
        assert!(status.status.success());
        assert_eq!(measure(&target).0,161,"junction contents are not the game's size");
        uninstall_at(&target,"demo").unwrap();
        assert_eq!(fs::read(outside.join("precious.txt")).unwrap(),b"keep");
    }
}
