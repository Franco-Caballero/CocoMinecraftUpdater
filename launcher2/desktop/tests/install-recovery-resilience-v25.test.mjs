/**
 * Windows native Coco2 installer recovery regression. Exercises actual Rust
 * download_one against ephemeral 127.0.0.1 HTTP and test-owned TEMP paths;
 * no commercial games, installed instances, HKCU, or external network.
 * Enable with COCO2_INSTALL_RECOVERY_RESILIENCE_V25_E2E=1.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const enabled=process.platform==='win32'&&
  process.env.COCO2_INSTALL_RECOVERY_RESILIENCE_V25_E2E==='1';

test('native ZIP Range retry preserves an actual ETag restart after a zero-byte truncated 206',{
  skip:enabled?false:'set COCO2_INSTALL_RECOVERY_RESILIENCE_V25_E2E=1 for native Windows HTTP E2E',
  timeout:220_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=chunk=>{output=(output+chunk.toString()).slice(-200_000);};
  child.stdout.on('data',collect);
  child.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},205_000);
  const result=await new Promise((resolveResult,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolveResult({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Native installer recovery suite timed out:\n'+output);
  assert.equal(result.code,0,'Native installer recovery suite failed:\n'+output);
  for(const name of [
    'uncommitted_http_etag_does_not_exhaust_single_real_rotation_v25',
    'etag_rotation_mid_fresh_download_restarts_once_without_publishing_mixed_mirrors_v16',
    'persistently_flapping_etag_fails_bounded_with_checkpoint_preserved_v16',
    'repeated_short_range_bodies_with_progress_resume_to_sha_v15',
    'mid_transfer_416_once_restarts_private_copy_even_without_legacy_partial_v15',
    'concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved',
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
  ]) assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
