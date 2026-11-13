import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');

async function load(){
  const source=await read('src/modal-scroll-lock.ts');
  const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(code,{module,exports:module.exports});
  return module.exports.lockBackgroundScroll;
}
function fixture({clientWidth=1200,innerWidth=1215,paddingRight='5px',inlineOverflow='clip',inlinePadding=''}={}){
  const documentElement={clientWidth,style:{overflow:inlineOverflow,paddingRight:inlinePadding}};
  return {
    root:documentElement,
    document:{documentElement},
    window:{innerWidth,getComputedStyle:()=>({paddingRight})},
  };
}

test('scroll lock prevents the underlying page scrolling while a dialog has its own scroll area',async()=>{
  const lock=await load();
  const f=fixture();
  const unlock=lock(f.document,f.window);
  assert.equal(f.root.style.overflow,'hidden');
  assert.equal(f.root.style.paddingRight,'20px','scrollbar width must be compensated without shifting cards');
  assert.equal(typeof unlock,'function');
  unlock();
  assert.equal(f.root.style.overflow,'clip');
  assert.equal(f.root.style.paddingRight,'','restore the exact inline style, not an assumed default');
});

test('responsive overlay with no scrollbar retains existing padding and restores style after closing',async()=>{
  const lock=await load();
  const f=fixture({clientWidth:390,innerWidth:390,paddingRight:'14px',inlineOverflow:'auto',inlinePadding:'14px'});
  const unlock=lock(f.document,f.window);
  assert.equal(f.root.style.overflow,'hidden');
  assert.equal(f.root.style.paddingRight,'14px');
  unlock();
  assert.equal(f.root.style.overflow,'auto');
  assert.equal(f.root.style.paddingRight,'14px');
});

test('React uses a single scroll lock for details, Host Studio, movies and a pending package review',async()=>{
  const main=await read('src/main.tsx');
  assert.match(main,/import \{lockBackgroundScroll\} from '\.\/modal-scroll-lock'/);
  assert.match(main,/useLayoutEffect\(\(\)=>\{[\s\S]*?lockBackgroundScroll\(document,window\)/);
  assert.match(main,/selected\|\|mediaPlaying\|\|hostStudioOpen/);
  assert.match(main,/incomingPackages\.length>0&&!packageReviewDeferred/);
  assert.match(main,/\[selected,mediaPlaying,hostStudioOpen,incomingPackages\.length,packageReviewDeferred\]/);
});
