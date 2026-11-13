import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const src=await readFile(resolve(root,'src/main.tsx'),'utf8');
const ast=ts.createSourceFile('main.tsx',src,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const extracted=new Map();
const visit=node=>{
  if(ts.isVariableDeclaration(node)&&['packageReviewDeferred','hostStudioBlocked'].includes(node.name.getText(ast)))
    extracted.set(node.name.getText(ast),node.initializer.getText(ast));
  ts.forEachChild(node,visit);
};
visit(ast);
assert.equal(extracted.size,2);
const compiled=Object.fromEntries([...extracted].map(([key,tsCode])=>[
  key,ts.transpileModule('('+tsCode+')',{compilerOptions:{module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022}}).outputText,
]));
function caseFor(changes={}){
  const base={
    selected:null,hostStudioOpen:false,nativeOperationGate:{current:{busy:()=>false}},
    installing:null,upgrading:null,upgradeRecovering:null,preparingRepair:null,
    repairCommitting:null,repairRecovering:null,mediaPlaying:null,streamLoading:'',
    mediaDownloadActive:null,appUpdate:{stage:'idle'},incomingPackages:[],
    runtime:null,observedGameIds:[],gameProcessUncertain:false,
    activeVerification:null,checkingRepair:null,checkingManaged:false,
    joiningNetwork:false,installingNetwork:false,mediaPrepareGate:{current:{busy:()=>false}},
    busy:false,updateRunning:{current:false},
  };
  const ctx={...base,...changes};
  ctx.packageReviewDeferred=vm.runInNewContext(compiled.packageReviewDeferred,ctx);
  ctx.hostStudioBlocked=vm.runInNewContext(compiled.hostStudioBlocked,ctx);
  return ctx;
}

test('Explorer package review cannot interrupt Host Studio, native writes, video or updater',()=>{
  assert.equal(caseFor().packageReviewDeferred,false);
  for(const changed of [
    {selected:{id:'selected-game'}},
    {hostStudioOpen:true},{installing:'game'},{upgrading:'game'},{repairRecovering:'game'},
    {mediaPlaying:{stream:{url:'local'}}},{mediaDownloadActive:{episodeId:'e'}},
    {appUpdate:{stage:'downloading'}},{appUpdate:{stage:'installing'}},
    {nativeOperationGate:{current:{busy:()=>true}}},
  ])assert.equal(caseFor(changed).packageReviewDeferred,true,JSON.stringify(changed));
  assert.equal(caseFor({appUpdate:{stage:'deferred'}}).packageReviewDeferred,false);
});

test('Host Studio cannot start while installer, package review or game needs resources',()=>{
  assert.equal(caseFor().hostStudioBlocked,false);
  for(const changed of [
    {incomingPackages:['C:\\Amigo\\x.coco2pack']},
    {runtime:{state:'running'}},{observedGameIds:['game']},
    {gameProcessUncertain:true},
    {mediaPrepareGate:{current:{busy:()=>true}}},
    {nativeOperationGate:{current:{busy:()=>true}}},
  ])assert.equal(caseFor(changed).hostStudioBlocked,true,JSON.stringify(changed));
});

test('React defers the inbox dialog but preserves queued path and correct focus on resume',()=>{
  const start=src.indexOf('// Windows can deliver a new package');
  const end=src.indexOf('// Hover clips stop playing',start);
  assert.ok(start>0&&end>start);
  assert.match(src,/incomingPackages\.length>0&&!packageReviewDeferred&&isTauri\(\)/);
  assert.match(src,/if\(incomingPackages\.length&&!packageReviewDeferred\)/);
  assert.match(src,/\},\[incomingPackages\[0\],packageReviewDeferred\]\)/);
  assert.match(src,/incomingPackages\.length>0&&packageReviewDeferred&&<div className="coco-package-deferred"/);
  assert.match(src,/disabled=\{hostStudioBlocked\}/);
  assert.match(src,/if\(!hostStudioBlocked\)setHostStudioOpen\(true\)/);
  assert.doesNotMatch(src.slice(start,end),/import_local_publish_package|install_standalone|launch_standalone/);
});
