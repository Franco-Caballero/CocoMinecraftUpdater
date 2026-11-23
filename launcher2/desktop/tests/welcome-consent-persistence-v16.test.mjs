import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('the first-use welcome offers no package picker to anyone',async()=>{
  const app=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const welcome=app.match(/<LazyFirstRun[\s\S]*?\/>/)?.[0];
  assert.ok(welcome);
  assert.doesNotMatch(welcome,/hostStudioAvailable=|setPackagePickerRequest/);
  assert.match(welcome,/onOpenPackage=\{dismissWelcome\}/);
  assert.match(app,/const openImportedGame=\(id:string\)=>\{\s*dismissWelcome\(\);/);
  assert.match(welcome,/onDismiss=\{dismissWelcome\}/);
});

test('native friend selection remains review-only, and empty/cancelled dialogs never commit a library write',async()=>{
  const hub=await readFile(resolve(root,'src/CatalogHub.tsx'),'utf8');
  assert.match(hub,/typeof selected!=='string'/);
  assert.match(hub,/setMessage\('Selección cancelada\. No se realizó ninguna importación\.'/);
  assert.match(hub,/review_local_publish_package/);
  assert.match(hub,/!hostCanImportNow\.current\|\|!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(hub,/if\(!hostCanImportNow\.current\)\{/);
  assert.match(hub,/beginCommit\(reviewTicket,sourcePath,review\.reviewToken\)/);
});
