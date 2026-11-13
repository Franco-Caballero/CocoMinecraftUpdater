import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
const source=await read('src/HostStudio.tsx');
const ast=ts.createSourceFile('HostStudio.tsx',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);

// Run the actual pure frontend helpers in Node, not copies of their logic.
// Extract just the functions to avoid importing Tauri, React or a browser.
const helperNames=['suggestedPortableFileName','isPortableSavePath','portableExportError','portableFriendMessage'];
const declarations=ast.statements.filter(statement=>
  ts.isFunctionDeclaration(statement)&&helperNames.includes(statement.name?.text));
assert.equal(declarations.length,helperNames.length,'frontend helper definitions must be present');
const helperSource=declarations.map(fn=>fn.getText(ast).replace(/^export\s+/,'')).join('\n');
const emitted=ts.transpileModule(helperSource,{
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None},
  reportDiagnostics:true,
});
assert.deepEqual(emitted.diagnostics??[],[],'pure helper TypeScript should transpile');
const helpers=runInNewContext(`${emitted.outputText}\n({${helperNames.join(',')}})`);
const {suggestedPortableFileName,isPortableSavePath,portableExportError,portableFriendMessage}=helpers;

test('Guardar como proposes one safe .coco2pack name, even with problematic game/version text',()=>{
  assert.equal(suggestedPortableFileName('my-game','1.2.3'),'my-game-1.2.3.coco2pack');
  assert.equal(suggestedPortableFileName('../Game Name','1/2:3'),'Game-Name-1-2-3.coco2pack');
  assert.equal(suggestedPortableFileName('///','..'),'experiencia-coco.coco2pack');
  const long=suggestedPortableFileName('A'.repeat(250),'B'.repeat(250));
  assert.match(long,/^[A-Z-]+\.coco2pack$/);
  assert.ok(long.length<=110,'long names must fit a typical Save As field');
  assert.doesNotMatch(long,/\.zip/i,'exported file names must not claim .zip');
});

test('selected destination must end with exactly .coco2pack, with no unsafe filename',()=>{
  for(const allowed of ['C:\\Users\\Demo\\Downloads\\pack.coco2pack',
    'D:\\Juegos\\Juego con espacios.COCO2PACK','/home/demo/coco.coco2pack']){
    assert.equal(isPortableSavePath(allowed),true,allowed);
  }
  for(const rejected of ['C:\\Downloads\\pack.coco2pack.zip',
    'C:\\Downloads\\pack.zip','C:\\Downloads\\pack.coco2pack.exe',
    '.coco2pack','C:\\Downloads\\a?.coco2pack','C:\\Downloads\\bad|name.coco2pack',
    'C:\\Downloads\\pack.coco2pack ','']){
    assert.equal(isPortableSavePath(rejected),false,rejected);
  }
});

test('native failures are explained in plain Spanish without leaking technical diagnostics',()=>{
  const scenarios=[
    ['Portable export target already exists; never overwrite',/Ya existe un archivo/],
    ['Portable package already exported; never overwrite',/Ya existe un archivo/],
    ['No space left on device',/No hay espacio suficiente/],
    ['Access denied (os error 5)',/No se puede escribir/],
    ['Portable export directory does not exist',/carpeta elegida/],
    ['Cannot export inside a sealed source package',/carpeta elegida/],
    ['Portable export requires a local file, not UNC\/device paths',/carpeta de tu equipo/],
    ['Sealed archive content changed',/paquete preparado cambió/],
  ];
  for(const [native,explanation] of scenarios){
    const translated=portableExportError(native,'export');
    assert.match(translated,explanation,native);
    assert.doesNotMatch(translated,/sha256|json|os error|traceback|\\\\|[a-f\d]{64}/i);
  }
  assert.match(portableExportError(new Error('unknown'), 'picker'),/Guardar como/);
  assert.match(portableExportError(new Error('unknown'), 'export'),/copia/);
});

test('friend message contains the file name and safe, review-before-import instructions',()=>{
  const text=portableFriendMessage('C:\\Descargas\\Juego-1.0.coco2pack');
  assert.match(text,/Juego-1\.0\.coco2pack/);
  assert.match(text,/Juegos → Abrir paquete Coco/);
  assert.match(text,/Revisa el contenido y acepta/);
  assert.match(text,/No necesitas extraer/);
  assert.doesNotMatch(text,/SHA256|\.json|GitHub|publicado/i);
});

test('Save As cancellation and failed destination do not call native export',()=>{
  const picker=source.indexOf('const destination=await save({');
  const canceled=source.indexOf('if(!destination)',picker);
  const invalid=source.indexOf('if(!isPortableSavePath(destination))',picker);
  const call=source.indexOf("invoke<PortableExport>('export_portable_standalone_package'",picker);
  assert.ok(picker>=0&&canceled>picker&&invalid>canceled&&call>invalid,
    'file dialog cancellation and extension checks must precede native export');
  assert.match(source,/if\(!publishArtifact\|\|busy\|\|exportPendingRef\.current\)return/);
  assert.match(source,/exportPendingRef\.current=true/);
  assert.match(source,/exportPendingRef\.current=false;setExportPhase\('idle'\);setBusyLabel\(''\);setBusy\(false\)/);
  assert.match(source,/if\(!destination\)\{\s*setExportNotice\('Guardado cancelado/);
  assert.match(source,/id:publishArtifact\.id,artifactPath:publishArtifact\.artifactPath,destinationPath:destination/);
  assert.match(source,/status!=='exported-local-untrusted-unpublished'/);
  assert.match(source,/setExportNotice\('Archivo guardado en tu equipo\. Ya puedes enviarlo; nada se publicó ni se importó\.'/);
  assert.doesNotMatch(source,/invoke\('import_local_publish_package'[^\n]*exportPortable/);
});

test('exported and imported states remain distinct and the recipient gets usable instructions',()=>{
  for(const phrase of [
    'Guardar como .coco2pack',
    'Guardar otra copia',
    'Exportado · Un archivo listo para enviar',
    'todavía no está publicado ni se ha importado',
    'Juegos → Abrir paquete Coco',
    'No necesita extraer nada',
    'No se creó una copia nueva',
    'Copiar ubicación',
    'Copiar instrucciones',
    'La ubicación está seleccionada. Pulsa Ctrl+C',
  ])assert.ok(source.includes(phrase),`missing recipient or export UX: ${phrase}`);
  assert.match(source,/setLocalImported\(true\)/);
  assert.match(source,/\{localImported&&<p className="studio-local-success"/);
  assert.match(source,/ref=\{closeButtonRef\}/);
  assert.match(source,/onKeyDown=\{handleDialogKeys\}/);
  assert.match(source,/if\(event\.key==='Escape'&&!busy&&!exportPendingRef\.current\)/);
  assert.match(source,/if\(event\.key!=='Tab'\)return/);
  assert.match(source,/previous instanceof HTMLElement&&previous\.isConnected/);
  assert.match(source,/aria-live="polite"/);
  assert.match(source,/role="region" aria-label="Paquete exportado correctamente"/);
  assert.match(source,/<details className="studio-local-promote"><summary>Opciones avanzadas del host \(opcionales\)<\/summary>/);
  assert.doesNotMatch(source,/<pre>\{publishPreview\.catalogDiff\}<\/pre>/);
  assert.doesNotMatch(source,/<code>\{publishArtifact\.artifactPath\}<\/code>/);
});
