/**
 * Native Host Studio intake/promotion hardening — never runs installed Coco2.
 * Static contract checks are the default. To opt into Rust TEMP-only fixtures:
 *   $env:COCO2_IMPORT_NATIVE_V8_E2E='1'
 *   node --test tests/import-native-v8.test.mjs
 * No external downloads, games, HKCU, installed EXE or real source packages.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const native=join(desktop,'src-tauri');
const read=path=>readFile(join(desktop,path),'utf8');

test('Host Studio Tauri API and .zip hashing stay unchanged, separate from channel import',async()=>{
  const [source,router,channel]=await Promise.all([
    read('src-tauri/src/services/import.rs'),
    read('src-tauri/src/lib.rs'),
    read('src-tauri/src/services/catalog_channel.rs'),
  ]);
  for(const name of [
    'inspect_standalone_archive','create_standalone_draft',
    'create_standalone_update_draft','review_standalone_draft',
    'promote_standalone_draft','export_portable_standalone_package',
  ]){
    assert.ok(source.includes(`fn ${name}(`),`${name} must exist in OWN import.rs`);
    assert.ok(router.includes(`services::r#import::${name}`),`${name} Tauri registration preserved`);
  }
  assert.match(source,/expected_sha256: String/);
  assert.match(source,/El ZIP cambió desde la inspección/);
  assert.match(source,/ORIGINAL ZIP bytes\/size mismatch against immutable draft/);
  assert.match(source,/FILE_SHARE_READ; no writers or rename\/delete/);
  assert.match(source,/fn rename_no_replace\(from: &Path, to: &Path\)/);
  assert.match(source,/fn replace_catalog\(staged: &Path, catalog: &Path, backup: &Path\)/);
  // Channel review/import is implemented elsewhere; this OWN change must not
  // claim or silently modify its explicit consent/token/Ed25519 pipeline.
  assert.doesNotMatch(source,/pub async fn (?:review_local_publish_package|import_local_publish_package)\(/);
  assert.match(channel,/pub async fn review_local_publish_package\(path:String\)/);
  assert.match(channel,/pub async fn import_local_publish_package\(path:String,review_token:String,confirmed:bool\)/);
});

test('Windows parent pin prevents local ancestor rename/junction swap during import staging',async()=>{
  const source=await read('src-tauri/src/services/import.rs');
  assert.match(source,/struct SourceParentPin\(Vec<\(PathBuf, File\)>\)/);
  assert.match(source,/FILE_FLAG_BACKUP_SEMANTICS \| FILE_FLAG_OPEN_REPARSE_POINT/);
  assert.match(source,/const FILE_SHARE_READ_WRITE: u32 = 0x0000_0003/);
  assert.match(source,/for part in ancestors\.into_iter\(\)\.rev\(\)/);
  assert.match(source,/let _stable_parent = pin_source_parent\(&archive\)\?/);
  assert.match(source,/let _source_parent = pin_source_parent\(&zip\)\?/);
  assert.match(source,/let _draft_parent = pin_source_parent\(&output\)\?/);
  assert.match(source,/let _cover_parent = pin_source_parent\(&cover\)\?/);
  assert.match(source,/let _catalog_parent = pin_source_parent\(/);
  assert.match(source,/native_parent_pin_rejects_unicode_directory_rename_and_reparse_swap/);
});

test('stale review and changed public lock/cover fail closed without overwriting external writers',async()=>{
  const source=await read('src-tauri/src/services/import.rs');
  assert.match(source,/let mut verified_lock = open_local_source\(&target_lock\)\?/);
  assert.match(source,/let mut verified_cover = open_local_source\(&target_cover\)\?/);
  assert.match(source,/actual_lock_hash != lock_hash \|\| actual_lock_size != prepared\.lock\.len\(\) as u64/);
  assert.match(source,/actual_cover_hash != cover_hash \|\| actual_cover_size != prepared\.cover\.len\(\) as u64/);
  assert.match(source,/Published cover or lock changed before catalog commit; recovery required/);
  assert.match(source,/changed cover\/lock preserved for manual inspection/);
  assert.match(source,/fn safely_undo_new\(path: &Path, original_sha: &str\)/);
  assert.match(source,/if sha_bytes\(&bytes\) == original_sha \{ let _ = fs::remove_file\(path\); \}/);
  assert.match(source,/fn late_cover_or_lock_mutation_refuses_catalog_commit_and_preserves_other_writer\(/);
  assert.match(source,/fn reviewed_zip_replaced_by_valid_same_size_zip_cannot_be_promoted\(/);
});

test('real native Rust TEMP fixtures: original review, parent swap, concurrent tamper and retry',{
  skip:process.platform==='win32' && process.env.COCO2_IMPORT_NATIVE_V8_E2E==='1'
    ? false : 'Opt-in Windows only: COCO2_IMPORT_NATIVE_V8_E2E=1',
  timeout:150_000,
},async t=>{
  const cargo=spawn('cargo',[
    'test','--lib','--offline','--locked','services::import::tests',
    '--','--test-threads=16',
  ],{
    cwd:native,windowsHide:true,shell:false,stdio:['ignore','pipe','pipe'],
  });
  let output='';
  const collect=bytes=>{output=(output+bytes.toString('utf8')).slice(-60_000);};
  cargo.stdout.on('data',collect);
  cargo.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;cargo.kill();},135_000);
  const result=await new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'native synthetic intake suite timed out:\n'+output);
  assert.equal(result.code,0,'native synthetic intake suite failed:\n'+output);
  for(const name of [
    'native_parent_pin_rejects_unicode_directory_rename_and_reparse_swap',
    'late_cover_or_lock_mutation_refuses_catalog_commit_and_preserves_other_writer',
    'reviewed_zip_replaced_by_valid_same_size_zip_cannot_be_promoted',
    'reviewed_native_promotion_preserves_original_catalog_format_and_publishes_verified_bytes',
    'catalog_cas_change_after_staged_cover_and_lock_rolls_back_only_own_files',
  ])assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Native ZIP fixtures are synthetic, offline, test-owned TEMP only');
});
