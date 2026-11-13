import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(root,name),'utf8');
async function load(path){
  const js=ts.transpileModule(await read(path),{compilerOptions:{
    module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
  }}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}
const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};

test('focus during cold activation queue read triggers second authoritative drain without duplicate import',async()=>{
  const {PackageActivationDrain}=await load('src/package-activation-drain.ts');
  const {enqueuePackageRequests,emptyPackageInbox}=await load('src/package-inbox.ts');
  let reads=0,imports=0,state=emptyPackageInbox();
  const first=deferred();
  const queue=[
    'C:\\Amigo\\Juego_日本語.coco2pack',
    'C:\\Amigo\\Otro.coco2pack',
  ];
  const drain=new PackageActivationDrain(async()=>{
    const i=++reads;
    if(i===1)return first.promise;
    return queue.splice(0);
  },value=>{state=enqueuePackageRequests(state,value);},error=>{throw error;});
  const pending=drain.trigger();
  drain.trigger(); // focus while previous take_pending is unresolved
  first.resolve([queue.shift()]);
  await pending;
  assert.equal(reads,2);
  assert.equal(state.paths.length,2);
  assert.equal(state.paths[0],'C:\\Amigo\\Juego_日本語.coco2pack');
  assert.equal(state.paths[1],'C:\\Amigo\\Otro.coco2pack');
  assert.equal(imports,0,'native queue is display-only, not a commit');
  drain.dispose();
});

test('128 focus bursts perform at most four coalesced native reads, not a 128-read IPC storm',async()=>{
  const {PackageActivationDrain}=await load('src/package-activation-drain.ts');
  const pending=[];
  let count=0;
  const drain=new PackageActivationDrain(async()=>{
    count++;
    const next=deferred();pending.push(next);return next.promise;
  },()=>{},()=>{});
  const run=drain.trigger();
  for(let k=0;k<128;k++)drain.trigger();
  pending[0].resolve([]);
  for(let i=0;i<4;i++)await Promise.resolve();
  assert.equal(count,2);
  for(let k=0;k<128;k++)drain.trigger();
  pending[1].resolve([]);
  for(let i=0;i<4;i++)await Promise.resolve();
  assert.equal(count,3);
  pending[2].resolve([]);
  await run;
  assert.equal(count,3,'coalesces second burst into another pass');
  drain.dispose();
});

test('failed native read does not permanently lock the inbox and next focus can retry',async()=>{
  const {PackageActivationDrain}=await load('src/package-activation-drain.ts');
  let reads=0;const observed=[],errors=[];
  const drain=new PackageActivationDrain(async()=>{
    if(++reads===1)throw Error('Tauri bridge warming');
    return [{path:'C:\\Trusted\\Game.coco2pack'}];
  },value=>observed.push(value),error=>errors.push(String(error)));
  await drain.trigger();
  assert.equal(errors.length,1);
  await drain.trigger();
  assert.equal(reads,2);
  assert.equal(observed.length,1);
  drain.dispose();
});

test('abandoned React view ignores native read completion; no stale inbox insertion',async()=>{
  const {PackageActivationDrain}=await load('src/package-activation-drain.ts');
  const slow=deferred();
  let shown=0;
  const drain=new PackageActivationDrain(()=>slow.promise,()=>shown++,()=>{});
  const work=drain.trigger();
  drain.dispose();
  slow.resolve(['C:\\Other\\Never.coco2pack']);
  await work;
  assert.equal(shown,0);
  await drain.trigger();
  assert.equal(shown,0);
});

test('React attaches recovery listeners BEFORE async Tauri subscribe and starts cold drain independently',async()=>{
  const ui=await read('src/main.tsx');
  const begin=ui.indexOf("const drain=new PackageActivationDrain<unknown>");
  const end=ui.indexOf('},[]);',begin);
  assert.ok(begin>0&&end>begin);
  const effect=ui.slice(begin,end);
  const listen=effect.indexOf("listen<unknown>('coco2://package-open-request'");
  const focus=effect.indexOf("window.addEventListener('focus',refocus)");
  assert.ok(focus>=0&&focus<listen,'focus fallback must not depend on listener success');
  assert.match(effect,/void drain\.trigger\(\);\s*return\(\)=>/);
  assert.match(effect,/drain\.dispose\(\)/);
  assert.doesNotMatch(effect,/import_local_publish_package|install_standalone|launch_standalone/);
});
