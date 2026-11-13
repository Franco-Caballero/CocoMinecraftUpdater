/** v27: Native Explorer FIFO must survive uncommitted React reads, and the
 * self-updater must never mistake an undisplayed native request for an empty
 * inbox. Source contracts + execution of actual TSX and pump via VM mocks.
 * TEMP-only; no Windows registry, installers, games or external network. */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [native,lib,main,helper]=await Promise.all([
  readFile(resolve(root,'src-tauri/src/services/activation.rs'),'utf8'),
  readFile(resolve(root,'src-tauri/src/lib.rs'),'utf8'),
  readFile(resolve(root,'src/main.tsx'),'utf8'),
  readFile(resolve(root,'src/package-activation-drain.ts'),'utf8'),
]);
const ast=ts.createSourceFile('main.tsx',main,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
let updateSource;
function visit(node){
  if(ts.isVariableDeclaration(node)&&node.name.getText(ast)==='applyAppUpdate')
    updateSource=node.initializer?.getText(ast);
  ts.forEachChild(node,visit);
}
visit(ast);
assert.ok(updateSource);
const transpile=expr=>ts.transpileModule('('+expr+')',{
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None},
}).outputText;

test('native activation exposes non-destructive read and FIFO-prefix receipt ACK',()=>{
  assert.match(native,/pub fn peek_pending_package_open_requests\(\)->Vec<PackageOpenRequest>/);
  const peek=native.slice(native.indexOf('pub fn peek_pending_package_open_requests()'),native.indexOf('pub fn take_pending_package_open_requests()'));
  assert.match(peek,/state\.items\.iter\(\)\.cloned\(\)\.collect\(\)/);
  assert.doesNotMatch(peek,/\.drain\(/);
  assert.match(native,/pub fn acknowledge_pending_package_open_requests\(paths:Vec<String>\)->bool/);
  assert.match(native,/pub fn has_pending_package_open_requests\(\)->bool/);
  assert.match(native,/pub fn try_arm_app_update_install\(\)->bool/);
  assert.match(native,/pub fn finish_app_update_install_guard\(\)->bool/);
  for(const name of ['peek_pending_package_open_requests','acknowledge_pending_package_open_requests','has_pending_package_open_requests'])
    assert.match(lib,new RegExp(`services::activation::${name}`));
  assert.match(lib,/services::activation::try_arm_app_update_install/);
  assert.match(lib,/services::activation::finish_app_update_install_guard/);
  const queue=native.slice(native.indexOf('fn queue(requests:'),native.indexOf('/// Attach from tauri Builder.setup'));
  assert.match(queue,/APP_UPDATE_INSTALL_ARMED\.load\(Ordering::Acquire\)/);
});

test('real frontend activation effect only ACKs after sync React inbox commit, not on event or a disposed drain',()=>{
  const section=main.slice(main.indexOf('// Explorer activation carries untrusted paths'),main.indexOf('// Reconcile interrupted native operations'));
  assert.match(section,/peek_pending_package_open_requests/);
  assert.match(section,/acknowledge_pending_package_open_requests/);
  assert.match(section,/listen<unknown>\('coco2:\/\/package-open-request',_event=>void drain\.trigger\(\)\)/);
  assert.match(helper,/private readonly acknowledgeNative/);
  assert.match(helper,/this\.presentForReview\(pending\)/);
  assert.match(helper,/await this\.acknowledgeNative\(pending\)/);
  assert.doesNotMatch(section,/event=>enqueue\(event\.payload\)/);
});

test('actual app updater refuses restart if Rust still holds an authenticated unseen package',async()=>{
  const calls=[];let stage={stage:'idle',message:''};
  const update={version:'0.6.12',download:async()=>calls.push('download'),
    install:async()=>calls.push('install'),close:async()=>calls.push('close')};
  const context={
    isTauri:()=>true,updateRunning:{current:false},updateAttempt:{current:0},
    pendingPackageInboxRef:{current:false},
    nativeOperationGate:{current:{busy:()=>false}},mediaDownloadGate:{current:{busy:()=>false}},
    mediaPrepareGate:{current:{busy:()=>false}},mediaPlaying:null,streamLoading:null,
    mediaDownloadActive:false,installing:null,upgrading:null,upgradeRecovering:null,
    preparingRepair:null,repairCommitting:null,repairRecovering:null,
    checkingRepair:null,busy:false,activeVerification:null,checkingManaged:null,
    savingIdentity:false,hostStudioOpen:false,installingNetwork:false,joiningNetwork:false,
    runtime:null,console:{error:()=>{}},performance:{now:()=>10},
    setAppUpdate:next=>{stage=typeof next==='function'?next(stage):next;},
    loadUpdaterPlugin:async()=>({check:async()=>update}),
    AppUpdaterProgressMeter:class{consume(){return null;}snapshot(){return {downloaded:12,total:12};}},
    invoke:async name=>{
      calls.push(name);
      if(name==='list_running_games')return [];
      if(name==='get_active_game_processes')return {status:'none',safeToUpdate:true};
      if(name==='has_pending_package_open_requests')return true;
      throw Error('unexpected IPC '+name);
    },
  };
  const js=transpile(updateSource.replaceAll("await import('@tauri-apps/plugin-updater')",'await loadUpdaterPlugin()'));
  const apply=vm.runInNewContext(js,context,{timeout:1000});
  await apply();
  assert.ok(calls.includes('has_pending_package_open_requests'));
  assert.ok(!calls.includes('install'),'native pending cannot be mistaken for empty React inbox');
  assert.equal(stage.stage,'deferred');
  assert.equal(context.updateRunning.current,false);
});

test('a new native activation racing after the final poll prevents updater install through an atomic arm',async()=>{
  const calls=[];let stage={stage:'idle'};
  const update={version:'0.6.12',download:async()=>calls.push('download'),
    install:async()=>calls.push('install'),close:async()=>calls.push('close')};
  const context={
    isTauri:()=>true,updateRunning:{current:false},updateAttempt:{current:0},
    pendingPackageInboxRef:{current:false},
    nativeOperationGate:{current:{busy:()=>false}},mediaDownloadGate:{current:{busy:()=>false}},
    mediaPrepareGate:{current:{busy:()=>false}},mediaPlaying:null,streamLoading:null,
    mediaDownloadActive:null,installing:null,upgrading:null,upgradeRecovering:null,
    preparingRepair:null,repairCommitting:null,repairRecovering:null,
    checkingRepair:null,busy:false,activeVerification:null,checkingManaged:null,
    savingIdentity:false,hostStudioOpen:false,installingNetwork:false,joiningNetwork:false,
    runtime:null,console:{error:()=>{},warn:()=>{}},performance:{now:()=>10},
    setAppUpdate:next=>{stage=typeof next==='function'?next(stage):next;},
    loadUpdaterPlugin:async()=>({check:async()=>update}),
    AppUpdaterProgressMeter:class{consume(){return null;}snapshot(){return {downloaded:12,total:12};}},
    invoke:async name=>{
      calls.push(name);
      if(name==='has_pending_package_open_requests')return false;
      if(name==='list_running_games')return [];
      if(name==='get_active_game_processes')return {status:'none',safeToUpdate:true};
      if(name==='try_arm_app_update_install')return false; // WM_COPYDATA accepted just before atomic arm
      if(name==='finish_app_update_install_guard')return true;
      throw Error('unexpected IPC '+name);
    },
  };
  const js=transpile(updateSource.replaceAll("await import('@tauri-apps/plugin-updater')",'await loadUpdaterPlugin()'));
  await vm.runInNewContext(js,context,{timeout:1000})();
  assert.ok(calls.includes('try_arm_app_update_install'));
  assert.ok(!calls.includes('install'),'updater must never start while a native sender won the race');
  assert.equal(stage.stage,'deferred');
  assert.ok(calls.includes('close'));
});

test('native operation begun during updater download blocks restart even before React busy state commits',async()=>{
  const calls=[];let stage={stage:'idle'};
  let started,complete;
  const downloadStarted=new Promise(r=>started=r);
  const downloadComplete=new Promise(r=>complete=r);
  const gate={current:false};
  const update={version:'0.6.12',download:async()=>{calls.push('download');started();await downloadComplete;},
    install:async()=>calls.push('install'),close:async()=>calls.push('close')};
  const context={
    isTauri:()=>true,updateRunning:{current:false},updateAttempt:{current:0},
    pendingPackageInboxRef:{current:false},nativeOperationGate:{current:{busy:()=>gate.current}},
    mediaDownloadGate:{current:{busy:()=>false}},mediaPrepareGate:{current:{busy:()=>false}},
    mediaPlaying:null,streamLoading:null,mediaDownloadActive:null,installing:null,upgrading:null,
    upgradeRecovering:null,preparingRepair:null,repairCommitting:null,repairRecovering:null,
    checkingRepair:null,busy:false,activeVerification:null,checkingManaged:null,savingIdentity:false,
    hostStudioOpen:false,installingNetwork:false,joiningNetwork:false,runtime:null,
    console:{error:()=>{},warn:()=>{}},performance:{now:()=>10},
    setAppUpdate:next=>{stage=typeof next==='function'?next(stage):next;},
    loadUpdaterPlugin:async()=>({check:async()=>update}),
    AppUpdaterProgressMeter:class{consume(){return null;}snapshot(){return {downloaded:12,total:12};}},
    invoke:async name=>{
      calls.push(name);
      if(name==='has_pending_package_open_requests')return false;
      if(name==='list_running_games')return [];
      if(name==='get_active_game_processes')return {status:'none',safeToUpdate:true};
      if(name==='try_arm_app_update_install'||name==='finish_app_update_install_guard')return true;
      throw Error('unexpected IPC '+name);
    },
  };
  const js=transpile(updateSource.replaceAll("await import('@tauri-apps/plugin-updater')",'await loadUpdaterPlugin()'));
  const task=vm.runInNewContext(js,context,{timeout:1000})();
  await downloadStarted;
  gate.current=true; // native operation begins synchronously; React has not rerendered
  complete();await task;
  assert.ok(!calls.includes('install'),'native game repair/upgrade must prevent a restart');
  assert.equal(stage.stage,'deferred');
  assert.ok(calls.includes('close'));
});

test('native queue remains valid when a drain is disposed before its delayed peek returns',async()=>{
  const module={exports:{}};
  vm.runInNewContext(ts.transpileModule(helper,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,
    {module,exports:module.exports,setTimeout,clearTimeout});
  let release;
  let acked=0;
  const shown=[];
  const d=new module.exports.PackageActivationDrain(
    ()=>new Promise(resolve=>{release=()=>resolve([{path:'C:\\TEMP\\owned.coco2pack'}]);}),
    batch=>shown.push(batch),()=>{},4,async()=>{acked++;},
  );
  const task=d.trigger();d.dispose();release();await task;
  assert.equal(acked,0,'do not ACK paths received after the consumer unmounted');
  assert.equal(shown.length,0);
});
