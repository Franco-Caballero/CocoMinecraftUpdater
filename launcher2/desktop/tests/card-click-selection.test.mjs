import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('card background opens details while nested controls retain their own actions',async()=>{
  const source=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const body=source.match(/return <article className=\{`experience-card[\s\S]*?onClick=\{event=>\{([\s\S]*?)\}\} onPointerEnter=/)?.[1];
  assert.ok(body,'shared normal/latest card click handler is present');
  class Element {
    constructor(interactive=false){this.interactive=interactive;}
    closest(selector){
      assert.match(selector,/button/);
      return this.interactive?this:null;
    }
  }
  const opened=[];
  const entry={id:'sample'};
  const handler=new Function('Element','cardActions','entry',`return event=>{${body}}`)(Element,{current:{openDetails:item=>opened.push(item.id)}},entry);
  handler({target:new Element()});
  assert.deepEqual(opened,['sample']);
  // Covers the image button and children of the play and favorite buttons.
  for(let i=0;i<3;i++)handler({target:new Element(true)});
  assert.deepEqual(opened,['sample']);
  assert.match(source,/latest\?card\(latest,0,true\)/);
  assert.match(source,/visibleEntries\.map\(\(entry,index\)=>card\(entry,index\)\)/);
});

test('selection stays disabled on cards and navigation but enabled in search',async()=>{
  const css=await readFile(resolve(root,'src/coco-ui.css'),'utf8');
  assert.match(css,/\.experience-card\{[^}]*user-select:none/);
  assert.match(css,/\.coco-bar\{user-select:none/);
  assert.match(css,/\.coco-bar input,\.coco2-desktop \.coco-bar textarea\{user-select:text/);
});
