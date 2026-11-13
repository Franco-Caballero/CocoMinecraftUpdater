// Coco2 v27: actual TSX components in deterministic React/Tauri mocks.
// Pure Node: no browser/WebView2, files, games, HTTP, HKCU or production state.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {performance} from 'node:perf_hooks';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const files=await Promise.all(['CatalogHub.tsx','HostStudio.tsx','portable-format.ts',
  'package-activation-drain.ts'].map(file=>readFile(resolve(root,'src',file),'utf8')));
const [catalogText,studioText,portableText,activationText]=files;
const compile=(source,fileName)=>{
  const result=ts.transpileModule(source,{fileName,compilerOptions:{
    target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,
    jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment',
  },reportDiagnostics:true});
  assert.equal(result.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0);
  return result.outputText;
};
const build={
  catalog:compile(catalogText,'CatalogHub.tsx'),
  studio:compile(studioText,'HostStudio.tsx'),
  portable:compile(portableText,'portable-format.ts'),
  activation:compile(activationText,'package-activation-drain.ts'),
};
function helpers(code){
  const exports={};
  return runInNewContext(`${code}\nmodule.exports`,{exports,module:{exports}},{timeout:1800});
}
const portable=helpers(build.portable);
const activation=helpers(build.activation);
function hookNames(text,component){
  const ast=ts.createSourceFile(component+'.tsx',text,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
  const declaration=ast.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name?.text===component);
  assert.ok(declaration);
  const names=[];
  for(const statement of declaration.body.statements){
    if(!ts.isVariableStatement(statement))continue;
    for(const entry of statement.declarationList.declarations){
      let init=entry.initializer;
      if(init&&ts.isAsExpression(init))init=init.expression;
      if(!init||!ts.isCallExpression(init)||!['useState','useRef'].includes(init.expression.getText(ast)))continue;
      names.push(ts.isArrayBindingPattern(entry.name)
        ?entry.name.elements[0].name.getText(ast):entry.name.getText(ast));
    }
  }
  return names;
}
const catalogHooks=hookNames(catalogText,'CatalogHub');
const studioHooks=hookNames(studioText,'HostStudio');
function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
function find(node,predicate){
  if(!node||typeof node!=='object')return null;
  if(Array.isArray(node)){
    for(const child of node){const found=find(child,predicate);if(found)return found;}
    return null;
  }
  if(predicate(node))return node;
  return find(node.children,predicate);
}
function content(node){
  if(typeof node==='string'||typeof node==='number')return String(node);
  if(!node||typeof node!=='object')return '';
  return (Array.isArray(node)?node:node.children||[]).map(content).join(' ');
}

function mount(component,{initialStatus=async()=>({status:'embedded',revision:1,localEntries:1,remoteEntries:0}),
  sync=async()=>({status:'unchanged',revision:2,localEntries:2,remoteEntries:0}),
  nativeImport=async()=>({status:'updated'}),
  hostStudioAvailable=true,
}={}){
  const isCatalog=component==='CatalogHub';
  const names=isCatalog?catalogHooks:studioHooks;
  const slots=[];
  const effects=[];
  const calls=[];
  let hookIndex=0;
  let refreshed=0;
  const react={
    useState(initial){
      const position=hookIndex++;
      if(!(position in slots))slots[position]=initial;
      return [slots[position],value=>{
        slots[position]=typeof value==='function'?value(slots[position]):value;
      }];
    },
    useRef(initial){
      const position=hookIndex++;
      if(!(position in slots))slots[position]={current:initial};
      return slots[position];
    },
    useEffect(effect,deps){effects.push({effect,deps});},
  };
  const h=(type,props,...children)=>({type,props:props||{},children});
  const modules={
    react,
    '@tauri-apps/api/core':{
      isTauri:()=>true,
      invoke:async(command,args)=>{
        calls.push({command,args});
        if(command==='get_catalog_channel_status')return initialStatus();
        if(command==='sync_catalog_channel')return sync();
        if(command==='import_local_publish_package')return nativeImport(args);
        throw new Error('unexpected native command: '+command);
      },
    },
    '@tauri-apps/plugin-dialog':{open:async()=>null,save:async()=>null},
    '@tauri-apps/api/event':{listen:async()=>()=>{}},
    './portable-format':portable,
    './package-activation-drain':activation,
    'lucide-react':new Proxy({}, {get:()=>()=>null}),
  };
  const exports={};
  const context={exports,module:{exports},require:name=>modules[name]||{},
    h,Fragment:'fragment',console};
  const code=isCatalog?build.catalog:build.studio;
  const module=runInNewContext(`${code}\nmodule.exports`,context,{timeout:2000});
  const props=isCatalog?{onChanged:async()=>{refreshed++;},compact:false,hostStudioAvailable}:
    {close(){},onCatalogChanged:async()=>{refreshed++;}};
  const render=()=>{hookIndex=0;return module.default(props);};
  const get=name=>{const pos=names.indexOf(name);assert.ok(pos>=0,`${name} hook exists`);return slots[pos];};
  const set=(name,value)=>{const pos=names.indexOf(name);assert.ok(pos>=0,`${name} hook exists`);slots[pos]=value;};
  const button=text=>{
    const value=find(render(),item=>item.type==='button'&&content(item).includes(text));
    assert.ok(value,`found '${text}' button in actual ${component} TSX`);
    return value;
  };
  render();
  return {render,get,set,button,effects,calls,get refreshed(){return refreshed;}};
}

test('slow mount status cannot overwrite successful newer catalog sync',async()=>{
  const initial=deferred();
  const newer=deferred();
  const app=mount('CatalogHub',{initialStatus:()=>initial.promise,sync:()=>newer.promise});
  // Simulate React's initial effect commit exactly once, including native
  // status fetch; the sync click may settle before that initial request.
  for(const effect of app.effects.splice(0))effect.effect();
  assert.equal(app.calls.filter(x=>x.command==='get_catalog_channel_status').length,1);
  app.button('Sincronizar').props.onClick();
  newer.resolve({status:'updated',revision:42,localEntries:40,remoteEntries:2,
    message:'Catálogo actualizado con cambios'});
  await flush();
  assert.equal(app.get('status').revision,42);
  assert.equal(app.refreshed,1);
  initial.resolve({status:'embedded',revision:1,localEntries:1,remoteEntries:0,message:'viejo'});
  await flush();
  assert.equal(app.get('status').revision,42,
    'stale initial network/status callback must not replace fresher sync state');
  assert.equal(app.get('message'),'Catálogo actualizado con cambios');
});

test('late initial status failure cannot turn a completed successful sync into an error',async()=>{
  const initial=deferred();
  const app=mount('CatalogHub',{initialStatus:()=>initial.promise,
    sync:async()=>({status:'updated',revision:58,localEntries:58,remoteEntries:0,message:'Listo'})});
  for(const effect of app.effects.splice(0))effect.effect();
  app.button('Sincronizar').props.onClick();
  await flush();
  assert.equal(app.get('status').revision,58);
  initial.reject(new Error('old initial read failed'));
  await flush();
  assert.equal(app.get('status').revision,58);
  assert.equal(app.get('error'),'','a completed valid sync must not show old initialization errors');
});

test('initial status arriving after a consented native import cannot roll back the committed catalog',async()=>{
  const initial=deferred();
  const path='C:\\Fixtures\\Game.coco2pack';
  const app=mount('CatalogHub',{initialStatus:()=>initial.promise,
    nativeImport:async()=>({status:'updated',revision:77,localEntries:77,remoteEntries:0})});
  for(const effect of app.effects.splice(0))effect.effect();
  const gate=app.get('reviewGate').current;
  const ticket=gate.begin();
  assert.ok(ticket!==null);
  assert.equal(gate.accept(ticket,path,'native-token-77'),true);
  app.set('reviewState',{id:'game77',name:'Juego 77',sourcePath:path,reviewToken:'native-token-77',
    newVersion:'1.0.0',mode:'new',status:'ready-for-review'});
  app.set('sourcePath',path);
  app.set('reviewTicket',ticket);
  app.set('confirmed',true);
  app.button('Añadir y ver juego').props.onClick();
  await flush();
  assert.equal(app.calls.filter(x=>x.command==='import_local_publish_package').length,1);
  assert.equal(app.get('status').revision,77);
  initial.resolve({status:'embedded',revision:1,localEntries:1,remoteEntries:0});
  await flush();
  assert.equal(app.get('status').revision,77,'late mount read cannot hide accepted local import');
});

test('client cannot reuse a preaccepted review token to bypass host permission',async()=>{
  const app=mount('CatalogHub',{hostStudioAvailable:false});
  const path='C:\\Fixtures\\client-denied.coco2pack';
  const gate=app.get('reviewGate').current;
  const ticket=gate.begin();
  assert.equal(gate.accept(ticket,path,'token-from-old-version'),true);
  app.set('reviewState',{id:'unapproved',name:'No aprobado',sourcePath:path,
    reviewToken:'token-from-old-version',newVersion:'1',mode:'new',status:'ready-for-review'});
  app.set('sourcePath',path);app.set('reviewTicket',ticket);app.set('confirmed',true);
  const tree=app.render();
  assert.equal(find(tree,item=>item.type==='button'&&content(item).includes('Añadir y ver juego')),null);
  assert.equal(app.calls.filter(item=>item.command==='import_local_publish_package').length,0);
  assert.ok(content(tree).includes('anfitrión'));
});

test('HostStudio does not claim imported on native nonaccepted status or refresh the library',async()=>{
  const app=mount('HostStudio',{nativeImport:async()=>({status:'degraded',message:'not committed'})});
  app.set('result',{id:'synthetic',requiredFilesCount:1});
  app.set('publishArtifact',{id:'synthetic',artifactPath:'C:\\Fixture\\a.coco2pack'});
  app.set('localReview',{id:'synthetic',reviewToken:'review-SHA-1',newVersion:'1.0.0',
    sourcePath:'C:\\Fixture\\a.coco2pack',status:'ready-for-review'});
  app.set('localConsent',true);
  app.button('Añadir a mi catálogo').props.onClick();
  await flush();
  assert.equal(app.calls.filter(x=>x.command==='import_local_publish_package').length,1);
  assert.equal(app.calls.find(x=>x.command==='import_local_publish_package').args.confirmed,true);
  assert.equal(app.get('localImported'),false,'not-accepted native status is not an import receipt');
  assert.equal(app.refreshed,0,'library refresh must not claim unaccepted import');
  assert.equal(app.get('localConsent'),false,'a new read-only review is required before a retry');
  assert.equal(app.get('localReview'),null);
  assert.match(app.get('error'),/confirm|incorpor|revis/i);
});

test('HostStudio accepts updated and unchanged native receipts without duplicate import',async()=>{
  for(const status of ['updated','unchanged']){
    const app=mount('HostStudio',{nativeImport:async()=>({status})});
    app.set('result',{id:'synthetic',requiredFilesCount:1});
    app.set('publishArtifact',{id:'synthetic',artifactPath:'C:\\Fixture\\a.coco2pack'});
    app.set('localReview',{id:'synthetic',reviewToken:'review-SHA-1',newVersion:'1.0.0',
      sourcePath:'C:\\Fixture\\a.coco2pack',status:'ready-for-review'});
    app.set('localConsent',true);
    const click=app.button('Añadir a mi catálogo').props.onClick;
    click();click();
    await flush();
    assert.equal(app.get('localImported'),true);
    assert.equal(app.refreshed,1);
    assert.equal(app.calls.filter(x=>x.command==='import_local_publish_package').length,1);
  }
});

test('synthetic Node-only 2,048 card preview search has bounded CPU; not WebView2 paint',()=>{
  const records=Array.from({length:2048},(_,index)=>({id:`game-${index}`,
    title:index%7===0?`Júego Español ${index}`:`Game ${index}`}));
  const start=performance.now();
  let count=0;
  for(let query=0;query<200;query++){
    const term=query%2?'game':'juego';
    count+=records.filter(item=>item.title.normalize('NFD').replace(/[\u0300-\u036f]/g,'')
      .toLowerCase().includes(term)).length;
  }
  const elapsed=performance.now()-start;
  assert.ok(count>0);
  assert.ok(elapsed<3000,`synthetic 2048x200 strings: ${elapsed.toFixed(1)}ms`);
  console.log(`SYNTHETIC NODE only: 2,048 records x 200 queries; ${elapsed.toFixed(1)} ms, NOT WebView2 render/focus measurement`);
});
