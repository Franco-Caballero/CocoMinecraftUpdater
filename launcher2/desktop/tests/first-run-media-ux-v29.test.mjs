// Coco2 v29: original FirstRun/MediaPlayer TSX event handlers with synthetic
// React hooks and native-media mocks; pure Node, no WebView2, HTTP, HKCU or games.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {performance} from 'node:perf_hooks';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const [playerSource,firstSource,controlsSource,poolSource,progressSource]=await Promise.all([
  'MediaPlayer.tsx','FirstRun.tsx','media-playback-controls.ts','hover-video-pool.ts','media-progress.ts',
].map(name=>readFile(resolve(root,'src',name),'utf8')));
function transpile(source,fileName){
  const output=ts.transpileModule(source,{fileName,reportDiagnostics:true,
    compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,
      jsx:ts.JsxEmit.React,jsxFactory:'h',jsxFragmentFactory:'Fragment'}});
  assert.equal(output.diagnostics?.filter(d=>d.category===ts.DiagnosticCategory.Error).length??0,0,
    `${fileName} must transpile as real TSX/TS`);
  return output.outputText;
}
const compiled={
  player:transpile(playerSource,'MediaPlayer.tsx'),
  first:transpile(firstSource,'FirstRun.tsx'),
  controls:transpile(controlsSource,'media-playback-controls.ts'),
  pool:transpile(poolSource,'hover-video-pool.ts'),
  progress:transpile(progressSource,'media-progress.ts'),
};
function evaluate(code,env={}){
  const exports={};
  return runInNewContext(`${code}\nmodule.exports`,{exports,module:{exports},...env},{timeout:2000});
}
const controls=evaluate(compiled.controls);
const mediaPool=evaluate(compiled.pool);
const mediaProgress=evaluate(compiled.progress);
const h=(type,props,...children)=>({type,props:props||{},children});
function find(node,predicate){
  if(!node||typeof node!=='object')return null;
  if(Array.isArray(node)){
    for(const child of node){const found=find(child,predicate);if(found)return found;}
    return null;
  }
  if(predicate(node))return node;
  return find(node.children,predicate);
}
const label=node=>typeof node==='string'||typeof node==='number'?String(node):
  !node?'':(Array.isArray(node)?node:node.children||[]).map(label).join(' ');
function delayed(){
  let resolve,reject;
  const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
}
async function settle(){for(let i=0;i<15;i++)await Promise.resolve();}

const playerAst=ts.createSourceFile('MediaPlayer.tsx',playerSource,
  ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const playerFunction=playerAst.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name?.text==='MediaPlayer');
assert.ok(playerFunction,'actual MediaPlayer function required');
const hooks=[];
for(const statement of playerFunction.body.statements){
  if(!ts.isVariableStatement(statement))continue;
  for(const decl of statement.declarationList.declarations){
    if(decl.initializer&&ts.isCallExpression(decl.initializer)&&
      ['useState','useRef'].includes(decl.initializer.expression.getText(playerAst))){
      hooks.push(ts.isArrayBindingPattern(decl.name)?decl.name.elements[0].name.getText(playerAst):decl.name.getText(playerAst));
    }
  }
}
assert.ok(hooks.includes('videoRef'));
assert.ok(hooks.includes('playEpoch'));

function syntheticVideo(name){
  return {name,paused:true,currentTime:42,duration:120,muted:false,isConnected:true,
    plays:0,loads:0,pauses:0,
    play(){this.plays++;this.paused=false;return Promise.resolve();},
    pause(){this.pauses++;this.paused=true;},
    load(){this.loads++;},
    removeAttribute(){},
  };
}
function mountPlayer({onReopen=async()=>false}={}){
  const slots=[];
  const effects=[];
  let currentIndex=0;
  let closeCount=0;
  let props={title:'Demo local',url:'https://synthetic.invalid/token-A',
    mimeType:'video/mp4',onClose:()=>{closeCount++;},onReopen};
  const react={
    useState(initial){
      const index=currentIndex++;
      if(!(index in slots))slots[index]=initial;
      return [slots[index],newValue=>{
        slots[index]=typeof newValue==='function'?newValue(slots[index]):newValue;
      }];
    },
    useRef(initial){
      const index=currentIndex++;
      if(!(index in slots))slots[index]={current:initial};
      return slots[index];
    },
    useEffect(effect,deps){effects.push({effect,deps});},
  };
  const modules={react,'./media-playback-controls':controls,'./media-progress':mediaProgress,
    '@tauri-apps/api/core':{isTauri:()=>false},'./native-playback':{useNativePlayback(){}},
    'lucide-react':new Proxy({}, {get:()=>()=>null})};
  const module=evaluate(compiled.player,{require:name=>modules[name]||{},h,
    Fragment:'fragment',console,queueMicrotask,
    // The exit animation closes after a short timer; run it at once here.
    window:{setTimeout:fn=>{fn();return 1;},clearTimeout(){},setInterval:()=>1,clearInterval(){}}});
  let cleanup=()=>{};
  function render(){
    currentIndex=0;effects.length=0;
    return module.default(props);
  }
  function activate(video){
    slots[hooks.indexOf('videoRef')].current=video;
    slots[hooks.indexOf('dialogRef')].current={focus(){}};
    const next=effects.find(e=>Array.isArray(e.deps)&&e.deps.length===1);
    assert.ok(next,'actual media player URL effect');
    cleanup=next.effect()||(()=>{});
  }
  function reroute(url,video){
    cleanup();
    props={...props,url};
    render();
    activate(video);
  }
  const get=name=>slots[hooks.indexOf(name)]?.current!==undefined&&
    ['videoRef','playEpoch','retryBusy','lastPosition','resumeAfterRefresh','resumeFromUrl'].includes(name)
      ?slots[hooks.indexOf(name)].current:slots[hooks.indexOf(name)];
  const mediaNode=()=>find(render(),n=>n.type==='video');
  const dialogNode=()=>find(render(),n=>n.props?.role==='dialog');
  return {render,activate,reroute,get,mediaNode,dialogNode,
    get closeCount(){return closeCount;},
    retryButton(){const button=find(render(),n=>n.type==='button'&&label(n).includes('Reintentar'));
      assert.ok(button,'real TSX retry button exists after a media error');return button;},
  };
}

test('host-authoring welcome with damaged/empty catalog can still inspect local draft without dismissal',()=>{
  const events=[];
  const module=evaluate(compiled.first,{require:()=>new Proxy({}, {get:()=>()=>null}),h,Fragment:'fragment'});
  const tree=module.default({catalogReady:false,hostStudioAvailable:true,networkState:'offline',networkRequiresApproval:false,
    onExplore:()=>events.push('explore'),onOpenPackage:()=>events.push('picker'),
    onNetwork:()=>events.push('network'),onDismiss:()=>events.push('dismiss')});
  const picker=find(tree,n=>n.type==='button'&&label(n).includes('Revisar paquete local'));
  const explore=find(tree,n=>n.type==='button'&&label(n).includes('Explorar juegos'));
  assert.ok(picker);assert.equal(Boolean(picker.props.disabled),false);
  assert.ok(explore);assert.equal(explore.props.disabled,true);
  picker.props.onClick();
  assert.deepEqual(events,['picker'],'real callback must not dismiss welcome or install anything');
});

test('player Escape shortcut closes dialog, even with video playback focused',()=>{
  const app=mountPlayer();
  app.render();const video=syntheticVideo('A');app.activate(video);
  let prevented=0,stopped=0;
  const dialog=app.dialogNode();
  dialog.props.onKeyDown({key:'Escape',target:{tagName:'DIV',hasAttribute:()=>false},
    ctrlKey:false,metaKey:false,altKey:false,
    preventDefault:()=>prevented++,stopPropagation:()=>stopped++});
  assert.equal(app.closeCount,1,'footer advertises Esc · cerrar; real handler must close');
  assert.equal(prevented,1);assert.equal(stopped,1);
});

test('old rejected native reopen cannot turn a newer, playing URL into an error',async()=>{
  const opener=delayed();
  let count=0;
  const app=mountPlayer({onReopen:()=>{count++;return opener.promise;}});
  app.render();const a=syntheticVideo('A');app.activate(a);
  app.mediaNode().props.onError({currentTarget:a});
  assert.equal(app.get('state'),'error');
  app.retryButton().props.onClick();
  await settle();
  assert.equal(count,1);
  assert.equal(app.get('retrying'),true);
  const b=syntheticVideo('B');
  app.reroute('https://synthetic.invalid/token-B',b);
  app.mediaNode().props.onPlaying({currentTarget:b});
  assert.equal(app.get('state'),'ready');
  opener.resolve(false);
  await settle();
  assert.equal(app.get('state'),'ready',
    'settled old retry must not overwrite decoded playback of new Range token');
  assert.equal(app.get('retryBusy'),false);
});

test('unmounted previous media retry must not paint errors on reused fresh player session',async()=>{
  const opener=delayed();
  const app=mountPlayer({onReopen:()=>opener.promise});
  app.render();const a=syntheticVideo('A');app.activate(a);
  app.mediaNode().props.onError({currentTarget:a});
  app.retryButton().props.onClick();
  await settle();
  const b=syntheticVideo('B');
  app.reroute('https://synthetic.invalid/token-C',b);
  app.mediaNode().props.onPlaying({currentTarget:b});
  opener.reject(new Error('stale revoked stream'));
  await settle();
  assert.equal(app.get('state'),'ready','late exception from old retry must be fenced');
});

test('same-token failed reopen still reports error and permits a deliberate retry',async()=>{
  let attempts=0;
  const app=mountPlayer({onReopen:async()=>{attempts++;return false;}});
  app.render();const video=syntheticVideo('A');app.activate(video);
  app.mediaNode().props.onError({currentTarget:video});
  app.retryButton().props.onClick();
  await settle();
  assert.equal(app.get('state'),'error','a current failed reopen must not be hidden');
  assert.equal(app.get('retryBusy'),false);
  app.retryButton().props.onClick();
  await settle();
  assert.equal(attempts,2,'current failed reopen can be explicitly retried');
});

test('old stuck reopen cannot retain retry lock on newer URL, or unlock its new retry',async()=>{
  const old=delayed();
  const current=delayed();
  let calls=0;
  const app=mountPlayer({onReopen:()=>++calls===1?old.promise:current.promise});
  app.render();const a=syntheticVideo('A');app.activate(a);
  app.mediaNode().props.onError({currentTarget:a});
  app.retryButton().props.onClick();
  await settle();
  const b=syntheticVideo('B');app.reroute('https://synthetic.invalid/token-B',b);
  app.mediaNode().props.onError({currentTarget:b});
  app.retryButton().props.onClick();
  await settle();
  assert.equal(calls,2,'B can retry while the old A token awaits a response');
  assert.equal(app.get('retryBusy'),true);
  old.resolve(false);
  await settle();
  assert.equal(app.get('retryBusy'),true,'obsolete A must not unlock B retry');
  current.resolve(false);
  await settle();
  assert.equal(app.get('retryBusy'),false);
  assert.equal(app.get('state'),'error','failed B retry should retain its own error');
});

test('successful fresh token still resumes the previous position only on new video metadata',async()=>{
  const native=delayed();
  const app=mountPlayer({onReopen:()=>native.promise});
  app.render();const a=syntheticVideo('A');app.activate(a);
  a.currentTime=47;
  app.mediaNode().props.onError({currentTarget:a});
  app.retryButton().props.onClick();
  await settle();
  const b=syntheticVideo('B');b.currentTime=0;
  app.reroute('https://synthetic.invalid/fresh-token-B',b);
  app.mediaNode().props.onLoadedMetadata({currentTarget:b});
  assert.equal(b.currentTime,47,'decoded metadata of new token applies bounded resume');
  native.resolve(true);
  await settle();
  assert.equal(app.get('retryBusy'),false);
  assert.equal(app.get('state'),'loading','token refresh does not claim decoded frame before playing');
  app.mediaNode().props.onPlaying({currentTarget:b});
  assert.equal(app.get('state'),'ready');
});

test('2,048 pool proximity entries: synthetic Node priority ordering, NOT browser frames',()=>{
  const proximity=new Map(Array.from({length:2048},(_,i)=>['game-'+i,i%17===0?2:1]));
  const started=performance.now();let selected=0;
  for(let i=0;i<300;i++){
    const top=mediaPool.topVisibleIds(proximity,32);
    assert.equal(top.length,32);
    assert.ok(top.every(id=>proximity.get(id)===2));
    selected+=top.length;
  }
  const duration=performance.now()-started;
  assert.equal(selected,9600);
  assert.ok(duration<3000,`pure JS priority pass unexpected ${duration.toFixed(1)}ms`);
  console.log(`SYNTHETIC Node: 2,048 entries × 300 top-32 passes in ${duration.toFixed(1)} ms; NO WebView2/GPU/frame measurement`);
});
