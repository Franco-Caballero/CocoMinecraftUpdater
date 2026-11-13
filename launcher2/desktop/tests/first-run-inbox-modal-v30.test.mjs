/** FirstRun Reyna and an authenticated Explorer package are mutually exclusive
 * modal surfaces. Exercise the actual render gate without browser/registry. */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const main=await readFile(resolve(root,'src/main.tsx'),'utf8');
const ast=ts.createSourceFile('main.tsx',main,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
let gateSource='';
function visit(node){
  if(ts.isVariableDeclaration(node)&&node.name.getText(ast)==='welcomeVisible')
    gateSource=node.initializer?.getText(ast)||'';
  ts.forEachChild(node,visit);
}
visit(ast);

function evaluate(overrides={}){
  assert.ok(gateSource,'main.tsx defines a single shared first-run visibility gate');
  const context={view:'library',bootstrapLoaded:true,firstRunDone:false,incomingPackages:[],
    selected:null,hostStudioOpen:false,mediaPlaying:null,streamLoading:null,
    nativeOperationGate:{current:{busy:()=>false}},updateRunning:{current:false},
    appUpdate:{stage:'idle'},
    isTauri:()=>true,items:[],loadError:'',...overrides};
  const js=ts.transpileModule('('+gateSource+')',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
  return vm.runInNewContext(js,context,{timeout:1000});
}

test('first run shows Reyna when catalog is completely empty or unavailable',()=>{
  assert.equal(evaluate({items:[],loadError:'synthetic offline'}),true);
});
test('with games in the catalog everyone goes straight to them, without the welcome',()=>{
  assert.equal(evaluate({items:[{id:'crack'}]}),false);
  assert.equal(evaluate({items:[{id:'crack'}],loadError:'offline'}),true,'an unreachable catalog is still explained');
});
test('authenticated Explorer opening takes modal priority over first-run welcome, then welcome resumes',()=>{
  assert.equal(evaluate({incomingPackages:['C:\\TEMP\\Friend.coco2pack']}),false);
  assert.equal(evaluate({incomingPackages:[]}),true);
  assert.match(main,/welcomeVisible&&<React\.Suspense/);
});
test('welcome never competes with detail, Host Studio, video or native operations',()=>{
  assert.equal(evaluate({selected:{id:'fixture'}}),false);
  assert.equal(evaluate({hostStudioOpen:true}),false);
  assert.equal(evaluate({mediaPlaying:{id:'fixture'}}),false);
  assert.equal(evaluate({nativeOperationGate:{current:{busy:()=>true}}}),false);
  assert.equal(evaluate({appUpdate:{stage:'installing'}}),false);
});

test('automatic background updater lookup must not unmount first-run modal before a user makes a choice',()=>{
  assert.equal(evaluate({updateRunning:{current:true},appUpdate:{stage:'checking'}}),true);
  assert.equal(evaluate({updateRunning:{current:true},appUpdate:{stage:'deferred'}}),true);
  assert.equal(evaluate({appUpdate:{stage:'downloading'}}),false);
});
