/**
 * Coco2 v29 HTTP response integrity on synthetic 127.0.0.1 and OS TEMP only.
 * Explicit opt-in runs real Rust proxy + offline media download E2E.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rustDir=join(desktop,'src-tauri','src','services');
const enabled=process.platform==='win32'&&process.env.COCO2_MEDIA_STREAM_RESILIENCE_V29_E2E==='1';

test('proxy validates all upstream Content-Range instances, not only the first',async()=>{
  const source=await readFile(join(rustDir,'media.rs'),'utf8');
  const begin=source.indexOf('let code = response.status().as_u16();');
  const end=source.indexOf('if request.method == "GET" {',begin);
  assert.ok(begin>=0&&end>begin,'actual media response gate must be present');
  assert.match(source.slice(begin,end),/get_all\(reqwest::header::CONTENT_RANGE\)/,
    'all conflicting 206/416 Content-Range values must be rejected');
  assert.match(source,/fn v29_duplicate_upstream_content_ranges_do_not_reach_browser\(/);
});

test('offline media download checks every Content-Encoding on a 206',async()=>{
  const source=await readFile(join(rustDir,'media_download.rs'),'utf8');
  const begin=source.indexOf('fn transfer(');
  const end=source.indexOf('let tag=body.headers().get(reqwest::header::ETAG)',begin);
  assert.ok(begin>=0&&end>begin,'real offline download response gate must be present');
  assert.match(source.slice(begin,end),/get_all\(reqwest::header::CONTENT_ENCODING\)/,
    'second gzip Content-Encoding must not bypass identity-only offline downloads');
  assert.match(source,/fn v29_duplicate_content_encoding_must_not_publish_offline_video\(/);
});

test('real native proxy and offline media range E2E on Windows localhost',{
  skip:enabled?false:'set COCO2_MEDIA_STREAM_RESILIENCE_V29_E2E=1 for native Windows E2E',
  timeout:220_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','-j','1','--lib','services::media',
    '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=data=>{output=(output+data.toString()).slice(-230_000);};
  child.stdout.on('data',collect);child.stderr.on('data',collect);
  let timeout=false;
  const watchdog=setTimeout(()=>{timeout=true;child.kill();},205_000);
  const result=await new Promise((resolveResult,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolveResult({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timeout,false,'Native media suite timeout:\n'+output);
  assert.equal(result.code,0,'Native media suite failed:\n'+output);
  for(const name of [
    'v29_duplicate_upstream_content_ranges_do_not_reach_browser',
    'v29_duplicate_content_encoding_must_not_publish_offline_video',
    'v23_upstream_compressed_206_cannot_be_misrepresented_as_raw_video_bytes',
    'v23_local_head_with_range_follows_http_head_semantics_without_a_body',
    'interrupted_first_chunk_does_not_pin_uncommitted_etag_on_retry',
    'hardlinked_partial_never_truncates_unrelated_file_or_publishes_it',
  ])assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
