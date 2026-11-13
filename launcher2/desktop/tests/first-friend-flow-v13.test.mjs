import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const file=name=>readFile(resolve(root,name),'utf8');
const loaded=async name=>{
  const module={exports:{}};
  const js=ts.transpileModule(await file(name),{compilerOptions:{
    module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
  }}).outputText;
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
};

test('first-day package picker can only launch from a fresh explicit action, once per intent',async()=>{
  const {ManualPackagePickerGate}=await loaded('src/package-activation-drain.ts');
  const gate=new ManualPackagePickerGate();
  assert.equal(gate.consume(0),false,'rendering welcome never opens file picker');
  assert.equal(gate.consume(NaN),false);
  assert.equal(gate.consume(-1),false);
  assert.equal(gate.consume(1),true,'first button click opens picker');
  for(let i=0;i<100;i++)assert.equal(gate.consume(1),false,'StrictMode/re-renders cannot repeat picker');
  assert.equal(gate.consume(0),false,'resetting parent request does not arm another picker');
  assert.equal(gate.consume(2),true,'new human click can intentionally reopen');
  assert.equal(gate.consume(2),false);
});

test('host-only first-run package review requires authoring capability and never imports silently',async()=>{
  const [welcome,main,hub,css]=await Promise.all([
    file('src/FirstRun.tsx'),file('src/main.tsx'),file('src/CatalogHub.tsx'),file('src/experience-v2.css'),
  ]);
  assert.match(welcome,/onOpenPackage:\(\)=>void/);
  assert.match(welcome,/hostStudioAvailable&&<button[^\n]*onClick=\{onOpenPackage\}/);
  assert.match(welcome,/Los amigos solo reciben juegos aprobados en el catálogo firmado/);
  assert.match(main,/onOpenPackage=\{\(\)=>\{if\(hostStudioAvailable\)\{navigate\('settings'\);setPackagePickerRequest\(\+\+packagePickerSerial\.current\);\}\}\}/);
  assert.match(main,/LazyFirstRun hostStudioAvailable=\{hostStudioAvailable\}/);
  assert.match(main,/onPickerRequestConsumed=\{\(\)=>setPackagePickerRequest\(0\)\}/);
  assert.match(hub,/firstRunPickerGate\.current\.consume\(pickerRequestId\)/);
  assert.match(hub,/onPickerRequestConsumed\?\.\(\)/);
  assert.match(hub,/if\(!hostCanImportNow\.current\|\|incomingPath\|\|!isTauri\(\)\)return/);
  assert.match(hub,/hostStudioAvailable=false/);
  assert.match(hub,/void choosePackage\(\)/);
  assert.match(hub,/review_local_publish_package/);
  assert.match(hub,/!hostCanImportNow\.current\|\|!review\|\|!confirmed/);
  assert.match(hub,/reviewGate\.current\.beginCommit\(reviewTicket,sourcePath,review\.reviewToken\)/);
  assert.match(hub,/confirmed:true/);
  assert.match(css,/\.first-run-package-action/);
  assert.doesNotMatch(welcome,/invoke\(|startProcess|import_local_publish_package|install_standalone/);
});

test('client first-run receives host-curated catalog and cannot trigger package import intent',async()=>{
  const [welcome,main,hub]=await Promise.all([
    file('src/FirstRun.tsx'),file('src/main.tsx'),file('src/CatalogHub.tsx')]);
  assert.match(welcome,/hostStudioAvailable=false/);
  assert.match(welcome,/Todo lo que ves lo aprobó el anfitrión/);
  assert.match(welcome,/el anfitrión apruebe y publique juegos en el catálogo verificado/);
  assert.match(main,/pickerRequestId=\{hostStudioAvailable\?packagePickerRequest:0\}/);
  assert.match(hub,/hostCanImport&&!compact&&<details className="catalog-legacy-import"/);
  assert.match(hub,/hostCanImport&&<label className="catalog-consent"/);
  assert.match(hub,/hostCanImport&&<button className="primary-button" disabled=\{!confirmed\|\|importing\}/);
});

test('one library holds games, movies and paused Minecraft; Minecraft stays unplayable',async()=>{
  const main=await file('src/main.tsx');
  assert.match(main,/useState<View>\('library'\)/);
  assert.doesNotMatch(main,/view==='home'|className="summary-strip"/);
  assert.match(main,/matchesLibraryFilter\(x,filter,favorites,installedIds\)/);
  assert.match(main,/isComingSoon\(selected\)&&<button className="primary-button" disabled/,
    'a paused Minecraft entry shows in the library but can never start');
  assert.match(main,/x\.state==='folder-present'/);
  assert.match(main,/pendingOperations\.length>0&&<section className="coco-recovery-banner"/);
});

test('Defender diagnosis uses exact trusted native destination when present, without asserting quarantine',async()=>{
  const main=await file('src/main.tsx');
  assert.match(main,/installPlan\?\.id===selected\.id\?installPlan\.instancePath/);
  assert.match(main,/securityGuide\?\.id===selected\.id\?securityGuide\.folder/);
  assert.match(main,/Ruta de destino prevista por el motor de Coco \(no demuestra que exista o esté bloqueada\)/);
  assert.match(main,/Historial de protección/);
  assert.match(main,/Reintentar instalación/);
  assert.match(main,/!\['integrity','recovery'\]\.includes\(nativeFailure\.kind\)/);
  assert.match(main,/onClick=\{\(\)=>void installNative\(selected\)\}/);
  assert.match(main,/navigator\.clipboard\.writeText\(nativeDiagnosticPath\)/);
  assert.doesNotMatch(main,/Add-MpPreference|Set-MpPreference|DisableRealtimeMonitoring/);
});
