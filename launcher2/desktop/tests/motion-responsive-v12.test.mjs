import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
async function moduleAt(path){
  const js=ts.transpileModule(await read(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});return module.exports;
}

test('legacy motion helper remains readable, but the launcher no longer exposes a user off switch',async()=>{
  const {parseMotionPreference:parse,motionEnabled:enabled,toggleMotionPreference:toggle}=await moduleAt('src/motion-preference.ts');
  for(const input of [undefined,null,42,'bogus',''])assert.equal(parse(input),'system');
  assert.equal(parse('system'),'system');
  assert.equal(parse('on'),'on');
  assert.equal(parse('off'),'off');
  assert.equal(enabled('system',false),true);
  assert.equal(enabled('system',true),false);
  assert.equal(enabled('on',true),true,'manual on remains explicit');
  assert.equal(enabled('off',false),false,'manual off remains explicit');
  assert.equal(toggle(true),'off');
  assert.equal(toggle(false),'on');
});

test('a live Windows accessibility change suspends video, with no animation-disable controls',async()=>{
  const [ui,css]=await Promise.all([read('src/main.tsx'),read('src/experience-v2.css')]);
  assert.match(ui,/const motion=!systemReducedMotion/);
  assert.match(ui,/addEventListener\('change',changed\)/);
  assert.match(ui,/removeEventListener\('change',changed\)/);
  assert.match(ui,/query\.addListener\?\.\(changed\)/);
  assert.match(ui,/hoverVideoPool\.setEnabled\(motion\)/);
  assert.doesNotMatch(ui,/setMotionPreference|toggleMotionPreference|Desactivar animaciones/);
  assert.match(css,/@media\(max-width:440px\)/);
  assert.match(css,/\.coco-catalog-feed \.cinema-grid\{grid-template-columns:minmax\(0,1fr\)/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});
