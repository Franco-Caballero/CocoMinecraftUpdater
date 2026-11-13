/**
 * Coco Launcher 2 after signed v0.6.5: adversarial HTTP Range/CDN recovery.
 * Native tests use only test-owned Windows TEMP and 127.0.0.1 sockets.
 * No GitHub, real ZIP/video, games, saves, HKCU, Defender, or Release.
 *
 * COCO2_INSTALL_RESILIENCE_V16_E2E=1 enables real Rust inline tests.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=()=>readFile(join(desktop,'src-tauri','src','services','install.rs'),'utf8');

test('rotating ETag between 206 chunks triggers exactly one private reset, preserving earlier checkpoints',async()=>{
  const code=await source();
  assert.match(code,/validator\.as_ref\(\)!=Some\(prior\)/);
  assert.match(code,/if restarted_after_rejected_range \{/);
  assert.match(code,/No se pudo reiniciar copia privada tras ETag/);
  assert.match(code,/restarted_after_rejected_range=true/);
  assert.match(code,/restarted_after_stale_partial=true/);
  assert.match(code,/resume_guard\.previous_len=0/);
  assert.match(code,/fn etag_rotation_mid_fresh_download_restarts_once_without_publishing_mixed_mirrors_v16/);
  assert.match(code,/fn persistently_flapping_etag_fails_bounded_with_checkpoint_preserved_v16/);
});

test('fresh CDN full SHA poison retries once and still denies publishing persistent malicious bytes',async()=>{
  const code=await source();
  assert.match(code,/if matches_digest\(&working, spec\.size, &hash, token\)\? \{ break; \}/);
  assert.match(code,/let may_restart_after_bad_sha=if previous_len>0 && !restarted_after_stale_partial/);
  assert.match(code,/previous_len==0 && !restarted_after_stale_partial/);
  assert.match(code,/if may_restart_after_bad_sha && source\.scheme\(\)!="file"/);
  assert.match(code,/No se pudo reiniciar copia privada/);
  assert.match(code,/publish_verified_archive\(&working,&archive,spec,token\)\?/);
  assert.match(code,/fs::hard_link\(work,archive\)/);
  assert.match(code,/fn first_fresh_mirror_full_sha_poison_recovers_without_user_retry_v16/);
  assert.match(code,/fn repeated_fresh_mirror_full_sha_poison_refuses_publish_v16/);
});

test('HTTPS redirect protection, bounded retries and immutable resume checkpoints stay in effect',async()=>{
  const code=await source();
  assert.match(code,/fn safe_archive_redirect\(\)->reqwest::redirect::Policy/);
  assert.match(code,/fn mark_download_stage\(stage:&Path,hash:&str,size:u64\)/);
  assert.match(code,/fn resumable_checkpoint\(cache:&Path, hash:&str, expected:u64, token:&AtomicBool\)/);
  assert.match(code,/fs::hard_link\(&self\.work,&self\.checkpoint\)/);
  assert.match(code,/const HTTP_ATTEMPTS: usize = 4/);
  assert.match(code,/const HTTP_ADVANCING_TRUNCATIONS: usize = 16/);
  assert.match(code,/fn rejected_resume_range_416_and_200_restart_once_without_touching_partial/);
});

test('native Windows TEMP/loopback Rust v16 regression E2E',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_RESILIENCE_V16_E2E==='1'
    ? false:'opt in on Windows with COCO2_INSTALL_RESILIENCE_V16_E2E=1',
  timeout:180000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const record=part=>{output=(output+part.toString()).slice(-180000);};
  child.stdout.on('data',record);child.stderr.on('data',record);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},165000);
  const result=await new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Rust v16 timed out:\n'+output);
  assert.equal(result.code,0,'Rust v16 E2E failed:\n'+output);
  for(const name of [
    'etag_rotation_mid_fresh_download_restarts_once_without_publishing_mixed_mirrors_v16',
    'persistently_flapping_etag_fails_bounded_with_checkpoint_preserved_v16',
    'first_fresh_mirror_full_sha_poison_recovers_without_user_retry_v16',
    'repeated_fresh_mirror_full_sha_poison_refuses_publish_v16',
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
    'rejected_resume_range_416_and_200_restart_once_without_touching_partial',
    'one_byte_range_trickles_are_bounded_and_preserved_for_later_recovery_v15',
    'concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved',
  ]) assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
