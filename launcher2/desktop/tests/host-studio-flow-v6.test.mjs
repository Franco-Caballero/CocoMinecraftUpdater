// Executable race tests for the actual Host Studio TS helpers plus UI
// contracts. Deliberately never imports Tauri, opens a dialog or writes data.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=await readFile(resolve(root,'src/HostStudio.tsx'),'utf8');
const ast=ts.createSourceFile('HostStudio.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const names=[
  'createHostStudioFlowGate','hostStudioOperationError','suggestedFutureZipName',
  'suggestedPortableFileName','isPortableSavePath','portableExportError',
];
const declarations=ast.statements.filter(node=>
  ts.isFunctionDeclaration(node)&&names.includes(node.name?.text));
assert.equal(declarations.length,names.length,'tests must run every current helper, not duplicate it');
const emitted=ts.transpileModule(
  declarations.map(fn=>fn.getText(ast).replace(/^export\s+/,'')).join('\n'),
  {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None},reportDiagnostics:true},
);
assert.equal(emitted.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);
const helpers=runInNewContext(`${emitted.outputText}\n({${names.join(',')}})`,{},{timeout:1000});
const {createHostStudioFlowGate,hostStudioOperationError,suggestedFutureZipName,
  suggestedPortableFileName,isPortableSavePath,portableExportError}=helpers;
const deferred=()=>{
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};

test('only one native or picker operation may run, even before React busy rerenders',()=>{
  const gate=createHostStudioFlowGate();
  const ticket=gate.begin();
  assert.equal(typeof ticket,'number');
  assert.equal(gate.isActive(),true);
  assert.equal(gate.begin(),null,'synchronous reentrance must be refused');
  assert.equal(gate.owns(ticket),true);
  assert.equal(gate.finish(ticket+1),null,'other operation cannot finish current work');
  assert.equal(gate.owns(ticket),true);
  assert.equal(gate.finish(ticket),null);
  assert.equal(gate.isActive(),false);
  const next=gate.begin();
  assert.notEqual(next,ticket);
  assert.equal(gate.owns(ticket),false);
  gate.finish(next);
});

test('request close while native export is in flight fences its result and defers close',async()=>{
  const gate=createHostStudioFlowGate();
  const native=deferred();
  const seen=[];
  const ticket=gate.begin();
  const operation=native.promise.then(result=>{
    if(gate.owns(ticket))seen.push(result);
  }).finally(()=>seen.push(gate.finish(ticket)));
  assert.equal(gate.request('close'),false);
  assert.equal(gate.owns(ticket),false);
  assert.equal(gate.begin(),null,'a second export must not overlap first native writer');
  native.resolve('C:\\Downloads\\new.coco2pack');
  await operation;
  assert.equal(seen.length,1);
  assert.equal(seen[0],'close');
  assert.equal(gate.isActive(),false);
});

test('change game during inspection invalidates old result; new game may begin after settle',async()=>{
  const gate=createHostStudioFlowGate();
  const inspection=deferred();
  const displayed=[];
  const oldTicket=gate.begin();
  const work=inspection.promise.then(result=>{
    if(gate.owns(oldTicket))displayed.push(result);
  }).finally(()=>displayed.push(gate.finish(oldTicket)));
  assert.equal(gate.request('new'),false);
  inspection.resolve({id:'old-game',name:'Old'});
  await work;
  assert.deepEqual(displayed,['new']);
  const newTicket=gate.begin();
  assert.equal(gate.owns(newTicket),true);
  assert.equal(gate.owns(oldTicket),false);
  gate.finish(newTicket);
});

test('close and change requests during a single operation honor only final action',()=>{
  const gate=createHostStudioFlowGate();
  const active=gate.begin();
  assert.equal(gate.request('new'),false);
  assert.equal(gate.request('close'),false);
  assert.equal(gate.finish(active),'close');
  const second=gate.begin();
  assert.equal(gate.request('close'),false);
  assert.equal(gate.request('new'),false);
  assert.equal(gate.finish(second),'new');
});

test('unmount while a picker promise is unresolved prevents state updates and callbacks',async()=>{
  const gate=createHostStudioFlowGate();
  const picker=deferred();
  const callbacks=[];
  const ticket=gate.begin();
  const opened=picker.promise.then(value=>{
    if(gate.owns(ticket))callbacks.push(['inspect',value]);
  }).finally(()=>callbacks.push(['done',gate.finish(ticket)]));
  gate.dispose();
  assert.equal(gate.isLive(),false);
  assert.equal(gate.begin(),null);
  assert.equal(gate.request('new'),false);
  picker.resolve('C:\\Users\\Old\\Game.zip');
  await opened;
  assert.equal(callbacks.length,1);
  assert.equal(callbacks[0][0],'done');
  assert.equal(callbacks[0][1],null);
});

test('obsolete clipboard callbacks cannot overwrite another export or close',()=>{
  const gate=createHostStudioFlowGate();
  const current=gate.revision();
  assert.equal(gate.isRevision(current),true);
  const ticket=gate.begin();
  assert.equal(gate.isRevision(current),false);
  const copied=gate.revision();
  gate.finish(ticket);
  assert.equal(gate.isRevision(copied),true);
  assert.equal(gate.request('new'),true);
  assert.equal(gate.isRevision(copied),false);
  gate.dispose();
  assert.equal(gate.isRevision(gate.revision()),false);
});

test('safe proposed names do not turn a ZIP into a double-extension delivery',()=>{
  assert.equal(suggestedFutureZipName('C:\\Games\\Juégo nuevo.zip'),'Jue-go-nuevo.zip');
  assert.equal(suggestedFutureZipName('D:\\Games\\--.zip'),'juego.zip');
  const future=suggestedFutureZipName('/tmp/x'.repeat(100));
  assert.ok(future.endsWith('.zip')&&future.length<=124);
  assert.equal(suggestedPortableFileName('game','1.0'),'game-1.0.coco2pack');
  assert.equal(isPortableSavePath('C:\\Downloads\\a.coco2pack'),true);
  assert.equal(isPortableSavePath('C:\\Downloads\\a.coco2pack.zip'),false);
});

test('native error categories are friendly and do not show JSON, SHA or local paths',()=>{
  for(const [stage,native,phrase] of [
    ['inspect','Unsupported ZIP archive','archivo no cumple'],
    ['draft','Draft already exists','Ya existe una preparación'],
    ['review','Original SHA256 changed','contenido cambió'],
    ['prepare','No space left on device','Falta espacio'],
    ['advanced','Internal native error','No se pudo completar'],
  ]){
    const message=hostStudioOperationError(native,stage);
    assert.match(message,new RegExp(phrase,'i'));
    assert.doesNotMatch(message,/sha256|\.json|C:\\|stacktrace|exception/i);
  }
  assert.match(portableExportError('Portable export target already exists','export'),/no reemplaza/);
});

test('every native mutation/read flow has an exclusive ticket and guarded result',()=>{
  for(const method of [
    'inspect_standalone_archive','create_standalone_draft','create_standalone_update_draft',
    'review_standalone_draft','preview_standalone_publish','prepare_standalone_publish',
    'export_portable_standalone_package','review_local_publish_package',
    'import_local_publish_package','prepare_catalog_channel',
    'verify_channel_delivery_online','review_channel_delivery','promote_standalone_draft',
  ])assert.ok(source.includes(method),`preserved native contract: ${method}`);
  const funcs=[
    'browse','create','reviewForCatalog','previewPublish','preparePublish',
    'reviewForMyLibrary','addToMyLibrary','prepareChannel','checkDelivery',
    'exportPortable','promote',
  ];
  for(const name of funcs){
    const start=source.indexOf(`const ${name}=async(`);
    const next=source.indexOf('\n  const ',start+1);
    const body=source.slice(start,next>=0?next:source.length);
    assert.ok(start>=0,`missing action ${name}`);
    assert.match(body,/beginOperation\(/,`${name} must acquire native/picker guard`);
    assert.match(body,/completeOperation\(ticket\)/,`${name} must release native/picker guard`);
    if(name!=='exportPortable')assert.match(body,/flowGate\.current\.owns\(ticket\)/,`${name} must guard native completion`);
  }
  assert.match(source,/prepareTicket\.current=ticket;progressSampler\.current\.reset\(\);setPublishProgress\(null\)/);
  assert.match(source,/ticket!==null&&flowGate\.current\.owns\(ticket\)/);
  assert.match(source,/prepareTicket\.current!==null&&flowGate\.current\.owns\(prepareTicket\.current\)/);
  assert.match(source,/event\.payload\.id===result\?\.id/);
});

test('native Save As cancellation never invokes export, and close/new are deferred safely',()=>{
  const savePosition=source.indexOf('const destination=await save({');
  const cancellation=source.indexOf('if(!destination)',savePosition);
  const validation=source.indexOf('if(!isPortableSavePath(destination))',cancellation);
  const native=source.indexOf("invoke<PortableExport>('export_portable_standalone_package'",validation);
  assert.ok(savePosition>=0&&cancellation>savePosition&&validation>cancellation&&native>validation);
  assert.match(source.slice(savePosition,native),/if\(!flowGate\.current\.owns\(ticket\)\)return/);
  assert.match(source,/const safelyClose=\(\)=>\{[\s\S]*?flowGate\.current\.request\('close'\)/);
  assert.match(source,/const changeGame=\(\)=>\{[\s\S]*?flowGate\.current\.request\('new'\)/);
  assert.match(source,/if\(action==='new'\)resetForNewGame\(\)/);
  assert.match(source,/else if\(action==='close'\)close\(\)/);
  assert.match(source,/if\(!flowGate\.current\.isLive\(\)\)return/);
});

test('accessible stage presentation and recipient actions have no technical JSON or SHA',()=>{
  assert.match(source,/aria-current=\{!inspection\?'step':undefined\}/);
  assert.match(source,/aria-busy=\{busy\}/);
  assert.match(source,/role="progressbar" aria-label="Preparación del paquete"/);
  assert.match(source,/aria-live="polite"/);
  assert.match(source,/Cerrar al terminar la operación/);
  assert.match(source,/Cambiar juego al terminar/);
  assert.match(source,/Guardar como \.coco2pack/);
  assert.match(source,/Guardar otra copia/);
  assert.match(source,/Copiar instrucciones/);
  assert.match(source,/Listo, cerrar Host Studio/);
  assert.match(source,/No necesita extraer nada/);
  assert.match(source,/<details className="studio-release-fields studio-wide">/);
  assert.match(source,/if\(!flowGate\.current\.isLive\(\)\)flowGate\.current=createHostStudioFlowGate\(\)/,
    'StrictMode effect re-setup must not leave the guard disposed');
  assert.doesNotMatch(source,/<pre>\{publishPreview\.catalogDiff\}<\/pre>/);
  assert.doesNotMatch(source,/<code>\{(?:publishArtifact\.artifactPath|promoted\.catalogPath|channelDraft\.signaturePath)\}<\/code>/);
  assert.doesNotMatch(source,/\{(?:publishPreview\.previewSha256|publishArtifact\.archiveSha256|channelDraft\.channelSha256)\}/);
  assert.doesNotMatch(source,/asset\.name\}\s*<\/strong>/);
});
