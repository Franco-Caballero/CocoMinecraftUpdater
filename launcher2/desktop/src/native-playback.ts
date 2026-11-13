import {useLayoutEffect,type RefObject} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {paintSharedFrame,fitVideoSize,type FrameImage} from './native-video-frame';

type Snapshot={position:number;duration:number;paused:boolean;volume:number;muted:boolean;rate:number;
  buffering:boolean;ended:boolean;loaded:boolean;hasVideo:boolean;cacheSeconds:number;error:string|null};
type SharedEvent={additionalData:{kind?:string;requestId?:string;id?:string;headerBytes:number;slotBytes:number;byteLength:number};getBuffer:()=>ArrayBuffer};
type SharedView={addEventListener:(name:string,listener:(event:SharedEvent)=>void)=>void;
  removeEventListener:(name:string,listener:(event:SharedEvent)=>void)=>void;releaseBuffer:(buffer:ArrayBuffer)=>void};
let lifecycle:Promise<unknown>=Promise.resolve();
const serialize=(task:()=>Promise<void>)=>{lifecycle=lifecycle.catch(()=>{}).then(task);return lifecycle;};

/** Decoder frames and controls share the WebView compositor. The hidden video
 * is just the existing controls' event adapter; no movie bytes enter its decoder. */
export function useNativePlayback(enabled:boolean,url:string,videoRef:RefObject<HTMLVideoElement|null>,canvasRef:RefObject<HTMLCanvasElement|null>){
  useLayoutEffect(()=>{
    if(!enabled)return;
    const video=videoRef.current,canvas=canvasRef.current;if(!video||!canvas)return;
    let disposed=false,id:string|null=null,timer=0,raf=0,metadata=false,started=false,drawn=false;
    let buffer:ArrayBuffer|null=null,image:FrameImage|null=null,lastSequence=0;
    const requestId=crypto.randomUUID();
    const shared=(window as unknown as {chrome?:{webview?:SharedView}}).chrome?.webview;
    const context=canvas.getContext('2d',{alpha:false,desynchronized:true});
    let state:Snapshot={position:0,duration:NaN,paused:true,volume:1,muted:false,rate:1,buffering:false,ended:false,loaded:false,hasVideo:false,cacheSeconds:0,error:null};
    const desired={volume:1,muted:false,rate:1};
    const pending:Array<{action:string;value?:number}>=[];
    let commands:Promise<unknown>=Promise.resolve();
    const event=(name:string)=>{if(!disposed)video.dispatchEvent(new Event(name));};
    const fail=(error:unknown)=>{if(!disposed){console.warn('Coco decoder:',error);event('error');}};
    const control=(action:string,value?:number)=>{
      if(disposed)return;
      if(!id){pending.push({action,value});return;}
      commands=commands.catch(()=>{}).then(async()=>{if(!disposed&&id)await invoke('control_native_player',{id,action,value:value??null});}).catch(fail);
    };
    const fit=()=>{
      if(!canvas.width||!canvas.height)return;
      const parent=canvas.parentElement;
      const size=fitVideoSize(canvas.width,canvas.height,parent?.clientWidth??window.innerWidth,parent?.clientHeight??window.innerHeight);
      canvas.style.width=`${size.width}px`;canvas.style.height=`${size.height}px`;
    };
    const draw=()=>{
      if(disposed)return;
      try{
        if(buffer&&context){
          const frame=paintSharedFrame(buffer,lastSequence,image);
          if(frame){
            image=frame.image;
            if(canvas.width!==image.width||canvas.height!==image.height){canvas.width=image.width;canvas.height=image.height;fit();}
            context.putImageData(image,0,0);lastSequence=frame.sequence;drawn=true;
          }
        }
      }catch(error){fail(error);}
      raf=window.requestAnimationFrame(draw);
    };
    const receive=(message:SharedEvent)=>{
      if(disposed||message.additionalData?.kind!=='coco-video-rgba-v1'||message.additionalData.requestId!==requestId)return;
      try{
        const next=message.getBuffer();
        if(next.byteLength!==64+2*1920*1080*4){shared?.releaseBuffer(next);throw Error('Invalid video buffer size');}
        if(buffer)shared?.releaseBuffer(buffer);buffer=next;lastSequence=0;
      }catch(error){fail(error);}
    };
    shared?.addEventListener('sharedbufferreceived',receive);
    const observer=new ResizeObserver(fit);if(canvas.parentElement)observer.observe(canvas.parentElement);
    window.addEventListener('resize',fit);
    const originals=new Map<string,PropertyDescriptor|undefined>();
    const define=(name:string,descriptor:PropertyDescriptor)=>{originals.set(name,Object.getOwnPropertyDescriptor(video,name));Object.defineProperty(video,name,{...descriptor,configurable:true});};
    define('duration',{get:()=>state.duration});define('paused',{get:()=>state.paused});define('ended',{get:()=>state.ended});
    define('currentTime',{get:()=>state.position,set:(value:number)=>{if(Number.isFinite(value)&&value>=0){state.position=value;state.ended=false;control('seek',value);}}});
    define('volume',{get:()=>desired.volume,set:(value:number)=>{desired.volume=value;control('volume',value);}});
    define('muted',{get:()=>desired.muted,set:(value:boolean)=>{desired.muted=value;control('mute',value?1:0);}});
    define('playbackRate',{get:()=>desired.rate,set:(value:number)=>{desired.rate=value;control('rate',value);}});
    define('buffered',{get:()=>({length:state.duration>0?1:0,start:()=>0,end:()=>Math.min(state.duration,state.position+state.cacheSeconds)})});
    define('play',{value:()=>{state.paused=false;state.ended=false;control('play');event('play');return Promise.resolve();}});
    define('pause',{value:()=>{state.paused=true;control('pause');event('pause');}});
    define('load',{value:()=>{control('seek',state.position);control(state.paused?'pause':'play');}});
    const poll=async()=>{
      if(disposed||!id)return;
      try{
        const next=await invoke<Snapshot>('native_player_status',{id});if(disposed)return;
        const previous=state;state=next;
        if(next.error){event('error');return;}
        if(next.loaded&&next.hasVideo&&drawn&&!metadata){metadata=true;event('loadedmetadata');event('canplay');}
        if(metadata){
          event('timeupdate');event('progress');
          if(next.paused!==previous.paused)event(next.paused?'pause':'play');
          if(next.buffering)event('waiting');else if(!next.paused&&(!started||previous.buffering)){started=true;event('playing');}
          if(next.ended&&!previous.ended)event('ended');
        }
        timer=window.setTimeout(()=>void poll(),250);
      }catch(error){fail(error);}
    };
    raf=window.requestAnimationFrame(draw);
    void serialize(async()=>{
      if(disposed)return;
      try{
        if(!shared||!context)throw Error('Shared video canvas unavailable');
        id=await invoke<string>('open_native_player',{url,requestId});
        if(disposed){await invoke('close_native_player',{id});id=null;return;}
        for(const request of pending.splice(0))control(request.action,request.value);
        await commands;void poll();
      }catch(error){fail(error);}
    });
    return()=>{
      disposed=true;window.clearTimeout(timer);window.cancelAnimationFrame(raf);observer.disconnect();window.removeEventListener('resize',fit);
      shared?.removeEventListener('sharedbufferreceived',receive);
      if(buffer){shared?.releaseBuffer(buffer);buffer=null;}
      void serialize(async()=>{await commands;if(id){await invoke('close_native_player',{id});id=null;}});
      for(const [name,original]of originals){if(original)Object.defineProperty(video,name,original);else delete(video as unknown as Record<string,unknown>)[name];}
    };
  },[enabled,url]);
}
