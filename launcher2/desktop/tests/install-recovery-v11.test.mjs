/**
 * Coco2 v11 download recovery regression checks. All mutable data in the Rust
 * synthetic tests live in per-test TEMP directories; HTTP stays on 127.0.0.1.
 * Opt in to the native tests with COCO2_INSTALL_RECOVERY_V11_E2E=1.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const impl=()=>readFile(join(desktop,'src-tauri/src/services/install.rs'),'utf8');

test('interrupted downloads publish immutable checkpoints and resume greatest progress',async()=>{
  const code=await impl();
  assert.match(code,/struct PartialResumeGuard \{/);
  assert.match(code,/meta\.len\(\)>self\.previous_len/);
  assert.match(code,/fs::hard_link\(&self\.work,&self\.canonical\)\.is_err\(\)/);
  assert.match(code,/fs::hard_link\(&self\.work,&self\.checkpoint\)/);
  assert.match(code,/fn resumable_checkpoint\(/);
  assert.match(code,/\.zip\.partial\.v11\./);
  assert.match(code,/let resume = resumable_checkpoint\(cache,&hash,spec\.size,token\)\?/);
  assert.match(code,/resume_guard\.complete=true/);
  assert.match(code,/fn publish_verified_archive\(/);
  assert.match(code,/error\.kind\(\)==std::io::ErrorKind::AlreadyExists/);
  assert.match(code,/fn concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved/);
  assert.match(code,/let mut restarted_after_stale_partial=false/);
  assert.match(code,/if previous_len>0 && !restarted_after_stale_partial/);
  assert.match(code,/resume_guard\.previous_len=0/);
  assert.match(code,/fn interrupted_unicode_download_checkpoints_advance_without_touching_foreign_partial/);
});

test('HTTP transient retries retain Range/ETag and check full digest before publishing',async()=>{
  const code=await impl();
  assert.match(code,/fn retryable_http_status\(status:u16\)->bool/);
  assert.match(code,/matches!\(status,408\|429\|500\|502\|503\|504\)/);
  assert.match(code,/retry_http_delay\(attempts,after\.as_deref\(\),token\)\?/);
  assert.match(code,/reqwest::header::IF_RANGE/);
  assert.match(code,/reqwest::header::CONTENT_ENCODING/);
  assert.match(code,/if matches_digest\(&working, spec\.size, &hash, token\)\? \{ break; \}/);
  assert.match(code,/fn transient_http_503_and_429_retry_with_bounded_ranges_and_verified_sha/);
  assert.match(code,/a corrupt resumed prefix must restart from byte zero exactly once/);
  assert.match(code,/fn retry_wait_is_cancelable_and_oversized_partial_fails_closed/);
});

test('native Rust recovery adversarial tests: local TEMP, no external network',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_RECOVERY_V11_E2E==='1'
    ? false : 'opt in on Windows with COCO2_INSTALL_RECOVERY_V11_E2E=1',
  timeout:180_000,
},async()=>{
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=8',
  ],{
    cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,
    stdio:['ignore','pipe','pipe'],
  });
  let output='';
  const collect=part=>{output=(output+part.toString()).slice(-100000);};
  cargo.stdout.on('data',collect);
  cargo.stderr.on('data',collect);
  let timeout=false;
  const watchdog=setTimeout(()=>{timeout=true;cargo.kill();},165000);
  const result=await new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timeout,false,'Native install Rust tests timed out:\n'+output);
  assert.equal(result.code,0,'Native install Rust tests failed:\n'+output);
  for(const name of [
    'interrupted_unicode_download_checkpoints_advance_without_touching_foreign_partial',
    'transient_http_503_and_429_retry_with_bounded_ranges_and_verified_sha',
    'retry_wait_is_cancelable_and_oversized_partial_fails_closed',
    'concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved',
    'corrupt_zip_and_cancel_leave_no_instance',
  ])assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
