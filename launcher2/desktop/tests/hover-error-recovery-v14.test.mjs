import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const js=ts.transpileModule(await readFile(resolve(root,'src/hover-video-pool.ts'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
}).outputText;

function harness(){
  const videos=[];let now=50_000;const timers=new Map();let next=0;
  const element=()=>{
    const classes=new Set();
    return {classList:{add(...xs){xs.forEach(x=>classes.add(x));},remove(...xs){xs.forEach(x=>classes.delete(x));},contains:x=>classes.has(x)},
      parent:null,children:[],style:{},closest(){return this;},setAttribute(){},
      appendChild(child){if(child.parent){child.parent.children=child.parent.children.filter(x=>x!==child);}this.children.push(child);child.parent=this;},
      remove(){if(this.parent)this.parent.children=this.parent.children.filter(x=>x!==this);this.parent=null;}};
  };
  class Video{
    constructor(){this.src='';this.paused=true;this.readyState=3;this.currentTime=0;this.frameNumber=0;this.frames=new Map();this.events=new Map();this.loads=0;videos.push(this);}
    addEventListener(name,listener){this.events.set(name,listener);}
    emit(name){this.events.get(name)?.();}
    setAttribute(){} removeAttribute(name){if(name==='src')this.src='';}
    load(){this.loads++;}pause(){this.paused=true;}
    play(){this.paused=false;this.emit('playing');return Promise.resolve();}
    requestVideoFrameCallback(callback){const id=++this.frameNumber;this.frames.set(id,callback);return id;}
    cancelVideoFrameCallback(id){this.frames.delete(id);}
    frame(){const item=[...this.frames.entries()][0];if(!item)return false;this.frames.delete(item[0]);item[1]();return true;}
    remove(){element().remove.call(this);}
  }
  class IO{observe(){} unobserve(){} disconnect(){}}
  class DateMock extends Date{static now(){return now;}}
  const doc={hidden:false,body:element(),createElement:t=>t==='video'?new Video():element(),addEventListener(){},removeEventListener(){}};
  const win={setTimeout(fn,delay){const id=++next;timers.set(id,{fn,delay});return id;},clearTimeout:id=>timers.delete(id)};
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,document:doc,window:win,Date:DateMock,
    navigator:{connection:{saveData:false,effectiveType:'4g'}},performance:{now:()=>now},
    IntersectionObserver:IO,HTMLMediaElement:{HAVE_CURRENT_DATA:2}});
  const slot=element(),pool=new module.exports.HoverVideoPool({coco:{url:'https://synthetic.invalid/coco.mp4',bytes:100000}});
  pool.registerSlot('coco',slot);pool.start();pool.play('coco',slot);
  return {pool,slot,video:videos[0],timers,setNow:t=>{now=t;}};
}

test('native media decode error after a visible frame releases foreground decoder and does not leave an active phantom player',()=>{
  const h=harness();
  assert.equal(h.video.frame(),true);
  assert.equal(h.slot.classList.contains('card-video-playing'),true);
  h.video.emit('error');
  assert.equal(h.slot.classList.contains('card-video-playing'),false);
  assert.equal(h.slot.classList.contains('card-video-unavailable'),true);
  assert.equal(h.video.src,'');
  assert.equal(h.pool.activeId,null,'error cannot keep a phantom active decoder');
  assert.equal(h.video.frames.size,0,'error must cancel stale frame callbacks');
  assert.equal([...h.timers.values()].filter(x=>x.delay===15_000).length,0,'error must release watchdog');
  h.pool.stop();
});

test('late queued video events after error cannot re-expose a corrupt decoder',()=>{
  const h=harness();
  h.video.emit('error');
  h.video.emit('playing');
  h.video.emit('seeked');
  assert.equal(h.slot.classList.contains('card-video-playing'),false);
  assert.equal(h.video.frames.size,0);
  h.pool.stop();
});
