import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function gate(){
  const tsCode=await readFile(resolve(root,'src/native-operation-gate.ts'),'utf8');
  const code=ts.transpileModule(tsCode,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(code,{module,exports:module.exports});
  return new module.exports.NativeOperationGate();
}

test('a late verification event from A cannot repaint the progress of B or an unrelated operation',async()=>{
  const work=await gate();
  const first=work.begin('game-A','verify');
  assert.ok(first);
  assert.equal(work.acceptsVerificationProgress('game-A'),true);
  assert.equal(work.acceptsVerificationProgress('game-B'),false);
  assert.equal(work.acceptsProgress('game-A'),false,'verification events must never enter the install progress sampler');
  assert.equal(work.finish(first),true);
  assert.equal(work.acceptsVerificationProgress('game-A'),false,'late event after native reply');
  const second=work.begin('game-B','verify');
  assert.ok(second);
  assert.equal(work.acceptsVerificationProgress('game-A'),false);
  assert.equal(work.acceptsVerificationProgress('game-B'),true);
  assert.equal(work.finish(second),true);
  for(const kind of ['launch','install','prepare-repair','upgrade']){
    const operation=work.begin('game-A',kind);
    assert.ok(operation);
    assert.equal(work.acceptsVerificationProgress('game-A'),false);
    assert.equal(work.finish(operation),true);
  }
});

test('the launcher starts no manual verification and shows no stale verification progress',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.doesNotMatch(ui,/verify_local_instance|verification-progress/);
  assert.doesNotMatch(ui,/nativeOperationGate.current.begin(entry.id,'verify')/);
});