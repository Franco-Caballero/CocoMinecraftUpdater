// No real ZIPs, Rust commands, dialogs or user files: these tests execute
// HostStudio's pure TypeScript helpers with controlled promises and events.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=await readFile(resolve(root,'src/HostStudio.tsx'),'utf8');
const ast=ts.createSourceFile('HostStudio.tsx',source,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const names=['createDraftWithPreview','createHostStudioProgressSampler','createHostStudioFlowGate'];
const functions=ast.statements.filter(node=>ts.isFunctionDeclaration(node)&&names.includes(node.name?.text));
assert.equal(functions.length,names.length,'tests must run actual production helpers');
const transpiled=ts.transpileModule(
  functions.map(node=>node.getText(ast).replace(/^export\s+/,'')).join('\n'),
  {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None},reportDiagnostics:true},
);
assert.deepEqual(transpiled.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error)??[],[]);
const {createDraftWithPreview,createHostStudioProgressSampler,createHostStudioFlowGate}=
  runInNewContext(`${transpiled.outputText}\n({${names.join(',')}})`,{},{timeout:1000});

const deferred=()=>{
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};
const progress=(phase,processedBytes,totalBytes,percent,id='game')=>
  ({id,phase,processedBytes,totalBytes,percent});

test('successful create saves one click by immediately invoking read-only preview',async()=>{
  const gate=createHostStudioFlowGate();
  const ticket=gate.begin();
  const actions=[];
  const result=await createDraftWithPreview(
    async()=>{actions.push('draft-command');return {id:'game',draftPath:'memory-only'};},
    async(id)=>{actions.push(`preview-command:${id}`);return {newVersion:'1.0.0'};},
    ()=>gate.owns(ticket),
    draft=>actions.push(`draft-ready:${draft.id}`),
    ()=>actions.push('reviewing'),
    preview=>actions.push(`review-ready:${preview.newVersion}`),
    ()=>actions.push('preview-failed')
  );
  gate.finish(ticket);
  assert.equal(result,undefined);
  assert.deepEqual(actions,[
    'draft-command','draft-ready:game','reviewing','preview-command:game','review-ready:1.0.0',
  ]);
  assert.match(source,/await createDraftWithPreview\(/);
  assert.match(source,/draftId=>invoke<PublishPreview>\('preview_standalone_publish'/);
  assert.match(source,/Revisando automáticamente…/);
  assert.match(source,/ref=\{previewConsentRef\}/);
  assert.match(source,/previewConsentRef\.current\?\.focus\(\)/);
});

test('preview failure keeps the already-created draft and enables independent retry',async()=>{
  const gate=createHostStudioFlowGate();
  const ticket=gate.begin();
  const callbacks=[];
  const issue=new Error('Preview became stale');
  await createDraftWithPreview(
    async()=>{callbacks.push('draft-made');return {id:'game'};},
    async()=>{callbacks.push('preview-attempt');throw issue;},
    ()=>gate.owns(ticket),
    draft=>callbacks.push(`keep:${draft.id}`),
    ()=>callbacks.push('checking'),
    ()=>callbacks.push('unexpected-success'),
    error=>callbacks.push(error===issue?'retry-preview':'unexpected-error')
  );
  gate.finish(ticket);
  assert.deepEqual(callbacks,['draft-made','keep:game','checking','preview-attempt','retry-preview']);
  assert.match(source,/Reintentar revisión/);
  assert.match(source,/Puedes reintentar la revisión sin crearlo de nuevo/);
  assert.match(source,/const previewPublish=async\(\)=>/);
});

test('failed draft never starts preview or falsely reports a prepared package',async()=>{
  let previewCalls=0,draftCalls=0;
  const issue=new Error('Draft already exists');
  await assert.rejects(createDraftWithPreview(
    async()=>{draftCalls++;throw issue;},
    async()=>{previewCalls++;return {};},
    ()=>true,
    ()=>assert.fail('must not announce draft ready'),
    ()=>assert.fail('must not announce reviewing'),
    ()=>assert.fail('must not announce preview ready'),
    ()=>assert.fail('must not call preview error for draft failure')
  ),error=>error===issue);
  assert.equal(draftCalls,1);
  assert.equal(previewCalls,0);
});

test('close while draft pending prevents subsequent native preview',async()=>{
  const gate=createHostStudioFlowGate();
  const ticket=gate.begin();
  const pendingDraft=deferred();
  const results=[];
  const task=createDraftWithPreview(
    ()=>pendingDraft.promise,
    async()=>{results.push('unexpected-preview');return {};},
    ()=>gate.owns(ticket),
    ()=>results.push('unexpected-draft'),
    ()=>results.push('unexpected-reviewing'),
    ()=>results.push('unexpected-review'),
    ()=>results.push('unexpected-error')
  );
  assert.equal(gate.request('close'),false);
  pendingDraft.resolve({id:'old'});
  await task;
  assert.deepEqual(results,[]);
  assert.equal(gate.finish(ticket),'close');
});

test('switch game while preview pending rejects old review and never auto-confirms rights',async()=>{
  const gate=createHostStudioFlowGate();
  const ticket=gate.begin();
  const pendingPreview=deferred();
  const previewStarted=deferred();
  const calls=[];
  const task=createDraftWithPreview(
    async()=>({id:'old'}),
    ()=>pendingPreview.promise,
    ()=>gate.owns(ticket),
    draft=>calls.push(`draft:${draft.id}`),
    ()=>{calls.push('reviewing');previewStarted.resolve();},
    ()=>calls.push('unexpected-review'),
    ()=>calls.push('unexpected-error')
  );
  // Wait for the actual preview transition, not a guessed microtask tick.
  await previewStarted.promise;
  assert.equal(gate.request('new'),false);
  pendingPreview.resolve({id:'old',newVersion:'2'});
  await task;
  assert.deepEqual(calls,['draft:old','reviewing']);
  assert.equal(gate.finish(ticket),'new');
  assert.match(source,/setRightsReviewed\(false\)/);
  assert.match(source,/disabled=\{busy\|\|!rightsReviewed\}/);
});

test('progress renders are bounded under 10,000 high-frequency native chunk events',()=>{
  const sampler=createHostStudioProgressSampler(125);
  const emitted=[];
  const events=10_000;
  for(let i=0;i<events;i++){
    const event=progress('copying',i*1024,events*1024,i*100/events);
    if(sampler.accept(event,i/10))emitted.push(event);
  }
  // About one sampled UI state every 125 ms; native emits 10,000.
  assert.ok(emitted.length>=7&&emitted.length<=10,`unexpected render budget: ${emitted.length}`);
  assert.equal(emitted[0].processedBytes,0);
  assert.ok(emitted.every(value=>value.totalBytes===events*1024));
  assert.equal(sampler.accept(progress('verifying',0,events*1024,0),1000),true);
  assert.equal(sampler.accept(progress('sealing',events*1024,events*1024,100),1000),true);
  assert.equal(sampler.accept(progress('complete',events*1024,events*1024,100),1000),true);
  assert.match(source,/progressSampler\.current\.accept\(event\.payload,Date\.now\(\)\)/);
});

test('real progress phase changes and terminal errors are never hidden by sampling',()=>{
  const sampler=createHostStudioProgressSampler();
  assert.equal(sampler.accept(progress('preflight',0,0,null),0),true);
  assert.equal(sampler.accept(progress('copying',0,100,0),1),true);
  assert.equal(sampler.accept(progress('copying',1,100,1),2),false);
  assert.equal(sampler.accept(progress('verifying',0,100,0),3),true);
  assert.equal(sampler.accept(progress('error',0,100,null),4),true);
  assert.equal(sampler.accept(progress('complete',100,100,100),5),true);
  assert.equal(sampler.accept(progress('complete',100,100,100),6),false,
    'duplicate completion should not trigger another React update');
  sampler.reset();
  assert.equal(sampler.accept(progress('copying',0,100,0),5),true);
  assert.equal(sampler.accept(progress('copying',1,100,1),Number.NaN),false);
  assert.equal(sampler.accept(progress('copying',-1,100,1),6),false);
  assert.equal(sampler.accept(progress('copying',50,100,50),131),true);
  assert.equal(sampler.accept(progress('copying',2,100,2),300),false,
    'late out-of-order chunk must never make the visible progress go backward');
  assert.equal(sampler.accept(progress('copying',80,100,Number.NaN),310),false);
});

test('no false completion, ZIP rewrite or extra native command was introduced',()=>{
  assert.match(source,/prepareTicket\.current=ticket;progressSampler\.current\.reset\(\)/);
  assert.match(source,/event\.payload\.id===result\?\.id/);
  assert.match(source,/if\(flowGate\.current\.owns\(ticket\)\)setPublishArtifact\(artifact\)/);
  assert.match(source,/await invoke<PortableExport>\('export_portable_standalone_package'/);
  assert.match(source,/filters:\[\{name:'Paquete Coco 2 \(\.coco2pack\)',extensions:\['coco2pack'\]\}\]/);
  assert.match(source,/if\(!destination\)/);
  assert.match(source,/No se creó una copia nueva/);
  assert.doesNotMatch(source,/setPublishProgress\(\{[^}]*percent:\s*100/i);
  assert.doesNotMatch(source,/invoke\('publish_|window\.open\(|shell\.execute\(/i);
});
