import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function createGate(){
  const code=await readFile(resolve(root,'src/native-operation-gate.ts'),'utf8');
  const js=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports});
  return new module.exports.NativeOperationGate();
}

test('two same-tick clicks permit only one native write even before React state commits',async()=>{
  const gate=await createGate();
  const first=gate.begin('g-1','install');
  assert.ok(first&&gate.busy());
  assert.equal(gate.begin('g-1','install'),null);
  assert.equal(gate.begin('g-2','upgrade'),null,'different game cannot race the same UI native writer');
  let finish;
  const pending=new Promise(resolve=>{finish=resolve;});
  finish('installed');
  assert.equal(await pending,'installed');
  assert.equal(gate.finish(first),true);
  assert.equal(gate.busy(),false);
  assert.equal(gate.finish(first),false,'stale completion cannot clear future lock');
});

test('a failed/cancelled native operation can release and future operations have unique tickets',async()=>{
  const gate=await createGate();
  for(const kind of ['install','launch','prepare-repair','commit-repair','recover-repair','upgrade','recover-upgrade']){
    const ticket=gate.begin('synthetic',kind);
    assert.ok(ticket);
    assert.equal(gate.begin('synthetic',kind),null);
    assert.equal(gate.finish(ticket),true);
  }
  assert.equal(gate.begin('','install'),null);
  assert.equal(gate.begin('g',''),null);
});

test('frontend guards every mutating/launching native operation synchronously',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const operations=[
    ['launchNative','launch'],['installNative','install'],
    ['recoverRepair','recover-repair'],['uninstallNative','uninstall'],
    ['performUpgrade','upgrade'],['recoverUpgrade','recover-upgrade'],
  ];
  for(let i=0;i<operations.length;i++){
    const [fn,kind]=operations[i];
    const start=ui.indexOf(`const ${fn}=async(entry:Experience)=>{`);
    const next=i+1<operations.length?ui.indexOf(`const ${operations[i+1][0]}=async(entry:Experience)=>{`,start):ui.indexOf('const primaryGame=',start);
    const code=ui.slice(start,next>start?next:undefined);
    assert.ok(start>=0,fn);
    assert.match(code,new RegExp(`nativeOperationGate\\.current\\.begin\\(entry\\.id,'${kind}'\\)`),fn);
    assert.match(code,/finally\{nativeOperationGate\.current\.finish\(ticket\)/,fn);
  }
});
