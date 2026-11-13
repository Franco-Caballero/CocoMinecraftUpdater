// Adversarial, deterministic HTMLMediaElement/IntersectionObserver simulation.
// No real requests, media decoder, browser, WebView2, GPU, or timers are used.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=await readFile(resolve(root,'src/hover-video-pool.ts'),'utf8');
const js=ts.transpileModule(source,{
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS},
}).outputText;

function fixture(){
  const videos=[];
  const timers=new Map();
  const listeners=new Map();
  const observers=[];
  let clock=1_700_000_000_000;
  let nextTimer=0;
  let peakPlayers=0;
  const classes=()=>{const own=new Set();return {
    add:(...values)=>values.forEach(v=>own.add(v)),
    remove:(...values)=>values.forEach(v=>own.delete(v)),
    contains:(value)=>own.has(value),
  };};
  const dom=()=>{
    const element={
      children:[],style:{},classList:classes(),parent:null,removed:false,
      setAttribute(){},closest(){return this;},
      appendChild(child){
        if(child.parent?.children){
          const i=child.parent.children.indexOf(child);
          if(i>=0)child.parent.children.splice(i,1);
        }
        child.parent=this;
        this.children.push(child);
        return child;
      },
      remove(){
        this.removed=true;
        if(this.parent?.children){
          const i=this.parent.children.indexOf(this);
          if(i>=0)this.parent.children.splice(i,1);
        }
        this.parent=null;
      },
    };
    return element;
  };
  class FakeVideo {
    constructor(){
      this.listeners=new Map();
      this.classList=classes();this.style={};
      this.src='';this.preload='none';this.readyState=3;
      this.paused=true;this.currentTime=0;
      this.loads=0;this.plays=0;this.frameCount=0;
      this.frames=new Map();this.lastCompletedLoad=0;
      this.buffered={length:0,end:()=>0};this.duration=6;
      this.parent=null;this.removed=false;
      videos.push(this);
      peakPlayers=Math.max(peakPlayers,videos.filter(v=>!v.removed).length);
    }
    setAttribute(){}
    removeAttribute(name){if(name==='src')this.src='';}
    addEventListener(name,fn){this.listeners.set(name,fn);}
    emit(name){this.listeners.get(name)?.();}
    load(){this.loads++;}
    pause(){this.paused=true;}
    play(){this.paused=false;this.plays++;this.emit('playing');return Promise.resolve();}
    remove(){dom().remove.call(this);}
    requestVideoFrameCallback(fn){
      const id=++this.frameCount;this.frames.set(id,fn);return id;
    }
    cancelVideoFrameCallback(id){this.frames.delete(id);}
    flushFrame(){
      const next=this.frames.entries().next();
      if(next.done)return false;
      const [id,fn]=next.value;this.frames.delete(id);fn();return true;
    }
  }
  const document={
    hidden:false,body:dom(),createElement:name=>name==='video'?new FakeVideo():dom(),
    addEventListener(name,fn){listeners.set(name,fn);},
    removeEventListener(name){listeners.delete(name);},
  };
  const connection={
    saveData:false,effectiveType:'4g',downlink:10,rtt:20,
    addEventListener(name,fn){listeners.set('net:'+name,fn);},
    removeEventListener(name){listeners.delete('net:'+name);},
  };
  const window={
    setTimeout(fn,ms){const id=++nextTimer;timers.set(id,{fn,ms,due:clock+ms});return id;},
    clearTimeout(id){timers.delete(id);},
  };
  class IO {
    constructor(callback,config){this.callback=callback;this.config=config;observers.push(this);}
    observe(){}
    unobserve(){}
    disconnect(){}
    deliverBatch(items){
      this.callback(items.map(([target,ratio])=>({
        target,intersectionRatio:ratio,isIntersecting:ratio>0,
      })));
    }
  }
  class TestDate extends Date{static now(){return clock;}}
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,document,navigator:{connection},
    window,IntersectionObserver:IO,Date:TestDate,
    HTMLMediaElement:{HAVE_CURRENT_DATA:2},performance:{now:()=>clock}});
  function runNext(){
    const next=[...timers.entries()].sort((a,b)=>a[1].due-b[1].due)[0];
    if(!next)return false;
    timers.delete(next[0]);clock=next[1].due;next[1].fn();return true;
  }
  function completeRequests(){
    for(const video of [...videos]){
      if(!video.src||video.lastCompletedLoad===video.loads)continue;
      video.lastCompletedLoad=video.loads;
      video.emit('loadedmetadata');
      if(video.preload==='auto')video.emit('loadeddata');
    }
  }
  return {Pool:module.exports.HoverVideoPool,videos,timers,document,connection,dom,
    getObserver:()=>observers[0],runNext,completeRequests,
    clock:()=>clock,setClock:value=>{clock=value;},
    fire:(ms)=>{
      const timer=[...timers].find(([,item])=>item.ms===ms);
      assert.ok(timer,`expected a ${ms}ms timer`);
      timers.delete(timer[0]);clock=timer[1].due;timer[1].fn();
    },
    emitNetwork:()=>listeners.get('net:change')?.(),
    emitVisibility:()=>listeners.get('visibilitychange')?.(),
    getPeakPlayers:()=>peakPlayers,
  };
}

const catalog=(count,bytes=350_000)=>Object.fromEntries(
  Array.from({length:count},(_,i)=>[
    `g-${i}`,{url:`https://example.invalid/previews/${i}.webm`,bytes},
  ]));

test('1,280-card viewport burst keeps peak players <=32, two fetch slots and eventual metadata coverage',t=>{
  const h=fixture(),sources=catalog(1280);
  const pool=new h.Pool(sources);
  const disposers=[],slots=[];
  for(let i=0;i<1280;i++){
    const slot=h.dom();slots.push(slot);
    disposers.push(pool.registerSlot(`g-${i}`,slot));
  }
  assert.equal(h.videos.length,0,'mounting thousands of cards must be placeholder-only');
  pool.start();
  h.getObserver().deliverBatch(slots.map((slot,i)=>[slot,i%3===0?.85:.55]));
  assert.ok(h.videos.length<=32,'one observer batch cannot instantiate 1280 decoders');
  assert.ok(h.getPeakPlayers()<=32);
  const start=process.hrtime.bigint();
  let maxLoading=0,maxResident=0,maxHot=0,steps=0;
  for(;steps<1280*8;steps++){
    if(!h.runNext())break;
    const working=pool.getStatus();
    maxLoading=Math.max(maxLoading,working.loading);
    maxResident=Math.max(maxResident,working.residentPlayers);
    maxHot=Math.max(maxHot,working.warm);
    h.completeRequests();
    const s=pool.getStatus();
    maxLoading=Math.max(maxLoading,s.loading);
    maxResident=Math.max(maxResident,s.residentPlayers);
    maxHot=Math.max(maxHot,s.warm);
    assert.ok(s.warmBytes<=12*1024*1024);
    if(s.metadataCovered===1280)break;
  }
  const status=pool.getStatus();
  const elapsed=Number(process.hrtime.bigint()-start)/1e6;
  assert.equal(status.metadataCovered,1280,
    'all curated metadata eventually covered; '+JSON.stringify({
      steps,status,scanCursor:pool.scanCursor,workTimer:pool.workTimer,
      upcoming:[...h.timers.values()].slice(0,5).map(x=>x.ms),
      active:[...pool.clips].filter(([,c])=>c.loading).map(([id,c])=>[id,c.tier,c.video.loads,c.video.src]),
    }));
  assert.equal(status.requested,1280);
  assert.ok(maxLoading<=2,`background inflight peak ${maxLoading}`);
  assert.ok(maxResident<=32,`resident peak ${maxResident}`);
  assert.ok(maxHot<=6,`warm incl loading peak ${maxHot}`);
  assert.ok(h.getPeakPlayers()<=32,`even temporary resident peak must be <=32, got ${h.getPeakPlayers()}`);
  t.diagnostic(`VM synthetic 1280 metadata: ${elapsed.toFixed(1)}ms CPU, ${steps} scheduled ticks; peak resident ${h.getPeakPlayers()}, hot ${maxHot}, inflight ${maxLoading}. NOT WebView2/network timing.`);
  disposers.forEach(off=>off());pool.stop();
  assert.equal(h.videos.filter(v=>!v.removed).length,0,'stop fully releases all fake nodes');
  assert.equal(h.timers.size,0,'stop removes all pending watchdog/scheduler timers');
});

test('1,000 rapid pointer/focus hovers retain at most one active decoder and hot 6/resident 32',t=>{
  const h=fixture(),sources=catalog(96,2_000_000),pool=new h.Pool(sources);
  const slots=Array.from({length:96},()=>h.dom());
  const disposers=slots.map((slot,i)=>pool.registerSlot(`g-${i}`,slot));
  pool.start();
  const start=process.hrtime.bigint();
  for(let i=0;i<1000;i++){
    const id=`g-${i%96}`,slot=slots[i%96];
    pool.play(id,slot);
    if(i%7===0)pool.pause(id,slot);
    if(i%23===0)pool.play(id,slot); // duplicate focus/pointerenter
    const s=pool.getStatus();
    assert.ok(s.residentPlayers<=32,`hover ${i} resident=${s.residentPlayers}`);
    assert.ok(s.warm<=6,`hover ${i} active hot=${s.warm}`);
    assert.ok(s.warmBytes<=12*1024*1024,`hover ${i} hot budget exceeded`);
    assert.ok(h.videos.filter(v=>!v.paused&&!v.removed).length<=1);
    assert.ok(h.timers.size<=2,'one foreground watchdog and one background scheduler maximum');
  }
  const elapsed=Number(process.hrtime.bigint()-start)/1e6;
  t.diagnostic(`VM synthetic 1000 hover/focus transitions: ${elapsed.toFixed(1)}ms CPU; NOT physical WebView2/GPU performance.`);
  disposers.forEach(off=>off());pool.stop();
  assert.equal(h.timers.size,0);
});

test('foreground lost first-frame callback stops spinner and network after deadline; retries require cooldown',()=>{
  const h=fixture(),pool=new h.Pool(catalog(1));
  const card=h.dom();const dispose=pool.registerSlot('g-0',card);
  pool.start();pool.play('g-0',card);
  const video=h.videos.at(-1);
  assert.equal(card.classList.contains('card-video-loading'),true);
  assert.equal(video.frames.size,1,'video remains hidden until decoded-frame callback');
  h.fire(15_000); // a lost HTML5 frame/error event, not wall-clock sleep
  assert.equal(video.paused,true);
  assert.equal(video.src,'','stalled foreground HTTP fetch must be cancelled');
  assert.equal(video.frames.size,0,'stale GPU frame callback was invalidated');
  assert.equal(card.classList.contains('card-video-unavailable'),true);
  assert.equal(card.classList.contains('card-video-playing'),false);
  const attempts=video.plays;
  pool.play('g-0',card);
  assert.equal(video.plays,attempts,'1000 repeated hovers cannot hammer a failed preview');
  h.setClock(h.clock()+60_001);
  pool.play('g-0',card);
  assert.equal(video.plays,attempts+1,'new explicit hover may retry after cooldown');
  assert.equal(card.classList.contains('card-video-playing'),false);
  video.flushFrame();
  assert.equal(card.classList.contains('card-video-playing'),true,'only decoded frame reveals video');
  assert.equal([...h.timers.values()].some(entry=>entry.ms===15_000),false);
  dispose();pool.stop();assert.equal(h.timers.size,0);
});

test('multi-card pointer races and late detached events cannot steal the active shared decoder',()=>{
  const h=fixture(),pool=new h.Pool(catalog(1));
  const left=h.dom(),right=h.dom(),stale=h.dom();
  const a=pool.registerSlot('g-0',left),b=pool.registerSlot('g-0',right);
  pool.start();h.getObserver().deliverBatch([[left,.8],[right,.6]]);
  pool.play('g-0',left);
  pool.play('g-0',right);
  const video=h.videos[0],prior=video.plays;
  pool.pause('g-0',left);
  assert.equal(video.paused,false,'old pointer leave cannot pause newly focused slot');
  assert.equal(video.parent,right);
  pool.play('g-0',stale);
  assert.equal(video.plays,prior);
  assert.equal(video.parent,right,'unregistered stale pointer event never redirects media');
  a();pool.pause('g-0',right);b();pool.stop();
});

test('cancelled load error events are ignored; metadata->warm promotion does not duplicate src/load',()=>{
  const h=fixture(),pool=new h.Pool(catalog(8));
  pool.start();h.runNext();
  const first=h.videos[0],id='g-0';
  assert.ok(first.src);
  pool.cancelBackground(pool.clips.get(id));
  first.emit('error');
  assert.equal(pool.clips.get(id).failed,false,'abort from hidden/save-data is not a CDN failure');
  // Distant metadata succeeds and can be upgraded on hover without another
  // resource selection / HTTP request for the opening segment.
  pool.schedule(0,true);h.runNext();
  const metadata=h.videos.find(v=>v.src&&v.preload==='metadata');
  assert.ok(metadata);
  const found=Object.keys(catalog(8)).find(key=>pool.clips.get(key)?.video===metadata);
  metadata.emit('loadedmetadata');
  const loads=metadata.loads,originalSrc=metadata.src;
  const slot=h.dom();pool.attach(found,slot);pool.play(found);
  assert.equal(metadata.src,originalSrc);
  assert.equal(metadata.loads,loads,'tier upgrade retains HTML5 source without network restart');
  pool.pause(found);pool.stop();assert.equal(h.timers.size,0);
});

test('busy, hidden and saveData stop speculative requests and resume without autoplay',()=>{
  const h=fixture(),pool=new h.Pool(catalog(30));
  pool.start();h.runNext();assert.equal(pool.getStatus().loading,2);
  pool.setBackgroundBusy(true);
  assert.equal(pool.getStatus().loading,0);
  assert.ok(h.videos.every(v=>!v.src));
  pool.setBackgroundBusy(false);h.runNext();
  assert.equal(pool.getStatus().loading,2);
  h.document.hidden=true;h.emitVisibility();
  assert.equal(pool.getStatus().loading,0);
  h.document.hidden=false;h.emitVisibility();h.runNext();
  assert.equal(pool.getStatus().loading,2);
  h.connection.saveData=true;h.emitNetwork();
  assert.equal(pool.getStatus().loading,0);
  h.connection.saveData=false;h.emitNetwork();h.runNext();
  assert.equal(pool.getStatus().loading,2);
  assert.ok(h.videos.every(v=>v.plays===0));
  pool.stop();
});
