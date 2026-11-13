import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [main,css,webp]=await Promise.all([
  readFile(resolve(root,'src/main.tsx'),'utf8'),
  readFile(resolve(root,'src/coco-ui.css'),'utf8'),
  readFile(resolve(root,'public/reyna-2.webp')),
]);

test('the library is the landing screen: newest game, then every other game right below',()=>{
  assert.match(main,/useState<View>\('library'\)/);
  assert.doesNotMatch(main,/view==='home'|className="summary-strip"|className="hero"/);
  assert.match(main,/\{latestNode\}\s*\{gridEntries\.length>0\|\|latest\?<div ref=\{gridRef\} className="experience-grid">/);
  assert.match(main,/bootstrapLoaded&&!firstRunDone&&isTauri\(\)/,'first-run action must still be usable without catalog');
  assert.match(main,/hostStudioAvailable=\{hostStudioAvailable\}/,'only the host receives the authoring capability');
});

test('the side panel always holds the wordmark, the full Reyna and the launcher state',()=>{
  assert.equal(webp.toString('ascii',8,12),'WEBP');
  const stage=main.slice(main.indexOf('<aside className="coco-stage"'),main.indexOf('</aside>'));
  assert.match(stage,/className="coco-wordmark"/);
  assert.match(stage,/className="coco-reyna" src="\/reyna-2\.webp"/);
  assert.match(stage,/launcherStatus\.label/);
  assert.match(css,/\.coco-stage\{position:fixed/);
  assert.match(css,/\.coco-reyna\{[^}]*pointer-events:none/);
});

test('cards keep a tight corner, and the bar stays reachable while scrolling',()=>{
  assert.match(css,/\.coco2-desktop \.experience-card\{[^}]*border-radius:6px/);
  assert.match(css,/\.coco-bar\{position:sticky;top:0/);
  assert.match(css,/\.coco2-desktop \.overlay\{top:0;z-index:60/);
});

test('no animation-off switch; subtle ambient motion follows Windows accessibility',()=>{
  assert.doesNotMatch(main,/Desactivar animaciones|Activar animaciones|toggleMotionPreference|setMotionPreference/);
  assert.match(main,/const motion=!systemReducedMotion/);
  assert.match(main,/hoverVideoPool\.setEnabled\(motion\)/);
  assert.match(css,/@keyframes coco-float/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)\{\.coco2-desktop \*/);
});

test('the app has its own icon and name, never Coco 1\'s',async()=>{
  const [icon,legacy,sync,config,html]=await Promise.all([
    readFile(resolve(root,'src-tauri/icons/icon.ico')),readFile(resolve(root,'../../reynaico.ico')),
    readFile(resolve(root,'scripts/sync-catalog.mjs'),'utf8'),readFile(resolve(root,'src-tauri/tauri.conf.json'),'utf8'),
    readFile(resolve(root,'index.html'),'utf8')]);
  assert.ok(!icon.equals(legacy),'the build must not ship the first launcher icon');
  assert.doesNotMatch(sync,/reynaico\.ico/,'the catalog sync must not overwrite the icon');
  assert.equal(JSON.parse(config).app.windows[0].title,'Coco Launcher 2','the taskbar shows the full name');
  assert.match(html,/<title>Coco Launcher 2<\/title>/);
});
