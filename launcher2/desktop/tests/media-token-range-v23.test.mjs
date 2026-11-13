/**
 * Native localhost token and range contract through the actual Rust proxy.
 * Fixtures use only 127.0.0.1 and unique test-owned OS TEMP files. Set
 * COCO2_MEDIA_TOKEN_RANGE_V23_E2E=1 on Windows to execute the Rust cases.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const enabled=process.platform==='win32'&&process.env.COCO2_MEDIA_TOKEN_RANGE_V23_E2E==='1';

test('native HTTP proxy keeps local ranged HEAD as 200 and rejects encoded 206',{
  skip:enabled?false:'set COCO2_MEDIA_TOKEN_RANGE_V23_E2E=1 on Windows for real Rust HTTP E2E',
  timeout:180_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::media::tests',
    '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let log='';
  const append=data=>{log=(log+data.toString()).slice(-200_000);};
  child.stdout.on('data',append);
  child.stderr.on('data',append);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},165_000);
  const status=await new Promise((resolveStatus,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolveStatus({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Rust localhost proxy suite timed out:\n'+log);
  assert.equal(status.code,0,'Rust localhost proxy suite failed:\n'+log);
  for(const name of [
    'v23_local_head_with_range_follows_http_head_semantics_without_a_body',
    'v23_upstream_compressed_206_cannot_be_misrepresented_as_raw_video_bytes',
    'local_range_proxy_supports_seek_head_cors_and_token_guard_without_real_network',
    'verified_local_media_serves_video_range_without_upstream_requests',
    'rejects_forged_unsatisfiable_range_and_unrequested_416',
  ]) assert.match(log,new RegExp(`test services::media::tests::${name} \\.\\.\\. ok`));
  assert.match(log,/test result: ok\. \d+ passed; 0 failed/);
});
