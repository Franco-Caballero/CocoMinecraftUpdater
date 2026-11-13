import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

async function fixture({intersection=false}={}){
  const source=await readFile(resolve(root,'src/hover-video-pool.ts'),'utf8');
  const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const videos=[];
  const timers=new Map();
  const listeners=new Map();
  let nextTimer=0;
  let now=1000;
  const container=()=>{
    const classes=new Set();
    return {style:{},children:[],
      classList:{add(...names){names.forEach(x=>classes.add(x));},
        remove(...names){names.forEach(x=>classes.delete(x));},contains:name=>classes.has(name)},
      setAttribute(){},closest(){return this;},
      remove(){this.removed=true;},
      appendChild(child){
        if(child.parent?.children){const prior=child.parent.children.indexOf(child);if(prior>=0)child.parent.children.splice(prior,1);}
        child.parent=this;this.children.push(child);return child;
      }};
  };
  class FakeVideo {
    constructor(){
      this.listeners=new Map();
      this.src='';
      this.currentTime=0;
      this.readyState=3;
      this.duration=4;
      this.buffered={length:0,end:()=>0};
      this.plays=0;this.pauses=0;this.loads=0;
      this.paused=true;
      this.frameId=0;this.pendingFrames=new Map();this.cancelledFrames=0;
      videos.push(this);
    }
    setAttribute(){}
    removeAttribute(name){if(name==='src')this.src='';}
    addEventListener(name,callback){this.listeners.set(name,callback);}
    emit(name){this.listeners.get(name)?.();}
    load(){this.loads++;}
    pause(){this.pauses++;this.paused=true;}
    remove(){
      this.removed=true;
      if(this.parent?.children){const i=this.parent.children.indexOf(this);if(i>=0)this.parent.children.splice(i,1);}
      this.parent=null;
    }
    play(){this.plays++;this.paused=false;this.emit('playing');return Promise.resolve();}
    requestVideoFrameCallback(cb){const id=++this.frameId;this.frame=cb;this.pendingFrames.set(id,cb);return id;}
    cancelVideoFrameCallback(id){const cb=this.pendingFrames.get(id);if(cb===this.frame)this.frame=undefined;if(this.pendingFrames.delete(id))this.cancelledFrames++;}
    flushFrame(){const cb=this.frame;this.frame=undefined;for(const [id,fn] of this.pendingFrames)if(fn===cb)this.pendingFrames.delete(id);cb?.();}
  }
  const document={
    body:container(),hidden:false,
    createElement:tag=>tag==='video'?new FakeVideo():container(),
    addEventListener:(name,callback)=>listeners.set(name,callback),
    removeEventListener:name=>listeners.delete(name),
  };
  const connection={saveData:false,effectiveType:'4g',downlink:10,rtt:30,
    addEventListener:(name,callback)=>listeners.set('connection:'+name,callback),
    removeEventListener:name=>listeners.delete('connection:'+name)};
  const window={
    setTimeout(fn,ms){const id=++nextTimer;timers.set(id,{fn,ms});return id;},
    clearTimeout(id){timers.delete(id);},
  };
  let intersectionObserver;
  class MockIntersectionObserver{
    constructor(callback,config){this.callback=callback;this.config=config;intersectionObserver=this;}
    observe(){}
    unobserve(){}
    disconnect(){}
    deliver(target,ratio){this.callback([{target,isIntersecting:ratio>0,intersectionRatio:ratio}]);}
  }
  function advance(){
    // Simulate a browser timer tick, not an unbounded infinite flush.
    const [id,task]=[...timers.entries()].sort((a,b)=>a[1].ms-b[1].ms)[0]||[];
    if(!task)return false;
    timers.delete(id);task.fn();return true;
  }
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports,document,window,navigator:{connection},
    performance:{now:()=>now},
    HTMLMediaElement:{HAVE_CURRENT_DATA:2},IntersectionObserver:intersection?MockIntersectionObserver:undefined});
  return {Pool:module.exports.HoverVideoPool,document,videos,timers,advance,container,
    getObserver:()=>intersectionObserver,connection,emitVisibility:()=>listeners.get('visibilitychange')?.(),
    emitConnection:()=>listeners.get('connection:change')?.(),
    advanceTime:ms=>{now+=ms;}};
}

test('all 18 trailers are preloaded progressively, never more than 2 background slots',async()=>{
  const {Pool,document,videos,advance}=await fixture();
  const source=Object.fromEntries(Array.from({length:18},(_,i)=>[`game-${i}`,{url:`https://example.com/${i}.webm`,bytes:100000}]));
  const pool=new Pool(source);
  pool.prioritize(['game-8','game-2']);
  pool.start();
  assert.equal(pool.getStatus().requested,0,'preload must not block first render');
  assert.ok(advance());
  assert.equal(pool.getStatus().requested,2);
  assert.equal(pool.getStatus().loading,2);
  assert.deepEqual(new Set(videos.filter(v=>v.src).map(v=>v.src)),
    new Set([source['game-8'].url,source['game-2'].url]));
  let max=2;
  for(let turn=0;turn<30;turn++){
    for(const video of [...videos])if(video.src&&!video.completeForTest){
      video.completeForTest=true;
      video.emit('canplaythrough');
    }
    advance();
    max=Math.max(max,pool.getStatus().loading);
    if(pool.getStatus().requested===18)break;
  }
  assert.equal(pool.getStatus().requested,18);
  assert.ok(max<=2);
  assert.ok(videos.every(v=>v.plays===0),'preload never starts playback');
  document.hidden=true;
  pool.stop();
});

test('hover interrupts queue immediately; same video is reused after card unmount',async()=>{
  const {Pool,container,videos,advance,document}=await fixture();
  const pool=new Pool({one:{url:'https://example.com/one.webm',bytes:1000},
    two:{url:'https://example.com/two.webm',bytes:1000}});
  const slot=container();
  const detach=pool.attach('two',slot);
  pool.start();
  pool.play('two');
  assert.equal(videos.length,1);
  assert.equal(videos[0].plays,1);
  assert.equal(videos[0].loads,1,'hover must trigger load even before idle scheduler');
  const instance=videos[0];
  detach();
  pool.attach('two',container());
  pool.play('two');
  assert.equal(videos[0],instance,'navigating between views must not create a new player');
  assert.equal(videos[0].loads,1,'same URL is not loaded again');
  assert.equal(videos[0].plays,2);
  pool.pause('two');
  assert.ok(videos[0].pauses>=1);
  document.hidden=true;
  advance();
  assert.equal(videos[0].plays,2,'background queue must never autoplay');
  pool.stop();
});

test('preloading obeys hidden window and save-data, foreground hover remains available',async()=>{
  const {Pool,document,videos,advance,container}=await fixture();
  const pool=new Pool({one:{url:'https://example.com/one.mp4',bytes:999}});
  document.hidden=true;
  pool.start();
  assert.equal(advance(),false);
  assert.equal(pool.getStatus().requested,0);
  const detach=pool.attach('one',container());
  pool.play('one');
  assert.equal(videos[0].plays,1);
  detach();
  pool.stop();
});

test('spinner appears on hover, clears on decoded frame, returns on network stall and disappears on leave',async()=>{
  const {Pool,videos,container}=await fixture();
  const pool=new Pool({one:{url:'https://example.com/one.webm',bytes:1000}});
  const card=container();
  const detach=pool.attach('one',card);
  pool.start();
  pool.play('one');
  assert.equal(card.classList.contains('card-video-loading'),true);
  assert.equal(card.classList.contains('card-video-playing'),false);
  videos[0].flushFrame();
  assert.equal(card.classList.contains('card-video-loading'),false);
  assert.equal(card.classList.contains('card-video-playing'),true);
  videos[0].emit('waiting');
  assert.equal(card.classList.contains('card-video-loading'),true);
  assert.equal(card.classList.contains('card-video-playing'),false);
  videos[0].emit('playing');
  videos[0].flushFrame();
  assert.equal(card.classList.contains('card-video-playing'),true);
  pool.pause('one');
  assert.equal(card.classList.contains('card-video-playing'),false);
  assert.equal(card.classList.contains('card-video-loading'),false);
  detach();
  pool.stop();
});

test('busy game/install operation suspends new background preloads and resumes after work',async()=>{
  const {Pool,advance}=await fixture();
  const source=Object.fromEntries(Array.from({length:5},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}]));
  const pool=new Pool(source);
  pool.start();
  pool.setBackgroundBusy(true);
  assert.equal(advance(),true,'existing startup scheduler checks busy before fetching');
  assert.equal(pool.getStatus().requested,0);
  pool.setBackgroundBusy(false);
  advance();
  assert.equal(pool.getStatus().requested,2);
  pool.stop();
});

test('a heavy native operation stops an already playing trailer and rejects incidental hover until idle',async()=>{
  const {Pool,container,videos}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000}});
  const card=container();pool.attach('a',card);pool.start();
  pool.play('a');videos[0].flushFrame();
  assert.equal(videos[0].paused,false);
  assert.equal(card.classList.contains('card-video-playing'),true);
  const previousPlays=videos[0].plays;
  pool.setBackgroundBusy(true);
  assert.equal(videos[0].paused,true);
  assert.equal(card.classList.contains('card-video-playing'),false);
  pool.play('a');
  assert.equal(videos[0].plays,previousPlays,'hover under game/install load cannot restart decoding');
  pool.setBackgroundBusy(false);
  assert.equal(videos[0].paused,true,'resuming background work never autoplays a trailer');
  pool.play('a');
  assert.equal(videos[0].plays,previousPlays+1,'new explicit hover can resume once idle');
  pool.stop();
});

test('active background requests are cancelled on heavy work and resumed when idle',async()=>{
  const {Pool,advance,videos}=await fixture();
  const pool=new Pool(Object.fromEntries(Array.from({length:5},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}])));
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  pool.setBackgroundBusy(true);
  assert.equal(pool.getStatus().loading,0);
  assert.ok(videos.slice(0,2).every(video=>video.src===''));
  pool.setBackgroundBusy(false);advance();
  assert.equal(pool.getStatus().loading,2);
  pool.stop();
});

test('newly visible cards outrank distant entries without duplicate elements',async()=>{
  const {Pool,advance,container,videos,getObserver}=await fixture({intersection:true});
  const source=Object.fromEntries(Array.from({length:8},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}]));
  const pool=new Pool(source);
  const near=container(),visible=container();
  const offNear=pool.observe('game-5',near);
  const offVisible=pool.observe('game-6',visible);
  pool.start();
  getObserver().deliver(near,0.02);
  getObserver().deliver(visible,0.6);
  advance();
  assert.deepEqual(videos.filter(v=>v.src).map(v=>v.src),[
    source['game-6'].url,source['game-5'].url]);
  offNear();offVisible();pool.stop();
});

test('a visible card preempts an unrelated slow metadata transfer instead of waiting 12 seconds',async()=>{
  const {Pool,advance,container,videos,getObserver}=await fixture({intersection:true});
  const source=Object.fromEntries(Array.from({length:9},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}]));
  const pool=new Pool(source);
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  const visible=container();
  pool.observe('game-8',visible);
  getObserver().deliver(visible,0.75);
  assert.equal(pool.getStatus().loading,1,'a far request yields immediately');
  advance();
  assert.ok(videos.some(video=>video.src===source['game-8'].url&&video.preload==='auto'));
  assert.equal(pool.getStatus().loading,2);
  pool.stop();
});

test('slow CDN request is aborted at deadline so other previews progress',async()=>{
  const {Pool,advance,videos}=await fixture();
  const source=Object.fromEntries(Array.from({length:4},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}]));
  const pool=new Pool(source);
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  advance();
  assert.equal(pool.getStatus().loading,1);
  assert.equal(videos.filter(v=>v.src).length,1);
  advance();
  assert.equal(pool.getStatus().loading,2);
  assert.equal(videos.filter(v=>v.src).length,2);
  pool.stop();
});

test('missing or inaccessible media shows fallback and does not retry on every rapid hover',async()=>{
  const {Pool,container,videos}=await fixture();
  const pool=new Pool({one:{url:'https://example.com/missing.webm',bytes:2000}});
  const card=container();
  pool.attach('one',card);
  pool.start();pool.play('one');
  assert.equal(videos[0].plays,1);
  videos[0].emit('error');
  assert.equal(card.classList.contains('card-video-unavailable'),true);
  assert.equal(card.classList.contains('card-video-loading'),false);
  pool.pause('one');pool.play('one');
  assert.equal(videos[0].plays,1,'a broken CDN must not be hammered on fast repeated hovers');
  assert.equal(card.classList.contains('card-video-unavailable'),true);
  pool.stop();
});

test('motion disabled immediately stops previews without removing cached players',async()=>{
  const {Pool,container,videos}=await fixture();
  const pool=new Pool({one:{url:'https://example.com/one.webm',bytes:1000}});
  pool.start();pool.attach('one',container());pool.play('one');
  const same=videos[0];
  pool.setEnabled(false);
  assert.ok(same.pauses>0);
  pool.play('one');
  assert.equal(same.plays,1);
  pool.setEnabled(true);pool.play('one');
  assert.equal(videos[0],same);
  assert.equal(same.plays,2);
  pool.stop();
});

test('hidden window cancels active preloads, and resuming visibility resumes the queue',async()=>{
  const {Pool,document,advance,emitVisibility,videos}=await fixture();
  const pool=new Pool(Object.fromEntries(Array.from({length:6},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}])));
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  document.hidden=true;
  emitVisibility();
  assert.equal(pool.getStatus().loading,0);
  assert.ok(videos.every(v=>!v.src));
  document.hidden=false;
  emitVisibility();advance();
  assert.equal(pool.getStatus().loading,2);
  pool.stop();
});

test('prototype-inherited IDs cannot be selected as external media URLs',async()=>{
  const {Pool,container,videos}=await fixture();
  const pool=new Pool({good:{url:'https://example.com/good.webm',bytes:1000}});
  pool.start();
  const dispose=pool.attach('constructor',container());
  pool.play('constructor');
  pool.prioritize(['toString','__proto__']);
  assert.equal(videos.length,0);
  dispose();pool.stop();
});

test('distant trailers fetch metadata only and promote to full clip synchronously on hover',async()=>{
  const {Pool,container,videos,advance}=await fixture();
  const source=Object.fromEntries(Array.from({length:8},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000000}]));
  const pool=new Pool(source);
  pool.prioritize(['game-7']);pool.start();advance();
  assert.equal(videos[0].preload,'auto');
  assert.equal(videos[1].preload,'metadata');
  const distant=videos[1];
  distant.emit('loadedmetadata');
  const detach=pool.attach('game-0',container());
  pool.play('game-0');
  assert.equal(distant.preload,'auto');
  assert.equal(distant.plays,1);
  assert.equal(distant.loads,1,'promotion must preserve the metadata resource and avoid restarting the first segment');
  detach();pool.stop();
});

test('up to 6 warm clips and 12MiB of known trailer bytes are resident, never 18 full videos',async()=>{
  const {Pool,videos,advance}=await fixture();
  const source=Object.fromEntries(Array.from({length:18},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:3000000}]));
  const pool=new Pool(source);
  pool.prioritize(['game-0','game-1','game-2','game-3','game-4','game-5','game-6']);
  pool.start();
  for(let i=0;i<60;i++){
    if(!advance())break;
    for(const video of videos)if(video.src&&!video.completeForTest){
      video.completeForTest=true;
      video.emit('loadeddata');
    }
    if(pool.getStatus().requested===18)break;
  }
  const status=pool.getStatus();
  assert.equal(status.requested,18);
  assert.ok(status.warm<=6);
  assert.ok(status.warmBytes<=12*1024*1024);
  assert.ok(videos.some(v=>v.preload==='metadata'));
  pool.stop();
});

test('slow network fetches metadata only with one slot and recovers when connectivity improves',async()=>{
  const {Pool,advance,videos,connection,emitConnection}=await fixture();
  const source=Object.fromEntries(Array.from({length:6},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:2500000}]));
  const pool=new Pool(source);
  connection.effectiveType='2g';connection.downlink=0.5;
  pool.prioritize(['game-5']);pool.start();advance();
  assert.equal(pool.getStatus().loading,1);
  assert.equal(videos[0].preload,'metadata');
  videos[0].emit('loadedmetadata');advance();
  assert.equal(pool.getStatus().loading,1);
  connection.effectiveType='4g';connection.downlink=20;
  emitConnection();advance();
  assert.equal(pool.getStatus().loading,2);
  assert.ok(videos.some(video=>video.preload==='auto'));
  pool.stop();
});

test('enabling save-data cancels pending background media immediately',async()=>{
  const {Pool,advance,videos,connection,emitConnection}=await fixture();
  const pool=new Pool(Object.fromEntries(Array.from({length:5},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}])));
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  connection.saveData=true;emitConnection();
  assert.equal(pool.getStatus().loading,0);
  assert.ok(videos.every(video=>!video.src));
  connection.saveData=false;emitConnection();advance();
  assert.equal(pool.getStatus().loading,2);
  pool.stop();
});

test('rapid back-and-forth hovers reuse sources and never play two trailers at once',async()=>{
  const {Pool,container,videos}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000},
    b:{url:'https://example.com/b.webm',bytes:1000},
    c:{url:'https://example.com/c.webm',bytes:1000}});
  pool.start();
  for(const id of ['a','b','c'])pool.attach(id,container());
  for(const id of ['a','b','a','c','b','a']){
    pool.play(id);
    assert.equal(videos.filter(v=>!v.paused).length,1);
  }
  assert.equal(videos.length,3,'exactly one reusable media element per ID');
  assert.ok(videos.every(v=>v.loads===1),'rapid hover does not restart existing network requests');
  pool.pause('a');
  assert.equal(videos.filter(v=>!v.paused).length,0);
  pool.stop();
});

test('a nearby metadata-only card is upgraded ahead of unrelated distant work',async()=>{
  const {Pool,container,videos,advance,getObserver}=await fixture({intersection:true});
  const source=Object.fromEntries(Array.from({length:5},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:1000}]));
  const pool=new Pool(source);
  pool.start();advance();
  const metadata=videos[1];
  metadata.emit('loadedmetadata');
  const target=container();
  pool.observe('game-1',target);
  getObserver().deliver(target,0.4);
  advance();
  assert.equal(metadata.preload,'auto');
  assert.equal(metadata.loads,1,'nearby promotion must not restart the media resource');
  pool.stop();
});

test('hovering an in-flight prefetch cancels its deadline without discarding the foreground video',async()=>{
  const {Pool,advance,videos,container}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000},b:{url:'https://example.com/b.webm',bytes:1000}});
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  pool.attach('a',container());
  pool.play('a');
  assert.equal(pool.getStatus().loading,1,'the foreground clip is not counted as an expiring background request');
  assert.equal(videos[0].src,'https://example.com/a.webm');
  advance(); // unrelated b timeout, must not abort active a
  assert.equal(videos[0].src,'https://example.com/a.webm');
  assert.equal(videos[0].plays,1);
  pool.stop();
});

test('stale decoded frame after rapid leave/reenter cannot reveal a previous playback request',async()=>{
  const {Pool,container,videos,advanceTime}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000}});
  const card=container();pool.attach('a',card);pool.start();
  pool.play('a');
  const callbackFromOldPlay=videos[0].frame;
  pool.pause('a');
  pool.play('a');
  advanceTime(75);
  callbackFromOldPlay();
  assert.equal(card.classList.contains('card-video-playing'),false);
  assert.equal(pool.getStatus().firstFrameSamples,0);
  videos[0].flushFrame();
  assert.equal(card.classList.contains('card-video-playing'),true);
  assert.equal(pool.getStatus().firstFrameP50Ms,75);
  assert.equal(pool.getStatus().firstFrameP95Ms,75);
  pool.stop();
});

test('rapid repeat hover or focus on one already-playing card has one pending decoded-frame callback',async()=>{
  const {Pool,container,videos}=await fixture();
  const pool=new Pool({same:{url:'https://example.com/same.webm',bytes:2000000}});
  const host=container();pool.attach('same',host);pool.start();
  for(let n=0;n<300;n++){
    pool.play('same');
    assert.ok(videos[0].pendingFrames.size<=1,'never accumulate unbounded GPU/frame callbacks');
  }
  assert.equal(videos[0].plays,1,'repeated focus/mouse-enter on same active card must not replay decoder');
  assert.equal(pool.getStatus().hoverAttempts,1,'repeated events must not inflate hover latency metrics');
  assert.equal(videos[0].pendingFrames.size,1,'keep exactly one first decoded frame request');
  videos[0].flushFrame();
  assert.equal(host.classList.contains('card-video-playing'),true);
  pool.pause('same');
  assert.equal(videos[0].pendingFrames.size,0);
  pool.stop();
});

test('disabling motion releases warm media bytes, retaining only reusable inert players',async()=>{
  const {Pool,advance,videos}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000000},b:{url:'https://example.com/b.webm',bytes:1000000}});
  pool.prioritize(['a','b']);pool.start();advance();
  videos.forEach(v=>v.emit('loadeddata'));
  assert.ok(pool.getStatus().warmBytes>0);
  pool.setEnabled(false);
  assert.equal(pool.getStatus().warmBytes,0);
  assert.equal(pool.getStatus().loading,0);
  assert.ok(videos.every(v=>!v.src&&v.paused));
  pool.setEnabled(true);advance();
  assert.equal(videos.length,2,'no additional video elements created');
  pool.stop();
});

test('1,000 rapid hover transitions stay bounded in DOM, scheduler and playback (measured synthetic CPU)',async t=>{
  const {Pool,container,videos,timers}=await fixture();
  const pool=new Pool(Object.fromEntries(Array.from({length:18},(_,i)=>[
    `game-${i}`,{url:`https://example.com/${i}.webm`,bytes:2_000_000}])));
  pool.start();
  for(let i=0;i<18;i++)pool.attach(`game-${i}`,container());
  const started=process.hrtime.bigint();
  for(let i=0;i<1000;i++){
    pool.play(`game-${i%18}`);
    if(i%7===0)pool.pause(`game-${i%18}`);
  }
  const elapsedMs=Number(process.hrtime.bigint()-started)/1e6;
  assert.equal(videos.length,18);
  assert.ok(videos.filter(v=>!v.paused).length<=1);
  assert.ok(timers.size<=2,'1000 pointer transitions must not accumulate unbounded timers');
  assert.ok(pool.getStatus().warm<=6);
  t.diagnostic(`Synthetic VM hover scheduler: 1000 transitions in ${elapsedMs.toFixed(2)} ms, ${(elapsedMs/1000).toFixed(3)} ms/transition (not WebView2 frame latency)`);
  pool.stop();
});

test('large library registers 900 off-screen cards without 900 players and immediate focused card attaches',async()=>{
  const {Pool,container,videos,getObserver,advance}=await fixture({intersection:true});
  const sources=Object.fromEntries(Array.from({length:900},(_,i)=>[
    `g-${i}`,{url:`https://example.com/${i}.webm`,bytes:500000}]));
  const pool=new Pool(sources);
  const disposers=[];
  const cards=[];
  for(let i=0;i<900;i++){
    const card=container();cards.push(card);
    disposers.push(pool.registerSlot(`g-${i}`,card));
  }
  assert.equal(videos.length,0,'mounting the library must not allocate video elements');
  pool.start();advance();
  assert.equal(pool.getStatus().loading,2);
  getObserver().deliver(cards[890],0.35);
  assert.ok(videos.length<=3,'only the near card and two background players exist');
  pool.play('g-877');
  assert.ok(videos.some(v=>v.src===sources['g-877'].url&&v.plays===1));
  assert.ok(pool.getStatus().residentPlayers<=4);
  disposers.forEach(dispose=>dispose());
  pool.stop();
});

test('scrolling 120 mounted cards evicts offscreen decoders at 32 and reattaches a previously evicted visible card',async()=>{
  const {Pool,container,getObserver,videos}=await fixture({intersection:true});
  const sources=Object.fromEntries(Array.from({length:120},(_,i)=>[
    `g-${i}`,{url:`https://example.com/${i}.webm`,bytes:100000}]));
  const pool=new Pool(sources),cards=[],dispose=[];
  for(let i=0;i<120;i++){
    const card=container();cards.push(card);
    dispose.push(pool.registerSlot(`g-${i}`,card));
  }
  pool.start();
  for(let i=0;i<120;i++){
    getObserver().deliver(cards[i],0.8);
    if(i>0)getObserver().deliver(cards[i-1],0);
    assert.ok(pool.getStatus().residentPlayers<=32,`card ${i} exceeded decoder cap`);
  }
  assert.ok(videos.length>=120,'long scrolling genuinely created more than 32 distinct players over time');
  assert.equal(videos.filter(video=>!video.removed).length,pool.getStatus().residentPlayers);
  assert.equal(videos[0].removed,true,'first previously visible card must release its decoder offscreen');
  pool.play('g-119',cards[119]);
  assert.equal(pool.activeId,'g-119');
  getObserver().deliver(cards[0],0.8);
  assert.ok(pool.getStatus().residentPlayers<=32);
  assert.equal(pool.activeId,'g-119','a new visible placeholder never steals active playback');
  assert.ok(videos.at(-1).parent===cards[0]||videos.some(v=>v.src===sources['g-0'].url&&v.parent===cards[0]),
    'evicted card reattaches an inert player when it returns near viewport');
  dispose.forEach(fn=>fn());pool.stop();
});

test('1,024 distant trailers get metadata eventually with at most 32 live players and 2 requests',async t=>{
  const {Pool,videos,advance,document}=await fixture();
  const total=1024;
  const sources=Object.fromEntries(Array.from({length:total},(_,i)=>[
    `g-${i}`,{url:`https://example.com/${i}.webm`,bytes:400000}]));
  const pool=new Pool(sources);
  pool.start();
  const start=process.hrtime.bigint();
  let maxPlayers=0,maxLoading=0,steps=0;
  for(;steps<total*5;steps++){
    if(!advance())break;
    for(const video of videos)if(video.src&&!video.completeForTest){
      video.completeForTest=true;
      video.emit('loadedmetadata');
    }
    const status=pool.getStatus();
    maxPlayers=Math.max(maxPlayers,status.residentPlayers);
    maxLoading=Math.max(maxLoading,status.loading);
    if(status.metadataCovered===total)break;
  }
  const elapsed=Number(process.hrtime.bigint()-start)/1e6;
  const status=pool.getStatus();
  assert.equal(status.metadataCovered,total,'rolling cursor eventually probes all catalog media');
  assert.equal(status.requested,total);
  assert.ok(maxLoading<=2);
  assert.ok(maxPlayers<=32,`resident players ${maxPlayers} must stay bounded`);
  assert.ok(document.body.children[0].children.length<=32,'hidden stage retains no unbounded video nodes');
  assert.equal(videos.filter(v=>!v.removed).length,status.residentPlayers);
  t.diagnostic(`Synthetic 1024 metadata probes: ${elapsed.toFixed(1)} ms CPU, ${steps} scheduler ticks, max ${maxPlayers} players (not network/codec time)`);
  pool.stop();
});

test('removed stale player callbacks cannot affect a new player with same ID',async()=>{
  const {Pool,videos,advance,container}=await fixture();
  const sources=Object.fromEntries(Array.from({length:45},(_,i)=>[
    `g-${i}`,{url:`https://example.com/${i}.webm`,bytes:400000}]));
  const pool=new Pool(sources);pool.start();
  for(let i=0;i<130;i++){
    if(!advance())break;
    for(const video of videos)if(video.src&&!video.completeForTest){
      video.completeForTest=true;video.emit('loadedmetadata');
    }
    if(pool.getStatus().metadataCovered===45)break;
  }
  const previous=videos[0];
  assert.equal(previous.removed,true);
  pool.attach('g-0',container());
  const newer=videos.at(-1);
  assert.notEqual(previous,newer);
  pool.play('g-0');
  const before=pool.getStatus().firstFrameSamples;
  previous.emit('loadeddata');
  assert.equal(pool.getStatus().firstFrameSamples,before);
  assert.equal(newer.src,sources['g-0'].url);
  pool.stop();
});

test('an active game releases completed background videos, not just its two scheduler slots',async()=>{
  const {Pool,advance,videos}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000000},
    b:{url:'https://example.com/b.webm',bytes:1000000}});
  pool.prioritize(['a','b']);pool.start();advance();
  for(const v of videos)v.emit('loadeddata');
  assert.equal(pool.getStatus().warm,2);
  assert.equal(pool.getStatus().loading,0);
  pool.setBackgroundBusy(true);
  assert.equal(pool.getStatus().warm,0,'idle video sources must stop after a game starts');
  assert.ok(videos.every(v=>!v.src&&v.paused));
  pool.setBackgroundBusy(false);advance();
  assert.equal(pool.getStatus().loading,2,'priority cards resume warm prefetch when app is idle');
  pool.stop();
});

test('hidden window releases completed warm streams without retrying already-known distant metadata',async()=>{
  const {Pool,advance,videos,document,emitVisibility}=await fixture();
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000000},
    b:{url:'https://example.com/b.webm',bytes:1000000}});
  pool.prioritize(['a']);pool.start();advance();
  for(const v of videos)v.emit('loadedmetadata');
  const distant=videos.find(v=>v.src.includes('/b.webm'));
  const previousLoads=distant?.loads;
  const priorMetadata=pool.getStatus().metadataCovered;
  document.hidden=true;emitVisibility();
  assert.equal(pool.getStatus().warm,0);
  document.hidden=false;emitVisibility();advance();
  assert.equal(pool.getStatus().metadataCovered,priorMetadata);
  assert.ok(videos.find(v=>v.src.includes('/a.webm')),'recent/visible high-priority clip can re-warm');
  assert.equal(distant?.loads,previousLoads,'distant clip should not re-download known metadata');
  pool.stop();
});

test('duplicate cards share one decoder; old card blur cannot interrupt the new focused card',async()=>{
  const {Pool,container,videos,getObserver}=await fixture({intersection:true});
  const pool=new Pool({same:{url:'https://example.com/same.webm',bytes:2000000}});
  const left=container(),right=container();
  const disposeLeft=pool.registerSlot('same',left);
  const disposeRight=pool.registerSlot('same',right);
  pool.start();
  getObserver().deliver(left,0.8);
  getObserver().deliver(right,0.5);
  assert.equal(videos.length,1);
  pool.play('same',left);
  videos[0].flushFrame();
  assert.equal(left.classList.contains('card-video-playing'),true);
  getObserver().deliver(right,0.8);
  assert.equal(videos[0].parent,left,'viewport events cannot steal a playing shared video');
  pool.play('same',right);
  assert.equal(videos.length,1);
  assert.equal(videos[0].parent,right,'the single player moves to the newly focused card');
  assert.equal(left.classList.contains('card-video-playing'),false,'transferred video restores previous poster');
  assert.equal(left.classList.contains('card-video-loading'),false,'old poster has no orphan spinner');
  pool.pause('same',left);
  assert.equal(videos[0].paused,false,'stale left blur cannot stop right preview');
  getObserver().deliver(left,0);
  disposeLeft();
  assert.equal(pool.proximity.get('same'),2,'one visible card retains the high-priority viewport state');
  assert.equal(videos[0].paused,false);
  pool.pause('same',right);
  assert.equal(videos[0].paused,true);
  disposeRight();pool.stop();
});

test('closing and reopening preview pool releases actual DOM nodes, media source and timers',async()=>{
  const {Pool,container,document,videos,advance,timers}=await fixture({intersection:true});
  const pool=new Pool({a:{url:'https://example.com/a.webm',bytes:1000},b:{url:'https://example.com/b.webm',bytes:1000}});
  const slot=container();
  pool.registerSlot('a',slot);pool.start();advance();
  assert.ok(document.body.children[0].children.length>0);
  pool.play('a',slot);
  const old=videos[0];
  pool.stop();
  assert.equal(old.src,'');
  assert.equal(old.removed,true);
  assert.equal(pool.getStatus().residentPlayers,0);
  assert.equal(pool.getStatus().loading,0);
  assert.equal(timers.size,0);
  assert.equal(document.body.children[0].removed,true);
  const next=container();pool.registerSlot('a',next);pool.start();
  pool.play('a',next);
  assert.ok(videos.length>2,'reopen can create a fresh player without leaking the former one');
  assert.notEqual(videos.at(-1),old);
  pool.stop();
});

test('a previously evicted warm clip can be prepared again when its card becomes visible',async()=>{
  const {Pool,container,videos,advance,getObserver}=await fixture({intersection:true});
  const source=Object.fromEntries(Array.from({length:7},(_,i)=>[
    `g-${i}`,{url:`https://example.com/${i}.webm`,bytes:4_000_000}]));
  const pool=new Pool(source);
  pool.prioritize(Object.keys(source));pool.start();
  for(let step=0;step<35;step++){
    if(!advance())break;
    for(const video of videos){
      if(!video.src||video.completeForTest)continue;
      video.completeForTest=true;video.emit('loadeddata');
    }
    if(pool.getStatus().requested===7&&pool.getStatus().loading===0)break;
  }
  assert.ok(pool.warmEvicted.size>0,'memory pressure evicted at least one warm resource');
  const id=[...pool.warmEvicted][0];
  const slot=container();
  const dispose=pool.registerSlot(id,slot);
  getObserver().deliver(slot,0.6);
  assert.equal(pool.warmEvicted.has(id),false,'visible transition clears the eviction fence');
  advance();
  assert.equal(pool.clips.get(id)?.video.src,source[id].url,'visible card gets a new bounded warm request');
  dispose();pool.stop();
});
