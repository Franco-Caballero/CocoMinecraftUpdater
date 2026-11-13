/**
 * Coco2 v0.6.3: test-only Win32 Explorer cold/warm file activation.
 * Explicit opt-in: COCO2_EXPLORER_V13_E2E=1 node --test tests/explorer-native-v13.test.mjs
 * No installed Coco app, GUI, NSIS, user registry, network, or game processes.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const native=join(desktop,'src-tauri','src','services','activation.rs');
const testName='services::activation::tests::native_explorer_v13_long_duplicate_fifo_cancel_shutdown';
const enabled=process.platform==='win32'&&process.env.COCO2_EXPLORER_V13_E2E==='1';

test('duplicate canonical paths only consume actual encoded IPC budget',async()=>{
  const source=await readFile(native,'utf8');
  const start=source.indexOf('fn parse<I>(args:I,source:');
  const end=source.indexOf('fn select_requests(',start);
  const parse=source.slice(start,end);
  assert.ok(start>=0&&end>start);
  assert.ok(parse.indexOf('if result.iter().any(')<parse.indexOf('total=total.saturating_add('),
    'duplicates must be removed before charging the IPC budget');
  assert.match(source,/fn repeated_long_path_dedup_does_not_spend_ipc_budget_on_duplicates/);
  assert.match(source,/fn native_explorer_v13_long_duplicate_fifo_cancel_shutdown/);
  assert.match(source,/MAX_REQUESTS:usize=24/);
  assert.match(source,/MAX_PAYLOAD:usize=128\*1024/);
  assert.match(source,/if supplied>MAX_REQUESTS\{return Err/);
  assert.match(source,/if total>MAX_PAYLOAD\{return Err/);
});

test('Win32 IPC hardening, cancellation and isolation contracts remain intact',async()=>{
  const source=await readFile(native,'utf8');
  assert.match(source,/peer_is_our_executable\(peer_pid\)/);
  assert.match(source,/peer_is_our_executable\(server_pid\)/);
  assert.match(source,/consume_capability\(&raw\[\.\.CAPABILITY_SIZE\],pid\)/);
  assert.match(source,/if lock\[index\]\.1!=pid\{return false;\}/);
  assert.match(source,/PIPE_REJECT_REMOTE_CLIENTS/);
  assert.match(source,/if meta\.file_type\(\)\.is_symlink\(\)/);
  assert.match(source,/meta\.file_attributes\(\)&0x400!=0/);
  assert.match(source,/UNC and native device paths are not accepted/);
  assert.match(source,/fn cancel_pending_package_open_request/);
  assert.match(source,/fn shutdown_activation/);
  assert.match(source,/fn start_isolated_for_test/);
  assert.match(source,/symlink_file\(&first,&link\)/);
  assert.doesNotMatch(source,/Command::new\("powershell"|reg(?:\.exe)?\s+add|HKEY_CURRENT_USER/i);
});

test('native process-owned Explorer E2E: 10 isolated PIDs and long Unicode reentrancy',{
  skip:!enabled?'Opt-in Win32 native E2E: COCO2_EXPLORER_V13_E2E=1':false,
  timeout:120_000,
},async t=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib',testName,'--','--nocapture','--test-threads=1',
  ],{
    cwd:join(desktop,'src-tauri'),shell:false,windowsHide:true,
    env:{...process.env,COCO2_ACTIVATION_REAL_E2E:'0'},
    stdio:['ignore','pipe','pipe'],
  });
  let stdout='',stderr='',timedOut=false;
  child.stdout.on('data',chunk=>{stdout=(stdout+chunk.toString()).slice(-110_000);});
  child.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-70_000);});
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},110_000);
  let outcome;
  try{
    outcome=await new Promise((resolve,reject)=>{
      child.once('error',reject);
      child.once('close',(code,signal)=>resolve({code,signal}));
    });
  }finally{clearTimeout(watchdog);}
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'E2E native watchdog expired:\n'+output.slice(-6000));
  assert.equal(outcome.code,0,'E2E native Cargo failed:\n'+output.slice(-9000));
  const pids=[...output.matchAll(/COCO2_EXPLORER_V13_SPAWN pid=(\d+)/g)].map(match=>Number(match[1]));
  assert.equal(pids.length,10,'10 synthetic secondaries must have started');
  assert.equal(new Set(pids).size,10,'all Win32 subprocess PIDs must differ');
  assert.match(output,/COCO2_EXPLORER_V13_PASS children=10 cold=1 warm=2 dedup24=1 fifo=1 cancel=1 closed=1 symlink_checked=[01] no_gui=1/);
  assert.match(output,/test result: ok\. 1 passed; 0 failed/);
  t.diagnostic('10 owned child PIDs exited; no installed Coco, Explorer GUI or HKCU used');
});
