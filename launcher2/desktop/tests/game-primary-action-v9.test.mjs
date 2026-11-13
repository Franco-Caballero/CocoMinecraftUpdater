import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const load=name=>readFile(resolve(desktop,name),'utf8');
async function actions(){
  const code=ts.transpileModule(await load('src/game-primary-action.ts'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};vm.runInNewContext(code,{module,exports:module.exports});
  return module.exports;
}
const base={nativeAvailable:true,hostingMode:'p2p',busy:false,gameActive:false,processUnknown:false};

test('one clear primary action transitions from prepare to install to play after the native receipt',async()=>{
  const {gamePrimaryAction}=await actions();
  const preparing=gamePrimaryAction({...base,localState:'not-found'});
  assert.equal(preparing.kind,'disabled');
  assert.match(preparing.reason,/Comprobando/);
  const install=gamePrimaryAction({...base,localState:'not-found',planStatus:'ready'});
  assert.equal(install.kind,'install');
  assert.equal(install.label,'Instalar juego');
  assert.match(install.reason,/progreso/);
  const ready=gamePrimaryAction({...base,localState:'folder-present',planStatus:'installed'});
  assert.equal(ready.kind,'launch');
  assert.equal(ready.label,'Jugar');
});

test('existing unknown/unmanaged paths and native conflicts cannot be overwritten or launched from a disabled CTA',async()=>{
  const {gamePrimaryAction}=await actions();
  for(const state of ['unknown','unmanaged']){
    const unsafe=gamePrimaryAction({...base,localState:state,planStatus:'ready'});
    assert.equal(unsafe.kind,'disabled');
    assert.match(unsafe.reason,/no es una instalación verificada/);
  }
  const blocked=gamePrimaryAction({...base,localState:'not-found',planStatus:'ready',busy:true});
  assert.equal(blocked.kind,'disabled');
  assert.match(blocked.reason,/terminando otra tarea/);
  const active=gamePrimaryAction({...base,localState:'folder-present',gameActive:true});
  assert.equal(active.kind,'disabled');
  const uncertain=gamePrimaryAction({...base,localState:'folder-present',processUnknown:true});
  assert.equal(uncertain.kind,'disabled');
  assert.match(uncertain.reason,/no puede confirmar/);
  const web=gamePrimaryAction({...base,localState:'not-found',planStatus:'ready',nativeAvailable:false});
  assert.equal(web.kind,'disabled');
  const unavailable=gamePrimaryAction({...base,localState:'not-found',hostingMode:'unsupported',planStatus:'ready'});
  assert.equal(unavailable.kind,'disabled');
});

test('every unavailable action supplies a human next step; an unrelated stale plan cannot enable install',async()=>{
  const {gamePrimaryAction}=await actions();
  const invalid=gamePrimaryAction({...base,localState:'not-found',planStatus:'missing-archive',planMessage:'No está disponible el paquete'});
  assert.equal(invalid.kind,'disabled');
  assert.match(invalid.reason,/No está disponible/);
  const app=await load('src/main.tsx');
  assert.match(app,/planStatus:installPlan\?\.id===selected\.id\?installPlan\.status:undefined/);
  assert.match(app,/primaryGame\.kind==='install'\?void installNative\(selected\)/);
  assert.match(app,/primaryGame\.kind==='launch'\?void launchNative\(selected\)/);
  assert.match(app,/id="gamePrimaryHint"/);
  assert.match(app,/aria-describedby=\{primaryGame\.kind==='disabled'\?'gamePrimaryHint':undefined\}/);
  assert.match(app,/disabled>Desactivado<\/button>/);
});

test('opening a game explains itself instead of asking to finish an operation',async()=>{
  const {gamePrimaryAction}=await actions();
  const first=gamePrimaryAction({...base,localState:'folder-present',busy:true,opening:true,firstRun:true});
  assert.equal(first.pending,true);
  assert.equal(first.label,'Preparando el juego');
  assert.match(first.reason,/primera vez en este PC/);
  const opening=gamePrimaryAction({...base,localState:'folder-present',busy:true,opening:true});
  assert.equal(opening.label,'Abriendo…');
  for(const action of [first,opening,gamePrimaryAction({...base,localState:'folder-present',busy:true})])
    assert.doesNotMatch(action.reason,/Termina/);
});
