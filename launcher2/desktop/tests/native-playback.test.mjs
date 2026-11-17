import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';
import {randomUUID} from 'node:crypto';
const tick=()=>new Promise(resolve=>setImmediate(resolve));
class Pixels{constructor(width,height){this.width=width;this.height=height;this.data=new Uint8ClampedArray(width*height*4);}}
const HEADER=64,SLOT=1920*1080*4;
function sample(){const buffer=new ArrayBuffer(HEADER+2*SLOT),header=new DataView(buffer);for(const [offset,value]of [[0,2],[4,0],[8,8],[12,2],[16,32]])header.setUint32(offset,value,true);const pixels=new Uint8Array(buffer,HEADER,64);for(let at=0;at<pixels.length;at+=4)pixels.set([21,42,63,255],at);return buffer;}
async function frameModule(){const code=await readFile(new URL('../src/native-video-frame.ts',import.meta.url),'utf8'),exports={};vm.runInNewContext(ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports,ImageData:Pixels});return exports;}
function yuvSample(){const buffer=new ArrayBuffer(HEADER+2*SLOT),header=new DataView(buffer);for(const [offset,value]of [[0,2],[4,0],[8,8],[12,2],[16,32],[20,1],[24,32]])header.setUint32(offset,value,true);return buffer;}
async function harness(invoke,setup={}){
 const frame=await frameModule(),source=await readFile(new URL('../src/native-playback.ts',import.meta.url),'utf8');
 const effects=[],timers=new Map(),rafs=new Map(),listeners=new Map(),released=[],painted=[],uploaded=[],reported=[];let serial=0,disposedRenderers=0,lose=null;
 const gl={yuvRendererFor:(canvas,onLost)=>{if(setup.webgl!=='ok')return setup.webgl??'unavailable';lose=onLost;return {draw:(buffer,frame)=>uploaded.push(frame),dispose:()=>disposedRenderers++};}};
 const bridge={addEventListener:(name,fn)=>listeners.set(name,fn),removeEventListener:(name,fn)=>{if(listeners.get(name)===fn)listeners.delete(name);},releaseBuffer:b=>released.push(b)};
 const exports={};
 const emit=requestId=>listeners.get('sharedbufferreceived')?.({additionalData:{kind:'coco-video-frame-v2',requestId},getBuffer:()=>setup.yuv?yuvSample():sample()});
 const native=async(name,args)=>{if(name==='open_native_player')queueMicrotask(()=>emit(args.requestId));return await invoke(name,args);};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{
  exports,require:name=>name==='react'?{useLayoutEffect:fn=>effects.push(fn)}:name==='./native-video-frame'?frame:name==='./native-video-gl'?gl:{invoke:native},
  ResizeObserver:class{observe(){}disconnect(){}},Event,console:{warn(){}},crypto:{randomUUID},
  window:{chrome:{webview:bridge},innerWidth:1920,innerHeight:1080,
   setTimeout:fn=>{timers.set(++serial,fn);return serial;},clearTimeout:id=>timers.delete(id),
   requestAnimationFrame:fn=>{rafs.set(++serial,fn);return serial;},cancelAnimationFrame:id=>rafs.delete(id),addEventListener(){},removeEventListener(){}},
 });
 const video=new EventTarget();Object.assign(video,{play:()=>Promise.resolve(),pause(){},load(){},currentTime:0,duration:NaN,paused:true,volume:1,muted:false,playbackRate:1});
 const canvas={width:300,height:150,style:{},parentElement:{clientWidth:1920,clientHeight:1080},getContext:()=>({putImageData:(image,x,y)=>painted.push({image,x,y})})};
 const mount=()=>{effects.length=0;exports.useNativePlayback(true,'http://127.0.0.1:2000/token.mp4',{current:video},{current:canvas},{safe:setup.safe??true,onEvent:(kind,detail)=>reported.push({kind,detail})});const cleanups=effects.map(fn=>fn());return()=>cleanups.reverse().forEach(fn=>fn?.());};
 const advance=async map=>{const entry=[...map.entries()].at(-1);assert.ok(entry);map.delete(entry[0]);await entry[1]();await tick();};
 return {video,canvas,mount,poll:()=>advance(timers),draw:()=>advance(rafs),released,painted,emit,uploaded,reported,renderersDisposed:()=>disposedRenderers,loseContext:()=>lose?.()};
}
const snapshot={position:12,duration:5632,paused:false,volume:.7,muted:false,rate:1,buffering:false,ended:false,loaded:true,hasVideo:true,cacheSeconds:30,error:null};

test('decoder frame and existing controls share a canvas; early commands preserve metadata and playback events',async()=>{
 const calls=[];const h=await harness(async(name,args)=>{calls.push({name,args});if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot};return true;});
 const events=[];for(const name of ['play','loadedmetadata','canplay','playing'])h.video.addEventListener(name,()=>events.push(name));
 const close=h.mount();h.video.volume=.4;await h.video.play();await tick();await tick();
 assert.ok(!events.includes('loadedmetadata'),'metadata must wait for an actually painted frame');
 await h.draw();await h.poll();assert.equal(h.video.duration,5632);assert.equal(h.video.currentTime,12);
 assert.ok(events.includes('loadedmetadata'));assert.ok(events.includes('playing'));assert.ok(events.includes('play'));
 assert.equal(h.painted.length,1);assert.deepEqual([...h.painted[0].image.data.slice(-4)],[21,42,63,255],'bottom row was not cut');
 assert.ok(calls.some(c=>c.name==='control_native_player'&&c.args.action==='volume'&&c.args.value===.4));
 h.video.currentTime=100;await tick();assert.ok(calls.some(c=>c.name==='control_native_player'&&c.args.action==='seek'&&c.args.value===100));
 close();await tick();assert.ok(calls.some(c=>c.name==='close_native_player'));assert.equal(h.released.length,1);
});

test('StrictMode late opens close before replacement and cannot overwrite its canvas or adapter',async()=>{
 let release;let opens=0;const calls=[];
 const h=await harness(async(name,args)=>{
  if(name==='open_native_player'){opens++;calls.push(`open${opens}`);if(opens===1)return await new Promise(resolve=>release=resolve);return 'new';}
  if(name==='close_native_player'){calls.push(`close:${args.id}`);return true;}
  if(name==='native_player_status')return {...snapshot};return true;
 });
 const first=h.mount();await tick();first();const second=h.mount();release('old');await tick();await tick();
 assert.deepEqual(calls.slice(0,3),['open1','close:old','open2']);await h.draw();await h.poll();assert.equal(h.video.duration,5632);
 second();await tick();assert.ok(calls.includes('close:new'));
});

test('closed session ignores late status instead of repainting a detached player',async()=>{
 let status;const h=await harness(async(name)=>{if(name==='open_native_player')return 'one';if(name==='native_player_status')return await new Promise(resolve=>status=resolve);return true;});
 let metadata=0;h.video.addEventListener('loadedmetadata',()=>metadata++);const close=h.mount();await tick();close();status({...snapshot});await tick();assert.equal(metadata,0);assert.equal(h.painted.length,0);
});

test('one viewport edge is touched, neither is exceeded, and the aspect ratio is preserved',async()=>{
 const {fitVideoSize}=await frameModule();
 for(const [w,h,vw,vh]of [[1918,1036,1920,1080],[1920,804,1280,820],[720,1280,1920,1080],[640,360,3840,2160]]){
  const fit=fitVideoSize(w,h,vw,vh);assert.ok(fit.width<=vw+1e-8&&fit.height<=vh+1e-8);
  assert.ok(Math.abs(fit.width-vw)<1e-8||Math.abs(fit.height-vh)<1e-8);assert.ok(Math.abs(fit.width/fit.height-w/h)<1e-8);
 }
});

test('shared reader copies complete padded rows and skips unstable or malformed frames',async()=>{
 const {paintSharedFrame}=await frameModule(),buffer=sample(),header=new DataView(buffer);
 header.setUint32(8,7,true);const frame=paintSharedFrame(buffer,0,null);assert.equal(frame.image.width,7);assert.equal(frame.image.data.length,7*2*4);assert.deepEqual([...frame.image.data.slice(-4)],[21,42,63,255]);
 assert.equal(paintSharedFrame(buffer,2,frame.image),null);header.setUint32(0,3,true);assert.equal(paintSharedFrame(buffer,0,null),null);
 header.setUint32(0,4,true);header.setUint32(8,999999,true);assert.throws(()=>paintSharedFrame(buffer,0,null),/dimensions/);
});

test('controls and hover UI use DOM overlays without child video windows, masks or reserved strips',async()=>{
 const source=await readFile(new URL('../src/MediaPlayer.tsx',import.meta.url),'utf8'),native=await readFile(new URL('../src-tauri/src/services/native_player.rs',import.meta.url),'utf8');
 assert.match(source,/<canvas ref=\{canvasRef\}/);assert.doesNotMatch(source,/Coco cinema|className="coco-media-type"/);
 assert.doesNotMatch(native,/CreateWindowEx|SetWindowPos|SetWindowRgn/);
 const handler=source.match(/onContextMenu=\{event=>([^}]+)\}/)?.[1];let prevented=false;new Function('event',handler)({preventDefault(){prevented=true;}});assert.ok(prevented);
 assert.match(source,/src=\{native\?undefined:url\}/);
});

test('fast mode asks for GPU decoding, draws I420 planes with WebGL and reports the first picture',async()=>{
 const calls=[];const h=await harness(async(name,args)=>{calls.push({name,args});if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot,frames:9};return true;},{safe:false,webgl:'ok',yuv:true});
 const events=[];for(const name of ['loadedmetadata','playing','error'])h.video.addEventListener(name,()=>events.push(name));
 const close=h.mount();await h.video.play();await tick();await tick();
 assert.equal(calls.find(c=>c.name==='open_native_player').args.fast,true);
 await h.draw();await h.poll();
 assert.equal(h.uploaded.length,1);assert.equal(h.painted.length,0,'no RGBA copy in the fast mode');
 assert.deepEqual({...h.uploaded[0]},{sequence:2,width:8,height:2,stride:32,yuv:true,chromaStride:32,offset:64});
 assert.equal(h.canvas.width,8);assert.equal(h.canvas.height,2);
 assert.deepEqual(events,['loadedmetadata','playing']);assert.ok(h.reported.some(e=>e.kind==='first-frame'&&/rápido/.test(e.detail)));
 close();await tick();assert.equal(h.renderersDisposed(),1);assert.ok(h.reported.some(e=>e.kind==='closed'));
});

test('a PC without WebGL keeps the 2D canvas and software decoding without remounting',async()=>{
 const calls=[];const h=await harness(async(name,args)=>{calls.push({name,args});if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot};return true;},{safe:false,webgl:'unavailable'});
 const close=h.mount();await tick();await tick();
 assert.equal(calls.find(c=>c.name==='open_native_player').args.fast,false);
 await h.draw();assert.equal(h.painted.length,1);assert.ok(!h.reported.some(e=>e.kind==='fallback'));close();
});

test('fast mode failures before the first picture ask for the compatible mode instead of an error',async()=>{
 // The decoder cannot open the film.
 let h=await harness(async name=>{if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot,error:'x'};return true;},{safe:false,webgl:'ok',yuv:true});
 let errors=0;h.video.addEventListener('error',()=>errors++);let close=h.mount();await tick();await tick();await tick();
 assert.equal(errors,0);assert.deepEqual(h.reported.map(e=>e.kind),['fallback']);close();
 // The engine does not start at all.
 h=await harness(async name=>{if(name==='open_native_player')throw Error('Cannot load bundled decoder');return true;},{safe:false,webgl:'ok',yuv:true});
 errors=0;h.video.addEventListener('error',()=>errors++);close=h.mount();await tick();await tick();
 assert.equal(errors,0);assert.deepEqual(h.reported.map(e=>e.kind),['fallback']);assert.match(h.reported[0].detail,/bundled decoder/);close();
 // Sound advances but no picture ever arrives.
 let position=0;h=await harness(async name=>{if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot,position:++position};return true;},{safe:false,webgl:'ok',yuv:true});
 close=h.mount();await h.video.play();await tick();await tick();
 for(let polls=0;polls<4;polls++)await h.poll();
 assert.equal(h.reported.length,0,'four seconds of sound without picture is still a slow start');await h.poll();assert.deepEqual(h.reported.map(e=>e.kind),['fallback']);close();
 // A lost graphics context mid-film.
 h=await harness(async name=>{if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot};return true;},{safe:false,webgl:'ok',yuv:true});
 close=h.mount();await tick();await tick();await h.draw();h.loseContext();assert.ok(h.reported.some(e=>e.kind==='fallback'));close();
});

test('the compatible mode reports the cause of an error; it has nothing left to fall back to',async()=>{
 const h=await harness(async name=>{if(name==='open_native_player')throw Error('Actualiza Microsoft Edge WebView2 para reproducir vídeo.');return true;});
 let errors=0;h.video.addEventListener('error',()=>errors++);const close=h.mount();await tick();await tick();
 assert.equal(errors,1);assert.deepEqual(h.reported.map(e=>e.kind),['problem']);assert.match(h.reported[0].detail,/WebView2/);close();
});

test('held seeks are merged, and the clock keeps the place asked for until the decoder reaches it',async()=>{
 const calls=[];let position=12;
 const h=await harness(async(name,args)=>{calls.push({name,args});if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot,position};return true;});
 const close=h.mount();await tick();await tick();await h.draw();await h.poll();
 const seeks=()=>calls.filter(c=>c.name==='control_native_player'&&c.args.action==='seek').map(c=>c.args.value);
 h.video.currentTime=22;h.video.currentTime=32;h.video.currentTime=42;await tick();
 assert.deepEqual(seeks(),[22],'the first goes out at once; the rest wait for the gap');
 assert.equal(h.video.currentTime,42);
 // The decoder still reports the old place: a relative seek must add up from the request.
 position=12.3;await h.poll();assert.equal(h.video.currentTime,42);
 close();
});

test('a film that stops advancing shows loading, and playing again when it moves',async()=>{
 let position=12;const h=await harness(async name=>{if(name==='open_native_player')return 'session';if(name==='native_player_status')return {...snapshot,position};return true;});
 const events=[];for(const name of ['waiting','playing'])h.video.addEventListener(name,()=>events.push(name));
 const close=h.mount();await tick();await tick();await h.draw();await h.poll();assert.deepEqual(events,['playing']);
 for(let polls=0;polls<2;polls++)await h.poll();assert.deepEqual(events,['playing'],'under a second without progress is not a stall yet');
 await h.poll();assert.deepEqual(events,['playing','waiting']);
 position=13;await h.poll();assert.deepEqual(events,['playing','waiting','playing']);close();
});

test('I420 frames are validated: even sizes, both strides and room for the three planes',async()=>{
 const {readFrameHeader}=await frameModule(),buffer=yuvSample(),header=new DataView(buffer);
 assert.equal(readFrameHeader(buffer,0).yuv,true);assert.equal(readFrameHeader(buffer,2),null);
 header.setUint32(8,7,true);assert.throws(()=>readFrameHeader(buffer,0),/dimensions/,'odd width');
 header.setUint32(8,8,true);header.setUint32(24,0,true);assert.throws(()=>readFrameHeader(buffer,0),/dimensions/,'missing chroma stride');
 header.setUint32(24,32,true);header.setUint32(8,1920,true);header.setUint32(12,1080,true);header.setUint32(16,7680,true);header.setUint32(24,7680,true);
 assert.throws(()=>readFrameHeader(buffer,0),/dimensions/,'planes larger than the slot');
});

test('the film plays over black, never over the launcher glow',async()=>{
 const css=await readFile(new URL('../src/cinema.css',import.meta.url),'utf8');
 assert.match(css,/\.coco-player-shell\{[^}]*background:#000;/);
});
