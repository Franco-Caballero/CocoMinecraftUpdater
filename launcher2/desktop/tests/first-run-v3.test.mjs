import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=name=>readFile(resolve(root,name),'utf8');

test('first launch never forces Minecraft identity, game installation, ZeroTier or UAC',async()=>{
  const [welcome,app]=await Promise.all([source('src/FirstRun.tsx'),source('src/main.tsx')]);
  assert.match(welcome,/onExplore/);
  // Games need no network setup: the welcome offers none, so nothing there can lead to UAC.
  assert.doesNotMatch(welcome,/onNetwork|Estado de la red|Preparar red/);
  assert.doesNotMatch(welcome,/Tus juegos ya están aquí/);
  assert.doesNotMatch(welcome,/invoke\(|child_process|powershell|install_network|join_coco_network/);
  assert.match(app,/coco2-welcome-v1/);
  assert.match(app,/bootstrapLoaded&&!firstRunDone&&isTauri\(\)/);
  assert.match(app,/catalogReady=\{items\.length>0&&!loadError\}/);
  assert.match(app,/onExplore=\{\(\)=>\{dismissWelcome\(\);navigate\('library'\);if\(installedIds\.size\)setFilter\('installed'\);\}\}/);
});

test('catalog refresh invalidates same-ID stale install and upgrade plans',async()=>{
  const app=await source('src/main.tsx');
  assert.match(app,/setCatalogEpoch\(previous=>previous\+1\)/);
  assert.match(app,/\},\[selected\?\.id,catalogEpoch\]\)/);
  const epochs=app.match(/\},\[selected\?\.id,localInstances,catalogEpoch\]\)/g)||[];
  assert.equal(epochs.length,2,'repair and upgrade effect must refresh after catalog acceptance');
});

test('pending upgrade journal takes precedence over normal repair and is not one-click dismissed',async()=>{
  const app=await source('src/main.tsx');
  assert.match(app,/upgradePlan\?\.status==='recovery-required'&&<button/);
  assert.match(app,/invoke<UpgradeOutcome>\('recover_standalone_upgrade'/);
  assert.match(app,/appUpdate.stage==='deferred'/);
});

test('client distinguishes signed official catalog, user-approved local package, and offline fallback',async()=>{
  const [app,hub,native]=await Promise.all([source('src/main.tsx'),source('src/CatalogHub.tsx'),source('src-tauri/src/lib.rs')]);
  assert.match(native,/services::catalog::get_catalog_provenance/);
  assert.match(app,/get_catalog_provenance/);
  assert.match(app,/Importado en este PC/);
  assert.match(hub,/No equivale a un juego del canal oficial firmado/);
  assert.match(hub,/status==='offline'/);
  assert.match(hub,/status==='unchanged'/);
});

test('Host Studio stage is explicitly unsigned/unpublished and reports assets for manual review',async()=>{
  const studio=await source('src/HostStudio.tsx');
  assert.match(studio,/readyForSignature:boolean/);
  assert.match(studio,/publicationAssets:/);
  assert.match(studio,/channelDraft\.publicationAssets\.length/);
  assert.match(studio,/archivos de distribución reservados para revisión manual del host/);
  assert.match(studio,/Esta pantalla no los publica/);
  assert.match(studio,/Firma oficial pendiente/);
  assert.match(studio,/Publicación GitHub pendiente/);
  assert.doesNotMatch(studio,/invoke\(['"](?:publish_release|github_upload|sign_release)['"]/);
});

test('Windows process discovery includes external games but never exposes unrelated process details',async()=>{
  const app=await source('src/main.tsx');
  assert.match(app,/get_active_game_processes/);
  assert.match(app,/setObservedGameIds\(current=>retainObservedGameIds\(current,report\.gameIds\)\)/);
  assert.match(app,/30000/);
  assert.match(app,/document\.hidden/);
  assert.match(app,/playing:\[\.\.\.new Set\(\[\.\.\.observedGameIds/);
  assert.doesNotMatch(app,/observedProcesses\.map|processReport\.matchedProcesses\.map/);
});
