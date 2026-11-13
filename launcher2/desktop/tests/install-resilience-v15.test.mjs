/**
 * Coco Launcher 2 v0.6.5 candidate — HTTP Range recovery after fresh progress.
 * Synthetic Windows TEMP files, ephemeral 127.0.0.1 HTTP only; no real games,
 * user saves, HKCU, Defender, GitHub, credentials, or Release.
 *
 * COCO2_INSTALL_RESILIENCE_V15_E2E=1 runs the Rust native suite through Node.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=()=>readFile(join(desktop,'src-tauri','src','services','install.rs'),'utf8');

test('late HTTP 416/ignored Range after fresh progress restarts only a private copy ONCE',async()=>{
  const code=await source();
  assert.match(code,/let legacy_range_rejected=previous_len>0 && start>0 && !restarted_after_rejected_range/);
  assert.match(code,/let fresh_range_rejected=previous_len==0 && start>0 && !restarted_after_rejected_range/);
  assert.match(code,/matches!\(status,200\|416\)/);
  assert.match(code,/let cleared=OpenOptions::new\(\)\.write\(true\)\.truncate\(true\)\.open\(&working\)/);
  assert.match(code,/resume_guard\.previous_len=0/);
  assert.match(code,/restarted_after_rejected_range=true/);
  assert.match(code,/fn mid_transfer_416_once_restarts_private_copy_even_without_legacy_partial_v15/);
  assert.match(code,/fn persistent_mid_transfer_416_fails_bounded_and_preserves_partial_v15/);
});

test('repeated short bodies count advancing offsets but cap malicious trickle',async()=>{
  const code=await source();
  assert.match(code,/const HTTP_ADVANCING_TRUNCATIONS: usize = 16/);
  assert.match(code,/let mut advancing_truncations=0usize/);
  assert.match(code,/if after>start/);
  assert.match(code,/output\.sync_all\(\)/);
  assert.match(code,/advancing_truncations>=HTTP_ADVANCING_TRUNCATIONS/);
  assert.match(code,/attempts=0;\s*retry_http_delay\(1,None,token\)/);
  assert.match(code,/fn repeated_short_range_bodies_with_progress_resume_to_sha_v15/);
  assert.match(code,/fn one_byte_range_trickles_are_bounded_and_preserved_for_later_recovery_v15/);
});

test('SHA publication, immutability, checkpoints, HTTPS and save protection stay intact',async()=>{
  const code=await source();
  assert.match(code,/if matches_digest\(&working, spec\.size, &hash, token\)\? \{ break; \}/);
  assert.match(code,/fs::hard_link\(work,archive\)/);
  assert.match(code,/fs::hard_link\(&self\.work,&self\.canonical\)/);
  assert.match(code,/fn mark_download_stage\(stage:&Path,hash:&str,size:u64\)/);
  assert.match(code,/if source\.scheme\(\)!="https" && source\.scheme\(\)!="file" && !synthetic_http_fixture\(&source\)/);
  assert.match(code,/fn safe_archive_redirect\(\)->reqwest::redirect::Policy/);
  assert.match(code,/fn mid_transfer_416_once_restarts_private_copy_even_without_legacy_partial_v15/);
  assert.match(code,/saves\/world\/player\.dat/);
});

test('Windows native synthetic Rust v15 HTTP Range and regression E2E',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_RESILIENCE_V15_E2E==='1'
    ? false : 'opt in on Windows using COCO2_INSTALL_RESILIENCE_V15_E2E=1',
  timeout:180_000,
},async()=>{
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),shell:false,windowsHide:true,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=chunk=>{output=(output+chunk.toString()).slice(-180000);};
  cargo.stdout.on('data',collect);cargo.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;cargo.kill();},165000);
  const completed=await new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Native Rust v15 exceeded safe limit:\n'+output);
  assert.equal(completed.code,0,'Native Rust v15 failure:\n'+output);
  for(const name of [
    'mid_transfer_416_once_restarts_private_copy_even_without_legacy_partial_v15',
    'persistent_mid_transfer_416_fails_bounded_and_preserves_partial_v15',
    'repeated_short_range_bodies_with_progress_resume_to_sha_v15',
    'one_byte_range_trickles_are_bounded_and_preserved_for_later_recovery_v15',
    'rejected_resume_range_416_and_200_restart_once_without_touching_partial',
    'redirect_policy_blocks_untrusted_http_before_following_location',
    'concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved',
  ])assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
