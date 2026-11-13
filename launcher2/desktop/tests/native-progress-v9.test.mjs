import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(desktop,name),'utf8');
async function helper(name){
  const js=ts.transpileModule(await read(name),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}
const event=(phase,done,total,id='game',file='archive-a.zip')=>({id,phase,file,
  downloadedBytes:done,totalBytes:total,percent:total?Math.floor(done*100/total):0});

test('real Rust extraction bytes progress to 100% without rebuilding React for every 0.1% event',async()=>{
  const {NativeProgressSampler}=await helper('src/native-progress-sampler.ts');
  const sampler=new NativeProgressSampler(90);
  const seen=[];
  for(let i=0;i<=1000;i++){
    const progress=event('extracting',i*1048576,1000*1048576);
    if(sampler.accept(progress,i*2))seen.push(progress);
  }
  assert.equal(seen[0].downloadedBytes,0);
  assert.equal(seen.at(-1).percent,100);
  assert.ok(seen.length>=12&&seen.length<70,`should throttle real byte events; got ${seen.length}`);
  assert.ok(seen.every((p,i)=>i===0||p.downloadedBytes>seen[i-1].downloadedBytes));
});

test('phase, file and fresh operation changes are not dropped; stale and malformed byte reports fail closed',async()=>{
  const {NativeProgressSampler,nativeProgressDescription}=await helper('src/native-progress-sampler.ts');
  const s=new NativeProgressSampler(1000);
  assert.equal(s.accept(event('downloading',500,1000),1),true);
  assert.equal(s.accept(event('downloading',400,1000),2),false,'old out-of-order network progress');
  assert.equal(s.accept(event('downloading',600,1000),3),false,'throttle mid-phase');
  assert.equal(s.accept(event('downloading',1000,1000),4),true,'final bytes are never throttled');
  assert.equal(s.accept(event('extracting',0,200000),5),true,'new phase can restart at zero with different unit');
  assert.equal(s.accept(event('extracting',1,200000,'game','archive-b.zip'),6),false,'new file alone must not trigger a catalog rerender');
  assert.equal(s.accept(event('extracting',1,200000,'game','archive-b.zip'),1006),true,'new archive progresses after the debounce interval');
  assert.equal(s.accept(event('extracting',0,200000,'game','archive-c.zip'),1010),false,'late earlier file never rolls cumulative extracted bytes backwards');
  assert.equal(s.accept(event('extracting',-1,200000),7),false);
  assert.equal(s.accept(event('extracting',200001,200000),7),false);
  assert.equal(s.accept(event('extracting',100,1000,'game','archive-b.zip'),Infinity),false);
  s.reset();
  assert.equal(s.accept(event('extracting',0,500),9),true,'next installation may reuse same native phase');
  assert.equal(nativeProgressDescription('extracting'),'Descomprimiendo juego');
  assert.equal(nativeProgressDescription('repair-extracting'),'Descomprimiendo reparación');
  assert.equal(nativeProgressDescription('upgrade-extracting'),'Descomprimiendo actualización');
  assert.equal(nativeProgressDescription('internal-private-path'),'Preparando archivos');
});

test('native events for another game, stale finished commands or launch must never override installer progress',async()=>{
  const {NativeOperationGate}=await helper('src/native-operation-gate.ts');
  const g=new NativeOperationGate();
  assert.equal(g.acceptsProgress('game'),false);
  const a=g.begin('game','install');
  assert.equal(g.acceptsProgress('game'),true);
  assert.equal(g.acceptsProgress('another'),false);
  g.finish(a);
  assert.equal(g.acceptsProgress('game'),false);
  const b=g.begin('game','launch');
  assert.equal(g.acceptsProgress('game'),false);
  g.finish(b);
  const c=g.begin('game','verify');
  assert.equal(g.acceptsProgress('game'),false,'file-hashing verification cannot accept a stale installer event');
  g.finish(c);
});

test('frontend wires event fencing and human-readable extraction, preserving genuine Rust bytes',async()=>{
  const [ui,rust]=await Promise.all([read('src/main.tsx'),read('src-tauri/src/services/install.rs')]);
  assert.match(ui,/nativeOperationGate\.current\.acceptsProgress\(update\.id\)/);
  assert.match(ui,/nativeProgressSampler\.current\.accept\(update,performance\.now\(\)\)/);
  assert.match(ui,/nativeProgressDescription\(installProgress\?\.phase\|\|''\)/);
  assert.match(ui,/nativeProgressSampler\.current\.reset\(\)/);
  assert.match(rust,/"repair-extracting"/);
  assert.match(rust,/"upgrade-extracting"/);
  assert.match(rust,/downloaded_bytes: done, total_bytes: total, percent/);
});
