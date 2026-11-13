import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const sample=(phase,done,total,id='synthetic')=>({id,phase,downloadedBytes:done,totalBytes:total,percent:Math.floor(done/total*100),file:'hash.zip'});
async function createMeter(){
  const code=await readFile(resolve(root,'src/native-transfer-rate.ts'),'utf8');
  const js=ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports});return module.exports;
}

test('download speed and ETA derive from observed native bytes and elapsed time only',async()=>{
  const {NativeTransferRateMeter,nativeTransferRateText}=await createMeter();
  const m=new NativeTransferRateMeter();
  const MB=1048576;
  assert.equal(m.observe(sample('downloading',0,100*MB),1000),null);
  assert.equal(m.observe(sample('downloading',3*MB,100*MB),1200),null,'insufficient observation window');
  const measured=m.observe(sample('downloading',10*MB,100*MB),2000);
  assert.equal(measured.bytesPerSecond,10*MB,'10 MiB physically observed in one synthetic second');
  assert.equal(measured.remainingSeconds,9);
  assert.equal(nativeTransferRateText(measured),'10.0 MB/s de avance · aprox. 9 s');
  assert.equal(m.observe(sample('downloading',100*MB,100*MB),10000),null,'no ETA after complete');
});

test('renamed phases and resets never misreport extraction/hash throughput as network speed',async()=>{
  const {NativeTransferRateMeter}=await createMeter();
  const m=new NativeTransferRateMeter();
  const MB=1048576;
  m.observe(sample('repair-downloading',MB,50*MB),1000);
  assert.ok(m.observe(sample('repair-downloading',2*MB,50*MB),2000));
  assert.equal(m.observe(sample('repair-extracting',20*MB,50*MB),3000),null);
  assert.equal(m.observe(sample('upgrade-downloading',2*MB,50*MB),4000),null,'new stage must wait to measure');
  assert.equal(m.observe(sample('upgrade-downloading',1*MB,50*MB),4500),null,'native offset rewind starts a fresh window');
  assert.ok(m.observe(sample('upgrade-downloading',3*MB,50*MB),5500));
  assert.equal(m.observe(sample('upgrade-downloading',5*MB,50*MB,'different-game'),6000),null,'another experience must reset');
  assert.equal(m.observe(sample('upgrade-verifying',6*MB,50*MB),7000),null);
});

test('stalled network, malformed events and hidden-window time gaps cannot generate fake speed',async()=>{
  const {NativeTransferRateMeter,nativeTransferRateText}=await createMeter();
  const m=new NativeTransferRateMeter();
  const MB=1048576;
  m.observe(sample('downloading',MB,50*MB),1);
  assert.ok(m.observe(sample('downloading',2*MB,50*MB),1001));
  assert.equal(m.observe(sample('downloading',2*MB,50*MB),16001),null,'stalled for 15s');
  assert.equal(m.observe(sample('downloading',2*MB,50*MB),16100),null);
  assert.ok(Math.abs(m.observe(sample('downloading',3*MB,50*MB),17100).bytesPerSecond-MB)<MB/10,'fresh observed speed after stall');
  assert.equal(m.observe(sample('downloading',5*MB,50*MB),32100),null,'gap with bytes must not be misreported as slow live network');
  assert.equal(m.observe(sample('downloading',-4,50*MB),18000),null);
  assert.equal(m.observe(sample('downloading',MB,50*MB),18050),null);
  assert.equal(m.observe(sample('downloading',2*MB,50*MB),17000),null,'reversed clock resets');
  assert.equal(nativeTransferRateText(null),'');
  assert.equal(nativeTransferRateText({bytesPerSecond:100,remainingSeconds:100}),'');
});

test('UI declares rates as observed download only, and repair/upgrade phases are correctly labeled',async()=>{
  const [ui,labels]=await Promise.all([
    readFile(resolve(root,'src/main.tsx'),'utf8'),
    readFile(resolve(root,'src/native-progress-sampler.ts'),'utf8'),
  ]);
  assert.match(ui,/nativeTransferRateMeter\.current\.observe\(update,observedAt\)/);
  assert.match(ui,/nativeTransferRateText\(installTransferRate\)/);
  assert.match(labels,/repair-downloading/);
  assert.match(labels,/upgrade-downloading/);
});
