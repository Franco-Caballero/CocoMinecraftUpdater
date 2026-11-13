import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
async function gateModule(){
  const js=ts.transpileModule(await read('src/catalog-refresh-gate.ts'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{exports:module.exports,module,console});
  return module.exports;
}
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const flush=async()=>{for(let n=0;n<4;n++)await Promise.resolve();};

test('native accepted catalog paints before the optional disk/provenance reads finish',async()=>{
  const {CatalogRefreshGate,publishVerifiedCatalog}=await gateModule();
  const gate=new CatalogRefreshGate(),disk=deferred(),seen=[];
  const accepted=await publishVerifiedCatalog(gate,
    async()=>[{id:'friend',name:'Juego importado'}],
    items=>items.some(x=>x.id==='friend'),
    items=>seen.push(`paint:${items[0].id}`),
    async isCurrent=>{await disk.promise;if(isCurrent())seen.push('disk');},
  );
  assert.equal(accepted,true);
  assert.deepEqual(seen,['paint:friend'],'UI must not wait for physical drive inspection');
  disk.resolve();await flush();
  assert.deepEqual(seen,['paint:friend','disk']);
});

test('an older overlapping native refresh cannot roll back a newer import or restore stale badges',async()=>{
  const {CatalogRefreshGate,publishVerifiedCatalog}=await gateModule();
  const gate=new CatalogRefreshGate(),slow=deferred(),oldBadge=deferred(),events=[];
  const older=publishVerifiedCatalog(gate,()=>slow.promise,()=>true,
    () => events.push('STALE catalog'),async()=>{events.push('STALE badge');});
  const newer=publishVerifiedCatalog(gate,async()=>[{id:'B',name:'Version B'}],()=>true,
    entries=>events.push('paint '+entries[0].id),async isCurrent=>{await oldBadge.promise;if(isCurrent())events.push('badge B');});
  assert.equal(await newer,true);
  slow.resolve([{id:'A',name:'old'}]);
  assert.equal(await older,false,'outdated read cannot overwrite a newer accepted catalog');
  oldBadge.resolve();await flush();
  assert.deepEqual(events,['paint B','badge B']);
  gate.invalidate();
  assert.equal(gate.current(2),false);
});

test('invalid native catalog is rejected before mutation, while optional disk failures do not rollback it',async()=>{
  const {CatalogRefreshGate,publishVerifiedCatalog}=await gateModule();
  const gate=new CatalogRefreshGate(),events=[];
  await assert.rejects(publishVerifiedCatalog(gate,async()=>[],entries=>entries.length>0,
    ()=>events.push('paint'),async()=>{}),/Catálogo nativo inválido/);
  assert.deepEqual(events,[]);
  assert.equal(await publishVerifiedCatalog(gate,async()=>[{id:'A'}],entries=>entries.length>0,
    ()=>events.push('paint'),async()=>{throw Error('read-only disk probe failed');}),true);
  assert.deepEqual(events,['paint']);
});

test('after an import the verified catalog snapshot replaces a second native get_catalog request and preserves game-open consent',async()=>{
  const ui=await read('src/main.tsx');
  const start=ui.indexOf('const refreshNativeCatalog=async()=>{');
  const end=ui.indexOf('\n  useEffect(()=>{',start);
  const fragment=ui.slice(start,end);
  assert.match(fragment,/publishVerifiedCatalog\(/);
  assert.match(fragment,/trustedCatalogSnapshot\.current=new Map\(\)/);
  assert.match(fragment,/trustedCatalogSnapshot\.current=nextById/);
  assert.match(fragment,/setItems\(\[\.\.\.result\]\)/);
  assert.match(fragment,/setLocalInstances\(new Map\(\)\)/);
  assert.match(fragment,/Promise\.allSettled/);
  const openStart=ui.indexOf('const openImportedGame=(id:string)=>{');
  const openEnd=ui.indexOf('\n  const dismissWelcome=',openStart);
  const open=ui.slice(openStart,openEnd);
  assert.match(open,/trustedCatalogSnapshot\.current\.get\(id\)/);
  assert.match(open,/verified\?\.workflow==='coco-standalone'/);
  assert.doesNotMatch(open,/invoke\(|installNative|launchNative|import_local_publish_package/);
});
