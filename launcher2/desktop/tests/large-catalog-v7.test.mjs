import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=name=>readFile(resolve(root,name),'utf8');

async function searchHelpers(){
  const js=ts.transpileModule(await source('src/experience-search.ts'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}

test('2,048 catalog items are indexed once; repeated accented searches do not recompute metadata',async t=>{
  const {indexExperiences,matchesExperienceQuery,normalizeExperienceQuery}=await searchHelpers();
  const catalog=Array.from({length:2048},(_,i)=>({
    id:`experience-${i}`,name:`Juego Núméro ${i}`,description:`Cooperativo áéíóú ${i}`,
  }));
  let metadataReads=0;
  const start=process.hrtime.bigint();
  const index=indexExperiences(catalog,()=>{metadataReads++;return 'Multijugador';});
  assert.equal(index.size,2048);
  assert.equal(metadataReads,2048);
  assert.equal(matchesExperienceQuery(index,'experience-73',normalizeExperienceQuery('NUMERO 73')),true);
  assert.equal(matchesExperienceQuery(index,'experience-73',normalizeExperienceQuery('cooperativo')),true);
  assert.equal(matchesExperienceQuery(index,'experience-73',normalizeExperienceQuery('multijugador')),true);
  assert.equal(matchesExperienceQuery(index,'experience-73',normalizeExperienceQuery('sin coincidencia')),false);
  for(let i=0;i<200;i++){
    const query=normalizeExperienceQuery(`Numero ${i}`);
    for(const entry of catalog)matchesExperienceQuery(index,entry.id,query);
  }
  assert.equal(metadataReads,2048,'typing must not rebuild descriptions and metadata');
  const elapsed=Number(process.hrtime.bigint()-start)/1e6;
  t.diagnostic(`Synthetic Node: 2048 entries, 200 queries, ${elapsed.toFixed(1)}ms search CPU; NOT WebView2 first paint`);
});

test('incremental cards render bounded batches but still reach the entire catalog',async()=>{
  const {EXPERIENCE_PAGE_SIZE,nextExperiencePage}=await searchHelpers();
  assert.equal(EXPERIENCE_PAGE_SIZE,48);
  let count=EXPERIENCE_PAGE_SIZE,steps=0;
  while(count<2048){
    const next=nextExperiencePage(count,2048);
    assert.ok(next>count&&next-count<=48);
    count=next;steps++;
  }
  assert.equal(count,2048);
  assert.ok(steps>40);
  assert.equal(nextExperiencePage(2048,2048),2048);
  assert.equal(nextExperiencePage(0,5),5);
  assert.equal(nextExperiencePage(-200,5),5);
});

test('search is deferred and results progressive; background previews still cover every curated source',async()=>{
  const [app,pool]=await Promise.all([source('src/main.tsx'),source('src/hover-video-pool.ts')]);
  assert.match(app,/useDeferredValue\(search\)/);
  assert.match(app,/indexExperiences\(items,meta\)/);
  assert.match(app,/gridEntries\.slice\(0,visibleCount\)/);
  assert.match(app,/IntersectionObserver\(entries=>/);
  assert.match(app,/rootMargin:'600px 0px'/);
  assert.match(app,/gameProcessUncertain\|\|/);
  assert.match(app,/if\(!bootstrapLoaded\|\|!isTauri\(\)\)return/);
  assert.match(app,/onClick=\{\(\)=>setVisibleCount\(current=>nextExperiencePage/);
  assert.match(pool,/const batch=Math\.min\(this\.sourceIds\.length,64\)/);
  assert.doesNotMatch(app,/filtered\.map\(card\)/);
});
