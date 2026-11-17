import {useLayoutEffect,type RefObject} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {paintSharedFrame,readFrameHeader,frameSequence,fitVideoSize,FRAME_BYTES,type FrameImage} from './native-video-frame';
import {yuvRendererFor,type YuvRenderer} from './native-video-gl';

type Snapshot={position:number;duration:number;paused:boolean;volume:number;muted:boolean;rate:number;
  buffering:boolean;ended:boolean;loaded:boolean;hasVideo:boolean;cacheSeconds:number;error:string|null;frames?:number};
type SharedEvent={additionalData:{kind?:string;requestId?:string;id?:string;headerBytes:number;slotBytes:number;byteLength:number};getBuffer:()=>ArrayBuffer};
type SharedView={addEventListener:(name:string,listener:(event:SharedEvent)=>void)=>void;
  removeEventListener:(name:string,listener:(event:SharedEvent)=>void)=>void;releaseBuffer:(buffer:ArrayBuffer)=>void};
/** 'fallback': the fast mode cannot show this film here; reopen with `safe`.
 * 'first-frame', 'note' and 'closed' are for the log; 'problem' is the cause of an error. */
export type PlaybackEvent='fallback'|'first-frame'|'problem'|'note'|'closed';
export type PlaybackOptions={
  /** Compatible mode: software decoding and a 2D canvas. Default is the fast mode (GPU decoding, WebGL). */
  safe?:boolean;
  onEvent?:(kind:PlaybackEvent,detail:string)=>void;
};
const POLL_MS=250;
/** Seeks while an arrow key is held are merged: each one reopens the stream. */
const SEEK_GAP_MS=140;
/** The clock shows the place asked for until the decoder gets there. */
const SEEK_HOLD_MS=2500;
/** A second without progress while playing is shown as loading. */
const STALL_POLLS=4;
/** Seconds of film heard without a single picture: the fast mode is not working here.
 * A slow first connection can delay the picture by 3 seconds; that is not a failure. */
const NO_PICTURE_SECONDS=5;
let lifecycle:Promise<unknown>=Promise.resolve();
const serialize=(task:()=>Promise<void>)=>{lifecycle=lifecycle.catch(()=>{}).then(task);return lifecycle;};

/** Decoder frames and controls share the WebView compositor. The hidden video
 * is just the existing controls' event adapter; no movie bytes enter its decoder. */
export function useNativePlayback(enabled:boolean,url:string,videoRef:RefObject<HTMLVideoElement|null>,canvasRef:RefObject<HTMLCanvasElement|null>,options?:PlaybackOptions){
  const safe=options?.safe===true;
  useLayoutEffect(()=>{
    if(!enabled)return;
    const video=videoRef.current,canvas=canvasRef.current;if(!video||!canvas)return;
    let disposed=false,id:string|null=null,timer=0,raf=0,metadata=false,started=false,drawn=false,gaveUp=false;
    let buffer:ArrayBuffer|null=null,image:FrameImage|null=null,lastSequence=0;
    const openedAt=Date.now();
    const requestId=crypto.randomUUID();
    const shared=(window as unknown as {chrome?:{webview?:SharedView}}).chrome?.webview;
    const notify=(kind:PlaybackEvent,detail:string)=>{try{options?.onEvent?.(kind,detail);}catch{/* a log line must not stop playback */}};
    const canFallBack=!safe&&typeof options?.onEvent==='function';
    /** Leaves the fast mode: the owner remounts this hook with `safe`. */
    const fallBack=(reason:string)=>{if(disposed||gaveUp)return;gaveUp=true;notify('fallback',reason);};
    let renderer:YuvRenderer|null=null;
    if(!safe){
      const made=yuvRendererFor(canvas,()=>fallBack('la tarjeta gráfica dejó de responder'));
      if(typeof made==='object'&&'broken' in made){
        // The canvas already has a WebGL context that cannot draw; only a new canvas can take 2D.
        if(canFallBack){fallBack(`WebGL no dibuja: ${made.broken}`);return;}
      }else if(made==='unavailable')notify('note','sin WebGL: se dibuja en modo compatible');
      else renderer=made;
    }
    const yuv=renderer!==null;
    const context=yuv?null:canvas.getContext('2d',{alpha:false,desynchronized:true});
    let state:Snapshot={position:0,duration:NaN,paused:true,volume:1,muted:false,rate:1,buffering:false,ended:false,loaded:false,hasVideo:false,cacheSeconds:0,error:null};
    const desired={volume:1,muted:false,rate:1};
    const pending:Array<{action:string;value?:number}>=[];
    let commands:Promise<unknown>=Promise.resolve();
    const event=(name:string)=>{if(!disposed)video.dispatchEvent(new Event(name));};
    const fail=(error:unknown)=>{
      if(disposed||gaveUp)return;
      console.warn('Coco decoder:',error);
      const detail=error instanceof Error?error.message:String(error);
      // Before the first picture, a failure of the fast mode is retried in the compatible one.
      if(yuv&&!drawn&&canFallBack){fallBack(detail);return;}
      notify('problem',detail);event('error');
    };
    const control=(action:string,value?:number)=>{
      if(disposed)return;
      if(!id){pending.push({action,value});return;}
      commands=commands.catch(()=>{}).then(async()=>{if(!disposed&&id)await invoke('control_native_player',{id,action,value:value??null});}).catch(fail);
    };
    // Seeking: the decoder's clock lags behind the request, and every seek costs a reconnection.
    let reported=0,seekWanted:number|null=null,seekTimer=0,lastSeekAt=0,holdUntil=0,holdTarget=0,holdFrom=0;
    const flushSeek=()=>{
      seekTimer=0;if(seekWanted===null||disposed)return;
      const value=seekWanted;seekWanted=null;lastSeekAt=Date.now();control('seek',value);
    };
    const seek=(value:number)=>{
      if(Date.now()>=holdUntil)holdFrom=reported;
      state.position=value;state.ended=false;holdTarget=value;holdUntil=Date.now()+SEEK_HOLD_MS;seekWanted=value;
      const wait=SEEK_GAP_MS-(Date.now()-lastSeekAt);
      if(wait<=0)flushSeek();else if(!seekTimer)seekTimer=window.setTimeout(flushSeek,wait);
    };
    const fit=()=>{
      if(!canvas.width||!canvas.height)return;
      const parent=canvas.parentElement;
      const size=fitVideoSize(canvas.width,canvas.height,parent?.clientWidth??window.innerWidth,parent?.clientHeight??window.innerHeight);
      canvas.style.width=`${size.width}px`;canvas.style.height=`${size.height}px`;
    };
    const resize=(width:number,height:number)=>{
      if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;fit();}
    };
    const painted=()=>{
      if(drawn)return;
      drawn=true;firstFrameAt=Date.now();notify('first-frame',`${Date.now()-openedAt} ms, ${canvas.width}×${canvas.height}, ${yuv?'rápido':'compatible'}`);
    };
    const draw=()=>{
      if(disposed)return;
      try{
        if(buffer&&renderer){
          const frame=readFrameHeader(buffer,lastSequence);
          if(frame){
            if(!frame.yuv)throw Error('Unexpected frame format');
            resize(frame.width,frame.height);
            renderer.draw(buffer,frame);
            // The decoder may publish while the planes upload: that frame is drawn again next time.
            if(frameSequence(buffer)===frame.sequence){lastSequence=frame.sequence;painted();}
          }
        }else if(buffer&&context){
          const frame=paintSharedFrame(buffer,lastSequence,image);
          if(frame){
            image=frame.image;resize(image.width,image.height);
            context.putImageData(image,0,0);lastSequence=frame.sequence;painted();
          }
        }
      }catch(error){fail(error);}
      raf=window.requestAnimationFrame(draw);
    };
    const receive=(message:SharedEvent)=>{
      if(disposed||message.additionalData?.kind!=='coco-video-frame-v2'||message.additionalData.requestId!==requestId)return;
      try{
        const next=message.getBuffer();
        if(next.byteLength!==FRAME_BYTES){shared?.releaseBuffer(next);throw Error('Invalid video buffer size');}
        if(buffer)shared?.releaseBuffer(buffer);buffer=next;lastSequence=0;
      }catch(error){fail(error);}
    };
    shared?.addEventListener('sharedbufferreceived',receive);
    const observer=new ResizeObserver(fit);if(canvas.parentElement)observer.observe(canvas.parentElement);
    window.addEventListener('resize',fit);
    const originals=new Map<string,PropertyDescriptor|undefined>();
    const define=(name:string,descriptor:PropertyDescriptor)=>{originals.set(name,Object.getOwnPropertyDescriptor(video,name));Object.defineProperty(video,name,{...descriptor,configurable:true});};
    define('duration',{get:()=>state.duration});define('paused',{get:()=>state.paused});define('ended',{get:()=>state.ended});
    define('currentTime',{get:()=>state.position,set:(value:number)=>{if(Number.isFinite(value)&&value>=0)seek(value);}});
    define('volume',{get:()=>desired.volume,set:(value:number)=>{desired.volume=value;control('volume',value);}});
    define('muted',{get:()=>desired.muted,set:(value:boolean)=>{desired.muted=value;control('mute',value?1:0);}});
    define('playbackRate',{get:()=>desired.rate,set:(value:number)=>{desired.rate=value;control('rate',value);}});
    define('buffered',{get:()=>({length:state.duration>0?1:0,start:()=>0,end:()=>Math.min(state.duration,state.position+state.cacheSeconds)})});
    define('play',{value:()=>{state.paused=false;state.ended=false;control('play');event('play');return Promise.resolve();}});
    define('pause',{value:()=>{state.paused=true;control('pause');event('pause');}});
    define('load',{value:()=>{control('seek',state.position);control(state.paused?'pause':'play');}});
    let stalled=0,waiting=false,heardFrom=-1,frames=0,firstFrameAt=0,pausedMs=0,lastPollAt=0;
    const poll=async()=>{
      if(disposed||!id)return;
      try{
        const next=await invoke<Snapshot>('native_player_status',{id});if(disposed||gaveUp)return;
        const previous=state,moved=next.position!==reported;
        reported=next.position;frames=next.frames??frames;
        if(Date.now()<holdUntil){
          // Until the decoder is nearer the place asked for than where it was, the clock stays on the request.
          if(seekWanted===null&&Math.abs(next.position-holdTarget)<Math.abs(next.position-holdFrom))holdUntil=0;
          else next.position=holdTarget;
        }
        state=next;
        if(next.error){
          if(yuv&&!drawn&&canFallBack){fallBack('el decodificador no pudo abrir el vídeo');return;}
          notify('problem',next.error);event('error');return;
        }
        if(!drawn&&yuv&&canFallBack&&moved&&!next.paused){
          if(heardFrom<0)heardFrom=next.position;
          else if(next.position-heardFrom>=NO_PICTURE_SECONDS){fallBack('hay sonido pero no llega imagen');return;}
        }
        if(next.loaded&&next.hasVideo&&drawn&&!metadata){metadata=true;event('loadedmetadata');event('canplay');}
        if(metadata){
          event('timeupdate');event('progress');
          if(next.paused!==previous.paused)event(next.paused?'pause':'play');
          if(next.paused||next.ended||moved)stalled=0;else stalled++;
          // Time spent paused is left out of the frame rate in the log.
          const now=Date.now();
          if(previous.paused&&lastPollAt)pausedMs+=now-lastPollAt;
          lastPollAt=now;
          const wasWaiting=waiting;waiting=next.buffering||stalled>=STALL_POLLS;
          if(waiting)event('waiting');
          else if(next.paused){if(wasWaiting)event('canplay');}
          else if(!started||wasWaiting){started=true;event('playing');}
          if(next.ended&&!previous.ended)event('ended');
        }
        timer=window.setTimeout(()=>void poll(),POLL_MS);
      }catch(error){fail(error);}
    };
    raf=window.requestAnimationFrame(draw);
    void serialize(async()=>{
      if(disposed)return;
      try{
        if(!shared||(!context&&!renderer))throw Error('Shared video canvas unavailable');
        id=await invoke<string>('open_native_player',{url,requestId,fast:yuv});
        if(disposed){await invoke('close_native_player',{id});id=null;return;}
        for(const request of pending.splice(0))control(request.action,request.value);
        await commands;void poll();
      }catch(error){fail(error);}
    });
    return()=>{
      if(drawn){
        const seconds=Math.max(0,Date.now()-firstFrameAt-pausedMs)/1000;
        notify('closed',`${frames} fotogramas, ${Math.round(seconds)} s reproduciendo${seconds>=5?` (${(frames/seconds).toFixed(1)} por segundo)`:''}, ${yuv?'rápido':'compatible'}`);
      }
      disposed=true;window.clearTimeout(timer);window.clearTimeout(seekTimer);window.cancelAnimationFrame(raf);observer.disconnect();window.removeEventListener('resize',fit);
      shared?.removeEventListener('sharedbufferreceived',receive);
      if(buffer){shared?.releaseBuffer(buffer);buffer=null;}
      renderer?.dispose();
      void serialize(async()=>{await commands;if(id){await invoke('close_native_player',{id});id=null;}});
      for(const [name,original]of originals){if(original)Object.defineProperty(video,name,original);else delete(video as unknown as Record<string,unknown>)[name];}
    };
  },[enabled,url,safe]);
}
