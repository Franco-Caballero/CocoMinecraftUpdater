import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=name=>readFile(resolve(root,name),'utf8');
async function gate(){
  const js=ts.transpileModule(await source('src/media-session-refresh.ts'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return new module.exports.MediaSessionRefreshGate();
}

test('expired URL can be renewed only one at a time, with matching playback session',async()=>{
  const g=await gate();
  const first=g.begin(9);
  assert.ok(first);
  assert.equal(g.busy(),true);
  assert.equal(g.begin(9),null,'double-click must never open a second proxy');
  assert.equal(g.canUse(first,9),true);
  assert.equal(g.canUse(first,10),false,'new playback session invalidates the old result');
  assert.equal(g.finish(first),true);
  assert.equal(g.busy(),false);
  assert.equal(g.finish(first),false,'old result cannot unlock the current request');
  assert.equal(g.begin(-1),null);
  assert.equal(g.begin(Number.NaN),null);
});

test('closing while a fresh native token is pending fences completion and permits later retry',async()=>{
  const g=await gate();
  const ticket=g.begin(1);
  let complete;
  const pending=new Promise(resolve=>{complete=resolve;});
  g.cancel();
  assert.equal(g.canUse(ticket,1),false);
  assert.equal(g.begin(1),null,'original in-flight request remains owned until settle');
  complete('http://127.0.0.1/new-private-token');
  assert.equal(await pending,'http://127.0.0.1/new-private-token');
  assert.equal(g.canUse(ticket,1),false,'caller must revoke the stale URL');
  g.finish(ticket);
  const newTicket=g.begin(2);
  assert.equal(g.canUse(newTicket,2),true);
  assert.equal(g.canUse(ticket,2),false);
});

test('native media retry reopens via trusted episode ID and closes exact URLs, no arbitrary frontend origin',async()=>{
  const [app,player]=await Promise.all([source('src/main.tsx'),source('src/MediaPlayer.tsx')]);
  assert.match(app,/const reopenMedia=async\(\):Promise<boolean>/);
  assert.match(app,/mediaRefreshGate\.current\.begin\(mediaSessionEpoch\.current\)/);
  assert.match(app,/id:playing\.stream\.id,episodeId:playing\.stream\.episodeId/);
  assert.match(app,/if\(!mediaRefreshGate\.current\.canUse\(ticket,mediaSessionEpoch\.current\)\)/);
  assert.match(app,/invoke<boolean>\('close_media_stream',\{url:fresh\.url\}\)/);
  assert.match(app,/invoke<boolean>\('close_media_stream',\{url:previousUrl\}\)/);
  assert.match(app,/mediaSessionEpoch\.current\+\+;\s*mediaRefreshGate\.current\.cancel\(\)/);
  assert.match(app,/onReopen=\{reopenMedia\}/);
  assert.match(player,/if\(await onReopen\(\)\)return/);
  assert.match(player,/disabled=\{retrying\} aria-busy=\{retrying\}/);
  assert.doesNotMatch(app,/prepare_media_stream.*?url:fresh\.url/);
});
