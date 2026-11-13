// Execute the real TSX component and its React event handlers in an isolated
// in-memory renderer. No native dialog, UI window or user files are touched.
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
const component=ast.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name?.text==='HostStudio');
assert.ok(component,'render actual HostStudio component');

// The order is obtained from the real component, so the test does not depend
// on magic hook indices when a future feature adds state or references.
const slotNames=[];
for(const statement of component.body.statements){
  if(!ts.isVariableStatement(statement))continue;
  for(const decl of statement.declarationList.declarations){
    const init=decl.initializer;
    if(!init||!ts.isCallExpression(init)||
      !['useState','useRef'].includes(init.expression.getText(ast)))continue;
    const name=ts.isArrayBindingPattern(decl.name)
      ?decl.name.elements[0].name.getText(ast):decl.name.getText(ast);
    slotNames.push(name);
  }
}
assert.ok(slotNames.includes('rightsReviewed'));
assert.ok(slotNames.includes('publishPreview'));

const transpiled=ts.transpileModule(source,{
  fileName:'HostStudio.tsx',
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
    jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment'},
  reportDiagnostics:true
});
assert.equal(transpiled.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);

function mount(overrides={}){
  const slots=[];
  let hookIndex=0;
  const doc={activeElement:null};
  const h=(type,props,...children)=>({type,props:props||{},children});
  const react={
    useState(initial){
      const index=hookIndex++;
      if(!(index in slots))slots[index]=initial;
      return [slots[index],next=>{slots[index]=typeof next==='function'?next(slots[index]):next;}];
    },
    useRef(initial){
      const index=hookIndex++;
      if(!(index in slots))slots[index]={current:initial};
      return slots[index];
    },
    useEffect(){},
  };
  const exports={};
  const native=[];
  const mocks={
    react,
    '@tauri-apps/api/core':{invoke:async(command)=>{native.push(command);return null;}},
    '@tauri-apps/api/event':{listen:async()=>()=>{}},
    '@tauri-apps/plugin-dialog':{open:async()=>null,save:async()=>null},
    'lucide-react':new Proxy({}, {get:()=>() => null}),
  };
  const context={exports,module:{exports},require:name=>mocks[name]||{},
    h,Fragment:'fragment',document:doc,console};
  const module=runInNewContext(`${transpiled.outputText}\nmodule.exports`,context,{timeout:1500});
  const Studio=module.default;
  function render(){hookIndex=0;return Studio({close:()=>{},onCatalogChanged:async()=>{}});}
  render();
  for(const [name,value] of Object.entries(overrides)){
    const index=slotNames.indexOf(name);
    assert.notEqual(index,-1,`state ${name} belongs to original HostStudio`);
    slots[index]=value;
  }
  return {render,doc,slots,slotNames,native};
}

function visit(node,predicate){
  if(!node||typeof node!=='object')return null;
  if(Array.isArray(node)){
    for(const item of node){const found=visit(item,predicate);if(found)return found;}
    return null;
  }
  if(predicate(node))return node;
  return visit(node.children,predicate);
}
function getText(node){
  if(typeof node==='string'||typeof node==='number')return String(node);
  if(!node||typeof node!=='object')return '';
  return (Array.isArray(node)?node:node.children||[]).map(getText).join(' ');
}
function labelWith(tree,text){
  const found=visit(tree,node=>node.type==='label'&&getText(node).includes(text));
  assert.ok(found,`label ${text} exists in actual UI`);
  return found;
}
function actionWith(tree,text){
  const found=visit(tree,node=>node.type==='button'&&getText(node).includes(text));
  assert.ok(found,`button ${text} exists in actual UI`);
  return found;
}

test('share authorization and advanced catalog consent must be independent',()=>{
  const box=mount({
    result:{id:'game',requiredFilesCount:5},
    publishPreview:{id:'game',mode:'new',newVersion:'1.0.0',previewSha256:'review-1'},
    review:{id:'game',name:'Game',version:'1.0.0',requiredFilesCount:5},
  });
  let tree=box.render();
  const share=()=>labelWith(tree,'He revisado los datos');
  const catalog=()=>labelWith(tree,'Tengo derecho a distribuir');
  const prep=()=>actionWith(tree,'Preparar y guardar como');
  const promote=()=>actionWith(tree,'Incorporar al catálogo');
  assert.equal(visit(share(),node=>node.type==='input').props.checked,false);
  assert.equal(visit(catalog(),node=>node.type==='input').props.checked,false);
  assert.equal(prep().props.disabled,true);
  assert.equal(promote().props.disabled,true);

  // A host asks only to add the game to the local source catalog.
  visit(catalog(),node=>node.type==='input').props.onChange({target:{checked:true}});
  tree=box.render();
  assert.equal(visit(catalog(),node=>node.type==='input').props.checked,true);
  assert.equal(visit(share(),node=>node.type==='input').props.checked,false,
    'advanced catalog approval cannot count as sharing consent');
  assert.equal(prep().props.disabled,true,
    'must never start prepare/share from the other checkbox');
  assert.equal(promote().props.disabled,false);

  visit(catalog(),node=>node.type==='input').props.onChange({target:{checked:false}});
  tree=box.render();
  visit(share(),node=>node.type==='input').props.onChange({target:{checked:true}});
  tree=box.render();
  assert.equal(visit(share(),node=>node.type==='input').props.checked,true);
  assert.equal(visit(catalog(),node=>node.type==='input').props.checked,false,
    'sharing review must not authorize editing host catalog');
  assert.equal(prep().props.disabled,false);
  assert.equal(promote().props.disabled,true);
  assert.equal(box.native.length,0);
});

test('Tab and Shift+Tab wrap across focusable advanced summary in the actual modal',()=>{
  const box=mount();
  const dialog=visit(box.render(),node=>node.props?.role==='dialog');
  assert.ok(dialog);
  const focusOrder=[];
  const element=name=>({
    name,getClientRects:()=>[{}],getAttribute:()=>null,
    focus(){focusOrder.push(name);box.doc.activeElement=this;}
  });
  const button=element('button');
  const summary=element('summary');
  const event=(shiftKey,active)=>{
    box.doc.activeElement=active;
    let prevented=false;
    return {
      key:'Tab',shiftKey,
      currentTarget:{
        contains:target=>target===button||target===summary,
        querySelectorAll:selector=>selector.includes('summary')?[button,summary]:[button],
      },
      preventDefault(){prevented=true;},stopPropagation(){},
      get prevented(){return prevented;}
    };
  };
  const forward=event(false,summary);
  dialog.props.onKeyDown(forward);
  assert.equal(forward.prevented,true,'Tab from last summary must not escape modal');
  assert.equal(focusOrder.at(-1),'button');
  const backward=event(true,button);
  dialog.props.onKeyDown(backward);
  assert.equal(backward.prevented,true);
  assert.equal(focusOrder.at(-1),'summary','Shift+Tab reaches the actual last focusable element');
});
