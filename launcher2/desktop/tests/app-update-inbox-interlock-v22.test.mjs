// Run Coco's actual asynchronous updater callback with a controlled fake Tauri
// bridge. No installed app, network, NSIS, games or user registry is touched.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const main=await readFile(resolve(root,'src/main.tsx'),'utf8');
const ast=ts.createSourceFile('main.tsx',main,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
let updaterText;
function visit(node){
  if(ts.isVariableDeclaration(node)&&node.name.getText(ast)==='applyAppUpdate')
    updaterText=node.initializer?.getText(ast);
  ts.forEachChild(node,visit);
}
visit(ast);
assert.ok(updaterText,'the real updater handler must remain available');
const js=ts.transpileModule('('+updaterText.replaceAll("await import('@tauri-apps/plugin-updater')",'await loadUpdaterPlugin()')+')',{
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None},
}).outputText;

function deferred(){let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};}
function scenario({pending=false,interruptDuringDownload=false,activeGame=false}={}){
  const gate={current:pending};
  const downloadEntered=deferred(),downloadComplete=deferred();
  const calls=[];
  let stage={stage:'deferred',version:'0.6.9',percent:0};
  const update={version:'0.6.9',
    download:async()=>{calls.push('download');downloadEntered.resolve();if(interruptDuringDownload)await downloadComplete.promise;},
    install:async()=>{calls.push('install');},
    close:async()=>{calls.push('close');},
  };
  const state={
    isTauri:()=>true,updateRunning:{current:false},updateAttempt:{current:0},
    pendingPackageInboxRef:gate,
    nativeOperationGate:{current:{busy:()=>false}},
    mediaDownloadGate:{current:{busy:()=>false}},
    mediaPrepareGate:{current:{busy:()=>false}},
    mediaPlaying:null,streamLoading:null,mediaDownloadActive:null,installing:null,upgrading:null,
    upgradeRecovering:null,preparingRepair:null,repairCommitting:null,repairRecovering:null,
    checkingRepair:null,busy:false,activeVerification:null,checkingManaged:null,savingIdentity:false,
    hostStudioOpen:false,installingNetwork:false,joiningNetwork:false,runtime:null,
    setAppUpdate:updateState=>{stage=typeof updateState==='function'?updateState(stage):updateState;},
    invoke:async command=>{calls.push(command);if(command==='has_pending_package_open_requests')return false;
      if(command==='try_arm_app_update_install'||command==='finish_app_update_install_guard')return true;
      if(command==='list_running_games')return activeGame?['synthetic-game']:[];
      if(command==='get_active_game_processes')return {status:'none',safeToUpdate:true};throw Error('unexpected invocation');},
    loadUpdaterPlugin:async()=>({check:async()=>{calls.push('check');return update;}}),
    AppUpdaterProgressMeter:class{consume(){return null;}snapshot(){return {downloaded:0,total:0};}},
    performance:{now:()=>100},console:{error:()=>{}},
  };
  const apply=vm.runInNewContext(js,state,{timeout:1000});
  return {apply,gate,calls,downloadEntered,downloadComplete,getStage:()=>stage,isRunning:()=>state.updateRunning.current};
}

test('an already queued Explorer package prevents starting the self-updater',async()=>{
  const s=scenario({pending:true});await s.apply();
  assert.equal(s.calls.includes('check'),false);
  assert.equal(s.calls.includes('install'),false);
  assert.equal(s.isRunning(),false);
});

test('new Explorer activation during signed update download defers restart and retains review queue',async()=>{
  const s=scenario({interruptDuringDownload:true});
  const task=s.apply();await s.downloadEntered.promise;
  s.gate.current=true; // native authenticated file-open delivered between awaits
  s.downloadComplete.resolve();await task;
  assert.equal(s.calls.includes('install'),false,'installer must not exit with an unreviewed package in memory');
  assert.equal(s.calls.includes('close'),true,'abandoned update handle must be released');
  assert.equal(s.getStage().stage,'deferred');
  assert.match(s.getStage().message,/paquete|revis/i);
  assert.equal(s.isRunning(),false);
});

test('without pending packages, an explicitly approved updater retains both native game checks',async()=>{
  const s=scenario();await s.apply();
  assert.equal(s.calls.filter(x=>x==='list_running_games').length,2);
  assert.equal(s.calls.filter(x=>x==='get_active_game_processes').length,2);
  assert.equal(s.calls.filter(x=>x==='install').length,1);
});

test('a running synthetic game still blocks the updater even without an inbox',async()=>{
  const s=scenario({activeGame:true});await s.apply();
  assert.equal(s.calls.includes('install'),false);
  assert.equal(s.getStage().stage,'deferred');
});

test('file-open event latches pending work before React schedules an asynchronous render',()=>{
  assert.match(main,/pendingPackageInboxRef\.current=Boolean\(next\.paths\.length\|\|next\.dropped\)/);
  assert.match(main,/commitInbox\(enqueuePackageRequests\(inboxLive\.current,accepted\)\)/);
  assert.match(main,/if\(retained\.size>=MAX_PENDING_PACKAGES\)break/);
  assert.doesNotMatch(main,/pendingPackageInboxRef\.current=Boolean\(incomingPackages\.length\)/,
    'React must never clear a live Explorer latch using an old rendered inbox');
  assert.match(main,/pendingPackageInboxRef\.current/);
  assert.doesNotMatch(updaterText,/TAURI_SIGNING_PRIVATE_KEY|powershell\.exe|disable.*defender/i);
});
