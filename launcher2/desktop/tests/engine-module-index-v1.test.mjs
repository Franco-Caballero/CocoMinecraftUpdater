import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,stat} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

const read=path=>readFile(fileURLToPath(new URL(`../${path}`,import.meta.url)),'utf8');

test('the video engine starts from its module index instead of opening all 360 modules',async()=>{
  const player=await read('src-tauri/src/services/native_player.rs');
  assert.doesNotMatch(player,/"--no-plugins-cache"/,'without the index an antivirus scans every module on each cold start (33 s seen)');
  assert.match(player,/"--reset-plugins-cache"/,'a PC where the shipped index does not fit rebuilds its own');
  assert.match(player,/SLOW_START/);
  assert.match(player,/rebuild-plugins-cache/);
  const build=await read('scripts/Build-CocoLauncher2.ps1');
  assert.match(build,/\$resourceMap\['resources\/vlc-plugins\.dat'\]='player\/plugins\/plugins\.dat'/);
  const index=await stat(fileURLToPath(new URL('../src-tauri/resources/vlc-plugins.dat',import.meta.url)));
  assert.ok(index.size>100_000,'the index built on the installed engine ships with Coco');
  const manifest=JSON.parse(await read('src-tauri/resources/vlc-runtime-manifest.json'));
  assert.ok(!manifest.files.some(file=>file.path.endsWith('plugins.dat')),'the index is rebuilt in place, so it is not a verified engine file');
});

test('a film closed before its first picture leaves a line in the log',async()=>{
  const playback=await read('src/native-playback.ts');
  assert.match(playback,/se cerró sin imagen tras/);
});

test('the engine is warmed after Coco opens and excluded from Defender with its repair copy',async()=>{
  const lib=await read('src-tauri/src/lib.rs');
  assert.match(lib,/native_player::prewarm_after_start\(app\.handle\(\)\.clone\(\)\)/);
  const defender=await read('src-tauri/src/services/defender.rs');
  assert.match(defender,/join\("player-runtime"\)/);
  assert.match(defender,/exe\.parent\(\)\.map\(\|dir\|dir\.join\("player"\)\)/);
});
