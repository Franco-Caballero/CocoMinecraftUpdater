import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
async function reconcile(){
  const code=ts.transpileModule(await read('src/runtime-event-fence.ts'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(code,{module,exports:module.exports});
  return module.exports.reconcileRuntimeEvent;
}
const running=(id,pid)=>({id,pid,state:'running',exitCode:null});
const exited=(id,pid)=>({id,pid,state:'exited',exitCode:0});

test('late exits for another game or an older PID cannot hide the current running process',async()=>{
  const apply=await reconcile();
  const current=running('game-B',4567);
  assert.equal(apply(current,exited('game-A',1234)),current);
  assert.equal(apply(current,exited('game-B',1234)),current,'old same-game PID must not hijack new launch');
  assert.deepEqual(apply(current,exited('game-B',4567)),exited('game-B',4567));
});

test('uncertain launch/restarted child remains fail-closed until correlated',async()=>{
  const apply=await reconcile();
  const verifying={id:'game-B',pid:null,state:'verifying',exitCode:null};
  assert.equal(apply(verifying,exited('game-B',1234)),verifying,'old exit must not erase pending launch');
  const unknown=running('game-B',null);
  assert.equal(apply(unknown,exited('game-B',4567)),unknown,'do not claim an unknown PID exited');
  assert.equal(apply(null,exited('game-A',1234)),null,'background exit with no observed game is not a new active game');
  assert.deepEqual(apply(verifying,running('game-B',4567)),running('game-B',4567));
});

test('Tauri runtime listener uses identity fence, not unconditional setRuntime of stale exits',async()=>{
  const ui=await read('src/main.tsx');
  const listener=ui.match(/listen<RuntimeEvent>\('coco2:\/\/runtime',[\s\S]*?\)\.then\(/)?.[0]||'';
  assert.ok(listener);
  assert.match(listener,/setRuntime\(current=>reconcileRuntimeEvent\(current,event\.payload\)\)/);
  assert.doesNotMatch(listener,/setRuntime\(event\.payload\)/);
  assert.doesNotMatch(listener,/setOperationMessage\('Juego cerrado'\)/,
    'a stale exit must never overwrite the current operation message');
});
