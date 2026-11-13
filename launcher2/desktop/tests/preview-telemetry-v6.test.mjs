import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
test('decoded-frame timings stay real inside the pool and never reach the settings page',async()=>{
  const [ui,pool]=await Promise.all([
    readFile(resolve(root,'src/main.tsx'),'utf8'),
    readFile(resolve(root,'src/hover-video-pool.ts'),'utf8'),
  ]);
  assert.doesNotMatch(ui,/PreviewDiagnostics|Rendimiento de las vistas previas/);
  assert.match(pool,/const latency=Math\.max\(0,this\.now\(\)-clip\.hoverStartedAt\)/);
  assert.match(pool,/requestVideoFrameCallback/);
});
