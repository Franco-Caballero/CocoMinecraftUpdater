import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

const source=path=>fileURLToPath(new URL(`../${path}`,import.meta.url));
const read=path=>readFile(source(path),'utf8');

test('updates install silently behind Coco\'s own «Actualizando Coco» window',async()=>{
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  assert.equal(config.plugins.updater.windows.installMode,'quiet');
  const main=await read('src/main.tsx');
  const prepare=main.indexOf("invoke<boolean>('prepare_update_curtain'");
  const install=main.indexOf('await update.install(');
  assert.ok(prepare>0&&prepare<install,'the stand-in window is up before the installer starts');
  assert.match(main,/invoke\('cancel_update_curtain'\)/);
  assert.match(main,/invoke<\{version:string\}\|null>\('take_update_curtain'\)/);
  assert.match(main,/invoke\('update_curtain_ready'\)/);
  const lib=await read('src-tauri/src/lib.rs');
  assert.ok(lib.indexOf('is_curtain_launch()')<lib.indexOf('start_or_handoff()'),
    'the stand-in never takes part in single-instance handoff');
  assert.equal(lib.match(/generate_context!\(\)/g)?.length,1,'one embedded copy of the frontend');
});

test('the installer keeps an identical video engine instead of rewriting it',async()=>{
  const manifest=JSON.parse(await read('src-tauri/resources/vlc-runtime-manifest.json'));
  const nsis=await read('src-tauri/windows/nsis/installer-safe.nsi');
  const expected=`${manifest.version}-${manifest.archiveSha256.slice(0,8)}`;
  assert.match(nsis,new RegExp(`!define COCO_PLAYER_RUNTIME "${expected.replace(/\./g,'\\.')}"`),
    'bump COCO_PLAYER_RUNTIME together with the VLC runtime');
  // Every resource still goes through File; only player files that exist are skipped.
  assert.match(nsis,/\$\{AndIf\} \$CocoResourcePrefix == "player\\"\r?\n\s*\$\{AndIf\} \$\{FileExists\} "\$INSTDIR\\\\\{\{this\.\[1\]\}\}"/);
  assert.match(nsis,/\$\{Else\}\r?\n\s*File \/a "\/oname=\{\{this\.\[1\]\}\}" "\{\{no-escape @key\}\}"/);
  assert.match(nsis,/Delete "\$INSTDIR\\player\\\.coco-runtime-\*"\r?\n\s*\$\{EndIf\}/,'a different runtime clears the old mark first');
  const player=await read('src-tauri/src/services/native_player.rs');
  assert.match(player,/verify\(directory\)\.inspect_err\(\|_\|forget_installed_runtime\(directory\)\)/,
    'a damaged engine is rewritten by the next update');
});
