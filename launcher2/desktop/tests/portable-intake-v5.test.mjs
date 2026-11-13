import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const get=name=>readFile(resolve(root,name),'utf8');

test('recipient selects portable archive directly, no manual extraction or script',async()=>{
  const hub=await get('src/CatalogHub.tsx');
  assert.match(hub,/open\(legacyFolder\s*\?/);
  assert.match(hub,/directory:false,multiple:false,title:'Elegir paquete Coco 2'/);
  assert.match(hub,/extensions:\['coco2pack','zip'\]/);
  assert.match(hub,/invoke<LocalPackageReview>\('review_local_publish_package'/);
  assert.match(hub,/invoke<ChannelStatus>\('import_local_publish_package'/);
  assert.match(hub,/path:sourcePath,reviewToken:review.reviewToken,confirmed:true/);
  assert.match(hub,/Origen local|Compartido por otra persona/);
  assert.doesNotMatch(hub,/spawn\(|powershell|extractArchive\(/i);
});

test('review binds user consent to verified metadata and opens game only after persistent commit',async()=>{
  const [hub,app]=await Promise.all([get('src/CatalogHub.tsx'),get('src/main.tsx')]);
  assert.match(hub,/coverDataUrl\?\.startsWith\('data:image\/'\)/);
  assert.match(hub,/changedFields\.slice\(0,12\)/);
  assert.match(hub,/!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(hub,/setStatus\(result\);setReview\(null\);setConfirmed\(false\)/);
  // A valid native commit now survives React unmount/routing changes; the
  // persistent catalog refresh is performed by the settlement helper, not an
  // inline conditional that could return early and lose warm inbox ACKs.
  assert.match(hub,/const outcome=await settleAcceptedPortableImport\(/);
  assert.match(hub,/result,\s*\(\)=>onChanged\(\)/);
  assert.match(hub,/\(\)=>\{[\s\S]*?onInboxDone\?\.\(committedPath\)/);
  assert.match(hub,/onImported\?\.\(importedId\)/);
  assert.match(app,/trustedCatalogSnapshot\.current=nextById/);
  assert.match(app,/const verified=trustedCatalogSnapshot\.current\.get\(id\)/);
  assert.match(app,/verified\?\.workflow==='coco-standalone'/);
});

test('repeat import is shown as no change and official trust never inferred from package',async()=>{
  const hub=await get('src/CatalogHub.tsx');
  assert.match(hub,/result.status==='unchanged'\?'Sin cambios/);
  assert.match(hub,/Compartido por otra persona/);
  assert.match(hub,/No equivale a un juego del canal oficial firmado/);
  assert.match(hub,/setConfirmed\(false\)/);
  assert.match(hub,/No se modificó tu biblioteca/);
});

test('Host export produces one Windows-extractable ZIP and clearly distinguishes public release review',async()=>{
  const [host,studio,lib]=await Promise.all([get('src-tauri/src/services/host_publish.rs'),get('src/HostStudio.tsx'),get('src-tauri/src/lib.rs')]);
  assert.match(host,/\.coco2pack/);
  assert.match(host,/rename_no_replace\(&temp,&dest\)/);
  assert.match(studio,/export_portable_standalone_package/);
  assert.match(studio,/Juegos → Abrir paquete Coco/);
  assert.match(studio,/nada se publicó ni se importó|no está publicado ni se ha importado/i);
  assert.match(lib,/review_local_publish_package/);
  assert.match(lib,/import_local_publish_package/);
});
