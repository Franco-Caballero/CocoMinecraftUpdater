/**
 * Coco Launcher 2 post-signed 0.6.7: bounded 206 Range handling.
 * Only synthetic localhost HTTP plus test-owned TEMP (including Unicode).
 * Native Rust E2E opt-in: COCO2_INSTALL_RESILIENCE_V21_E2E=1.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=()=>readFile(join(desktop,'src-tauri','src','services','install.rs'),'utf8');

test('a shorter 206 subset advances actual delivered bytes, not the requested end',async()=>{
  const code=await source();
  assert.match(code,/let delivered = match status \{/);
  assert.match(code,/first != start \|\| last < first \|\| last > end \|\| remote_total != total/);
  assert.match(code,/last - first \+ 1/);
  assert.match(code,/length\.is_some_and\(\|value\| value != delivered\)/);
  assert.match(code,/let chunk_length = validate_remote_chunk\(/);
  assert.match(code,/copy_stream\(&mut response, &mut output, start, start \+ chunk_length, token, &mut progress\)/);
  assert.match(code,/fn capped_206_ranges_advance_actual_bytes_and_reconstruct_full_sha_v21/);
});

test('overlong and forged 206 must fail closed; full SHA and create-only publication retained',async()=>{
  const code=await source();
  assert.match(code,/fn overlong_206_range_must_fail_closed_without_partial_or_archive_v21/);
  assert.match(code,/if matches_digest\(&working, spec\.size, &hash, token\)\? \{ break; \}/);
  assert.match(code,/publish_verified_archive\(&working,&archive,spec,token\)\?/);
  assert.match(code,/fs::hard_link\(work,archive\)/);
  assert.match(code,/fn safe_archive_redirect\(\)->reqwest::redirect::Policy/);
  assert.match(code,/fn resumable_checkpoint\(cache:&Path, hash:&str, expected:u64, token:&AtomicBool\)/);
  assert.match(code,/fn pinned_unicode_zip_cache_denies_concurrent_writes_rename_and_same_size_asset_spoof/);
});

test('native Windows HTTP Range and install recovery Rust v21 E2E',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_RESILIENCE_V21_E2E==='1'
    ? false:'opt in on Windows with COCO2_INSTALL_RESILIENCE_V21_E2E=1',
  timeout:180000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=chunk=>{output=(output+chunk.toString()).slice(-200000);};
  child.stdout.on('data',collect);child.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},160000);
  const result=await new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Rust install tests timed out:\n'+output);
  assert.equal(result.code,0,'Rust install tests failed:\n'+output);
  for(const name of [
    'capped_206_ranges_advance_actual_bytes_and_reconstruct_full_sha_v21',
    'overlong_206_range_must_fail_closed_without_partial_or_archive_v21',
    'etag_rotation_mid_fresh_download_restarts_once_without_publishing_mixed_mirrors_v16',
    'persistent_mid_transfer_416_fails_bounded_and_preserves_partial_v15',
    'repeated_short_range_bodies_with_progress_resume_to_sha_v15',
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
    'concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved',
  ])assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
