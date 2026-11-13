// Exercise the *actual* React deferral expression, not a duplicate model.
// A Windows file-open can arrive while a game details sheet is already modal.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const main=await readFile(resolve(root,'src/main.tsx'),'utf8');
const file=ts.createSourceFile('main.tsx',main,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
let expression;
const visit=node=>{
  if(ts.isVariableDeclaration(node)&&node.name.getText(file)==='packageReviewDeferred')
    expression=node.initializer?.getText(file);
  ts.forEachChild(node,visit);
};
visit(file);
assert.ok(expression,'the actual UI must declare a package review deferral gate');
const js=ts.transpileModule('('+expression+')',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
let closeDetailsCode;
const findClose=node=>{
  if(ts.isVariableDeclaration(node)&&node.name.getText(file)==='closeDetails')
    closeDetailsCode=node.initializer?.getText(file);
  ts.forEachChild(node,findClose);
};
findClose(file);
assert.ok(closeDetailsCode,'test actual details close handler');
const closeJs=ts.transpileModule('('+closeDetailsCode+')',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
const render=(state={})=>vm.runInNewContext(js,{
  selected:null,hostStudioOpen:false,mediaPlaying:null,streamLoading:false,mediaDownloadActive:null,
  installing:null,upgrading:null,upgradeRecovering:null,preparingRepair:null,
  repairCommitting:null,repairRecovering:null,
  nativeOperationGate:{current:{busy:()=>false}},appUpdate:{stage:'idle'},...state,
},{timeout:1000});

test('Explorer activation remains queued while a game details modal has keyboard focus',()=>{
  assert.equal(render({selected:{id:'game-123'}}),true,
    'native inbox must not overlay details and create simultaneous modal traps');
});

test('closing details makes the pending authenticated package review available immediately',()=>{
  assert.equal(render({selected:{id:'game-123'}}),true);
  assert.equal(render({selected:null}),false,
    'review can resume on the next render without a second Explorer activation');
});

test('closing a details modal cannot restore focus behind an incoming Explorer review',()=>{
  let restored=0,queued=0,selected=true;
  const returnFocus={current:{isConnected:true,focus:()=>restored++}};
  const close=vm.runInNewContext(closeJs,{
    incomingPackages:['C:\\Friends\\New Game.coco2pack'],
    pendingPackageInboxRef:{current:true},
    detailFocusReturn:returnFocus,
    setSelected:value=>{selected=value;},
    window:{requestAnimationFrame:callback=>{queued++;callback();}},
  });
  close();
  assert.equal(selected,null);
  assert.equal(queued,0,'pending package inbox must own focus after the details sheet closes');
  assert.equal(restored,0,'background card must never steal focus from the pending inbox');
  assert.equal(returnFocus.current,null,'stale focus return target must be released');
});

test('closing ordinary details with no new package retains keyboard focus restoration',()=>{
  let restored=0;
  const close=vm.runInNewContext(closeJs,{
    incomingPackages:[],
    pendingPackageInboxRef:{current:false},
    detailFocusReturn:{current:{isConnected:true,focus:()=>restored++}},
    setSelected:()=>{},window:{requestAnimationFrame:callback=>callback()},
  });
  close();assert.equal(restored,1);
});

test('deferred queue preserves the existing busy and playback safety fences',()=>{
  assert.equal(render({nativeOperationGate:{current:{busy:()=>true}}}),true);
  assert.equal(render({hostStudioOpen:true}),true);
  assert.equal(render({mediaPlaying:{title:'Película'}}),true);
  assert.equal(render({appUpdate:{stage:'installing'}}),true);
});

test('the same deferral gate controls both inbox mount and its focus effect, without implicit import',()=>{
  assert.match(main,/incomingPackages\.length>0&&!packageReviewDeferred&&isTauri\(\)&&<div className="coco-inbox-overlay"/);
  assert.match(main,/if\(incomingPackages\.length&&!packageReviewDeferred\)\{/);
  assert.match(main,/incomingPackages\.length>0&&packageReviewDeferred&&<div className="coco-package-deferred"/);
  assert.doesNotMatch(expression,/import_local_publish_package|install_standalone|launch_standalone/);
});
