/**
 * Coco2 native Explorer delivery v7. Source-only by default, and an explicit
 * test-owned Rust IPC E2E on Windows:
 *   $env:COCO2_ACTIVATION_V7_E2E='1'
 *   node --test tests/activation-v7.test.mjs
 * The Rust test binary alone may spawn a second identical synthetic test EXE;
 * no HKCU, Explorer, installed Coco2, GUI, user package or external network.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=join(desktop,'src-tauri');
const source=()=>readFile(join(rust,'src','services','activation.rs'),'utf8');

test('wrong-PID capability never consumes the rightful Win32 authenticated sender token',async()=>{
  const code=await source();
  assert.match(code,/fn consume_capability\(token:&\[u8\],pid:u32\)->bool/);
  const functionText=code.slice(code.indexOf('fn consume_capability(token:&[u8],pid:u32)->bool'),
    code.indexOf('fn revoke_capability('));
  const check=functionText.indexOf('if lock[index].1!=pid{return false;}');
  const consume=functionText.indexOf('lock.swap_remove(index)');
  assert.ok(check>=0&&consume>check,'PID must be authenticated before destructive token removal');
  assert.match(code,/wrong PID must not destroy the legitimate sender's token/);
  assert.match(code,/the legitimate sender cannot replay its consumed capability/);
  assert.match(code,/GetNamedPipeClientProcessId/);
  assert.match(code,/GetNamedPipeServerProcessId/);
  assert.match(code,/peer_is_our_executable/);
});

test('warm wake notification never acknowledges a path; legacy failed-emit FIFO regression remains',async()=>{
  const code=await source();
  const queue=code.slice(code.indexOf('fn queue(requests:'),code.indexOf('/// Attach from tauri Builder.setup'));
  assert.match(code,/static DELIVERY:OnceLock<Mutex<\(\)>>/);
  assert.match(code,/let _ordered=delivery\(\)\.lock\(\)\.map_err/);
  assert.match(queue,/select_requests\(&mut current,requests,Instant::now\(\),false\)\?/);
  assert.match(queue,/app\.emit\(PACKAGE_OPEN_EVENT,\(\)\)/);
  assert.doesNotMatch(queue,/select_with_backlog|deliver_with_fallback|items\.drain/);
  assert.match(code,/pub fn take_pending_package_open_requests\(\)->Vec<PackageOpenRequest>/);
  assert.match(code,/pub fn confirm_package_open_listener_ready\(\)->bool/);
  // Keep historic helper tests as a regression for failed event emission,
  // although direct event dispatch is no longer part of active queue().
  assert.match(code,/fn deliver_with_fallback\(/);
  assert.match(code,/current\.items\.extend\(undelivered\.drain\(\.\.\)\)/);
  assert.match(code,/return Err\("Package activation UI event failed; undelivered paths retained"/);
  assert.match(code,/if !can_emit\{return Ok\(fresh\);\}/);
  assert.match(code,/let mut outbound:Vec<_>=current\.items\.drain\(\.\.\)\.collect\(\)/);
  assert.match(code,/outbound\.append\(&mut fresh\)/);
  assert.match(code,/failed_ui_emit_returns_error_and_recovers_fifo_before_new_warm_requests/);
  assert.match(code,/if ACTIVATION_CLOSED\.load\(Ordering::Acquire\)\{/);
  assert.doesNotMatch(code,/FlushFileBuffers\(|HKEY_CURRENT_USER|Command::new\("powershell"/i);
});

test('24-path batch and 96-slot queue remain bounded, with actual Win32 handoff regression',async()=>{
  const [code,v6]=await Promise.all([
    source(),readFile(join(desktop,'tests','windows-activation-e2e-v6.test.mjs'),'utf8'),
  ]);
  assert.match(code,/const MAX_REQUESTS:usize=24;/);
  assert.match(code,/const MAX_PENDING:usize=96;/);
  assert.match(code,/if supplied>MAX_REQUESTS\{return Err/);
  assert.match(code,/current\.items\.len\(\)\.saturating_add\(accepted\.len\(\)\)>=MAX_PENDING/);
  assert.match(code,/current\.recent\.len\(\)\.saturating_add\(accepted\.len\(\)\)>=MAX_PENDING/);
  assert.match(code,/warm-fifo-24/);
  assert.match(code,/cross-process delivery must preserve all 24 requests FIFO/);
  assert.match(code,/COCO2_ACTIVATION_E2E_PASS primary_pid=/);
  assert.match(v6,/fifo24=1/);
  assert.match(v6,/secondary\.length,13/);
  assert.match(v6,/shell:false/);
});

test('native Rust synthetic 2-PID tests and replay/FIFO/capability cases', {
  skip:process.platform==='win32'&&process.env.COCO2_ACTIVATION_V7_E2E==='1'
    ? false : 'Opt-in Windows: COCO2_ACTIVATION_V7_E2E=1',
  timeout:150_000,
},async t=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','--lib','services::activation::tests',
    '--','--test-threads=1',
  ],{
    cwd:rust,windowsHide:true,shell:false,
    env:{...process.env,COCO2_ACTIVATION_REAL_E2E:'0'},
    stdio:['ignore','pipe','pipe'],
  });
  let stdout='',stderr='';
  child.stdout.on('data',b=>{stdout=(stdout+b.toString()).slice(-48_000);});
  child.stderr.on('data',b=>{stderr=(stderr+b.toString()).slice(-48_000);});
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},130_000);
  const result=await new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'Rust synthetic activation tests timed out:\n'+output);
  assert.equal(result.code,0,'Rust activation suite failed:\n'+output);
  for(const name of [
    'failed_ui_emit_returns_error_and_recovers_fifo_before_new_warm_requests',
    'authenticated_capability_is_single_use_and_wrong_pid_is_rejected',
    'actual_two_win32_processes_authenticate_and_deliver_unicode_path',
    'replay_burst_cancellation_and_capacity_are_bounded_and_atomic',
  ])assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
  t.diagnostic('Synthetic Windows IPC only; no installed application or HKCU invoked');
});
