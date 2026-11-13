import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function ledger(){
  const text=await readFile(resolve(root,'src/activity-ledger.ts'),'utf8');
  const js=ts.transpileModule(text,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  let payload=null;
  const store={getItem:()=>payload,setItem:(_,v)=>{payload=v;},removeItem:()=>{payload=null;}};
  return {...module.exports,store,setPayload:value=>{payload=value;},getPayload:()=>payload};
}
test('only bounded, validated action and game ID are persisted, never user paths or hashes',async()=>{
  const x=await ledger();const now=1_800_000_000_000;
  assert.equal(x.recordActivity('installed','big-walk',x.store,now).length,1);
  assert.deepEqual(JSON.parse(x.getPayload()),[{kind:'installed',id:'big-walk',at:now}]);
  assert.equal(x.recordActivity('played','C:\\Users\\Private\\game.exe',x.store,now+1).length,1);
  assert.equal(x.recordActivity('played','../bad',x.store,now+1).length,1);
  assert.equal(x.recordActivity('unknown','safe',x.store,now+2).length,1);
  assert.ok(!x.getPayload().includes('Users'));
});
test('history survives app reload, deduplicates callback bursts and preserves different actions',async()=>{
  const x=await ledger();const now=1_800_000_000_000;
  x.recordActivity('played','game-a',x.store,now);
  x.recordActivity('played','game-a',x.store,now+50);
  x.recordActivity('repaired','game-a',x.store,now+100);
  x.recordActivity('played','game-a',x.store,now+20_000);
  const fresh=await ledger();fresh.setPayload(x.getPayload());
  assert.equal(fresh.readActivity(fresh.store,now+21_000).length,3);
  assert.equal(fresh.readActivity(fresh.store,now+21_000)[0].kind,'played');
});
test('invalid, expired, future and over-cap history is filtered without overwriting other settings',async()=>{
  const x=await ledger();const now=1_800_000_000_000;
  x.setPayload('not-json');assert.equal(x.readActivity(x.store,now).length,0);
  x.setPayload(JSON.stringify([
    {id:'old',kind:'played',at:now-100*86400_000},
    {id:'future',kind:'installed',at:now+100_000},
    {id:'bad-path',kind:'played',at:now-3},
    ...Array.from({length:70},(_,i)=>({id:`game-${i}`,kind:'watched',at:now-i*1000})),
  ]));
  assert.equal(x.readActivity(x.store,now).length,60);
  x.clearActivity(x.store);assert.equal(x.readActivity(x.store,now).length,0);
});
test('React records only native-confirmed operations and offers local history clearing',async()=>{
  const app=await readFile(resolve(root,'src/main.tsx'),'utf8');
  for(const status of [
    "if(started.state==='running')rememberActivity('played',entry.id)",
    "if(result.status==='installed'){",
    "rememberActivity('installed',entry.id)",
    "rememberActivity('uninstalled',entry.id)",
    "if(outcome.status==='upgraded')rememberActivity('upgraded',entry.id)",
    "if(outcome.status==='recovery-complete')rememberActivity('recovered',entry.id)",
  ])assert.ok(app.includes(status),`Missing native success event gating: ${status}`);
  assert.match(app,/clearActivity\(\);setActivity\(\[\]\)/);
  assert.match(app,/view==='settings'.*?Tu actividad/s);
});
