//! Where a standalone game lives. The chosen folder is a parent: Coco creates the game's
//! own folder inside it, in the same instance-locations.json Launcher 1 reads. Moving never
//! leaves a game half-way: within a drive it is one rename, and across drives the original
//! is only removed after every copied file has been read back and compared.
use crate::services::{catalog,identity,install,inventory,standalone,uninstall};
use serde::Serialize;
use serde_json::{Map,Value};
use sha2::{Digest,Sha256};
use std::fs::{self,File,OpenOptions};
use std::io::{Read,Write};
use std::path::{Component,Path,PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool,Ordering};
use std::time::{Duration,Instant};
use tauri::{AppHandle,State};

pub(crate) const MOVE_STAGE_PREFIX:&str=".coco-moving-";
pub(crate) const MOVED_PREFIX:&str=".coco-moved-";
const ERROR_NOT_SAME_DEVICE:i32=17;
const COPY_BUFFER:usize=1024*1024;

#[derive(Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct InstallLocation{id:String,path:String,custom:bool,free_bytes:Option<u64>}

#[derive(Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct LocationCheck{id:String,root:String,same_drive:bool,free_bytes:Option<u64>,needed_bytes:u64}

#[derive(Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct MoveOutcome{id:String,path:String,copied:bool,leftovers:bool}

struct Roots{local_data:PathBuf,locations:Map<String,Value>,current:PathBuf,default_root:PathBuf,others:Vec<PathBuf>}

fn roots_for(entry:&catalog::Experience)->Result<Roots,String>{
    let app_data=PathBuf::from(std::env::var_os("APPDATA").ok_or("APPDATA no disponible")?);
    let local_data=PathBuf::from(std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA no disponible")?);
    let locations=inventory::custom_locations(&local_data)?;
    let others=catalog::read_catalog()?.iter()
        .filter(|other|other.id!=entry.id&&matches!(other.workflow.as_str(),"coco-standalone"|"coco-managed"))
        .map(|other|inventory::resolve_instance_root(other,&app_data,&locations)).collect();
    Ok(Roots{current:inventory::resolve_instance_root(entry,&app_data,&locations),
        default_root:inventory::games_root(&app_data).join(&entry.instance_id),
        local_data,locations,others})
}

fn key(path:&Path)->Vec<String>{
    path.components().map(|part|part.as_os_str().to_string_lossy().to_lowercase()).collect()
}
fn same_path(a:&Path,b:&Path)->bool{key(a)==key(b)}
fn within(path:&Path,root:&Path)->bool{
    let (path,root)=(key(path),key(root));
    path.len()>=root.len()&&path[..root.len()]==root[..]
}
fn same_drive(a:&Path,b:&Path)->bool{key(a).first()==key(b).first()}

/// Every reason a folder can be refused, in words the player can act on.
fn validate_destination(parent:&Path,instance_id:&str,current:&Path,others:&[PathBuf])->Result<PathBuf,String>{
    if !parent.is_absolute()||parent.to_string_lossy().starts_with("\\\\")
        ||parent.components().any(|part|matches!(part,Component::ParentDir|Component::CurDir)){
        return Err("Elige una carpeta de este PC. Las carpetas de red no sirven para jugar.".into());
    }
    if !parent.is_dir(){return Err("Esa carpeta ya no existe.".into());}
    if install::assert_no_links(parent).is_err(){
        return Err("Esa carpeta es un acceso a otro lugar. Elige una carpeta normal.".into());
    }
    let root=parent.join(instance_id);
    if same_path(&root,current){return Err("El juego ya está en esa carpeta.".into());}
    if within(&root,current){return Err("No se puede mover un juego dentro de su propia carpeta.".into());}
    if others.iter().any(|other|within(&root,other)||within(other,&root)){
        return Err("Esa carpeta pertenece a otro juego. Elige otra.".into());
    }
    if fs::symlink_metadata(&root).is_ok(){
        return Err(format!("Ya hay una carpeta llamada {instance_id} ahí. Elige otra ubicación."));
    }
    let probe=parent.join(format!(".coco-write-test-{}",uninstall::unique_suffix()));
    OpenOptions::new().write(true).create_new(true).open(&probe)
        .map_err(|_|"Windows no deja escribir en esa carpeta. Elige otra.".to_string())?;
    let _=fs::remove_file(&probe);
    Ok(root)
}

/// Same atomic replace and shape as Launcher 1, keeping every other game's entry.
fn write_location(local_data:&Path,entry:&catalog::Experience,root:Option<&Path>)->Result<(),String>{
    let store=local_data.join("CocoMinecraftUpdater").join("instance-locations.json");
    let mut map=inventory::custom_locations(local_data)?;
    map.remove(&entry.id);
    match root{
        Some(path)=>{map.insert(entry.instance_id.clone(),Value::String(path.display().to_string()));}
        None=>{map.remove(&entry.instance_id);}
    }
    write_store(&store,&map)
}

fn write_store(store:&Path,map:&Map<String,Value>)->Result<(),String>{
    let parent=store.parent().ok_or("Ubicación inválida")?;
    fs::create_dir_all(parent).map_err(|error|error.to_string())?;
    let payload=serde_json::to_vec_pretty(map).map_err(|error|error.to_string())?;
    let temp=parent.join(format!(".instance-locations.tmp-{}",uninstall::unique_suffix()));
    let result=(||{
        let mut file=OpenOptions::new().write(true).create_new(true).open(&temp)?;
        file.write_all(&payload)?;
        file.sync_all()?;
        drop(file);
        identity::atomic_replace(&temp,store)
    })();
    if result.is_err(){let _=fs::remove_file(&temp);}
    result.map_err(|error|format!("No se pudo guardar la ubicación: {error}"))
}

fn stored_value(root:&Path,default_root:&Path)->Option<PathBuf>{
    if same_path(root,default_root){None}else{Some(root.to_path_buf())}
}

fn hash_file(path:&Path,token:&AtomicBool,on_bytes:&mut dyn FnMut(u64))->Result<[u8;32],String>{
    let mut file=File::open(path).map_err(|error|error.to_string())?;
    let mut hasher=Sha256::new();
    let mut buffer=vec![0u8;COPY_BUFFER];
    loop{
        if token.load(Ordering::Relaxed){return Err("cancelled".into());}
        let count=file.read(&mut buffer).map_err(|error|error.to_string())?;
        if count==0{break;}
        hasher.update(&buffer[..count]);
        on_bytes(count as u64);
    }
    Ok(hasher.finalize().into())
}

fn copy_file(source:&Path,destination:&Path,token:&AtomicBool,on_bytes:&mut dyn FnMut(u64))->Result<(),String>{
    let mut input=File::open(source).map_err(|error|error.to_string())?;
    let mut output=OpenOptions::new().write(true).create_new(true).open(destination).map_err(|error|error.to_string())?;
    let mut hasher=Sha256::new();
    let mut buffer=vec![0u8;COPY_BUFFER];
    loop{
        if token.load(Ordering::Relaxed){return Err("cancelled".into());}
        let count=input.read(&mut buffer).map_err(|error|error.to_string())?;
        if count==0{break;}
        hasher.update(&buffer[..count]);
        output.write_all(&buffer[..count]).map_err(|error|error.to_string())?;
        on_bytes(count as u64);
    }
    output.sync_all().map_err(|error|error.to_string())?;
    let metadata=input.metadata().map_err(|error|error.to_string())?;
    if let Ok(modified)=metadata.modified(){let _=output.set_modified(modified);}
    drop(output);
    let copied:[u8;32]=hasher.finalize().into();
    if hash_file(destination,token,on_bytes)?!=copied{
        return Err(format!("{} no coincide después de copiarlo",source.display()));
    }
    fs::set_permissions(destination,metadata.permissions()).map_err(|error|error.to_string())
}

/// `on_bytes` counts each byte twice, written and read back: total is twice the size.
fn copy_tree(source:&Path,destination:&Path,token:&AtomicBool,on_bytes:&mut dyn FnMut(u64))->Result<(),String>{
    fs::create_dir_all(destination).map_err(|error|error.to_string())?;
    let mut pending=vec![(source.to_path_buf(),destination.to_path_buf())];
    while let Some((from,to))=pending.pop(){
        for entry in fs::read_dir(&from).map_err(|error|error.to_string())?{
            let entry=entry.map_err(|error|error.to_string())?;
            let metadata=fs::symlink_metadata(entry.path()).map_err(|error|error.to_string())?;
            let target=to.join(entry.file_name());
            if uninstall::is_link(&metadata){
                return Err("El juego contiene accesos a otras carpetas y no se puede copiar a otra unidad.".into());
            }
            if metadata.is_dir(){
                fs::create_dir(&target).map_err(|error|error.to_string())?;
                pending.push((entry.path(),target));
            }else{copy_file(&entry.path(),&target,token,on_bytes)?;}
        }
    }
    Ok(())
}

struct RemoveUnlessKept(Option<PathBuf>);
impl Drop for RemoveUnlessKept{
    fn drop(&mut self){if let Some(path)=&self.0{let _=fs::remove_dir_all(path);}}
}

/// Saves set aside by an uninstall follow the game, or a reinstall would not find them.
pub(crate) fn follow_kept_saves(old_root:&Path,new_root:&Path,instance_id:&str){
    let (Some(old),Some(new))=(uninstall::kept_saves_dir(old_root,instance_id),uninstall::kept_saves_dir(new_root,instance_id)) else {return};
    if !old.is_dir()||new.exists()||same_path(&old,&new){return;}
    if let Some(parent)=new.parent(){if fs::create_dir_all(parent).is_err(){return;}}
    if fs::rename(&old,&new).is_err(){
        let stop=AtomicBool::new(false);
        if copy_tree(&old,&new,&stop,&mut |_|{}).is_ok(){let _=fs::remove_dir_all(&old);}
        else{let _=fs::remove_dir_all(&new);}
    }
}

struct MoveRequest<'a>{current:&'a Path,root:&'a Path,default_root:&'a Path,local_data:&'a Path,instance_id:&'a str,previous:Option<String>}

/// The record is written before the original goes, so a crash at any point leaves the
/// game playable from the place the record names.
fn move_game(request:MoveRequest,token:&AtomicBool,on_bytes:&mut dyn FnMut(u64),save:&dyn Fn(Option<&Path>)->Result<(),String>)
    ->Result<(bool,bool),String>{
    let MoveRequest{current,root,default_root,local_data,instance_id,previous}=request;
    let target=stored_value(root,default_root);
    let parent=root.parent().ok_or("Ubicación inválida")?;
    match fs::rename(current,root){
        Ok(())=>{
            if let Err(error)=save(target.as_deref()){
                let _=fs::rename(root,current);
                return Err(error);
            }
            return Ok((false,false));
        }
        Err(error) if error.raw_os_error()!=Some(ERROR_NOT_SAME_DEVICE)=>{
            return Err("Windows no deja mover la carpeta. Cierra el juego y vuelve a intentarlo.".into());
        }
        Err(_)=>{}
    }
    let (bytes,_)=uninstall::measure(current);
    install::ensure_free_space(parent,bytes)?;
    let stage=parent.join(format!("{MOVE_STAGE_PREFIX}{instance_id}-{}",uninstall::unique_suffix()));
    let mut cleanup=RemoveUnlessKept(Some(stage.clone()));
    copy_tree(current,&stage,token,on_bytes)?;
    if token.load(Ordering::Relaxed){return Err("cancelled".into());}
    let (_,copied)=uninstall::measure(current);
    if uninstall::measure(&stage).1!=copied{return Err("La copia no contiene todos los archivos.".into());}
    fs::rename(&stage,root).map_err(|error|format!("No se pudo publicar la copia: {error}"))?;
    cleanup.0=Some(root.to_path_buf());
    save(target.as_deref())?;
    let trash=current.parent().ok_or("Ubicación inválida")?.join(format!("{MOVED_PREFIX}{instance_id}-{}",uninstall::unique_suffix()));
    if fs::rename(current,&trash).is_err(){
        let store=local_data.join("CocoMinecraftUpdater").join("instance-locations.json");
        let mut map=inventory::custom_locations(local_data)?;
        match &previous{
            Some(value)=>{map.insert(instance_id.to_string(),Value::String(value.clone()));}
            None=>{map.remove(instance_id);}
        }
        write_store(&store,&map)?;
        return Err("Windows no deja mover la carpeta. Cierra el juego y vuelve a intentarlo.".into());
    }
    cleanup.0=None;
    Ok((true,fs::remove_dir_all(&trash).is_err()))
}

fn drive_free(path:&Path)->Option<u64>{
    let mut probe=path;
    loop{
        if probe.is_dir(){return install::available_disk_bytes(probe).ok().flatten();}
        probe=probe.parent()?;
    }
}

fn destination_parent(parent:Option<String>,roots:&Roots)->Result<PathBuf,String>{
    match parent{
        Some(value)=>Ok(PathBuf::from(value)),
        None=>{
            let default_parent=roots.default_root.parent().ok_or("Ubicación inválida")?.to_path_buf();
            fs::create_dir_all(&default_parent).map_err(|error|error.to_string())?;
            Ok(default_parent)
        }
    }
}

#[tauri::command]
pub async fn get_install_location(id:String)->Result<InstallLocation,String>{
    tauri::async_runtime::spawn_blocking(move||{
        let entry=uninstall::standalone_entry(&id)?;
        let roots=roots_for(&entry)?;
        Ok(InstallLocation{id,free_bytes:drive_free(&roots.current),path:roots.current.display().to_string(),
            custom:!same_path(&roots.current,&roots.default_root)})
    }).await.map_err(|error|format!("Lectura interrumpida: {error}"))?
}

#[tauri::command]
pub async fn check_install_location(id:String,parent:Option<String>)->Result<LocationCheck,String>{
    tauri::async_runtime::spawn_blocking(move||{
        let entry=uninstall::standalone_entry(&id)?;
        let roots=roots_for(&entry)?;
        let parent=destination_parent(parent,&roots)?;
        let root=validate_destination(&parent,&entry.instance_id,&roots.current,&roots.others)?;
        let same=same_drive(&root,&roots.current);
        Ok(LocationCheck{id,root:root.display().to_string(),same_drive:same,free_bytes:drive_free(&parent),
            needed_bytes:if !same&&roots.current.is_dir(){uninstall::measure(&roots.current).0}else{0}})
    }).await.map_err(|error|format!("Comprobación interrumpida: {error}"))?
}

/// For a game that is not installed yet: only the record changes.
#[tauri::command]
pub async fn set_install_location(id:String,parent:Option<String>,install_state:State<'_,install::InstallState>)->Result<InstallLocation,String>{
    let (reservation,_)=install::reserve_exclusive(&id,&install_state)?;
    tauri::async_runtime::spawn_blocking(move||{
        let _reservation=reservation;
        let entry=uninstall::standalone_entry(&id)?;
        let roots=roots_for(&entry)?;
        if roots.current.exists(){return Err("Este juego ya está instalado: hay que moverlo.".to_string());}
        let chosen=destination_parent(parent,&roots)?;
        let root=if same_path(&chosen.join(&entry.instance_id),&roots.default_root)&&!roots.default_root.exists(){roots.default_root.clone()}
            else{validate_destination(&chosen,&entry.instance_id,&roots.current,&roots.others)?};
        write_location(&roots.local_data,&entry,stored_value(&root,&roots.default_root).as_deref())?;
        follow_kept_saves(&roots.current,&root,&entry.instance_id);
        Ok(InstallLocation{id,free_bytes:drive_free(&root),path:root.display().to_string(),custom:!same_path(&root,&roots.default_root)})
    }).await.map_err(|error|format!("Cambio interrumpido: {error}"))?
}

#[tauri::command]
pub async fn move_installation(id:String,parent:Option<String>,app:AppHandle,runtime:State<'_,standalone::RuntimeState>,
    install_state:State<'_,install::InstallState>)->Result<MoveOutcome,String>{
    let entry=uninstall::standalone_entry(&id)?;
    if standalone::is_game_active(&id,&runtime).await{
        return Err("Cierra el juego antes de moverlo.".into());
    }
    let (reservation,token)=install::reserve_exclusive(&id,&install_state)?;
    tauri::async_runtime::spawn_blocking(move||{
        let _reservation=reservation;
        let roots=roots_for(&entry)?;
        if !roots.current.is_dir(){return Err("El juego ya no está instalado.".to_string());}
        let custom=inventory::custom_path(&roots.locations,&entry.instance_id,&entry.id).is_some();
        if !uninstall::owns_folder(&roots.current,custom,&entry.instance_id,&entry.executable){
            return Err("Esa carpeta no parece ser de este juego, así que Coco no la movió.".to_string());
        }
        install::assert_can_remove(&roots.current,&entry.id,&entry.instance_id)?;
        let chosen=destination_parent(parent,&roots)?;
        let root=validate_destination(&chosen,&entry.instance_id,&roots.current,&roots.others)?;
        crate::services::defender::ensure_for_new_folder(&app,&root);
        let previous=roots.locations.get(&entry.instance_id).and_then(Value::as_str).map(str::to_string);
        let total=uninstall::measure(&roots.current).0.saturating_mul(2);
        let (mut done,mut last)=(0u64,Instant::now());
        let (local_data,progress_entry)=(roots.local_data.clone(),entry.clone());
        let (copied,leftovers)=move_game(
            MoveRequest{current:&roots.current,root:&root,default_root:&roots.default_root,local_data:&roots.local_data,instance_id:&entry.instance_id,previous},
            &token,
            &mut |count|{
                done=done.saturating_add(count);
                if last.elapsed()>=Duration::from_millis(120){
                    last=Instant::now();
                    install::emit_progress(&app,&progress_entry.id,"moving","",done,total);
                }
            },
            &|target|write_location(&local_data,&entry,target),
        )?;
        follow_kept_saves(&roots.current,&root,&entry.instance_id);
        Ok(MoveOutcome{id:entry.id.clone(),path:root.display().to_string(),copied,leftovers})
    }).await.map_err(|error|format!("Movimiento interrumpido: {error}"))?
}

#[tauri::command]
pub async fn open_game_folder(id:String)->Result<(),String>{
    tauri::async_runtime::spawn_blocking(move||{
        let entry=uninstall::standalone_entry(&id)?;
        let roots=roots_for(&entry)?;
        if !roots.current.is_dir()||install::assert_no_links(&roots.current).is_err(){
            return Err("La carpeta del juego no está disponible.".to_string());
        }
        Command::new("explorer.exe").arg(&roots.current).spawn().map(|_|())
            .map_err(|_|"No se pudo abrir la carpeta.".to_string())
    }).await.map_err(|error|format!("Apertura interrumpida: {error}"))?
}

#[cfg(test)]
mod tests{
    use super::*;
    use std::cell::RefCell;
    use std::sync::atomic::AtomicU64;
    static SEQUENCE:AtomicU64=AtomicU64::new(0);

    struct Root(PathBuf);
    impl Root{
        fn new()->Self{
            let path=std::env::temp_dir().join(format!("coco-location-test-{}-{}",std::process::id(),SEQUENCE.fetch_add(1,Ordering::Relaxed)));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Root{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
    fn put(path:&Path,bytes:&[u8]){fs::create_dir_all(path.parent().unwrap()).unwrap();fs::write(path,bytes).unwrap();}
    fn game(root:&Path){
        put(&root.join("game.exe"),&[1;5000]);
        put(&root.join("Data/deep/level.bin"),&[2;3000]);
        put(&root.join(".coco/standalone-install-v1.json"),b"{}");
        fs::create_dir_all(root.join("empty")).unwrap();
    }

    #[test]
    fn a_destination_is_refused_for_every_unsafe_reason(){
        let root=Root::new();
        let current=root.0.join("old/demo");
        game(&current);
        let other=root.0.join("other/game");
        fs::create_dir_all(&other).unwrap();
        let free=root.0.join("free");
        fs::create_dir_all(&free).unwrap();
        let others=vec![other.clone()];
        let ok=validate_destination(&free,"demo",&current,&others).unwrap();
        assert_eq!(ok,free.join("demo"));
        assert!(fs::read_dir(&free).unwrap().next().is_none(),"the write test leaves nothing behind");
        assert!(validate_destination(&root.0.join("old"),"demo",&current,&others).unwrap_err().contains("ya está"));
        assert!(validate_destination(&current.join("Data"),"demo",&current,&others).unwrap_err().contains("propia carpeta"));
        assert!(validate_destination(&other,"demo",&current,&others).unwrap_err().contains("otro juego"));
        assert!(validate_destination(&root.0.join("missing"),"demo",&current,&others).unwrap_err().contains("ya no existe"));
        assert!(validate_destination(Path::new("relative"),"demo",&current,&others).is_err());
        #[cfg(windows)]assert!(validate_destination(Path::new("\\\\server\\share"),"demo",&current,&others).unwrap_err().contains("red"));
        put(&free.join("demo/x"),b"x");
        assert!(validate_destination(&free,"demo",&current,&others).unwrap_err().contains("Ya hay"));
    }

    #[cfg(windows)]
    #[test]
    fn a_junction_is_not_a_destination(){
        let root=Root::new();
        let real=root.0.join("real");
        fs::create_dir_all(&real).unwrap();
        let link=root.0.join("link");
        assert!(Command::new("cmd").args(["/C","mklink","/J"]).arg(&link).arg(&real).output().unwrap().status.success());
        assert!(validate_destination(&link,"demo",&root.0.join("old/demo"),&[]).unwrap_err().contains("acceso"));
    }

    #[test]
    fn the_copy_is_complete_and_counts_every_byte_twice(){
        let root=Root::new();
        let source=root.0.join("a");
        game(&source);
        let target=root.0.join("b");
        let mut counted=0;
        copy_tree(&source,&target,&AtomicBool::new(false),&mut |count|counted+=count).unwrap();
        assert_eq!(fs::read(target.join("Data/deep/level.bin")).unwrap(),vec![2;3000]);
        assert!(target.join("empty").is_dir());
        assert_eq!(counted,uninstall::measure(&source).0*2);
    }

    #[test]
    fn a_cancelled_copy_cannot_finish(){
        let root=Root::new();
        let source=root.0.join("a");
        game(&source);
        assert_eq!(copy_tree(&source,&root.0.join("b"),&AtomicBool::new(true),&mut |_|{}).unwrap_err(),"cancelled");
    }

    #[cfg(windows)]
    #[test]
    fn a_game_with_a_junction_cannot_cross_drives_and_nothing_is_followed(){
        let root=Root::new();
        let source=root.0.join("a");
        game(&source);
        let outside=root.0.join("outside");
        put(&outside.join("precious"),b"keep");
        assert!(Command::new("cmd").args(["/C","mklink","/J"]).arg(source.join("link")).arg(&outside).output().unwrap().status.success());
        assert!(copy_tree(&source,&root.0.join("b"),&AtomicBool::new(false),&mut |_|{}).unwrap_err().contains("accesos"));
        assert_eq!(fs::read(outside.join("precious")).unwrap(),b"keep");
    }

    #[test]
    fn a_move_on_one_drive_is_a_rename_and_a_failed_record_puts_it_back(){
        let root=Root::new();
        let current=root.0.join("old/demo");
        game(&current);
        let target=root.0.join("new/demo");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        let request=||MoveRequest{current:&current,root:&target,default_root:&current,local_data:&root.0,instance_id:"demo",previous:None};
        let failed=move_game(request(),&AtomicBool::new(false),&mut |_|{},&|_|Err("disk full".to_string()));
        assert_eq!(failed.unwrap_err(),"disk full");
        assert!(current.join("game.exe").is_file()&&!target.exists(),"the game went back");
        let saved=RefCell::new(None);
        let (copied,leftovers)=move_game(request(),&AtomicBool::new(false),&mut |_|{},&|value|{*saved.borrow_mut()=value.map(Path::to_path_buf);Ok(())}).unwrap();
        assert_eq!((copied,leftovers),(false,false));
        assert!(target.join("game.exe").is_file()&&!current.exists());
        assert_eq!(saved.into_inner(),Some(target.clone()),"anywhere but the default is recorded");
    }

    #[test]
    fn the_default_folder_is_not_recorded_and_other_games_entries_survive(){
        let root=Root::new();
        assert_eq!(stored_value(Path::new("C:\\A\\demo"),Path::new("c:\\a\\DEMO")),None);
        assert_eq!(stored_value(Path::new("D:\\demo"),Path::new("C:\\a\\demo")),Some(PathBuf::from("D:\\demo")));
        let store=root.0.join("CocoMinecraftUpdater/instance-locations.json");
        put(&store,br#"{"other":"D:\\Games\\other","demo":"E:\\demo"}"#);
        let mut map=inventory::custom_locations(&root.0).unwrap();
        map.remove("demo");
        write_store(&store,&map).unwrap();
        let read=inventory::custom_locations(&root.0).unwrap();
        assert_eq!(read.get("other").and_then(Value::as_str),Some("D:\\Games\\other"));
        assert!(read.get("demo").is_none());
        assert_eq!(fs::read_dir(store.parent().unwrap()).unwrap().count(),1,"no temporary file remains");
    }

    #[test]
    fn saves_set_aside_follow_the_new_folder(){
        let root=Root::new();
        let old=root.0.join("old/demo");
        let new=root.0.join("new/demo");
        put(&root.0.join("old/.coco-kept-saves/demo/saves/a.dat"),b"mine");
        follow_kept_saves(&old,&new,"demo");
        assert_eq!(fs::read(root.0.join("new/.coco-kept-saves/demo/saves/a.dat")).unwrap(),b"mine");
    }
}
