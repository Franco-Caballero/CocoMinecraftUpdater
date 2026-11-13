/**
 * Host Studio Save As QA contract. Default: offline source checks, no app/GUI
 * or installer execution. Explicit native opt-in only runs Rust unit-test EXE
 * with synthetic packages rooted in test-owned TEMP folders:
 *   COCO2_HOST_PUBLISH_GUARD_E2E=1 node --test tests/host-publish-guard-v6.test.mjs
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const native=join(desktop,'src-tauri');
const source=()=>readFile(join(native,'src','services','host_publish.rs'),'utf8');

test('Save As pins local ancestor directories and detects reparse changes before atomic commit',async()=>{
  const code=await source();
  assert.match(code,/selected\.starts_with\(r"\\\\"\)/,'reject UNC and device paths');
  assert.match(code,/selected\.starts_with\("\/\/"\)/);
  assert.match(code,/fn pin_portable_parent\(parent: &Path\)/);
  assert.match(code,/FILE_FLAG_OPEN_REPARSE_POINT/);
  assert.match(code,/FILE_FLAG_BACKUP_SEMANTICS/);
  assert.match(code,/FILE_SHARE_READ_WRITE: u32 = 0x0000_0003/,
    'directory handles must deny DELETE/rename while preserving reads/writes');
  assert.match(code,/pinned\.file_attributes\(\)\s*&\s*0x400/);
  assert.match(code,/let pinned=pin_portable_parent\(parent\)\?/,
    'pin Save As original parent before canonicalizing');
  assert.match(code,/let \(dest,pinned_parent\)=portable_destination\(&trusted_parent,directory,destination_path\)\?/);
  assert.match(code,/pinned_parent\.check\(\)\?/);
  assert.match(code,/rename_no_replace\(&temp,&dest\)\?/);
  assert.ok(code.indexOf('pinned_parent.check()?')<code.indexOf('rename_no_replace(&temp,&dest)?'));
});

test('destination publication preserves payload while racing a competitor, and cleans failed stage',async()=>{
  const code=await source();
  assert.match(code,/fn open_staged_portable_for_verification\(path: &Path\)/);
  assert.match(code,/options\.share_mode\(0x0000_0001 \| 0x0000_0004\)/,
    'verification handle must deny writers but permit rename');
  const hold=code.indexOf('let mut delivered=open_staged_portable_for_verification(&temp)?');
  const commit=code.indexOf('rename_no_replace(&temp,&dest)?');
  const release=code.indexOf('drop(delivered)');
  assert.ok(hold>=0&&commit>hold&&release>commit,
    'hold verified read-only handle through final atomic rename');
  assert.match(code,/let stage=create_stage\(destination_parent,id\)\?/);
  assert.match(code,/let pinned_stage=pin_portable_parent\(&stage\.0\)\?/,
    'the private stage must also resist rename/substitution');
  assert.match(code,/pinned_stage\.check\(\)\?/);
  assert.match(code,/fn portable_file_with_commit_hook\(/);
  assert.match(code,/before_commit\(\);\s*pinned_parent\.check\(\)\?/);
  assert.match(code,/fn portable_export_detects_late_competing_writer_cleans_stage_and_can_retry\(/);
  assert.match(code,/assert_eq!\(fs::read\(&collision\)\.unwrap\(\),b"competing user file: do not overwrite"\)/);
  assert.match(code,/failed export must remove only its own stage/);
});

test('Win32 reserved device names are rejected while Unicode filenames and ZIP payload remain supported',async()=>{
  const code=await source();
  assert.match(code,/fn windows_device_filename\(name: &str\) -> bool/);
  for(const token of ['CON','PRN','AUX','NUL','CONIN$','CONOUT$','COM','LPT','¹','²','³']){
    assert.ok(code.includes(token),`missing forbidden Windows device component: ${token}`);
  }
  assert.match(code,/name\.ends_with\('\s'\).*windows_device_filename\(name\)/s);
  assert.match(code,/fn portable_save_as_rejects_windows_devices_and_preserves_unicode_names\(/);
  assert.match(code,/fn portable_save_as_rejects_unc_device_and_reparse_aliases\(/);
  assert.match(code,/fn portable_parent_and_verified_stage_handles_block_rename_and_writers\(/);
  assert.match(code,/zip::ZipWriter::new\(output\)/);
  assert.match(code,/\.compression_method\(zip::CompressionMethod::Stored\)/);
  assert.match(code,/status:"exported-local-untrusted-unpublished"/);
  assert.doesNotMatch(code,/Command::new\("(?:powershell|reg|cmd|msiexec)"\)|HKEY_CURRENT_USER|start_game\(/i);
});

test('native adversarial Rust E2E operates on synthetic TEMP packages only',{
  skip:process.platform==='win32'&&process.env.COCO2_HOST_PUBLISH_GUARD_E2E==='1'
    ? false
    : 'Opt-in on Windows: COCO2_HOST_PUBLISH_GUARD_E2E=1',
  timeout:180_000,
},async t=>{
  const cargo=spawn('cargo',['test','--offline','--locked','--lib',
    'host_publish::tests','--','--test-threads=1'],{
    cwd:native,windowsHide:true,shell:false,stdio:['ignore','pipe','pipe'],
  });
  let output='';
  const append=chunk=>{output=(output+chunk.toString('utf8')).slice(-32_000);};
  cargo.stdout.on('data',append);
  cargo.stderr.on('data',append);
  const settled=new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  });
  let timeout=false;
  const watchdog=setTimeout(()=>{timeout=true;cargo.kill();},140_000);
  let result;
  try{result=await settled;}finally{clearTimeout(watchdog);}
  assert.equal(timeout,false,'native Rust tests timed out:\n'+output);
  assert.equal(result.code,0,'native Rust tests failed:\n'+output);
  assert.match(output,/portable_parent_and_verified_stage_handles_block_rename_and_writers \.\.\. ok/);
  assert.match(output,/portable_export_detects_late_competing_writer_cleans_stage_and_can_retry \.\.\. ok/);
  assert.match(output,/portable_save_as_rejects_windows_devices_and_preserves_unicode_names \.\.\. ok/);
  assert.match(output,/portable_save_as_rejects_unc_device_and_reparse_aliases \.\.\. ok/);
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Verified synthetic Rust publisher tests; registry and live app untouched');
});
