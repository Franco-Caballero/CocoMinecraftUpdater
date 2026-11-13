import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=path=>readFile(resolve(root,path),'utf8');
async function getMeter(){
  const js=ts.transpileModule(await source('src/app-updater-progress.ts'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return new module.exports.AppUpdaterProgressMeter();
}

test('10,000 native chunks accumulate exact bytes but limit React updates and never announce installer completion',async()=>{
  const meter=await getMeter();
  const started=meter.consume({event:'Started',data:{contentLength:10_000_000}},0);
  assert.equal(started.percent,0);
  let rendered=1;
  for(let i=0;i<10_000;i++){
    const updated=meter.consume({event:'Progress',data:{chunkLength:1000}},i/10);
    if(updated){
      rendered++;
      assert.ok(updated.percent<=99,'byte counters do not prove verified installer completion');
      assert.match(updated.message,/Descargando/);
    }
  }
  assert.ok(rendered<=15,`10k updates should render <=15, got ${rendered}`);
  assert.equal(meter.snapshot().downloaded,10_000_000);
  assert.equal(meter.snapshot().percent,99);
  const complete=meter.consume({event:'Finished'},1001);
  assert.equal(complete.percent,100);
  assert.match(complete.message,/Transferencia terminada/);
  assert.doesNotMatch(complete.message,/Instalado|Actualización completada/);
  assert.equal(meter.consume({event:'Progress',data:{chunkLength:8}},1002),null,'stale after Finished');
});

test('unknown size remains indeterminate; malformed and huge totals never invent transfer rates or ETA',async()=>{
  const meter=await getMeter();
  assert.equal(meter.consume({event:'Started',data:{contentLength:-1}},100).total,0);
  assert.equal(meter.consume({event:'Started',data:{contentLength:100}},101),null,'repeated start cannot reset bytes');
  for(const invalid of [Number.NaN,-1,0,1.25,Infinity,2**55])
    assert.equal(meter.consume({event:'Progress',data:{chunkLength:invalid}},200),null);
  const progress=meter.consume({event:'Progress',data:{chunkLength:1024}},450);
  assert.equal(progress.total,0);
  assert.equal(progress.percent,0);
  assert.equal(progress.downloaded,1024);
  assert.equal(meter.consume({event:'Finished'},900).percent,100);
});

test('version update UI rechecks games after download, fences stale events, and never bypasses signed updater',async()=>{
  const ui=await source('src/main.tsx');
  const section=ui.slice(ui.indexOf('const applyAppUpdate=async()=>{'),ui.indexOf('// The updater performs HTTPS discovery'));
  assert.match(section,/const attempt=\+\+updateAttempt\.current/);
  assert.match(section,/new AppUpdaterProgressMeter\(\)/);
  assert.match(section,/attempt!==updateAttempt\.current\|\|!updateRunning\.current/);
  assert.match(section,/transfer\.consume\(event,performance\.now\(\)\)/);
  assert.match(section,/await update\.download\(/);
  assert.match(section,/await invoke<string\[\]>\('list_running_games'\)/);
  assert.match(section,/await invoke<ActiveGameProcessReport>\('get_active_game_processes'\)/);
  assert.match(section,/safeToUpdate!==true/);
  assert.match(section,/await update\.install\(\{restartAfterInstall:true\}\)/);
  assert.doesNotMatch(section,/TAURI_SIGNING_PRIVATE_KEY|powershell\.exe|defender.*disable/i);
});
