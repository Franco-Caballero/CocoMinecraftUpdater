/**
 * Native Coco2 standalone v9 safety/progress contract. No release build, no
 * installed GUI, no HKCU or personal game paths. Full synthetic Windows Rust
 * TEMP E2E requires explicitly:
 *   $env:COCO2_INSTALL_RESILIENCE_V9_E2E='1'
 *   node --test tests/install-resilience-v9.test.mjs
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const native=join(desktop,'src-tauri');
const read=file=>readFile(join(desktop,file),'utf8');
const source=()=>read('src-tauri/src/services/install.rs');

test('original Tauri command/event interfaces and durable repair journal remain wired',async()=>{
  const [impl,app]=await Promise.all([source(),read('src-tauri/src/lib.rs')]);
  for(const name of [
    'plan_standalone_install','install_standalone','cancel_standalone_install',
    'plan_standalone_repair','prepare_standalone_repair','commit_standalone_repair',
    'recover_standalone_repair','get_standalone_repair_recovery_status',
    'plan_standalone_upgrade','upgrade_standalone','recover_standalone_upgrade',
    'recover_pending_standalone_operations',
  ]){
    assert.match(impl,new RegExp('(?:pub async fn|pub fn) '+name+'\\('));
    assert.ok(app.includes('services::install::'+name),name+' Tauri registration must be preserved');
  }
  assert.match(impl,/const PROGRESS_EVENT: &str = "coco2:\/\/standalone-install-progress";/);
  assert.match(impl,/struct InstallProgress \{/);
  for(const field of ['downloaded_bytes: u64','total_bytes: u64','percent: u8']){
    assert.ok(impl.includes(field),'existing progress field '+field+' must be preserved');
  }
  assert.match(impl,/fn guard_game_processes\(app:&AppHandle\)->Result<\(\),String>/);
  assert.match(impl,/repair_transaction::commit\(/);
  assert.match(impl,/repair_transaction::upgrade\(/);
  assert.match(impl,/repair_transaction::recover\(/);
});

test('full SHA-256 and Win32 no-write/no-delete pins persist through staging/repair/upgrade',async()=>{
  const impl=await source();
  assert.match(impl,/struct PinnedArchiveSources \{/);
  assert.match(impl,/fn pin_verified_archives\(paths: &\[PathBuf\], specs: &\[ArchiveSpec\], token: &AtomicBool\)/);
  assert.match(impl,/FILE_FLAG_BACKUP_SEMANTICS \| FILE_FLAG_OPEN_REPARSE_POINT/);
  assert.match(impl,/options\.read\(true\)\.share_mode\(SHARE_READ_WRITE\)/);
  assert.match(impl,/options\.share_mode\(0x0000_0001\)/);
  assert.match(impl,/ZIP de caché cambió tras SHA-256; instalación no confirmada/);
  assert.match(impl,/let _pinned_archives = pin_verified_archives\(&all_archives, &expected_zip_sources\(m\), token\)\?/);
  assert.match(impl,/let _pinned_archives = pin_verified_archives\(&sources, &expected_zip_sources\(m\), token\)\?/);
  assert.match(impl,/let _pinned_archives=pin_verified_archives\(&sources,&expected_zip_sources\(m\),token\)\?/);
  assert.match(impl,/pinned_unicode_zip_cache_denies_concurrent_writes_rename_and_same_size_asset_spoof/);
});

test('install repair upgrade now emit actual bounded uncompressed bytes and can cancel mid-file',async()=>{
  const impl=await source();
  assert.match(impl,/fn extract_archive\(source: &Path, stage: &Path, token: &AtomicBool,/);
  assert.match(impl,/on_bytes\(&entry\.name, extracted\)/);
  assert.match(impl,/fn extract_archives_with_progress\(/);
  assert.match(impl,/let bucket = if expected_bytes == 0 \{ 0 \}/);
  assert.match(impl,/last_bucket != Some\(bucket\) \|\| done == expected_bytes/);
  assert.match(impl,/if completed != expected_bytes \{/);
  for(const phase of ['extracting','repair-extracting','upgrade-extracting']){
    assert.ok(impl.includes('"'+phase+'",&mut progress)?'),phase+' must use genuine byte progress');
  }
  assert.match(impl,/extraction_progress_counts_real_uncompressed_bytes_and_can_cancel_in_single_file/);
  assert.match(impl,/if done>0 \{stopped\.store\(true,Ordering::Relaxed\);\}/);
});

test('existing no-overwrite/recovery safeguards remain and synthetic tests protect personal data',async()=>{
  const impl=await source();
  assert.match(impl,/fn publish_stage\(stage: &Path, target: &Path\) -> Result<\(\), String>/);
  assert.match(impl,/fn write_install_receipt\(/);
  assert.match(impl,/let _guard=ActiveGuard/);
  assert.match(impl,/if !jobs\.is_empty\(\)/);
  assert.match(impl,/fn immutable_extra_files\(/);
  assert.match(impl,/repair_cancellation_removes_stage_and_never_changes_instance/);
  assert.match(impl,/offline_repair_preparation_preserves_saves_dh_config_and_old_executable/);
  assert.match(impl,/commit_never_replaces_an_instance_created_in_parallel/);
  assert.match(impl,/fs::remove_dir_all\(root\)\.unwrap\(\)/);
});

test('native Rust standalone TEMP synthetic tests (parallel and no production/network)',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_RESILIENCE_V9_E2E==='1'
    ? false : 'Opt-in Windows only: COCO2_INSTALL_RESILIENCE_V9_E2E=1',
  timeout:150_000,
},async t=>{
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=16',
  ],{cwd:native,windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=bytes=>{output=(output+bytes.toString()).slice(-65000);};
  cargo.stdout.on('data',collect);
  cargo.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;cargo.kill();},135000);
  const result=await new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Rust synthetic install tests timed out:\n'+output);
  assert.equal(result.code,0,'Rust synthetic install tests failed:\n'+output);
  for(const name of [
    'pinned_unicode_zip_cache_denies_concurrent_writes_rename_and_same_size_asset_spoof',
    'extraction_progress_counts_real_uncompressed_bytes_and_can_cancel_in_single_file',
    'installs_local_fixture_atomically_and_refuses_existing_instance',
    'repair_cancellation_removes_stage_and_never_changes_instance',
    'stage_installs_verified_zip_extras_and_records_immutable_expansion',
  ])assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Only test-owned ZIPs in TEMP; no installed GUI, HKCU, app data or external network');
});
