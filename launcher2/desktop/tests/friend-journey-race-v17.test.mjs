// Coco Launcher 2: real TS event handlers, no browser, Tauri, Explorer, game,
// native catalog or user profile. The first-run picker these races covered was removed
// with the host section of Settings (0.6.83).
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
const activationEnqueue=extractArrow(main,'enqueue');

test('the welcome has no package picker; Explorer activations stay review-only',()=>{
  assert.match(main,/onOpenPackage=\{dismissWelcome\}/);
  assert.doesNotMatch(main,/setPackagePickerRequest|pickerRequestId=/);
});

test('boundaries: no automatic import/launch; native review token stays inside explicit commit',()=>{
  assert.match(first,/onClick=\{onOpenPackage\}/);
  assert.match(hub,/reviewGate\.current\.beginCommit\(reviewTicket,sourcePath,review\.reviewToken\)/);
  assert.match(hub,/path:sourcePath,reviewToken:review\.reviewToken,confirmed:true/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(main,/get_active_game_processes/);
  assert.match(main,/reconcileLaunchObservation\(snapshot,entry\.id\)/);
  assert.doesNotMatch(first,/invoke\(|install_standalone|launch_standalone/);
  assert.doesNotMatch(activationEnqueue,/import_local_publish_package|launch_standalone/);
});
