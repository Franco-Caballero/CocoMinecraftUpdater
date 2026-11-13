import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function trap(){
  const code=ts.transpileModule(await readFile(resolve(root,'src/dialog-focus.ts'),'utf8'),{
    compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS},
  }).outputText;
  const module={exports:{}};
  vm.runInNewContext(code,{module,exports:module.exports});
  return module.exports.trapDialogTab;
}

test('Tab and Shift+Tab stay inside a modal, skip hidden controls, and never trap normal inner navigation',async()=>{
  const trapDialogTab=await trap();
  const calls=[];
  const control=(id,visible=true)=>({id,focus(){calls.push(id);},getClientRects(){return {length:visible?1:0};}});
  const first=control('close'),second=control('play'),hidden=control('hidden',false),last=control('favorite');
  const controls=[first,second,hidden,last];
  const container={querySelectorAll(){return controls;},contains(item){return controls.includes(item);},focus(){calls.push('container');}};
  assert.equal(trapDialogTab(container,last,false),true);
  assert.equal(calls.at(-1),'close');
  assert.equal(trapDialogTab(container,first,true),true);
  assert.equal(calls.at(-1),'favorite');
  assert.equal(trapDialogTab(container,second,false),false);
  assert.equal(trapDialogTab(container,null,false),true);
  assert.equal(calls.at(-1),'close');
  assert.equal(trapDialogTab(container,container,true),true);
  assert.equal(calls.at(-1),'favorite');
});

test('empty dialogs keep keyboard focus instead of leaking into an underlying card',async()=>{
  const trapDialogTab=await trap();
  let focused=0;
  const container={querySelectorAll:()=>[],focus:()=>{focused++;}};
  assert.equal(trapDialogTab(container,null,false),true);
  assert.equal(trapDialogTab(container,null,true),true);
  assert.equal(focused,2);
});

test('detail drawer Escape closes without changing game state and restores previous control focus',async()=>{
  const app=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.match(app,/const openDetails=\(entry:Experience\)=>\{/);
  assert.match(app,/detailFocusReturn\.current=document\.activeElement/);
  assert.match(app,/const closeDetails=\(\)=>\{/);
  assert.match(app,/previous\.isConnected\)previous\.focus\(\)/);
  assert.match(app,/onKeyDown=\{onDetailKey\}/);
  assert.match(app,/onClick=\{closeDetails\}/);
  assert.match(app,/trapDialogTab\(event\.currentTarget,document\.activeElement,event\.shiftKey\)/);
  assert.doesNotMatch(app.slice(app.indexOf('const closeDetails='),app.indexOf('const onDetailKey=')),/invoke\(|launchNative\(|installNative\(/);
});
