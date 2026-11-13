//! Real Windows process/filesystem E2E using ONLY self-compiled harmless EXEs.
//! Host manifests are synthesized and parsed, not signed/published to the real
//! per-user catalog. The test trust history is thread-local and test-only.
use super::*;
use std::process::{Child,Command};
use std::sync::Mutex;
use std::thread;
use std::time::Instant;
use std::net::TcpListener;
use std::sync::atomic::Ordering;
use zip::write::SimpleFileOptions;

struct Fixture{root:PathBuf}
impl Fixture{
    fn new()->Self{
        let nanos=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let root=std::env::temp_dir().join(format!("coco2-native-e2e-{}-{nanos}",std::process::id()));
        fs::create_dir(&root).unwrap();Self{root}
    }
    fn host(&self,version:&str)->PathBuf{self.root.join("host").join(version)}
    fn real_publisher_root(&self)->PathBuf{self.root.join("real-publisher").join("launcher2")}
    fn prepare_real_publisher(&self){
        let repo=self.root.join("real-publisher");
        for rel in ["launcher2","launcher/experiences","assets/experiences"]{
            fs::create_dir_all(repo.join(rel)).unwrap();
        }
        fs::write(repo.join("launcher/catalog.template.json"),
            br#"{"schemaVersion":1,"experiences":[]}"#).unwrap();
        // Complete standalone PNG 1x1, not merely a recognized file extension.
        let cover=base64::Engine::decode(&base64::engine::general_purpose::STANDARD,
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9c9TdS4AAAAASUVORK5CYII=").unwrap();
        fs::write(repo.join("cover.png"),cover).unwrap();
    }
    fn host_portable(&self,version:&str,update:bool)->(PathBuf,PathBuf){
        let repo=self.root.join("real-publisher");
        crate::services::r#import::test_host_studio_portable(
            &self.real_publisher_root(),"synthetic-game",version,
            &self.host(version).join("game.zip"),&repo.join("cover.png"),update,
        ).unwrap()
    }
    fn profile(&self,label:&str)->Profile{
        let root=self.root.join(format!("profile-{label}"));
        let app_data=root.join("AppData").join("Roaming");
        let local_data=root.join("AppData").join("Local");
        let target=app_data.join("CocoMinecraft").join("experiences").join("synthetic-game");
        let cache=local_data.join("CocoMinecraftUpdater").join("downloads").join("standalone-packs");
        fs::create_dir_all(&app_data).unwrap();fs::create_dir_all(&local_data).unwrap();
        let channel=root.join("catalog-snapshots");
        Profile{root,app_data,local_data,target,cache,channel}
    }
    fn publish_synthetic(&self,version:&str)->(Manifest,crate::services::catalog::Experience){
        let host=self.host(version);
        fs::create_dir_all(&host).unwrap();
        let src=host.join("helper.rs");
        let executable=host.join("game.exe");
        let code=format!(r#"
fn main() {{
  let mut args=std::env::args().skip(1);
  let marker=args.next().expect("marker path explicitly supplied by test");
  let millis:u64=args.next().expect("sleep milliseconds").parse().unwrap();
  std::fs::write(marker,b"{version}").expect("test-only marker");
  if let Some(child_exe)=args.next() {{
    let child_marker=args.next().expect("child marker path");
    std::process::Command::new(child_exe).arg(child_marker)
      .arg(millis.to_string()).spawn().expect("synthetic child starts");
    return; // parent launcher has exited; child is an independent Win32 PID
  }}
  std::thread::sleep(std::time::Duration::from_millis(millis));
}}
"#);
        fs::write(&src,code).unwrap();
        let compiler=std::env::var_os("RUSTC").unwrap_or_else(||"rustc".into());
        let output=Command::new(compiler).arg("--edition=2021")
            .arg("-C").arg("opt-level=0")
            .arg("-o").arg(&executable).arg(&src).output().unwrap();
        assert!(output.status.success(),"rustc synthetic helper: {}",String::from_utf8_lossy(&output.stderr));
        let exe_bytes=fs::read(&executable).unwrap();
        let asset=format!("synthetic-asset-v{version}");
        let archive=host.join("game.zip");
        let zip_file=File::create(&archive).unwrap();
        let mut zip=zip::ZipWriter::new(zip_file);
        zip.start_file("game.exe",SimpleFileOptions::default()).unwrap();
        zip.write_all(&exe_bytes).unwrap();
        zip.start_file("assets/runtime.dat",SimpleFileOptions::default()).unwrap();
        zip.write_all(asset.as_bytes()).unwrap();
        zip.finish().unwrap();
        let (size,sha256)=file_digest(&archive,&AtomicBool::new(false)).unwrap();
        let spec=|path:&str,data:&[u8]| FileSpec{path:path.into(),size:data.len() as u64,
            sha256:format!("{:x}",Sha256::digest(data))};
        let official_url=format!("https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.2.0/synthetic-{version}.zip");
        let manifest=Manifest{id:"synthetic-game".into(),instance_id:"synthetic-game".into(),
            workflow:"coco-standalone".into(),version:version.into(),
            archives:vec![ArchiveSpec{url:official_url.clone(),sha256:sha256.clone(),size}],
            required_files:vec![spec("game.exe",&exe_bytes),spec("assets/runtime.dat",asset.as_bytes())],
            executable:"game.exe".into(),files:vec![],extras:vec![],extra_files:vec![],has_extras:false};
        validate_manifest(&manifest).unwrap();
        let catalog=crate::services::catalog::Experience{id:manifest.id.clone(),
            instance_id:manifest.instance_id.clone(),name:"Synthetic Safe E2E".into(),
            image:"/synthetic.png".into(),description:"Test-only synthetic binary".into(),
            workflow:"coco-standalone".into(),minecraft_version:String::new(),loader:String::new(),
            required_files:manifest.required_files.iter().map(|f|crate::services::catalog::RequiredFile{
                path:f.path.clone(),sha256:f.sha256.clone(),size:f.size}).collect(),
            executable:"game.exe".into(),launch_arguments:vec![],hosting_mode:"p2p".into()};
        // Complete Host Studio offline package contract. It passes the REAL
        // channel intake/review/explicit-consent/import APIs at isolated roots.
        let id=&manifest.id;
        let required=serde_json::to_value(&manifest.required_files).unwrap();
        let candidate=serde_json::json!({"id":id,"name":catalog.name,"instanceId":id,
            "runtime":{"executable":manifest.executable,"requiredFiles":required},
            "pack":{"version":version,"archives":[{"archiveUrl":official_url,"sha256":sha256,"size":size}]}});
        let source=serde_json::json!({"schemaVersion":1,"experiences":[candidate]});
        let lock=serde_json::json!({"schemaVersion":1,"experienceId":id,
            "archive":{"url":manifest.archives[0].url,"sha256":sha256,"size":size}});
        let cover=b"\x89PNG\r\n\x1a\nsynthetic-e2e-cover";
        let write_json=|file:&str,data:&serde_json::Value|{
            let bytes=serde_json::to_vec(data).unwrap();
            fs::write(host.join(file),&bytes).unwrap();
            format!("{:x}",Sha256::digest(&bytes))
        };
        let source_sha=write_json("catalog.template.json",&source);
        let candidate_sha=write_json("catalog-candidate.json",&candidate);
        let lock_sha=write_json("source-lock.json",&lock);
        let client_sha=write_json("coco2-client-entry.json",&serde_json::to_value(&catalog).unwrap());
        let installer_sha=write_json("coco2-install-manifest.json",&serde_json::to_value(&manifest).unwrap());
        fs::write(host.join("cover.png"),cover).unwrap();
        let metadata=serde_json::json!({"schemaVersion":1,"packageKind":"coco2-host-publish-offline",
            "id":id,"mode":if version=="1.0.0"{"new"}else{"update"},
            "reviewedRights":true,"uploaded":false,"published":false,"installationsUpdated":false,
            "newVersion":version,"archiveSha256":sha256,"archiveSize":size,
            "archiveFile":"game.zip","catalogFile":"catalog.template.json",
            "lockFile":"source-lock.json","coverFile":"cover.png",
            "resultCatalogSha256":source_sha,"candidateSha256":candidate_sha,
            "lockSha256":lock_sha,"coverSha256":format!("{:x}",Sha256::digest(cover)),
            "clientPreviewSha256":client_sha,"installPreviewSha256":installer_sha});
        fs::write(host.join("publish-manifest.json"),serde_json::to_vec(&metadata).unwrap()).unwrap();
        let parsed:Manifest=serde_json::from_slice(&fs::read(host.join("coco2-install-manifest.json")).unwrap()).unwrap();
        validate_manifest(&parsed).unwrap();
        let client:crate::services::catalog::Experience=serde_json::from_slice(
            &fs::read(host.join("coco2-client-entry.json")).unwrap()).unwrap();
        assert_eq!(client.required_files.len(),parsed.required_files.len());
        (parsed,client)
    }
}
impl Drop for Fixture{
    fn drop(&mut self){
        // All fixture paths are freshly generated beneath the system temp root.
        if self.root.starts_with(std::env::temp_dir())&&self.root.file_name()
            .is_some_and(|s|s.to_string_lossy().starts_with("coco2-native-e2e-")){
            let _=fs::remove_dir_all(&self.root);
        }
    }
}
struct Profile{root:PathBuf,app_data:PathBuf,local_data:PathBuf,target:PathBuf,cache:PathBuf,channel:PathBuf}
impl Profile{
    fn import_portable(&self,source:&Path,version:&str)->Manifest{
        use crate::services::catalog::test_api as api;
        assert!(source.to_string_lossy().ends_with(".coco2pack")
            || source.to_string_lossy().ends_with(".coco2pack.zip"));
        // Receive as the legacy extension to prove old recipients still read
        // the same canonical ZIP bytes without re-exporting or unpacking.
        let received=self.root.join(format!("received-{version}.coco2pack.zip"));
        let size=fs::copy(source,&received).unwrap();
        assert!(size>0);
        assert_eq!(fs::read(&received).unwrap(),fs::read(source).unwrap(),
            "transfer must be byte-for-byte identical, never manually extracted");
        let review=api::review(&self.channel,&received).unwrap();
        assert_eq!(review.id,"synthetic-game");
        assert_eq!(review.new_version,version);
        assert!(api::import(&self.channel,&self.cache,&received,&"0".repeat(64)).is_err());
        let accepted=api::import(&self.channel,&self.cache,&received,&review.review_token).unwrap();
        assert_eq!(accepted.status,"updated");
        let cached=self.cache.join(format!("{}.zip",review.archive_sha256));
        let cached_before=fs::read(&cached).unwrap();
        let repeat=api::review(&self.channel,&received).unwrap();
        assert_eq!(repeat.status,"unchanged","second reviewed identical ZIP should be idempotent");
        let repeated=api::import(&self.channel,&self.cache,&received,&repeat.review_token).unwrap();
        assert_eq!(repeated.status,"unchanged");
        assert_eq!(fs::read(&cached).unwrap(),cached_before,
            "idempotent import must not overwrite even a correctly verified cache");
        let raw=api::manifest(&self.channel,"synthetic-game",None).unwrap().unwrap();
        let manifest:Manifest=serde_json::from_str(&raw).unwrap();
        assert_eq!(manifest.version,version);
        assert!(cached.is_file());
        manifest
    }
    fn import_host(&self,fixture:&Fixture,version:&str)->Manifest{
        let host=fixture.host(version);
        use crate::services::catalog::test_api as api;
        let review=api::review(&self.channel,&host).unwrap();
        assert_eq!(review.new_version,version);
        if version=="1.0.0"{assert_eq!(review.mode,"new");}
        else{assert_eq!(review.mode,"update");}
        assert!(api::import(&self.channel,&self.cache,&host,&"x".repeat(64)).is_err(),
            "unreviewed token cannot cause a write");
        let outcome=api::import(&self.channel,&self.cache,&host,&review.review_token).unwrap();
        assert_eq!(outcome.status,"updated");
        let raw=api::manifest(&self.channel,"synthetic-game",None).unwrap().unwrap();
        let m:Manifest=serde_json::from_str(&raw).unwrap();
        validate_manifest(&m).unwrap();
        assert_eq!(m.version,version);
        assert!(api::catalog(&self.channel).iter().any(|e|e.id==m.id));
        m
    }
    fn user_files(&self)->Vec<(PathBuf,Vec<u8>)>{
        let files=[("saves/world/player.dat",b"World personal data".as_slice()),
            ("BepInEx/config/player.cfg",b"Custom config".as_slice()),
            ("mods/user-mod.jar",b"User mod".as_slice()),
            ("DistantHorizons/cache/dh.db",b"DH data".as_slice()),
            ("playerdata/custom.dat",b"Player data".as_slice())];
        files.iter().map(|(rel,bytes)|{
            let path=self.target.join(rel);fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path,bytes).unwrap();(path,bytes.to_vec())
        }).collect()
    }
    fn assert_user_files(&self,files:&[(PathBuf,Vec<u8>)]){
        for (path,contents) in files{assert_eq!(fs::read(path).unwrap(),*contents,"{}",path.display());}
    }
    fn launch(&self,entry:&crate::services::catalog::Experience,version:&str,delay:u64)->Child{
        let marker=self.root.join(format!("process-{version}-{delay}.marker"));
        let mut entry=entry.clone();
        entry.launch_arguments=vec![marker.to_string_lossy().into(),delay.to_string()];
        let child=crate::services::standalone::launch_synthetic_fixture(
            &entry,&self.app_data,&self.local_data,&self.target).unwrap();
        let timeout=Instant::now()+Duration::from_secs(8);
        while !marker.exists()&&Instant::now()<timeout{thread::sleep(Duration::from_millis(10));}
        assert_eq!(fs::read(marker).unwrap(),version.as_bytes());
        child
    }
    fn native_guard(&self,entry:&crate::services::catalog::Experience,prior_pid:Option<u32>)
        ->Result<(),String>{
        let report=crate::services::standalone::active_synthetic_profile(entry,&self.target,prior_pid);
        if report.status=="none"&&report.safe_to_update{Ok(())}
        else{Err(format!("Win32 process guard: {}",report.status))}
    }
}

#[test]
fn two_isolated_profiles_real_native_lifecycle_install_launch_close_upgrade_repair_crash_recover(){
    let fixture=Fixture::new();
    let (a,entry_a)=fixture.publish_synthetic("1.0.0");
    let (b,entry_b)=fixture.publish_synthetic("2.0.0");
    let p=fixture.profile("alice");
    let q=fixture.profile("bob");
    let token=AtomicBool::new(false);
    let guard=||Ok(());
    for profile in [&p,&q]{
        let accepted=profile.import_host(&fixture,"1.0.0");
        assert_eq!(accepted.archives[0].sha256,a.archives[0].sha256);
        let result=install_new(&accepted,&profile.target,&profile.cache,&token,|_,_,_,_|{}).unwrap();
        assert_eq!(result.status,"installed");
        assert_eq!(read_owned_receipt(&profile.target).unwrap()["version"],"1.0.0");
    }
    for profile in [&p,&q]{
        let accepted=profile.import_host(&fixture,"2.0.0");
        assert_eq!(accepted.archives[0].sha256,b.archives[0].sha256);
        let from_profile=crate::services::catalog::test_api::manifest(
            &profile.channel,"synthetic-game",Some("1.0.0")).unwrap().unwrap();
        let historical:Manifest=serde_json::from_str(&from_profile).unwrap();
        assert_eq!(historical.archives[0].sha256,a.archives[0].sha256);
        let provenance=crate::services::catalog::test_api::provenance(&profile.channel).unwrap();
        assert!(provenance.iter().any(|record|record.id==a.id));
    }
    // The test-only trusted-history adapter is populated from an ACTUAL
    // reviewed/imported channel snapshot, not a fabricated receipt. Production
    // uses the corresponding authenticated catalog::read_install_manifest_version.
    let old_manifest:Manifest=serde_json::from_str(&crate::services::catalog::test_api::manifest(
        &p.channel,"synthetic-game",Some("1.0.0")).unwrap().unwrap()).unwrap();
    test_with_authorized_baseline(&old_manifest,||{
        let original_a=p.user_files();let original_b=q.user_files();
        let active=Mutex::new(p.launch(&entry_a,"1.0.0",2500));
        let guard_running=||p.native_guard(&entry_a,None);
        // Real ToolHelp32Snapshot + QueryFullProcessImageNameW from production
        // guard, not a test boolean or fabricated process list.
        let guard_report=crate::services::standalone::active_synthetic_profile(&entry_a,&p.target,None);
        assert!(guard_report.game_ids.contains(&a.id));
        assert!(upgrade_internal(&b,&p.target,&p.cache,&token,&guard_running,|_,_,_,_|{}).is_err());
        fs::write(p.target.join("assets/runtime.dat"),b"synthetic-corrupt-while-active").unwrap();
        assert!(repair_internal(&a,&p.target,&p.cache,&token,true,&guard_running,|_,_,_,_|{}).is_err());
        assert_eq!(fs::read(p.target.join("assets/runtime.dat")).unwrap(),b"synthetic-corrupt-while-active");
        assert_eq!(read_owned_receipt(&p.target).unwrap()["version"],"1.0.0");
        active.lock().unwrap().wait().unwrap();
        assert_eq!(repair_internal(&a,&p.target,&p.cache,&token,true,&guard,|_,_,_,_|{}).unwrap().status,"repaired");
        // Catalog imports already staged both ZIPs into distinct verified
        // per-profile caches. Remove source to prove zero-network client use.
        fs::remove_file(fixture.host("2.0.0").join("game.zip")).unwrap();
        let changed=upgrade_internal(&b,&p.target,&p.cache,&token,&guard,|_,_,_,_|{}).unwrap();
        assert_eq!(changed.status,"upgraded");
        p.assert_user_files(&original_a);
        assert_eq!(read_owned_receipt(&q.target).unwrap()["version"],"1.0.0",
            "upgrading Alice never changes Bob's isolated profile");
        let mut child=p.launch(&entry_b,"2.0.0",60);assert!(child.wait().unwrap().success());

        assert!(q.cache.join(format!("{}.zip",b.archives[0].sha256)).is_file());
        // Abort after the first journaled rename, like a crash between file
        // updates; no automatic rollback runs on unwinding this worker.
        let crash=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||{
            repair_transaction::test_with_crash_after_change(1,||{
                let _=upgrade_internal(&b,&q.target,&q.cache,&token,&guard,|_,_,_,_|{});
            });
        }));
        assert!(crash.is_err());
        assert!(q.target.join(".coco/upgrade-transaction-v1/journal.json").is_file());
        let notices=pending_operations_at(&[entry_b.clone()],&q.app_data,&q.local_data);
        assert_eq!(notices.len(),1,"startup scan must detect interrupted upgrade");
        assert_eq!(notices[0].status,"recovery-required");
        assert_eq!(notices[0].kind,"upgrade");
        assert_eq!(notices[0].from_version.as_deref(),Some("1.0.0"));
        assert_eq!(notices[0].to_version.as_deref(),Some("2.0.0"));
        assert_eq!(read_owned_receipt(&q.target).unwrap()["version"],"1.0.0",
            "startup discovery cannot apply rollback itself");
        assert_eq!(repair_transaction::recover_upgrade(&b,&q.target,&guard,&mut |_,_,_,_|{}).unwrap(),
            "recovery-complete");
        assert!(pending_operations_at(&[entry_b.clone()],&q.app_data,&q.local_data).is_empty());
        assert_eq!(read_owned_receipt(&q.target).unwrap()["version"],"1.0.0");
        assert!(matches_digest(&q.target.join("game.exe"),a.required_files[0].size,
            &a.required_files[0].sha256,&token).unwrap());
        let recovered_upgrade=upgrade_internal(&b,&q.target,&q.cache,&token,&guard,|_,_,_,_|{}).unwrap();
        assert_eq!(recovered_upgrade.status,"upgraded",
            "verified cached ZIP upgrades without the original host ZIP");
        q.assert_user_files(&original_b);
        let mut child=q.launch(&entry_b,"2.0.0",60);assert!(child.wait().unwrap().success());

        // Repair real corrupt installed bytes from the verified local cache;
        // then crash mid-repair, recover original SHA and repair again.
        fs::write(p.target.join("game.exe"),b"corrupted executable").unwrap();
        assert_eq!(repair_internal(&b,&p.target,&p.cache,&token,true,&guard,|_,_,_,_|{}).unwrap().status,
            "repaired");
        p.assert_user_files(&original_a);
        assert!(matches_digest(&p.target.join("game.exe"),b.required_files[0].size,
            &b.required_files[0].sha256,&token).unwrap());
        fs::write(q.target.join("game.exe"),b"corrupt-before-repair").unwrap();
        let crash=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||{
            repair_transaction::test_with_crash_after_change(1,||{
                let _=repair_internal(&b,&q.target,&q.cache,&token,true,&guard,|_,_,_,_|{});
            });
        }));
        assert!(crash.is_err());
        assert!(q.target.join(".coco/repair-transaction-v1/journal.json").exists());
        let notices=pending_operations_at(&[entry_b.clone()],&q.app_data,&q.local_data);
        assert_eq!(notices.len(),1);
        assert_eq!(notices[0].kind,"repair");
        assert_eq!(repair_transaction::recover(&b,&q.target,&guard,&mut |_,_,_,_|{}).unwrap(),
            "recovery-complete");
        assert_eq!(fs::read(q.target.join("game.exe")).unwrap(),b"corrupt-before-repair");
        assert_eq!(repair_internal(&b,&q.target,&q.cache,&token,true,&guard,|_,_,_,_|{}).unwrap().status,
            "repaired");
        q.assert_user_files(&original_b);
        assert_eq!(read_owned_receipt(&q.target).unwrap()["version"],"2.0.0");
        assert_eq!(fs::read(q.target.join("assets/runtime.dat")).unwrap(),b"synthetic-asset-v2.0.0");
    });
}

#[test]
fn real_host_studio_a_b_portable_zip_direct_to_two_profiles_then_native_lifecycle(){
    use crate::services::catalog::test_api as api;
    let fixture=Fixture::new();
    let (a_fabricated,_)=fixture.publish_synthetic("1.0.0");
    let (_b_fabricated,_)=fixture.publish_synthetic("2.0.0");
    fixture.prepare_real_publisher();
    let (portable_a,source_a)=fixture.host_portable("1.0.0",false);
    assert!(portable_a.is_file());
    let original_a_sha=format!("{:x}",Sha256::digest(fs::read(&portable_a).unwrap()));
    let alice=fixture.profile("a");
    let bob=fixture.profile("b");
    let token=AtomicBool::new(false);
    let guard=||Ok(());
    let mut a_manifest=None;
    for profile in [&alice,&bob]{
        let imported=profile.import_portable(&portable_a,"1.0.0");
        assert_eq!(imported.archives[0].sha256,a_fabricated.archives[0].sha256);
        let install=install_new(&imported,&profile.target,&profile.cache,&token,|_,_,_,_|{}).unwrap();
        assert_eq!(install.status,"installed");
        assert_eq!(read_owned_receipt(&profile.target).unwrap()["version"],"1.0.0");
        a_manifest=Some(imported);
    }
    let a=a_manifest.unwrap();
    let entry_a=api::catalog(&alice.channel).into_iter()
        .find(|entry|entry.id==a.id).unwrap();
    let retained_alice=alice.user_files();
    let retained_bob=bob.user_files();
    let mut first=alice.launch(&entry_a,"1.0.0",50);
    assert!(first.wait().unwrap().success());
    // Only modify the synthetic Host Studio repository after A has been
    // separately transferred. This is the normal reviewed source promotion
    // needed before Host Studio authoring B as an UPDATE of A.
    let real_source=fixture.root.join("real-publisher/launcher/catalog.template.json");
    fs::copy(&source_a,&real_source).unwrap();
    let (portable_b,_)=fixture.host_portable("2.0.0",true);
    assert!(portable_b.is_file());
    let mut b_manifest=None;
    for profile in [&alice,&bob]{
        let imported=profile.import_portable(&portable_b,"2.0.0");
        assert_eq!(api::manifest(&profile.channel,&a.id,Some("1.0.0")).unwrap()
            .and_then(|raw|serde_json::from_str::<Manifest>(&raw).ok())
            .map(|m|m.version),Some("1.0.0".into()));
        b_manifest=Some(imported);
    }
    let b=b_manifest.unwrap();
    let entry_b=api::catalog(&alice.channel).into_iter()
        .find(|entry|entry.id==b.id).unwrap();
    assert_ne!(a.required_files[0].sha256,b.required_files[0].sha256);
    assert_eq!(format!("{:x}",Sha256::digest(fs::read(&portable_a).unwrap())),original_a_sha,
        "publishing B must not mutate A transfer bytes");
    // No source ZIP is needed after both clients have their own verified
    // content-addressed caches; keep all original user data intact.
    fs::remove_file(fixture.host("2.0.0").join("game.zip")).unwrap();
    let old:Manifest=serde_json::from_str(&api::manifest(
        &alice.channel,&a.id,Some("1.0.0")).unwrap().unwrap()).unwrap();
    test_with_authorized_baseline(&old,||{
        let upgraded=upgrade_internal(&b,&alice.target,&alice.cache,&token,&guard,|_,_,_,_|{}).unwrap();
        assert_eq!(upgraded.status,"upgraded");
        let mut running=alice.launch(&entry_b,"2.0.0",40);
        assert!(running.wait().unwrap().success());
        alice.assert_user_files(&retained_alice);
        let aborted=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||{
            repair_transaction::test_with_crash_after_change(1,||{
                let _=upgrade_internal(&b,&bob.target,&bob.cache,&token,&guard,|_,_,_,_|{});
            });
        }));
        assert!(aborted.is_err());
        assert_eq!(pending_operations_at(&[entry_b.clone()],&bob.app_data,&bob.local_data)[0].kind,"upgrade");
        assert_eq!(repair_transaction::recover_upgrade(&b,&bob.target,&guard,&mut |_,_,_,_|{}).unwrap(),"recovery-complete");
        assert_eq!(read_owned_receipt(&bob.target).unwrap()["version"],"1.0.0");
        assert_eq!(upgrade_internal(&b,&bob.target,&bob.cache,&token,&guard,|_,_,_,_|{}).unwrap().status,"upgraded");
        fs::write(bob.target.join("game.exe"),b"corrupt after official Host Studio ZIP transfer").unwrap();
        assert_eq!(repair_internal(&b,&bob.target,&bob.cache,&token,true,&guard,|_,_,_,_|{}).unwrap().status,"repaired");
        let mut child=bob.launch(&entry_b,"2.0.0",40);
        assert!(child.wait().unwrap().success());
        bob.assert_user_files(&retained_bob);
    });
}

/// Deliberately adversarial transfer variants. This helper belongs only to
/// tests: the client never extracts the portable ZIP manually or trusts these
/// bytes before native catalog::test_api validation.
fn tamper_portable(source:&Path,destination:&Path,attack:&str){
    let mut original=zip::ZipArchive::new(File::open(source).unwrap()).unwrap();
    let mut writer=zip::ZipWriter::new(File::create(destination).unwrap());
    let options=SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    let mut original_game=None;
    for i in 0..original.len(){
        let mut member=original.by_index(i).unwrap();
        let name=member.name().to_owned();
        let mut data=Vec::new();member.read_to_end(&mut data).unwrap();
        if name=="game.zip"{original_game=Some(data.clone());}
        match attack{
            "metadata" if name=="publish-manifest.json"=>{
                let mut json:serde_json::Value=serde_json::from_slice(&data).unwrap();
                json["reviewedRights"]=false.into();
                data=serde_json::to_vec(&json).unwrap();
            },
            "archive-sha" if name=="game.zip"=>{
                let mid=data.len()/2;data[mid]^=0x20;
            },
            "cover-sha" if name=="cover.png"=>{
                data.extend_from_slice(b"tampering-after-Host-Studio-seal");
            },
            _=>{},
        }
        writer.start_file(name,options).unwrap();
        writer.write_all(&data).unwrap();
    }
    match attack{
        "foreign-file"=>{
            writer.start_file("unsigned-foreign.txt",options).unwrap();
            writer.write_all(b"foreign transport artifact").unwrap();
        },
        "duplicate-name"=>{
            // zip::ZipWriter deliberately refuses an exact duplicate; write
            // a case-alias, then change both archive header filenames in the
            // finalized ZIP without changing sizes/offsets to model a forged
            // ZIP with two literally identical central-directory names.
            writer.start_file("GAME.ZIP",options).unwrap();
            writer.write_all(original_game.as_ref().unwrap()).unwrap();
        },
        "case-alias"=>{
            writer.start_file("GAME.ZIP",options).unwrap();
            writer.write_all(original_game.as_ref().unwrap()).unwrap();
        },
        "traversal"=>{
            writer.start_file("../outside.txt",options).unwrap();
            writer.write_all(b"do not extract").unwrap();
        },
        _=>{},
    }
    writer.finish().unwrap();
    if attack=="duplicate-name"{
        let mut bytes=fs::read(destination).unwrap();
        let mut matches=0;
        for index in 0..bytes.len().saturating_sub(b"GAME.ZIP".len()-1){
            if &bytes[index..index+8]==b"GAME.ZIP"{
                bytes[index..index+8].copy_from_slice(b"game.zip");
                matches+=1;
            }
        }
        assert_eq!(matches,2,"must forge both local and central directory filenames");
        fs::write(destination,bytes).unwrap();
    }
    if attack=="truncated"{
        let size=fs::metadata(destination).unwrap().len();
        OpenOptions::new().write(true).open(destination).unwrap()
            .set_len(size/2).unwrap();
    }
}

#[test]
fn portable_zip_invalid_transport_and_metadata_do_not_install_or_touch_other_profiles(){
    use crate::services::catalog::test_api as api;
    let fixture=Fixture::new();
    fixture.publish_synthetic("1.0.0");
    fixture.prepare_real_publisher();
    let (portable,_)=fixture.host_portable("1.0.0",false);
    let reference=fs::read(&portable).unwrap();
    let clean=fixture.profile("clean");
    let original_catalog=api::catalog(&clean.channel);
    assert!(original_catalog.iter().all(|entry|entry.id!="synthetic-game"));
    for attack in ["metadata","archive-sha","cover-sha","foreign-file",
        "duplicate-name","case-alias","traversal","truncated"]{
        let received=clean.root.join(format!("{attack}.coco2pack.zip"));
        tamper_portable(&portable,&received,attack);
        assert!(api::review(&clean.channel,&received).is_err(),
            "adversarial ZIP '{attack}' was accepted for review");
        assert!(!clean.cache.exists(),"failed review must not seed game cache: {attack}");
        assert!(!clean.target.exists(),"failed review must not install any game: {attack}");
        assert_eq!(fs::read(&portable).unwrap(),reference,
            "bad transfer must not alter immutable original package");
        assert!(api::catalog(&clean.channel).iter().all(|entry|entry.id!="synthetic-game"));
    }
    assert!(!clean.root.join("outside.txt").exists());
}

#[test]
fn portable_zip_cannot_replace_signed_official_catalog_or_steal_its_revision(){
    use crate::services::catalog::test_api as api;
    use ring::signature::{Ed25519KeyPair,KeyPair};
    let fixture=Fixture::new();
    fixture.publish_synthetic("1.0.0");
    fixture.publish_synthetic("2.0.0");
    fixture.prepare_real_publisher();
    let (portable_a,source_a)=fixture.host_portable("1.0.0",false);
    let client=fixture.profile("s");
    client.import_portable(&portable_a,"1.0.0");
    let accepted_before=api::provenance(&client.channel).unwrap();
    assert!(accepted_before.iter().any(|p|p.id=="synthetic-game"&&p.source=="local"));
    let signer=Ed25519KeyPair::from_seed_unchecked(&[59u8;32]).unwrap();
    let mut key=[0u8;32];key.copy_from_slice(signer.public_key().as_ref());
    let draft=api::channel_draft(source_a.parent().unwrap(),&client.channel,
        &client.root.join("official-channel-draft")).unwrap();
    let channel=fs::read(&draft.channel_draft_path).unwrap();
    let signature=base64::Engine::encode(&base64::engine::general_purpose::STANDARD,
        signer.sign(&channel).as_ref());
    assert_eq!(api::apply_signed(&client.channel,&channel,signature.as_bytes(),&key).unwrap().status,"updated");
    let accepted=api::provenance(&client.channel).unwrap();
    assert!(accepted.iter().any(|p|p.id=="synthetic-game"&&p.source=="official"));
    let prior=api::manifest(&client.channel,"synthetic-game",None).unwrap().unwrap();
    let received=client.root.join("unsigned-attempt.coco2pack.zip");
    fs::copy(&portable_a,&received).unwrap();
    assert!(api::review(&client.channel,&received).is_err(),
        "unsigned identical portable package cannot displace signed official entry");
    assert_eq!(api::manifest(&client.channel,"synthetic-game",None).unwrap().unwrap(),prior);
    let real_source=fixture.root.join("real-publisher/launcher/catalog.template.json");
    fs::copy(&source_a,&real_source).unwrap();
    let (portable_b,_)=fixture.host_portable("2.0.0",true);
    let unsigned_b=client.root.join("unsigned-b.coco2pack.zip");
    fs::copy(&portable_b,&unsigned_b).unwrap();
    assert!(api::review(&client.channel,&unsigned_b).is_err(),
        "unsigned newer B cannot override signed official A");
    assert_eq!(api::manifest(&client.channel,"synthetic-game",None).unwrap().unwrap(),prior);
}

#[test]
fn cache_preexisting_corrupt_zip_and_partial_are_never_modified_or_deleted(){
    let fixture=Fixture::new();
    let (manifest,_)=fixture.publish_synthetic("1.0.0");
    let profile=fixture.profile("cache-adversarial");
    fs::create_dir_all(&profile.cache).unwrap();
    let client=reqwest::blocking::Client::builder().build().unwrap();
    let spec=&manifest.archives[0];
    let final_cache=profile.cache.join(format!("{}.zip",spec.sha256));
    let partial=profile.cache.join(format!("{}.zip.partial",spec.sha256));
    fs::write(&final_cache,b"user-owned wrong archive bytes").unwrap();
    fs::write(&partial,b"user-owned partial bytes").unwrap();
    let result=download_one(spec,&profile.cache,&client,&AtomicBool::new(false),|_|{});
    assert!(result.unwrap_err().contains("Conflicto"));
    assert_eq!(fs::read(&final_cache).unwrap(),b"user-owned wrong archive bytes");
    assert_eq!(fs::read(&partial).unwrap(),b"user-owned partial bytes");
    assert!(!profile.target.exists());

    fs::remove_file(&final_cache).unwrap(); // only our explicitly owned test artifact
    // The existing partial cannot be truncated/removed even when it is not
    // the correct SHA prefix. File-backed synthetic source uses fresh private
    // staging, then publishes only complete verified bytes.
    let mut from_file=spec.clone();
    from_file.url=reqwest::Url::from_file_path(fixture.host("1.0.0").join("game.zip"))
        .unwrap().to_string();
    let result=download_one(&from_file,&profile.cache,&client,&AtomicBool::new(false),|_|{}).unwrap();
    assert_eq!(result,final_cache);
    assert_eq!(fs::read(&partial).unwrap(),b"user-owned partial bytes");
    assert!(matches_digest(&final_cache,spec.size,&spec.sha256,&AtomicBool::new(false)).unwrap());
    assert!(!profile.target.exists());
}

#[test]
fn broken_offline_source_preserves_existing_partial_and_never_creates_installation(){
    let fixture=Fixture::new();
    let (mut manifest,_)=fixture.publish_synthetic("1.0.0");
    let profile=fixture.profile("source-failure");
    fs::create_dir_all(&profile.cache).unwrap();
    manifest.archives[0].url=reqwest::Url::from_file_path(fixture.root.join("nonexistent.zip"))
        .unwrap().to_string();
    let partial=profile.cache.join(format!("{}.zip.partial",manifest.archives[0].sha256));
    fs::write(&partial,b"private external partial").unwrap();
    let failed=install_new(&manifest,&profile.target,&profile.cache,&AtomicBool::new(false),|_,_,_,_|{});
    assert!(failed.is_err(),"offline missing source must not attempt network");
    assert_eq!(fs::read(&partial).unwrap(),b"private external partial");
    assert!(!profile.target.exists());
}

#[test]
fn real_win32_detached_child_outside_game_root_remains_attributed_after_launcher_exit(){
    let fixture=Fixture::new();
    let (manifest,entry)=fixture.publish_synthetic("1.0.0");
    // Keep the Win32 synthetic profile path short for MoveFileW MAX_PATH.
    let p=fixture.profile("o");
    p.import_host(&fixture,"1.0.0");
    assert_eq!(install_new(&manifest,&p.target,&p.cache,&AtomicBool::new(false),|_,_,_,_|{}).unwrap().status,"installed");
    let external=fixture.root.join("test-only-child-outside-root.exe");
    fs::copy(p.target.join("game.exe"),&external).unwrap();
    let marker=p.root.join("launcher-started.marker");
    let child_marker=p.root.join("detached-child-started.marker");
    let mut launch=entry.clone();
    launch.launch_arguments=vec![marker.display().to_string(),"2800".into(),
        external.display().to_string(),child_marker.display().to_string()];
    let mut parent=crate::services::standalone::launch_synthetic_fixture(
        &launch,&p.app_data,&p.local_data,&p.target).unwrap();
    let launcher_pid=parent.id();
    assert!(parent.wait().unwrap().success(),"real wrapper exits after spawning test child");
    let deadline=Instant::now()+Duration::from_secs(5);
    while !child_marker.exists()&&Instant::now()<deadline {thread::sleep(Duration::from_millis(10));}
    assert_eq!(fs::read(&child_marker).unwrap(),b"1.0.0");
    let report=crate::services::standalone::active_synthetic_profile(&entry,&p.target,Some(launcher_pid));
    assert!(report.game_ids.contains(&entry.id),"detached child outside game root must remain attributable: {report:?}");
    assert!(!report.safe_to_update);
    let guard=||p.native_guard(&entry,Some(launcher_pid));
    // Both upgrade and repair must refuse a *real* detached child of an exited
    // launcher, even when the child's executable resides outside the game root.
    let (newer,_)=fixture.publish_synthetic("2.0.0");
    p.import_host(&fixture,"2.0.0");
    assert!(guard().is_err(),"real detached Win32 child must forbid both native mutations");
    test_with_authorized_baseline(&manifest,||{
        assert!(upgrade_internal(&newer,&p.target,&p.cache,&AtomicBool::new(false),&guard,|_,_,_,_|{}).is_err());
    });
    fs::write(p.target.join("assets/runtime.dat"),b"corrupted-while-detached-child-alive").unwrap();
    assert!(repair_internal(&manifest,&p.target,&p.cache,&AtomicBool::new(false),true,&guard,|_,_,_,_|{}).is_err());
    // Child is a test-only synthetic process; wait naturally for its own exit.
    let deadline=Instant::now()+Duration::from_secs(6);
    loop{
        let present=crate::services::standalone::synthetic_process_is_running(&external);
        if !present{break;}
        assert!(Instant::now()<deadline,"test child did not exit cleanly");
        thread::sleep(Duration::from_millis(50));
    }
}

/// Real TCP/HTTP over 127.0.0.1 only. The production downloader cannot accept
/// HTTP: this fixture URL allowance exists under cfg(test) exclusively.
fn http_fixture(payload:Vec<u8>,mode:&'static str)
    ->(ArchiveSpec,Arc<AtomicBool>,thread::JoinHandle<Vec<u64>>){
    use std::io::{Read,Write};
    let server=TcpListener::bind("127.0.0.1:0").unwrap();
    server.set_nonblocking(true).unwrap();
    let address=server.local_addr().unwrap();
    let shutdown=Arc::new(AtomicBool::new(false));
    let done=Arc::clone(&shutdown);
    let spec=ArchiveSpec{url:format!("http://127.0.0.1:{}/test.zip",address.port()),
        size:payload.len() as u64,sha256:format!("{:x}",Sha256::digest(&payload))};
    let worker=thread::spawn(move||{
        let mut requests=Vec::new();
        while !done.load(Ordering::SeqCst){
            let Ok((mut stream,_))=server.accept() else{
                thread::sleep(Duration::from_millis(5));continue;
            };
            // WinSock can inherit O_NONBLOCK from a nonblocking TcpListener.
            // The test server must read a complete request as blocking I/O;
            // otherwise WouldBlock is mistaken for an incomplete Range header.
            stream.set_nonblocking(false).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            // TCP is a byte stream, not a message boundary. A single `read`
            // can return before the Range header arrives under concurrent
            // Rust tests, incorrectly recording an implicit start=0 even if
            // the real client requested bytes=32768-. Read ALL HTTP headers.
            let mut header=Vec::new();
            let mut chunk=[0u8;2048];
            while !header.windows(4).any(|bytes|bytes==b"\r\n\r\n") {
                let n=match stream.read(&mut chunk){
                    Ok(n)=>n,
                    Err(error) if matches!(error.kind(),std::io::ErrorKind::WouldBlock|std::io::ErrorKind::Interrupted)=>continue,
                    Err(error)=>panic!("localhost request headers: {error}"),
                };
                assert!(n>0,"localhost request closed before end of headers");
                header.extend_from_slice(&chunk[..n]);
                assert!(header.len()<=8192,"unexpectedly long HTTP test request");
            }
            let text=String::from_utf8_lossy(&header);
            let range=text.lines().filter_map(|line|line.split_once(':'))
                .find(|(key,_)|key.eq_ignore_ascii_case("range"))
                .and_then(|(_,value)|value.trim().strip_prefix("bytes="));
            // These tests specifically require the REAL HTTP Range protocol.
            // Never silently default to byte 0 when parsing is incomplete.
            let (start,end)=range.and_then(|value|value.split_once('-'))
                .and_then(|(a,b)|Some((a.parse::<u64>().ok()?,b.parse::<u64>().ok()?)))
                .unwrap_or_else(||panic!("HTTP test request has no valid Range header: {text}"));
            requests.push(start);
            if mode=="timeout"{thread::sleep(Duration::from_millis(260));continue;}
            if mode=="not-found"{
                let _=stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                continue;
            }
            let etag=if mode=="etag-switch"&&requests.len()>1{"\"different\""}else{"\"stable\""};
            let start=start.min(payload.len() as u64);
            let end=end.min(payload.len() as u64-1);
            let body=if start<=end{&payload[start as usize..=end as usize]}else{&[]};
            let response=format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{}\r\nContent-Length: {}\r\nETag: {etag}\r\nConnection: close\r\n\r\n",payload.len(),body.len());
            if stream.write_all(response.as_bytes()).is_ok(){let _=stream.write_all(body);}
        }
        requests
    });
    (spec,shutdown,worker)
}

#[test]
fn loopback_http_206_resume_and_changed_etag_recovery_404_timeout_stay_sha_verified(){
    let fixture=Fixture::new();
    let bytes=(0..110_000usize).map(|n|(n%251) as u8).collect::<Vec<_>>();
    let client=reqwest::blocking::Client::builder().connect_timeout(Duration::from_millis(200))
        .timeout(Duration::from_millis(100)).build().unwrap();
    let token=AtomicBool::new(false);
    // A single ETag rotation is now recoverable only by restarting the
    // private byte stream at zero, then validating the complete SHA. A 404 or
    // persistent timeout still never publishes a cache artifact.
    for (mode,should_succeed) in [("ok",true),("etag-switch",true),
        ("not-found",false),("timeout",false)]{
        let profile=fixture.profile(mode);
        let (spec,stop,server)=http_fixture(bytes.clone(),mode);
        let result=download_one(&spec,&profile.cache,&client,&token,|_|{});
        stop.store(true,Ordering::SeqCst);
        let requests=server.join().unwrap();
        assert!(!requests.is_empty(),"{mode} must issue an actual HTTP request");
        assert_eq!(result.is_ok(),should_succeed,"{mode}: {result:?}");
        if should_succeed{
            assert!(requests.len()>1,"real 206 requests must be chunked in test");
            if mode=="etag-switch"{
                assert!(requests.windows(2).any(|pair|pair[0]>0&&pair[1]==0),
                    "ETag change must discard the in-flight private bytes and restart at zero: {requests:?}");
            }
            assert_eq!(fs::read(result.unwrap()).unwrap(),bytes);
        }else{
            assert!(!profile.cache.join(format!("{}.zip",spec.sha256)).exists(),
                "{mode} must never publish an unverified final artifact");
        }
    }
    let profile=fixture.profile("resume");
    fs::create_dir_all(&profile.cache).unwrap();
    let (spec,stop,server)=http_fixture(bytes.clone(),"ok");
    let partial=profile.cache.join(format!("{}.zip.partial",spec.sha256));
    fs::write(&partial,&bytes[..32*1024]).unwrap();
    let result=download_one(&spec,&profile.cache,&client,&token,|_|{}).unwrap();
    stop.store(true,Ordering::SeqCst);
    let requests=server.join().unwrap();
    assert_eq!(requests[0],(32*1024) as u64,"real HTTP Range resumes at partial length");
    assert_eq!(fs::read(&partial).unwrap(),bytes[..32*1024]);
    assert_eq!(fs::read(result).unwrap(),bytes);
}

#[test]
fn live_windows_file_lock_and_unsafe_startup_journal_fail_closed_without_data_writes(){
    use std::os::windows::fs::OpenOptionsExt;
    let fixture=Fixture::new();
    let (a,_)=fixture.publish_synthetic("1.0.0");
    let (b,_)=fixture.publish_synthetic("2.0.0");
    let p=fixture.profile("l");
    p.import_host(&fixture,"1.0.0");
    p.import_host(&fixture,"2.0.0");
    let token=AtomicBool::new(false);
    let guard=||Ok(());
    assert_eq!(install_new(&a,&p.target,&p.cache,&token,|_,_,_,_|{}).unwrap().status,"installed");
    let user=p.user_files();
    fs::write(p.target.join("assets/runtime.dat"),b"corrupted-asset").unwrap();
    let lock=OpenOptions::new().read(true).share_mode(0)
        .open(p.target.join("assets/runtime.dat")).unwrap();
    assert!(repair_internal(&a,&p.target,&p.cache,&token,true,&guard,|_,_,_,_|{}).is_err());
    assert!(!p.target.join(".coco/repair-transaction-v1").exists());
    drop(lock);
    assert_eq!(repair_internal(&a,&p.target,&p.cache,&token,true,&guard,|_,_,_,_|{}).unwrap().status,"repaired");
    test_with_authorized_baseline(&a,||{
        let lock=OpenOptions::new().read(true).share_mode(0).open(p.target.join("game.exe")).unwrap();
        assert!(upgrade_internal(&b,&p.target,&p.cache,&token,&guard,|_,_,_,_|{}).is_err());
        assert!(!p.target.join(".coco/upgrade-transaction-v1").exists());
        drop(lock);
    });
    p.assert_user_files(&user);
    assert_eq!(read_owned_receipt(&p.target).unwrap()["version"],"1.0.0");
    // A fabricated startup journal is never recovered/deleted automatically.
    let fake=p.target.join(".coco/upgrade-transaction-v1");
    fs::create_dir(&fake).unwrap();
    fs::write(fake.join("journal.json"),b"{\"schema\":1,\"foreign\":true}").unwrap();
    let entry=crate::services::catalog::test_api::catalog(&p.channel).into_iter()
        .find(|entry|entry.id==a.id).unwrap();
    let status=pending_operations_at(&[entry],&p.app_data,&p.local_data);
    assert_eq!(status.len(),1);
    assert_eq!(status[0].status,"blocked-unsafe");
    assert!(fake.join("journal.json").is_file());
    p.assert_user_files(&user);
}
