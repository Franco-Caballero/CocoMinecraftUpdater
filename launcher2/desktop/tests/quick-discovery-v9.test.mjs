import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(desktop,name),'utf8');
async function moduleExports(name,requireFn=()=>{throw Error('Unexpected import');}){
  const script=ts.transpileModule(await read(name),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(script,{module,exports:module.exports,require:requireFn},{timeout:2000});
  return module.exports;
}
async function helpers(){
  const search=await moduleExports('src/experience-search.ts');
  const quick=await moduleExports('src/quick-discovery.ts',id=>{
    assert.equal(id,'./experience-search');
    return search;
  });
  return {...quick,...search};
}

test('cross-category search prefers title prefix, accents, favorites and recent; excludes paused Minecraft',async()=>{
  const {quickDiscovery,indexExperiences}=await helpers();
  const entries=[
    {id:'a',name:'Laberinto y pistas',description:'Espacios y velocidad',workflow:'coco-standalone'},
    {id:'b',name:'PEAK',description:'Escalada y aventura',workflow:'coco-standalone'},
    {id:'c',name:'Película en línea',description:'Video que menciona peak',workflow:'coco-media'},
    {id:'d',name:'Paquete de mods',description:'Minecraft peak',workflow:'coco-managed'},
    {id:'e',name:'Peaky capítulo',description:'Video sin conexión',workflow:'coco-media'},
  ];
  const index=indexExperiences(entries,()=> 'juegos videos');
  const matching=quickDiscovery(entries,index,'péak',new Set(['b']),new Set(['e']));
  assert.deepEqual(matching.map(x=>x.id).join(','),'b,e,c');
  assert.equal(quickDiscovery(entries,index,'película',new Set(),new Set())[0].id,'c');
  const suggestions=quickDiscovery(entries,index,'',new Set(['a']),new Set(['e']));
  assert.equal(suggestions[0].id,'e');
  assert.equal(suggestions[1].id,'a');
  assert.ok(!suggestions.some(x=>x.id==='d'));
  assert.equal(quickDiscovery(entries,index,'unmatched',new Set(),new Set()).length,0);
  assert.equal(quickDiscovery(entries,index,'',new Set(),new Set(),0).length,0);
});

test('arrows cycle the six visible results but never return an invalid index',async()=>{
  const {nextDiscoveryIndex}=await helpers();
  assert.equal(nextDiscoveryIndex(-1,'ArrowDown',6),0);
  assert.equal(nextDiscoveryIndex(0,'ArrowUp',6),5);
  assert.equal(nextDiscoveryIndex(5,'ArrowDown',6),0);
  assert.equal(nextDiscoveryIndex(2,'ArrowUp',6),1);
  assert.equal(nextDiscoveryIndex(12,'ArrowUp',6),5);
  assert.equal(nextDiscoveryIndex(0,'ArrowDown',0),-1);
  assert.equal(nextDiscoveryIndex(0,'ArrowDown',Number.NaN),-1);
});

test('large catalog search keeps at most six mounted options and reports only JavaScript CPU time',async t=>{
  const {quickDiscovery,indexExperiences,indexDiscoveryNames}=await helpers();
  const entries=Array.from({length:4096},(_,i)=>({
    id:`game-${i}`,name:`Juego de aventuras número ${i}`,description:`Video cooperativo capítulo ${i}`,
    workflow:i%5===0?'coco-media':'coco-standalone',
  }));
  const index=indexExperiences(entries,()=> 'Coop');
  const names=indexDiscoveryNames(entries);
  const start=process.hrtime.bigint();
  for(let i=0;i<240;i++){
    const found=quickDiscovery(entries,index,String(i%30),new Set(),new Set(),6,names);
    assert.ok(found.length<=6);
  }
  const milliseconds=Number(process.hrtime.bigint()-start)/1e6;
  assert.ok(milliseconds<4000,'small top-k search must stay usable without a full list sort');
  t.diagnostic(`Synthetic Node CPU: 4096 catalog entries, 240 searches, ${milliseconds.toFixed(2)} ms (not WebView2 typing/paint latency)`);
});

test('Ctrl+K, arrows and Enter only open trusted catalog details; modals retain keyboard priority',async()=>{
  const app=await read('src/main.tsx');
  const css=await read('src/discovery-v9.css');
  assert.match(app,/onKeyDown=\{onDiscoveryKey\}/);
  assert.match(app,/role="combobox" aria-autocomplete="list" aria-expanded=\{searchOpen\}/);
  assert.match(app,/role="listbox" aria-label=/);
  assert.match(app,/role="option" aria-selected=/);
  assert.match(app,/nextDiscoveryIndex\(/);
  assert.match(app,/if\(incomingPackages\.length\|\|hostStudioOpen\|\|selected\|\|mediaPlaying\)return/);
  const openAt=app.indexOf('const openDiscoveryEntry=(entry:Experience)=>{');
  assert.ok(openAt>=0);
  const details=app.slice(openAt,app.indexOf('const onDiscoveryKey=',openAt));
  assert.match(details,/openDetails\(entry\)/);
  assert.match(app,/const openDetails=\(entry:Experience\)=>\{[\s\S]*?setSelected\(entry\)/);
  assert.doesNotMatch(details,/invoke|installNative|launchNative|import_local_publish_package/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
  assert.match(css,/@media\(max-width:580px\)/);
});
