import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const js=ts.transpileModule(await readFile(resolve(root,'src/native-progress-sampler.ts'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
}).outputText;
const module={exports:{}};
vm.runInNewContext(js,{module,exports:module.exports});
const {NativeProgressSampler}=module.exports;
const update=(downloadedBytes,totalBytes,percent,phase='extracting')=>({
  id:'juego-españa',phase,file:'archive.zip',downloadedBytes,totalBytes,percent,
});

test('native events delivered out of order may never regress progress when bytes are equal or same phase has inconsistent totals',()=>{
  const meter=new NativeProgressSampler(0);
  assert.equal(meter.accept(update(500,1000,50),100),true);
  assert.equal(meter.accept(update(500,1000,10),300),false,'old percent must not rewind at equal bytes');
  assert.equal(meter.accept(update(500,2000,25),500),false,'old total must not invent a new progress ratio');
  assert.equal(meter.accept(update(800,900,88),700),false,'same phase cannot suddenly shrink declared total');
  assert.equal(meter.accept(update(550,1000,55),800),true,'legitimate next byte update');
  assert.equal(meter.accept(update(0,2400,0,'verifying'),900),true,'phase transition intentionally starts new stage');
  assert.equal(meter.accept(update(2400,2400,100,'verifying'),1100),true);
});

test('large progress streams remain bounded, terminal events emitted and invalid values cannot escape',()=>{
  const meter=new NativeProgressSampler(90);
  let painted=0;
  for(let i=0;i<=10000;i++)if(meter.accept(update(i,10000,Math.floor(i/100)),i/10))painted++;
  assert.ok(painted<30,`too many React paints: ${painted}`);
  assert.equal(meter.accept(update(10000,10000,100),1002),false);
  assert.equal(meter.accept(update(50,100,50,'repair-verifying'),1200),true);
  assert.equal(meter.accept(update(50,100,-1,'repair-verifying'),1300),false);
});
