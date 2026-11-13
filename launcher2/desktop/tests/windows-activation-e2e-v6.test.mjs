/**
 * Coco2 v0.6.0 REAL Win32 IPC cold/warm regression.
 *
 * Default npm test: non-invasive contract only; NO executable starts.
 *
 * Explicit opt-in on Windows:
 *   $env:COCO2_WINDOWS_ACTIVATION_E2E='1'
 *   node --test tests/windows-activation-e2e-v6.test.mjs
 *
 * Starts ONLY a Cargo Rust test EXE, never the installed/release Coco2 app.
 * The native test uses independent Windows PIDs, authenticated private IPC,
 * a test-only mutex namespace, and disposable non-ZIP "package" files.
 * It does not create Tauri windows, register HKCU, access real games, install
 * software, load credentials, or connect to the network.
 *
 * Actual Explorer/NSIS association, visible Tauri foreground, and installed
 * frontend event delivery remain UNVERIFIED by this deliberately isolated E2E.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=join(desktop,'src-tauri');
const ownedSource=join(rust,'src','services','activation.rs');
const nativeTest='services::activation::tests::isolated_real_cold_warm_single_instance_two_processes_no_gui';
const enabled=process.platform==='win32'&&process.env.COCO2_WINDOWS_ACTIVATION_E2E==='1';

test('activation E2E uses only a test executable and isolated mutex namespace',async()=>{
  const code=await readFile(ownedSource,'utf8');
  assert.match(code,/fn isolated_real_cold_warm_single_instance_two_processes_no_gui\(/);
  assert.match(code,/COCO2_ACTIVATION_REAL_E2E/);
  assert.match(code,/Coco2\.TEST\.FileActivation/);
  assert.match(code,/start_isolated_for_test\(/);
  assert.match(code,/COCO2_ACTIVATION_E2E_PASS primary_pid=/);
  assert.match(code,/COCO2_ACTIVATION_E2E_SPAWN pid=/);
  assert.match(code,/GetNamedPipeClientProcessId/);
  assert.match(code,/GetNamedPipeServerProcessId/);
  assert.match(code,/consume_capability/);
  assert.match(code,/SendMessageTimeoutW/);
  assert.match(code,/SetForegroundWindow/);
  assert.match(code,/r"\\\\untrusted-server\\share\\forged\.coco2pack"/);
  assert.match(code,/warm-burst/);
  assert.match(code,/warm-repeated/);
  assert.match(code,/warm-no-files/);
  assert.match(code,/warm-fifo-24/);
  assert.match(code,/warm-after-shutdown/);
  assert.match(code,/abort-auth-pipe/);
  assert.match(code,/abort-no-ack/);
  assert.match(code,/abort-after-token/);
  assert.match(code,/abandoned_pipe_client_for_test/);
  assert.match(code,/unacknowledged_pipe_client_for_test/);
  assert.match(code,/revoke_capability/);
  assert.match(code,/cancel_pending_package_open_request/);
  assert.match(code,/shutdown_activation/);
  assert.match(code,/PeekNamedPipe/);
  assert.doesNotMatch(code,/FlushFileBuffers\(/);
  assert.doesNotMatch(code,/Command::new\("powershell"|reg(?:\.exe)?\s+add|HKEY_CURRENT_USER/i);
});

// Node only invokes Cargo on explicit opt-in. Rust's synthetic test starts
// and reaps every warm child. On watchdog timeout Node terminates ONLY the
// Cargo process that this test itself spawned; it never kills by image name.
test('real Windows cold and warm activation using two synthetic EXE processes',{
  skip:!enabled
    ? 'Opt-in Windows only: COCO2_WINDOWS_ACTIVATION_E2E=1 (never start personal Coco2)'
    : false,
  timeout:180_000,
},async t=>{
  let stdout='',stderr='';
  let timedOut=false;
  const syntheticPids=new Set();
  const cap=2*1024*1024;
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib',nativeTest,
    '--','--nocapture','--test-threads=1',
  ],{
    cwd:rust,
    env:{...process.env,COCO2_ACTIVATION_REAL_E2E:'1'},
    stdio:['ignore','pipe','pipe'],
    windowsHide:true,
    shell:false,
  });
  const collect=(stream,data)=>{
    const chunk=data.toString('utf8');
    if(stream==='stdout')stdout=(stdout+chunk).slice(-cap);
    else stderr=(stderr+chunk).slice(-cap);
    for(const match of (stdout+'\n'+stderr)
        .matchAll(/COCO2_ACTIVATION_E2E_(?:START primary_pid|SPAWN pid)=(\d+)/g)){
      const pid=Number(match[1]);
      if(Number.isSafeInteger(pid)&&pid>0)syntheticPids.add(pid);
    }
  };
  cargo.stdout.on('data',chunk=>collect('stdout',chunk));
  cargo.stderr.on('data',chunk=>collect('stderr',chunk));
  const completion=new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  });
  const watchdog=setTimeout(()=>{
    timedOut=true;
    if(cargo.pid)cargo.kill();
  },135_000);
  let result;
  try{result=await completion;}
  finally{clearTimeout(watchdog);}
  const combined=stdout+'\n'+stderr;
  t.diagnostic('Synthetic native E2E: '+syntheticPids.size+' test PID markers, Cargo exit '+result.code);
  assert.equal(timedOut,false,'isolated Rust test timed out:\n'+combined.slice(-5000));
  assert.equal(result.code,0,'isolated activation failed (not personal app):\n'+combined.slice(-7000));
  assert.match(combined,/running 1 test/);
  assert.match(combined,/test result: ok\. 1 passed; 0 failed/);
  const evidence=combined.match(/COCO2_ACTIVATION_E2E_PASS primary_pid=(\d+) warm_pids=\[([0-9,\s]+)\] cold=1 warm=1 rejected=3 aborted=3 replay=0 cancelled=1 reopened=1 fifo24=1 shutdown=1 idle_cpu_ms=(\d+) no_gui=1/);
  assert.ok(evidence,'Rust did not confirm cold/warm, cancellation, replay, CPU and shutdown');
  const primary=Number(evidence[1]);
  const secondary=evidence[2].split(',').map(s=>Number(s.trim()));
  const cpuMs=Number(evidence[3]);
  assert.ok(cpuMs<150,'Win32 idle listener must not spin CPU');
  assert.equal(secondary.length,13,
    'three rejected, three aborted authentication peers, burst/replay/no-file, cancel/reopen, post-drain, FIFO-24 and shutdown');
  assert.equal(new Set([primary,...secondary]).size,14,'all fourteen Windows PIDs must differ');
  assert.ok(syntheticPids.has(primary));
  assert.ok(secondary.every(pid=>syntheticPids.has(pid)));

  // Optional read-only CIM inspection, restricted to exact, already recorded
  // test PIDs. Neither process names nor system-wide services are enumerated.
  const cim=await checkOnlySyntheticPids([primary,...secondary]);
  if(cim.available){
    assert.deepEqual(cim.stillRunning,[],
      'the fourteen test EXE processes must exit without terminating other processes');
    t.diagnostic('CIM confirms all fourteen test-owned PIDs have exited.');
  }else{
    t.diagnostic('PID-scoped CIM unavailable: '+cim.reason+'; exit statuses verified.');
  }
});

async function checkOnlySyntheticPids(pids){
  if(process.platform!=='win32'||pids.length===0)return {available:false,reason:'not Windows'};
  const ids=pids.filter(pid=>Number.isInteger(pid)&&pid>0&&pid<0x80000000);
  if(ids.length!==pids.length)return {available:false,reason:'invalid PID evidence'};
  const command=[
    '$ids=@('+ids.join(',')+');',
    '$items=@();',
    'foreach($number in $ids){',
    ' $p=Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId="+$number) -ErrorAction Stop;',
    ' if($p -and $p.Name -like "coco_launcher_2_lib-*.exe"){ $items+=@($p.ProcessId) }',
    '}',
    '$items | ConvertTo-Json -Compress',
  ].join(' ');
  try{
    const result=await runBounded('powershell.exe',[
      '-NoProfile','-NonInteractive','-Command',command,
    ],12_000);
    if(result.code!==0)return {available:false,reason:'CIM query denied'};
    const raw=result.stdout.trim();
    const parsed=raw?JSON.parse(raw):[];
    const stillRunning=(Array.isArray(parsed)?parsed:[parsed]).filter(Number.isInteger);
    return {available:true,stillRunning};
  }catch(error){
    return {available:false,reason:error.message};
  }
}

async function runBounded(executable,args,timeoutMs){
  const child=spawn(executable,args,{windowsHide:true,stdio:['ignore','pipe','pipe'],shell:false});
  let stdout='',stderr='';
  child.stdout.on('data',bytes=>{stdout=(stdout+bytes.toString('utf8')).slice(-65536);});
  child.stderr.on('data',bytes=>{stderr=(stderr+bytes.toString('utf8')).slice(-65536);});
  let timedOut=false;
  const timer=setTimeout(()=>{
    timedOut=true;
    if(child.pid)child.kill(); // Exact process we created, never a user app.
  },timeoutMs);
  try{
    const result=await new Promise((resolve,reject)=>{
      child.once('error',reject);
      child.once('close',(code,signal)=>resolve({code,signal}));
    });
    if(timedOut)throw new Error('PID-scoped CIM query timed out');
    return {...result,stdout,stderr};
  }finally{clearTimeout(timer);}
}
