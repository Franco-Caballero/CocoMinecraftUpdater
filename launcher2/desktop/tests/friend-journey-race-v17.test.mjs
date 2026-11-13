// Coco Launcher 2: real TS event handlers, no browser, Tauri, Explorer, game,
// native catalog or user profile. This test is intentionally RED before the
// v17 fix: a superseded first-run picker request reopens after Explorer review.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const main=await readFile(resolve(root,'src/main.tsx'),'utf8');
const hub=await readFile(resolve(root,'src/CatalogHub.tsx'),'utf8');
const drain=await readFile(resolve(root,'src/package-activation-drain.ts'),'utf8');
const inbox=await readFile(resolve(root,'src/package-inbox.ts'),'utf8');
const portable=await readFile(resolve(root,'src/portable-format.ts'),'utf8');
const first=await readFile(resolve(root,'src/FirstRun.tsx'),'utf8');

function compile(expression){
  return ts.transpileModule(`(${expression})`,{compilerOptions:{
    module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX,
  }}).outputText;
}
function extractArrow(source,name,kind='variable'){
  const ast=ts.createSourceFile(name+'.tsx',source,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
  let match;
  function visit(node){
    if(kind==='variable'&&ts.isVariableDeclaration(node)&&node.name.getText(ast)===name){
      const candidate=node.initializer;
      if(candidate&&ts.isArrowFunction(candidate))match=candidate.getText(ast);
    }
    if(kind==='jsx'&&ts.isJsxAttribute(node)&&node.name.getText(ast)===name){
      const candidate=node.initializer?.expression;
      if(candidate&&ts.isArrowFunction(candidate))match=candidate.getText(ast);
    }
    if(kind==='effect'&&ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'){
      const candidate=node.arguments[0];
      if(candidate&&ts.isArrowFunction(candidate)&&candidate.body.getText(ast).includes(name))
        match=candidate.getText(ast);
    }
    ts.forEachChild(node,visit);
  }
  visit(ast);
  assert.ok(match,'Missing actual TS handler '+kind+': '+name);
  return compile(match);
}
function nativeModule(source,exported){
  const sandbox={exports:{},module:{exports:{}}};
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{
    module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
  }}).outputText,sandbox,{timeout:1000});
  return sandbox.exports[exported];
}
const packageEnqueue=nativeModule(inbox,'enqueuePackageRequests');
const packageDismiss=nativeModule(inbox,'dismissPackageRequest');
const PickerGate=nativeModule(drain,'ManualPackagePickerGate');
const welcomeClick=extractArrow(main,'onOpenPackage','jsx');
const activationEnqueue=extractArrow(main,'enqueue');
const consumePickerEffect=extractArrow(hub,'firstRunPickerGate.current.consume(pickerRequestId)','effect');

function scenario(){
  const steps=[];
  const state={request:0,inbox:{paths:[],dropped:0},pickerSerial:{current:0},pickerGate:new PickerGate(),pickerCount:0,
    pendingPackageInboxRef:{current:false}};
  state.inboxLive={current:state.inbox};
  const ctx={
    disposed:false,
    hostStudioAvailable:true, // These manual picker regression scenarios are host-authoring only.
    MAX_PENDING_PACKAGES:96,
    stagedNativePrefix:[],
    packagePickerSerial:state.pickerSerial,
    pendingPackageInboxRef:state.pendingPackageInboxRef,
    inboxLive:state.inboxLive,
    commitInbox:next=>{state.inboxLive.current=next;state.pendingPackageInboxRef.current=Boolean(next.paths.length||next.dropped);state.inbox=next;steps.push(['inbox',next.paths.length]);return true;},
    navigate:next=>steps.push(['navigate',next]),
    setPackagePickerRequest:value=>{state.request=typeof value==='function'?value(state.request):value;steps.push(['pickerIntent',state.request]);},
    setInbox:update=>{state.inbox=update(state.inbox);steps.push(['inbox',state.inbox.paths.length]);},
    enqueuePackageRequests:packageEnqueue,
    extractPackagePaths:nativeModule(inbox,'extractPackagePaths'),
    isPortablePackageFile:nativeModule(portable,'isPortablePackageFile'),
  };
  const click=vm.runInNewContext(welcomeClick,ctx,{timeout:1000});
  const enqueue=vm.runInNewContext(activationEnqueue,ctx,{timeout:1000});
  const renderHub=()=>{
    const effectCtx={
      pickerRequestId:state.request,incomingPath:state.inbox.paths[0],
      hostCanImportNow:{current:true},
      firstRunPickerGate:{current:state.pickerGate},
      onPickerRequestConsumed:()=>ctx.setPackagePickerRequest(0),
      choosePackage:()=>{state.pickerCount++;steps.push('native-picker');},
      isTauri:()=>true,
    };
    vm.runInNewContext(consumePickerEffect,effectCtx,{timeout:1000})();
  };
  const done=path=>{ctx.commitInbox(packageDismiss(state.inboxLive.current,path));steps.push(['dismiss',path]);};
  return {state,steps,click,enqueue,renderHub,done};
}

const A='C:\\Amigos\\Paquete Áé 💜.coco2pack';
const B='C:\\Amigos\\Otro juego 漢字.coco2pack';

test('real first-run intent is superseded by warm Explorer review, never reopens an old picker',()=>{
  const s=scenario();
  s.click();
  assert.equal(s.state.request,1);
  // A slow React lazy render and cold native subscription have not yet mounted
  // CatalogHub, then Explorer delivers A before the manual picker can open.
  s.enqueue([{path:A,source:'cold'}]);
  assert.deepEqual(Array.from(s.state.inbox.paths),[A]);
  s.done(A); // User explicitly discarded or imported A from the Explorer inbox.
  s.renderHub(); // CatalogHub remounts when incomingPackages returns to [].
  assert.equal(s.state.pickerCount,0,
    'stale first-run request opened an unsolicited OS picker AFTER Explorer review');
  assert.equal(s.state.request,0,'Explorer activation must retire superseded manual intent');
  // Fresh click is distinct and allowed exactly once, no implicit import.
  s.click();s.renderHub();s.renderHub();
  assert.equal(s.state.pickerCount,1);
  assert.equal(s.steps.filter(step=>step==='native-picker').length,1);
});

test('empty focus-drain and invalid IPC payload must not consume a deliberate picker click',()=>{
  const s=scenario();
  s.click();
  s.enqueue([]);s.enqueue(null);s.enqueue({bad:'not a package'});
  assert.equal(s.state.request,1,'startup read with no packages is not an Explorer activation');
  s.renderHub();
  assert.equal(s.state.pickerCount,1,'manual native file picker still opens from explicit intent');
  assert.equal(s.state.request,0);
});

test('invalid Explorer filename may be dismissed without stealing the existing manual intent',()=>{
  const s=scenario();s.click();
  const invalid='C:\\Amigos\\not-a-coco-package.zip';
  s.enqueue({path:invalid});
  assert.equal(s.state.request,1,'a generic ZIP is not a Coco association');
  assert.deepEqual(Array.from(s.state.inbox.paths),[invalid]);
  s.done(invalid);
  s.renderHub();
  assert.equal(s.state.pickerCount,1,'the earlier real click can now open the native picker');
});

test('valid duplicate Explorer activation supersedes pending intent without duplicate inbox entries',()=>{
  const s=scenario();s.click();
  s.enqueue([{path:A},{path:A},{path:B}]);
  assert.deepEqual(Array.from(s.state.inbox.paths),[A,B]);
  s.done(A);s.done(B);s.renderHub();
  assert.equal(s.state.pickerCount,0);
  assert.equal(s.state.request,0);
});

test('boundaries: no automatic import/launch; native review token stays inside explicit commit',()=>{
  assert.match(first,/onClick=\{onOpenPackage\}/);
  assert.match(hub,/reviewGate\.current\.beginCommit\(reviewTicket,sourcePath,review\.reviewToken\)/);
  assert.match(hub,/path:sourcePath,reviewToken:review\.reviewToken,confirmed:true/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(main,/onOpenPackage=\{\(\)=>\{if\(hostStudioAvailable\)/);
  assert.match(main,/get_active_game_processes/);
  assert.match(main,/reconcileLaunchObservation\(snapshot,entry\.id\)/);
  assert.doesNotMatch(first,/invoke\(|install_standalone|launch_standalone/);
  assert.doesNotMatch(activationEnqueue,/import_local_publish_package|launch_standalone/);
});
