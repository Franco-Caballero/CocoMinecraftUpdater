/**
 * Windows Explorer first-install contract without changing personal HKCU.
 * Source checks run by default. Native opt-in uses only the Rust unit-test
 * executable plus its test-owned secondary processes in synthetic TEMP:
 *   COCO2_EXPLORER_FIRST_INSTALL_V15=1 node --test tests/explorer-first-install-v15.test.mjs
 * Never execute NSIS, Explorer GUI, an installed Coco build, or any game.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const tauri=join(desktop,'src-tauri');
const native=join(tauri,'src','services','activation.rs');
const nsis=join(tauri,'windows','nsis','installer-safe.nsi');
const enabled=process.platform==='win32'&&process.env.COCO2_EXPLORER_FIRST_INSTALL_V15==='1';
const rustName='services::activation::tests::native_explorer_v15_delayed_first_install_handoff_without_gui';

test('first install registration is currentUser, reversible and limited to .coco2pack',async()=>{
  const code=await readFile(nsis,'utf8');
  const registered=code.slice(code.indexOf('Function Coco2PackRegister'),code.indexOf('Function un.Coco2PackUnregister'));
  const unregistered=code.slice(code.indexOf('Function un.Coco2PackUnregister'),code.indexOf('Section Install'));
  assert.match(code,/!if "\$\{INSTALLMODE\}" != "currentUser"/);
  assert.match(code,/!define COCO2PACK_EXT "\.coco2pack"/);
  assert.match(code,/!define COCO2PACK_PROGID "CocoLauncher2PortablePack"/);
  assert.match(code,/!if "\{\{ext\}\}" != "coco2pack"/);
  assert.doesNotMatch(code,/!define\s+COCO2PACK_EXT\s+"\.zip"/);
  assert.match(registered,/ReadRegStr \$R0 HKCR "\$\{COCO2PACK_EXT\}" ""/);
  assert.match(registered,/ReadRegStr \$R2 HKCU .*\\UserChoice" "ProgId"/);
  assert.match(registered,/ReadRegStr \$R3 HKCU .*\\UserChoice" "Hash"/);
  assert.match(registered,/WriteRegStr HKCU "\$\{COCO2PACK_CLASS\}\\shell\\open\\command"/);
  assert.ok(registered.includes(String.raw`$\"%1$\"`),'NSIS must quote the Explorer path parameter');
  assert.match(registered,/DefaultOwner/);
  assert.match(registered,/OpenWithOwner/);
  assert.match(unregistered,/ReadRegStr \$R0 HKCU "\$\{COCO2PACK_CLASS\}\\shell\\open\\command"/);
  assert.ok(unregistered.includes(String.raw`$R0 != "$\"$INSTDIR`),
    'Uninstall must require the exact own Explorer open-command before deleting values');
  assert.match(unregistered,/ReadRegStr \$R5 HKCU "\$\{COCO2PACK_OWNERSHIP\}" "DefaultOwner"/);
  assert.match(unregistered,/ReadRegStr \$R5 HKCU "\$\{COCO2PACK_OWNERSHIP\}" "OpenWithOwner"/);
  assert.doesNotMatch(registered+unregistered,/WriteReg(?:Str|DWORD) HKLM/);
  assert.doesNotMatch(unregistered,/DeleteRegKey HKCU "Software\\Classes\\\.zip"/);
});

test('cold/warm native queue remains bounded, authenticated and recovers exited clients',async()=>{
  const source=await readFile(native,'utf8');
  const issue=source.slice(source.indexOf('fn process_has_exited('),source.indexOf('fn consume_capability('));
  assert.match(issue,/WaitForSingleObject\(raw,0\)/);
  assert.match(issue,/GetLastError\(\)\}==ERROR_INVALID_PARAMETER/);
  assert.match(issue,/now\.duration_since\(\*born\)<Duration::from_secs\(10\)&&!process_has_exited\(\*owner\)/);
  assert.match(source,/fn orphaned_pipe_capabilities_do_not_block_healthy_first_install_handoff/);
  assert.match(source,/fn first_install_96th_unique_package_fits_exactly_but_97th_is_rejected/);
  assert.match(source,/const MAX_PENDING:usize=96/);
  assert.match(source,/peer_is_our_executable\(peer_pid\)/);
  assert.match(source,/peer_is_our_executable\(server_pid\)/);
  assert.match(source,/if lock\[index\]\.1!=pid\{return false;\}/);
  assert.match(source,/PIPE_REJECT_REMOTE_CLIENTS/);
  assert.match(source,/if meta\.file_type\(\)\.is_symlink\(\)/);
  assert.match(source,/fn cancel_pending_package_open_request/);
  assert.match(source,/fn shutdown_activation/);
});

test('slow first launch waits boundedly for private pipe and never attempts auto-import',async()=>{
  const source=await readFile(native,'utf8');
  const start=source.indexOf('fn get_pipe_capability(');
  const end=source.indexOf('fn delayed_ack_contract_for_test',start);
  const auth=source.slice(start,end);
  assert.match(auth,/let connect_deadline=Instant::now\(\)\+Duration::from_secs\(9\)/);
  assert.match(auth,/if Instant::now\(\)>=connect_deadline/);
  assert.match(auth,/WaitNamedPipeW\(name\.as_ptr\(\),75\)/);
  assert.match(auth,/GetNamedPipeServerProcessId/);
  assert.match(source,/fn native_explorer_v15_delayed_first_install_handoff_without_gui/);
  assert.match(source,/delay_primary_listener_for_test\(2_400\)/);
  assert.match(source,/\"abort-no-ack\"/);
  assert.match(source,/\"warm-repeat\"/);
  assert.match(source,/\"warm-after-shutdown\"/);
  assert.doesNotMatch(source,/Command::new\("(?:powershell|reg|msiexec|explorer)"\)|HKEY_CURRENT_USER|\.install\(/i);
  assert.match(source,/pub const PACKAGE_OPEN_EVENT:&str="coco2:\/\/package-open-request"/);
});

test('actual Win32 test-owned cold/slow warm, lost ACK, burst and shutdown',{
  skip:!enabled?'Opt-in Windows only: COCO2_EXPLORER_FIRST_INSTALL_V15=1':false,
  timeout:145_000,
},async t=>{
  const child=spawn('cargo',['test','--offline','--locked','--lib',rustName,
    '--','--nocapture','--test-threads=1'],{
    cwd:tauri,shell:false,windowsHide:true,
    env:{...process.env,COCO2_ACTIVATION_REAL_E2E:'0'},
    stdio:['ignore','pipe','pipe'],
  });
  let stdout='',stderr='',timedOut=false;
  child.stdout.on('data',chunk=>{stdout=(stdout+chunk.toString()).slice(-150_000);});
  child.stderr.on('data',chunk=>{stderr=(stderr+chunk.toString()).slice(-70_000);});
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},130_000);
  let result;
  try {
    result=await new Promise((resolve,reject)=>{
      child.once('error',reject);
      child.once('close',(code,signal)=>resolve({code,signal}));
    });
  } finally { clearTimeout(watchdog); }
  const output=stdout+'\n'+stderr;
  assert.equal(timedOut,false,'test-owned native first-install watchdog expired:\n'+output.slice(-6000));
  assert.equal(result.code,0,'Native Explorer first-install failed:\n'+output.slice(-10000));
  const pids=[...output.matchAll(/COCO2_EXPLORER_FIRST_INSTALL_SPAWN mode=\S+ pid=(\d+)/g)]
    .map(match=>Number(match[1]));
  assert.equal(pids.length,7,'all seven synthetic secondary processes must have started');
  assert.equal(new Set(pids).size,7,'secondary PIDs must be distinct');
  assert.match(output,/COCO2_EXPLORER_FIRST_INSTALL_PASS children=7 cold=1 warm=2 replay=0 expired_ack=1 untrusted=1 shutdown=1 no_gui=1/);
  assert.match(output,/test result: ok\. 1 passed; 0 failed/);
  t.diagnostic('Native unit-test EXE and seven owned helper processes only; installer and HKCU unchanged');
});
