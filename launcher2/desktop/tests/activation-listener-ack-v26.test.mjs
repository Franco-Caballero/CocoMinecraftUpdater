import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [native,ui,commands]=await Promise.all([
  readFile(resolve(root,'src-tauri/src/services/activation.rs'),'utf8'),
  readFile(resolve(root,'src/main.tsx'),'utf8'),
  readFile(resolve(root,'src-tauri/src/lib.rs'),'utf8'),
]);

test('native warm activation retains FIFO until explicit frontend take, never treats app.emit as ACK',()=>{
  const queue=native.slice(native.indexOf('fn queue(requests:'),native.indexOf('/// Attach from tauri Builder.setup'));
  assert.ok(queue.length>300);
  assert.match(queue,/select_requests\(&mut current,requests,Instant::now\(\),false\)/);
  assert.match(queue,/app\.emit\(PACKAGE_OPEN_EVENT,\(\)\)/,
    'wake events carry no unreviewed file path and cannot themselves acknowledge delivery');
  assert.doesNotMatch(queue,/deliver_with_fallback|select_with_backlog|current\.items\.drain/);
});

test('a cold frontend drain never marks UI subscription ready before it actually exists',()=>{
  const take=native.slice(native.indexOf('pub fn take_pending_package_open_requests()'),native.indexOf('pub fn shutdown_activation()'));
  assert.doesNotMatch(take,/state\.ready\s*=\s*true/);
  assert.match(native,/pub fn confirm_package_open_listener_ready\(\)->bool/);
  assert.match(commands,/services::activation::confirm_package_open_listener_ready/);
});

test('React subscribes before signaling readiness, wakes native drain from event, and keeps early cold drain',()=>{
  const effect=ui.slice(ui.indexOf('// Explorer activation carries untrusted paths'),ui.indexOf('// Reconcile interrupted native operations'));
  assert.match(effect,/listen<unknown>\('coco2:\/\/package-open-request',_event=>void drain\.trigger\(\)\)/);
  assert.match(effect,/await drain\.trigger\(\);[\s\S]*?invoke<boolean>\('confirm_package_open_listener_ready'\)/);
  assert.match(effect,/window\.addEventListener\('focus',refocus\)/);
  assert.match(effect,/document\.addEventListener\('visibilitychange',refocus\)/);
  assert.match(effect,/void drain\.trigger\(\);\s*return\(\)=>/);
  assert.doesNotMatch(effect,/import_local_publish_package|install_standalone\(|launch_standalone\(/);
});

// Execute the actual useEffect and PackageActivationDrain implementations under
// an async fake Tauri event bus. Only local arrays/promise gates, no Explorer,
// registry, browser, installer, processes or user data.
const ast=ts.createSourceFile('main.tsx',ui,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
let actualActivationEffect;
function findEffect(node){
  if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&
    node.arguments[0]?.getText(ast).includes('confirm_package_open_listener_ready'))
    actualActivationEffect=node.arguments[0].getText(ast);
  ts.forEachChild(node,findEffect);
}
findEffect(ast);
assert.ok(actualActivationEffect,'activation effect source exists');
const transpile=code=>ts.transpileModule('('+code+')',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
const drainSource=await readFile(resolve(root,'src/package-activation-drain.ts'),'utf8');
const drainModule={exports:{}};
vm.runInNewContext(ts.transpileModule(drainSource,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,
  {module:drainModule,exports:drainModule.exports,setTimeout,clearTimeout});
const turn=()=>new Promise(resolve=>setImmediate(resolve));

function scenario(){
  const paths=[];
  const seen=[];
  let wake;
  let subscribed=false;
  let confirmed=false;
  let stopCount=0;
  let pendingFirstRead;
  let reads=0;
  const events=new Map();
  const ctx={
    isTauri:()=>true,
    PackageActivationDrain:drainModule.exports.PackageActivationDrain,
    MAX_PENDING_PACKAGES:96,
    activationDrainRef:{current:null},
    inboxLive:{current:{paths:[],dropped:0}},
    extractPackagePaths:v=>Array.isArray(v)?v.map(x=>x.path):[],
    isPortablePackageFile:p=>p.endsWith('.coco2pack'),
    setPackagePickerRequest:()=>{},
    enqueuePackageRequests:(old,value)=>({paths:[...old.paths,...value.filter(p=>!old.paths.includes(p))],dropped:0}),
    commitInbox:next=>{ctx.inboxLive.current=next;seen.push(...next.paths.slice(seen.length));return true;},
    console:{warn:()=>{}},
    window:{addEventListener:(name,fn)=>events.set(`window:${name}`,fn),removeEventListener:(name)=>events.delete(`window:${name}`)},
    document:{hidden:false,addEventListener:(name,fn)=>events.set(`document:${name}`,fn),removeEventListener:(name)=>events.delete(`document:${name}`)},
    listen:(_name,fn)=>new Promise((resolve,reject)=>{
      wake=()=>fn({payload:undefined});
      ctx.finishSubscribe=()=>{subscribed=true;resolve(()=>{stopCount++;subscribed=false;});};
      ctx.rejectSubscribe=()=>reject(Error('synthetic listener unavailable'));
    }),
    invoke:async (command,args)=>{
      if(command==='confirm_package_open_listener_ready'){
        assert.ok(subscribed,'native readiness cannot precede listener');
        confirmed=true;
        return true;
      }
      if(command==='acknowledge_pending_package_open_requests'){
        assert.deepEqual(Array.from(args.paths),paths.slice(0,args.paths.length).map(item=>item.path));
        paths.splice(0,args.paths.length);
        return true;
      }
      assert.equal(command,'peek_pending_package_open_requests');
      reads++;
      const batch=paths.slice();
      if(reads===1)await new Promise(resolve=>{pendingFirstRead=resolve;});
      return batch;
    },
  };
  const effect=vm.runInNewContext(transpile(actualActivationEffect),ctx,{timeout:1000});
  const cleanup=effect();
  return {ctx,paths,seen,events,cleanup,
    deliver:path=>{paths.push({path,source:'warm'});if(confirmed&&subscribed)wake();},
    finishSubscribe:()=>ctx.finishSubscribe(),
    rejectSubscribe:()=>ctx.rejectSubscribe(),
    finishFirstRead:()=>pendingFirstRead?.(),
    get reads(){return reads;},
    get confirmed(){return confirmed;},
    get stopCount(){return stopCount;},
  };
}

test('actual React activation effect survives cold read pending while listener registers and warm requests arrive',async()=>{
  const s=scenario();
  const base='C:\\Synthetic\\';
  // Cold read is paused; subsequent native queue additions are not emitted
  // until the listener explicitly confirms readiness.
  s.deliver(`${base}Cold.coco2pack`);
  s.finishSubscribe();
  s.deliver(`${base}Before ack 💜.coco2pack`);
  s.finishFirstRead();
  await turn();await turn();await turn();
  assert.ok(s.confirmed);
  s.deliver(`${base}Warm 漢字.coco2pack`);
  await turn();await turn();
  assert.deepEqual(s.seen,[`${base}Cold.coco2pack`,`${base}Before ack 💜.coco2pack`,`${base}Warm 漢字.coco2pack`]);
  assert.ok(s.reads>=3,'cold, post-subscribe, and post-ACK drains occurred');
  s.cleanup();
  assert.equal(s.stopCount,1);
});

test('listener subscription failure leaves native paths for focus fallback, never confirms ready',async()=>{
  const s=scenario();
  s.deliver('C:\\Synthetic\\Recovery.coco2pack');
  s.rejectSubscribe();
  s.finishFirstRead();
  await turn();
  s.events.get('window:focus')();
  await turn();await turn();
  assert.deepEqual(s.seen,['C:\\Synthetic\\Recovery.coco2pack']);
  s.cleanup();
  assert.equal(s.confirmed,false);
  assert.equal(s.stopCount,0,'failed listener cannot return an unsubscribe callback');
  assert.equal(s.events.size,0);
});
