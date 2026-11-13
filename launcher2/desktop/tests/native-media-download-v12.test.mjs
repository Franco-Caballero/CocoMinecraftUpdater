import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=path=>readFile(resolve(root,path),'utf8');
async function load(path){
  const js=ts.transpileModule(await source(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}
const event=(id,episodeId,done,total,phase='downloading')=>({
  id,episodeId,phase,downloadedBytes:done,totalBytes:total,percent:total?Math.floor(done/total*100):0,
});

test('two rapid clicks cannot start duplicate offline downloads or another native filesystem writer',async()=>{
  const {NativeMediaDownloadGate}=await load('src/native-media-download-gate.ts');
  const {NativeOperationGate}=await load('src/native-operation-gate.ts');
  const media=new NativeMediaDownloadGate(),writes=new NativeOperationGate();
  const first=media.begin('film-1','ep-1');
  const native=writes.begin('film-1','media-download');
  assert.ok(first&&native);
  for(let i=0;i<1000;i++){
    assert.equal(media.begin('film-1','ep-1'),null);
    assert.equal(media.begin('film-2','ep-2'),null);
    assert.equal(writes.begin('game','install'),null);
  }
  assert.equal(writes.finish(native),true);
  assert.equal(media.finish(first),true);
  assert.equal(media.finish(first),false);
  const next=media.begin('film-2','ep-2');
  assert.ok(next&&next.sequence>first.sequence);
  assert.equal(media.isLatest(first),false);
  assert.equal(media.isLatest(next),true);
});

test('1000 burst progress events are bounded and do not accept other episodes or stale rewinds',async()=>{
  const {NativeMediaDownloadGate}=await load('src/native-media-download-gate.ts');
  const media=new NativeMediaDownloadGate();
  const ticket=media.begin('film-é','ep-01');
  assert.ok(ticket);
  let accepted=0;
  for(let i=0;i<1000;i++){
    if(media.acceptProgress(event('film-é','ep-01',i+1,1000),i))accepted++;
    assert.equal(media.acceptProgress(event('film-é','other',i+1,1000),i),false);
    assert.equal(media.acceptProgress(event('other','ep-01',i+1,1000),i),false);
  }
  assert.ok(accepted>=2&&accepted<=15,`too many state updates: ${accepted}`);
  assert.equal(media.acceptProgress(event('film-é','ep-01',995,1000),1100),false,'old bytes cannot reduce progress');
  assert.equal(media.acceptProgress({...event('film-é','ep-01',1000,1000),downloadedBytes:1001},1100),false);
  assert.equal(media.acceptProgress(event('film-é','ep-01',0,0,'verifying'),1101),true,'new stage has a fresh byte counter');
  assert.equal(media.acceptProgress(event('film-é','ep-01',0,0,'verifying'),1102),false);
  assert.equal(media.acceptProgress(event('film-é','ep-01',0,0,'complete'),1103),true);
  media.finish(ticket);
  assert.equal(media.acceptProgress(event('film-é','ep-01',1000,1000),2000),false,'late event after completion');
});

test('cancel is exactly once until error resets it, without aborting another episode',async()=>{
  const {NativeMediaDownloadGate}=await load('src/native-media-download-gate.ts');
  const gate=new NativeMediaDownloadGate();
  assert.equal(gate.requestCancel(),null);
  const first=gate.begin('a','b');
  assert.equal(gate.requestCancel(),first);
  for(let i=0;i<200;i++)assert.equal(gate.requestCancel(),null);
  gate.cancellationFailed(first);
  assert.equal(gate.requestCancel(),first,'explicit retry after failed native cancellation');
  gate.finish(first);
  const next=gate.begin('a','c');
  gate.cancellationFailed(first);
  assert.equal(gate.requestCancel(),next,'stale failure cannot unlock another cancel');
  gate.finish(next);
});

test('malformed native progress rejects overflow, fractions, infinities and invalid IDs',async()=>{
  const {NativeMediaDownloadGate}=await load('src/native-media-download-gate.ts');
  const gate=new NativeMediaDownloadGate();
  assert.equal(gate.begin('','ep'),null);
  assert.equal(gate.begin('a',''),null);
  assert.equal(gate.begin('a'.repeat(129),'ep'),null);
  const current=gate.begin('safe','ep');
  for(const invalid of [
    {...event('safe','ep',5,10),downloadedBytes:Number.POSITIVE_INFINITY},
    {...event('safe','ep',5,10),downloadedBytes:-1},
    {...event('safe','ep',5,10),percent:0.5},
    {...event('safe','ep',5,10),totalBytes:-1},
    {...event('safe','ep',5,10),phase:''},
    {...event('safe','ep',5,10),downloadedBytes:2**54},
  ])assert.equal(gate.acceptProgress(invalid,500),false);
  assert.equal(gate.acceptProgress(event('safe','ep',2,10),Number.NaN),false);
  assert.equal(gate.acceptProgress(event('safe','ep',2,10),500),true);
  gate.finish(current);
});

test('React gates native media writes and progress together, and checks post-download identity',async()=>{
  const ui=await source('src/main.tsx');
  const listener=ui.slice(ui.indexOf("listen<MediaDownloadProgress>('coco2://media-download-progress'"),ui.indexOf("listen<RuntimeEvent>('coco2://runtime'"));
  assert.match(listener,/mediaDownloadGate\.current\.acceptProgress\(event\.payload,performance\.now\(\)\)/);
  // Films are no longer offered for download: nothing in the UI may start one.
  assert.doesNotMatch(ui,/invoke<[^>]*>\('download_media_episode'/);
});
