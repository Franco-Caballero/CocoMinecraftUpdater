import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=path=>readFile(resolve(root,path),'utf8');
async function load(path){
  const js=ts.transpileModule(await source(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});return module.exports;
}
const store=()=>{const data=new Map();return {getItem:key=>data.get(key)||null,setItem:(key,val)=>data.set(key,val),removeItem:key=>data.delete(key),debug:()=>[...data.values()]};};

test('Windows install, upgrade, repair interruptions persist as actions, never store raw file errors or passwords',async()=>{
  const {recordActivity,readActivity}=await load('src/activity-ledger.ts');
  const storage=store(),now=Date.now();
  for(const [kind,id] of [
    ['install-interrupted','coco-jeu'],
    ['upgrade-interrupted','juego-漢字'],
    ['repair-interrupted','coco-jeu'],
    ['recover-interrupted','coco-jeu'],
  ])recordActivity(kind,id,storage,now);
  const saved=readActivity(storage,now+100);
  assert.equal(saved.length,3,'invalid IDs cannot enter persisted history');
  assert.ok(saved.some(x=>x.kind==='repair-interrupted'));
  assert.ok(saved.some(x=>x.kind==='upgrade-interrupted')===false,'untrusted Unicode identifier must not bypass catalog ID policy');
  assert.ok(storage.debug().every(text=>!text.includes('C:\\')&&!text.includes('token=')&&!text.includes('password=')));
});

test('an interrupted native command never records success or executes recovery silently',async()=>{
  const ui=await source('src/main.tsx');
  const begin=ui.indexOf('const explainFailedNativeWrite=');
  const end=ui.indexOf('const launchNative=',begin);
  const implementation=ui.slice(begin,end);
  assert.ok(begin>0&&end>begin);
  assert.match(implementation,/rememberActivity\(interruption,entry\.id\)/);
  assert.match(implementation,/kind==='install'\?'install-interrupted'/);
  assert.match(implementation,/inspectAfterNativeFailure/);
  assert.doesNotMatch(implementation, /invoke\('recover_standalone|invoke\('upgrade_standalone|invoke\('install_standalone/);
  assert.match(ui,/activityTitles:Record<ActivityKind,string>/);
  assert.match(ui,/Se interrumpió la instalación de/);
});
