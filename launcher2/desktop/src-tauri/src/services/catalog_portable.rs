//! Direct intake of a sealed Host Studio .coco2pack.zip envelope.
//! The untrusted ZIP is never extracted to a user-selected directory.
use super::*;
use std::io::{Seek, SeekFrom};
use zip::{CompressionMethod, ZipArchive};

const PORTABLE_METADATA: &[&str] = &[
    "publish-manifest.json","catalog.template.json","catalog-candidate.json",
    "source-lock.json","coco2-client-entry.json","coco2-install-manifest.json",
];
const PORTABLE_COVERS: &[&str] = &["cover.png","cover.jpg","cover.jpeg","cover.webp"];
const MAX_PORTABLE_ENVELOPE: u64 = MAX_ARCHIVE + 64 * 1024 * 1024;
const MAX_PORTABLE_EXPANDED: u64 = MAX_ARCHIVE + 32 * 1024 * 1024;

/// zip::ZipArchive's name map can collapse duplicate literal filenames even
/// when the central directory contains two entries. Inspect the raw central
/// directory ourselves: exactly eight *physical* entries, no hidden aliases.
/// Host Studio writes a canonical ZIP with no comment or leading stub.
fn validate_physical_central_directory(input:&mut File,length:u64)->Result<HashSet<String>,String>{
    if length<22{return Err("Portable ZIP lacks end-of-directory record".into());}
    input.seek(SeekFrom::End(-22)).map_err(|e|e.to_string())?;
    let mut eocd=[0u8;22];
    input.read_exact(&mut eocd).map_err(|e|e.to_string())?;
    let u16at=|bytes:&[u8],offset:usize|u16::from_le_bytes([bytes[offset],bytes[offset+1]]);
    let u32at=|bytes:&[u8],offset:usize|u32::from_le_bytes(bytes[offset..offset+4].try_into().unwrap());
    if &eocd[..4]!=b"PK\x05\x06" || u16at(&eocd,4)!=0 || u16at(&eocd,6)!=0
        || u16at(&eocd,8)!=8 || u16at(&eocd,10)!=8 || u16at(&eocd,20)!=0 {
        return Err("Portable ZIP physical entry count/disk/comment not canonical".into());
    }
    let mut central_size=u32at(&eocd,12) as u64;
    let mut central_offset=u32at(&eocd,16) as u64;
    let end=length-22;
    let mut central_end=end;
    if central_size==u32::MAX as u64 || central_offset==u32::MAX as u64 {
        if end<20{return Err("Missing ZIP64 locator".into());}
        input.seek(SeekFrom::Start(end-20)).map_err(|e|e.to_string())?;
        let mut locator=[0u8;20];
        input.read_exact(&mut locator).map_err(|e|e.to_string())?;
        if &locator[..4]!=b"PK\x06\x07"
            || u32at(&locator,4)!=0 || u32at(&locator,16)!=1 {
            return Err("Invalid ZIP64 locator or disk count".into());
        }
        let zip64_offset=u64::from_le_bytes(locator[8..16].try_into().unwrap());
        if zip64_offset>length.saturating_sub(56){return Err("Invalid ZIP64 central offset".into());}
        input.seek(SeekFrom::Start(zip64_offset)).map_err(|e|e.to_string())?;
        let mut record=[0u8;56];
        input.read_exact(&mut record).map_err(|e|e.to_string())?;
        if &record[..4]!=b"PK\x06\x06"
            || u64::from_le_bytes(record[4..12].try_into().unwrap())!=44
            || u32at(&record,16)!=0 || u32at(&record,20)!=0
            || zip64_offset.checked_add(56)!=Some(end-20)
            || u64::from_le_bytes(record[24..32].try_into().unwrap())!=8
            || u64::from_le_bytes(record[32..40].try_into().unwrap())!=8{
            return Err("ZIP64 physical entry count mismatch".into());
        }
        central_size=u64::from_le_bytes(record[40..48].try_into().unwrap());
        central_offset=u64::from_le_bytes(record[48..56].try_into().unwrap());
        central_end=zip64_offset;
    }
    if central_size==0 || central_size>128*1024
        || central_offset.checked_add(central_size)!=Some(central_end) {
        return Err("Portable central directory size/offset inconsistent".into());
    }
    input.seek(SeekFrom::Start(central_offset)).map_err(|e|e.to_string())?;
    let mut central=vec![0u8;central_size as usize];
    input.read_exact(&mut central).map_err(|e|e.to_string())?;
    let mut cursor=0usize;
    let mut names=HashSet::new();
    for _ in 0..8 {
        if cursor+46>central.len() || &central[cursor..cursor+4]!=b"PK\x01\x02" {
            return Err("Physical central-directory entry missing".into());
        }
        let flags=u16at(&central,cursor+8);
        let method=u16at(&central,cursor+10);
        let name_len=u16at(&central,cursor+28) as usize;
        let extra_len=u16at(&central,cursor+30) as usize;
        let comment_len=u16at(&central,cursor+32) as usize;
        let size=46usize.checked_add(name_len).and_then(|v|v.checked_add(extra_len))
            .and_then(|v|v.checked_add(comment_len)).ok_or("Central-directory entry overflow")?;
        if cursor+size>central.len() || name_len==0 || name_len>128 || flags&1!=0 || method!=0 {
            return Err("Unsupported portable physical ZIP header".into());
        }
        let name=std::str::from_utf8(&central[cursor+46..cursor+46+name_len])
            .map_err(|_|"Portable physical filename is not UTF-8 ASCII")?;
        if !name.is_ascii() || !valid_relative_file(name) || name.contains('/')
            || name.contains('\\') || !names.insert(name.to_ascii_lowercase())
            || !(PORTABLE_METADATA.contains(&name) || PORTABLE_COVERS.contains(&name) || name=="game.zip") {
            return Err("Portable ZIP physical duplicate/case alias/unknown member".into());
        }
        cursor+=size;
    }
    if cursor!=central.len(){return Err("Hidden physical central-directory entries refused".into());}
    Ok(names)
}

pub(super) fn is_portable(path:&Path)->bool {
    path.file_name().and_then(|s|s.to_str())
        .is_some_and(|s|{
            let name=s.to_ascii_lowercase();
            name.ends_with(".coco2pack") || name.ends_with(".coco2pack.zip")
        })
}

#[cfg(windows)]
fn locked_source(path:&Path)->Result<File,String>{
    use std::os::windows::fs::OpenOptionsExt;
    // FILE_SHARE_READ only: no write/delete/rename until this handle closes.
    OpenOptions::new().read(true).share_mode(1).open(path)
        .map_err(|e|format!("Cannot hold portable source read lock: {e}"))
}
#[cfg(not(windows))]
fn locked_source(path:&Path)->Result<File,String>{
    File::open(path).map_err(|e|format!("Cannot open portable source: {e}"))
}

fn portable_path(value:&str)->Result<PathBuf,String>{
    let path=PathBuf::from(value);
    if !path.is_absolute()||!is_portable(&path){return Err("Select an absolute .coco2pack file (or legacy .coco2pack.zip)".into());}
    #[cfg(windows)]
    if value.starts_with(r"\\") {
        let bytes=value.as_bytes();
        // Rust canonicalize() returns \\?\C:\...; allow exactly local
        // extended DRIVE paths, never UNC, device or GLOBALROOT paths.
        if !(bytes.len()>7 && value.starts_with(r"\\?\")
            && bytes[4].is_ascii_alphabetic() && bytes[5]==b':'
            && bytes[6]==b'\\') {
            return Err("Network/UNC/device portable package is not accepted".into());
        }
    }
    guarded_path(&path)?;
    let canon=path.canonicalize().map_err(|_|"Portable package missing")?;
    guarded_path(&canon)?;
    if !canon.is_file(){return Err("Portable package must be a regular file".into());}
    Ok(canon)
}

#[cfg(windows)]
fn available_disk(dir:&Path)->Result<u64,String>{
    use std::os::windows::ffi::OsStrExt;
    #[link(name="kernel32")]
    extern "system" {
        fn GetDiskFreeSpaceExW(path:*const u16,available:*mut u64,total:*mut u64,free:*mut u64)->i32;
    }
    let wide=dir.as_os_str().encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let mut free=0u64;
    if unsafe{GetDiskFreeSpaceExW(wide.as_ptr(),&mut free,std::ptr::null_mut(),std::ptr::null_mut())}==0 {
        return Err("Cannot determine free disk capacity for portable staging".into());
    }
    Ok(free)
}
#[cfg(not(windows))]
fn available_disk(_dir:&Path)->Result<u64,String>{Ok(u64::MAX)}

struct PrivateStage(PathBuf);
impl Drop for PrivateStage {
    fn drop(&mut self){
        // Only this invocation's exclusively-created private tree is owned.
        // A redirected/reparse point is never followed or recursively deleted.
        if guarded_path(&self.0).is_ok() && self.0.is_dir(){
            let _=fs::remove_dir_all(&self.0);
        }
    }
}

pub(super) struct PortablePackage {
    _stage:PrivateStage,
    pub(super) root:PathBuf,
    pub(super) source:PathBuf,
    pub(super) sha256:String,
    pub(super) manifest_sha256:String,
}

fn expected_member_hash(manifest:&Value,name:&str)->Result<String,String>{
    let field=match name {
        "catalog.template.json"=>"resultCatalogSha256",
        "catalog-candidate.json"=>"candidateSha256",
        "source-lock.json"=>"lockSha256",
        "coco2-client-entry.json"=>"clientPreviewSha256",
        "coco2-install-manifest.json"=>"installPreviewSha256",
        "cover.png"|"cover.jpg"|"cover.jpeg"|"cover.webp"=>"coverSha256",
        "game.zip"=>"archiveSha256",
        _=>return Err("Unexpected portable member".into()),
    };
    let value=manifest[field].as_str().ok_or("Portable package manifest lacks member SHA256")?;
    if !valid_sha(value){return Err("Invalid member SHA256".into());}
    Ok(value.to_owned())
}

pub(super) fn unpack(path:&str,root:&Path)->Result<PortablePackage,String>{
    let source=portable_path(path)?;
    let mut input=locked_source(&source)?;
    let file_len=input.metadata().map_err(|e|e.to_string())?.len();
    if file_len==0||file_len>MAX_PORTABLE_ENVELOPE {
        return Err("Portable ZIP exceeds bounded transport size".into());
    }
    let mut digest=Sha256::new();
    let mut buf=vec![0u8;1024*1024];
    let mut counted=0u64;
    loop {
        let n=input.read(&mut buf).map_err(|e|e.to_string())?;
        if n==0 {break;}
        counted=counted.checked_add(n as u64).ok_or("Portable ZIP size overflow")?;
        if counted>file_len{return Err("Portable ZIP size changed during review".into());}
        digest.update(&buf[..n]);
    }
    if counted!=file_len{return Err("Portable ZIP truncated during review".into());}
    let portable_sha=format!("{:x}",digest.finalize());
    let physical_names=validate_physical_central_directory(&mut input,file_len)?;
    input.seek(SeekFrom::Start(0)).map_err(|e|e.to_string())?;
    let mut archive=ZipArchive::new(input).map_err(|e|format!("Malformed portable ZIP: {e}"))?;
    if archive.len()!=8{return Err("Portable ZIP requires exactly eight flat members".into());}
    let mut seen=HashSet::new();
    let mut expanded=0u64;
    let mut cover=None;
    for i in 0..archive.len(){
        let member=archive.by_index(i).map_err(|e|format!("ZIP member header rejected: {e}"))?;
        let name=member.name();
        if name.contains('/') || name.contains('\\') || !valid_relative_file(name)
            || member.is_dir() || !seen.insert(name.to_ascii_lowercase()) {
            return Err("Portable ZIP has traversal, duplicate, or non-flat member".into());
        }
        if member.encrypted() || member.compression()!=CompressionMethod::Stored
            || member.compressed_size()!=member.size()
            || !matches!(member.unix_mode().unwrap_or(0)&0o170000,0|0o100000) {
            return Err("Portable ZIP must contain unencrypted STORE regular files".into());
        }
        let limit=if name=="game.zip"{MAX_ARCHIVE}
            else if PORTABLE_COVERS.contains(&name){MAX_COVER}else{MAX_METADATA};
        if member.size()==0 || member.size()>limit {
            return Err("Portable member exceeds its strict size limit".into());
        }
        expanded=expanded.checked_add(member.size()).ok_or("Portable expanded size overflow")?;
        if expanded>MAX_PORTABLE_EXPANDED{return Err("Portable expanded size budget exceeded".into());}
        if PORTABLE_COVERS.contains(&name){
            if cover.replace(name.to_owned()).is_some(){return Err("Multiple portable covers".into());}
        }else if !PORTABLE_METADATA.contains(&name) && name!="game.zip" {
            return Err("Unrecognized portable package member".into());
        }
    }
    if seen!=physical_names {
        return Err("ZIP reader names differ from physical central-directory whitelist".into());
    }
    let cover=cover.ok_or("Portable cover missing")?;
    if PORTABLE_METADATA.iter().any(|name|!seen.contains(*name))
        || !seen.contains("game.zip") {
        return Err("Portable metadata whitelist incomplete".into());
    }
    let mut manifest_file=archive.by_name("publish-manifest.json")
        .map_err(|_|"Portable publisher manifest missing")?;
    let mut bytes=Vec::new();
    (&mut manifest_file).take(MAX_METADATA+1).read_to_end(&mut bytes)
        .map_err(|e|format!("Portable publisher manifest unreadable: {e}"))?;
    if bytes.len() as u64>MAX_METADATA {return Err("Portable publisher manifest exceeds limit".into());}
    let manifest_sha=hash(&bytes);
    let manifest:Value=serde_json::from_slice(&bytes).map_err(|_|"Invalid portable publish manifest")?;
    if manifest["schemaVersion"]!=1 || manifest["packageKind"]!="coco2-host-publish-offline"
        || manifest["coverFile"]!=cover || manifest["archiveFile"]!="game.zip"
        || manifest["reviewedRights"]!=true || manifest["published"]!=false
        || manifest["uploaded"]!=false {
        return Err("Portable envelope does not match reviewed Host Studio package".into());
    }
    drop(manifest_file);
    let archive_size=manifest["archiveSize"].as_u64().ok_or("Portable game ZIP size absent")?;
    if archive_size==0||archive_size>MAX_ARCHIVE{return Err("Portable archive size exceeds bound".into());}
    if archive.by_name("game.zip").map_err(|_|"Game ZIP missing")?.size()!=archive_size {
        return Err("Portable archive length differs from publication manifest".into());
    }
    guarded_path(root)?;
    fs::create_dir_all(root).map_err(|e|e.to_string())?;
    guarded_path(root)?;
    let available=available_disk(root)?;
    // Maintain a small reserve for metadata, ZIP central-directory and FS.
    if available<expanded.saturating_add(16*1024*1024) {
        return Err("Insufficient free disk space for private portable inspection".into());
    }
    let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_|"System clock unavailable")?.as_nanos();
    let stage=root.join(format!(".portable-{}-{stamp}.stage",std::process::id()));
    guarded_path(&stage)?;
    fs::create_dir(&stage).map_err(|_|"Cannot exclusively reserve portable inspection stage")?;
    let owned=PrivateStage(stage.clone());
    for i in 0..archive.len(){
        let mut member=archive.by_index(i).map_err(|_|"Portable ZIP changed during extraction")?;
        let name=member.name().to_owned();
        let sha=if name=="publish-manifest.json"{manifest_sha.clone()}
            else {expected_member_hash(&manifest,&name)?};
        let length=member.size();
        let target=stage.join(&name);
        guarded_path(&target)?;
        let mut output=OpenOptions::new().create_new(true).write(true).open(&target)
            .map_err(|_|"Cannot reserve private portable component")?;
        let mut digest=Sha256::new();let mut read=0u64;
        loop {
            let n=member.read(&mut buf).map_err(|e|format!("Portable ZIP CRC/content rejected: {e}"))?;
            if n==0{break;}
            read=read.checked_add(n as u64).ok_or("Portable extraction overflow")?;
            if read>length{return Err("Portable component expanded beyond expected size".into());}
            digest.update(&buf[..n]);
            output.write_all(&buf[..n]).map_err(|e|e.to_string())?;
        }
        output.sync_all().map_err(|e|e.to_string())?;
        if read!=length || format!("{:x}",digest.finalize())!=sha {
            return Err(format!("Portable member hash/size mismatch: {name}"));
        }
    }
    // The same content-stable Windows handle remains live through all reads.
    let mut input=archive.into_inner();
    input.seek(SeekFrom::Start(0)).map_err(|e|e.to_string())?;
    let mut digest=Sha256::new();let mut read=0u64;
    loop {
        let n=input.read(&mut buf).map_err(|e|e.to_string())?;
        if n==0 {break;}
        read=read.checked_add(n as u64).ok_or("Portable fingerprint overflow")?;
        if read>file_len{return Err("Portable ZIP modified during extraction".into());}
        digest.update(&buf[..n]);
    }
    if read!=file_len || format!("{:x}",digest.finalize())!=portable_sha {
        return Err("Portable ZIP changed after extraction; no import performed".into());
    }
    Ok(PortablePackage{_stage:owned,root:stage,source,sha256:portable_sha,manifest_sha256:manifest_sha})
}

pub(super) fn review_token(pack:&PortablePackage,snapshot_sha:Option<&str>)->String{
    hash(format!("coco2-portable-v1\n{}\n{}\n{}\n{}",
        pack.source.display(),pack.sha256,pack.manifest_sha256,snapshot_sha.unwrap_or_default()).as_bytes())
}
