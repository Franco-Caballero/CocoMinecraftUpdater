import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('a missing or damaged initial catalog keeps Reyna and honest host-curated guidance without unsigned client import',async()=>{
  const [main,welcome]=await Promise.all([
    readFile(resolve(root,'src/main.tsx'),'utf8'),
    readFile(resolve(root,'src/FirstRun.tsx'),'utf8'),
  ]);
  const gate=main.match(/const welcomeVisible=[\s\S]*?;/)?.[0]||'';
  const render=main.match(/\{welcomeVisible&&<React\.Suspense[^\n]*<LazyFirstRun[^\n]+/)?.[0]||'';
  assert.match(gate,/bootstrapLoaded&&!firstRunDone&&isTauri\(\)/);
  assert.match(gate,/incomingPackages\.length===0/,'the Explorer inbox must take modal precedence');
  assert.match(main,/useState<View>\('library'\)/,'the welcome must remain reachable in the actual landing tab');
  assert.doesNotMatch(render,/items\.length>0&&!loadError&&isTauri\(\)/);
  assert.match(render,/catalogReady=\{items\.length>0&&!loadError\}/);
  assert.match(render,/hostStudioAvailable=\{hostStudioAvailable\}/);
  assert.match(welcome,/catalogReady:boolean/);
  assert.match(welcome,/disabled=\{!catalogReady\}/);
  assert.match(main,/className="coco-reyna" src="\/reyna-2\.webp"/,'Reyna stays in the side panel, catalog or not');
  assert.match(welcome,/hostStudioAvailable&&<button[^\n]*onClick=\{onOpenPackage\}/);
  assert.match(welcome,/No necesitas recibir archivos de otras personas/);
  assert.doesNotMatch(render,/onOpenPackage=\{\(\)=>\{dismissWelcome/);
  assert.match(render,/onOpenPackage=\{\(\)=>\{if\(hostStudioAvailable\)/);
});

test('client receives signed catalog route, but never a legacy or unsigned friend-package fallback',async()=>{
  const [main,hub]=await Promise.all([
    readFile(resolve(root,'src/main.tsx'),'utf8'),
    readFile(resolve(root,'src/CatalogHub.tsx'),'utf8'),
  ]);
  assert.match(main,/LazyCatalogHub hostStudioAvailable=\{hostStudioAvailable\}/);
  assert.match(main,/pickerRequestId=\{hostStudioAvailable\?packagePickerRequest:0\}/);
  assert.match(hub,/hostCanImport&&<button ref=\{openPackageButtonRef\}/);
  assert.match(hub,/hostCanImport&&!compact&&<details className="catalog-legacy-import"/);
  assert.match(hub,/hostCanImport&&<label className="catalog-consent"/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|!review/);
  assert.match(hub,/sync_catalog_channel/);
});
