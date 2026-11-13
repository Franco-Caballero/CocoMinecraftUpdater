import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=await readFile(resolve(root,'src/main.tsx'),'utf8');
const start=source.indexOf('const launchNative=async(entry:Experience)=>{');
const end=source.indexOf('const installNative=async(',start);
assert.ok(start>=0&&end>start);
const compiled=ts.transpileModule(source.slice(start,end),{compilerOptions:{module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022}}).outputText;
const tests=[];

function makeScenario(launchResult,observation){
  const events=[];
  let runtime=null, uncertain=false,observedIds=[];
  const calls=[];
  const nativeOperationGate={current:{begin:(id,kind)=>{
    events.push(['begin',id,kind]);return {id,kind};
  },finish:t=>events.push(['finish',t.id])}};
  const setters={
    setBusy:value=>events.push(['busy',value]),
    setOperationMessage:value=>events.push(['message',value]),
    setRuntime:value=>{runtime=value;events.push(['runtime',value?.state]);},
    setProgress:value=>events.push(['progress',value]),
    setObservedGameIds:fn=>{observedIds=fn(observedIds);},
    setGameProcessUncertain:value=>{uncertain=value;},
  };
  const context={
    busy:false,activeVerification:null,upgrading:null,upgradeRecovering:null,
    preparingRepair:null,repairCommitting:null,repairRecovering:null,
    updateRunning:{current:false},appUpdate:{stage:'idle'},isTauri:()=>true,
    nativeOperationGate,...setters,
    invoke:async name=>{
      calls.push(name);
      if(name==='launch_standalone'){
        if(launchResult instanceof Error)throw launchResult;
        return launchResult;
      }
      if(name==='get_active_game_processes'){
        if(observation==='hanging')return new Promise(()=>{});
        if(observation instanceof Error)throw observation;
        return observation;
      }
      throw Error('unexpected native call: '+name);
    },
    rememberActivity:(kind,id)=>events.push(['activity',kind,id]),
    retainObservedGameIds:(prior,ids)=>prior.length===ids.length&&prior.every(x=>ids.includes(x))?prior:[...ids],
    reconcileLaunchObservation:(report,id)=>!report||report.status==='unknown'?'unknown':
      report.gameIds.includes(id)?'running':report.status==='none'&&report.safeToUpdate&&report.gameIds.length===0?'absent':'unknown',
    window:{setTimeout:observation==='hanging'?(fn)=>setTimeout(fn,0):setTimeout,clearTimeout},Promise,
  };
  const launchNative=vm.runInNewContext(compiled+'\nlaunchNative;',context);
  return {launchNative,events,calls,getRuntime:()=>runtime,getUncertain:()=>uncertain,getIds:()=>observedIds};
}

test('actual launchNative rejects an ambiguous IPC response but confirms only matching native running process, no duplicated launch',async()=>{
  const app=makeScenario(new Error('http://token.invalid/?secret=ALPHA'),{
    status:'active',safeToUpdate:false,gameIds:['friend-game'],
  });
  await app.launchNative({id:'friend-game'});
  assert.deepEqual(app.calls,['launch_standalone','get_active_game_processes']);
  assert.equal(app.getRuntime()?.state,'running');
  assert.equal(app.getUncertain(),false);
  assert.match(app.events.findLast(e=>e[0]==='message')?.[1]||'',/Windows detectó el juego activo/);
  assert.ok(!JSON.stringify(app.events).includes('ALPHA'),'native error tokens must not become user-visible');
  assert.equal(app.events.filter(e=>e[0]==='activity').length,0,'no unconfirmed played event');
  assert.deepEqual(app.events.at(-1),['busy',false]);
});

test('unrelated game, unknown snapshot and no process observation remain safe to retry only after inspection',async()=>{
  const app=makeScenario(new Error('native died'),{status:'active',safeToUpdate:false,gameIds:['other-game']});
  await app.launchNative({id:'wanted'});
  assert.equal(app.getRuntime()?.state,'verifying');
  assert.equal(app.getUncertain(),true);
  assert.equal(app.calls.filter(x=>x==='launch_standalone').length,1);
  assert.match(app.events.findLast(e=>e[0]==='message')?.[1]||'',/sin confirmar/);
  const failed=makeScenario(new Error('native IPC lost'),new Error('snapshot denied'));
  await failed.launchNative({id:'wanted'});
  assert.equal(failed.getRuntime()?.state,'verifying');
  assert.equal(failed.getUncertain(),true);
});

test('a real native exited receipt must not display false running or played confirmation',async()=>{
  const app=makeScenario({id:'synthetic',state:'exited',pid:null,exitCode:1},null);
  await app.launchNative({id:'synthetic'});
  assert.deepEqual(app.calls,['launch_standalone']);
  assert.equal(app.getRuntime()?.state,'exited');
  assert.match(app.events.findLast(e=>e[0]==='message')?.[1]||'',/se cerró durante el inicio/);
  assert.equal(app.events.filter(e=>e[0]==='activity').length,0);
});

test('stalled read-only native process inspection does not leave the launch gate or UI busy indefinitely',async()=>{
  const app=makeScenario(new Error('IPC response lost'),'hanging');
  await app.launchNative({id:'synthetic'});
  assert.equal(app.getRuntime()?.state,'verifying');
  assert.equal(app.getUncertain(),true);
  assert.equal(app.events.findLast(e=>e[0]==='busy')?.[1],false);
  assert.ok(app.events.some(e=>e[0]==='finish'));
  assert.equal(app.calls.filter(c=>c==='launch_standalone').length,1);
});
