import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const code=ts.transpileModule(await readFile(resolve(root,'src/media-session-refresh.ts'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
}).outputText;
const module={exports:{}};
vm.runInNewContext(code,{module,exports:module.exports});
const Gate=module.exports.MediaSessionRefreshGate;

test('closing video while retry is waiting on stalled native stream does not block new video session',()=>{
  const gate=new Gate();
  const old=gate.begin(3);
  assert.ok(old);
  gate.cancel();
  gate.supersedeSession(4);
  const current=gate.begin(4);
  assert.ok(current,'new video must not wait forever for the old dead native promise');
  assert.equal(gate.canUse(old,4),false);
  assert.equal(gate.finish(old),false,'stale finished request cannot unlock fresh token');
  assert.equal(gate.canUse(current,4),true);
  assert.equal(gate.finish(current),true);
});

test('same-session retries stay single-flight; supersede never releases a live current-session request',()=>{
  const gate=new Gate();
  const ticket=gate.begin(5);
  assert.ok(ticket);
  assert.equal(gate.supersedeSession(5),false);
  assert.equal(gate.begin(5),null);
  assert.equal(gate.finish(ticket),true);
  assert.equal(gate.begin(5)!==null,true);
});

test('React fences all previous media sessions before opening a fresh player and closing one',async()=>{
  const app=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.match(app,/mediaSessionEpoch\.current\+\+;\s*mediaRefreshGate\.current\.cancel\(\);\s*mediaRefreshGate\.current\.supersedeSession\(mediaSessionEpoch\.current\)/);
  assert.match(app,/if\(!mediaRefreshGate\.current\.canUse\(ticket,mediaSessionEpoch\.current\)\)/);
  assert.match(app,/close_media_stream',\{url:fresh\.url\}/);
});
