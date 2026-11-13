/** Explorer review after a restart is a review-only draft, never authority to
 * import/install/launch. Synthetic localStorage; no personal profiles/HKCU. */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const main=await readFile(resolve(root,'src/main.tsx'),'utf8');
const inboxSource=await readFile(resolve(root,'src/package-inbox.ts'),'utf8');
const durableSource=await readFile(resolve(root,'src/package-inbox-persistence.ts'),'utf8');
function transpileModule(source,requireFn=()=>{throw Error('unexpected import');}){
  const obj={exports:{}};
  const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code,{module:obj,exports:obj.exports,require:requireFn},{timeout:1000});
  return obj.exports;
}
const inbox=transpileModule(inboxSource);
const durable=transpileModule(durableSource,name=>{
  assert.equal(name,'./package-inbox');return inbox;
});
function storage({failWrite=false,seed={}}={}){
  const data=new Map(Object.entries(seed));
  return {data,getItem:key=>data.get(key)??null,
    setItem:(key,value)=>{if(failWrite)throw Error('synthetic quota exceeded');data.set(key,value);}};
}
const path=n=>`C:\\Shared\\Amigo-${n} 漢字.coco2pack`;

test('a confirmed React inbox survives an app restart for review only, with FIFO and no duplication',()=>{
  const st=storage();
  const extended='\\\\?\\C:\\Shared\\Amigo Unicode 💜.coco2pack';
  const before=inbox.enqueuePackageRequests(inbox.emptyPackageInbox(),[path(1),extended,path(2),path(2)]);
  assert.equal(durable.persistPackageInbox(before,st),true);
  // Fresh React process: same app origin, no native queue or implicit actions.
  const recovered=durable.readPersistedPackageInbox(st);
  assert.deepEqual(Array.from(recovered.paths),[path(1),extended,path(2)]);
  assert.equal(recovered.dropped,0);
  const after=inbox.dismissPackageRequest(recovered,path(1));
  assert.equal(durable.persistPackageInbox(after,st),true);
  assert.deepEqual(Array.from(durable.readPersistedPackageInbox(st).paths),[extended,path(2)]);
});

test('hostile or corrupt persisted inbox cannot manufacture arbitrary paths, capacity or auto-import flags',()=>{
  const st=storage();
  st.setItem(durable.EXPLORER_INBOX_STORAGE_KEY,JSON.stringify({version:1,paths:[
    path(1),path(1),'../../../evil.zip','file:///fake.coco2pack',
    '\\\\server\\share\\remote.coco2pack',
    'C:\\Bad\\newline\n.coco2pack',9,null,...Array.from({length:110},(_,i)=>path(i+10)),
  ],dropped:999999,importNow:true}));
  const result=durable.readPersistedPackageInbox(st);
  assert.equal(result.paths.length,96);
  assert.equal(result.paths[0],path(1));
  assert.equal(result.paths.includes('file:///fake.coco2pack'),false);
  assert.equal(result.dropped,0);
  assert.equal('importNow' in result,false);
});

test('a storage failure fails closed before native ACK and never silently claims durable receipt',()=>{
  const st=storage({failWrite:true});
  assert.equal(durable.persistPackageInbox(inbox.enqueuePackageRequests(inbox.emptyPackageInbox(),path(1)),st),false);
  assert.match(main,/useState\(readPersistedPackageInbox\)/);
  assert.match(main,/if\(accepted\.length&&!commitInbox\(enqueuePackageRequests\(inboxLive\.current,accepted\)\)\)/);
  assert.match(main,/pendingPackageInboxRef=React\.useRef\(Boolean\(inbox\.paths\.length\|\|inbox\.dropped\)\)/);
  assert.match(main,/onInboxDone=\{path=>\{[\s\S]*?commitInbox\(dismissPackageRequest/);
  assert.doesNotMatch(durableSource,/import_local_publish_package|install_standalone|launch_standalone|window\.location/);
});
