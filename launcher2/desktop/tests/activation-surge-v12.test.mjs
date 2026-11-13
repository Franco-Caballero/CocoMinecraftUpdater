/**
 * Native Win32 activation surge, v12. Default run is a source contract check.
 * Opt-in: COCO2_ACTIVATION_SURGE_V12=1 node --test tests/activation-surge-v12.test.mjs
 * Cargo's test EXE spawns and reaps ONLY twelve test-owned child EXEs in
 * an isolated namespace. No Coco GUI, installer, HKCU, user saves or network.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const native=join(desktop,'src-tauri','src','services','activation.rs');
const testName='services::activation::tests::native_activation_surge_v12_cross_process_no_gui';
const enabled=process.platform==='win32'&&process.env.COCO2_ACTIVATION_SURGE_V12==='1';

test('client cannot use capability before server confirms Win32 named-pipe ACK',async()=>{
  const source=await readFile(native,'utf8');
  const server=source.slice(source.indexOf('fn run_pipe_server('),source.indexOf('fn start_pipe_server('));
  const client=source.slice(source.indexOf('fn get_pipe_capability('),source.indexOf('fn encode('));
  assert.match(server,/ack\[0\]==0xA5/);
  assert.match(server,/ready=\[0x5Au8\]/);
  assert.match(server,/receipt\[0\]==0xC3/);
  assert.match(client,/confirmed\[0\]!=0x5A/);
  assert.match(client,/receipt=\[0xC3u8\]/);
  assert.match(source,/native_pipe_capability_waits_for_server_ack_under_delayed_receipt/);
  assert.match(source,/assert!\(elapsed>=200/);
  assert.doesNotMatch(server,/FlushFileBuffers\s*\(/);
  assert.match(source,/PIPE_REJECT_REMOTE_CLIENTS/);
  assert.match(source,/peer_is_our_executable\(pid\)/);
  assert.match(source,/CAPABILITY_SIZE:usize=16/);
  assert.match(source,/if lock\[index\]\.1!=pid\{return false;\}/);
  assert.match(source,/ACTIVATION_CLOSED\.store\(true,Ordering::Release\)/);
});

test('native surge uses twelve owned Windows child PIDs and isolated namespace',async()=>{
  const source=await readFile(native,'utf8');
  const section=source.slice(source.indexOf('fn native_activation_surge_v12_cross_process_no_gui('));
  assert.match(section,/COCO2_ACTIVATION_SURGE_V12_CHILD/);
  assert.match(section,/start_isolated_for_test\(&id,Vec::new\(\)\)/);
  assert.match(section,/set_server_ack_delay_for_test\(35\)/);
  assert.match(section,/encode_utf16\(\)\.count\(\)>260/);
  assert.match(section,/for file in &files/);
  assert.match(section,/struct OwnedChildren/);
  assert.match(section,/let _=child\.kill\(\);let _=child\.wait\(\)/);
  assert.match(section,/HashSet/);
  assert.match(section,/take_pending_package_open_requests\(\)/);
  assert.match(section,/shutdown_activation\(\)\.unwrap\(\)/);
  assert.doesNotMatch(section,/Command::new\("(?:powershell|cmd|explorer)/i);
});

test('twelve concurrent real Win32 IPC senders retain all Unicode paths',{
  skip:!enabled?'Opt-in Windows native synthetic test only: COCO2_ACTIVATION_SURGE_V12=1':false,
  timeout:125_000,
},async t=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib',testName,
    '--','--nocapture','--test-threads=1',
  ],{
    cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,
    env:{...process.env,COCO2_ACTIVATION_REAL_E2E:'0'},
    stdio:['ignore','pipe','pipe'],
  });
  let stdout='',stderr='',timedOut=false;
  child.stdout.on('data',data=>{stdout=(stdout+data.toString()).slice(-150_000);});
  child.stderr.on('data',data=>{stderr=(stderr+data.toString()).slice(-70_000);});
  const timer=setTimeout(()=>{timedOut=true;child.kill();},110_000);
  let result;
  try{
    result=await new Promise((resolve,reject)=>{
      child.once('error',reject);
      child.once('close',(code,signal)=>resolve({code,signal}));
    });
  }finally{clearTimeout(timer);}
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'native surge watchdog expired:\n'+output.slice(-7000));
  assert.equal(result.code,0,'native surge Rust test failed:\n'+output.slice(-8000));
  const pids=[...output.matchAll(/COCO2_ACTIVATION_SURGE_SPAWN pid=(\d+)/g)]
    .map(match=>Number(match[1]));
  assert.equal(pids.length,12,'all twelve synthetic child process PIDs must be reported');
  assert.equal(new Set(pids).size,12,'all sender processes must be distinct');
  assert.match(output,/COCO2_ACTIVATION_SURGE_PASS count=12 distinct=12 closed=1 no_gui=1/);
  assert.match(output,/test result: ok\. 1 passed; 0 failed/);
  t.diagnostic('12 distinct child PIDs reaped; isolated Win32 path-only IPC, no GUI');
});
