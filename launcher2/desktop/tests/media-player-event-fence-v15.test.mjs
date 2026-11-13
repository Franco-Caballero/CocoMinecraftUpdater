import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('late buffered/error/playing events from a revoked video element cannot repaint a new player',async()=>{
  const player=await readFile(resolve(root,'src/MediaPlayer.tsx'),'utf8');
  assert.match(player,/const videoEvent=\(event:SyntheticEvent<HTMLVideoElement>,next:State\)=>\{/);
  assert.match(player,/if\(event\.currentTarget!==videoRef\.current\)return;/);
  for(const event of ['onLoadStart','onPlaying','onWaiting','onStalled','onSeeking','onError'])
    assert.match(player,new RegExp(event+'=\\{event=>videoEvent\\(event,'));
  assert.match(player,/onLoadedMetadata=\{event=>\{\s*if\(event\.currentTarget!==videoRef\.current\)return;/);
  assert.match(player,/onTimeUpdate=\{event=>\{\s*if\(event\.currentTarget!==videoRef\.current\)return;/);
  assert.match(player,/key=\{url\} src=\{native\?undefined:url\}/);
});
