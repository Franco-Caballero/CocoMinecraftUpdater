import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const code=await readFile(resolve(root,'src/hover-video-pool.ts'),'utf8');
const js=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const module={exports:{}};
vm.runInNewContext(js,{module,exports:module.exports});

test('visible proximity scheduler selects exactly the same stable top 32 as legacy full sorting',()=>{
  const {topVisibleIds}=module.exports;
  assert.equal(typeof topVisibleIds,'function');
  const map=new Map();
  for(let i=0;i<4096;i++)map.set(`game-${String(i).padStart(4,'0')}`,i%7===0?2:1);
  const sorted=[...map].sort((a,b)=>b[1]-a[1]).slice(0,32).map(([id])=>id);
  assert.deepEqual([...topVisibleIds(map,32)],sorted);
  assert.equal(topVisibleIds(map,0).length,0);
  assert.deepEqual([...topVisibleIds(new Map(),32)],[]);
  assert.ok(!code.includes('[...this.proximity].sort('),'per-metadata-tick full viewport sorting still exists');
});

test('benchmark 4096 mounted visible candidates over 500 scheduler refreshes: CPU-only Node, no WebView2',()=>{
  const {topVisibleIds}=module.exports;
  const map=new Map();
  for(let i=0;i<4096;i++)map.set(`game-${i}`,i%5===0?2:1);
  const iterations=500;
  const legacy=()=>[...map].sort((a,b)=>b[1]-a[1]).slice(0,32).map(([id])=>id);
  const optimized=()=>topVisibleIds(map,32);
  for(let n=0;n<30;n++){legacy();optimized();}
  let checksum=0;
  const a=performance.now();for(let n=0;n<iterations;n++)checksum+=legacy().length;
  const middle=performance.now();for(let n=0;n<iterations;n++)checksum+=optimized().length;
  const b=performance.now();
  assert.equal(checksum,iterations*64);
  assert.ok(b-middle<(middle-a)*2,'avoid pathological slowdown in Node fixture');
  console.log(`Node scheduler CPU 4096 visibility entries × ${iterations}: sorted ${(middle-a).toFixed(1)}ms; stable top-k ${(b-middle).toFixed(1)}ms; not WebView2/GPU`);
});
