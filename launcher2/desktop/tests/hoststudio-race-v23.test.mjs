// Host Studio v23: exercise actual TSX event handlers against mocked native
// file pickers/inspection. No GUI, app runtime, registry or disk writes.
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
assert.ok(component);
const hookNames=[];
for(const statement of component.body.statements){
  if(!ts.isVariableStatement(statement))continue;
  for(const decl of statement.declarationList.declarations){
    const init=decl.initializer;
    if(init&&ts.isCallExpression(init)&&['useState','useRef'].includes(init.expression.getText(ast)))
      hookNames.push(ts.isArrayBindingPattern(decl.name)?decl.name.elements[0].name.getText(ast):decl.name.getText(ast));
  }
}

const output=ts.transpileModule(source,{
  fileName:'HostStudio.tsx',
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
    jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment'},
  reportDiagnostics:true,
});
assert.equal(output.diagnostics?.filter(item=>item.category===ts.DiagnosticCategory.Error).length??0,0);

const A='C:\\Games\\A.zip';
const B='D:\\Archive\\B.zip';
const COVER='C:\\Games\\A.png';
const inspectedA={suggestedId:'a',suggestedName:'Game A',sha256:'a'.repeat(64),
  executables:['GameA.exe'],filesCount:20,archiveSize:1234,uncompressedBytes:3000};
const inspectedB={suggestedId:'b',suggestedName:'Game B',sha256:'b'.repeat(64),
  executables:['GameB.exe'],filesCount:30,archiveSize:2000,uncompressedBytes:6000};
const reviewedA=`${inspectedA.sha256}\0GameA.exe`;

function find(node,predicate){
  if(!node||typeof node!=='object')return null;
  if(Array.isArray(node)){
    for(const child of node){const result=find(child,predicate);if(result)return result;}
    return null;
  }
  if(predicate(node))return node;
  return find(node.children,predicate);
}
function contents(node){
  if(typeof node==='string'||typeof node==='number')return String(node);
  if(!node||typeof node!=='object')return '';
  return (Array.isArray(node)?node:node.children||[]).map(contents).join(' ');
}

function mount({pick,inspect,initialCover=COVER}={}){
  const slots=[];
  let nextHook=0;
  const calls=[];
  const react={
    useState(defaultValue){
      const pos=nextHook++;
      if(!(pos in slots))slots[pos]=defaultValue;
      return [slots[pos],v=>{slots[pos]=typeof v==='function'?v(slots[pos]):v;}];
    },
    useRef(defaultValue){
      const pos=nextHook++;
      if(!(pos in slots))slots[pos]={current:defaultValue};
      return slots[pos];
    },
    useEffect(){},
  };
  const h=(type,props,...children)=>({type,props:props||{},children});
  const modules={
    react,
    '@tauri-apps/api/core':{invoke:async(command,args)=>{
      calls.push([command,args]);
      if(command==='inspect_standalone_archive')return inspect(args.zipPath);
      throw Error(`Unexpected native command: ${command}`);
    }},
    '@tauri-apps/api/event':{listen:async()=>()=>{}},
    '@tauri-apps/plugin-dialog':{open:async options=>{
      calls.push(['open',options]);
      return pick(options);
    },save:async()=>null},
    'lucide-react':new Proxy({}, {get:()=>()=>null}),
  };
  const exports={};
  const context={module:{exports},exports,require:name=>modules[name]||{},
    h,Fragment:'fragment',console};
  const componentModule=runInNewContext(`${output.outputText}\nmodule.exports`,context,{timeout:2000});
  const set=(name,value)=>{
    const position=hookNames.indexOf(name);
    assert.ok(position>=0,`${name} in component hooks`);
    slots[position]=value;
  };
  const get=name=>slots[hookNames.indexOf(name)];
  const render=()=>{nextHook=0;return componentModule.default({close(){}});};
  render();
  Object.entries({zip:A,cover:initialCover,inspection:inspectedA,
    id:'a',name:'Game A',executable:'GameA.exe',executableReviewKey:reviewedA,
    assetName:'A.zip'}).forEach(([name,value])=>set(name,value));
  const clickZip=()=>{
    const picker=find(render(),node=>node.type==='button'&&node.props['aria-label']==='Cambiar ZIP del juego');
    assert.ok(picker);
    return picker.props.onClick();
  };
  const clickCover=()=>{
    const area=find(render(),node=>node.props?.className==='studio-wide studio-v9-cover');
    assert.ok(area);
    const picker=find(area,node=>node.type==='button');
    assert.ok(picker);
    return picker.props.onClick();
  };
  return {render,set,get,calls,clickZip,clickCover};
}

test('a failed replacement ZIP inspection leaves previously reviewed game A usable',async()=>{
  const box=mount({pick:()=>[B],inspect:async()=>{throw Error('Unsupported ZIP archive');}});
  const previousCreate=find(box.render(),node=>node.type==='button'&&contents(node).includes('Crear y revisar el juego'));
  assert.ok(previousCreate);
  assert.equal(previousCreate.props.disabled,false,'game A is valid and fully reviewed');
  box.clickZip();
  await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(box.calls.filter(([name])=>name==='inspect_standalone_archive').map(([,args])=>args.zipPath),[B]);
  assert.equal(box.get('zip'),A,'a corrupt ZIP B must not replace the last good ZIP A');
  assert.equal(box.get('inspection').sha256,inspectedA.sha256);
  assert.equal(box.get('cover'),COVER);
  assert.equal(box.get('executableReviewKey'),reviewedA);
  const create=find(box.render(),node=>node.type==='button'&&contents(node).includes('Crear y revisar el juego'));
  assert.ok(create);
  assert.equal(create.props.disabled,false,'the host may still prepare A without reselecting it');
  assert.match(box.get('error'),/ZIP|archivo/i,'the invalid ZIP is explained without losing A');
  assert.equal(box.calls.filter(([name])=>name==='create_standalone_draft').length,0);
});

test('a successfully inspected ZIP B commits its metadata and clears only A-dependent consent',async()=>{
  const box=mount({pick:()=>[B],inspect:async()=>inspectedB});
  box.clickZip();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(box.get('zip'),B);
  assert.equal(box.get('cover'),'');
  assert.equal(box.get('inspection').sha256,inspectedB.sha256);
  assert.equal(box.get('id'),'b');
  assert.equal(box.get('name'),'Game B');
  assert.equal(box.get('executable'),'GameB.exe');
  assert.equal(box.get('executableReviewKey'),'','B needs its own executable confirmation');
  const create=find(box.render(),node=>node.type==='button'&&contents(node).includes('Crear y revisar el juego'));
  assert.equal(create.props.disabled,true);
});

test('pending ZIP B inspection cannot overwrite game A or undo a requested switch to a new game',async()=>{
  let releaseInspection;
  const pending=new Promise(resolve=>{releaseInspection=resolve;});
  const box=mount({pick:()=>[B],inspect:()=>pending});
  box.clickZip();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(box.get('zip'),A,'A remains selected during asynchronous B inspection');
  assert.equal(box.get('inspection').sha256,inspectedA.sha256);
  assert.equal(box.get('busy'),true);

  // Even an accidental double click cannot start a second inspection.
  box.clickZip();
  assert.equal(box.calls.filter(([name])=>name==='inspect_standalone_archive').length,1);

  const change=find(box.render(),node=>node.type==='button'&&
    node.props['aria-label']==='Cambiar juego al terminar el proceso');
  assert.ok(change);
  change.props.onClick();
  releaseInspection(inspectedB);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(box.get('zip'),'','user requested a fresh game, never a stale B inspection');
  assert.equal(box.get('inspection'),null);
  assert.equal(box.get('executableReviewKey'),'');
  assert.equal(box.get('busy'),false);
});

test('a manually entered unsupported cover extension is rejected without losing a valid cover',async()=>{
  const box=mount({pick:()=> 'C:\\Games\\installer.exe',inspect:async()=>inspectedA});
  box.clickCover();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(box.get('cover'),COVER,'bad image selection does not replace the original cover');
  assert.equal(box.get('inspection').sha256,inspectedA.sha256);
  assert.match(box.get('error'),/PNG|JPG|WebP|portada/i);
  assert.equal(box.calls.filter(([name])=>name==='inspect_standalone_archive').length,0);
});
