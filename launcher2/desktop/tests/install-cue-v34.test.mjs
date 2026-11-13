// Installing from a game's sheet: the sheet folds into the library, the side panel keeps the
// finished game ready to play, and its card lifts above the others until the player moves on.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
async function load(path){
  const js=ts.transpileModule(await read(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{exports:module.exports,module,require:()=>({})});
  return module.exports;
}
const idle={update:{stage:'idle',version:'',percent:0,message:''},operation:null,mediaDownload:null,launching:null,playing:[],
  processUncertain:false,uninstalling:null,authorizing:false,startingSteam:false,pendingRecovery:0,arrival:null,catalog:'current',catalogLoaded:true};

test('a finished install stays in the panel as ready to play, below anything still happening',async()=>{
  const {deriveLauncherStatus:status}=await load('src/launcher-status.ts');
  const ready=status({...idle,installed:{name:'PEAK'}});
  assert.equal(ready.tone,'installed');
  assert.equal(ready.label,'Instalado');
  assert.equal(ready.subject,'PEAK');
  assert.equal(ready.percent,100,'the finished bar stays full instead of disappearing');
  const another={kind:'install',name:'REPO',description:'Descargando',percent:12,rate:''};
  assert.equal(status({...idle,installed:{name:'PEAK'},operation:another}).label,'Instalando','a new operation takes the panel');
  assert.equal(status({...idle,installed:{name:'PEAK'},playing:['REPO']}).tone,'playing');
  assert.equal(status({...idle,installed:{name:'PEAK'},arrival:'Pilgrim'}).tone,'installed','the finished install outranks routine news');
  assert.equal(status({...idle,installed:null}).label,'Listo para jugar');
});

test('installing from the sheet folds it only once the install really started, and failures bring it back',async()=>{
  const ui=await read('src/main.tsx');
  assert.match(ui,/if\(primaryGame\.kind==='install'\)foldOnInstall\.current=\{id:selected\.id,at:Date\.now\(\)\}/);
  assert.match(ui,/if\(!request\|\|installing!==request\.id/,'the fold waits for the install to be under way');
  const install=ui.slice(ui.indexOf('const installNative=async(entry:Experience)=>{'),ui.indexOf('const cancelInstall='));
  assert.match(install,/result\.status!=='installed'&&result\.status!=='cancelled'&&!selectedRef\.current\)openDetails\(entry\)/);
  assert.match(install,/catch\(error\)\{\s*if\(!selectedRef\.current\)openDetails\(entry\);\s*explainFailedNativeWrite/);
  assert.match(install,/setInstalledCue\(\{id:entry\.id,path:result\.instancePath\}\);\s*setSpotlightId\(entry\.id\)/);
});

test('the lifted card is brought into view and settles when the player moves on',async()=>{
  const ui=await read('src/main.tsx');
  assert.match(ui,/scrollIntoView\(\{behavior:motion\?'smooth':'auto',block:'center'\}\)/);
  assert.match(ui,/target\?\.closest\('\.experience-card\.is-spotlit,\.coco-status'\)/,'clicks on the card or the panel keep it lifted');
  assert.match(ui,/if\(opened\|\|!installedIds\.has\(installedCue\.id\)\)dismissInstalledCue\(\)/,'playing or uninstalling ends the cue');
  const css=await read('src/install-cue.css');
  assert.match(css,/\.detail-drawer\.is-closing\{animation:coco-cue-sheet-out/);
  assert.match(css,/\.experience-card\.is-spotlit\{z-index:7\}/,'the lifted card covers its neighbours');
  assert.match(ui,/import '\.\/install-cue\.css';/);
});
