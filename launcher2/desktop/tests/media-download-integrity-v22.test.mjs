/**
 * Coco Launcher 2 native offline media integrity: test-owned TEMP files and
 * ephemeral 127.0.0.1 responses only, with no real media or installed state.
 * Set COCO2_MEDIA_DOWNLOAD_INTEGRITY_V22_E2E=1 to run the Rust native suite.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const execute=process.platform==='win32'&&
  process.env.COCO2_MEDIA_DOWNLOAD_INTEGRITY_V22_E2E==='1';

test('native media download defends hardlinked partials and retries an interrupted ETag',{
  skip:execute?false:'enable the native Windows E2E with COCO2_MEDIA_DOWNLOAD_INTEGRITY_V22_E2E=1',
  timeout:180_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::media_download::tests',
    '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=buffer=>{output=(output+buffer.toString()).slice(-150_000);};
  child.stdout.on('data',collect);
  child.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},165_000);
  const finish=await new Promise((done,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>done({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'native media-download E2E timed out:\n'+output);
  assert.equal(finish.code,0,'native media-download E2E failed:\n'+output);
  for(const name of [
    'hardlinked_partial_never_truncates_unrelated_file_or_publishes_it',
    'interrupted_first_chunk_does_not_pin_uncommitted_etag_on_retry',
    'fixture_download_cancellation_and_resume_with_sha_and_ranges',
    'rate_limits_retries_then_etag_switch_and_connection_reset_fail_safe',
  ]) {
    assert.match(output,new RegExp(`test services::media_download::tests::${name} \\.\\.\\. ok`));
  }
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
