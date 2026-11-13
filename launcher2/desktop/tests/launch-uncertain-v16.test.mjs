import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('native game launch response failure is reconciled read-only before another launch can start',async()=>{
  const source=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const start=source.indexOf('const launchNative=async(entry:Experience)=>{');
  const end=source.indexOf('const installNative=async(',start);
  assert.ok(start>0&&end>start);
  const launch=source.slice(start,end);
  assert.match(launch,/get_active_game_processes/);
  assert.match(launch,/retainObservedGameIds/);
  assert.match(launch,/reconcileLaunchObservation/);
  assert.match(launch,/if\(observed==='running'\)/);
  assert.doesNotMatch(launch,/setOperationMessage\(`Error: \$\{String\(error\)\}`\)/);
  assert.match(launch,/if\(started\.state==='running'\)rememberActivity\('played'/);
  assert.match(launch,/setOperationMessage\(started\.state==='running'\?'Juego iniciado'/);
  assert.match(launch,/nativeOperationGate\.current\.finish\(ticket\)/);
});

test('only exact game ID proves active, no unrelated game or error string proves launch',async()=>{
  const tsCode=await readFile(resolve(root,'src/launch-observation.ts'),'utf8');
  const js=ts.transpileModule(tsCode,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const m={exports:{}};vm.runInNewContext(js,{module:m,exports:m.exports});
  const {reconcileLaunchObservation}=m.exports;
  assert.equal(reconcileLaunchObservation({status:'active',safeToUpdate:false,gameIds:['other']},'my-game'),'unknown');
  assert.equal(reconcileLaunchObservation({status:'active',safeToUpdate:false,gameIds:['my-game']},'my-game'),'running');
  assert.equal(reconcileLaunchObservation({status:'unknown',safeToUpdate:false,gameIds:[]},'my-game'),'unknown');
  assert.equal(reconcileLaunchObservation(null,'my-game'),'unknown');
  assert.equal(reconcileLaunchObservation({status:'none',safeToUpdate:true,gameIds:[]},'my-game'),'absent');
});
