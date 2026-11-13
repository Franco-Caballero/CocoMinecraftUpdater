/**
 * Coco2 media proxy v7 regression. The default checks only native source and
 * public Tauri contracts. Explicit opt-in runs the Rust synthetic localhost
 * HTTP fixture without internet, WebView, media downloads or user files:
 *   COCO2_MEDIA_PROXY_V7_E2E=1 node --test tests/media-proxy-v7.test.mjs
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const native=join(desktop,'src-tauri');
const read=path=>readFile(join(desktop,path),'utf8');

test('Tauri media commands and private upstream allowlist retain their contracts',async()=>{
  const [source,entry]=await Promise.all([
    read('src-tauri/src/services/media.rs'),read('src-tauri/src/lib.rs'),
  ]);
  for(const command of ['prepare_media_stream','prepare_local_media_stream','close_media_stream']){
    assert.match(entry,new RegExp(`services::media::${command}`));
    assert.match(source,new RegExp(`pub (?:async )?fn ${command}\\(`));
  }
  assert.match(source,/const MAX_CONNECTIONS_PER_PROXY: usize = 4;/);
  assert.match(source,/SocketAddrV4::new\(Ipv4Addr::LOCALHOST, 0\)/);
  assert.match(source,/if url\.scheme\(\) != "https" \|\| url\.port_or_known_default\(\) != Some\(443\)/);
  assert.match(source,/"\/Franco-Caballero\/CocoMinecraftUpdater\/releases\/download\/"/);
  assert.match(source,/"release-assets\.githubusercontent\.com"/);
  assert.match(source,/"objects\.githubusercontent\.com"/);
  assert.match(source,/fn secure_token\(\) -> Result<String, String>/);
  assert.match(source,/let mut bytes = \[0_u8; 24\]/);
});

test('upstream HTTP 416 only reaches WebView when request is truly unsatisfiable',async()=>{
  const source=await read('src-tauri/src/services/media.rs');
  assert.match(source,/fn valid_unsatisfiable_response\(request: Option<&str>, content_range: Option<&str>, expected: u64\)/);
  assert.match(source,/content_range\.strip_prefix\("bytes \*\/"\)/);
  assert.match(source,/total == 0 \|\| \(expected != 0 && total != expected\)/);
  assert.match(source,/!first\.is_empty\(\) && first\.parse::<u64>\(\)\.is_ok_and\(\|start\| start >= total\)/);
  assert.match(source,/if valid_unsatisfiable_response\(request\.range\.as_deref\(\), content_range, spec\.expected_bytes\)/);
  assert.match(source,/send_headers\(&mut stream, 502, "text\/plain", 0, None, false\)/);
  assert.match(source,/fn synthetic_upstream_416_requires_genuine_unsatisfiable_range_and_correct_total\(/);
  assert.match(source,/fn rejects_forged_unsatisfiable_range_and_unrequested_416\(/);
});

test('closing playback stops an active GET after the next bounded read and keeps HEAD semantics',async()=>{
  const source=await read('src-tauri/src/services/media.rs');
  assert.match(source,/cancelled: Arc<AtomicBool>/);
  assert.match(source,/local_file,cancelled:Arc::clone\(&cancelled\)/);
  assert.match(source,/if !token\.swap\(true,Ordering::AcqRel\) \{/);
  assert.match(source,/ACTIVE_PROXIES\.fetch_sub\(1,Ordering::AcqRel\)/,
    'closing a stream releases its quota exactly once, before worker exit');
  assert.match(source,/while remaining>0 && !spec\.cancelled\.load\(Ordering::Acquire\)/);
  assert.match(source,/if count==0 \|\| spec\.cancelled\.load\(Ordering::Acquire\) \{break;\}/);
  assert.match(source,/let mut buffer=\[0u8;64\*1024\]/);
  assert.match(source,/let mut source=response\.take\(length\)/);
  assert.doesNotMatch(source,/std::io::copy\(&mut response\.take\(length\)/);
  assert.match(source,/request\.method == "HEAD" && spec\.expected_bytes != 0/,
    'a HEAD carrying Range is answered locally from trusted manifest length');
  assert.match(source,/fn closing_stream_stops_active_remote_get_before_later_upstream_chunks\(/);
});

test('concurrent media GET/HEAD retries one transient socket abort without widening Range or timeouts',async()=>{
  const source=await read('src-tauri/src/services/media.rs');
  assert.match(source,/fn transient_media_transport\(error: &\(dyn std::error::Error \+ 'static\)\) -> bool/);
  for(const kind of ['ConnectionAborted','ConnectionReset','BrokenPipe','UnexpectedEof']){
    assert.ok(source.includes(`std::io::ErrorKind::${kind}`),`missing transient transport kind ${kind}`);
  }
  assert.match(source,/let mut retried_transport = false;/);
  assert.match(source,/if spec\.cancelled\.load\(Ordering::Acquire\) \{return;\}/);
  assert.match(source,/Err\(error\) if !retried_transport && transient_media_transport\(&error\)/);
  assert.match(source,/retried_transport = true;/);
  assert.match(source,/upstream = upstream\.header\(reqwest::header::RANGE, range\)/);
  assert.match(source,/fn aborted_first_upstream_connection_retries_identical_range_once\(/);
  assert.match(source,/fn transport_retries_only_reset_abort_and_eof_not_timeout_or_untrusted_http\(/);
  assert.doesNotMatch(source,/eprintln!\("(?:fixture upstream|media upstream)/,
    'debugging transport traces must not ship in Release');
});

test('actual native localhost fixture tests malformed 416 and stops active remote GET',{
  skip:process.platform==='win32' && process.env.COCO2_MEDIA_PROXY_V7_E2E==='1'
    ? false : 'Opt-in Windows localhost fixture: COCO2_MEDIA_PROXY_V7_E2E=1',
  timeout:150_000,
},async t=>{
  const child=spawn('cargo',['test','--offline','--locked','--lib',
    'services::media::tests','--','--test-threads=16'],{
    cwd:native,windowsHide:true,shell:false,stdio:['ignore','pipe','pipe'],
  });
  let output='';
  const collect=chunk=>{output=(output+chunk.toString('utf8')).slice(-30_000);};
  child.stdout.on('data',collect);
  child.stderr.on('data',collect);
  const complete=new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolve({code,signal}));
  });
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},135_000);
  let result;
  try{result=await complete;}finally{clearTimeout(watchdog);}
  assert.equal(timedOut,false,'native Rust fixture timed out:\n'+output);
  assert.equal(result.code,0,'native Rust media fixture failed:\n'+output);
  for(const name of [
    'closing_stream_stops_active_remote_get_before_later_upstream_chunks',
    'synthetic_upstream_416_requires_genuine_unsatisfiable_range_and_correct_total',
    'rejects_forged_unsatisfiable_range_and_unrequested_416',
    'local_range_proxy_supports_seek_head_cors_and_token_guard_without_real_network',
    'aborted_first_upstream_connection_retries_identical_range_once',
    'transport_retries_only_reset_abort_and_eof_not_timeout_or_untrusted_http',
  ])assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Local synthetic HTTP only; Rust media API and allowlist preserved');
});
