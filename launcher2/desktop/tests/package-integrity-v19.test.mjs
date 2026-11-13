/**
 * v19 sealed Host Studio package integrity. Read-only contracts run by default;
 * Windows TEMP synthetic native opt-in:
 *   COCO2_PACKAGE_INTEGRITY_V19_E2E=1 node --test tests/package-integrity-v19.test.mjs
 * No installed Coco2, personal HKCU, GUI, network, games or release build.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const tauri=join(desktop,'src-tauri');
const host=await readFile(join(tauri,'src','services','host_publish.rs'),'utf8');
const importer=await readFile(join(tauri,'src','services','import.rs'),'utf8');
const enabled=process.platform==='win32'&&process.env.COCO2_PACKAGE_INTEGRITY_V19_E2E==='1';

test('sealed preview identity is recomputed from reviewed content rather than trusting matching names',()=>{
  const begin=host.indexOf('fn portable_file_with_commit_hook(');
  const end=host.indexOf('pub(super) fn export_portable(',begin);
  assert.ok(begin>=0&&end>begin);
  const flow=host.slice(begin,end);
  assert.match(flow,/let fingerprint=serde_json::json!\(\{/);
  for(const field of ['sourceCatalogSha256','candidateSha256','resultCatalogSha256',
    'lockSha256','coverSha256','archiveSha256','archiveSize','oldVersion','mode','version']){
    assert.ok(flow.includes(`"${field}"`),'preview fingerprint misses '+field);
  }
  assert.match(flow,/let actual_preview_sha=sha_bytes\(&serde_json::to_vec\(&fingerprint\)/);
  assert.match(flow,/if preview_hash!=actual_preview_sha/);
  assert.match(flow,/directory!=format!\("\{id\}-\{\}",&preview_hash\[\.\.24\]\)/);
  assert.match(host,/fn v19_forged_preview_sha_with_matching_renamed_folder_never_exports/);
  assert.doesNotMatch(flow,/Ed25519KeyPair|apply_signed|sign_official|published:true/);
});

test('portable export refuses self-inconsistent sealed file maps before destination or staging',()=>{
  const flow=host.slice(host.indexOf('fn portable_file_with_commit_hook('),
    host.indexOf('pub(super) fn export_portable('));
  assert.match(flow,/meta\["archiveFile"\]!="game.zip"/);
  assert.match(flow,/meta\["catalogFile"\]!="catalog.template.json"/);
  assert.match(flow,/meta\["lockFile"\]!="source-lock.json"/);
  assert.match(flow,/let stage=create_stage\(destination_parent,id\)\?/);
  assert.ok(flow.indexOf('meta["archiveFile"]')<flow.indexOf('let stage=create_stage('),
    'reject corrupt manifest before allocating any destination stage');
  assert.match(flow,/rename_no_replace\(&temp,&dest\)\?/);
  assert.match(host,/fn v19_inconsistent_sealed_manifest_member_names_rejected_before_friend_delivery/);
  assert.match(flow,/status:"exported-local-untrusted-unpublished"/);
});

test('optional cover, explicitly selected executable, Unicode Save As, review consent and replay stay separate',()=>{
  assert.match(importer,/let explicit_cover = if cover_path\.is_empty\(\)/);
  assert.match(importer,/Selected executable is not present in the ZIP/);
  assert.match(importer,/Some\(&reviewed\),false/);
  assert.match(host,/fn v16_friend_optional_cover_unicode_save_as_review_token_and_idempotent_direct_import/);
  assert.match(host,/saved\.status,"exported-local-untrusted-unpublished"/);
  assert.match(host,/review\.portable_sha256\.as_deref\(\),Some\(saved\.sha256\.as_str\(\)\)/);
  assert.match(host,/review\.review_token/);
  assert.match(host,/assert_eq!\(again\.status,"unchanged"\)/);
  assert.match(host,/entry\.id=="friend-game"&&entry\.source=="local"/);
  assert.match(host,/fn transient_reader_lock_does_not_leave_partial_portable_stage/);
  assert.match(host,/fn two_concurrent_save_as_writers_commit_once_and_preserve_other_artifacts/);
  assert.match(importer,/"CONIN\$" \| "CONOUT\$"/);
});

test('native Windows TEMP E2E: two RED/GREEN v19 cases plus full Host Studio publisher regression',{
  skip:!enabled?'Native TEMP Rust tests require COCO2_PACKAGE_INTEGRITY_V19_E2E=1 on Windows':false,
  timeout:150_000,
},async t=>{
  const child=spawn('cargo',['test','--offline','--locked','--lib',
    'services::import::host_publish::tests','--','--nocapture','--test-threads=1'],{
    cwd:tauri,shell:false,windowsHide:true,stdio:['ignore','pipe','pipe'],
    env:{...process.env},
  });
  let stdout='',stderr='',timedOut=false;
  child.stdout.on('data',data=>{stdout=(stdout+data.toString()).slice(-150_000);});
  child.stderr.on('data',data=>{stderr=(stderr+data.toString()).slice(-80_000);});
  const timer=setTimeout(()=>{timedOut=true;child.kill();},135_000);
  let state;
  try{
    state=await new Promise((resolve,reject)=>{
      child.once('error',reject);
      child.once('close',(code,signal)=>resolve({code,signal}));
    });
  }finally{clearTimeout(timer);}
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'test-owned Rust watchdog timed out:\n'+output.slice(-10000));
  assert.equal(state.code,0,'Rust HostStudio v19 tests failed:\n'+output.slice(-14000));
  for(const name of [
    'v19_forged_preview_sha_with_matching_renamed_folder_never_exports',
    'v19_inconsistent_sealed_manifest_member_names_rejected_before_friend_delivery',
    'v16_friend_optional_cover_unicode_save_as_review_token_and_idempotent_direct_import',
    'portable_export_rejects_same_size_zip_mutation_without_destination_or_staging',
    'transient_reader_lock_does_not_leave_partial_portable_stage',
    'two_concurrent_save_as_writers_commit_once_and_preserve_other_artifacts',
  ])assert.ok(output.includes('::'+name+' ... '),'missing synthetic native regression: '+name);
  assert.match(output,/COCO2_FRIEND_PATH_V16_PASS optional_cover=1 unicode_save_as=1 token=1 idempotent=1 local_provenance=1/);
  assert.match(output,/test result: ok\. 21 passed; 0 failed/);
  t.diagnostic('Only test-owned synthetic TEMP packages; never modified installed game, registry or Release');
});
