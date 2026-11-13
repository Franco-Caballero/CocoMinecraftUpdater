import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=name=>readFile(resolve(root,name),'utf8');
async function load(name){
  const module={exports:{}};
  const js=ts.transpileModule(await source(name),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}

test('phase-specific bars cannot claim an installation is finished after only downloading or extracting',async()=>{
  const {nativeStageView:view}=await load('src/native-stage-ui.ts');
  for(const p of ['downloading','repair-downloading','upgrade-downloading']){
    const step=view(p);
    assert.equal(step.stageIndex,1);
    assert.equal(step.stageCount,4);
    assert.equal(step.isComplete,false);
    assert.equal(step.steps.filter(x=>x.state==='done').length,0);
    assert.equal(step.steps[0].label,'Descargar');
  }
  for(const p of ['extracting','repair-extracting','upgrade-extracting']){
    const step=view(p);
    assert.equal(step.stageIndex,2);
    assert.equal(step.steps.filter(x=>x.state==='done').length,1);
    assert.equal(step.isComplete,false);
  }
  assert.equal(view('verifying').steps.filter(x=>x.state==='done').length,2);
  assert.equal(view('upgrade-committing').steps.filter(x=>x.state==='done').length,3);
  assert.equal(view('completed').isComplete,true);
  assert.equal(view('repair-prepared').isComplete,false,'prepared zip is not a repaired game');
  assert.match(view('repair-prepared').currentLabel,/sin aplicar cambios/);
  assert.equal(view('failed'),null);
  assert.equal(view('cancelled'),null);
  assert.equal(view(''),null);
});

test('rollback and crash-recovery show a separate restoration stage rather than completed installation',async()=>{
  const {nativeStageView:view}=await load('src/native-stage-ui.ts');
  for(const phase of ['upgrade-rolling-back','repair-recovering','upgrade-recovery']){
    const step=view(phase);
    assert.equal(step.steps.length,1);
    assert.equal(step.steps[0].id,'restaurar');
    assert.equal(step.isComplete,false);
  }
  for(const phase of ['upgrade-recovered','repair-recovered']){
    assert.equal(view(phase).isComplete,true);
    assert.equal(view(phase).steps[0].state,'done');
  }
});

test('post-failure read-only plans preserve independently successful results and cannot mutate journals',async()=>{
  const {inspectAfterNativeFailure:inspect}=await load('src/native-failure-reconciliation.ts');
  const readonly=[];
  const snapshot=await inspect(
    ()=>Promise.resolve([{id:'u-Ã©',kind:'upgrade',status:'recovery-required'}]),
    ()=>Promise.resolve([{id:'u-Ã©',state:'folder-present'}]),
    ()=>Promise.reject(Error('optional repair status unavailable')),
    ()=>Promise.resolve({id:'u-Ã©',status:'recovery-required',toVersion:'1.1.0'}),
  );
  assert.equal(snapshot.pending[0].status,'recovery-required');
  assert.equal(snapshot.instances[0].state,'folder-present');
  assert.equal(snapshot.repair,null);
  assert.equal(snapshot.plan.toVersion,'1.1.0');
  assert.equal(snapshot.unavailable.join(','),'repair');
  assert.deepEqual(readonly,[]);
  const failedPlan=await inspect(()=>Promise.resolve([]),()=>Promise.resolve([]),undefined,
    ()=>{throw Error('source offline');});
  assert.equal(failedPlan.plan,null);
  assert.equal(failedPlan.unavailable.join(','),'plan');
});

test('catalog revision fencing blocks a stale installation recovery from reviving a prior package',async()=>{
  const {CatalogRefreshGate}=await load('src/catalog-refresh-gate.ts');
  const {NativeOperationGate}=await load('src/native-operation-gate.ts');
  const catalog=new CatalogRefreshGate(),writer=new NativeOperationGate();
  const ticket=writer.begin('old-game','install');
  const before=catalog.snapshot();
  catalog.begin(); // a new signed / manually accepted catalog wins
  writer.finish(ticket);
  assert.equal(writer.isLatest(ticket),true);
  assert.equal(catalog.current(before),false,'old read must not overwrite newly trusted catalog state');
  const latest=catalog.snapshot();
  assert.equal(catalog.current(latest),true);
});

test('UI displays independent phases, concrete Windows actions and safe read-only reconciliation',async()=>{
  const [ui,css]=await Promise.all([source('src/main.tsx'),source('src/experience-v2.css')]);
  assert.match(ui,/function NativeStageRail/);
  assert.match(ui,/NativeStageRail phase=\{installProgress\?\.phase\}/);
  assert.doesNotMatch(ui,/Instalando \$\{/,'percent belongs to one phase, so the button never claims an overall figure');
  assert.match(ui,/catalogRefreshGate\.current\.snapshot\(\)/);
  assert.match(ui,/catalogRefreshGate\.current\.current\(catalogRevision\)/);
  assert.match(ui,/plan_standalone_install/);
  assert.match(ui,/plan_standalone_upgrade/);
  assert.match(ui,/nativeFailure\.kind==='permissions'/);
  assert.match(ui,/Comprobar ruta del juego/);
  assert.match(ui,/Abrir Seguridad de Windows|Seguridad de Windows/);
  assert.match(ui,/Carpeta registrada y verificada \(no necesariamente el archivo bloqueado\)/);
  assert.match(css,/coco-native-failure-card/);
  assert.match(css,/coco-native-stage-list/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});
