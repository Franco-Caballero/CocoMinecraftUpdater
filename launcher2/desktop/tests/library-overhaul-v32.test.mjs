// The rules behind the side-panel library: previews allowed by the real CSP, one
// library for every entry, a single launcher status, and gliding grid changes.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
async function load(path,context={}){
  const js=ts.transpileModule(await read(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{exports:module.exports,module,require:()=>({}),...context});
  return module.exports;
}
const plain=value=>JSON.parse(JSON.stringify(value));

const game=(id,name=id)=>({id,name,workflow:'coco-standalone'});
const movie=(id)=>({id,name:id,workflow:'coco-media'});
const pack=(id)=>({id,name:id,workflow:'coco-managed'});

test('the CSP allows Steam clips, cached files and the fast IPC channel, and nothing broader',async()=>{
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  const csp=config.app.security.csp;
  const media=csp.match(/media-src ([^;]+)/)[1];
  for(const source of ['https://cdn.akamai.steamstatic.com','https://shared.akamai.steamstatic.com','https://video.akamai.steamstatic.com','asset:','http://asset.localhost'])
    assert.ok(media.includes(source),`media-src must allow ${source}`);
  assert.doesNotMatch(media,/https:(\s|$)|\*\./,'no wildcard media host');
  assert.match(csp,/connect-src [^;]*ipc: http:\/\/ipc\.localhost/,'without it every native call falls back to postMessage');
  assert.deepEqual(plain(config.app.security.assetProtocol),
    {enable:true,scope:['$LOCALDATA/CocoMinecraftUpdater/preview-cache/*']},'file access stays limited to the clip cache');
});

test('Coco 2 feeds never share the Latest release with Coco 1',async()=>{
  const channel=await read('src-tauri/src/services/catalog_channel.rs');
  assert.doesNotMatch(channel,/releases\/latest\/download\/coco2/);
  assert.match(channel,/releases\/download\/coco2-channel\/coco2-catalog-channel\.json"/);
});

test('one library: filters, newest first, Minecraft last and never counted as latest',async()=>{
  const {sortLibrary,matchesLibraryFilter,latestAddition,isComingSoon}=await load('src/library-view.ts');
  const entries=[pack('mine'),game('old','Zeta'),movie('film'),game('new','Alfa')];
  assert.deepEqual(plain(sortLibrary(entries,'recent').map(x=>x.id)),['new','film','old','mine']);
  assert.deepEqual(plain(sortLibrary(entries,'name').map(x=>x.id)),['new','film','old','mine']);
  assert.equal(latestAddition(entries).id,'new');
  assert.equal(latestAddition([pack('mine')]),null);
  assert.equal(isComingSoon(pack('x')),true);
  assert.equal(isComingSoon({id:'o',name:'o',workflow:'external-launcher'}),true);
  const none=new Set();
  assert.equal(matchesLibraryFilter(movie('m'),'games',none,none),false);
  assert.equal(matchesLibraryFilter(pack('m'),'games',none,none),true);
  assert.equal(matchesLibraryFilter(movie('m'),'movies',none,none),true);
  assert.equal(matchesLibraryFilter(game('g'),'installed',none,new Set(['g'])),true);
  assert.equal(matchesLibraryFilter(game('g'),'favorites',none,none),false);
});

test('the first catalog is the baseline; only later arrivals count as new',async()=>{
  const {unseenEntries}=await load('src/library-view.ts');
  assert.deepEqual(plain(unseenEntries(['a','b'],null)),[]);
  assert.deepEqual(plain(unseenEntries(['a','b'],new Set(['a']))),['b']);
});

const idle={update:{stage:'idle',version:'',percent:0,message:''},operation:null,mediaDownload:null,launching:null,playing:[],
  processUncertain:false,uninstalling:null,authorizing:false,startingSteam:false,pendingRecovery:0,arrival:null,catalog:'current',catalogLoaded:true};

test('the panel always says one true thing, most important first',async()=>{
  const {deriveLauncherStatus:status}=await load('src/launcher-status.ts');
  assert.equal(status(idle).label,'Listo para jugar');
  assert.equal(status({...idle,catalogLoaded:false}).label,'Abriendo biblioteca');
  const syncing=status({...idle,catalog:'syncing'});
  assert.equal(syncing.label,'Listo para jugar','a background catalog check never flashes in the panel');
  assert.equal(syncing.detail,'');assert.equal(syncing.tone,'ready');
  assert.equal(status(idle).detail,'','no «al día» line after a check');
  assert.equal(status({...idle,uninstalling:'PEAK'}).label,'Desinstalando PEAK');
  assert.equal(status({...idle,startingSteam:true,launching:'PEAK'}).label,'Abriendo Steam');
  assert.equal(status({...idle,authorizing:true,operation:{kind:'install',name:'PEAK',description:'',percent:1,rate:''}}).label,'Autorización de Windows','the only thing waiting on the player comes first');
  assert.equal(status({...idle,arrival:'Pilgrim'}).detail,'Pilgrim');
  const install={kind:'install',name:'PEAK',description:'Descargando',percent:34,rate:'5 MB/s'};
  const installing=status({...idle,catalog:'syncing',arrival:'Pilgrim',operation:install});
  assert.equal(installing.label,'Instalando');assert.equal(installing.subject,'PEAK','the game name has its own line');assert.equal(installing.percent,34);
  assert.equal(installing.detail,'Descargando');assert.equal(installing.metrics,'5 MB/s','figures go on their own fixed line');
  assert.equal(status({...idle,playing:['PEAK']}).tone,'playing');
  assert.equal(status({...idle,update:{stage:'downloading',version:'1.0.0',percent:20,message:''},operation:install}).label,'Actualizando Coco');
  assert.equal(status({...idle,pendingRecovery:2}).tone,'attention');
});

test('an offline launcher reads as ready, not as an error',async()=>{
  const {deriveLauncherStatus:status}=await load('src/launcher-status.ts');
  const offline=status({...idle,catalog:'local'});
  assert.equal(offline.tone,'ready');
  assert.equal(offline.detail,'','an offline library needs no explanation');
});

test('existing cards glide and a new one is announced as entering',async()=>{
  const {planFlip}=await load('src/flip-grid.ts');
  const plan=plain(planFlip(new Map([['a',{left:0,top:0}],['b',{left:100,top:0}],['gone',{left:9,top:9}]]),
    new Map([['new',{left:0,top:0}],['a',{left:100,top:0}],['b',{left:100,top:0}]])));
  assert.deepEqual(plan,{moved:[{id:'a',dx:-100,dy:0}],entered:['new']});
});

test('a cached clip replaces streaming and an unreadable one falls back without losing the preview',async()=>{
  const pool=await read('src/hover-video-pool.ts');
  assert.match(pool,/if\(!clip\.video\.src\)clip\.video\.src=this\.sourceUrl\(id\)/);
  assert.match(pool,/if\(this\.usesLocalFile\(id\)\)\{\s*\/\/ An unreadable cached file[\s\S]*?this\.localFiles\.delete\(id\)/);
  const css=await read('src/coco-ui.css');
  assert.match(css,/\.card-video-unavailable::after\{content:none\}/,'a card without a clip simply keeps its cover');
});

test('opening the launcher does not wait on the network or on process probes',async()=>{
  const ui=await read('src/main.tsx');
  assert.match(ui,/useState<Experience\[\]>\(restoreCatalogSnapshot\)/,'cards exist on the very first render');
  assert.match(ui,/introStage!=='done'&&introStage!=='none'[\s\S]*?window\.setTimeout\([\s\S]*?prepare_windows/,'the Windows prompt waits for the presentation, never for the network');
  assert.doesNotMatch(ui,/coco2-last-catalog-attempt/,'a new game must not wait six hours');
  for(const [file,command] of [['inventory.rs','get_local_instances'],['identity.rs','get_local_identity'],['media.rs','get_media_catalog'],['install.rs','plan_standalone_install']]){
    const source=await read(`src-tauri/src/services/${file}`);
    assert.match(source,new RegExp(`pub async fn ${command}\\(`),`${command} must leave the UI thread`);
  }
});
