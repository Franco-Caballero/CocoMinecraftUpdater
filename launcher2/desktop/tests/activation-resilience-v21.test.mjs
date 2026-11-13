/**
 * Windows first/second instance file-open resilience. No actual Coco UI,
 * registry writes, installation, user games, internet or owned profile data.
 * Test-only Windows native opt-in:
 *   COCO2_ACTIVATION_RESILIENCE_V21=1 node --test tests/activation-resilience-v21.test.mjs
 * The native Rust tests use isolated Win32 class/mutex/pipe namespaces and
 * TEMP Unicode package paths. Child EXEs are the exact Cargo test-owned binary.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const tauri=join(desktop,'src-tauri');
const native=await readFile(join(tauri,'src','services','activation.rs'),'utf8');
const enabled=process.platform==='win32'&&process.env.COCO2_ACTIVATION_RESILIENCE_V21==='1';
const skipNative=enabled?false:'Requires Windows native TEMP opt-in COCO2_ACTIVATION_RESILIENCE_V21=1';

test('native frontend drain linearizes with failed delivery before exposing recovered FIFO',()=>{
  const start=native.indexOf('pub fn take_pending_package_open_requests()');
  const end=native.indexOf('pub fn shutdown_activation()',start);
  assert.ok(start>=0&&end>start);
  const drain=native.slice(start,end);
  assert.match(drain,/let Ok\(_ordered\)=delivery\(\)\.lock\(\)/);
  assert.ok(drain.indexOf('delivery().lock()')<drain.indexOf('state().lock()'),
    'must acquire DELIVERY before STATE; queue and shutdown use the same order');
  assert.match(drain,/state\.items\.drain\(\.\.\)\.collect\(\)/);
  assert.match(native,/fn v21_failed_ui_emit_racing_native_drain_never_strands_pending_fifo/);
  assert.match(native,/deliver_with_fallback\(state\(\),outbound,\|_item\|/);
});

test('cold/warm transfer remains authenticated, path-only, bounded and user-controlled',()=>{
  assert.match(native,/const MAX_REQUESTS:usize=24/);
  assert.match(native,/const MAX_PENDING:usize=96/);
  assert.match(native,/const REPLAY_WINDOW:Duration=Duration::from_secs\(2\)/);
  assert.match(native,/fn peer_is_our_executable\(pid:u32\)->bool/);
  assert.match(native,/fn consume_capability\(token:&\[u8\],pid:u32\)->bool/);
  assert.match(native,/let connect_deadline=Instant::now\(\)\+Duration::from_secs\(9\)/);
  assert.match(native,/fn get_pipe_capability\(name:&\[u16\]\)->Result/);
  assert.match(native,/fn handoff\(class:&\[u16\],title:&\[u16\],requests:&\[PackageOpenRequest\]\)/);
  assert.match(native,/fn checked_path\(raw:&OsString\)->Result<String,String>/);
  assert.match(native,/UNC and native device paths are not accepted/);
  assert.match(native,/pub fn cancel_pending_package_open_request\(path:String\)->bool/);
  assert.doesNotMatch(native,/(?:import_local_publish_package|install_standalone|launch_standalone)\s*\(/);
});

async function runRust(name,extraEnv={}){
  const child=spawn('cargo',['test','--offline','--locked','--lib',name,
    '--','--nocapture','--test-threads=1'],{
    cwd:tauri,shell:false,windowsHide:true,
    env:{...process.env,...extraEnv},stdio:['ignore','pipe','pipe'],
  });
  let stdout='',stderr='',timedOut=false;
  child.stdout.on('data',buffer=>{stdout=(stdout+buffer.toString()).slice(-120_000);});
  child.stderr.on('data',buffer=>{stderr=(stderr+buffer.toString()).slice(-40_000);});
  const timer=setTimeout(()=>{timedOut=true;child.kill();},135_000);
  let result;
  try{
    result=await new Promise((done,fail)=>{
      child.once('error',fail);
      child.once('close',(code,signal)=>done({code,signal}));
    });
  }finally{clearTimeout(timer);}
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'Cargo native test watchdog expired:\n'+output.slice(-8000));
  assert.equal(result.code,0,'Native activation regression failed:\n'+output.slice(-16000));
  return output;
}

test('real native Windows queue/read race RED→GREEN with TEMP Unicode files',{
  skip:skipNative,timeout:160_000,
},async()=>{
  const name='v21_failed_ui_emit_racing_native_drain_never_strands_pending_fifo';
  const output=await runRust(name);
  assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. 1 passed; 0 failed/);
});

test('isolated 7-child cold/warm first-install handshake, crash, FIFO, replay, UNC and shutdown',{
  skip:skipNative,timeout:160_000,
},async t=>{
  // This EXISTING native test is run from a fresh Cargo test process so its
  // shutdown cannot poison other tests' process-global activation state.
  const name='native_explorer_v15_delayed_first_install_handoff_without_gui';
  const output=await runRust(name,{COCO2_EXPLORER_FIRST_INSTALL_V15:'1'});
  assert.match(output,/COCO2_EXPLORER_FIRST_INSTALL_PASS children=7 cold=1 warm=2 replay=0 expired_ack=1 untrusted=1 shutdown=1 no_gui=1/);
  assert.match(output,/test result: ok\. 1 passed; 0 failed/);
  t.diagnostic('Validated 7 test-owned Win32 children, not a user-installed launcher');
});
