// Browser-free adversarial test using the ACTUAL TypeScript pool and a tiny
// deterministic HTML5 media mock. No real network, browser decoder or GPU.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const original=await readFile(resolve(root,'src/hover-video-pool.ts'),'utf8');
const js=ts.transpileModule(original,{compilerOptions:{
  module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,
}}).outputText;

function harness(){
  const videos=[],timers=new Map();let next=0,now=12345678;
  function box(){
    const classes=new Set();
    return {
      classList:{add(...names){names.forEach(n=>classes.add(n));},remove(...names){names.forEach(n=>classes.delete(n));},contains(name){return classes.has(name);}},
      style:{},children:[],parent:null,
      closest(){return this;},
      appendChild(child){if(child.parent){child.parent.children=child.parent.children.filter(v=>v!==child);}child.parent=this;this.children.push(child);return child;},
      remove(){if(this.parent)this.parent.children=this.parent.children.filter(v=>v!==this);this.parent=null;},
      setAttribute(){},
    };
  }
  class Video{
    constructor(){this.src='';this.paused=true;this.readyState=3;this.currentTime=0;this.listeners=new Map();this.frames=new Map();this.frameSerial=0;this.buffered={length:0};videos.push(this);}
    addEventListener(type,fn){this.listeners.set(type,fn);}
    emit(type){this.listeners.get(type)?.();}
    setAttribute(){}
    removeAttribute(name){if(name==='src')this.src='';}
    load(){}
    pause(){this.paused=true;}
    play(){this.paused=false;this.emit('playing');return Promise.resolve();}
    requestVideoFrameCallback(callback){const id=++this.frameSerial;this.frames.set(id,callback);return id;}
    cancelVideoFrameCallback(id){this.frames.delete(id);}
    frame(){const first=this.frames.entries().next().value;if(!first)return false;this.frames.delete(first[0]);first[1]();return true;}
    remove(){box().remove.call(this);}
  }
  const doc={hidden:false,body:box(),createElement:tag=>tag==='video'?new Video():box(),addEventListener(){},removeEventListener(){}};
  const win={setTimeout(fn,ms){const id=++next;timers.set(id,{fn,ms});return id;},clearTimeout(id){timers.delete(id);}};
  class IO{observe(){}unobserve(){}disconnect(){}}
  class DateMock extends Date{static now(){return now;}}
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,document:doc,window:win,
    navigator:{connection:{saveData:false,effectiveType:'4g'}},
    Date:DateMock,performance:{now:()=>now},IntersectionObserver:IO,
    HTMLMediaElement:{HAVE_CURRENT_DATA:2}});
  const slot=box(),pool=new module.exports.HoverVideoPool({clip:{url:'https://synthetic.invalid/clip.webm',bytes:320000}});
  pool.registerSlot('clip',slot);pool.start();
  pool.play('clip',slot);
  return {pool,slot,video:videos[0],timers,advance:ms=>{now+=ms;},deadline:()=>{
    const matched=[...timers].filter(([,timer])=>timer.ms===15_000);
    assert.equal(matched.length,1,'foreground watchdog must be single and bounded');
    timers.delete(matched[0][0]);matched[0][1].fn();
  }};
}

test('seeked does not reveal poster until a NEW actually decoded video frame arrives',()=>{
  const f=harness();
  assert.equal(f.slot.classList.contains('card-video-playing'),false);
  assert.equal(f.slot.classList.contains('card-video-loading'),true);
  const firstId=[...f.video.frames.keys()][0];
  f.video.emit('seeked');
  assert.equal(f.slot.classList.contains('card-video-playing'),false,
    'old seeked handler incorrectly bypassed requestVideoFrameCallback');
  assert.equal(f.video.frames.has(firstId),false,'prior pending callback was cancelled');
  assert.equal(f.video.frames.size,1);
  assert.equal(f.video.frame(),true);
  assert.equal(f.slot.classList.contains('card-video-playing'),true);
  assert.equal(f.slot.classList.contains('card-video-loading'),false);
  f.pool.stop();
});

test('endless waiting AFTER a decoded frame fails safely instead of infinite spinner/network activity',()=>{
  const f=harness();
  assert.ok(f.video.frame());
  assert.equal(f.slot.classList.contains('card-video-playing'),true);
  f.video.emit('waiting');
  assert.equal(f.slot.classList.contains('card-video-loading'),true);
  assert.equal(f.slot.classList.contains('card-video-playing'),false);
  const initial=[...f.timers.entries()].filter(([,timer])=>timer.ms===15_000)[0]?.[0];
  assert.ok(initial);
  f.advance(12_000);
  f.video.emit('waiting');f.video.emit('stalled');
  assert.ok(f.timers.has(initial),'repeated network stalls cannot extend deadline');
  f.advance(3_000);
  f.deadline();
  assert.equal(f.slot.classList.contains('card-video-loading'),false);
  assert.equal(f.slot.classList.contains('card-video-unavailable'),true);
  assert.equal(f.video.src,'','abort unresolved range and free decoder');
  assert.equal(f.pool.getStatus().firstFrameSamples,1,
    'buffering duration is not misreported as initial hover-to-frame latency');
  f.pool.stop();
});

test('late seeking events after pointer exit cannot resurrect a stale preview',()=>{
  const f=harness();
  f.pool.pause('clip',f.slot);
  f.video.emit('seeked');f.video.emit('playing');
  assert.equal(f.slot.classList.contains('card-video-playing'),false);
  assert.equal(f.video.frames.size,0);
  f.pool.stop();
});
