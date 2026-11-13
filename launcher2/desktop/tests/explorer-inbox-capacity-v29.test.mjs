/** An already-full React inbox must never ACK a native path it did not retain.
 * Exercise the actual main.tsx activation effect, real PackageActivationDrain
 * and real package-inbox.ts under a synthetic native FIFO. No real registry,
 * Explorer, application, games, disk mutation or external network. */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [main,drainSource,inboxSource]=await Promise.all([
  readFile(resolve(root,'src/main.tsx'),'utf8'),
  readFile(resolve(root,'src/package-activation-drain.ts'),'utf8'),
  readFile(resolve(root,'src/package-inbox.ts'),'utf8'),
]);
const compileModule=source=>{
  const mod={exports:{}};
  const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(js,{module:mod,exports:mod.exports,setTimeout,clearTimeout});
  return mod.exports;
};
const {PackageActivationDrain}=compileModule(drainSource);
const inbox=compileModule(inboxSource);
const ast=ts.createSourceFile('main.tsx',main,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
let effectSource='';
function visit(node){
  if(ts.isCallExpression(node)&&node.expression.getText(ast)==='useEffect'&&
    node.arguments[0]?.getText(ast).includes('confirm_package_open_listener_ready'))
    effectSource=node.arguments[0].getText(ast);
  ts.forEachChild(node,visit);
}
visit(ast);
assert.ok(effectSource,'the actual Explorer activation effect must exist');
const effectCode=ts.transpileModule('('+effectSource+')',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
const turn=()=>new Promise(resolve=>setImmediate(resolve));

async function scenario({alreadyInInbox,nativePaths}){
  const pending=[...nativePaths];
  const acknowledged=[];
  const events=new Map();
  const initial=inbox.enqueuePackageRequests(inbox.emptyPackageInbox(),alreadyInInbox);
  const ctx={
    isTauri:()=>true,
    PackageActivationDrain,
    MAX_PENDING_PACKAGES:inbox.MAX_PENDING_PACKAGES,
    activationDrainRef:{current:null},
    inboxLive:{current:initial},
    setPackagePickerRequest:()=>{},
    isPortablePackageFile:p=>p.toLowerCase().endsWith('.coco2pack'),
    extractPackagePaths:inbox.extractPackagePaths,
    enqueuePackageRequests:inbox.enqueuePackageRequests,
    commitInbox:next=>{ctx.inboxLive.current=next;return true;},
    console:{warn:()=>{}},
    window:{addEventListener:(name,fn)=>events.set(`window:${name}`,fn),removeEventListener:name=>events.delete(`window:${name}`)},
    document:{hidden:false,addEventListener:(name,fn)=>events.set(`document:${name}`,fn),removeEventListener:name=>events.delete(`document:${name}`)},
    listen:async(_name,callback)=>{
      ctx.notify=()=>callback({payload:undefined});
      return ()=>{};
    },
    invoke:async(command,args)=>{
      if(command==='peek_pending_package_open_requests')return pending.map(path=>({path,source:'warm'}));
      if(command==='acknowledge_pending_package_open_requests'){
        assert.ok(Array.isArray(args.paths));
        assert.deepEqual(Array.from(args.paths),pending.slice(0,args.paths.length));
        acknowledged.push(...args.paths);
        pending.splice(0,args.paths.length);
        return true;
      }
      if(command==='confirm_package_open_listener_ready')return true;
      throw Error('Unexpected synthetic native command '+command);
    },
  };
  const effect=vm.runInNewContext(effectCode,ctx,{timeout:1000});
  const cleanup=effect();
  for(let i=0;i<8;i++)await turn();
  return {ctx,pending,acknowledged,cleanup,async flush(){for(let i=0;i<8;i++)await turn();}};
}

const name=n=>`C:\\Synthetic\\Invitado-${String(n).padStart(3,'0')} 漢字.coco2pack`;

test('React with 95 reviews ACKs only one native entry; retains second in native FIFO until a card is dismissed',async()=>{
  const existing=Array.from({length:95},(_,i)=>name(i));
  const first=name(95),second=name(96);
  const s=await scenario({alreadyInInbox:existing,nativePaths:[first,second]});
  try{
    assert.equal(s.ctx.inboxLive.current.paths.length,96);
    assert.ok(s.ctx.inboxLive.current.paths.includes(first));
    assert.equal(s.ctx.inboxLive.current.paths.includes(second),false);
    assert.equal(s.ctx.inboxLive.current.dropped,0,'the native-held suffix is not a lost-path overflow');
    assert.deepEqual(s.acknowledged,[first]);
    assert.deepEqual(s.pending,[second],'native still owns every undisplayed package');

    s.ctx.commitInbox(inbox.dismissPackageRequest(s.ctx.inboxLive.current,existing[0]));
    assert.ok(s.ctx.activationDrainRef.current,'React must expose its mounted pump to a dismiss-triggered retry');
    await s.ctx.activationDrainRef.current.trigger();
    await s.flush();
    assert.equal(s.ctx.inboxLive.current.paths.length,96);
    assert.ok(s.ctx.inboxLive.current.paths.includes(second));
    assert.deepEqual(s.pending,[]);
    assert.deepEqual(s.acknowledged,[first,second]);
  }finally{s.cleanup();}
});

test('a full inbox only ACKs duplicate already visible in React, not a new blocked suffix',async()=>{
  const existing=Array.from({length:96},(_,i)=>name(i));
  const duplicate=existing[15],newRequest=name(97);
  const s=await scenario({alreadyInInbox:existing,nativePaths:[duplicate,newRequest]});
  try{
    assert.deepEqual(s.acknowledged,[duplicate]);
    assert.deepEqual(s.pending,[newRequest]);
    assert.equal(s.ctx.inboxLive.current.dropped,0);
  }finally{s.cleanup();}
});

test('the real completed package review wakes the remaining native FIFO without requiring focus',()=>{
  assert.match(main,/onInboxDone=\{path=>\{[\s\S]*?activationDrainRef\.current\?\.trigger\(\)/);
});
