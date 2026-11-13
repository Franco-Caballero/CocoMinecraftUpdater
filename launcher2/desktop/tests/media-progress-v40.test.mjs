// Coco Cinema: where a viewer left each title, how it reads, and what the main button plays.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const compile=async(name,env={})=>{
  const source=await readFile(resolve(root,'src',name),'utf8');
  const code=ts.transpileModule(source,{fileName:name,compilerOptions:{target:ts.ScriptTarget.ES2022,
    module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.React}}).outputText;
  const module={exports:{}};
  runInNewContext(code,{module,exports:module.exports,...env});
  return module.exports;
};
function memoryStorage(){
  const data=new Map();
  return {getItem:key=>data.has(key)?data.get(key):null,setItem:(key,value)=>data.set(key,String(value))};
}

test('a title resumes only past the opening and before the credits',async()=>{
  const progress=await compile('media-progress.ts',{localStorage:memoryStorage(),Date});
  progress.saveProgress('film','main',12,6000);
  assert.equal(progress.resumePoint(progress.progressFor('film','main')),null,'a few seconds in starts over');
  progress.saveProgress('film','main',2400,6000);
  assert.equal(progress.resumePoint(progress.progressFor('film','main')),2400);
  assert.equal(progress.watchedFraction(progress.progressFor('film','main')),.4);
  progress.saveProgress('film','main',5950,6000);
  const done=progress.progressFor('film','main');
  assert.equal(done.finished,true,'the credits count as watched');
  assert.equal(progress.resumePoint(done),null);
  assert.equal(progress.watchedFraction(done),1);
  progress.saveProgress('film','main',NaN,6000);
  assert.equal(progress.progressFor('film','main').position,5950,'a broken reading never overwrites a good one');
});

test('missing storage never breaks playback',async()=>{
  const broken={getItem(){throw Error('denied');},setItem(){throw Error('denied');}};
  const progress=await compile('media-progress.ts',{localStorage:broken,Date});
  assert.doesNotThrow(()=>progress.saveProgress('film','main',100,200));
  assert.equal(progress.progressFor('film','main'),null);
});

test('clock and remaining time read like a player',async()=>{
  const progress=await compile('media-progress.ts',{Date});
  assert.equal(progress.formatClock(9),'0:09');
  assert.equal(progress.formatClock(309),'5:09');
  assert.equal(progress.formatClock(3909),'1:05:09');
  assert.equal(progress.formatClock(NaN),'0:00');
  assert.equal(progress.formatRemaining(4320),'1 h 12 min');
  assert.equal(progress.formatRemaining(3600),'1 h');
  assert.equal(progress.formatRemaining(20),'1 min');
});

test('season titles become a heading plus short episode names; the main button follows progress',async()=>{
  const storage=memoryStorage();
  const progress=await compile('media-progress.ts',{localStorage:storage,Date});
  const picker=await compile('EpisodePicker.tsx',{require:name=>name==='./media-progress'?progress:new Proxy({},{get:()=>()=>null}),React:{createElement:()=>null}});
  const episodes=[{id:'a',title:'Temporada 5 - Episodio 1 - Parte 1'},{id:'b',title:'Temporada 5 - Episodio 1 - Parte 2'},{id:'c',title:'Temporada 5 - Episodio 2'}];
  const {season,labels}=picker.episodeLabels(episodes);
  assert.equal(season,'Temporada 5');
  assert.deepEqual(labels,['Episodio 1 · Parte 1','Episodio 1 · Parte 2','Episodio 2']);
  assert.deepEqual(picker.episodeLabels([{id:'x',title:'The Drama (2026)'}]).labels,['The Drama (2026)'],'a lone film keeps its name');
  assert.equal(picker.mediaPlan('show',episodes,false).label,'Ver episodio 1');
  progress.saveProgress('show','a',3000,3000);
  assert.equal(picker.mediaPlan('show',episodes,false).episode.id,'b','after a finished episode comes the next one');
  progress.saveProgress('show','b',600,3000);
  const plan=picker.mediaPlan('show',episodes,false);
  assert.equal(plan.label,'Continuar E2');
  assert.equal(plan.remaining,2400);
  assert.equal(picker.mediaPlan('film',[{id:'main',title:'Film'}],true).label,'Ver película');
});
