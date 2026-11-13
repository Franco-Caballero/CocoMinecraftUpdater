import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');

test('new client sees approved host catalog journey, and host-only picker never auto-imports or launches',async()=>{
  const [first,app,hub,css]=await Promise.all([
    read('src/FirstRun.tsx'),read('src/main.tsx'),read('src/CatalogHub.tsx'),read('src/experience-v2.css'),
  ]);
  assert.match(first,/hostStudioAvailable&&<button className="primary-button first-run-package-action" onClick=\{onOpenPackage\}/);
  assert.match(first,/Todo lo que ves lo aprobó el anfitrión/);
  assert.doesNotMatch(first,/Abrir paquete|importar/i);
  assert.match(app,/onOpenPackage=\{\(\)=>\{if\(hostStudioAvailable\)/);
  assert.match(app,/LazyFirstRun hostStudioAvailable=\{hostStudioAvailable\}/);
  assert.match(hub,/review_local_publish_package/);
  assert.match(hub,/!hostCanImportNow\.current\|\|!review\|\|!confirmed/);
  assert.match(hub,/reviewGate\.current\.beginCommit\(reviewTicket,sourcePath,review\.reviewToken\)/);
  assert.doesNotMatch(first,/invoke\(|import_local_publish_package|install_standalone|launch_standalone/);
  assert.match(css,/@media\(max-width:570px\)\{\.coco2-desktop \.first-run\{min-height:405px\}/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});

test('client first-day path cannot expose unsigned CTA even with empty embedded catalog',async()=>{
  const [first,app]=await Promise.all([read('src/FirstRun.tsx'),read('src/main.tsx')]);
  assert.match(first,/hostStudioAvailable=false/);
  assert.match(first,/hostStudioAvailable&&<button/);
  assert.match(first,/La biblioteca aún no tiene juegos disponibles/);
  assert.match(app,/pickerRequestId=\{hostStudioAvailable\?packagePickerRequest:0\}/);
});
