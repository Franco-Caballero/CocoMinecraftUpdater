import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const code=ts.transpileModule(await readFile(resolve(root,'src/package-inbox.ts'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
}).outputText;
const mod={exports:{}};
vm.runInNewContext(code,{module:mod,exports:mod.exports});
const {emptyPackageInbox,enqueuePackageRequests,extractPackagePaths,dismissPackageRequest}=mod.exports;

test('untrusted 100k-entry Explorer event has bounded parsing, visible loss notice and exact FIFO',()=>{
  const paths=Array.from({length:100_000},(_,i)=>`C:\\Synthetic\\game-${i}.coco2pack`);
  const begin=performance.now();
  const parsed=extractPackagePaths({paths});
  const inbox=enqueuePackageRequests(emptyPackageInbox(),{paths});
  const elapsed=performance.now()-begin;
  assert.ok(parsed.length<=512,`must not materialize ${parsed.length} untrusted strings`);
  assert.equal(inbox.paths.length,96);
  assert.equal(inbox.paths[0],paths[0]);
  assert.equal(inbox.paths.at(-1),paths[95]);
  assert.ok(inbox.dropped>0,'truncated batch must be visible, not silent');
  assert.ok(elapsed<500,`100k adversarial event ${elapsed.toFixed(1)} ms`,);
  const afterDismiss=dismissPackageRequest(inbox,paths[0]);
  const resumed=enqueuePackageRequests(afterDismiss,{path:'C:\\Synthetic\\later.coco2pack'});
  assert.equal(resumed.paths.length,96);
  assert.equal(resumed.paths.at(-1),'C:\\Synthetic\\later.coco2pack');
  console.log(`Synthetic Node 100k Explorer paths: ${elapsed.toFixed(2)}ms; not a physical Explorer/WebView2 timing`);
});

test('a burst of repeated IDs is deduplicated and does not create false overflow for <=512 input paths',()=>{
  const filename='C:\\Packages\\Único 漢字.coco2pack';
  const inbox=enqueuePackageRequests(emptyPackageInbox(),Array.from({length:500},()=>filename));
  assert.equal(inbox.paths.length,1);
  assert.equal(inbox.dropped,0);
});
