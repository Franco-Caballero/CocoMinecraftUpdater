import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function helper(){
  const source=await readFile(resolve(root,'src/native-operation-settlement.ts'),'utf8');
  const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}

test('post-commit refresh failures are isolated, continue recovery and never throw a false install failure',async()=>{
  const {refreshAfterConfirmedWrite,confirmedOperationMessage}=await helper();
  const events=[];
  const result=await refreshAfterConfirmedWrite([
    async()=>{events.push('instances');throw new Error('synthetic unavailable external disk');},
    async()=>{events.push('install-plan');return {status:'already-installed'};},
    async()=>{events.push('journal');throw Error('synthetic journal locked');},
    async()=>{events.push('repair-plan');},
  ]);
  assert.deepEqual([...events],['instances','install-plan','journal','repair-plan']);
  assert.equal(result.failed,2);
  assert.equal(result.completed,2);
  const message=confirmedOperationMessage('Instalación completada.',result.failed);
  assert.match(message,/Instalación completada.*cambios ya están guardados/i);
  assert.doesNotMatch(message,/Error:|La instalación falló|synthetic|Error.*no se pudo instalar/);
});

test('a successful refresh leaves native result untouched and sequentially prevents stale plan overwrite',async()=>{
  const {refreshAfterConfirmedWrite,confirmedOperationMessage}=await helper();
  let catalogueResolved=false;
  const result=await refreshAfterConfirmedWrite([
    async()=>{await Promise.resolve();catalogueResolved=true;},
    async()=>assert.equal(catalogueResolved,true,'catalog must finish before the newer plan is written'),
  ]);
  assert.equal(result.failed,0);
  assert.equal(confirmedOperationMessage('Juego actualizado',result.failed),'Juego actualizado');
});

test('install, upgrade, repair and both recovery paths separate native receipts from fallible read-only refreshes',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.match(ui,/const result=await invoke<InstallOutcome>\('install_standalone'/);
  assert.match(ui,/if\(result\.status==='installed'\)\{[\s\S]*?refreshAfterConfirmedWrite\(/);
  assert.match(ui,/if\(outcome\.status==='upgraded'\|\|outcome\.status==='already-current'\)\{[\s\S]*?refreshAfterConfirmedWrite\(/);
  for(const action of ['recover_standalone_repair','recover_standalone_upgrade']){
    const at=ui.indexOf(`'${action}'`);
    const tail=ui.slice(at,at+2200);
    assert.ok(at>=0,action);
    assert.match(tail,/refreshAfterConfirmedWrite\(/,`${action} recovery does not become a false failure when its read-only plan is unavailable`);
    assert.match(tail,/confirmedOperationMessage\(outcome\.message,refresh\.failed\)/);
  }
  assert.match(ui,/confirmedOperationMessage\(outcome\.message,refresh\.failed\)/);
});
