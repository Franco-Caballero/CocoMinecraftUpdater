//! Crash-recoverable replacement of *only* pinned, immutable standalone files.
//! The journal and backup live on the target volume. A crash before the durable
//! committed marker always means rollback; a crash after it means finish cleanup.
use super::*;

const TRANSACTION: &str = "repair-transaction-v1";
const CLEANUP: &str = "repair-cleanup-v1";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Fingerprint { size:u64, sha256:String }

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Change { path:String, old:Option<Fingerprint>, new:Fingerprint }

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Journal {
    schema:u8, id:String, instance_id:String, version:String,
    canonical_target:String, phase:String, changes:Vec<Change>,
    #[serde(default)] kind:String,
    #[serde(default)] from_version:String,
}

const UPGRADE_TRANSACTION:&str="upgrade-transaction-v1";
const RECEIPT:&str=".coco/standalone-install-v1.json";

fn protected_path(path:&str)->bool {
    path.replace('\\',"/").split('/').any(|part|matches!(part.to_ascii_lowercase().as_str(),
        ".coco"|"saves"|"playerdata"|"advancements"|"stats"|
        "config"|"configs"|"mods"|"plugins"|"bepinex"|"distanthorizons"|
        "distant_horizons"|"dh"|"shaderpacks"|"resourcepacks"))
}

fn fingerprint(path:&Path, token:&AtomicBool)->Result<Option<Fingerprint>,String>{
    assert_no_links(path)?;
    match fs::symlink_metadata(path){
        Err(e) if e.kind()==std::io::ErrorKind::NotFound=>return Ok(None),
        Err(e)=>return Err(e.to_string()),
        Ok(meta) if !meta.is_file()=>return Err(format!("Reparación rechazada: ruta que no es archivo: {}",path.display())),
        Ok(meta) if meta.len()>MAX_SINGLE_ENTRY_BYTES=>return Err("Archivo a reparar supera el límite seguro".into()),
        Ok(_)=>{},
    }
    // An exclusive share restriction fails while another Windows process holds
    // a writable/deletable handle. Preserve the read-only handle through hash.
    let mut options=OpenOptions::new();options.read(true);
    #[cfg(windows)]{
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1); // FILE_SHARE_READ, deny live writers and delete
    }
    let mut file=options.open(path).map_err(|_|"Archivo del juego bloqueado por otro proceso")?;
    let before=file.metadata().map_err(|e|e.to_string())?;
    let mut sha=Sha256::new();let mut len=0u64;let mut buf=[0u8;1024*1024];
    loop{
        cancelled(token)?;
        let n=file.read(&mut buf).map_err(|e|e.to_string())?;
        if n==0{break;}
        len=len.checked_add(n as u64).ok_or("Tamaño de archivo excedido")?;
        if len>MAX_SINGLE_ENTRY_BYTES{return Err("Archivo excede el límite seguro".into());}
        sha.update(&buf[..n]);
    }
    let after=file.metadata().map_err(|e|e.to_string())?;
    if len!=before.len()||len!=after.len()||before.modified().ok()!=after.modified().ok(){
        return Err("El archivo fue modificado durante la verificación".into());
    }
    Ok(Some(Fingerprint{size:len,sha256:format!("{:x}",sha.finalize())}))
}

fn pinned(file:&FileSpec)->Fingerprint {Fingerprint{size:file.size,sha256:file.sha256.to_ascii_lowercase()}}

fn journal_path(root:&Path)->PathBuf{root.join("journal.json")}
fn payload(root:&Path,index:usize)->PathBuf{root.join("payload").join(index.to_string())}
fn backup(root:&Path,index:usize)->PathBuf{root.join("backup").join(index.to_string())}
fn trash(root:&Path,index:usize)->PathBuf{root.join("trash").join(index.to_string())}

/// Windows std::fs::rename may replace an existing destination. During the
/// gap between verifying a live file and moving a staged one, another process
/// can create that destination. MoveFileExW without REPLACE_EXISTING fails in
/// that case; no user/foreign bytes are overwritten by a recovery race.
#[cfg(windows)]
fn move_no_replace(from:&Path,to:&Path)->Result<(),String>{
    use std::os::windows::ffi::OsStrExt;
    #[link(name="kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(from:*const u16,to:*const u16,flags:u32)->i32;
    }
    assert_no_links(from)?;assert_no_links(to)?;
    let absolute=|path:&Path|->Result<Vec<u16>,String>{
        let parent=path.parent().ok_or("Movimiento sin carpeta padre")?;
        let name=path.file_name().ok_or("Movimiento sin nombre de archivo")?;
        // canonicalize produces extended-length Windows paths, preserving
        // Unicode and keeping long paths valid for native UTF-16 Win32 calls.
        let full=fs::canonicalize(parent).map_err(|e|e.to_string())?.join(name);
        Ok(full.as_os_str().encode_wide().chain(Some(0)).collect())
    };
    let source=absolute(from)?;
    let destination=absolute(to)?;
    const MOVEFILE_WRITE_THROUGH:u32=0x0000_0008;
    if unsafe {MoveFileExW(source.as_ptr(),destination.as_ptr(),MOVEFILE_WRITE_THROUGH)}==0{
        let error=std::io::Error::last_os_error();
        return Err(format!("Movimiento sin reemplazo bloqueado (permiso, uso o destino ocupado): {error}"));
    }
    Ok(())
}

#[cfg(not(windows))]
fn move_no_replace(_from:&Path,_to:&Path)->Result<(),String>{
    Err("Movimientos transaccionales requieren Win32".into())
}

fn durable_copy(source:&Path,target:&Path,expected:&Fingerprint,token:&AtomicBool)->Result<(),String>{
    assert_no_links(source)?;assert_no_links(target)?;
    let mut options=OpenOptions::new(); options.read(true);
    #[cfg(windows)]{
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1);
    }
    let mut input=options.open(source).map_err(|_|"Origen en uso o inaccesible")?;
    let mut output=OpenOptions::new().create_new(true).write(true).open(target)
        .map_err(|e|format!("No se pudo reservar respaldo: {e}"))?;
    let mut hasher=Sha256::new();let mut copied=0u64;let mut buffer=[0u8;1024*1024];
    loop{
        cancelled(token)?;
        let n=input.read(&mut buffer).map_err(|e|e.to_string())?;
        if n==0{break;}
        copied=copied.checked_add(n as u64).ok_or("Copia excede el máximo")?;
        if copied>expected.size{return Err("Origen cambió mientras se copiaba".into());}
        output.write_all(&buffer[..n]).map_err(|e|e.to_string())?;
        hasher.update(&buffer[..n]);
    }
    output.sync_all().map_err(|e|e.to_string())?;
    let found=Fingerprint{size:copied,sha256:format!("{:x}",hasher.finalize())};
    if found!=*expected{return Err("Origen no corresponde al SHA-256 verificado".into());}
    Ok(())
}

fn write_journal(root:&Path,journal:&Journal,replace:bool)->Result<(),String>{
    let bytes=serde_json::to_vec(journal).map_err(|e|e.to_string())?;
    if bytes.len()>1024*1024{return Err("Journal excede el límite".into());}
    let stage=root.join("journal.new");assert_no_links(&stage)?;
    let mut file=OpenOptions::new().create_new(true).write(true).open(&stage)
        .map_err(|e|format!("Journal ocupado o ajeno: {e}"))?;
    file.write_all(&bytes).and_then(|_|file.sync_all()).map_err(|e|e.to_string())?;
    drop(file);
    let destination=journal_path(root);
    if !replace && destination.exists(){return Err("Journal ya existe".into());}
    fs::rename(&stage,&destination).map_err(|e|format!("No se pudo persistir journal: {e}"))
}

fn load_journal(m:&Manifest,target:&Path,root:&Path)->Result<Journal,String>{
    let path=journal_path(root);assert_no_links(&path)?;
    if fs::metadata(&path).map_err(|e|e.to_string())?.len()>1024*1024{return Err("Journal demasiado grande".into());}
    let journal:Journal=serde_json::from_slice(&fs::read(&path).map_err(|e|e.to_string())?)
        .map_err(|_|"Journal corrupto; conservar respaldos para inspección")?;
    let canonical=fs::canonicalize(target).map_err(|e|e.to_string())?;
    if journal.schema!=1||journal.id!=m.id||journal.instance_id!=m.instance_id||journal.version!=m.version
        ||journal.canonical_target!=canonical.to_string_lossy()
        ||!matches!(journal.phase.as_str(),"rolling"|"committed")
        ||journal.changes.is_empty()||journal.changes.len()>100_000 {
        return Err("Journal no corresponde a esta instancia/version".into());
    }
    let mut paths=HashSet::new();
    for (idx,change) in journal.changes.iter().enumerate(){
        let receipt=journal.kind=="upgrade"&&idx+1==journal.changes.len()&&change.path==RECEIPT;
        let path=if receipt{RECEIPT.to_string()}else{normal_path(&change.path)?};
        if path!=change.path||(!receipt&&protected_path(&path))||!paths.insert(path.to_ascii_lowercase())
            ||!valid_hash(&change.new.sha256)||change.new.size==0
            ||change.old.as_ref().is_some_and(|old|!valid_hash(&old.sha256)) {
            return Err("Journal contiene rutas o hashes inseguros".into());
        }
        // Backup must remain available even if a crash occurs just after rename.
        let saved=backup(root,idx);
        if let Some(expected)=&change.old{
            if fingerprint(&saved,&AtomicBool::new(false))?.as_ref()!=Some(expected){
                return Err("Respaldo ausente o modificado; recuperación retenida".into());
            }
        }
    }
    Ok(journal)
}

#[cfg(windows)]
fn acquire_lock(target:&Path)->Result<File,String>{
    use std::os::windows::fs::OpenOptionsExt;
    let lock=target.join(".coco").join("repair.lock");assert_no_links(&lock)?;
    OpenOptions::new().read(true).write(true).create(true).share_mode(0).open(lock)
        .map_err(|_|"Otra reparación está activa o no se puede bloquear la instancia".into())
}
#[cfg(not(windows))]
fn acquire_lock(target:&Path)->Result<File,String>{
    // Actual repair commits target Windows; no portable advisory exclusion here.
    let _=target;Err("La reparación transaccional requiere bloqueo nativo de Windows".into())
}

fn clean_transaction(target:&Path,root:&Path)->Result<(),String>{
    let cleanup=target.join(".coco").join(CLEANUP);
    assert_no_links(root)?;assert_no_links(&cleanup)?;
    if cleanup.exists(){finish_cleanup(target)?;}
    let data=fs::read(journal_path(root)).map_err(|e|e.to_string())?;
    let journal:Journal=serde_json::from_slice(&data).map_err(|_|"Journal finalizado inválido")?;
    if journal.schema!=1 || !valid_id(&journal.id)
        || journal.canonical_target!=fs::canonicalize(target).map_err(|e|e.to_string())?.to_string_lossy(){
        return Err("Identidad de journal finalizado no coincide".into());
    }
    let marker=root.join("cleanup-marker.json");assert_no_links(&marker)?;
    if marker.exists(){
        if fs::read(&marker).map_err(|e|e.to_string())? !=data {
            return Err("Marcador de limpieza anterior no coincide".into());
        }
    }else{
        let mut f=OpenOptions::new().write(true).create_new(true).open(&marker)
            .map_err(|e|e.to_string())?;
        f.write_all(&data).and_then(|_|f.sync_all()).map_err(|e|e.to_string())?;
    }
    fs::rename(root,&cleanup).map_err(|e|format!("No se pudo archivar journal finalizado: {e}"))?;
    finish_cleanup(target)
}

fn finish_cleanup(target:&Path)->Result<(),String>{
    let cleanup=target.join(".coco").join(CLEANUP);
    assert_no_links(&cleanup)?;
    if !cleanup.exists(){return Ok(());}
    let marker=cleanup.join("cleanup-marker.json");
    assert_no_links(&marker)?;
    if !marker.exists(){
        if fs::read_dir(&cleanup).map_err(|e|e.to_string())?.next().is_none(){
            return fs::remove_dir(&cleanup).map_err(|e|e.to_string());
        }
        return Err("Limpieza incompleta sin marcador auténtico; conservar para revisión".into());
    }
    if fs::metadata(&marker).map_err(|e|e.to_string())?.len()>1024*1024 {
        return Err("Marcador de limpieza excesivo".into());
    }
    let data=fs::read(&marker).map_err(|e|e.to_string())?;
    let journal:Journal=serde_json::from_slice(&data)
        .map_err(|_|"Marcador de limpieza corrupto; no borrar")?;
    if journal.schema!=1||!valid_id(&journal.id)||journal.changes.is_empty()
        ||journal.changes.len()>100_000
        ||journal.canonical_target!=fs::canonicalize(target).map_err(|e|e.to_string())?.to_string_lossy()
        ||!matches!(journal.phase.as_str(),"rolling"|"committed") {
        return Err("Marcador de limpieza no pertenece a esta instancia".into());
    }
    let allowed=["payload","backup","trash","discard","recovery","journal.json","journal.new","cleanup-marker.json"];
    for entry in fs::read_dir(&cleanup).map_err(|e|e.to_string())?{
        let entry=entry.map_err(|e|e.to_string())?;
        let name=entry.file_name().to_string_lossy().to_string();
        if !allowed.contains(&name.as_str()){return Err("Carpeta de limpieza contiene archivo ajeno".into());}
        assert_no_links(&entry.path())?;
    }
    // Validate all artifacts before removing any; only indices and bytes from
    // the journal are eligible. Unknown files are never recursively deleted.
    for folder in ["payload","backup","trash","discard","recovery"]{
        let dir=cleanup.join(folder);assert_no_links(&dir)?;
        if !dir.exists(){continue;}
        if !dir.is_dir(){return Err("Carpeta de limpieza es un archivo ajeno".into());}
        for item in fs::read_dir(&dir).map_err(|e|e.to_string())?{
            let item=item.map_err(|e|e.to_string())?;
            let filename=item.file_name().to_string_lossy().to_string();
            let index=filename.parse::<usize>().map_err(|_|"Archivo inesperado en limpieza")?;
            if filename!=index.to_string(){return Err("Índice de limpieza no canónico".into());}
            let change=journal.changes.get(index).ok_or("Índice de limpieza fuera de journal")?;
            let expected=if matches!(folder,"payload"|"discard"){Some(&change.new)}else{change.old.as_ref()};
            if fingerprint(&item.path(),&AtomicBool::new(false))?.as_ref()!=expected {
                return Err("Artefacto de limpieza modificado; se conserva".into());
            }
        }
    }
    for file in ["journal.json","journal.new"]{
        let path=cleanup.join(file);assert_no_links(&path)?;
        if path.exists(){
            if file=="journal.json"&&fs::read(&path).map_err(|e|e.to_string())?!=data{
                return Err("Journal y marcador discrepan durante limpieza".into());
            }
            if file=="journal.new"{
                let staged:Journal=serde_json::from_slice(&fs::read(&path).map_err(|e|e.to_string())?)
                    .map_err(|_|"Journal auxiliar ilegible durante limpieza")?;
                if staged.id!=journal.id||staged.changes!=journal.changes{
                    return Err("Journal auxiliar ajeno durante limpieza".into());
                }
            }
        }
    }
    for folder in ["payload","backup","trash","discard","recovery"]{
        let dir=cleanup.join(folder);
        if !dir.exists(){continue;}
        for entry in fs::read_dir(&dir).map_err(|e|e.to_string())?{
            let entry=entry.map_err(|e|e.to_string())?;
            assert_no_links(&entry.path())?;
            fs::remove_file(entry.path()).map_err(|e|e.to_string())?;
        }
        fs::remove_dir(dir).map_err(|e|e.to_string())?;
    }
    for file in ["journal.new","journal.json"]{
        let file=cleanup.join(file);
        if file.exists(){fs::remove_file(file).map_err(|e|e.to_string())?;}
    }
    fs::remove_file(marker).map_err(|e|e.to_string())?;
    fs::remove_dir(cleanup).map_err(|e|e.to_string())?;
    Ok(())
}

fn restore(m:&Manifest,target:&Path,root:&Path,guard:&dyn Fn()->Result<(),String>,
           progress:&mut dyn FnMut(&'static str,&str,u64,u64))->Result<&'static str,String>{
    let journal=load_journal(m,target,root)?;
    // Validate ALL live paths and backups before touching one live byte.
    let mut current=Vec::new();
    for (index,change) in journal.changes.iter().enumerate() {
        let observed=fingerprint(&target.join(&change.path),&AtomicBool::new(false))?;
        if observed.is_some() && observed.as_ref()!=change.old.as_ref()&&observed.as_ref()!=Some(&change.new){
            return Err("Archivo modificado por tercero durante reparación; se conservan respaldos".into());
        }
        let temp=root.join("recovery").join(index.to_string());
        let saved=fingerprint(&temp,&AtomicBool::new(false))?;
        if saved.is_some() && saved.as_ref()!=change.old.as_ref(){
            return Err("Copia temporal de rollback modificada o ajena; conservar journal".into());
        }
        current.push(observed);
    }
    if journal.phase=="committed" {
        if current.iter().zip(&journal.changes).any(|(have,change)|have.as_ref()!=Some(&change.new)){
            return Err("Commit finalizado, pero archivos ya cambiaron: conservar journal".into());
        }
        clean_transaction(target,root)?;
        return Ok("recovery-complete");
    }
    for index in (0..journal.changes.len()).rev(){
        guard()?;
        let change=&journal.changes[index];
        let live=target.join(&change.path);
        let observed=fingerprint(&live,&AtomicBool::new(false))?;
        if observed.as_ref()==change.old.as_ref(){continue;}
        if observed.is_some() && observed.as_ref()!=Some(&change.new){return Err("Cambio inesperado durante rollback".into());}
        if observed.is_some(){
            let discard=root.join("discard").join(index.to_string());
            assert_no_links(&discard)?;
            if discard.exists(){return Err("Rollback anterior tiene archivo desconocido".into());}
            move_no_replace(&live,&discard)
                .map_err(|e|format!("No se pudo retirar archivo reparado: {e}"))?;
        }
        if let Some(previous)=&change.old {
            let temp=root.join("recovery").join(index.to_string());
            if !temp.exists() {
                durable_copy(&backup(root,index),&temp,previous,&AtomicBool::new(false))?;
            } else if fingerprint(&temp,&AtomicBool::new(false))?.as_ref()!=Some(previous){
                return Err("Copia temporal de rollback no coincide con SHA-256".into());
            }
            if let Some(parent)=live.parent(){fs::create_dir_all(parent).map_err(|e|e.to_string())?;assert_no_links(parent)?;}
            move_no_replace(&temp,&live)
                .map_err(|e|format!("No se pudo restaurar original: {e}"))?;
        }
        progress(if journal.kind=="upgrade"{"upgrade-rollback"}else{"repair-rollback"},
            &change.path,(journal.changes.len()-index) as u64,journal.changes.len() as u64);
    }
    for change in &journal.changes{
        if fingerprint(&target.join(&change.path),&AtomicBool::new(false))?.as_ref()!=change.old.as_ref(){
            return Err("Rollback incompleto: journal preservado".into());
        }
    }
    clean_transaction(target,root)?;
    Ok("recovery-complete")
}

pub(super) fn recover(m:&Manifest,target:&Path,guard:&dyn Fn()->Result<(),String>,
              progress:&mut dyn FnMut(&'static str,&str,u64,u64))->Result<&'static str,String>{
    assert_no_links(target)?;
    if !target.is_dir(){return Err("Instancia de reparación ausente".into());}
    if inspect_receipt(m,target)!="matching"{return Err("Recibo Coco2 no coincide; recuperación protegida".into());}
    let _lock=acquire_lock(target)?;
    guard()?;
    let root=target.join(".coco").join(TRANSACTION);assert_no_links(&root)?;
    if root.exists(){return restore(m,target,&root,guard,progress);}
    finish_cleanup(target)?;
    Ok("no-recovery-needed")
}

fn collect_changes(m:&Manifest,target:&Path,stage:&Path,token:&AtomicBool)->Result<Vec<Change>,String>{
    if inspect_receipt(m,target)!="matching"{return Err("Reparación requiere recibo Coco2 vigente y coincidente".into());}
    let mut expected=m.required_files.clone();
    if !m.extra_files.is_empty(){expected.extend(recorded_immutable_extras(target)?);}
    let mut seen=HashMap::<String,Fingerprint>::new();let mut changes=Vec::new();
    for file in &expected{
        cancelled(token)?;
        let relative=normal_path(&file.path)?;
        let new=pinned(file);
        if let Some(previous)=seen.insert(relative.to_lowercase(),new.clone()){
            if previous!=new{return Err("Archivo con hashes discordantes entre manifiestos".into());}
            continue;
        }
        let live=target.join(&relative);
        let old=fingerprint(&live,token)?;
        if old.as_ref()==Some(&new){continue;}
        if protected_path(&relative){return Err(format!("Archivo protegido por el usuario requiere revisión: {relative}"));}
        let source=stage.join(&relative);
        if fingerprint(&source,token)?.as_ref()!=Some(&new){
            return Err(format!("El staging no contiene SHA verificado: {relative}"));
        }
        changes.push(Change{path:relative,old,new});
    }
    changes.sort_by(|a,b|a.path.cmp(&b.path));
    Ok(changes)
}

fn apply_changes(target:&Path,root:&Path,journal:&Journal,
                 guard:&dyn Fn()->Result<(),String>,progress:&mut dyn FnMut(&'static str,&str,u64,u64),
                 interrupt_after:Option<usize>)->Result<(),String>{
    for (i,change) in journal.changes.iter().enumerate(){
        guard()?;
        let path=target.join(&change.path);
        assert_no_links(&path)?;
        if fingerprint(&path,&AtomicBool::new(false))?!=change.old {
            return Err("El archivo cambió desde la preparación; cancelar y recuperar".into());
        }
        let parent=path.parent().ok_or("Ruta sin carpeta padre")?;
        fs::create_dir_all(parent).map_err(|e|e.to_string())?;
        assert_no_links(parent)?;
        if change.old.is_some(){move_no_replace(&path,&trash(root,i))
            .map_err(|e|format!("Archivo bloqueado al retirar original: {e}"))?;}
        move_no_replace(&payload(root,i),&path)
            .map_err(|e|format!("No se pudo instalar componente verificado: {e}"))?;
        progress(if journal.kind=="upgrade"{"upgrade-committing"}else{"repair-committing"},
            &change.path,(i+1) as u64,journal.changes.len() as u64);
        #[cfg(test)]
        TEST_CRASH_AFTER_CHANGE.with(|slot|{
            if slot.get()==Some(i+1){panic!("synthetic Windows crash during journaled commit");}
        });
        if interrupt_after==Some(i+1){return Err("Simulated interrupted commit".into());}
    }
    for change in &journal.changes{
        if fingerprint(&target.join(&change.path),&AtomicBool::new(false))?.as_ref()!=Some(&change.new){
            return Err("SHA-256 posterior al commit no coincide".into());
        }
    }
    Ok(())
}

#[cfg(test)]
std::thread_local!{
    static TEST_CRASH_AFTER_CHANGE:std::cell::Cell<Option<usize>>=const {std::cell::Cell::new(None)};
}

#[cfg(test)]
pub(super) fn test_with_crash_after_change<T>(index:usize,f:impl FnOnce()->T)->T{
    TEST_CRASH_AFTER_CHANGE.with(|slot|slot.set(Some(index)));
    struct Reset;
    impl Drop for Reset{fn drop(&mut self){TEST_CRASH_AFTER_CHANGE.with(|slot|slot.set(None));}}
    let _reset=Reset;
    f()
}

pub(super) fn commit(m:&Manifest,target:&Path,stage:&Path,token:&AtomicBool,
             guard:&dyn Fn()->Result<(),String>,progress:&mut dyn FnMut(&'static str,&str,u64,u64))
    ->Result<&'static str,String>{
    cancelled(token)?;guard()?;assert_no_links(target)?;
    let _lock=acquire_lock(target)?;
    finish_cleanup(target)?;
    let root=target.join(".coco").join(TRANSACTION);assert_no_links(&root)?;
    if root.exists(){return Err("Existe reparación interrumpida; ejecutar recuperación primero".into());}
    let changes=collect_changes(m,target,stage,token)?;
    if changes.is_empty(){return Ok("already-verified");}
    let bytes=changes.iter().try_fold(0u64,|sum,c|{
        sum.checked_add(c.new.size)?.checked_add(c.old.as_ref().map_or(0,|old|old.size))
    }).ok_or("Tamaño de reparación excedido")?;
    ensure_free_space(target,bytes)?;
    fs::create_dir(&root).map_err(|e|format!("No se pudo reservar journal: {e}"))?;
    let prepared=(||->Result<Journal,String>{
        for folder in ["payload","backup","trash","discard","recovery"]{
            fs::create_dir(root.join(folder)).map_err(|e|e.to_string())?;
        }
        for (idx,change) in changes.iter().enumerate(){
            cancelled(token)?;guard()?;
            durable_copy(&stage.join(&change.path),&payload(&root,idx),&change.new,token)?;
            if let Some(old)=&change.old {
                durable_copy(&target.join(&change.path),&backup(&root,idx),old,token)?;
            }
            if fingerprint(&target.join(&change.path),token)?!=change.old {
                return Err("Archivos originales cambiaron durante staging".into());
            }
            progress("repair-commit-preflight",&change.path,(idx+1) as u64,changes.len() as u64);
        }
        Ok(Journal{schema:1,id:m.id.clone(),instance_id:m.instance_id.clone(),
            version:m.version.clone(),canonical_target:fs::canonicalize(target)
                .map_err(|e|e.to_string())?.to_string_lossy().to_string(),
            phase:"rolling".into(),changes,kind:String::new(),from_version:String::new()})
    })();
    let journal=match prepared{
        Ok(journal)=>journal,
        Err(e)=>{let _=fs::remove_dir_all(&root);return Err(e);}
    };
    if let Err(e)=write_journal(&root,&journal,false){
        // Even a failed journal write may have left a durable journal. Keep it
        // if so; otherwise the temporary area contains no changed live bytes.
        if !journal_path(&root).exists(){let _=fs::remove_dir_all(&root);}
        return Err(e);
    }
    // Cancellation is now deferred until all files commit or rollback. A
    // request to cancel while applying never abandons a half-written instance.
    let mut result=apply_changes(target,&root,&journal,guard,progress,None);
    if result.is_ok(){
        let mut committed=journal.clone();committed.phase="committed".into();
        result=write_journal(&root,&committed,true);
    }
    match result{
        Ok(())=>{clean_transaction(target,&root)?;progress("repair-completed","",1,1);Ok("repaired")},
        Err(cause)=>{
            let rollback=restore(m,target,&root,guard,progress);
            match rollback{
                Ok(_)=>Err(format!("Reparación revertida: {cause}")),
                Err(why)=>Err(format!("Reparación pendiente de recuperación: {cause}; {why}")),
            }
        }
    }
}

/// Authenticated A -> B upgrade. Only an old path independently pinned by the
/// trusted A manifest may be replaced; a newly introduced path MUST be absent.
/// The receipt is the last journaled change and is rolled back together with
/// the executable/assets if a crash occurs before the committed journal marker.
pub(super) fn upgrade(old:&Manifest,new:&Manifest,target:&Path,stage:&Path,
    new_extras:&[FileSpec],token:&AtomicBool,guard:&dyn Fn()->Result<(),String>,
    progress:&mut dyn FnMut(&'static str,&str,u64,u64))->Result<&'static str,String>{
    cancelled(token)?;guard()?;assert_no_links(target)?;
    if old.id!=new.id||old.instance_id!=new.instance_id||old.version==new.version{
        return Err("El upgrade exige identidad estable y versiones diferentes".into());
    }
    let _lock=acquire_lock(target)?;
    finish_cleanup(target)?;
    let repair=target.join(".coco").join(TRANSACTION);
    let root=target.join(".coco").join(UPGRADE_TRANSACTION);
    assert_no_links(&repair)?;assert_no_links(&root)?;
    if repair.exists()||root.exists(){return Err("Existe journal pendiente, recuperar antes de actualizar".into());}
    // The caller supplies A from trusted signed history/embedded manifest,
    // not from the receipt. Recheck the on-disk receipt under the exclusive lock.
    validate_receipt_baseline(old,&read_owned_receipt(target)?)?;
    let mut allowed_old=HashMap::new();
    for file in &old.required_files{
        allowed_old.insert(normal_path(&file.path)?.to_ascii_lowercase(),pinned(file));
    }
    // An immutable extra can be replaced only if it is explicitly pinned by
    // A's trusted requiredFiles. User-editable mods/config are never touched.
    let mut desired=HashMap::<String,FileSpec>::new();
    for file in new.required_files.iter().chain(new_extras.iter()){
        let path=normal_path(&file.path)?;
        if let Some(previous)=desired.insert(path.to_ascii_lowercase(),file.clone()){
            if pinned(&previous)!=pinned(file)||previous.path!=file.path{
                return Err("Conflicto de rutas de archivos del upgrade".into());
            }
        }
    }
    let mut files=desired.into_values().collect::<Vec<_>>();
    files.sort_by(|a,b|a.path.cmp(&b.path));
    let mut changes=Vec::new();
    for file in files{
        cancelled(token)?;
        let path=normal_path(&file.path)?;
        let desired=pinned(&file);
        let current=fingerprint(&target.join(&path),token)?;
        if current.as_ref()==Some(&desired){continue;}
        if protected_path(&path){
            return Err(format!("El upgrade no reemplaza archivos de usuario: {path}"));
        }
        let old_pinned=allowed_old.get(&path.to_ascii_lowercase());
        if let Some(actual)=current.as_ref(){
            match old_pinned{
                None=>return Err(format!("Archivo previo no pertenece al manifiesto antiguo: {path}")),
                Some(baseline) if actual!=baseline=>return Err(format!(
                    "Archivo de versión anterior fue modificado o está corrupto: {path}; reparar A antes de actualizar")),
                _=>{},
            }
        }
        if fingerprint(&stage.join(&path),token)?.as_ref()!=Some(&desired){
            return Err(format!("Staging no coincide con SHA-256 del manifiesto B: {path}"));
        }
        changes.push(Change{path,old:current,new:desired});
    }
    let old_receipt=fingerprint(&target.join(RECEIPT),token)?.ok_or("Recibo original ausente")?;
    let new_receipt=fingerprint(&stage.join(RECEIPT),token)?.ok_or("Recibo B no preparado")?;
    if old_receipt==new_receipt{return Err("No se puede actualizar sin cambiar recibo de versión".into());}
    changes.push(Change{path:RECEIPT.into(),old:Some(old_receipt),new:new_receipt});
    let bytes=changes.iter().try_fold(0u64,|sum,c|{
        sum.checked_add(c.new.size)?.checked_add(c.old.as_ref().map_or(0,|old|old.size))
    }).ok_or("Upgrade demasiado grande")?;
    ensure_free_space(target,bytes)?;
    fs::create_dir(&root).map_err(|e|format!("Journal upgrade no disponible: {e}"))?;
    let prepared=(||->Result<Journal,String>{
        for folder in ["payload","backup","trash","discard","recovery"]{
            fs::create_dir(root.join(folder)).map_err(|e|e.to_string())?;
        }
        for (index,change) in changes.iter().enumerate(){
            cancelled(token)?;guard()?;
            durable_copy(&stage.join(&change.path),&payload(&root,index),&change.new,token)?;
            if let Some(previous)=&change.old{
                durable_copy(&target.join(&change.path),&backup(&root,index),previous,token)?;
            }
            if fingerprint(&target.join(&change.path),token)?!=change.old{
                return Err("Un archivo cambió mientras se preparaba journal upgrade".into());
            }
            progress("upgrade-preflight",&change.path,(index+1) as u64,changes.len() as u64);
        }
        Ok(Journal{schema:1,id:new.id.clone(),instance_id:new.instance_id.clone(),
            version:new.version.clone(),canonical_target:fs::canonicalize(target).map_err(|e|e.to_string())?
                .to_string_lossy().to_string(),phase:"rolling".into(),changes,
            kind:"upgrade".into(),from_version:old.version.clone()})
    })();
    let journal=match prepared{
        Ok(journal)=>journal,
        Err(e)=>{let _=fs::remove_dir_all(&root);return Err(e);}
    };
    if let Err(e)=write_journal(&root,&journal,false){
        if !journal_path(&root).exists(){let _=fs::remove_dir_all(&root);}
        return Err(e);
    }
    // Commit must finish, or rollback; cancellation is deferred past journal.
    let mut result=apply_changes(target,&root,&journal,guard,progress,None);
    if result.is_ok(){
        let mut committed=journal.clone();committed.phase="committed".into();
        result=write_journal(&root,&committed,true);
    }
    match result{
        Ok(())=>{
            clean_transaction(target,&root)?;
            progress("upgrade-completed","",1,1);
            Ok("upgraded")
        },
        Err(cause)=>{
            match restore(new,target,&root,guard,progress){
                Ok(_)=>Err(format!("Upgrade revertido con recibo original: {cause}")),
                Err(why)=>Err(format!("Upgrade pendiente de recuperación: {cause}; {why}")),
            }
        }
    }
}

pub(super) fn recover_upgrade(new:&Manifest,target:&Path,guard:&dyn Fn()->Result<(),String>,
    progress:&mut dyn FnMut(&'static str,&str,u64,u64))->Result<&'static str,String>{
    assert_no_links(target)?;
    if !target.is_dir(){return Err("Instancia no encontrada".into());}
    let _lock=acquire_lock(target)?;
    guard()?;
    let root=target.join(".coco").join(UPGRADE_TRANSACTION);
    assert_no_links(&root)?;
    if !root.exists(){finish_cleanup(target)?;return Ok("no-recovery-needed");}
    let journal=load_journal(new,target,&root)?;
    if journal.kind!="upgrade"||journal.from_version==journal.version
        ||journal.changes.last().is_none_or(|change|change.path!=RECEIPT){
        return Err("Journal no corresponde a upgrade A->B".into());
    }
    let old=trusted_manifest_version(&new.id,&journal.from_version)?
        .ok_or("Manifest A ya no está en historial confiable; restauración bloqueada")?;
    let receipt_index=journal.changes.len()-1;
    let old_receipt:serde_json::Value=serde_json::from_slice(&fs::read(backup(&root,receipt_index))
        .map_err(|e|e.to_string())?).map_err(|_|"Recibo respaldado ilegible")?;
    validate_receipt_baseline(&old,&old_receipt)?;
    restore(new,target,&root,guard,progress)
}

pub(super) fn upgrade_recovery_versions(target:&Path)->Result<Option<(String,String)>,String>{
    assert_no_links(target)?;
    let root=target.join(".coco").join(UPGRADE_TRANSACTION);
    assert_no_links(&root)?;
    if !root.exists(){return Ok(None);}
    let path=journal_path(&root);assert_no_links(&path)?;
    let meta=fs::metadata(&path).map_err(|e|e.to_string())?;
    if !meta.is_file()||meta.len()>1024*1024{return Err("Journal de upgrade ilegible o excesivo".into());}
    let journal:Journal=serde_json::from_slice(&fs::read(path).map_err(|e|e.to_string())?)
        .map_err(|_|"Journal de upgrade inválido")?;
    if journal.schema!=1||journal.kind!="upgrade"||journal.changes.is_empty()
        ||journal.canonical_target!=fs::canonicalize(target).map_err(|e|e.to_string())?.to_string_lossy(){
        return Err("Journal de upgrade pertenece a otra instancia".into());
    }
    Ok(Some((journal.from_version,journal.version)))
}

/// Startup probe reads only a journal under a caller-supplied, already
/// recognized Coco instance. It NEVER restores or removes any content.
pub(super) fn inspect_pending(target:&Path,id:&str,instance_id:&str)
    ->Result<Vec<(&'static str,String,String,String)>,String>{
    assert_no_links(target)?;
    if !target.is_dir(){return Ok(Vec::new());}
    let base=target.join(".coco");assert_no_links(&base)?;
    let mut found=Vec::new();
    for (dir,kind) in [(TRANSACTION,"repair"),(UPGRADE_TRANSACTION,"upgrade")]{
        let root=base.join(dir);assert_no_links(&root)?;
        if !root.exists(){continue;}
        let path=journal_path(&root);assert_no_links(&path)?;
        let meta=fs::symlink_metadata(&path).map_err(|_|"Journal pendiente ausente o ilegible")?;
        if !meta.is_file()||meta.len()>1024*1024{return Err("Journal pendiente inseguro".into());}
        let journal:Journal=serde_json::from_slice(&fs::read(path).map_err(|e|e.to_string())?)
            .map_err(|_|"Journal pendiente corrupto")?;
        if journal.schema!=1||journal.id!=id||journal.instance_id!=instance_id
            ||journal.canonical_target!=fs::canonicalize(target).map_err(|e|e.to_string())?.to_string_lossy()
            ||!matches!(journal.phase.as_str(),"rolling"|"committed")
            ||journal.changes.is_empty()||journal.changes.len()>100_000
            ||(kind=="upgrade")!=(journal.kind=="upgrade"){
            return Err("Journal de otra instancia o sin procedencia".into());
        }
        let mut seen=HashSet::new();
        for (index,change) in journal.changes.iter().enumerate(){
            let receipt=kind=="upgrade"&&index==journal.changes.len()-1&&change.path==RECEIPT;
            let rel=if receipt{RECEIPT.into()}else{normal_path(&change.path)?};
            if rel!=change.path||(!receipt&&protected_path(&rel))||!seen.insert(rel.to_lowercase())
                ||!valid_hash(&change.new.sha256)||change.new.size==0
                ||change.old.as_ref().is_some_and(|f|!valid_hash(&f.sha256)){
                return Err("Journal tiene rutas o firmas inválidas".into());
            }
        }
        if kind=="upgrade"&&(journal.from_version.is_empty()||journal.from_version==journal.version
            ||journal.changes.last().is_none_or(|c|c.path!=RECEIPT)){
            return Err("Journal de versión B incompleto".into());
        }
        found.push((kind,journal.phase,journal.from_version,journal.version));
    }
    let cleanup=base.join(CLEANUP);assert_no_links(&cleanup)?;
    if cleanup.exists(){
        let path=cleanup.join("cleanup-marker.json");assert_no_links(&path)?;
        let bytes=fs::read(&path).map_err(|_|"Marcador de limpieza ausente; inspección requerida")?;
        if bytes.len()>1024*1024{return Err("Marcador de limpieza excesivo".into());}
        let journal:Journal=serde_json::from_slice(&bytes).map_err(|_|"Marcador de limpieza corrupto")?;
        if journal.schema!=1||journal.id!=id||journal.instance_id!=instance_id
            ||journal.canonical_target!=fs::canonicalize(target).map_err(|e|e.to_string())?.to_string_lossy(){
            return Err("Marcador de limpieza ajeno".into());
        }
        found.push(("cleanup",journal.phase,journal.from_version,journal.version));
    }
    Ok(found)
}

#[cfg(all(test,windows))]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize,Ordering as AtomOrdering};
    static SERIAL:AtomicUsize=AtomicUsize::new(0);

    struct Fixture{root:PathBuf,live:PathBuf,stage:PathBuf,m:Manifest}
    impl Drop for Fixture{fn drop(&mut self){let _=fs::remove_dir_all(&self.root);}}
    fn spec(path:&str,bytes:&[u8])->FileSpec{
        FileSpec{path:path.into(),size:bytes.len() as u64,sha256:format!("{:x}",Sha256::digest(bytes))}
    }
    fn fixture(files:&[(&str,&[u8],Option<&[u8]>)])->Fixture{
        let n=SERIAL.fetch_add(1,AtomOrdering::Relaxed);
        let root=std::env::temp_dir().join(format!("coco2-repair-tx-{}-{}-{n}",
            std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        let live=root.join("installed");let stage=root.join("stage");
        fs::create_dir_all(live.join(".coco")).unwrap();fs::create_dir_all(&stage).unwrap();
        let mut pinned=Vec::new();
        for (name,new,old) in files {
            let destination=stage.join(name);
            fs::create_dir_all(destination.parent().unwrap()).unwrap();
            fs::write(destination,new).unwrap();
            if let Some(old)=old {
                let original=live.join(name);
                fs::create_dir_all(original.parent().unwrap()).unwrap();
                fs::write(original,old).unwrap();
            }
            pinned.push(spec(name,new));
        }
        let m=Manifest{
            id:"fixture-game".into(),instance_id:"fixture-game".into(),workflow:"coco-standalone".into(),
            version:"1".into(),archives:vec![ArchiveSpec{url:"file:///fixture.zip".into(),
                sha256:"a".repeat(64),size:1}],required_files:pinned,executable:"game.exe".into(),
            files:vec![],extras:vec![],extra_files:vec![],has_extras:false,
        };
        let receipt=serde_json::json!({"schemaVersion":1,"complete":true,
            "type":"coco2-standalone-install","id":m.id,"instanceId":m.instance_id,
            "workflow":m.workflow,"version":m.version,"archiveShas":[m.archives[0].sha256],
            "requiredFiles":m.required_files});
        fs::write(live.join(".coco/standalone-install-v1.json"),receipt.to_string()).unwrap();
        Fixture{root,live,stage,m}
    }
    fn guard()->Result<(),String>{Ok(())}
    fn noop(_: &'static str,_:&str,_:u64,_:u64){}
    fn unfinished(f:&Fixture)->(PathBuf,Journal){
        let changes=collect_changes(&f.m,&f.live,&f.stage,&AtomicBool::new(false)).unwrap();
        let root=f.live.join(".coco").join(TRANSACTION);
        for folder in ["payload","backup","trash","discard","recovery"]{
            fs::create_dir_all(root.join(folder)).unwrap();
        }
        for (i,change) in changes.iter().enumerate(){
            durable_copy(&f.stage.join(&change.path),&payload(&root,i),&change.new,&AtomicBool::new(false)).unwrap();
            if let Some(old)=&change.old {
                durable_copy(&f.live.join(&change.path),&backup(&root,i),old,&AtomicBool::new(false)).unwrap();
            }
        }
        let journal=Journal{schema:1,id:f.m.id.clone(),instance_id:f.m.instance_id.clone(),
            version:f.m.version.clone(),canonical_target:fs::canonicalize(&f.live).unwrap().to_string_lossy().into(),
            phase:"rolling".into(),changes,kind:String::new(),from_version:String::new()};
        write_journal(&root,&journal,false).unwrap();
        (root,journal)
    }

    #[test]
    fn healthy_only_reads_and_corrupt_repair_updates_exactly_pinned_file(){
        let f=fixture(&[("game.exe",b"pristine",Some(b"wrong"))]);
        let user=f.live.join("saves/world/player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();fs::write(&user,b"untouched").unwrap();
        assert_eq!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&guard,&mut noop).unwrap(),"repaired");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"pristine");
        assert_eq!(fs::read(&user).unwrap(),b"untouched");
        assert_eq!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&guard,&mut noop).unwrap(),"already-verified");
        assert!(!f.live.join(".coco").join(TRANSACTION).exists());
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"no-recovery-needed");
    }

    #[test]
    fn missing_file_is_installed_without_touching_neighbor(){
        let f=fixture(&[("game.exe",b"native",None),("assets/core.bin",b"good",Some(b"good"))]);
        fs::write(f.live.join("readme.txt"),b"unrelated").unwrap();
        assert_eq!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&guard,&mut noop).unwrap(),"repaired");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"native");
        assert_eq!(fs::read(f.live.join("assets/core.bin")).unwrap(),b"good");
        assert_eq!(fs::read(f.live.join("readme.txt")).unwrap(),b"unrelated");
    }

    #[test]
    fn interrupted_multi_file_commit_rolls_back_while_restoring_missing_file(){
        let f=fixture(&[("data/core.bin",b"fixed",Some(b"old")),("game.exe",b"new",None)]);
        let (root,journal)=unfinished(&f);
        let result=apply_changes(&f.live,&root,&journal,&guard,&mut noop,Some(1));
        assert!(result.unwrap_err().contains("Simulated interrupted"));
        assert_eq!(fs::read(f.live.join("data/core.bin")).unwrap(),b"fixed");
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"recovery-complete");
        assert_eq!(fs::read(f.live.join("data/core.bin")).unwrap(),b"old");
        assert!(!f.live.join("game.exe").exists());
        assert!(!root.exists());
    }

    #[test]
    fn interrupted_between_old_rename_and_new_rename_restores_backup(){
        let f=fixture(&[("game.exe",b"new",Some(b"old"))]);
        let (root,_)=unfinished(&f);
        fs::rename(f.live.join("game.exe"),trash(&root,0)).unwrap();
        assert!(!f.live.join("game.exe").exists());
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"recovery-complete");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old");
    }

    #[test]
    fn crash_after_rollback_copy_resumes_verified_unicode_temp_and_preserves_saves(){
        let path="mundo gráfico/recursos 漢字.bin";
        let f=fixture(&[(path,b"publisher-fixed",Some(b"previous-binary"))]);
        let user=f.live.join("saves").join("Mi mundo").join("player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();
        fs::write(&user,b"private-player-data").unwrap();
        let (root,journal)=unfinished(&f);
        assert!(apply_changes(&f.live,&root,&journal,&guard,&mut noop,Some(1)).is_err());
        let live=f.live.join(path);
        assert_eq!(fs::read(&live).unwrap(),b"publisher-fixed");
        // Simulate the crash boundary immediately after copying the verified
        // backup, before the recovery temp has been moved back into the game.
        let temporary=root.join("recovery/0");
        durable_copy(&backup(&root,0),&temporary,journal.changes[0].old.as_ref().unwrap(),
            &AtomicBool::new(false)).unwrap();
        assert_eq!(fs::read(&temporary).unwrap(),b"previous-binary");
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"recovery-complete");
        assert_eq!(fs::read(&live).unwrap(),b"previous-binary");
        assert!(!root.exists());
        assert_eq!(fs::read(&user).unwrap(),b"private-player-data");
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"no-recovery-needed");
    }

    #[test]
    fn foreign_recovery_temp_rejected_before_any_live_change_then_recovers(){
        let f=fixture(&[("game.exe",b"publisher-fixed",Some(b"old-original"))]);
        let (root,journal)=unfinished(&f);
        assert!(apply_changes(&f.live,&root,&journal,&guard,&mut noop,Some(1)).is_err());
        let temporary=root.join("recovery/0");
        fs::write(&temporary,b"tampered-temp").unwrap();
        let live=f.live.join("game.exe");
        let before=fs::read(&live).unwrap();
        assert!(recover(&f.m,&f.live,&guard,&mut noop).unwrap_err().contains("temporal"));
        assert_eq!(fs::read(&live).unwrap(),before,
            "failed preflight must not remove an otherwise valid live game");
        assert_eq!(fs::read(backup(&root,0)).unwrap(),b"old-original");
        assert!(root.exists());
        // Test owns this fixture temp, so it may remove it to model a user
        // clearing the foreign obstruction before retrying recovery.
        fs::remove_file(&temporary).unwrap();
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"recovery-complete");
        assert_eq!(fs::read(&live).unwrap(),b"old-original");
    }

    #[test]
    fn win32_no_replace_unicode_race_and_sharing_lock_preserve_foreign_destination(){
        use std::os::windows::fs::OpenOptionsExt;
        let f=fixture(&[("game.exe",b"publisher",Some(b"original"))]);
        let unsafe_source=f.root.join("unsafe source.bin");
        let unsafe_target=f.root.join("unsafe target.bin");
        fs::write(&unsafe_source,b"publisher").unwrap();
        fs::write(&unsafe_target,b"foreign").unwrap();
        fs::rename(&unsafe_source,&unsafe_target).unwrap();
        assert_eq!(fs::read(&unsafe_target).unwrap(),b"publisher",
            "Windows std::fs::rename can replace existing foreign bytes: original bug");
        let work=f.root.join("origen 漢字.bin");
        let foreign=f.root.join("destino 漢字.bin");
        fs::write(&work,b"publisher-new").unwrap();
        // An unrelated process creates a new file after our earlier
        // not-found probe but before the atomic Windows move.
        assert!(!foreign.exists());
        fs::write(&foreign,b"third-party-bytes").unwrap();
        assert!(move_no_replace(&work,&foreign).is_err());
        assert_eq!(fs::read(&work).unwrap(),b"publisher-new");
        assert_eq!(fs::read(&foreign).unwrap(),b"third-party-bytes");
        fs::remove_file(&foreign).unwrap();
        let locked=OpenOptions::new().read(true).share_mode(0).open(&work).unwrap();
        assert!(move_no_replace(&work,&foreign).is_err(),
            "exclusive Win32 sharing lock must block moving a source file");
        drop(locked);
        assert!(!foreign.exists());
        move_no_replace(&work,&foreign).unwrap();
        assert!(!work.exists());
        assert_eq!(fs::read(&foreign).unwrap(),b"publisher-new");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"original");
    }

    #[test]
    fn locked_rollback_retries_after_av_sharing_violation_without_losing_journal(){
        use std::os::windows::fs::OpenOptionsExt;
        let f=fixture(&[("assets/rótulo 漢字.bin",b"new",Some(b"old"))]);
        let user=f.live.join("saves/world/player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();
        fs::write(&user,b"player-progress").unwrap();
        let (root,journal)=unfinished(&f);
        assert!(apply_changes(&f.live,&root,&journal,&guard,&mut noop,Some(1)).is_err());
        let live=f.live.join("assets/rótulo 漢字.bin");
        let held=OpenOptions::new().read(true).share_mode(0).open(&live).unwrap();
        assert!(recover(&f.m,&f.live,&guard,&mut noop).is_err());
        assert!(root.exists(),"a sharing violation must retain recovery journal");
        assert_eq!(fs::read(backup(&root,0)).unwrap(),b"old");
        drop(held);
        assert_eq!(recover(&f.m,&f.live,&guard,&mut noop).unwrap(),"recovery-complete");
        assert_eq!(fs::read(&live).unwrap(),b"old");
        assert_eq!(fs::read(&user).unwrap(),b"player-progress");
    }

    #[test]
    fn rollback_refuses_to_overwrite_third_party_changes_and_keeps_backups(){
        let f=fixture(&[("game.exe",b"new",Some(b"old"))]);
        let (root,journal)=unfinished(&f);
        apply_changes(&f.live,&root,&journal,&guard,&mut noop,None).unwrap();
        fs::write(f.live.join("game.exe"),b"user-customized").unwrap();
        assert!(recover(&f.m,&f.live,&guard,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"user-customized");
        assert_eq!(fs::read(backup(&root,0)).unwrap(),b"old");
        assert!(journal_path(&root).exists());
    }

    #[test]
    fn protected_mod_or_configuration_and_unknown_receipt_block_mutation(){
        for name in ["mods/custom.jar","BepInEx/plugins/mod.dll","config/preferences.ini",
                     "saves/world.dat","DistantHorizons/save.db","playerdata/42.dat"]{
            let f=fixture(&[(name,b"expected",Some(b"modified"))]);
            let before=fs::read(f.live.join(name)).unwrap();
            assert!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&guard,&mut noop).is_err(),"{name}");
            assert_eq!(fs::read(f.live.join(name)).unwrap(),before);
            assert!(!f.live.join(".coco").join(TRANSACTION).exists());
        }
        let f=fixture(&[("game.exe",b"expected",Some(b"modified"))]);
        fs::write(f.live.join(".coco/standalone-install-v1.json"),b"{}" ).unwrap();
        assert!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&guard,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"modified");
    }

    #[test]
    fn windows_locked_file_refuses_commit_and_symlink_is_rejected(){
        use std::os::windows::fs::OpenOptionsExt;
        let f=fixture(&[("game.exe",b"good",Some(b"bad"))]);
        let locked=OpenOptions::new().read(true).share_mode(0).open(f.live.join("game.exe")).unwrap();
        assert!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&guard,&mut noop).is_err());
        assert!(fs::read(f.live.join("game.exe")).is_err(),"Windows exclusive handle must block readers");
        drop(locked);
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"bad");
        let link=f.live.join("alias.bin");
        if std::os::windows::fs::symlink_file(f.live.join("game.exe"),&link).is_ok(){
            assert!(fingerprint(&link,&AtomicBool::new(false)).is_err());
            fs::remove_file(link).unwrap();
        }
    }

    #[test]
    fn game_guard_fails_closed_before_touching_any_installed_bytes(){
        let f=fixture(&[("game.exe",b"expected",Some(b"old"))]);
        let denied=||Err("active game".to_string());
        assert!(commit(&f.m,&f.live,&f.stage,&AtomicBool::new(false),&denied,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old");
        assert!(!f.live.join(".coco").join(TRANSACTION).exists());
    }

    #[test]
    fn cancellation_before_journal_never_changes_original_file(){
        let f=fixture(&[("game.exe",b"correct",Some(b"old"))]);
        let cancel=AtomicBool::new(true);
        assert_eq!(commit(&f.m,&f.live,&f.stage,&cancel,&guard,&mut noop).unwrap_err(),"cancelled");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old");
        assert!(!f.live.join(".coco").join(TRANSACTION).exists());
    }

    #[test]
    fn journal_backup_symlink_or_wrong_bytes_blocks_recovery(){
        let f=fixture(&[("game.exe",b"new",Some(b"old"))]);
        let (root,_)=unfinished(&f);
        fs::write(backup(&root,0),b"tampered").unwrap();
        assert!(recover(&f.m,&f.live,&guard,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old");
        assert!(root.exists(),"journal retained when backup cannot be trusted");
    }

    #[test]
    fn cleanup_after_crash_resumes_only_owned_files_and_refuses_foreign_entry(){
        let f=fixture(&[("game.exe",b"new",Some(b"old"))]);
        let (root,journal)=unfinished(&f);
        apply_changes(&f.live,&root,&journal,&guard,&mut noop,None).unwrap();
        let mut committed=journal.clone();committed.phase="committed".into();
        write_journal(&root,&committed,true).unwrap();
        fs::write(root.join("cleanup-marker.json"),fs::read(journal_path(&root)).unwrap()).unwrap();
        let cleanup=f.live.join(".coco").join(CLEANUP);
        fs::rename(&root,&cleanup).unwrap();
        fs::remove_file(cleanup.join("payload").join("0")).ok(); // already moved into live
        fs::remove_file(cleanup.join("trash").join("0")).unwrap(); // simulated partial cleanup
        fs::write(cleanup.join("backup").join("surprise.txt"),b"foreign").unwrap();
        assert!(finish_cleanup(&f.live).is_err(),"unknown files prevent recursive deletion");
        assert_eq!(fs::read(cleanup.join("backup").join("surprise.txt")).unwrap(),b"foreign");
        fs::remove_file(cleanup.join("backup").join("surprise.txt")).unwrap();
        finish_cleanup(&f.live).unwrap();
        assert!(!cleanup.exists());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"new");
    }

    fn upgrade_fixture()->(Fixture,Manifest){
        let f=fixture(&[("game.exe",b"old-version",Some(b"old-version")),
            ("assets/common.bin",b"common",Some(b"common"))]);
        let mut next=f.m.clone();
        next.version="2.0.0".into();
        next.required_files[0]=spec("game.exe",b"new-version");
        fs::write(f.stage.join("game.exe"),b"new-version").unwrap();
        write_install_receipt(&f.stage,&next,&[]).unwrap();
        (f,next)
    }

    fn prepare_upgrade_journal(f:&Fixture,new:&Manifest)->(PathBuf,Journal){
        let previous=fingerprint(&f.live.join("game.exe"),&AtomicBool::new(false)).unwrap();
        let new_fp=fingerprint(&f.stage.join("game.exe"),&AtomicBool::new(false)).unwrap().unwrap();
        let old_receipt=fingerprint(&f.live.join(RECEIPT),&AtomicBool::new(false)).unwrap().unwrap();
        let new_receipt=fingerprint(&f.stage.join(RECEIPT),&AtomicBool::new(false)).unwrap().unwrap();
        let changes=vec![Change{path:"game.exe".into(),old:previous,new:new_fp},
            Change{path:RECEIPT.into(),old:Some(old_receipt),new:new_receipt}];
        let root=f.live.join(".coco").join(UPGRADE_TRANSACTION);
        for name in ["payload","backup","trash","discard","recovery"]{
            fs::create_dir_all(root.join(name)).unwrap();
        }
        for (index,change) in changes.iter().enumerate(){
            durable_copy(&f.stage.join(&change.path),&payload(&root,index),&change.new,&AtomicBool::new(false)).unwrap();
            if let Some(old)=&change.old{
                durable_copy(&f.live.join(&change.path),&backup(&root,index),old,&AtomicBool::new(false)).unwrap();
            }
        }
        let journal=Journal{schema:1,id:new.id.clone(),instance_id:new.instance_id.clone(),
            version:new.version.clone(),canonical_target:fs::canonicalize(&f.live).unwrap().to_string_lossy().to_string(),
            phase:"rolling".into(),changes,kind:"upgrade".into(),from_version:f.m.version.clone()};
        write_journal(&root,&journal,false).unwrap();
        (root,journal)
    }

    #[test]
    fn upgrade_a_to_b_replaces_only_pinned_bytes_and_receipt_then_refuses_repeat(){
        let (f,new)=upgrade_fixture();
        let user=f.live.join("saves/world/player.dat");
        fs::create_dir_all(user.parent().unwrap()).unwrap();fs::write(&user,b"user-data").unwrap();
        assert_eq!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).unwrap(),"upgraded");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"new-version");
        assert_eq!(fs::read(f.live.join("assets/common.bin")).unwrap(),b"common");
        assert_eq!(fs::read(user).unwrap(),b"user-data");
        assert_eq!(read_owned_receipt(&f.live).unwrap()["version"],"2.0.0");
        assert!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).is_err());
        assert!(!f.live.join(".coco").join(UPGRADE_TRANSACTION).exists());
    }

    #[test]
    fn upgrades_missing_owned_file_but_refuses_corrupt_and_unowned_collision(){
        let (f,new)=upgrade_fixture();
        fs::remove_file(f.live.join("game.exe")).unwrap();
        assert_eq!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).unwrap(),"upgraded");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"new-version");
        let (f,new)=upgrade_fixture();
        fs::write(f.live.join("game.exe"),b"corrupt" ).unwrap();
        assert!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"corrupt");
        assert_eq!(read_owned_receipt(&f.live).unwrap()["version"],"1");
        assert!(!f.live.join(".coco").join(UPGRADE_TRANSACTION).exists());
        let (f,mut new)=upgrade_fixture();
        fs::write(f.live.join("foreign.dll"),b"user-plugin").unwrap();
        fs::write(f.stage.join("foreign.dll"),b"official-plugin").unwrap();
        new.required_files.push(spec("foreign.dll",b"official-plugin"));
        fs::remove_dir_all(f.stage.join(".coco")).unwrap();
        write_install_receipt(&f.stage,&new,&[]).unwrap();
        assert!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("foreign.dll")).unwrap(),b"user-plugin");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old-version");
    }

    #[test]
    fn interrupted_upgrade_before_metadata_restores_both_executable_and_old_receipt(){
        let (f,new)=upgrade_fixture();
        let before=fs::read(f.live.join(RECEIPT)).unwrap();
        let (root,journal)=prepare_upgrade_journal(&f,&new);
        assert!(apply_changes(&f.live,&root,&journal,&guard,&mut noop,Some(1)).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"new-version");
        assert_eq!(fs::read(f.live.join(RECEIPT)).unwrap(),before);
        assert_eq!(restore(&new,&f.live,&root,&guard,&mut noop).unwrap(),"recovery-complete");
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old-version");
        assert_eq!(fs::read(f.live.join(RECEIPT)).unwrap(),before);
    }

    #[test]
    fn interrupted_upgrade_after_receipt_rolls_back_complete_a_state(){
        let (f,new)=upgrade_fixture();
        let before=fs::read(f.live.join(RECEIPT)).unwrap();
        let (root,journal)=prepare_upgrade_journal(&f,&new);
        assert!(apply_changes(&f.live,&root,&journal,&guard,&mut noop,Some(2)).is_err());
        assert_eq!(read_owned_receipt(&f.live).unwrap()["version"],"2.0.0");
        restore(&new,&f.live,&root,&guard,&mut noop).unwrap();
        assert_eq!(fs::read(f.live.join(RECEIPT)).unwrap(),before);
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old-version");
    }

    #[test]
    fn committed_upgrade_recovery_finishes_cleanup_without_downgrading(){
        let (f,new)=upgrade_fixture();
        let (root,journal)=prepare_upgrade_journal(&f,&new);
        apply_changes(&f.live,&root,&journal,&guard,&mut noop,None).unwrap();
        let mut committed=journal.clone();committed.phase="committed".into();
        write_journal(&root,&committed,true).unwrap();
        restore(&new,&f.live,&root,&guard,&mut noop).unwrap();
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"new-version");
        assert_eq!(read_owned_receipt(&f.live).unwrap()["version"],"2.0.0");
    }

    #[test]
    fn upgrade_locked_old_exe_and_protected_mod_abort_without_journal(){
        use std::os::windows::fs::OpenOptionsExt;
        let (f,new)=upgrade_fixture();
        let lock=OpenOptions::new().read(true).share_mode(0).open(f.live.join("game.exe")).unwrap();
        assert!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).is_err());
        drop(lock);
        assert!(!f.live.join(".coco").join(UPGRADE_TRANSACTION).exists());
        let (f,mut new)=upgrade_fixture();
        new.required_files.push(spec("mods/custom.jar",b"publisher"));
        fs::create_dir_all(f.stage.join("mods")).unwrap();
        fs::write(f.stage.join("mods/custom.jar"),b"publisher").unwrap();
        assert!(upgrade(&f.m,&new,&f.live,&f.stage,&[],&AtomicBool::new(false),&guard,&mut noop).is_err());
        assert_eq!(fs::read(f.live.join("game.exe")).unwrap(),b"old-version");
    }
}
