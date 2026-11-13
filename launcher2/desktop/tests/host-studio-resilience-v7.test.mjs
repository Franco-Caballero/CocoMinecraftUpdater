// Executes the actual frontend exportPortable handler against deterministic
// Tauri mocks. No GUI, installer, HKCU, user file or network is touched.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=await readFile(resolve(root,'src/HostStudio.tsx'),'utf8');
const ast=ts.createSourceFile('HostStudio.tsx',source,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const names=['isPortableSavePath','isLocalPortableSavePath','isConfirmedPortableExport',
  'suggestedPortableFileName','portableExportError','createHostStudioFlowGate'];
const functions=ast.statements.filter(n=>ts.isFunctionDeclaration(n)&&names.includes(n.name?.text));
assert.equal(functions.length,names.length,'test must execute original TS helpers');
let handler;
const visit=node=>{
  if(ts.isVariableDeclaration(node)&&node.name.getText(ast)==='exportPortable')
    handler=node.initializer?.getText(ast);
  ts.forEachChild(node,visit);
};
visit(ast);
assert.ok(handler?.startsWith('async()=>{'),'test must execute original frontend handler');
const compiled=ts.transpileModule(
  functions.map(f=>f.getText(ast).replace(/^export\s+/,'')).join('\n')+
  '\nconst exportPortable='+handler+';\nexportPortable;',
  {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.None},reportDiagnostics:true}
);
assert.equal(compiled.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);
const deferred=()=>{
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};
const selected='C:\\Users\\Tester\\Downloads\\My Game.coco2pack';
const receipt=(changes={})=>({
  id:'game',path:selected,status:'exported-local-untrusted-unpublished',
  size:1200,sha256:'hidden',...changes
});
function harness({pick=()=>selected,native=()=>receipt()}={}){
  const events=[];
  const state={error:'',notice:'',busy:false,phase:'idle',restoring:false,
    exported:null,copied:false,label:'',exit:null};
  const ctx={
    busy:false,
    publishArtifact:{id:'game',artifactPath:'C:\\STAGED\\sealed'},
    publishPreview:{newVersion:'1.0'},
    exportPendingRef:{current:false},
    exportButtonRef:{current:{focus:()=>events.push('premature-focus')}},
    save:async options=>{events.push(['picker',options]);return pick();},
    invoke:async (command,args)=>{events.push(['native',command,args]);return native(command,args);},
    setBusy(value){ctx.busy=value;state.busy=value;},
    setBusyLabel(value){state.label=value;},
    setExportPhase(value){state.phase=value;},
    setExportNotice(value){state.notice=value;},
    setCopiedExport(value){state.copied=value;},
    setRestoreExportFocus(value){state.restoring=value;},
    setError(value){state.error=value;},
    setPortableExport(value){state.exported=value;events.push(['exported',value]);}
  };
  const run=runInNewContext(compiled.outputText,ctx,{timeout:1000});
  ctx.flowGate={current:runInNewContext('createHostStudioFlowGate()',ctx)};
  ctx.beginOperation=label=>{
    const ticket=ctx.flowGate.current.begin();
    if(ticket!==null){ctx.setBusy(true);ctx.setBusyLabel(label);}
    return ticket;
  };
  ctx.completeOperation=ticket=>{
    const action=ctx.flowGate.current.finish(ticket);
    ctx.setBusy(false);ctx.setBusyLabel('');
    state.exit=action;
  };
  return {run,ctx,state,events,
    pickers:()=>events.filter(e=>Array.isArray(e)&&e[0]==='picker'),
    writes:()=>events.filter(e=>Array.isArray(e)&&e[0]==='native')};
}

test('cancel Save As invokes no native write and requests focus after re-enable',async()=>{
  const box=harness({pick:()=>null});
  await box.run();
  assert.equal(box.pickers().length,1);
  assert.equal(box.writes().length,0);
  assert.equal(box.state.phase,'idle');
  assert.equal(box.state.busy,false);
  assert.equal(box.state.restoring,true);
  assert.match(box.state.notice,/Guardado cancelado/);
  assert.equal(box.state.exported,null);
  assert.ok(!box.events.includes('premature-focus'));
  assert.match(source,/if\(!busy&&restoreExportFocus&&!flowGate\.current\.isActive\(\)\)/);
  assert.match(source,/exportButtonRef\.current\?\.focus\(\)/);
});

test('bad extension, relative path, UNC and traversal never invoke Rust',async()=>{
  for(const destination of [
    'game.zip','game.coco2pack','\\\\server\\share\\game.coco2pack',
    'C:\\Downloads\\..\\other\\game.coco2pack',
    'C:\\Downloads\\game.coco2pack.zip','C:\\temp\\bad|name.coco2pack',
    'C:\\temp\\bad.\\game.coco2pack'
  ]){
    const box=harness({pick:()=>destination});
    await box.run();
    assert.equal(box.writes().length,0,destination);
    assert.equal(box.state.exported,null,destination);
    assert.equal(box.state.restoring,true,destination);
    assert.ok(box.state.error.length>0,destination);
  }
});

test('only an exact game+destination+status+size receipt permits success',async()=>{
  for(const value of [
    receipt(),
    receipt({path:'c:/users/tester/downloads/my game.coco2pack'}),
    receipt({path:'\\\\?\\C:\\Users\\Tester\\Downloads\\My Game.coco2pack'})
  ]){
    const box=harness({native:()=>value});
    await box.run();
    assert.equal(box.writes().length,1);
    assert.equal(box.state.exported,value);
    assert.match(box.state.notice,/Archivo guardado en tu equipo/);
    assert.equal(box.state.restoring,false);
  }
  for(const value of [
    receipt({id:'different-game'}),
    receipt({path:'C:\\Other\\My Game.coco2pack'}),
    receipt({path:'C:\\Users\\Tester\\Downloads\\Other.coco2pack'}),
    receipt({status:'unverified'}),receipt({size:0}),
    receipt({size:Number.NaN}),receipt({size:1.5}),
    receipt({path:'\\\\server\\share\\My Game.coco2pack'})
  ]){
    const box=harness({native:()=>value});
    await box.run();
    assert.equal(box.writes().length,1,'do not retry a potentially committed export');
    assert.equal(box.state.exported,null,'no success for mismatched receipt');
    assert.match(box.state.error,/Es posible que ya se haya guardado/);
    assert.equal(box.state.restoring,true);
  }
});

test('double click while Save As waits opens exactly one picker',async()=>{
  const pending=deferred();
  const box=harness({pick:()=>pending.promise});
  const first=box.run();
  await box.run();
  assert.equal(box.pickers().length,1);
  assert.equal(box.ctx.flowGate.current.isActive(),true);
  pending.resolve(null);
  await first;
  assert.equal(box.writes().length,0);
  assert.equal(box.ctx.flowGate.current.isActive(),false);
  assert.equal(box.ctx.exportPendingRef.current,false);
});

test('deferred close supersedes the file dialog before a native write',async()=>{
  const pending=deferred();
  const box=harness({pick:()=>pending.promise});
  const task=box.run();
  assert.equal(box.ctx.flowGate.current.request('close'),false);
  pending.resolve(selected);
  await task;
  assert.equal(box.writes().length,0);
  assert.equal(box.state.exported,null);
  assert.equal(box.state.exit,'close');
  assert.equal(box.state.restoring,false);
});

test('deferred close during native write waits for settle and does not lie',async()=>{
  const pending=deferred();
  const box=harness({native:()=>pending.promise});
  const task=box.run();
  while(box.writes().length===0)await Promise.resolve();
  assert.equal(box.ctx.flowGate.current.request('close'),false);
  pending.resolve(receipt());
  await task;
  assert.equal(box.writes().length,1);
  assert.equal(box.state.exported,null,'closed dialog must not show stale result');
  assert.equal(box.state.exit,'close');
  assert.equal(box.ctx.flowGate.current.isActive(),false);
});

test('change game during native writer defers reset and suppresses its old receipt',async()=>{
  const pending=deferred();
  const box=harness({native:()=>pending.promise});
  const task=box.run();
  while(box.writes().length===0)await Promise.resolve();
  assert.equal(box.ctx.flowGate.current.request('new'),false);
  pending.resolve(receipt());
  await task;
  assert.equal(box.writes().length,1);
  assert.equal(box.state.exported,null);
  assert.equal(box.state.exit,'new');
  assert.equal(box.state.restoring,false);
});

test('picker failure is friendly, then explicit retry opens a new picker only',async()=>{
  let picks=0;
  const box=harness({pick:()=>{
    picks++;
    if(picks===1)throw Error('internal user path C:\\private\\secret');
    return null;
  }});
  await box.run();
  assert.equal(box.writes().length,0);
  assert.match(box.state.error,/No pude abrir Guardar como/);
  assert.doesNotMatch(box.state.error,/private|secret|internal/);
  assert.equal(box.state.restoring,true);
  await box.run();
  assert.equal(picks,2);
  assert.equal(box.writes().length,0);
  assert.match(box.state.notice,/Guardado cancelado/);
});

test('native failure keeps previous verified copy and requires manual retry',async()=>{
  const old=receipt({path:'C:\\Old\\previous.coco2pack'});
  const box=harness({native:async()=>{throw Error('Portable export target already exists; never overwrite');}});
  box.state.exported=old;
  await box.run();
  assert.equal(box.state.exported,old);
  assert.match(box.state.error,/Ya existe un archivo/);
  assert.equal(box.writes().length,1);
  assert.equal(box.state.busy,false);
  assert.equal(box.state.restoring,true);
});

test('contract has one Save As and preserved Rust authority, never auto-imports',()=>{
  assert.match(source,/if\(!isPortableSavePath\(destination\)\)/);
  assert.match(source,/if\(!isLocalPortableSavePath\(destination\)\)/);
  assert.match(source,/if\(!isConfirmedPortableExport\(exported,publishArtifact\.id,destination\)\)/);
  const picker=source.indexOf('const destination=await save({');
  const check=source.indexOf('if(!isLocalPortableSavePath(destination))',picker);
  const native=source.indexOf("invoke<PortableExport>('export_portable_standalone_package'",picker);
  const receiptCheck=source.indexOf('if(!isConfirmedPortableExport(exported',native);
  assert.ok(picker>=0&&check>picker&&native>check&&receiptCheck>native);
  assert.match(source,/destinationPath:destination/);
  assert.match(source,/filters:\[\{name:'Paquete Coco 2 \(\.coco2pack\)',extensions:\['coco2pack'\]\}\]/);
  assert.match(source,/if\(!flowGate\.current\.owns\(ticket\)\)return/);
});
