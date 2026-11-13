import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function makeGate(){
  const source=await readFile(resolve(root,'src/media-preparation-gate.ts'),'utf8');
  const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return new module.exports.MediaPreparationGate();
}
test('double-click during an outstanding native stream cannot allocate two proxies',async()=>{
  const gate=await makeGate();
  const first=gate.begin('movie');
  assert.ok(first&&gate.busy());
  assert.equal(gate.begin('movie'),null);
  assert.equal(gate.begin('other'),null);
  assert.equal(gate.canDisplay(first),true);
  assert.equal(gate.finish(first),true);
  assert.equal(gate.busy(),false);
});
test('changing media while native Promise is pending invalidates stale token until it settles',async()=>{
  const gate=await makeGate();
  const ticket=gate.begin('movie-a');
  let resolveDeferred;
  const unresolved=new Promise(resolve=>{resolveDeferred=resolve;});
  gate.cancelIfChanged('movie-b');
  assert.equal(gate.canDisplay(ticket),false);
  assert.equal(gate.begin('movie-b'),null,'native request is still in flight');
  resolveDeferred('old-token-url');
  assert.equal(await unresolved,'old-token-url');
  assert.equal(gate.canDisplay(ticket),false,'old token must be discarded by caller');
  assert.equal(gate.finish(ticket),true);
  const second=gate.begin('movie-b');
  assert.ok(second&&second.id>ticket.id);
  assert.equal(gate.finish(ticket),false,'late first completion cannot unlock second');
  assert.equal(gate.canDisplay(second),true);
  gate.cancel();assert.equal(gate.canDisplay(second),false);
  assert.equal(gate.finish(second),true);
});
test('frontend closes exact stale native URL without opening a player or leaking diagnostic paths',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.match(ui,/const stream=await invoke<PreparedMediaStream>\('prepare_media_stream'/);
  assert.match(ui,/if\(!mediaPrepareGate\.current\.canDisplay\(ticket\)\)\{/);
  assert.match(ui,/invoke<boolean>\('close_media_stream',\{url:stream\.url\}\)/);
  assert.match(ui,/mediaPrepareGate\.current\.cancelIfChanged\(selected\?\.id\)/);
  assert.match(ui,/mediaPrepareGate\.current\.finish\(ticket\)/);
  assert.doesNotMatch(ui,/pendingMediaPrepare|mediaPrepareTicket/);
});
