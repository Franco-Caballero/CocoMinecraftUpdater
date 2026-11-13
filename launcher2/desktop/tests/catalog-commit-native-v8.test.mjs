/**
 * Coco2 catalog channel native v8 regression.
 * Read-only source-contract checks are on by default. To run synthetic Rust
 * TEMP fixtures (NO GUI, installed app, HKCU, network or personal archives):
 *   $env:COCO2_CATALOG_NATIVE_V8_E2E='1'
 *   node --test tests/catalog-commit-native-v8.test.mjs
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=join(desktop,'src-tauri');
const source=()=>readFile(join(rust,'src','services','catalog_channel.rs'),'utf8');
const portable=()=>readFile(join(rust,'src','services','catalog_portable.rs'),'utf8');

test('Tauri review/import signatures and separate Ed25519 trust boundary remain unchanged',async()=>{
  const [channel,router]=await Promise.all([source(),readFile(join(rust,'src','services','catalog.rs'),'utf8')]);
  assert.match(channel,/pub async fn review_local_publish_package\(path:String\)->Result<LocalPublishReview,String>/);
  assert.match(channel,/pub async fn import_local_publish_package\(path:String,review_token:String,confirmed:bool\)/);
  assert.match(router,/catalog_channel::review_local_publish_package\(path\)\.await/);
  assert.match(router,/catalog_channel::import_local_publish_package\(path,review_token,confirmed\)\.await/);
  assert.match(channel,/if !confirmed\{return Err\("Explicit local publish-package consent is required"/);
  assert.match(channel,/let _guard=CATALOG_LOCK\.get_or_init/);
  assert.match(channel,/let _os=OsLock::new\(dir\)\?/);
  assert.match(channel,/Publish review is stale or unauthorized/);
  assert.match(channel,/UnparsedPublicKey, ED25519/);
});

test('cache ZIP verified stage is write-sealed through atomic no-replace publication',async()=>{
  const channel=await source();
  assert.match(channel,/const FILE_SHARE_READ_DELETE:u32=0x0000_0005/);
  assert.match(channel,/let _sealed_stage=/);
  assert.match(channel,/share_mode\(FILE_SHARE_READ_DELETE\)\.open\(&stage\)/);
  assert.ok(channel.indexOf('let _sealed_stage=')<channel.indexOf('if let Err(error)=stream_hash(&stage,sha,size)'),
    'writer denial must start BEFORE final hash verification');
  assert.ok(channel.indexOf('let _sealed_stage=')<channel.indexOf('before_publish(&stage,&target)'),
    'writer denial must remain live through test-controlled publish window');
  assert.match(channel,/fn verified_cache_stage_refuses_concurrent_writer_until_atomic_publish\(/);
  assert.match(channel,/fn publish_cache_noreplace\(source:&Path,target:&Path\)/);
  assert.match(channel,/fn seed_cache_with_hook\(/);
});

test('catalog pointer survives old crashed stage; concurrent imports produce one revision',async()=>{
  const channel=await source();
  assert.match(channel,/let \(stage,backup\)=unique_pointer_paths\(dir,next\.revision\)\?/);
  assert.match(channel,/let _stage_cleanup=UncommittedPointerStage\(stage\.clone\(\)\)/);
  assert.match(channel,/for retry in 0\.\.16u8/);
  assert.match(channel,/fn pointer_commit_recovers_from_legacy_crash_stage_without_deleting_foreign_files\(/);
  assert.match(channel,/fn simultaneous_confirmed_local_imports_commit_only_one_snapshot_and_cache_zip\(/);
  assert.match(channel,/let \(_,current\)=load\(dir\)\?/);
  assert.match(channel,/if current!=prior_sha\{return Err\("Catalog changed during review \(CAS\)"/);
});

test('portable review binds full SHA and requires revalidation before import, without ZIP schema changes',async()=>{
  const [channel,pack]=await Promise.all([source(),portable()]);
  assert.match(pack,/name\.ends_with\("\.coco2pack"\) \|\| name\.ends_with\("\.coco2pack\.zip"\)/);
  assert.match(pack,/let portable_sha=format!\("\{:x\}",digest\.finalize\(\)\)/);
  assert.match(pack,/if read!=file_len \|\| format!\("\{:x\}",digest\.finalize\(\)\)!=portable_sha/);
  assert.match(pack,/fn review_token\(pack:&PortablePackage,snapshot_sha:Option<&str>\)->String/);
  assert.match(channel,/review\.review_token=portable::review_token\(&pack,current_sha\.as_deref\(\)\)/);
  assert.match(channel,/portable_source_whole_sha_binds_review_token_and_corrupt_portable_never_commits/);
});

test('native Rust test-only TEMP fixtures for review/commit/retry and official signature',{
  skip:process.platform==='win32'&&process.env.COCO2_CATALOG_NATIVE_V8_E2E==='1'
    ? false : 'Opt-in Windows only: COCO2_CATALOG_NATIVE_V8_E2E=1',
  timeout:150_000,
},async t=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib',
    'services::catalog::catalog_channel::tests','--','--test-threads=16',
  ],{cwd:rust,windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=bytes=>{output=(output+bytes.toString('utf8')).slice(-70_000);};
  child.stdout.on('data',collect);
  child.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},135_000);
  const result=await new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'synthetic Rust catalog tests timed out:\n'+output);
  assert.equal(result.code,0,'synthetic Rust catalog tests failed:\n'+output);
  for(const name of [
    'verified_cache_stage_refuses_concurrent_writer_until_atomic_publish',
    'pointer_commit_recovers_from_legacy_crash_stage_without_deleting_foreign_files',
    'simultaneous_confirmed_local_imports_commit_only_one_snapshot_and_cache_zip',
    'portable_store_envelope_review_import_repeat_and_upgrade_are_idempotent',
    'local_review_requires_consent_streams_cache_and_retains_version_history',
    'ed25519_channel_enforces_embedded_key_format_exact_signature_and_sequence',
  ])assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Native tests are synthetic offline TEMP only; Ed25519 production code unchanged');
});
