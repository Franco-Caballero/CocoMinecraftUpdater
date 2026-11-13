import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function load(){
  const js=ts.transpileModule(await readFile(resolve(root,'src/package-activation-drain.ts'),'utf8'),{
    compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,setTimeout,clearTimeout});
  return module.exports;
}
const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};
const sleep=ms=>new Promise(done=>setTimeout(done,ms));

test('fifth native activation during maxPasses boundary is eventually drained even without a new focus',async()=>{
  const {PackageActivationDrain}=await load();
  const waiters=[],results=[];
  let reads=0;
  const pump=new PackageActivationDrain(async()=>{
    reads++;
    const wait=deferred();waiters.push(wait);return wait.promise;
  },data=>results.push(...data),error=>{throw error;},4);
  const current=pump.trigger();
  for(let pass=0;pass<4;pass++){
    assert.equal(reads,pass+1);
    // Native can queue a new package while the fourth read is in flight.
    // The original implementation silently drops this final rerun signal.
    for(let burst=0;burst<64;burst++)pump.trigger();
    waiters[pass].resolve([`C:\\Revisión\\${pass} 日本語.coco2pack`]);
    for(let tick=0;tick<6;tick++)await Promise.resolve();
  }
  await current;
  await sleep(100);
  assert.ok(reads>=5,'the new arrival on the final bounded pass needs a later drain');
  waiters[4].resolve(['C:\\Revisión\\Final.coco2pack']);
  await sleep(10);
  assert.ok(results.includes('C:\\Revisión\\Final.coco2pack'));
  pump.dispose();
});

test('disposal while a deferred follow-up is queued cannot reopen the native inbox',async()=>{
  const {PackageActivationDrain}=await load();
  let reads=0;
  const pump=new PackageActivationDrain(async()=>{reads++;return [];},()=>{},()=>{},1);
  // Force an incoming signal between initial read and final microtask.
  const first=pump.trigger();pump.trigger();
  await first;
  const initial=reads;
  pump.dispose();
  await sleep(100);
  assert.equal(reads,initial);
  await pump.trigger();assert.equal(reads,initial);
});
