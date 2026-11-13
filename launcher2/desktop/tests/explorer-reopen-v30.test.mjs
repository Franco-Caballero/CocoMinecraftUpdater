/** Explorer immediately after review: a completed/dismissed review is an
 * explicit human action. Fresh double click on the same file must open a new
 * review, while transient duplicate WM_COPYDATA events still deduplicate.
 * TEMP/VM source contracts; no real Explorer, registry or package execution. */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [app,native,lib]=await Promise.all([
  readFile(resolve(root,'src/main.tsx'),'utf8'),
  readFile(resolve(root,'src-tauri/src/services/activation.rs'),'utf8'),
  readFile(resolve(root,'src-tauri/src/lib.rs'),'utf8'),
]);

function completedReviewHandler(){
  const ast=ts.createSourceFile('main.tsx',app,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
  let found='';
  function walk(node){
    if(ts.isJsxAttribute(node)&&node.name.getText(ast)==='onInboxDone'){
      found=node.initializer?.getText(ast)||'';
    }
    ts.forEachChild(node,walk);
  }
  walk(ast);return found;
}

function executeActualHandler(persisted,{reject=false}={}){
  const calls=[];
  const context={
    inboxLive:{current:{paths:['C:\\Synthetic\\human-reviewed.coco2pack'],dropped:0}},
    dismissPackageRequest:(_current,path)=>{calls.push(['dismiss',path]);return {paths:[],dropped:0};},
    commitInbox:state=>{calls.push(['commit',state.paths.length]);return persisted;},
    invoke:async(name,{path})=>{calls.push(['native',name,path]);if(reject)throw Error('synthetic IPC unavailable');return true;},
    activationDrainRef:{current:{trigger:async()=>{calls.push(['drain']);}}},
    console:{warn:(...parts)=>calls.push(['warn',String(parts[0])])},
  };
  const source=completedReviewHandler().slice(1,-1);
  const js=ts.transpileModule('('+source+')',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None}}).outputText;
  const fn=vm.runInNewContext(js,context,{timeout:1000});
  fn(context.inboxLive.current.paths[0]);
  return new Promise(resolve=>setImmediate(()=>resolve(calls)));
}

test('explicit review completion releases only replay suppression, after durable dismissal',()=>{
  const handler=completedReviewHandler();
  assert.ok(handler,'real React onInboxDone handler extracted');
  assert.match(handler,/commitInbox\(dismissPackageRequest\(inboxLive\.current,path\)\)/);
  assert.match(handler,/release_reviewed_package_replay_suppression/);
  assert.match(handler,/if\(persisted\)/);
  assert.match(handler,/activationDrainRef\.current\?\.trigger\(\)/);
  assert.doesNotMatch(handler,/import_local_publish_package|install_standalone|launch_standalone/);
});

test('explicit review dismissal can cancel still-native request if storage was unavailable; accidental native ACK remains forbidden',()=>{
  const handler=completedReviewHandler();
  assert.match(handler,/cancel_pending_package_open_request/);
  assert.match(handler,/if\(persisted\)\{[\s\S]*?release_reviewed_package_replay_suppression[\s\S]*?\}else\{[\s\S]*?cancel_pending_package_open_request/);
  assert.match(native,/pub fn release_reviewed_package_replay_suppression\(path:String\)->bool/);
  assert.match(lib,/services::activation::release_reviewed_package_replay_suppression/);
  const cmd=native.slice(native.indexOf('pub fn release_reviewed_package_replay_suppression('),native.indexOf('pub fn peek_pending_package_open_requests('));
  assert.match(cmd,/delivery\(\)\.lock\(\)/);
  assert.match(cmd,/release_review_replay\(&mut state,&path\)/);
  assert.doesNotMatch(cmd,/\.drain\(|\.pop_front\(/);
});

test('real React completion commits before native replay-release, then drains any queued suffix',async()=>{
  const calls=await executeActualHandler(true);
  assert.deepEqual(calls.map(item=>item[0]),['dismiss','commit','native','drain']);
  assert.equal(calls[2][1],'release_reviewed_package_replay_suppression');
});

test('real React explicit discard fails closed when storage is full, and IPC rejection cannot authorize install',async()=>{
  const calls=await executeActualHandler(false,{reject:true});
  assert.deepEqual(calls.map(item=>item[0]),['dismiss','commit','native','warn','drain']);
  assert.equal(calls[2][1],'cancel_pending_package_open_request');
  assert.ok(calls.every(item=>!String(item[1]).includes('install_standalone')));
});
