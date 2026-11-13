// Host Studio v9: execute ORIGINAL TypeScript helpers and React event handlers
// against deterministic in-memory Tauri mocks. No ZIP, user file, GUI, Setup,
// HKCU, publication or native import is ever opened or modified.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=await readFile(resolve(root,'src/HostStudio.tsx'),'utf8');
const style=await readFile(resolve(root,'src/host-studio-v9.css'),'utf8');
const ast=ts.createSourceFile('HostStudio.tsx',source,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const helpers=[
  'classifyStudioSelection','suggestStudioExecutable','studioMissingItems',
  'suggestedFutureZipName','createDraftWithPreview','isPortableSavePath',
  'isLocalPortableSavePath','isConfirmedPortableExport',
  'suggestedPortableFileName','portableExportError','createHostStudioFlowGate',
];
const originals=ast.statements.filter(n=>ts.isFunctionDeclaration(n)&&helpers.includes(n.name?.text));
assert.equal(originals.length,helpers.length,'must execute actual source helpers');
const handlers=['browse','preparePublish','exportPortable'];
const extracted=new Map();
let autoSaveEffect;
const visit=node=>{
  if(ts.isVariableDeclaration(node)&&handlers.includes(node.name.getText(ast)))
    extracted.set(node.name.getText(ast),node.initializer.getText(ast));
  if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&
    node.arguments[0]?.getText(ast).includes('autoSavePendingRef.current')){
    autoSaveEffect=node.arguments[0].getText(ast);
  }
  ts.forEachChild(node,visit);
};
visit(ast);
assert.equal(extracted.size,handlers.length);
assert.ok(autoSaveEffect,'auto-SaveAs effect must be extracted from actual React component');
const executableCode=originals.map(node=>node.getText(ast).replace(/^export\s+/,'')).join('\n')+
  '\n'+handlers.map(name=>'const '+name+'='+extracted.get(name)+';').join('\n')+
  '\nconst autoSaveEffect='+autoSaveEffect+';\n({'+[...handlers,'autoSaveEffect'].join(',')+'});';
const js=ts.transpileModule(executableCode,{compilerOptions:{
  module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022},reportDiagnostics:true});
assert.equal(js.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);
const defer=()=>{
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};
// The React effect schedules an async handler but does not await its promise.
const drain=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
const ZIP='C:\\Juegos\\日本語 áé\\Aventura 2.zip';
const COVER='C:\\Juegos\\日本語 áé\\cover.webp';
const DEST='C:\\Descargas\\日本語 Aventura.coco2pack';
const sampleInspection={
  suggestedId:'aventura-2',suggestedName:'Aventura 2',
  executables:['Support\\setup.exe','Game\\Aventura 2.exe','Launcher.exe'],
  filesCount:120,archiveSize:2_048_000,uncompressedBytes:3_500_000,
  sha256:'a'.repeat(64)
};
const sealed={id:'aventura-2',artifactPath:'C:\\Synthetic\\sealed',status:'prepared'};
const receipt={id:'aventura-2',path:DEST,size:10340,
  status:'exported-local-untrusted-unpublished',sha256:'hidden'};

// A test harness for actual UI handler bodies, not a reimplementation of the
// source event flow. State setter stubs mirror React's most recent render.
function mount({selection=[ZIP,COVER],inspected=sampleInspection,
  prepared=sealed,pickSave=()=>DEST,exported=receipt}={}){
  const events=[];
  const ctx={
    zip:ZIP,cover:COVER,inspection:sampleInspection,
    name:'Aventura 2',id:'aventura-2',version:'1.0.0',
    executable:'Game\\Aventura 2.exe',url:'https://example.test/v1/aventura.zip',
    mode:'new',busy:false,result:{id:'aventura-2'},
    rightsReviewed:true,publishPreview:{previewSha256:'review-token',newVersion:'1.0.0'},
    publishArtifact:null,publishProgress:null,
    exportPendingRef:{current:false},prepareTicket:{current:null},
    progressSampler:{current:{reset:()=>events.push('progress-reset')}},
    autoSavePendingRef:{current:false},
    flowGate:{current:null},
    exportButtonRef:{current:{focus:()=>events.push('focus')}},
    copiedExport:false,error:'',notice:'',exportPhase:'idle',
    setError(value){ctx.error=value;},
    setBusy(value){ctx.busy=value;},
    setBusyLabel(value){ctx.busyLabel=value;},
    setExportPhase(value){ctx.exportPhase=value;},
    setExportNotice(value){ctx.notice=value;},
    setRestoreExportFocus(value){ctx.restore=value;},
    setCopiedExport(value){ctx.copiedExport=value;},
    setPublishArtifact(value){ctx.publishArtifact=value;},
    setPublishProgress(value){ctx.publishProgress=value;},
    setPortableExport(value){ctx.portableExport=value;},
    setZip(value){ctx.zip=value;},
    setCover(value){ctx.cover=value;},
    setInspection(value){ctx.inspection=value;},
    setResult(value){ctx.result=value;},
    setReview(){},setPromoted(){},setPublishPreview(){},
    setChannelDraft(){},
    setAssetName(value){ctx.assetName=value;},
    setId(value){ctx.id=value;},
    setName(value){ctx.name=value;},
    setExecutable(value){ctx.executable=value;},
    setExecutableReviewKey(value){ctx.executableReviewKey=value;},
    setMessage(){},
    setRestoreExportFocus(value){ctx.restore=value;},
    setCopiedExport(value){ctx.copiedExport=value;},
    open:async opts=>{events.push(['open',opts]);return typeof selection==='function'?selection(opts):selection;},
    save:async opts=>{events.push(['save',opts]);return pickSave(opts);},
    invoke:async (command,args)=>{
      events.push(['invoke',command,args]);
      if(command==='inspect_standalone_archive')return inspected;
      if(command==='prepare_standalone_publish')return typeof prepared==='function'?prepared(args):prepared;
      if(command==='export_portable_standalone_package')return typeof exported==='function'?exported(args):exported;
      throw new Error('Unexpected native command: '+command);
    }
  };
  const extractedRun=runInNewContext(js.outputText,ctx,{timeout:1000});
  ctx.flowGate.current=runInNewContext('createHostStudioFlowGate()',ctx);
  ctx.beginOperation=label=>{
    const ticket=ctx.flowGate.current.begin();
    if(ticket!==null){ctx.setBusy(true);ctx.setBusyLabel(label);}
    return ticket;
  };
  ctx.completeOperation=ticket=>{
    const action=ctx.flowGate.current.finish(ticket);
    ctx.setBusy(false);ctx.setBusyLabel('');ctx.prepareTicket.current=null;
    ctx.lastAction=action;
  };
  ctx.showOperationError=(ticket,error,stage)=>{
    if(ctx.flowGate.current.owns(ticket))ctx.setError(stage+':'+String(error));
  };
  ctx.suggestedFutureZipName=runInNewContext('suggestedFutureZipName',ctx);
  ctx.classifyStudioSelection=runInNewContext('classifyStudioSelection',ctx);
  ctx.suggestStudioExecutable=runInNewContext('suggestStudioExecutable',ctx);
  return {ctx,events,...extractedRun,
    calls:command=>events.filter(e=>Array.isArray(e)&&e[0]==='invoke'&&
      (!command||e[1]===command)),
    dialogs:name=>events.filter(e=>Array.isArray(e)&&e[0]===name)};
}

test('single picker may choose Unicode ZIP + optional cover, no second browse',async()=>{
  const box=mount();
  await box.browse('zip');
  assert.equal(box.dialogs('open').length,1);
  assert.equal(box.calls('inspect_standalone_archive').length,1);
  assert.equal(box.ctx.zip,ZIP);
  assert.equal(box.ctx.cover,COVER);
  assert.equal(box.ctx.id,'aventura-2');
  assert.equal(box.ctx.name,'Aventura 2');
  assert.equal(box.ctx.executable,'Game\\Aventura 2.exe');
  const opts=box.dialogs('open')[0][1];
  assert.equal(opts.multiple,true);
  assert.equal(opts.filters[0].extensions.includes('zip'),true);
  assert.equal(opts.filters[0].extensions.includes('webp'),true);
  assert.equal(box.calls('export_portable_standalone_package').length,0);
});

test('ZIP-only selection is allowed for inspection and draft with an original generated neutral cover',async()=>{
  const box=mount({selection:[ZIP]});
  await box.browse('zip');
  assert.equal(box.ctx.zip,ZIP);
  assert.equal(box.ctx.cover,'');
  const required=runInNewContext('studioMissingItems',box.ctx)({
    zip:box.ctx.zip,cover:box.ctx.cover,executable:box.ctx.executable,
    name:box.ctx.name,id:box.ctx.id,version:'1.0.0',urlValid:true
  });
  assert.ok(!required.some(item=>item.includes('portada')));
  assert.match(source,/missingItems\.length>0/);
  assert.match(source,/disabled=\{busy\|\|!urlValid\|\|missingItems\.length>0\}/);
  assert.match(source,/Portada \(opcional\)/);
});

test('unsafe or ambiguous selection never inspects files',async()=>{
  for(const selected of [
    ['C:\\A.zip','C:\\B.zip'],['C:\\cover.webp'],
    ['C:\\A.zip','C:\\cover.png','C:\\cover.jpg'],
    ['C:\\A.zip','C:\\file.txt']
  ]){
    const box=mount({selection:selected});
    await box.browse('zip');
    assert.equal(box.calls('inspect_standalone_archive').length,0);
    assert.match(box.ctx.error,/Elige exactamente un ZIP|Selecciona un ZIP/);
  }
});

test('classifier never proposes setup or uninstall as the game executable',()=>{
  const funcs=runInNewContext('({classifyStudioSelection,suggestStudioExecutable,studioMissingItems})',
    mount().ctx);
  const choose=funcs.suggestStudioExecutable;
  assert.equal(choose(['support/setup.exe','Aventura 2.exe'],ZIP),'Aventura 2.exe');
  assert.equal(choose(['uninstall.exe','setup.exe'],ZIP),'');
  assert.equal(choose(['other.exe','Game/launcher.exe'],'C:\\Game.zip'),'Game/launcher.exe');
  assert.equal(choose([],ZIP),'');
  assert.equal(funcs.classifyStudioSelection(null).error,'');
  assert.equal(funcs.classifyStudioSelection([ZIP,COVER]).cover,COVER);
});

test('prepare+save is one user action, but separate exclusive native tickets',async()=>{
  const box=mount();
  await box.preparePublish();
  assert.equal(box.calls('prepare_standalone_publish').length,1);
  assert.equal(box.ctx.publishArtifact.artifactPath,sealed.artifactPath);
  assert.equal(box.ctx.autoSavePendingRef.current,true);
  assert.equal(box.ctx.busy,false);
  await box.autoSaveEffect();
  await drain();
  assert.equal(box.ctx.autoSavePendingRef.current,false);
  assert.equal(box.dialogs('save').length,1);
  assert.equal(box.calls('export_portable_standalone_package').length,1);
  assert.equal(box.ctx.portableExport.path,DEST);
  assert.match(box.ctx.notice,/Archivo guardado/);
  await box.autoSaveEffect();
  await drain();
  assert.equal(box.dialogs('save').length,1,'StrictMode re-entry must not reopen Save As');
  assert.equal(box.ctx.flowGate.current.isActive(),false);
});

test('cancel Save As keeps prepared artifact, later redo uses no second prepare',async()=>{
  const box=mount({pickSave:()=>null});
  await box.preparePublish();
  await box.autoSaveEffect();
  await drain();
  assert.equal(box.dialogs('save').length,1);
  assert.equal(box.ctx.publishArtifact.artifactPath,sealed.artifactPath);
  assert.equal(box.ctx.portableExport,undefined);
  assert.match(box.ctx.notice,/Guardado cancelado/);
  assert.equal(box.ctx.restore,true);
  await box.exportPortable();
  assert.equal(box.calls('prepare_standalone_publish').length,1);
  assert.equal(box.dialogs('save').length,2);
  assert.equal(box.calls('export_portable_standalone_package').length,0);
});

test('close during native prepare invalidates result and never starts Save As',async()=>{
  const pending=defer();
  const box=mount({prepared:()=>pending.promise});
  const task=box.preparePublish();
  assert.equal(box.ctx.flowGate.current.request('close'),false);
  pending.resolve(sealed);
  await task;
  await box.autoSaveEffect();
  assert.equal(box.ctx.publishArtifact,null);
  assert.equal(box.ctx.autoSavePendingRef.current,false);
  assert.equal(box.dialogs('save').length,0);
  assert.equal(box.ctx.lastAction,'close');
});

test('fast double click during native prepare issues one operation only',async()=>{
  const pending=defer();
  const box=mount({prepared:()=>pending.promise});
  const first=box.preparePublish();
  await box.preparePublish();
  assert.equal(box.calls('prepare_standalone_publish').length,1);
  pending.resolve(sealed);
  await first;
  await box.autoSaveEffect();
  await drain();
  assert.equal(box.dialogs('save').length,1);
  assert.equal(box.calls('export_portable_standalone_package').length,1);
});

test('change game during Save As prevents later native export',async()=>{
  const picker=defer();
  const box=mount({pickSave:()=>picker.promise});
  await box.preparePublish();
  const saving=box.autoSaveEffect();
  assert.equal(box.ctx.flowGate.current.request('new'),false);
  picker.resolve(DEST);
  await saving;
  await drain();
  assert.equal(box.calls('export_portable_standalone_package').length,0);
  assert.equal(box.ctx.lastAction,'new');
});

test('close during actual native .coco2pack export waits for writer and suppresses stale success',async()=>{
  const writer=defer();
  const box=mount({exported:()=>writer.promise});
  await box.preparePublish();
  await box.autoSaveEffect();
  await drain();
  assert.equal(box.calls('export_portable_standalone_package').length,1);
  assert.equal(box.ctx.flowGate.current.request('close'),false);
  assert.equal(box.ctx.flowGate.current.isActive(),true);
  writer.resolve(receipt);
  await drain();
  assert.equal(box.ctx.portableExport,undefined);
  assert.equal(box.ctx.lastAction,'close');
  assert.equal(box.calls('export_portable_standalone_package').length,1);
  assert.equal(box.ctx.flowGate.current.isActive(),false);
});

test('native export failure never repeats writer or asserts unverified completion',async()=>{
  const box=mount({exported:async()=>{throw new Error('Portable export target already exists; never overwrite');}});
  await box.preparePublish();
  await box.autoSaveEffect();
  await drain();
  assert.equal(box.calls('export_portable_standalone_package').length,1);
  assert.equal(box.ctx.portableExport,undefined);
  assert.match(box.ctx.error,/Ya existe un archivo/);
  assert.equal(box.ctx.publishArtifact.artifactPath,sealed.artifactPath);
});

test('native commands and consent, legacy panels remain isolated from automatic sharing',()=>{
  assert.match(source,/onClick=\{\(\)=>void create\(\)\}/);
  assert.match(source,/onClick=\{\(\)=>void preparePublish\(\)\}/);
  assert.match(source,/disabled=\{busy\|\|!rightsReviewed\}/);
  assert.match(source,/if\(!flowGate\.current\.owns\(ticket\)\)return/);
  assert.match(source,/if\(!destination\)/);
  assert.match(source,/No se creó una copia nueva/);
  assert.match(source,/Guardar otra copia/);
  assert.match(source,/Copiar instrucciones/);
  assert.match(source,/No necesita extraer nada/);
  assert.match(source,/role="progressbar"/);
  assert.match(source,/onCatalogChanged\?\.\(\)/);
  assert.match(source,/Guardar como \.coco2pack/);
  assert.match(source,/Configuración avanzada \(opcional\)/);
  assert.match(source,/Portada \(opcional\)/);
  assert.match(source,/require|requiere/i);
  assert.match(source,/import_local_publish_package/,'advanced manual import retained');
  assert.match(source,/promote_standalone_draft/,'advanced host promo retained');
  assert.match(source,/review_standalone_draft/,'advanced review retained');
  assert.match(source,/preview_standalone_publish/);
  assert.match(source,/create_standalone_draft/);
  assert.match(source,/export_portable_standalone_package/);
  assert.match(source,/import '.\/host-studio-v9\.css'/);
  assert.match(style,/\.coco-studio \.studio-v9-form/);
  assert.doesNotMatch(source,/<pre>\{publishPreview\.catalogDiff\}<\/pre>/);
  assert.doesNotMatch(source,/<code>\{publishArtifact\.artifactPath\}<\/code>/);
});
