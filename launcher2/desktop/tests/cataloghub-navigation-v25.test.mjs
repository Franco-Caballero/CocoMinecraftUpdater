// Catalog Hub v25: render original TSX with React hook and native Tauri mocks.
// Only synthetic promises and strings are used; no GUI, files, HKCU or network.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [hubText,portableText,activationText]=await Promise.all([
  readFile(resolve(root,'src/CatalogHub.tsx'),'utf8'),
  readFile(resolve(root,'src/portable-format.ts'),'utf8'),
  readFile(resolve(root,'src/package-activation-drain.ts'),'utf8'),
]);

function transpile(source,fileName){
  const compiled=ts.transpileModule(source,{fileName,
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
      jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment'},
    reportDiagnostics:true});
  assert.equal(compiled.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0,
    `${fileName} parses as real TypeScript`);
  return compiled.outputText;
}
const hubCode=transpile(hubText,'CatalogHub.tsx');
const portableCode=transpile(portableText,'portable-format.ts');
const activationCode=transpile(activationText,'package-activation-drain.ts');

function loadExports(code){
  const exports={};
  return runInNewContext(`${code}\nmodule.exports`,{exports,module:{exports}},{timeout:1500});
}
const portable=loadExports(portableCode);
const activation=loadExports(activationCode);
const ast=ts.createSourceFile('CatalogHub.tsx',hubText,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const component=ast.statements.find(statement=>
  ts.isFunctionDeclaration(statement)&&statement.name?.text==='CatalogHub');
assert.ok(component,'test loads original CatalogHub function');
const hookNames=[];
for(const statement of component.body.statements){
  if(!ts.isVariableStatement(statement))continue;
  for(const declaration of statement.declarationList.declarations){
    const init=declaration.initializer&&ts.isAsExpression(declaration.initializer)
      ?declaration.initializer.expression:declaration.initializer;
    if(!init||!ts.isCallExpression(init)||
      !['useState','useRef'].includes(init.expression.getText(ast)))continue;
    hookNames.push(ts.isArrayBindingPattern(declaration.name)
      ?declaration.name.elements[0].name.getText(ast)
      :declaration.name.getText(ast));
  }
}
assert.ok(hookNames.includes('pickerPendingRef'));
assert.ok(hookNames.includes('checking'));

function delayed(){
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
}
async function drain(){for(let i=0;i<10;i++)await Promise.resolve();}
const A='C:\\Synthetic\\A.coco2pack';
const B='C:\\Synthetic\\B.coco2pack';
const reviewA={id:'gameA',newVersion:'1.0',status:'ready-for-review',
  sourcePath:A,reviewToken:'rust-A',mode:'new'};

function find(node,predicate){
  if(!node||typeof node!=='object')return null;
  if(Array.isArray(node)){
    for(const entry of node){const match=find(entry,predicate);if(match)return match;}
    return null;
  }
  if(predicate(node))return node;
  return find(node.children,predicate);
}
function label(node){
  if(typeof node==='string'||typeof node==='number')return String(node);
  if(!node||typeof node!=='object')return '';
  return (Array.isArray(node)?node:node.children||[]).map(label).join(' ');
}

function mount({pick=async()=>null,review=async()=>reviewA,sync=async()=>({status:'unchanged',localEntries:0,remoteEntries:0}),hostStudioAvailable=true}={}){
  const slots=[];
  const calls=[];
  let hookIndex=0;
  const react={
    useState(initial){
      const pos=hookIndex++;
      if(!(pos in slots))slots[pos]=initial;
      return [slots[pos],next=>{slots[pos]=typeof next==='function'?next(slots[pos]):next;}];
    },
    useRef(initial){
      const pos=hookIndex++;
      if(!(pos in slots))slots[pos]={current:initial};
      return slots[pos];
    },
    useEffect(){},
  };
  const h=(type,props,...children)=>({type,props:props||{},children});
  const modules={
    react,
    '@tauri-apps/api/core':{
      isTauri:()=>true,
      invoke:async(command,args)=>{
        calls.push({command,args});
        if(command==='sync_catalog_channel')return sync();
        if(command==='review_local_publish_package')return review(args.path);
        throw Error(`unexpected native command ${command}`);
      },
    },
    '@tauri-apps/plugin-dialog':{open:async options=>{
      calls.push({command:'native-picker',options});
      return pick(options);
    }},
    './portable-format':portable,
    './package-activation-drain':activation,
    'lucide-react':new Proxy({}, {get:()=>()=>null}),
  };
  const exports={};
  const context={exports,module:{exports},require:name=>modules[name]||{},
    console,h,Fragment:'fragment'};
  const module=runInNewContext(`${hubCode}\nmodule.exports`,context,{timeout:2000});
  let refreshes=0;
  function render(){
    hookIndex=0;
    return module.default({onChanged:async()=>{refreshes++;},compact:false,hostStudioAvailable});
  }
  function button(text){
    const element=find(render(),node=>node.type==='button'&&label(node).includes(text));
    assert.ok(element,`actual UI has '${text}' button`);
    return element;
  }
  render();
  const get=name=>slots[hookNames.indexOf(name)];
  return {button,calls,get,render,get refreshes(){return refreshes;}};
}

test('client cannot reach native picker or import while retaining official catalog sync',async()=>{
  const box=mount({hostStudioAvailable:false});
  const tree=box.render();
  assert.equal(find(tree,node=>node.type==='button'&&label(node).includes('Abrir paquete Coco')),null);
  assert.equal(find(tree,node=>node.type==='button'&&label(node).includes('Elegir carpeta')),null);
  assert.ok(find(tree,node=>node.type==='button'&&label(node).includes('Sincronizar')));
  assert.equal(box.calls.filter(c=>c.command==='native-picker').length,0);
  assert.equal(box.calls.filter(c=>c.command==='review_local_publish_package').length,0);
});

test('old review completion cannot close a newer still-open native picker',async()=>{
  const pendingA=delayed();
  const pendingB=delayed();
  let pickerCount=0;
  const box=mount({
    pick:()=>++pickerCount===1?A:pendingB.promise,
    review:()=>pendingA.promise,
  });
  box.button('Abrir paquete Coco').props.onClick();
  await drain();
  assert.equal(box.calls.filter(c=>c.command==='review_local_publish_package').length,1);
  box.button('Cancelar revisión').props.onClick();
  box.button('Abrir paquete Coco').props.onClick();
  await drain();
  assert.equal(pickerCount,2);
  assert.equal(box.get('pickerPendingRef').current,true);
  assert.equal(box.get('pickerOpen'),true);

  pendingA.resolve(reviewA);
  await drain();
  assert.equal(box.get('pickerPendingRef').current,true,
    'obsolete A review must not release B Windows picker lock');
  assert.equal(box.get('pickerOpen'),true,
    'native B dialog remains visually represented while it is open');
  box.button('Cancelar revisión').props.onClick();
  box.button('Abrir paquete Coco').props.onClick();
  await drain();
  assert.equal(pickerCount,2,'cancelled B dialog still blocks any third picker until it settles');
  pendingB.resolve(null);
  await drain();
  assert.equal(box.get('pickerPendingRef').current,false);
  assert.equal(box.get('pickerOpen'),false);
});

test('two sync clicks before React rerenders issue one native operation and retain its outcome',async()=>{
  const first=delayed();
  let count=0;
  const box=mount({sync:()=>{count++;return first.promise;}});
  const click=box.button('Sincronizar').props.onClick;
  click();
  click();
  try{
    assert.equal(count,1,'sync must acquire an immediate single-flight lock');
    assert.equal(box.get('checking'),true);
  }finally{
    first.resolve({status:'updated',localEntries:4,remoteEntries:3,message:'Siete juegos actualizados'});
    await drain();
  }
  assert.equal(box.refreshes,1);
  assert.equal(box.get('checking'),false);
  box.button('Sincronizar').props.onClick();
  await drain();
  assert.equal(count,2,'the next explicit click after settlement starts fresh sync');
});
