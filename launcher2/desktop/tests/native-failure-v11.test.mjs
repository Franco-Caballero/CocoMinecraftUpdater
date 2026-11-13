import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=name=>readFile(join(root,name),'utf8');
async function helper(path){
  const js=ts.transpileModule(await source(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,Error,Promise});
  return module.exports;
}

test('native Windows failures show truthful actionable causes and never prescribe blanket antivirus exclusions',async()=>{
  const {nativeFailureGuidance:guide}=await helper('src/native-failure-guidance.ts');
  const cases=[
    ['os error 112: Disk full','space','espacio'],
    ['ERROR_SHARING_VIOLATION (os error 32)','locked','ocupado'],
    ['Access denied (os error 5)','permissions','Windows denegó'],
    ['archive sha256 checksum mismatch','integrity','integridad'],
    ['HTTP 503 temporary gateway failure','network','conexión'],
    ['journal rollback recovery-required','recovery','transacción'],
    ['cancelled by player','cancelled','cancelación'],
    ['unknown low-level IO','unknown','Comprueba'],
  ];
  for(const [input,kind,expected] of cases){
    const result=guide(input,'install');
    assert.equal(result.kind,kind,input);
    assert.ok(result.summary.includes(expected),input);
    assert.doesNotMatch(result.summary,/desactiva (?:tu |el )?antivirus|excluye toda la carpeta|garantiz/i);
  }
  assert.match(guide('Permission denied','upgrade').summary,/La actualización no se completó/);
  assert.match(guide('ERROR_SHARING_VIOLATION','repair').summary,/La reparación no se completó/);
  assert.match(guide('os error 112','recover').summary,/La recuperación no se completó/);
  assert.match(guide('os error 112','prepare').summary,/La preparación no se completó/);
  const scrubbed=guide('https://example.test/auth?token=secret authorization=topsecret\npath','upgrade');
  assert.doesNotMatch(scrubbed.detail,/example\.test|topsecret|secret|\n/);
  assert.ok(scrubbed.detail.includes('[dirección remota omitida]'));
});

test('failure snapshot is read-only and preserves independent successful diagnostics across two Unicode synthetic profiles',async()=>{
  const {inspectAfterNativeFailure}=await helper('src/native-failure-reconciliation.ts');
  const base=await mkdtemp(join(tmpdir(),'coco2-failure-v11-'));
  try{
    for(const name of ['Usuario Éxito con espacios','ユーザー segundo perfil']){
      const profile=join(base,name);
      await mkdir(profile,{recursive:true});
      const contents=JSON.stringify([{id:'synthetic-game',kind:'upgrade',status:'recovery-required'}]);
      await writeFile(join(profile,'journal.json'),contents);
      const pending=()=>readFile(join(profile,'journal.json'),'utf8').then(JSON.parse);
      const instance=()=>Promise.reject(Error('ERROR_ACCESS_DENIED on optional drive'));
      const repair=()=>Promise.resolve({id:'synthetic-game',pending:true});
      const snapshot=await inspectAfterNativeFailure(pending,instance,repair);
      assert.equal(snapshot.pending.length,1);
      assert.equal(snapshot.instances,null);
      assert.equal(snapshot.repair.pending,true);
      assert.equal(snapshot.unavailable.join(','),'instances');
      assert.equal(await readFile(join(profile,'journal.json'),'utf8'),contents,'no mutation of a pending transaction');
    }
  }finally{await rm(base,{recursive:true,force:true});}
});

test('synchronous and async inspection failures never prevent healthy journal state from being reported',async()=>{
  const {inspectAfterNativeFailure}=await helper('src/native-failure-reconciliation.ts');
  const result=await inspectAfterNativeFailure(
    ()=>{throw Error('corrupt journal encoding');},
    ()=>Promise.resolve([{id:'present'}]),
    ()=>{throw Error('locked');},
  );
  assert.equal(result.pending,null,'invalid callback result must fail separately');
  assert.equal(result.instances[0].id,'present');
  assert.equal(result.repair,null);
  assert.equal(result.unavailable.sort().join(','),'journals,repair');
});

test('late failure inspection cannot revive a stale journal after a new native operation',async()=>{
  const {NativeOperationGate}=await helper('src/native-operation-gate.ts');
  const {inspectAfterNativeFailure}=await helper('src/native-failure-reconciliation.ts');
  const gate=new NativeOperationGate();
  const first=gate.begin('game','upgrade');
  let release;
  const pending=new Promise(resolve=>{release=resolve;});
  const oldRead=inspectAfterNativeFailure(()=>pending,async()=>[],undefined);
  gate.finish(first);
  const second=gate.begin('game','recover-upgrade');gate.finish(second);
  assert.equal(gate.isLatest(first),false);
  assert.equal(gate.isLatest(second),true);
  release([{id:'old',status:'recovery-required'}]);
  const snapshot=await oldRead;
  const applied=gate.isLatest(first)?snapshot.pending:[];
  assert.equal(applied.length,0);
});

test('frontend immediately reconciles native write failures without replay or UI blocking',async()=>{
  const ui=await source('src/main.tsx');
  const section=ui.slice(ui.indexOf('// Native commands may reject AFTER'),ui.indexOf('const launchNative=async'));
  assert.match(section,/inspectAfterNativeFailure/);
  assert.match(section,/recover_pending_standalone_operations/);
  assert.match(section,/get_local_instances/);
  assert.match(section,/get_standalone_repair_recovery_status/);
  assert.match(section,/nativeOperationGate\.current\.isLatest\(ticket\)/);
  assert.doesNotMatch(section,/invoke.*(?:install_standalone|commit_standalone_repair|recover_standalone_repair|upgrade_standalone|recover_standalone_upgrade)/);
  for(const fn of ['installNative','recoverRepair','performUpgrade','recoverUpgrade']){
    const start=ui.indexOf(`const ${fn}=async(entry:Experience)=>{`);
    const next=ui.indexOf('\n  };',start+7);
    assert.ok(start>=0,fn);
    assert.ok(next>start,fn+' closure');
    assert.match(ui.slice(start,next+6),/explainFailedNativeWrite\(error,/i,fn);
  }
  assert.match(ui,/Ver detalle del fallo/);
});
