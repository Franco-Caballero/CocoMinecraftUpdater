import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('opening a game drawer suspends trailers underneath and resumes only after explicit hover',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const effect=ui.match(/const heavyWork=Boolean\([\s\S]*?\},\[[\s\S]*?\]\);/)?.[0];
  assert.ok(effect,'the central pool priority effect must remain present');
  assert.match(effect,/incomingPackages\.length\|\|hostStudioOpen/);
  assert.match(ui,/useEffect\(\(\)=>\{if\(selected\)hoverVideoPool\.pauseActive\(\);\},\[selected\?\.id\]\);/,
    'the hovered card stops behind an opened sheet');
  const pool=await readFile(resolve(root,'src/hover-video-pool.ts'),'utf8');
  assert.match(pool,/setBackgroundBusy\(busy:boolean\)\{[\s\S]*?this\.pauseAll\(\)/);
  assert.match(pool,/if\(!this\.enabled\|\|\(this\.backgroundBusy&&!this\.usesLocalFile\(id\)\)\)return;/,
    'only streaming yields to busy work; a clip on disk costs nothing');
});
