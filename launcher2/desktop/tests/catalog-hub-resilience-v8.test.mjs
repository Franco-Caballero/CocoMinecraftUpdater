// Exercises the REAL TypeScript review gate, post-commit helper, picker and
// consent handlers with controlled promises. Never opens Tauri, Explorer,
// a game, a ZIP, HKCU or the user's library.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const format=await readFile(resolve(root,'src/portable-format.ts'),'utf8');
const hub=await readFile(resolve(root,'src/CatalogHub.tsx'),'utf8');
const fmt=ts.transpileModule(format,{compilerOptions:{
  module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},reportDiagnostics:true});
assert.equal(fmt.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);
const sandbox={exports:{}};
runInNewContext(fmt.outputText,sandbox,{timeout:1000});
const {createPortableReviewGate,isMatchingPortableReview,isPortablePackageFile,
  settleAcceptedPortableImport,recipientPackageError,portablePackageKind}=sandbox.exports;

const ast=ts.createSourceFile('CatalogHub.tsx',hub,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const targets=['confirmImport','choosePackage','retryIncomingReview','discardReview'];
const handlers=new Map();
const visit=node=>{
  if(ts.isVariableDeclaration(node)&&targets.includes(node.name.getText(ast)))
    handlers.set(node.name.getText(ast),node.initializer.getText(ast));
  ts.forEachChild(node,visit);
};
visit(ast);
assert.equal(handlers.size,targets.length,'must run actual frontend handlers');
const source=targets.map(name=>'const '+name+'='+handlers.get(name)+';').join('\n')+
  '\n({'+targets.join(',')+'});';
const transpiled=ts.transpileModule(source,{compilerOptions:{
  module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022},reportDiagnostics:true});
assert.equal(transpiled.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);

const A='C:\\Usuarios\\García\\Descargas\\Juégo 日本語.coco2pack';
const B='C:\\Usuarios\\García\\Descargas\\Другой.coco2pack.zip';
const review=(path=A,token='rust-token-A')=>({
  id:'juego-utf8',newVersion:'1.0.0',mode:'new',
  status:'ready-for-review',reviewToken:token,
  sourcePath:'\\\\?\\'+path
});
const deferred=()=>{
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};
function mount({
  hostStudioAvailable=true, // Legacy review/commit scenarios are host-authoring ONLY.
  incomingPath=A,
  nativeCommit=async()=>({status:'updated'}),
  nativeReview=async path=>review(path),
  picker=async()=>null,
  refresh=async()=>{},
  confirmed=true
}={}){
  const events=[];
  const gate=createPortableReviewGate();
  const ticket=gate.begin();
  const preview=review(incomingPath||A);
  if(incomingPath!==undefined)assert.equal(gate.accept(ticket,incomingPath,preview.reviewToken),true);
  const ctx={
    reviewGate:{current:gate},mounted:{current:true},incomingNow:{current:incomingPath},
    // Real TSX closes over a ref derived from hostStudioAvailable. AST-extracted
    // handlers must receive that lexical ref, not silently omit the policy.
    hostCanImportNow:{current:hostStudioAvailable===true},
    pendingReview:{current:null},incomingPath,sourcePath:incomingPath||'',
    pickerPendingRef:{current:false},pickerOpen:false,
    review:incomingPath?preview:null,reviewTicket:ticket,confirmed,
    checking:false,importing:false,stage:'idle',error:'',message:'',
    inboxReplay:0, status:null,
    isTauri:()=>true,isPortablePackageFile,isMatchingPortableReview,
    recipientPackageError,settleAcceptedPortableImport,
    open:async opts=>{events.push(['picker',opts]);return picker(opts);},
    invoke:async (command,args)=>{
      events.push(['native',command,args]);
      if(command==='import_local_publish_package')return nativeCommit(args);
      if(command==='review_local_publish_package')return nativeReview(args.path);
      throw Error('Unexpected native call '+command);
    },
    onChanged:async()=>{events.push('refresh');return refresh();},
    onImported:id=>events.push(['details',id]),
    onInboxDone:path=>events.push(['ack',path]),
    console:{warn:(...args)=>events.push(['warning',String(args[0])])},
    setReview(value){ctx.review=value;},
    setReviewTicket(value){ctx.reviewTicket=value;},
    setSourcePath(value){ctx.sourcePath=value;},
    setConfirmed(value){ctx.confirmed=value;},
    setImporting(value){ctx.importing=value;},
    setStage(value){ctx.stage=value;},
    setError(value){ctx.error=value;},
    setMessage(value){ctx.message=value;},
    setStatus(value){ctx.status=value;},
    setInboxReplay(updater){ctx.inboxReplay=updater(ctx.inboxReplay);},
    setPickerOpen(value){ctx.pickerOpen=value;},
    clearReview(){ctx.review=null;ctx.reviewTicket=0;ctx.confirmed=false;ctx.sourcePath='';}
  };
  const handlers=runInNewContext(transpiled.outputText,ctx,{timeout:1000});
  return {
    ctx,gate,events,...handlers,
    natives:command=>events.filter(e=>Array.isArray(e)&&e[0]==='native'&&
      (command===undefined||e[1]===command)),
    acknowledged:()=>events.filter(e=>Array.isArray(e)&&e[0]==='ack'),
    details:()=>events.filter(e=>Array.isArray(e)&&e[0]==='details')
  };
}

test('UTF-8 .coco2pack and legacy .coco2pack.zip bind canonical native review to selection',()=>{
  assert.equal(isPortablePackageFile(A),true);
  assert.equal(isPortablePackageFile(B),true);
  assert.equal(portablePackageKind(B),'legacy');
  assert.equal(isMatchingPortableReview(review(A),A),true);
  assert.equal(isMatchingPortableReview(review(B,'token-B'),B),true);
  assert.equal(isMatchingPortableReview({...review(A),sourcePath:A.toUpperCase()},A),true);
  assert.equal(isMatchingPortableReview({...review(A),sourcePath:B},A),false);
  assert.equal(isMatchingPortableReview({...review(A),reviewToken:'  '},A),false);
  assert.equal(isMatchingPortableReview({...review(A),status:'unverified'},A),false);
  assert.equal(isMatchingPortableReview({...review(A),newVersion:''},A),false);
  assert.equal(isPortablePackageFile('C:\\Temp\\ordinary.zip'),false);
});

test('double click Commit uses exact path+reviewToken once; no import without consent',async()=>{
  const native=deferred();
  const box=mount({nativeCommit:()=>native.promise});
  const first=box.confirmImport();
  await box.confirmImport();
  assert.equal(box.natives('import_local_publish_package').length,1);
  const args=box.natives()[0][2];
  assert.equal(args.path,A);
  assert.equal(args.reviewToken,'rust-token-A');
  assert.equal(args.confirmed,true);
  assert.equal(box.gate.isCommitting(),true);
  native.resolve({status:'unchanged'});
  await first;
  assert.equal(box.gate.isCommitting(),false);
  assert.equal(box.acknowledged().length,1);
  assert.equal(box.events.includes('refresh'),false,'unchanged import avoids refresh');
  const withoutConsent=mount({confirmed:false});
  await withoutConsent.confirmImport();
  assert.equal(withoutConsent.natives().length,0);
});

test('warm Explorer B during accepted A commit: refresh A, ack A, never open old details',async()=>{
  const committed=deferred();
  const box=mount({nativeCommit:()=>committed.promise});
  const task=box.confirmImport();
  box.ctx.incomingPath=B;
  box.ctx.incomingNow.current=B;
  assert.equal(box.gate.begin(),null,'B must wait for irreversible A commit');
  committed.resolve({status:'updated'});
  await task;
  assert.equal(box.natives('import_local_publish_package').length,1);
  assert.deepEqual(box.acknowledged(),[['ack',A]]);
  assert.equal(box.events.includes('refresh'),true);
  assert.equal(box.details().length,0,'never navigate to old A during B review');
  assert.equal(box.ctx.inboxReplay,1,'B must receive a fresh review after native commit');
  assert.equal(box.gate.isCommitting(),false);
  const bTicket=box.gate.begin();
  assert.ok(bTicket>0);
  assert.equal(box.gate.accept(bTicket,B,'fresh-token-B'),true);
  assert.equal(box.gate.beginCommit(bTicket,B,'rust-token-A'),false);
});

test('cold Explorer unmount while native commit is in flight still refreshes and acknowledges',async()=>{
  const committed=deferred();
  const box=mount({nativeCommit:()=>committed.promise});
  const task=box.confirmImport();
  box.ctx.mounted.current=false;
  assert.equal(box.gate.discard(),false,'native commit cannot be canceled by unmount');
  committed.resolve({status:'updated'});
  await task;
  assert.equal(box.events.includes('refresh'),true);
  assert.deepEqual(box.acknowledged(),[['ack',A]]);
  assert.equal(box.details().length,0);
  assert.equal(box.ctx.inboxReplay,0);
  assert.equal(box.gate.isCommitting(),false);
});

test('refresh failure after accepted native import does not misreport or repeat the commit',async()=>{
  const box=mount({refresh:async()=>{throw Error('refresh failed C:\\private\\token');}});
  await box.confirmImport();
  assert.equal(box.natives('import_local_publish_package').length,1);
  assert.deepEqual(box.acknowledged(),[['ack',A]]);
  assert.equal(box.details().length,1);
  assert.match(box.ctx.message,/Experiencia añadida/);
  assert.equal(box.ctx.error,'');
  assert.equal(box.events.some(e=>Array.isArray(e)&&e[0]==='warning'),true);
  await box.confirmImport();
  assert.equal(box.natives('import_local_publish_package').length,1,'already consumed token');
});

test('changed package rejected by Rust never acknowledges or reuses its old token',async()=>{
  const box=mount({nativeCommit:async()=>{throw Error('Publish review is stale or unauthorized');}});
  await box.confirmImport();
  assert.equal(box.natives('import_local_publish_package').length,1);
  assert.equal(box.acknowledged().length,0);
  assert.equal(box.ctx.confirmed,false);
  assert.equal(box.ctx.review,null);
  assert.match(box.ctx.error,/paquete cambió/i);
  assert.equal(box.gate.isCommitting(),false);
  assert.equal(box.gate.beginCommit(box.ctx.reviewTicket,A,'rust-token-A'),false);
});

test('manual picker cancel and double click have no native review or import',async()=>{
  const picked=deferred();
  let pickerCount=0;
  const box=mount({incomingPath:undefined,picker:async()=>{
    pickerCount++;
    return picked.promise;
  }});
  const first=box.choosePackage();
  await box.choosePackage();
  assert.equal(pickerCount,1,'second click rejected while first dialog pending');
  picked.resolve(null);
  await first;
  assert.equal(box.natives().length,0);
  assert.match(box.ctx.message,/Selección cancelada/);
  assert.equal(box.ctx.importing,false);
  assert.match(hub,/ref=\{openPackageButtonRef\}/);
  assert.match(hub,/message\.startsWith\('Selección cancelada'\)/);
  assert.match(hub,/openPackageButtonRef\.current\?\.focus\(\)/);
});

test('discard during a pending native picker blocks a second OS dialog until first settles',async()=>{
  const pending=deferred();
  let pickers=0;
  const box=mount({incomingPath:undefined,picker:()=>{
    pickers++;
    return pickers===1?pending.promise:null;
  }});
  const first=box.choosePackage();
  assert.equal(box.ctx.pickerOpen,true);
  assert.equal(box.ctx.pickerPendingRef.current,true);
  box.discardReview();
  assert.equal(box.ctx.importing,false);
  assert.match(box.ctx.message,/selector de Windows puede seguir abierto/);
  await box.choosePackage();
  assert.equal(pickers,1,'do not show another native picker while one still exists');
  pending.resolve(A);
  await first;
  assert.equal(box.natives().length,0,'discarded picker response must remain inert');
  assert.equal(box.ctx.pickerOpen,false);
  assert.equal(box.ctx.pickerPendingRef.current,false);
  await box.choosePackage();
  assert.equal(pickers,2,'user can choose again after actual dialog dismissal');
  assert.equal(box.natives().length,0);
  assert.match(hub,/disabled=\{!isTauri\(\)\|\|checking\|\|importing\|\|pickerOpen\}/);
});

test('legacy folder remains selectable and is only REVIEWED, never imported automatically',async()=>{
  const folder='D:\\Coco\\Antiguo-日本語';
  const box=mount({incomingPath:undefined,picker:async()=>folder,
    nativeReview:async()=>review(folder,'legacy-folder-token')});
  await box.choosePackage(true);
  assert.equal(box.natives('review_local_publish_package').length,1);
  assert.equal(box.natives('import_local_publish_package').length,0);
  assert.equal(box.ctx.sourcePath,folder);
  assert.equal(box.ctx.review.reviewToken,'legacy-folder-token');
  assert.equal(box.ctx.confirmed,false);
  const options=box.events.find(event=>Array.isArray(event)&&event[0]==='picker')[1];
  assert.equal(options.directory,true);
});

test('manual picker rejects another source from native and Explorer race supersedes old picker',async()=>{
  const box=mount({incomingPath:undefined,picker:async()=>A,
    nativeReview:async()=>review(B,'token-from-B')});
  await box.choosePackage();
  assert.equal(box.natives('review_local_publish_package').length,1);
  assert.equal(box.ctx.review,null);
  assert.match(box.ctx.error,/No se recibió una revisión válida/);

  const oldPicker=deferred();
  const newer=mount({incomingPath:undefined,picker:()=>oldPicker.promise});
  const first=newer.choosePackage();
  const bTicket=newer.gate.begin();
  assert.equal(newer.gate.accept(bTicket,B,'B'),true);
  oldPicker.resolve(A);
  await first;
  assert.equal(newer.natives().length,0);
  assert.equal(newer.gate.isReviewed(bTicket,B,'B'),true);
});

test('retry incoming performs read-only review and can recover after a changed file',async()=>{
  let number=0;
  const box=mount({nativeReview:async path=>{
    number++;
    return number===1?{...review(path),sourcePath:B}:review(path,'fresh-token');
  }});
  await box.retryIncomingReview();
  assert.equal(box.ctx.review,null);
  assert.match(box.ctx.error,/No se recibió una revisión válida/);
  await box.retryIncomingReview();
  assert.equal(box.ctx.review.reviewToken,'fresh-token');
  assert.equal(box.ctx.confirmed,false);
  assert.equal(box.natives('review_local_publish_package').length,2);
  assert.equal(box.natives('import_local_publish_package').length,0);
});

test('pure settlement is idempotent-by-invocation and preserves ack through callback errors',async()=>{
  const events=[];
  const result=await settleAcceptedPortableImport(
    {status:'updated'},
    async()=>{events.push('refresh');throw Error('offline');},
    ()=>{events.push('open');throw Error('missing view');},
    ()=>{events.push('ack');},
    (stage)=>events.push('failed-'+stage)
  );
  assert.equal(result,'updated');
  assert.deepEqual(events,['refresh','failed-refresh','open','failed-open','ack']);
  events.length=0;
  assert.equal(await settleAcceptedPortableImport(
    {status:'degraded'},async()=>events.push('refresh'),
    ()=>events.push('open'),()=>events.push('ack'),()=>{}
  ),null);
  assert.deepEqual(events,[]);
});

test('review and import are separated by user confirmation; legacy selector retained',()=>{
  assert.match(hub,/extensions:\['coco2pack','zip'\]/);
  assert.match(hub,/if\(!legacyFolder&&!isPortablePackageFile\(selected\)\)/);
  assert.match(hub,/!hostCanImportNow\.current\|\|!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(hub,/hostCanImport&&!compact&&<details className="catalog-legacy-import"/);
  assert.match(hub,/path:sourcePath,reviewToken:review\.reviewToken,confirmed:true/);
  assert.match(hub,/if\(wasInbox&&incomingNow\.current&&incomingNow\.current!==sourcePath\)/);
  assert.match(hub,/setInboxReplay\(value=>value\+1\)/);
  assert.match(hub,/settleAcceptedPortableImport\(/);
  assert.doesNotMatch(hub,/invoke\([^)]*launch_game|invoke\([^)]*execute_game/i);
});

test('client capability denial stops formerly valid consent, native picker and legacy folder',async()=>{
  const client=mount({hostStudioAvailable:false});
  await client.confirmImport();
  await client.choosePackage();
  await client.choosePackage(true);
  assert.equal(client.natives('import_local_publish_package').length,0);
  assert.equal(client.natives('review_local_publish_package').length,0);
  assert.equal(client.events.filter(e=>Array.isArray(e)&&e[0]==='picker').length,0);
  assert.equal(client.ctx.review?.reviewToken,'rust-token-A',
    'read-only Explorer preview remains available, but not an import permission');
  assert.equal(client.gate.isCommitting(),false);
});

test('client capability revoked after host picker request blocks late path review',async()=>{
  const pending=deferred();
  const host=mount({incomingPath:undefined,picker:()=>pending.promise});
  const task=host.choosePackage();
  assert.equal(host.events.filter(e=>Array.isArray(e)&&e[0]==='picker').length,1);
  host.ctx.hostCanImportNow.current=false;
  pending.resolve(A);
  await task;
  assert.equal(host.natives().length,0);
  assert.equal(host.ctx.pickerPendingRef.current,false);
});
