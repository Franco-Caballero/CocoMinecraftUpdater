use crate::services::{catalog, inventory};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, ErrorKind};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, State};

#[derive(Default)]
pub struct VerifyState {
    active: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifyProgress {
    pub id: String,
    pub current: usize,
    pub total: usize,
    pub file: String,
    pub percent: u8,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerificationResult {
    pub id: String,
    pub status: &'static str,
    pub checked: usize,
    pub total: usize,
    pub first_issue: Option<String>,
}

pub(crate) fn safe_relative_path(value: &str) -> Option<&Path> {
    if value.contains('\\') || value.contains(':') { return None; }
    let path=Path::new(value);
    if value.is_empty() || !path.components().all(|c| matches!(c, Component::Normal(_))) { return None; }
    Some(path)
}

fn check_file(root: &Path, rel: &str, size: u64, hash: &str, cancelled: &AtomicBool,
              mut progress: impl FnMut(u64, u64)) -> Result<bool, String> {
    let sub=safe_relative_path(rel).ok_or("Ruta de archivo inválida")?;
    let path=root.join(sub);
    let metadata=match path.metadata(){
        Ok(value)=>value,
        Err(e) if e.kind()==ErrorKind::NotFound=>return Ok(false),
        Err(e)=>return Err(format!("No se puede leer {rel}: {e}")),
    };
    if !metadata.is_file() || metadata.len()!=size { return Ok(false); }
    // Do not follow a junction or symlink beyond this instance directory.
    let canonical_root=root.canonicalize().map_err(|e|format!("No se puede resolver la instancia: {e}"))?;
    let canonical_file=path.canonicalize().map_err(|e|format!("No se puede resolver el archivo: {e}"))?;
    if !canonical_file.starts_with(canonical_root) { return Err("Archivo fuera de la instancia".into()); }
    let mut input=File::open(&path).map_err(|e|format!("No se puede abrir {rel}: {e}"))?;
    let mut digest=Sha256::new();
    let mut buffer=[0_u8; 1024*1024];
    let mut read=0_u64;
    let mut last_report=0_u64;
    loop {
        if cancelled.load(Ordering::Relaxed) { return Err("cancelled".into()); }
        let n=input.read(&mut buffer).map_err(|e|format!("No se puede leer {rel}: {e}"))?;
        if n==0 { break; }
        read+=n as u64;
        digest.update(&buffer[..n]);
        if read-last_report>=16*1024*1024 || read==size {progress(read,size);last_report=read;}
    }
    if read!=size{return Ok(false);}
    Ok(format!("{:x}",digest.finalize())==hash.to_ascii_lowercase())
}

pub(crate) fn verify_entry(
    entry: &catalog::Experience,
    app_data: &Path,
    local_app_data: &Path,
    cancelled: &AtomicBool,
    mut on_progress: impl FnMut(VerifyProgress),
) -> Result<VerificationResult,String> {
    let result=|status,checked,first_issue|VerificationResult{
        id:entry.id.clone(),status,checked,total:entry.required_files.len(),first_issue,
    };
    if entry.workflow!="coco-standalone" {return Ok(result("unsupported",0,None));}
    if entry.required_files.is_empty(){return Ok(result("unsupported",0,None));}
    let locations=inventory::custom_locations(local_app_data)?;
    let root=inventory::resolve_instance_root(entry,app_data,&locations);
    if !root.is_absolute() || root.to_string_lossy().starts_with("\\\\") {
        return Ok(result("unknown",0,Some("Ubicación no accesible localmente".into())));
    }
    if !root.is_dir(){return Ok(result("missing",0,None));}
    let total=entry.required_files.len();
    let mut checked=0;
    for file in &entry.required_files {
        if cancelled.load(Ordering::Relaxed) {return Ok(result("cancelled",checked,None));}
        let current=checked+1;
        on_progress(VerifyProgress{id:entry.id.clone(),current,total,file:file.path.clone(),percent:0});
        // Online-Fix rewrites its ini with each PC's own hash: it only has to be there.
        let verified=if is_fix_settings(&file.path){
            Ok(safe_relative_path(&file.path).is_some_and(|relative|root.join(relative).is_file()))
        }else{check_file(&root,&file.path,file.size,&file.sha256,cancelled,|done,length|{
            on_progress(VerifyProgress{id:entry.id.clone(),current,total,file:file.path.clone(),
                percent:if length==0{100}else{((done as f64/length as f64)*100.0).min(100.0) as u8}});
        })};
        match verified {
            Ok(true)=>{checked+=1;}
            Ok(false)=>return Ok(result("mismatch",checked,Some(file.path.clone()))),
            Err(error) if error=="cancelled"=>return Ok(result("cancelled",checked,None)),
            Err(error)=>return Ok(result("error",checked,Some(error))),
        }
    }
    Ok(result("essential-files-verified",checked,None))
}

/// OnlineFix.ini: the fix writes into it on every PC, so its pinned bytes are only the host's.
pub(crate) fn is_fix_settings(path:&str)->bool{
    path.replace('\\',"/").rsplit('/').next().is_some_and(|name|name.eq_ignore_ascii_case("OnlineFix.ini"))
}

struct ActiveGuard { id:String, active:Arc<Mutex<HashMap<String,Arc<AtomicBool>>>> }
impl Drop for ActiveGuard {
    fn drop(&mut self) { if let Ok(mut jobs)=self.active.lock(){jobs.remove(&self.id);} }
}

#[tauri::command]
pub async fn verify_local_instance(id:String, app:AppHandle, state:State<'_,VerifyState>) -> Result<VerificationResult,String> {
    let entry=catalog::read_catalog()?.into_iter().find(|x|x.id==id).ok_or("Experiencia desconocida")?;
    let app_data=std::env::var_os("APPDATA").map(PathBuf::from).ok_or("APPDATA no disponible")?;
    let local_data=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or("LOCALAPPDATA no disponible")?;
    let active=Arc::clone(&state.active);
    let cancel=Arc::new(AtomicBool::new(false));
    {
        let mut jobs=active.lock().map_err(|_|"Bloqueo de verificación")?;
        if jobs.contains_key(&id) {return Err("Esta experiencia ya se está verificando".into());}
        jobs.insert(id.clone(),Arc::clone(&cancel));
    }
    let guard=ActiveGuard{id,active};
    let outcome=tauri::async_runtime::spawn_blocking(move||{
        let _guard=guard;
        verify_entry(&entry,&app_data,&local_data,&cancel,|progress|{
            let _=app.emit("coco2://verification-progress",progress);
        })
    }).await.map_err(|e|format!("Error de verificación: {e}"))?;
    outcome
}

#[tauri::command]
pub fn cancel_verification(id:String,state:State<'_,VerifyState>)->Result<bool,String>{
    let active=state.active.lock().map_err(|_|"Bloqueo de verificación")?;
    if let Some(token)=active.get(&id){token.store(true,Ordering::Relaxed);Ok(true)}else{Ok(false)}
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn verifies_real_bytes_and_refuses_tampering(){
        let root=std::env::temp_dir().join(format!("coco2-verify-{}",std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path=root.join("sample.bin");
        {let mut f=File::create(&path).unwrap();f.write_all(b"good bytes").unwrap();}
        let hash=format!("{:x}",Sha256::digest(b"good bytes"));
        let cancelled=AtomicBool::new(false);
        assert_eq!(check_file(&root,"sample.bin",10,&hash,&cancelled,|_,_|{}).unwrap(),true);
        assert_eq!(check_file(&root,"sample.bin",9,&hash,&cancelled,|_,_|{}).unwrap(),false);
        assert_eq!(check_file(&root,"sample.bin",10,&"0".repeat(64),&cancelled,|_,_|{}).unwrap(),false);
        assert!(safe_relative_path("../secret").is_none());
        assert!(safe_relative_path("C:/secrets").is_none());
        std::fs::remove_file(&path).unwrap();std::fs::remove_dir(&root).unwrap();
    }
}
