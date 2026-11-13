/**
 * Coco2 ZIP Range header integrity, using only test-owned TEMP and localhost
 * in native Windows Rust E2E. The existing signed 0.6.11 release is immutable.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const install=join(desktop,'src-tauri','src','services','install.rs');
const native=process.platform==='win32' &&
  process.env.COCO2_INSTALL_RECOVERY_RESILIENCE_V27_E2E==='1';

test('HTTP 206 inspects every Content-Encoding field before accepting ZIP bytes',async()=>{
  const source=await readFile(install,'utf8');
  const start=source.indexOf('if status == 416 {');
  const end=source.indexOf('let chunk_length = validate_remote_chunk(',start);
  assert.ok(start>0&&end>start,'expected real HTTP Range validation path');
  const validator=source.slice(start,end);
  assert.ok(validator.includes('get_all(reqwest::header::CONTENT_ENCODING).iter()'),
    'a second Content-Encoding must not bypass identity-only ZIP Range integrity');
  assert.match(source,/fn duplicate_content_encoding_does_not_publish_untrusted_206_v27\(/);
});

test('native Windows local ZIP recovery rejects duplicate encoding and preserves existing ETag/416 contracts',{
  skip:native?false:'set COCO2_INSTALL_RECOVERY_RESILIENCE_V27_E2E=1 on Windows for native HTTP E2E',
  timeout:200_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const add=chunk=>{output=(output+chunk.toString()).slice(-220_000);};
  child.stdout.on('data',add);
  child.stderr.on('data',add);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},185_000);
  const finished=await new Promise((resolveClose,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolveClose({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Native ZIP Range suite exceeded deadline:\n'+output);
  assert.equal(finished.code,0,'Native ZIP Range suite failed:\n'+output);
  for(const name of [
    'duplicate_content_encoding_does_not_publish_untrusted_206_v27',
    'uncommitted_http_etag_does_not_exhaust_single_real_rotation_v25',
    'etag_rotation_mid_fresh_download_restarts_once_without_publishing_mixed_mirrors_v16',
    'persistent_mid_transfer_416_fails_bounded_and_preserves_partial_v15',
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
    'pinned_unicode_zip_cache_denies_concurrent_writes_rename_and_same_size_asset_spoof',
  ]) assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
