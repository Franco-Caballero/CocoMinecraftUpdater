import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function inbox(){
  const js=ts.transpileModule(await readFile(resolve(root,'src/package-inbox.ts'),'utf8'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}

test('cold and warm activation merge FIFO, object and array events, Unicode spaces, and de-duplicate exact paths',async()=>{
  const {emptyPackageInbox,enqueuePackageRequests,dismissPackageRequest}=await inbox();
  const first='C:\\Juegos\\Mi amigo\\revisión áé 漢字.coco2pack';
  const second='C:\\Juegos\\Otro juego.coco2pack';
  let state=enqueuePackageRequests(emptyPackageInbox(),{paths:[{path:first},second,{path:first}]});
  assert.deepEqual([...state.paths],[first,second]);
  state=enqueuePackageRequests(state,{path:first});
  assert.equal(state.paths.length,2);
  state=enqueuePackageRequests(state,'C:\\Juegos\\tercero.coco2pack');
  assert.equal(state.paths[2],'C:\\Juegos\\tercero.coco2pack');
  state=dismissPackageRequest(state,first);
  assert.deepEqual([...state.paths],[second,'C:\\Juegos\\tercero.coco2pack']);
});

test('excess native notifications cannot silently discard after 24 or exhaust React memory; overflow remains visible',async()=>{
  const {MAX_PENDING_PACKAGES,emptyPackageInbox,enqueuePackageRequests,acknowledgePackageOverflow}=await inbox();
  assert.equal(MAX_PENDING_PACKAGES,96);
  const batch=Array.from({length:112},(_,i)=>`C:\\Shared\\game-${i}.coco2pack`);
  let state=enqueuePackageRequests(emptyPackageInbox(),batch);
  assert.equal(state.paths.length,96);
  assert.equal(state.dropped,16);
  assert.equal(state.paths[0],batch[0]);
  assert.equal(state.paths.at(-1),batch[95]);
  state=enqueuePackageRequests(state,[...batch.slice(0,96),'C:\\Shared\\excess.coco2pack']);
  assert.equal(state.dropped,17,'duplicate notifications do not inflate the overflow');
  assert.equal(acknowledgePackageOverflow(state).dropped,0);
  assert.equal(acknowledgePackageOverflow(state).paths.length,96);
});

test('malformed activation entries are ignored before UI, never imported as a manifest',async()=>{
  const {extractPackagePaths}=await inbox();
  assert.deepEqual([...extractPackagePaths({paths:[null,12,{path:13},'',
    'C:\\games\\a\nwrong.coco2pack','C:\\games\\a\0b.coco2pack',
    'C:\\games\\allowed.coco2pack']})],['C:\\games\\allowed.coco2pack']);
  assert.equal(extractPackagePaths('X'.repeat(32768)).length,0);
});

test('Tauri starts cold drain regardless of subscription, then drains again after listener; review stays consent-only',async()=>{
  const app=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const subscribe=app.indexOf("listen<unknown>('coco2://package-open-request'");
  const drain=app.indexOf('void drain.trigger();',subscribe);
  const nativeQueue=app.indexOf("new PackageActivationDrain<unknown>");
  assert.ok(nativeQueue>=0&&subscribe>nativeQueue&&drain>subscribe,
    'cold-start queue is independent of event subscription and rechecked after attachment');
  assert.match(app,/new PackageActivationDrain<unknown>\([\s\S]*?peek_pending_package_open_requests/);
  assert.match(app,/acknowledge_pending_package_open_requests/);
  assert.match(app,/commitInbox\(enqueuePackageRequests\(inboxLive\.current,accepted\)\)/);
  assert.match(app,/window\.addEventListener\('focus',refocus\)/);
  assert.match(app,/document\.addEventListener\('visibilitychange',refocus\)/);
  assert.match(app,/drain\.dispose\(\)/);
  assert.match(app,/void drain\.trigger\(\);\s*return\(\)=>/);
  assert.match(app,/onInboxDone=\{path=>\{[\s\S]*?commitInbox\(dismissPackageRequest\(inboxLive\.current,path\)\)/);
  assert.match(app,/release_reviewed_package_replay_suppression/);
  assert.match(app,/priorInboxFocus\.current=document\.activeElement/);
  assert.match(app,/if\(!packageReviewDeferred&&prior\?\.isConnected\)prior\.focus\(\)/);
  assert.match(app,/inbox\.dropped>0/);
  assert.doesNotMatch(app,/invoke\(['"]import_local_publish_package['"].*?incomingPackages/);
});
