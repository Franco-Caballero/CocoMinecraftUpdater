import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function quick(){
  const source=await readFile(resolve(root,'src/quick-discovery.ts'),'utf8');
  const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const searchSource=await readFile(resolve(root,'src/experience-search.ts'),'utf8');
  const searchJs=ts.transpileModule(searchSource,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const moduleSearch={exports:{}};
  vm.runInNewContext(searchJs,{module:moduleSearch,exports:moduleSearch.exports});
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,require:()=>moduleSearch.exports});
  return module.exports;
}

test('first Ctrl+K without personalized history must inspect only enough cards to fill stable top six',async t=>{
  const {quickDiscovery}=await quick();
  let workflowReads=0;
  const cards=Array.from({length:4096},(_,i)=>({
    id:`g-${i}`,name:`Juego ${i}`,description:'',
    get workflow(){workflowReads++;return 'coco-standalone';},
  }));
  const start=performance.now();
  for(let n=0;n<100;n++){
    const found=quickDiscovery(cards,new Map(),'',new Set(),new Set(),6);
    assert.equal(found.map(x=>x.id).join(','),'g-0,g-1,g-2,g-3,g-4,g-5');
  }
  const elapsed=performance.now()-start;
  assert.ok(workflowReads<=6*100,'no need to scan 4,096 cards for six unpersonalized suggestions');
  t.diagnostic(`Synthetic Node 4096 cards, 100 empty Ctrl+K: ${workflowReads} workflow reads, ${elapsed.toFixed(1)}ms; NOT WebView2 first paint`);
});

test('fast path still preserves game-over-movie score, earlier tie order and personalized ranking',async()=>{
  const {quickDiscovery}=await quick();
  const media=Array.from({length:8},(_,i)=>({id:`movie-${i}`,name:`Película ${i}`,description:'',workflow:'coco-media'}));
  const games=Array.from({length:8},(_,i)=>({id:`game-${i}`,name:`Juego ${i}`,description:'',workflow:'coco-standalone'}));
  const cards=[...media,...games];
  const initial=quickDiscovery(cards,new Map(),'',new Set(),new Set(),6);
  assert.equal(initial.map(x=>x.id).join(','),'game-0,game-1,game-2,game-3,game-4,game-5');
  const personalized=quickDiscovery(cards,new Map(),'',new Set(['movie-7']),new Set(['movie-6']),6);
  assert.equal(personalized[0].id,'movie-6');
  assert.equal(personalized[1].id,'movie-7');
  assert.equal(quickDiscovery(cards,new Map(),'',new Set(),new Set(),0).length,0);
});
