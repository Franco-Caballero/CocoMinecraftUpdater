// Test real React event handlers and a deliberately delayed React state commit.
// Never opens Explorer, Tauri, NSIS or any real package.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
const source=await readFile(resolve(root,'src/package-inbox.ts'),'utf8');
const ast=ts.createSourceFile('main.tsx',ui,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const transpile=code=>ts.transpileModule('('+code+')',{compilerOptions:{module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022}}).outputText;
const exported=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const module={exports:{}};
vm.runInNewContext(exported,{module,exports:module.exports});
const helpers=module.exports;
const getHandler=(name,kind='variable')=>{
  let result;
  const visit=node=>{
    if(kind==='variable'&&ts.isVariableDeclaration(node)&&node.name.getText(ast)===name)
      result=node.initializer?.getText(ast);
    if(kind==='jsx'&&ts.isJsxAttribute(node)&&node.name.getText(ast)===name)
      result=node.initializer?.expression?.getText(ast);
    ts.forEachChild(node,visit);
  };
  visit(ast);assert.ok(result,`missing actual handler ${name}`);return transpile(result);
};
let inboxFocusEffectText;
const findInboxEffect=node=>{
  if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&
    node.arguments[0]?.getText(ast).includes('wasInboxOpen.current')&&
    node.arguments[0]?.getText(ast).includes('priorInboxFocus.current'))
    inboxFocusEffectText=node.arguments[0].getText(ast);
  ts.forEachChild(node,findInboxEffect);
};
findInboxEffect(ast);
assert.ok(inboxFocusEffectText,'the actual inbox-focus useEffect must still exist');
const inboxFocusCode=transpile(inboxFocusEffectText);
const entryA='C:\\Mis Amigos\\Juego 漢字.coco2pack';
const entryB='C:\\Mis Amigos\\Coop 💜.coco2pack';
function createScenario(){
  const initial=helpers.emptyPackageInbox();
  let visible=initial;
  const queued=[];
  const state={inboxLive:{current:initial},pendingPackageInboxRef:{current:false},selected:true};
  const ctx={
    ...helpers,...state,disposed:false,
    stagedNativePrefix:[],
    persistPackageInbox:()=>true,
    setInboxPersistenceError:()=>{},
    activationDrainRef:{current:{trigger:async()=>{}}},
    isPortablePackageFile:path=>path.endsWith('.coco2pack'),
    setPackagePickerRequest:()=>{},
    setInbox:next=>queued.push(next),
    setSelected:value=>{state.selected=value;},
    detailFocusReturn:{current:{isConnected:true,focus:()=>ctx.focused++}},
    focused:0,frameScheduled:0,
    window:{requestAnimationFrame:callback=>{ctx.frameScheduled++;callback();}},
  };
  const sync=vm.runInNewContext(getHandler('commitInbox'),ctx,{timeout:1000});
  ctx.commitInbox=sync;
  const enqueue=vm.runInNewContext(getHandler('enqueue'),ctx,{timeout:1000});
  const dismiss=vm.runInNewContext(getHandler('onInboxDone','jsx'),ctx,{timeout:1000});
  const close=vm.runInNewContext(getHandler('closeDetails'),ctx,{timeout:1000});
  return {state,ctx,enqueue,dismiss,close,
    flush:()=>{if(queued.length)visible=queued.pop();queued.length=0;return visible;},
    getVisible:()=>visible,
  };
}

test('a warm Explorer request stays latched across unrelated React renders before inbox commit',()=>{
  const s=createScenario();
  s.enqueue({path:entryA,source:'warm'});
  assert.equal(s.state.pendingPackageInboxRef.current,true);
  assert.equal(s.getVisible().paths.length,0,'React has not committed the new state yet');
  // Before the fix every render assigned false from the old inbox array.
  assert.doesNotMatch(ui,/pendingPackageInboxRef\.current\s*=\s*Boolean\(incomingPackages\.length\)/);
  assert.equal(s.state.pendingPackageInboxRef.current,true);
  s.close();
  assert.equal(s.ctx.frameScheduled,0,'closing details cannot steal focus back before review appears');
  assert.deepEqual([...s.flush().paths],[entryA]);
});

test('two uncommitted deliveries retain FIFO, duplicate dedupe and correct updater gate through each dismissal',()=>{
  const s=createScenario();
  s.enqueue({path:entryA});s.enqueue([{path:entryA},{path:entryB}]);
  assert.deepEqual([...s.state.inboxLive.current.paths],[entryA,entryB]);
  assert.deepEqual([...s.flush().paths],[entryA,entryB]);
  s.dismiss(entryA);
  assert.equal(s.state.pendingPackageInboxRef.current,true);
  assert.deepEqual([...s.flush().paths],[entryB]);
  s.dismiss(entryB);
  assert.equal(s.state.pendingPackageInboxRef.current,false);
  assert.deepEqual([...s.flush().paths],[]);
});

test('invalid events do not create phantom work; native-owned overflow is never falsely acknowledged by React',()=>{
  const s=createScenario();
  s.enqueue({unknown:'malformed'});
  assert.equal(s.state.pendingPackageInboxRef.current,false);
  assert.deepEqual([...s.flush().paths],[]);
  s.enqueue(Array.from({length:98},(_,i)=>({path:`C:\\tmp\\${i}.coco2pack`})));
  assert.equal(s.state.inboxLive.current.paths.length,96);
  assert.equal(s.state.inboxLive.current.dropped,0,'remaining native suffix is retained, not recorded as a lost path');
  assert.equal(s.state.pendingPackageInboxRef.current,true);
  for(const path of [...s.state.inboxLive.current.paths])s.dismiss(path);
  s.flush();
  assert.equal(s.state.pendingPackageInboxRef.current,false);
});

test('a warm delivery arriving after details-close scheduled a frame cannot let the old card steal review focus',()=>{
  const s=createScenario();
  const frames=[];
  s.ctx.window.requestAnimationFrame=fn=>{frames.push(fn);};
  s.close();
  assert.equal(frames.length,1);
  s.enqueue({path:entryA}); // deliver before browser executes the pending frame
  frames[0]();
  assert.equal(s.ctx.focused,0,'queued Explorer review owns the next focus');
});

test('hiding the inbox because another modal opens does not return keyboard focus behind that modal',()=>{
  let restored=0;
  const ctx={
    incomingPackages:[entryA],packageReviewDeferred:true,
    wasInboxOpen:{current:true},
    priorInboxFocus:{current:{isConnected:true,focus:()=>restored++}},
    inboxDialogRef:{current:{focus:()=>{}}},
    document:{activeElement:null},HTMLElement:class{},
  };
  const effect=vm.runInNewContext(inboxFocusCode,ctx,{timeout:1000});
  effect();
  assert.equal(restored,0,'game/player/Host Studio modal should retain focus');
  assert.equal(ctx.priorInboxFocus.current,null,'obsolete target is released');
});

test('normally completing the last package review restores prior keyboard focus',()=>{
  let restored=0;
  const ctx={
    incomingPackages:[],packageReviewDeferred:false,
    wasInboxOpen:{current:true},
    priorInboxFocus:{current:{isConnected:true,focus:()=>restored++}},
    inboxDialogRef:{current:{focus:()=>{}}},
    document:{activeElement:null},HTMLElement:class{},
  };
  vm.runInNewContext(inboxFocusCode,ctx,{timeout:1000})();
  assert.equal(restored,1);
  assert.equal(ctx.wasInboxOpen.current,false);
});
