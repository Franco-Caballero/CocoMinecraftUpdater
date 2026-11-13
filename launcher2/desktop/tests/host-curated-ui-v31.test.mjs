// v31 RED contract for a host-curated ONLY client library. DO NOT weaken these
// tests by allowing unsigned .coco2pack consent to bypass host approval.
// Transpiles and renders the ORIGINAL FirstRun/CatalogHub TSX, with synthetic
// React and Tauri IPC. This is NOT an actual Windows WebView2/E2E run.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {performance} from 'node:perf_hooks';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [firstText,hubText,portableText,activationText]=await Promise.all([
  'FirstRun.tsx','CatalogHub.tsx','portable-format.ts','package-activation-drain.ts',
].map(name=>readFile(resolve(root,'src',name),'utf8')));
const compile=(source,name)=>{
  const output=ts.transpileModule(source,{fileName:name,reportDiagnostics:true,
    compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,
      jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment'}});
  assert.equal(output.diagnostics?.filter(issue=>issue.category===ts.DiagnosticCategory.Error).length??0,0,
    `${name} should transpile as its real implementation`);
  return output.outputText;
};
const compiled={
  first:compile(firstText,'FirstRun.tsx'),
  hub:compile(hubText,'CatalogHub.tsx'),
  portable:compile(portableText,'portable-format.ts'),
  activation:compile(activationText,'package-activation-drain.ts'),
};
function pureModule(code){
  const exports={};
  return runInNewContext(code+'\nmodule.exports',
    {exports,module:{exports}},{timeout:1500});
}
const portable=pureModule(compiled.portable);
const activation=pureModule(compiled.activation);
const h=(type,props,...children)=>({type,props:props||{},children});
const textOf=node=>typeof node==='string'||typeof node==='number'?String(node):
  !node||typeof node!=='object'?'':
  (Array.isArray(node)?node:node.children||[]).map(textOf).join(' ');
function all(node,predicate,found=[]){
  if(!node||typeof node!=='object')return found;
  if(Array.isArray(node)){
    for(const child of node)all(child,predicate,found);
    return found;
  }
  if(predicate(node))found.push(node);
  all(node.children,predicate,found);
  return found;
}
function buttons(tree){return all(tree,item=>item.type==='button');}
function button(tree,phrase){
  return buttons(tree).find(item=>textOf(item).includes(phrase))||null;
}
const flush=async()=>{for(let i=0;i<24;i++)await Promise.resolve();};
const syntheticPath='C:\\Synthetic\\NoAprobado.coco2pack';
const reviewed={id:'not-host-approved',mode:'new',newVersion:'1.0.0',
  sourcePath:syntheticPath,reviewToken:'synthetic-local-token',
  archiveSha256:'a'.repeat(64),manifestSha256:'b'.repeat(64),
  status:'ready-for-review',name:'Juego sin aprobación del host',
  description:'Paquete sintético recibido por Explorer',executable:'Game.exe',
  requiredFilesCount:2};

function firstRun({hostStudioAvailable=undefined,catalogReady=false}={}){
  const events=[];
  const exports={};
  const module=runInNewContext(compiled.first+'\nmodule.exports',{
    exports,module:{exports},
    require:()=>new Proxy({}, {get:()=>()=>null}),
    h,Fragment:'fragment',
  },{timeout:1800});
  const tree=module.default({...hostStudioAvailable===undefined?{}:{hostStudioAvailable},catalogReady,networkState:'offline',
    networkRequiresApproval:false,
    onExplore:()=>events.push('explore'),onOpenPackage:()=>events.push('picker'),
    onNetwork:()=>events.push('network'),onDismiss:()=>events.push('dismiss')});
  return {tree,events};
}
function hookNames(source,name){
  const ast=ts.createSourceFile(name+'.tsx',source,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
  const declaration=ast.statements.find(statement=>ts.isFunctionDeclaration(statement)&&statement.name?.text===name);
  assert.ok(declaration,`original ${name} function is required`);
  const names=[];
  for(const statement of declaration.body.statements){
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
const names=hookNames(hubText,'CatalogHub');
function mountCatalog({hostStudioAvailable=false,incomingPath=undefined,pickerRequestId=0,
  nativeReview=async()=>reviewed,
  openPicker=async()=>null,
  sync=async()=>({status:'updated',revision:9,localEntries:0,remoteEntries:9,
    remoteSequence:9,message:'Catálogo del anfitrión sincronizado'}),
}={}){
  const slots=[],effects=[],calls=[];
  let hookIndex=0,done=0,consumed=0,refreshed=0,imported=0,opened=0;
  const react={
    useState(initial){
      const index=hookIndex++;
      if(!(index in slots))slots[index]=initial;
      return [slots[index],value=>{
        slots[index]=typeof value==='function'?value(slots[index]):value;
      }];
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
        if(command==='host_studio_available')return hostStudioAvailable;
        if(command==='get_catalog_channel_status')return {status:'embedded',revision:1,
          localEntries:0,remoteEntries:0,remoteSequence:0,message:'Biblioteca incluida'};
        if(command==='sync_catalog_channel')return sync();
        if(command==='review_local_publish_package')return nativeReview(args?.path);
        if(command==='import_local_publish_package')return {status:'updated',revision:10,
          localEntries:1,remoteEntries:9,remoteSequence:9,message:'Local imported'};
        throw Error(`Unexpected IPC ${command}`);
      },
    },
    '@tauri-apps/plugin-dialog':{
      open:async()=>{opened++;return openPicker();},
    },
    './portable-format':portable,
    './package-activation-drain':activation,
    'lucide-react':new Proxy({}, {get:()=>()=>null}),
  };
  const exports={};
  const mod=runInNewContext(compiled.hub+'\nmodule.exports',{
    exports,module:{exports},require:name=>modules[name]||{},
    h,Fragment:'fragment',console,
  },{timeout:2200});
  const props={hostStudioAvailable,onChanged:async()=>{refreshed++;},
    onImported:()=>{imported++;},onInboxDone:()=>{done++;},
    compact:false,incomingPath,pendingCount:1,pickerRequestId,
    onPickerRequestConsumed:()=>{consumed++;}};
  const get=name=>{
    const index=names.indexOf(name);
    assert.ok(index>=0,`${name} hook must exist in original CatalogHub`);
    return slots[index];
  };
  const set=(name,value)=>{slots[names.indexOf(name)]=value;};
  function render(){hookIndex=0;effects.length=0;return mod.default(props);}
  function setCapability(value){props.hostStudioAvailable=value;render();}
  function runEffects(){
    const jobs=[...effects];effects.length=0;
    for(const job of jobs)job.effect();
  }
  render();
  return {render,setCapability,runEffects,get,set,calls,
    get done(){return done;},get consumed(){return consumed;},
    get refreshed(){return refreshed;},get imported(){return imported;},
    get opened(){return opened;}};
}

test('client empty catalog shows useful host-curated information, never package CTA',()=>{
  const {tree,events}=firstRun({hostStudioAvailable:false,catalogReady:false});
  assert.match(textOf(tree),/anfitri[oó]n/i);
  assert.match(textOf(tree),/aprobad|verificad|cat[aá]logo/i);
  assert.equal(buttons(tree).filter(item=>/abrir.*paquete|recib[ií].*paquete|instal.*paquete/i
    .test(textOf(item))).length,0,'client may not open unsigned package picker');
  assert.doesNotMatch(textOf(tree),/acepta e instala cuando quieras/i);
  assert.deepEqual(events,[]);
});

test('missing capability must fail closed: unknown host is not a temporary importer',()=>{
  const {tree}=firstRun({catalogReady:false});
  assert.equal(button(tree,'Abrir paquete de un amigo'),null);
  assert.match(textOf(tree),/anfitri[oó]n/i);
  const app=mountCatalog({hostStudioAvailable:undefined});
  assert.equal(button(app.render(),'Abrir paquete Coco'),null);
  assert.match(textOf(app.render()),/anfitri[oó]n/i);
});

test('client with catalog can explore approved games, without manual ZIP/package injection',()=>{
  const {tree,events}=firstRun({hostStudioAvailable:false,catalogReady:true});
  const explore=button(tree,'Explorar juegos');
  assert.ok(explore);assert.notEqual(explore.props.disabled,true);
  explore.props.onClick();
  assert.deepEqual(events,['explore']);
  assert.equal(buttons(tree).filter(item=>/abrir.*paquete|recib[ií].*paquete/i
    .test(textOf(item))).length,0);
});

test('host authoring profile stays explicitly separate from a client and requires user intent',()=>{
  const {tree,events}=firstRun({hostStudioAvailable:true,catalogReady:true});
  assert.deepEqual(events,[],'host-only authoring never auto-opens picker');
  assert.ok(button(tree,'Explorar juegos'));
});

test('client CatalogHub has sync but no picker, import control or legacy-folder affordance',async()=>{
  const app=mountCatalog({hostStudioAvailable:false});
  app.runEffects();await flush();
  const tree=app.render();
  assert.ok(button(tree,'Sincronizar'),'signed/embedded channel sync is still available');
  assert.equal(button(tree,'Abrir paquete Coco'),null);
  assert.equal(all(tree,item=>item.type==='button'&&/elegir carpeta/i.test(textOf(item))).length,0);
  assert.doesNotMatch(textOf(tree),/Paquete anterior|Elegir carpeta|Añadir y ver juego/i);
  assert.match(textOf(tree),/anfitri[oó]n/i);
  assert.equal(app.opened,0);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('queued old first-run picker intent is consumed on client WITHOUT opening native picker',async()=>{
  const app=mountCatalog({hostStudioAvailable:false,pickerRequestId:7});
  app.runEffects();await flush();
  assert.equal(app.consumed,1,'old host/first-run intent must be explicitly consumed');
  assert.equal(app.opened,0,'client cannot open a picker from leftover first-run request');
  assert.equal(app.calls.filter(c=>c.command==='review_local_publish_package').length,0);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('revoking dev capability while native picker is pending suppresses its late selection',async()=>{
  let release;
  const pending=new Promise(resolve=>{release=resolve;});
  const app=mountCatalog({hostStudioAvailable:true,openPicker:()=>pending});
  const hostButton=button(app.render(),'Abrir paquete Coco');
  assert.ok(hostButton);
  hostButton.props.onClick();
  assert.equal(app.opened,1);
  app.setCapability(false);
  assert.equal(button(app.render(),'Abrir paquete Coco'),null);
  release(syntheticPath);
  await flush();
  assert.equal(app.calls.filter(c=>c.command==='review_local_publish_package').length,0,
    'late host selection may not begin a new local import review as client');
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('Explorer .coco2pack on a client is read-only review and rejection, NEVER consent/import',async()=>{
  const app=mountCatalog({hostStudioAvailable:false,incomingPath:syntheticPath});
  app.runEffects();await flush();
  assert.equal(app.calls.filter(c=>c.command==='review_local_publish_package').length,0,
    'client Explorer must not call unsigned local native review, which is forbidden in Rust');
  const preview=app.render();
  assert.match(textOf(preview),/Archivo externo sin aprobaci[oó]n del anfitri[oó]n/i);
  assert.match(textOf(preview),/anfitri[oó]n|no aprob/i);
  assert.equal(all(preview,item=>item.type==='input'&&item.props.type==='checkbox').length,0,
    'client must never consent to import an unsigned package');
  assert.equal(buttons(preview).filter(item=>/Añadir y ver juego|Ver juego en mi biblioteca|Añadir a/i
    .test(textOf(item))).length,0);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
  const dismiss=button(preview,'Descartar sin importar')||button(preview,'Ahora no');
  assert.ok(dismiss,'client can reject Explorer request');
  dismiss.props.onClick();
  assert.equal(app.done,1,'native inbox is acknowledged when user discards');
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('Explorer client review Escape dismisses, and a forged prior consent cannot surface commit',async()=>{
  const app=mountCatalog({hostStudioAvailable:false,incomingPath:syntheticPath});
  app.runEffects();await flush();
  assert.equal(app.calls.filter(c=>c.command==='review_local_publish_package').length,0);
  app.set('confirmed',true); // adversarial persisted stale consent from prior UI session
  const tree=app.render();
  assert.equal(buttons(tree).filter(item=>/Añadir y ver juego|Ver juego en mi biblioteca/i.test(textOf(item))).length,0);
  const dismiss=button(tree,'Ahora no');
  assert.ok(dismiss,'client must be able to discard a non-approved incoming package');
  dismiss.props.onClick();
  assert.equal(app.done,1);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
});

test('revoked authoring capability fences a previously captured host accept handler',async()=>{
  const app=mountCatalog({hostStudioAvailable:true,incomingPath:syntheticPath});
  app.runEffects();await flush();
  app.set('confirmed',true);
  const priorHostAccept=button(app.render(),'Añadir y ver juego');
  assert.ok(priorHostAccept&&!priorHostAccept.props.disabled);
  app.setCapability(false);
  assert.equal(button(app.render(),'Añadir y ver juego'),null);
  priorHostAccept.props.onClick();
  await flush();
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0,
    'host action captured before permission change must fail closed at invocation');
});

test('host=true preserves explicit native host reviewed workflow, no automatic import',async()=>{
  const app=mountCatalog({hostStudioAvailable:true,incomingPath:syntheticPath});
  app.runEffects();await flush();
  assert.equal(app.calls.filter(c=>c.command==='review_local_publish_package').length,1);
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
  const tree=app.render();
  const consent=all(tree,item=>item.type==='input'&&item.props?.type==='checkbox')[0];
  assert.ok(consent,'host dev workspace retains explicit review/consent');
  assert.equal(consent.props.checked,false);
  assert.equal(button(tree,'Añadir y ver juego')?.props.disabled,true);
  consent.props.onChange({target:{checked:true}});
  const accept=button(app.render(),'Añadir y ver juego');
  assert.notEqual(accept.props.disabled,true);
  accept.props.onClick();
  await flush();
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,1);
  assert.equal(app.done,1);
});

test('client channel sync remains native and read-only; 2K synthetic catalog is not UI timing',async()=>{
  const app=mountCatalog({hostStudioAvailable:false});
  app.runEffects();await flush();
  const sync=button(app.render(),'Sincronizar');
  sync.props.onClick();await flush();
  assert.equal(app.calls.filter(c=>c.command==='sync_catalog_channel').length,1);
  assert.equal(app.refreshed,1,'accepted official catalog refresh remains available');
  assert.equal(app.calls.filter(c=>c.command==='import_local_publish_package').length,0);
  const sourceIds=Array.from({length:2048},(_,i)=>`juego-${i}`);
  const start=performance.now();
  let selected=0;
  for(let i=0;i<200;i++)selected+=sourceIds.filter(id=>id.includes(i%2?'o-':'jue')).length;
  const ms=performance.now()-start;
  assert.ok(selected>0);
  assert.ok(ms<3000,`2K metadata-only Node benchmark ${ms.toFixed(1)}ms`);
  console.log(`SYNTHETIC Node only: 2,048 ids × 200 filters = ${ms.toFixed(1)}ms; NOT WebView2 rendering, focus, keyboard or small-screen verification`);
});
