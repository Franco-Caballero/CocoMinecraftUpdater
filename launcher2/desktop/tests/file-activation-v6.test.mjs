import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const load=p=>readFile(resolve(root,p),'utf8');

test('Windows starts one primary UI; secondary activation is a path-only request',async()=>{
  const [native,mod,ipc]=await Promise.all([
    load('src-tauri/src/lib.rs'),load('src-tauri/src/services/mod.rs'),
    load('src-tauri/src/services/activation.rs'),
  ]);
  assert.match(mod,/pub mod activation;/);
  assert.match(native,/match services::activation::start_or_handoff\(\)/);
  assert.match(native,/Ok\(false\) => return/);
  assert.ok(native.indexOf('start_or_handoff()')<native.indexOf('tauri::Builder::default()'));
  assert.match(native,/services::activation::attach_app\(app\.handle\(\)\)/);
  assert.match(native,/services::activation::take_pending_package_open_requests/);
  assert.match(ipc,/coco2:\/\/package-open-request/);
  assert.match(ipc,/\.coco2pack\.zip/);
  assert.match(ipc,/\.coco2pack/);
  assert.doesNotMatch(ipc,/import_local_publish_package|install_standalone\(/);
});

test('Explorer opens a review overlay, never an automatic importer or launcher',async()=>{
  const [app,hub,inbox]=await Promise.all([load('src/main.tsx'),load('src/CatalogHub.tsx'),load('src/package-inbox.ts')]);
  const listenAt=app.indexOf("listen<unknown>('coco2://package-open-request'");
  const drainAt=app.indexOf('void drain.trigger();',listenAt);
  assert.ok(listenAt>=0&&drainAt>listenAt,'subscribe before initiating the native cold queue drain');
  assert.match(app,/new PackageActivationDrain<unknown>\([\s\S]*?peek_pending_package_open_requests/);
  assert.match(app,/acknowledge_pending_package_open_requests/);
  assert.match(app,/window\.addEventListener\('focus',refocus\);[\s\S]*?listen<unknown>/);
  assert.match(inbox,/const path=typeof item==='string'\?item:/);
  assert.match(inbox,/i<Math\.min\(raw\.length,MAX_BATCH_INSPECT\)/);
  assert.match(inbox,/let dropped=Math\.min\(999,state\.dropped\+overLimit\)/);
  assert.match(inbox,/path\.length<=32767/);
  assert.match(app,/commitInbox\(enqueuePackageRequests\(inboxLive\.current,accepted\)\)/);
  assert.match(app,/if\(retained\.size>=MAX_PENDING_PACKAGES\)break/);
  assert.match(app,/persistPackageInbox\(next\)/);
  assert.match(app,/inbox\.dropped>0/);
  assert.match(app,/incomingPackages\.length>0&&!packageReviewDeferred&&isTauri\(\)/);
  assert.match(app,/role="dialog" aria-modal="true"/);
  assert.match(app,/event\.key==='Escape'/);
  assert.match(app,/\.catalog-inbox-dismiss:not\(:disabled\)/);
  assert.match(hub,/if\(!hostCanImportNow\.current\)\{/);
  assert.match(hub,/incomingPath\}\)\s*\.then/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(hub,/reviewToken:review\.reviewToken,confirmed:true/);
  assert.match(hub,/onInboxDone\?\.\(incomingPath\)/);
  const start=app.indexOf('// Explorer activation');
  const end=app.indexOf('// Reconcile interrupted native operations',start);
  assert.ok(start>=0&&end>start,'file activation effect must be delimited before read-only recovery');
  assert.doesNotMatch(app.slice(start,end),/import_local_publish_package|install_standalone|launch_standalone/);
});

test('manual picker includes canonical and legacy format, never associates generic ZIP',async()=>{
  const [hub,config]=await Promise.all([load('src/CatalogHub.tsx'),load('src-tauri/tauri.conf.json')]);
  assert.match(hub,/extensions:\['coco2pack','zip'\]/);
  const settings=JSON.parse(config);
  assert.deepEqual(settings.bundle.fileAssociations.flatMap(a=>a.ext),['coco2pack']);
  assert.equal(settings.bundle.windows.nsis.installMode,'currentUser');
  assert.equal(settings.bundle.windows.nsis.template,'windows/nsis/installer-safe.nsi');
});
