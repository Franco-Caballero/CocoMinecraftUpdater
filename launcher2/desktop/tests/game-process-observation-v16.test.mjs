import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const js=ts.transpileModule(await readFile(resolve(root,'src/game-process-observation.ts'),'utf8'),{
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS},
}).outputText;
const module={exports:{}};
vm.runInNewContext(js,{module,exports:module.exports});
const {retainObservedGameIds}=module.exports;

test('native Win32 polling preserves React state for identical game IDs even if process scan order changes',()=>{
  const old=['game-2','game-1'];
  assert.equal(retainObservedGameIds(old,['game-1','game-2']),old);
  assert.equal(retainObservedGameIds(old,['game-2','game-1']),old);
  assert.equal(retainObservedGameIds(old,['game-1','game-1','game-2']),old);
  assert.deepEqual([...retainObservedGameIds(old,['game-1'])],['game-1']);
  assert.deepEqual([...retainObservedGameIds(old,['game-2','game-3'])],['game-2','game-3']);
});

test('1,000 repeated nonempty native Win32 snapshots cause zero new React array commits',()=>{
  let state=Array.from({length:100},(_,i)=>`g${i}`);
  const before=performance.now();let commits=0;
  for(let i=0;i<1000;i++){
    const next=retainObservedGameIds(state,[...state].reverse());
    if(next!==state){state=next;commits++;}
  }
  const ms=performance.now()-before;
  assert.equal(commits,0);
  assert.ok(ms<250,`1000 synthetic process observations took ${ms.toFixed(1)}ms`);
  console.log(`CPU Node Win32 snapshot compare ×1000: ${ms.toFixed(2)}ms, 0 React state changes; NOT a native Win32 or WebView2 measurement`);
});

test('frontend native process observation uses identity-preserving state update',async()=>{
  const code=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.match(code,/setObservedGameIds\(current=>retainObservedGameIds\(current,report\.gameIds\)\)/);
});
