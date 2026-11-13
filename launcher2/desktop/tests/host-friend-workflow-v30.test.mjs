// Coco2 v30: exercise ORIGINAL HostStudio/CatalogHub TSX handlers in React/Tauri
// VM. Synthetic responses only; no app, browsers, network, games or HKCU.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {performance} from 'node:perf_hooks';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [hostText,hubText,portableText,activationText]=await Promise.all([
  'HostStudio.tsx','CatalogHub.tsx','portable-format.ts','package-activation-drain.ts',
].map(name=>readFile(resolve(root,'src',name),'utf8')));
function transpile(source,name){
  const output=ts.transpileModule(source,{fileName:name,
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
      jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment'},
    reportDiagnostics:true});
  assert.equal(output.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0,
    `${name}: original TSX must compile`);
  return output.outputText;
}
const compiled={host:transpile(hostText,'HostStudio.tsx'),
  hub:transpile(hubText,'CatalogHub.tsx'),
  portable:transpile(portableText,'portable-format.ts'),
  activation:transpile(activationText,'package-activation-drain.ts')};
function unmockedModule(code){
  const exports={};return runInNewContext(`${code}\nmodule.exports`,
    {exports,module:{exports}},{timeout:1800});
}
const portable=unmockedModule(compiled.portable);
const activation=unmockedModule(compiled.activation);
function namesFor(source,component){
  const ast=ts.createSourceFile(`${component}.tsx`,source,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
  const fn=ast.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name?.text===component);
  assert.ok(fn,`original ${component} function exists`);
  const names=[];
  for(const statement of fn.body.statements){
    if(!ts.isVariableStatement(statement))continue;
    for(const entry of statement.declarationList.declarations){
      let init=entry.initializer;
      if(init&&ts.isAsExpression(init))init=init.expression;
      if(!init||!ts.isCallExpression(init)||
        !['useState','useRef'].includes(init.expression.getText(ast)))continue;
      names.push(ts.isArrayBindingPattern(entry.name)?entry.name.elements[0].name.getText(ast):
        entry.name.getText(ast));
    }
  }
  return names;
}
const hostHooks=namesFor(hostText,'HostStudio');
const hubHooks=namesFor(hubText,'CatalogHub');
async function settle(){for(let i=0;i<18;i++)await Promise.resolve();}
function deferred(){let resolve,reject;const promise=new Promise((ok,no)=>{resolve=ok;reject=no;});return {promise,resolve,reject};}
function find(node,predicate){
  if(!node||typeof node!=='object')return null;
  if(Array.isArray(node)){
    for(const child of node){const match=find(child,predicate);if(match)return match;}
    return null;
  }
  if(predicate(node))return node;
  return find(node.children,predicate);
}
function textOf(node){
  if(typeof node==='string'||typeof node==='number')return String(node);
  if(!node||typeof node!=='object')return '';
  return (Array.isArray(node)?node:node.children||[]).map(textOf).join(' ');
}
const h=(type,props,...children)=>({type,props:props||{},children});

function mount(component,{
  nativeReview=async(path)=>reviewFor(path),
  nativeImport=async()=>({status:'updated'}),
  sync=async()=>({status:'updated',revision:20,localEntries:20,remoteEntries:0,message:'Catálogo al día'}),
  refresh=async()=>{},
}={}){
  const isHost=component==='HostStudio';
  const hooks=isHost?hostHooks:hubHooks;
  const slots=[];
  const calls=[];
  const effects=[];
  let hookIndex=0,refreshCount=0;
  const react={
    useState(initial){
      const index=hookIndex++;
      if(!(index in slots))slots[index]=initial;
      return [slots[index],value=>{slots[index]=typeof value==='function'?value(slots[index]):value;}];
    },
    useRef(initial){
      const index=hookIndex++;
      if(!(index in slots))slots[index]={current:initial};
      return slots[index];
    },
    useEffect(effect,deps){effects.push({effect,deps});},
  };
  const modules={
    react,
    '@tauri-apps/api/core':{
      isTauri:()=>true,
      invoke:async(command,args)=>{
        calls.push({command,args});
        if(command==='review_local_publish_package')return nativeReview(args.path);
        if(command==='import_local_publish_package')return nativeImport(args);
        if(command==='sync_catalog_channel')return sync();
        if(command==='get_catalog_channel_status')return {status:'embedded',revision:1,
          localEntries:1,remoteEntries:0};
        throw Error('unexpected native operation '+command);
      },
    },
    '@tauri-apps/api/event':{listen:async()=>()=>{}},
    '@tauri-apps/plugin-dialog':{open:async()=>null,save:async()=>null},
    'lucide-react':new Proxy({}, {get:()=>()=>null}),
    './portable-format':portable,
    './package-activation-drain':activation,
    './host-studio-v9.css':{},
  };
  const exports={};
  const module=runInNewContext(`${isHost?compiled.host:compiled.hub}\nmodule.exports`,
    {exports,module:{exports},require:name=>modules[name]||{},h,Fragment:'fragment',console},
    {timeout:2200});
  const getPosition=name=>{
    const index=hooks.indexOf(name);
    assert.ok(index>=0,`${component} hook ${name} is present in original TSX`);
    return index;
  };
  const get=name=>slots[getPosition(name)];
  const set=(name,value)=>{slots[getPosition(name)]=value;};
  let closed=0;
  const props=isHost?{close:()=>closed++,onCatalogChanged:async()=>{refreshCount++;return refresh();}}:
    {onChanged:async()=>{refreshCount++;return refresh();},compact:false};
  function render(){hookIndex=0;effects.length=0;return module.default(props);}
  function button(contains){
    const found=find(render(),element=>element.type==='button'&&textOf(element).includes(contains));
    assert.ok(found,`${component}: real button '${contains}'`);
    return found;
  }
  render();
  return {get,set,render,button,effects,calls,get refreshed(){return refreshCount;},get closed(){return closed;}};
}
const ARTIFACT='C:\\Demo\\Juego.coco2pack';
function reviewFor(path=ARTIFACT,id='juego',extra={}){
  return {id,sourcePath:path,status:'ready-for-review',reviewToken:'native-proof',
    newVersion:'2.0.0',mode:'new',archiveSha256:'a'.repeat(64),
    manifestSha256:'b'.repeat(64),...extra};
}
function preparedHost(box){
  box.set('result',{id:'juego',requiredFilesCount:8});
  box.set('publishArtifact',{id:'juego',artifactPath:ARTIFACT,
    status:'prepared-local',artifactSha256:'a'.repeat(64)});
}

test('Host Studio refuses consent on a review for a different native package path',async()=>{
  const app=mount('HostStudio',{nativeReview:async()=>
    reviewFor('D:\\Unrelated\\other.coco2pack','juego')});
  preparedHost(app);
  app.button('Probar en mi biblioteca').props.onClick();
  await settle();
  assert.equal(app.calls.filter(c=>c.command==='review_local_publish_package').length,1);
  assert.equal(app.calls[0].args.path,ARTIFACT);
  assert.equal(app.get('localReview'),null,'wrong native package must not appear for consent');
  assert.equal(app.get('localConsent'),false);
  assert.match(app.get('error'),/revisi[oó]n|paquete|coincide/i);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('Host Studio refuses a review with the right path but another game ID or invalid token',async()=>{
  for(const nativeReview of [
    async()=>reviewFor(ARTIFACT,'another-game'),
    async()=>reviewFor(ARTIFACT,'juego',{reviewToken:'',status:'unchanged'}),
  ]){
    const app=mount('HostStudio',{nativeReview});
    preparedHost(app);
    app.button('Probar en mi biblioteca').props.onClick();
    await settle();
    assert.equal(app.get('localReview'),null,'mismatched ID/token cannot be consented');
    assert.equal(app.get('localConsent'),false);
  }
});

test('after a crossed review, a new explicit native review recovers without carrying old consent',async()=>{
  let attempts=0;
  const app=mount('HostStudio',{nativeReview:async()=>++attempts===1?
    reviewFor('C:\\Wrong\\other.coco2pack'):
    reviewFor('\\\\?\\C:\\Demo\\Juego.coco2pack')});
  preparedHost(app);
  app.button('Probar en mi biblioteca').props.onClick();
  await settle();
  assert.equal(app.get('localReview'),null);
  app.button('Probar en mi biblioteca').props.onClick();
  await settle();
  assert.equal(attempts,2);
  assert.equal(app.get('localReview')?.id,'juego');
  assert.equal(app.get('localConsent'),false);
  assert.equal(app.get('error'),'');
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('canonical matching native review remains read-only until deliberate consent and one import',async()=>{
  const app=mount('HostStudio',{nativeReview:async()=>reviewFor('\\\\?\\C:\\Demo\\Juego.coco2pack')});
  preparedHost(app);
  app.button('Probar en mi biblioteca').props.onClick();
  await settle();
  assert.equal(app.get('localReview')?.id,'juego');
  assert.equal(app.get('localConsent'),false);
  assert.equal(app.button('Añadir a mi catálogo').props.disabled,true);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
  const consent=find(app.render(),e=>e.type==='input'&&e.props?.type==='checkbox'&&
    e.props?.checked===false&&e.props?.onChange);
  assert.ok(consent);
  consent.props.onChange({target:{checked:true}});
  const click=app.button('Añadir a mi catálogo').props.onClick;
  click();click();
  await settle();
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,1);
  assert.equal(app.get('localImported'),true);
  assert.equal(app.refreshed,1);
});

test('native successful sync stays successful even if post-sync UI refresh fails',async()=>{
  const app=mount('CatalogHub',{refresh:async()=>{throw Error('synthetic UI refresh failed');}});
  app.button('Sincronizar').props.onClick();
  await settle();
  assert.equal(app.calls.filter(c=>c.command==='sync_catalog_channel').length,1);
  assert.equal(app.get('status')?.status,'updated','native update was accepted');
  assert.equal(app.refreshed,1);
  assert.equal(app.get('error'),'','refresh error cannot claim native sync failed');
  assert.match(app.get('message'),/sincronizad|actualizad/i,
    'user must receive honest success-with-display-warning status');
  assert.doesNotMatch(app.get('message'),/cat[aá]logo anterior|no se pudo sincronizar/i);
});

test('actual failed native sync still reports an error and does not call UI refresh',async()=>{
  const app=mount('CatalogHub',{sync:async()=>{throw Error('synthetic offline');}});
  app.button('Sincronizar').props.onClick();
  await settle();
  assert.match(app.get('error'),/No se pudo sincronizar/);
  assert.equal(app.get('status'),null);
  assert.equal(app.refreshed,0);
});

test('pending sync second click is single-flight, then next deliberate click retries',async()=>{
  const delayed=deferred();let call=0;
  const app=mount('CatalogHub',{sync:()=>{call++;return call===1?delayed.promise:
    Promise.resolve({status:'unchanged',revision:22,localEntries:22,remoteEntries:0});}});
  const click=app.button('Sincronizar').props.onClick;
  click();click();
  assert.equal(call,1);
  delayed.resolve({status:'updated',revision:21,localEntries:21,remoteEntries:0});
  await settle();
  app.button('Sincronizar').props.onClick();
  await settle();
  assert.equal(call,2);
});

test('2,048 item metadata searching in pure Node is bounded, NOT WebView2 focus/paint',()=>{
  const titles=Array.from({length:2048},(_,i)=>i%11===0?`Júego ${i}`:`Game ${i}`);
  const start=performance.now();let hits=0;
  for(let q=0;q<200;q++){
    const term=q%2?'game':'juego';
    hits+=titles.filter(name=>name.normalize('NFD').replace(/[\u0300-\u036f]/g,'')
      .toLowerCase().includes(term)).length;
  }
  const elapsed=performance.now()-start;
  assert.ok(hits>0);
  assert.ok(elapsed<3000,`synthetic 2048×200 pure JS search: ${elapsed.toFixed(1)}ms`);
  console.log(`SYNTHETIC Node 2,048 titles x 200 searches = ${elapsed.toFixed(1)}ms CPU; NOT WebView2 paint, input latency or memory`);
});
