/**
 * Coco2 Host Studio portable v14. No game/GUI/NSIS, registry, Defender config,
 * user paths, network or published assets. Source guards run by default.
 * Opt-in native Windows synthetic filesystem E2E:
 *   COCO2_HOST_PORTABLE_V14_E2E=1 node --test tests/host-portable-resilience-v14.test.mjs
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=join(desktop,'src-tauri');
const source=()=>readFile(join(rust,'src','services','host_publish.rs'),'utf8');

test('outer game.zip is ZIP64-capable before writing any content',async()=>{
  const code=await source();
  assert.match(code,/fn portable_member_options\(is_game_zip:bool\)/);
  assert.match(code,/\.compression_method\(zip::CompressionMethod::Stored\)/);
  assert.match(code,/\.large_file\(is_game_zip\)/);
  assert.match(code,/let opts=portable_member_options\(false\)/);
  assert.match(code,/writer\.start_file\("game\.zip",portable_member_options\(true\)\)/);
  assert.match(code,/portable_outer_game_zip_supports_zip64_past_four_gib_without_real_disk_usage/);
  assert.match(code,/struct VirtualZipSink/);
  assert.match(code,/for _ in 0\.\.4_097/);
  assert.doesNotMatch(code,/\.compression_method\(zip::CompressionMethod::Deflated\)/);
});

test('failure cleanup retries only its exact private stage with bounded waits',async()=>{
  const code=await source();
  const start=code.indexOf('struct PortableStageCleanup(PathBuf);');
  const end=code.indexOf('/// The extension',start);
  assert.ok(start>=0&&end>start);
  const cleanup=code.slice(start,end);
  assert.match(cleanup,/impl Drop for PortableStageCleanup/);
  assert.match(cleanup,/for attempt in 0\.\.12/);
  assert.match(cleanup,/no_links\(&self\.0\)\.is_err\(\)/);
  assert.match(cleanup,/fs::remove_dir_all\(&self\.0\)/);
  assert.match(cleanup,/Duration::from_millis\(35\)/);
  assert.match(code,/let stage=create_stage\(destination_parent,id\)\?/);
  assert.match(code,/let _retry_cleanup=PortableStageCleanup\(stage\.0\.clone\(\)\)/);
  assert.match(code,/transient_reader_lock_does_not_leave_partial_portable_stage/);
});

test('save-as remains local, atomic, verified and refuses concurrent overwrite',async()=>{
  const code=await source();
  assert.match(code,/selected\.starts_with\(r"\\\\"\)/);
  assert.match(code,/windows_device_filename\(name\)/);
  assert.match(code,/fn pin_portable_parent\(parent: &Path\)/);
  assert.match(code,/FILE_FLAG_OPEN_REPARSE_POINT/);
  assert.match(code,/let mut archive=open_local_source\(&zip_path\)\?/);
  assert.match(code,/if copied!=archive_size\|\|format!\("\{:x\}",actual\.finalize\(\)\)!=archive_sha/);
  assert.match(code,/let mut delivered=open_staged_portable_for_verification\(&temp\)\?/);
  assert.match(code,/pinned_parent\.check\(\)\?/);
  assert.match(code,/pinned_stage\.check\(\)\?/);
  assert.match(code,/rename_no_replace\(&temp,&dest\)\?/);
  assert.match(code,/two_concurrent_save_as_writers_commit_once_and_preserve_other_artifacts/);
  assert.match(code,/portable_export_rejects_same_size_zip_mutation_without_destination_or_staging/);
  assert.match(code,/status:"exported-local-untrusted-unpublished"/);
  assert.doesNotMatch(code,/Command::new\("(?:powershell|reg|cmd|msiexec)"\)|HKEY_CURRENT_USER/i);
});

test('Rust synthetic native portable E2E for ZIP64, races and locked cleanup',{
  skip:process.platform==='win32'&&process.env.COCO2_HOST_PORTABLE_V14_E2E==='1'
    ? false : 'Opt-in Windows native TEMP suite only: COCO2_HOST_PORTABLE_V14_E2E=1',
  timeout:180_000,
},async t=>{
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib','services::import::host_publish::tests',
    '--','--test-threads=1',
  ],{
    cwd:rust,windowsHide:true,shell:false,stdio:['ignore','pipe','pipe'],
    env:{...process.env},
  });
  let stdout='',stderr='',timedOut=false;
  cargo.stdout.on('data',chunk=>{stdout=(stdout+chunk.toString()).slice(-80_000);});
  cargo.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-60_000);});
  const watchdog=setTimeout(()=>{timedOut=true;if(cargo.pid)cargo.kill();},150_000);
  let status;
  try{
    status=await new Promise((resolve,reject)=>{
      cargo.once('error',reject);
      cargo.once('close',(code,signal)=>resolve({code,signal}));
    });
  }finally{clearTimeout(watchdog);}
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'Native synthetic Host Studio test timed out:\n'+output.slice(-8_000));
  assert.equal(status.code,0,'Synthetic Rust publisher tests failed:\n'+output.slice(-14_000));
  for(const name of [
    'portable_outer_game_zip_supports_zip64_past_four_gib_without_real_disk_usage',
    'transient_reader_lock_does_not_leave_partial_portable_stage',
    'portable_export_rejects_same_size_zip_mutation_without_destination_or_staging',
    'two_concurrent_save_as_writers_commit_once_and_preserve_other_artifacts',
    'portable_export_detects_late_competing_writer_cleans_stage_and_can_retry',
    'portable_save_as_rejects_windows_devices_and_preserves_unicode_names',
  ]){
    assert.match(output,new RegExp(name+' \\.\\.\\. ok'),`missing passing Rust proof: ${name}`);
  }
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Native Cargo unit-test EXE only; sparse virtual 4GiB ZIP and synthetic TEMP files');
});
