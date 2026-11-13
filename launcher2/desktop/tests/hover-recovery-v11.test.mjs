// Coco2 v0.6.1 preview recovery tests. All media, IO, clocks and timers here
// are in-memory fakes: NO HTTP, WebView2, decoder, physical GPU or real video.
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
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
}).outputText;

const catalog=(count,bytes=400_000)=>Object.fromEntries(Array.from({length:count},(_,i)=>[
  `g-${i}`,{url:`https://synthetic.invalid/g-${i}.webm`,bytes},
]));

function fixture(){
  const videos=[],timers=new Map(),listeners=new Map(),observers=[];
  let time=1_700_000_000_000,seq=0,createdPeak=0;
  const container=()=>{
    const set=new Set();
    return {
      children:[],parent:null,removed:false,style:{},
      classList:{
        add(...keys){keys.forEach(k=>set.add(k));},
        remove(...keys){keys.forEach(k=>set.delete(k));},
        contains(key){return set.has(key);},
      },
      setAttribute(){},
      closest(){return this;},
      appendChild(child){
        if(child.parent?.children){
          const i=child.parent.children.indexOf(child);
          if(i>=0)child.parent.children.splice(i,1);
        }
        child.parent=this;this.children.push(child);return child;
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
  };
  class FakeVideo{
    constructor(){
      this.src='';this.preload='none';this.readyState=3;
      this.paused=true;this.currentTime=0;
      this.listeners=new Map();this.frameId=0;this.frames=new Map();
      this.buffered={length:0,end:()=>0};this.duration=5;
      this.loads=0;this.plays=0;this.pauses=0;
      this.parent=null;this.removed=false;this.rejectNext=false;this.deferNext=false;
      videos.push(this);
      createdPeak=Math.max(createdPeak,videos.filter(v=>!v.removed).length);
    }
    setAttribute(){}
    addEventListener(name,callback){this.listeners.set(name,callback);}
    removeAttribute(name){if(name==='src')this.src='';}
    emit(name){this.listeners.get(name)?.();}
    load(){this.loads++;}
    pause(){this.pauses++;this.paused=true;}
    play(){
      this.plays++;
      if(this.rejectNext){
        this.rejectNext=false;this.paused=true;
        return Promise.reject(new Error('synthetic-play-blocked'));
      }
      if(this.deferNext){
        this.deferNext=false;
        return new Promise((_,reject)=>{this.rejectDeferred=reject;});
      }
      this.paused=false;
      this.emit('playing');
      return Promise.resolve();
    }
    requestVideoFrameCallback(fn){
      const id=++this.frameId;this.frames.set(id,fn);return id;
    }
    cancelVideoFrameCallback(id){this.frames.delete(id);}
    flushFrame(){
      const [id,callback]=this.frames.entries().next().value||[];
      if(!callback)return false;
      this.frames.delete(id);callback();return true;
    }
    remove(){container().remove.call(this);}
  }
  const document={
    body:container(),hidden:false,
    createElement:tag=>tag==='video'?new FakeVideo():container(),
    addEventListener(name,fn){listeners.set(name,fn);},
    removeEventListener(name){listeners.delete(name);},
  };
  const connection={
    saveData:false,effectiveType:'4g',downlink:10,rtt:30,
    addEventListener(name,fn){listeners.set('net:'+name,fn);},
    removeEventListener(name){listeners.delete('net:'+name);},
  };
  const window={
    setTimeout(fn,ms){const id=++seq;timers.set(id,{fn,ms,due:time+ms});return id;},
    clearTimeout(id){timers.delete(id);},
  };
  class IO{
    constructor(callback,options){this.callback=callback;this.options=options;observers.push(this);}
    observe(){}
    unobserve(){}
    disconnect(){}
    deliverBatch(items){
      this.callback(items.map(([target,ratio])=>({
        target,isIntersecting:ratio>0,intersectionRatio:ratio,
      })));
    }
  }
  class VirtualDate extends Date{static now(){return time;}}
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,document,window,
    navigator:{connection},Date:VirtualDate,performance:{now:()=>time},
    HTMLMediaElement:{HAVE_CURRENT_DATA:2},IntersectionObserver:IO});
  const advance=()=>{
    const task=[...timers.entries()].sort((a,b)=>a[1].due-b[1].due)[0];
    if(!task)return false;
    timers.delete(task[0]);time=Math.max(time,task[1].due);task[1].fn();
    return true;
  };
  return {
    Pool:module.exports.HoverVideoPool,container,videos,timers,document,connection,advance,
    observer:()=>observers[0],
    peak:()=>createdPeak,
    time:()=>time,
    fastForward:ms=>{time+=ms;},
    visibility:()=>listeners.get('visibilitychange')?.(),
    network:()=>listeners.get('net:change')?.(),
    drainMetadata:()=>{
      for(const v of videos){
        if(v.src&&v.completedUrl!==v.src){
          v.completedUrl=v.src;v.emit('loadedmetadata');
          if(v.preload==='auto')v.emit('loadeddata');
        }
      }
    },
  };
}

test('1152 mounted cards: repeated alternating IntersectionObserver ratios cannot resurrect evicted videos',t=>{
  const f=fixture(),pool=new f.Pool(catalog(1152));
  const slots=Array.from({length:1152},()=>f.container());
  const dispose=slots.map((slot,i)=>pool.registerSlot(`g-${i}`,slot));
  assert.equal(f.videos.length,0);
  pool.start();
  const first=slots.map((slot,i)=>[slot,i<32?.9:i<64?.4:0]);
  f.observer().deliverBatch(first);
  assert.equal(pool.getStatus().residentPlayers,32);
  assert.equal(pool.getStatus().metadataCovered,0,
    'viewport-only players have not yet fetched metadata');
  const second=slots.slice(0,64).map((slot,i)=>[slot,i<32?.05:.95]);
  f.observer().deliverBatch(second);
  const evicted=[...Array(32).keys()].filter(i=>!pool.clips.has(`g-${i}`));
  assert.equal(evicted.length,32,'lower-priority not-yet-fetched videos must be evictable');
  assert.equal(pool.getStatus().residentPlayers,32);
  assert.ok(evicted.every(i=>pool.warmEvicted.has(`g-${i}`)));
  const constructed=f.videos.length;
  const start=process.hrtime.bigint();
  for(let round=0;round<128;round++){
    f.observer().deliverBatch(slots.slice(0,64).map((slot,i)=>[
      slot,i<32?(round%2?.99:.88):.05,
    ]));
    const status=pool.getStatus();
    assert.ok(status.residentPlayers<=32);
    assert.ok(status.warm<=6);
    assert.ok(status.loading<=2);
  }
  const cpuMs=Number(process.hrtime.bigint()-start)/1e6;
  assert.equal(f.videos.length,constructed,
    'ratio-only callbacks for continuously visible evicted cards cannot recreate decoders');
  assert.ok(f.peak()<=32,'even transient video allocations remain <=32');
  // The fence is not permanent: actual leave/reentry can rebuild one player.
  f.observer().deliverBatch([[slots[0],0]]);
  f.observer().deliverBatch([[slots[0],.99]]);
  assert.equal(pool.warmEvicted.has('g-0'),false);
  assert.ok(pool.clips.has('g-0'));
  assert.equal(f.videos.length,constructed+1);
  // A fence on never-fetched players must not starve the catalog: background
  // scanner still requests their small metadata tier once bandwidth is idle.
  let steps=0,maxLoading=0;
  for(;steps<1152*6;steps++){
    if(!f.advance())break;
    f.drainMetadata();
    maxLoading=Math.max(maxLoading,pool.getStatus().loading);
    if(pool.getStatus().metadataCovered===1152)break;
  }
  assert.equal(pool.getStatus().metadataCovered,1152,
    `uncached evictions must eventually get metadata; covered ${pool.getStatus().metadataCovered} after ${steps} ticks`);
  assert.ok(maxLoading<=2);
  assert.ok(pool.getStatus().residentPlayers<=32);
  t.diagnostic(`Synthetic 1152 cards, 128 repeated 64-entry IO callbacks: ${cpuMs.toFixed(1)} ms Node CPU; ${constructed} initial video creations, no churn during callbacks; metadata complete after ${steps} virtual ticks (not physical GPU time)`);
  dispose.forEach(fn=>fn());pool.stop();
  assert.equal(f.timers.size,0);
  assert.equal(f.videos.filter(v=>!v.removed).length,0);
});

test('1000 high-frequency hovers across 96 cards preserve limits and first-frame gating',t=>{
  const f=fixture(),pool=new f.Pool(catalog(96,2_000_000));
  const slots=Array.from({length:96},()=>f.container());
  const off=slots.map((slot,i)=>pool.registerSlot(`g-${i}`,slot));
  pool.start();f.advance();
  const start=process.hrtime.bigint();
  let maxHot=0,maxResident=0,maxNetwork=0;
  for(let i=0;i<1000;i++){
    const id=`g-${i%96}`,slot=slots[i%96];
    pool.play(id,slot);
    if(i%9===0)pool.play(id,slot);
    if(i%7===0)pool.pause(id,slot);
    const stat=pool.getStatus();
    maxHot=Math.max(maxHot,stat.warm);
    maxResident=Math.max(maxResident,stat.residentPlayers);
    maxNetwork=Math.max(maxNetwork,stat.loading);
    assert.ok(stat.residentPlayers<=32);
    assert.ok(stat.warm<=6);
    assert.ok(stat.warmBytes<=12*1024*1024);
    assert.ok(stat.loading<=2);
    assert.ok(f.videos.filter(v=>!v.paused&&!v.removed).length<=1);
    assert.ok(f.timers.size<=4);
    assert.ok(!slot.classList.contains('card-video-playing'),
      'never display an unconfirmed decoded frame');
  }
  const cpuMs=Number(process.hrtime.bigint()-start)/1e6;
  t.diagnostic(`1000 VM pointer/focus actions: ${cpuMs.toFixed(1)} ms Node CPU; peak resident ${maxResident}, hot ${maxHot}, background ${maxNetwork} (not WebView2 timing)`);
  off.forEach(fn=>fn());pool.stop();assert.equal(f.timers.size,0);
});

test('rejected HTML5 play promise aborts immediately, cancels watchdog, then recovers after short cooldown',async()=>{
  const f=fixture(),pool=new f.Pool(catalog(1));
  const slot=f.container(),off=pool.registerSlot('g-0',slot);
  pool.start();pool.attach('g-0',slot);
  const video=f.videos[0];
  video.rejectNext=true;
  pool.play('g-0',slot);
  assert.equal(slot.classList.contains('card-video-loading'),true);
  assert.ok([...f.timers.values()].some(timer=>timer.ms===15_000));
  await Promise.resolve();await Promise.resolve(); // synthetic microtask, no clock advance
  assert.equal(video.src,'','known play rejection must stop network without 15s wait');
  assert.equal(video.frames.size,0);
  assert.equal(slot.classList.contains('card-video-loading'),false);
  assert.equal(slot.classList.contains('card-video-unavailable'),true);
  assert.equal([...f.timers.values()].some(timer=>timer.ms===15_000),false);
  const plays=video.plays;
  for(let i=0;i<40;i++)pool.play('g-0',slot);
  assert.equal(video.plays,plays,'repeated pointer/focus cannot hammer failed decoder');
  f.fastForward(5_001);
  pool.play('g-0',slot);
  assert.equal(video.plays,plays+1);
  assert.equal(slot.classList.contains('card-video-playing'),false);
  video.flushFrame();
  assert.equal(slot.classList.contains('card-video-playing'),true);
  assert.equal([...f.timers.values()].some(timer=>timer.ms===15_000),false);
  off();pool.stop();assert.equal(f.timers.size,0);
});

test('stale rejected playback from old card cannot cancel newer active video',async()=>{
  const f=fixture(),pool=new f.Pool(catalog(2));
  const a=f.container(),b=f.container();
  const offA=pool.registerSlot('g-0',a),offB=pool.registerSlot('g-1',b);
  pool.start();pool.play('g-0',a);
  const old=f.videos[0];
  // Reproduce a deferred WebView2 promise from a previous hover epoch.
  pool.pause('g-0',a);
  old.deferNext=true;
  pool.play('g-0',a);
  pool.play('g-1',b);
  const current=pool.clips.get('g-1').video;
  old.rejectDeferred(new Error('old playback rejected after navigation'));
  await Promise.resolve();await Promise.resolve();
  assert.equal(pool.activeId,'g-1');
  assert.equal(current.paused,false);
  assert.equal(current.src,'https://synthetic.invalid/g-1.webm');
  current.flushFrame();
  assert.equal(b.classList.contains('card-video-playing'),true);
  offA();offB();pool.stop();
});

test('busy, hidden and motion recovery preempt stale 30-second scheduler timers',()=>{
  const f=fixture(),pool=new f.Pool(catalog(1040));
  pool.start();
  pool.schedule(30_000,true);
  assert.ok([...f.timers.values()].some(v=>v.ms===30_000));
  pool.setBackgroundBusy(true);
  pool.setBackgroundBusy(false);
  assert.ok([...f.timers.values()].some(v=>v.ms===400),
    'finish of native install/game must not wait for old 30s backoff');
  pool.schedule(30_000,true);
  f.document.hidden=true;f.visibility();
  f.document.hidden=false;f.visibility();
  assert.ok([...f.timers.values()].some(v=>v.ms===400),
    'return to foreground schedules prompt background recovery');
  pool.schedule(30_000,true);
  pool.setEnabled(false);
  pool.setEnabled(true);
  assert.ok([...f.timers.values()].some(v=>v.ms===0),
    'motion reenable should not inherit stale retry scheduler');
  f.connection.saveData=true;f.network();
  f.connection.saveData=false;f.network();
  assert.ok([...f.timers.values()].some(v=>v.ms===0),
    'saveData off resumes bounded scheduler without waiting for old retry');
  f.advance();
  assert.ok(pool.getStatus().loading<=2);
  assert.ok(pool.getStatus().residentPlayers<=32);
  pool.stop();assert.equal(f.timers.size,0);
});
