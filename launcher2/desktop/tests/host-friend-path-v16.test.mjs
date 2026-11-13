/**
 * Coco2 Host Studio "send to friend" contract: all filesystem tests operate
 * on Rust-created synthetic TEMP repositories, profiles and ZIP bytes.
 * Source guards run by default. Explicit native Windows opt-in:
 *   COCO2_HOST_FRIEND_V16_E2E=1 node --test tests/host-friend-path-v16.test.mjs
 * No installed games, UI, HKCU/Defender, network or release invocation.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const tauri=join(desktop,'src-tauri');
const host=join(tauri,'src','services','host_publish.rs');
const importer=join(tauri,'src','services','import.rs');
const enabled=process.platform==='win32'&&process.env.COCO2_HOST_FRIEND_V16_E2E==='1';

test('Save As binds sealed package directory to original reviewed preview SHA',async()=>{
  const source=await readFile(host,'utf8');
  const start=source.indexOf('fn portable_file_with_commit_hook(');
  const end=source.indexOf('pub(super) fn export_portable(',start);
  const flow=source.slice(start,end);
  assert.ok(start>=0&&end>start);
  assert.match(flow,/let preview_hash=meta\["previewSha256"\]\.as_str\(\)/);
  assert.match(flow,/!valid_sha\(preview_hash\)/);
  assert.match(flow,/directory!=format!\("\{id\}-\{\}",&preview_hash\[\.\.24\]\)/);
  assert.match(flow,/let mut archive=open_local_source\(&zip_path\)\?/);
  assert.match(flow,/if counted!=archive_size \|\| format!\("\{:x\}",archive_digest\.finalize\(\)\)!=archive_sha/);
  assert.match(flow,/let _retry_cleanup=PortableStageCleanup\(stage\.0\.clone\(\)\)/);
  assert.match(flow,/rename_no_replace\(&temp,&dest\)\?/);
  assert.match(flow,/status:"exported-local-untrusted-unpublished"/);
  assert.match(source,/fn v16_portable_export_rejects_renamed_sealed_package_identity/);
});

test('Windows-safe ZIP path intake rejects legacy device names including Unicode superscripts',async()=>{
  const source=await readFile(importer,'utf8');
  const path=source.slice(source.indexOf('fn safe_path('),source.indexOf('fn no_links('));
  for(const name of ['"CON"','"PRN"','"AUX"','"NUL"','"CONIN$"','"CONOUT$"','"COM"','"LPT"','"¹"','"²"','"³"']){
    assert.ok(path.includes(name),'missing Win32 device rule: '+name);
  }
  assert.match(source,/fn v16_reject_windows_reserved_superscript_and_console_device_zip_members/);
  assert.match(source,/let path = safe_path\(item\.name\(\), directory\)\?/);
  assert.match(source,/fn v16_same_size_same_mtime_replaced_zip_and_invalid_executable_fail_closed/);
  assert.match(source,/file\.set_times\(std::fs::FileTimes::new\(\)\.set_modified\(first_time\)\)/);
  assert.match(source,/Some\(&reviewed\),false/);
});

test('friend ZIP review never auto-imports; explicit user consent and content-addressing are separate from official signing',async()=>{
  const source=await readFile(host,'utf8');
  assert.match(source,/fn v16_friend_optional_cover_unicode_save_as_review_token_and_idempotent_direct_import/);
  assert.match(source,/&original\.to_string_lossy\(\),\s*"friend-game","Friend Game","1\.0\.0",url,"","Game\.exe",Some\(&source_sha\),false/s);
  assert.match(source,/saved\.status,"exported-local-untrusted-unpublished"/);
  assert.match(source,/review\.portable_sha256\.as_deref\(\),Some\(saved\.sha256\.as_str\(\)\)/);
  assert.match(source,/!profile\.join\("current\.json"\)\.exists\(\)/);
  assert.match(source,/"0"\.repeat\(64\)/);
  assert.match(source,/assert_eq!\(first\.status,"updated"\)/);
  assert.match(source,/assert_eq!\(again\.status,"unchanged"\)/);
  assert.match(source,/entry\.id=="friend-game"&&entry\.source=="local"/);
  assert.doesNotMatch(source,/Command::new\("(?:powershell|reg|msiexec|explorer|curl)"\)|HKEY_CURRENT_USER/i);
});

test('native v16: optional cover to actual .coco2pack to reviewed/idempotent friend import',{
  skip:!enabled?'Opt-in Windows synthetic TEMP suite: COCO2_HOST_FRIEND_V16_E2E=1':false,
  timeout:160_000,
},async t=>{
  const cargo=spawn('cargo',['test','--offline','--locked','--lib','v16_',
    '--','--nocapture','--test-threads=1'],{
    cwd:tauri,shell:false,windowsHide:true,stdio:['ignore','pipe','pipe'],
    env:{...process.env},
  });
  let stdout='',stderr='',timedOut=false;
  cargo.stdout.on('data',chunk=>{stdout=(stdout+chunk.toString()).slice(-95_000);});
  cargo.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-65_000);});
  const timer=setTimeout(()=>{timedOut=true;cargo.kill();},140_000);
  let outcome;
  try{
    outcome=await new Promise((resolve,reject)=>{
      cargo.once('error',reject);
      cargo.once('close',(code,signal)=>resolve({code,signal}));
    });
  }finally{clearTimeout(timer);}
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'Native test-only Cargo watchdog expired:\n'+output.slice(-8_000));
  assert.equal(outcome.code,0,'Native friend E2E failed:\n'+output.slice(-14_000));
  for(const name of [
    'v16_portable_export_rejects_renamed_sealed_package_identity',
    'v16_reject_windows_reserved_superscript_and_console_device_zip_members',
    'v16_same_size_same_mtime_replaced_zip_and_invalid_executable_fail_closed',
  ]){
    assert.match(output,new RegExp(name+' \\.\\.\\. ok'),'Missing native test proof: '+name);
  }
  assert.match(output,/v16_friend_optional_cover_unicode_save_as_review_token_and_idempotent_direct_import \.\.\. COCO2_FRIEND_PATH_V16_PASS[^\n]*\nok/);
  assert.match(output,/COCO2_FRIEND_PATH_V16_PASS optional_cover=1 unicode_save_as=1 token=1 idempotent=1 local_provenance=1/);
  assert.match(output,/test result: ok\. 4 passed; 0 failed/);
  t.diagnostic('Only test-owned TEMP files and Cargo Rust unit tests; no live installation, GUI or profile');
});
