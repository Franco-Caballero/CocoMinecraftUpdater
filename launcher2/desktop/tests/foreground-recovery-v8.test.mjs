import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=name=>readFile(resolve(root,name),'utf8');
async function createGate(){
  const js=ts.transpileModule(await source('src/foreground-recovery-gate.ts'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return new module.exports.ForegroundRecoveryGate();
}

test('focus and visibility bursts share exactly one read-only journal scan, even after cancel',async()=>{
  const gate=await createGate();
  const first=gate.begin(1000);
  assert.equal(typeof first,'number');
  for(let i=0;i<100;i++)assert.equal(gate.begin(1000+i),null);
  gate.cancel();
  assert.equal(gate.isCurrent(first),false,'unmounted pending scan cannot restore stale results');
  assert.equal(gate.finish(first),false);
  assert.equal(gate.begin(3000),null,'restarting within debounce window cannot scan twice');
  const second=gate.begin(5000);
  assert.ok(second>first);
  assert.equal(gate.finish(second),true);
  assert.equal(gate.begin(5001),null);
});

test('after a successful install, an explicit refresh can bypass focus cooldown but old read cannot commit',async()=>{
  const gate=await createGate();
  const ticket=gate.begin(400);
  gate.cancel();gate.allowImmediateRetry();
  const next=gate.begin(401);
  assert.equal(gate.isCurrent(ticket),false);
  assert.equal(gate.isCurrent(next),true);
  assert.equal(gate.finish(ticket),false);
  assert.equal(gate.finish(next),true);
  assert.equal(gate.begin(Number.NaN),null);
  assert.equal(gate.begin(Number.POSITIVE_INFINITY),null);
});

test('foreground recovery never commits repair or installs, and native errors do not erase other read-only results',async()=>{
  const ui=await source('src/main.tsx');
  const effect=ui.slice(ui.indexOf('// Reconcile interrupted native operations'),ui.indexOf('// First paint reads'));
  assert.match(effect,/document\.hidden\|\|nativeWriteBusy\.current\|\|nativeOperationGate\.current\.busy\(\)/);
  assert.match(ui,/nativeWriteBusy\.current=Boolean\(runtime\?\.state==='running'\|\|observedGameIds\.length\|\|gameProcessUncertain/);
  assert.match(effect,/Promise\.allSettled\(\[/);
  assert.match(effect,/recover_pending_standalone_operations/);
  assert.match(effect,/get_local_instances/);
  assert.match(effect,/gate\.isCurrent\(ticket\)/);
  assert.match(effect,/window\.addEventListener\('focus',onFocus\)/);
  assert.match(effect,/document\.addEventListener\('visibilitychange',onFocus\)/);
  assert.doesNotMatch(effect,/invoke.*(?:commit_standalone_repair|recover_standalone_upgrade|install_standalone|launch_standalone)/);
});
