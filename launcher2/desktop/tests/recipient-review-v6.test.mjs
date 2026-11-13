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
const emitted=ts.transpileModule(format,{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  reportDiagnostics:true,
});
assert.equal((emitted.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0);
const sandbox={exports:{}};
runInNewContext(emitted.outputText,sandbox,{timeout:1000});
const {isPortablePackageFile,portablePackageKind,recipientPackageError,
  createPortableReviewGate}=sandbox.exports;
const deferred=()=>{
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};

test('picker accepts .coco2pack and old .coco2pack.zip, but never generic .zip',()=>{
  for(const path of [
    'C:\\Downloads\\Game.coco2pack',
    'D:\\Juegos\\foo.COCO2PACK',
    '/tmp/Fun Game.coco2pack.zip',
    'C:\\Downloads\\juego.COCO2PACK.ZIP',
  ]) assert.equal(isPortablePackageFile(path),true,path);
  assert.equal(portablePackageKind('C:\\Downloads\\A.coco2pack'),'coco2pack');
  assert.equal(portablePackageKind('/tmp/A.coco2pack.zip'),'legacy');
  for(const path of [
    'C:\\Downloads\\Game.zip','/tmp/Game.zip','/tmp/a.coco2pack.zip.exe',
    '/tmp/a.coco2pack?download=1','/tmp/.coco2pack','/tmp/a?.coco2pack',
    '/tmp/dir.coco2pack/', '', '/tmp/a.coco2pack\n.bat',
    'C:\\Downloads\\Game.coco2pack:stream',
  ]) assert.equal(isPortablePackageFile(path),false,path);
  assert.equal(portablePackageKind('C:\\Downloads\\Game.zip'),null);
});

test('errors are friendly and never show SHA, native stack details or private paths',()=>{
  const scenarios=[
    ['No such file or directory (os error 2)',/archivo ya no está disponible/i],
    ['Review token mismatch for C:\\Users\\Secret\\Games',/paquete cambió/i],
    ['Unsupported ZIP manifest SHA256: 234'.repeat(2),/formato incompatible/i],
    ['Not enough disk space',/espacio suficiente/i],
  ];
  for(const [native,meaning] of scenarios){
    const userMessage=recipientPackageError(native,'review');
    assert.match(userMessage,meaning);
    assert.doesNotMatch(userMessage,/C:\\|os error|sha256|stack|\.json|token mismatch/i);
  }
  assert.match(recipientPackageError('unknown','review'),/biblioteca sigue intacta/);
  assert.match(recipientPackageError('unknown','import'),/Revisa nuevamente/);
});

test('late A review cannot override newer B even if native promises finish out of order',async()=>{
  const gate=createPortableReviewGate();
  const first=deferred(),second=deferred();
  const a=gate.begin();
  const resultA=first.promise.then(token=>gate.accept(a,'C:\\A.coco2pack',token));
  const b=gate.begin();
  const resultB=second.promise.then(token=>gate.accept(b,'C:\\B.coco2pack',token));
  second.resolve('token-B');
  assert.equal(await resultB,true);
  first.resolve('token-A');
  assert.equal(await resultA,false);
  assert.equal(gate.isReviewed(a,'C:\\A.coco2pack','token-A'),false);
  assert.equal(gate.isReviewed(b,'C:\\B.coco2pack','token-B'),true);
  assert.equal(gate.beginCommit(a,'C:\\A.coco2pack','token-A'),false);
  assert.equal(gate.beginCommit(b,'C:\\B.coco2pack','token-B'),true);
  gate.finishCommit();
});

test('discard invalidates in-flight reviews; no stale token can be committed later',async()=>{
  const gate=createPortableReviewGate();
  const deferredReview=deferred();
  const a=gate.begin();
  const pending=deferredReview.promise.then(token=>gate.accept(a,'C:\\A.coco2pack',token));
  assert.equal(gate.discard(),true);
  deferredReview.resolve('verified-A');
  assert.equal(await pending,false);
  assert.equal(gate.beginCommit(a,'C:\\A.coco2pack','verified-A'),false);
  const b=gate.begin();
  assert.equal(gate.accept(b,'D:\\B.coco2pack.zip','verified-B'),true);
  assert.equal(gate.beginCommit(b,'D:\\B.coco2pack.zip','verified-B'),true);
});

test('strict path+reviewToken binding, empty token denial and idempotent commit lock',()=>{
  const gate=createPortableReviewGate();
  const a=gate.begin();
  assert.equal(gate.accept(a,'C:\\a.coco2pack',''),false);
  assert.equal(gate.accept(a,'C:\\a.coco2pack','   '),false);
  assert.equal(gate.accept(a,'C:\\a.coco2pack',undefined),false);
  assert.equal(gate.beginCommit(a,'C:\\a.coco2pack',''),false);
  assert.equal(gate.accept(a,'C:\\a.coco2pack','trusted-rust-review'),true);
  assert.equal(gate.beginCommit(a,'C:\\b.coco2pack','trusted-rust-review'),false);
  assert.equal(gate.beginCommit(a,'C:\\a.coco2pack','wrong-token'),false);
  assert.equal(gate.beginCommit(a,'C:\\a.coco2pack','trusted-rust-review'),true);
  assert.equal(gate.beginCommit(a,'C:\\a.coco2pack','trusted-rust-review'),false);
  assert.equal(gate.begin(),null,'cannot switch files during already-authorized commit');
  assert.equal(gate.discard(),false,'cannot pretend to undo an already-running native commit');
  gate.finishCommit();
  assert.equal(gate.beginCommit(a,'C:\\a.coco2pack','trusted-rust-review'),false);
  assert.equal(gate.discard(),true);
});

test('file picker, incoming activation and commit all fence asynchronous native promises',()=>{
  assert.match(hub,/hostStudioAvailable=false/);
  assert.match(hub,/hostCanImportNow\.current=hostCanImport/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|checking\|\|importing/);
  assert.match(hub,/reviewGate\.current\.begin\(\)/);
  assert.match(hub,/if\(!reviewGate\.current\.isCurrent\(ticket\)\)return/);
  assert.match(hub,/reviewGate\.current\.accept\(ticket,incomingPath,result\.reviewToken\)/);
  assert.match(hub,/reviewGate\.current\.accept\(ticket,selected,result\.reviewToken\)/);
  assert.match(hub,/if\(pendingReview\.current===ticket\)/);
  assert.match(hub,/const retryIncomingReview=async\(\)=>\{/);
  assert.match(hub,/incomingNow\.current===incomingPath&&[\s\S]*?reviewGate\.current\.accept\(ticket,incomingPath,checked\.reviewToken\)/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|!review\|\|!confirmed\|\|checking\|\|importing/);
  assert.match(hub,/reviewGate\.current\.beginCommit\(reviewTicket,sourcePath,review\.reviewToken\)/);
  assert.match(hub,/path:sourcePath,reviewToken:review\.reviewToken,confirmed:true/);
  assert.match(hub,/reviewGate\.current\.finishCommit\(\)/);
  assert.match(hub,/No se recibió una revisión válida/);
  assert.match(hub,/reviewGate\.current\.discard\(\)/);
  assert.match(hub,/incomingNow\.current&&incomingNow\.current!==sourcePath/);
  assert.match(hub,/result\.status!=='updated'&&result\.status!=='unchanged'/);
  assert.doesNotMatch(hub,/invoke\([^\n]*launch|invoke\([^\n]*execute/i);
});

test('canceling file dialog and dismissing inbox cannot import silently',()=>{
  const picker=hub.indexOf('const selected=await open(');
  const dismissed=hub.indexOf("if(typeof selected!=='string')",picker);
  const extension=hub.indexOf('!isPortablePackageFile(selected)',dismissed);
  const review=hub.indexOf("invoke<LocalPackageReview>('review_local_publish_package'",picker);
  const importCall=hub.indexOf("invoke<ChannelStatus>('import_local_publish_package'");
  assert.ok(picker>=0&&dismissed>picker&&extension>dismissed&&review>extension&&importCall>review);
  assert.match(hub,/if\(!legacyFolder&&!isPortablePackageFile\(selected\)\)/);
  assert.match(hub,/No se aceptan ZIP genéricos/);
  assert.match(hub,/const discardReview=\(\)=>\{[\s\S]*?if\(!reviewGate\.current\.discard\(\)\)return/);
  assert.match(hub,/onClick=\{discardReview\}/);
  assert.match(hub,/Descartar sin importar/);
  assert.match(hub,/Volver a revisar/);
  assert.match(hub,/disabled=\{stage==='committing'\}/);
  assert.match(hub,/role="dialog" aria-label=\{hostCanImport\?'Confirmar importación local':'Revisión de paquete sin importar'\} onKeyDown=\{handleReviewKeys\}/);
  assert.match(hub,/hostCanImport&&<label className="catalog-consent"/);
  assert.match(hub,/hostCanImport&&<button className="primary-button" disabled=\{!confirmed\|\|importing\}/);
});

test('visual review makes provenance, version, safety, and idempotent result explicit',()=>{
  for(const phrase of [
    'Compartido por otra persona','No equivale a un juego del canal oficial firmado',
    'No se aceptan ZIP genéricos','Cambios de esta versión','Información del ejecutable',
    'Comprobado localmente','Revisé el nombre, la versión y el origen',
    'No se modificó tu biblioteca','No se ejecuta',
  ]){
    // Native side effects are forbidden before approval. UX can describe
    // execution in negative wording without exposing technical hashes.
    if(phrase==='No se ejecuta')assert.match(hub,/no ejecuta el juego/i);
    else assert.ok(hub.includes(phrase),phrase);
  }
  assert.match(hub,/result\.status==='unchanged'\?'Sin cambios/);
  assert.match(hub,/try\{onImported\?\.\(importedId\);\}catch\(error\)/);
  assert.match(hub,/try\{onInboxDone\?\.\(incomingPath\);\}catch\(error\)/);
  assert.match(hub,/review\.coverDataUrl\?\.startsWith\('data:image\/'\)/);
  assert.match(hub,/review\.changedFields\.slice\(0,12\)/);
  assert.doesNotMatch(hub,/\{review\.archiveSha256\}|\{review\.manifestSha256\}|\{review\.reviewToken\}/);
  assert.match(hub,/Archivo externo · Sin aprobación/);
  assert.match(hub,/Solo el anfitrión puede agregar juegos al catálogo firmado/);
});
