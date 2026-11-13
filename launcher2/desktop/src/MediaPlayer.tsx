import {useEffect,useRef,useState,type KeyboardEvent,type PointerEvent as ReactPointerEvent,type SyntheticEvent} from 'react';
import {AlertCircle,ArrowLeft,Keyboard,Maximize,Minimize,Pause,Play,RefreshCw,RotateCcw,RotateCw,SkipForward,Volume1,Volume2,VolumeX} from 'lucide-react';
import {isTauri} from '@tauri-apps/api/core';
import {getCurrentWindow} from '@tauri-apps/api/window';
import {nextPlaybackRate,resumeMediaPosition,seekRelative,shouldHandlePlaybackKey,stepVolume} from './media-playback-controls';
import {formatClock,saveProgress} from './media-progress';
import {useNativePlayback} from './native-playback';

type Props={title:string;url:string;mimeType:string;onClose:()=>void;onReopen?:()=>Promise<boolean>;
  /** The show or «Película»: the line above the title. */
  subtitle?:string;
  /** Where the viewer left it last time; consumed once, on the first metadata. */
  startAt?:number|null;
  /** Saves where the viewer is, so the detail view can offer to continue. */
  progress?:{id:string;episodeId:string};
  next?:{title:string;play:()=>void};};
type State='loading'|'ready'|'buffering'|'error'|'blocked';
type Flash={icon:'play'|'pause'|'back'|'forward'|'mute'|'volume';label?:string;key:number};

const IDLE_MS=2600;
const CLOSE_MS=230;
const UP_NEXT_SECONDS=8;
const SAVE_EVERY_MS=4000;
const VOLUME_KEY='coco2.player-volume.v1';

/** Coco's controls work with the bundled native decoder on Windows and an
 * HTML video in browser previews. Native media never enters WebView2's decoder. */
export default function MediaPlayer({title,url,onClose,onReopen,subtitle,startAt,progress,next}:Props){
  const videoRef=useRef<HTMLVideoElement>(null);
  const canvasRef=useRef<HTMLCanvasElement>(null);
  const native=isTauri();
  const dialogRef=useRef<HTMLDivElement>(null);
  const scrubRef=useRef<HTMLDivElement>(null);
  const playEpoch=useRef(0);
  const retryBusy=useRef(false);
  const retryTicket=useRef(0);
  const lastPosition=useRef(0);
  const resumeAfterRefresh=useRef<number|null>(null);
  const resumeFromUrl=useRef<string|null>(null);
  const pendingStart=useRef<number|null>(startAt??null);
  const idleTimer=useRef(0);
  const toastTimer=useRef(0);
  const upNextTimer=useRef(0);
  const overControls=useRef(false);
  const lastSaved=useRef(0);
  const flashCount=useRef(0);
  const fullscreenOn=useRef(false);
  const [retrying,setRetrying]=useState(false);
  const [state,setState]=useState<State>('loading');
  const [paused,setPaused]=useState(true);
  const [current,setCurrent]=useState(0);
  const [duration,setDuration]=useState(0);
  const [buffered,setBuffered]=useState(0);
  const [volume,setVolume]=useState(1);
  const [muted,setMuted]=useState(false);
  const [rate,setRate]=useState(1);
  const [fullscreen,setFullscreen]=useState(false);
  const [idle,setIdle]=useState(false);
  const [scrub,setScrub]=useState<{fraction:number;dragging:boolean}|null>(null);
  const [flash,setFlash]=useState<Flash|null>(null);
  const [resumedFrom,setResumedFrom]=useState<number|null>(null);
  const [upNext,setUpNext]=useState<number|null>(null);
  const [ended,setEnded]=useState(false);
  const [help,setHelp]=useState(false);
  const [closing,setClosing]=useState(false);
  useNativePlayback(native,url,videoRef,canvasRef);
  const videoEvent=(event:SyntheticEvent<HTMLVideoElement>,next:State)=>{
    // A revoked Range token may dispatch a late waiting/error/playing event
    // after a new key={url} video has mounted. Such events belong only to the
    // detached node, not to the fresh player state.
    if(event.currentTarget!==videoRef.current)return;
    setState(next);
  };

  useEffect(()=>{
    const video=videoRef.current;
    if(!video)return;
    // A new Range token owns a fresh player. An old native reopen may remain
    // unresolved indefinitely; neither its result nor its retry lock belongs
    // to this URL, including after React reuses the modal component.
    retryTicket.current++;
    retryBusy.current=false;
    setRetrying(false);
    const epoch=++playEpoch.current;
    setState('loading');
    dialogRef.current?.focus();
    // Activation can be lost while the Tauri bridge prepares a fresh Range
    // token. A big play button takes over if autoplay is blocked.
    void video.play().catch(()=>{
      if(playEpoch.current===epoch)setState(previous=>previous==='error'?previous:'blocked');
    });
    return()=>{
      playEpoch.current++;
      video.pause();
      // React StrictMode replays effects while retaining the same DOM node.
      // Releasing src synchronously would leave the second setup without its
      // Range token. After commit, release only genuinely detached nodes.
      queueMicrotask(()=>{
        if(video.isConnected)return;
        video.removeAttribute('src');
        video.load();
      });
    };
  },[url]);

  // The viewer's volume carries over between films; timers and fullscreen never outlive the player.
  useEffect(()=>{
    try{
      const saved=JSON.parse(localStorage.getItem(VOLUME_KEY)||'null');
      if(saved&&Number.isFinite(saved.volume)){
        const level=Math.max(0,Math.min(1,saved.volume));
        setVolume(level);setMuted(Boolean(saved.muted));
        if(videoRef.current){videoRef.current.volume=level;videoRef.current.muted=Boolean(saved.muted);}
      }
    }catch{/* default volume */}
    return()=>{
      window.clearTimeout(idleTimer.current);window.clearTimeout(toastTimer.current);window.clearInterval(upNextTimer.current);
      remember();
      void leaveFullscreen();
    };
  },[]);

  const remember=(force=false)=>{
    const video=videoRef.current;
    if(!progress||!video||!Number.isFinite(video.duration))return;
    const now=Date.now();
    if(!force&&now-lastSaved.current<SAVE_EVERY_MS)return;
    lastSaved.current=now;
    saveProgress(progress.id,progress.episodeId,video.currentTime,video.duration);
  };

  const showFlash=(icon:Flash['icon'],label?:string)=>setFlash({icon,label,key:++flashCount.current});

  /** Controls and cursor fade out while a film plays untouched, and come back on any movement. */
  const wake=()=>{
    setIdle(false);
    window.clearTimeout(idleTimer.current);
    const video=videoRef.current;
    if(video&&!video.paused&&!overControls.current)idleTimer.current=window.setTimeout(()=>setIdle(true),IDLE_MS);
  };

  const togglePlay=()=>{
    const video=videoRef.current;
    if(!video)return;
    if(video.paused){
      setEnded(false);cancelUpNext();
      void video.play().catch(()=>setState('blocked'));showFlash('play');
    }else{video.pause();showFlash('pause');}
  };

  const seekBy=(seconds:number)=>{
    const video=videoRef.current;
    if(!video)return;
    const target=seekRelative(video.currentTime,video.duration,seconds);
    if(target===null)return;
    try{video.currentTime=target;}catch{/* Range unseekable */}
    setCurrent(target);setEnded(false);
    showFlash(seconds<0?'back':'forward',`${seconds>0?'+':''}${seconds} s`);
  };

  const seekTo=(seconds:number)=>{
    const video=videoRef.current;
    if(!video||!Number.isFinite(video.duration))return;
    const target=Math.max(0,Math.min(video.duration-.05,seconds));
    try{video.currentTime=target;}catch{/* Range unseekable */}
    setCurrent(target);setEnded(false);
  };

  const applyVolume=(level:number,mute:boolean)=>{
    const video=videoRef.current;
    if(video){video.volume=level;video.muted=mute;}
    setVolume(level);setMuted(mute);
    try{localStorage.setItem(VOLUME_KEY,JSON.stringify({volume:level,muted:mute}));}catch{/* not remembered */}
  };
  const toggleMute=()=>{
    const unmute=muted||volume===0;
    applyVolume(unmute&&volume===0?.6:volume,!unmute);
    showFlash(unmute?'volume':'mute',unmute?`${Math.round((volume||.6)*100)} %`:'Silencio');
  };

  const cycleRate=()=>{
    const value=nextPlaybackRate(rate);
    if(videoRef.current)videoRef.current.playbackRate=value;
    setRate(value);
  };

  // Tauri's own window fills the screen; a plain browser falls back to the element API.
  async function setScreen(on:boolean){
    try{
      if(isTauri())await getCurrentWindow().setFullscreen(on);
      else if(on)await dialogRef.current?.requestFullscreen();
      else if(document.fullscreenElement)await document.exitFullscreen();
      fullscreenOn.current=on;setFullscreen(on);
    }catch{/* stays windowed */}
  }
  async function leaveFullscreen(){if(fullscreenOn.current)await setScreen(false);}

  const cancelUpNext=()=>{window.clearInterval(upNextTimer.current);setUpNext(null);};
  const playNext=()=>{
    if(!next)return;
    cancelUpNext();remember(true);
    next.play();
  };

  const requestClose=()=>{
    if(closing)return;
    remember(true);
    setClosing(true);
    void leaveFullscreen();
    window.setTimeout(onClose,CLOSE_MS);
  };

  const retry=async()=>{
    const video=videoRef.current;
    if(!video||retryBusy.current)return;
    const ticket=++retryTicket.current;
    let epoch=playEpoch.current;
    retryBusy.current=true;setRetrying(true);
    try{
      if(onReopen){
        // The loopback access token may have expired or its upstream may be
        // down. Opening a fresh native stream is safer than calling load() on
        // the very same revoked URL and repeatedly showing a dead player.
        const position=Number.isFinite(video.currentTime)&&video.currentTime>=1
          ?video.currentTime:lastPosition.current;
        resumeAfterRefresh.current=position>=1?position:null;
        resumeFromUrl.current=url;
        if(await onReopen())return;
        if(retryTicket.current!==ticket||playEpoch.current!==epoch)return;
        resumeAfterRefresh.current=null;
        resumeFromUrl.current=null;
        setState('error');
        return;
      }
      video.pause();
      setState('loading');
      video.load();
      epoch=++playEpoch.current;
      await video.play().catch(()=>{if(playEpoch.current===epoch)setState('blocked');});
    }catch{
      if(retryTicket.current===ticket&&playEpoch.current===epoch)setState('error');
    }finally{
      if(retryTicket.current===ticket){retryBusy.current=false;setRetrying(false);}
    }
  };

  const handleKey=(event:KeyboardEvent<HTMLDivElement>)=>{
    if(event.key==='Escape'&&!event.ctrlKey&&!event.metaKey&&!event.altKey){
      event.preventDefault();event.stopPropagation();
      // Step back one layer at a time: the shortcut sheet, then fullscreen, then the player.
      if(help){setHelp(false);return;}
      if(fullscreen){void setScreen(false);return;}
      requestClose();
      return;
    }
    if(!shouldHandlePlaybackKey(event.key,event.target,event.ctrlKey||event.metaKey||event.altKey))return;
    const video=videoRef.current;
    if(!video)return;
    event.preventDefault();
    wake();
    const key=event.key.length===1?event.key.toLowerCase():event.key;
    if(key===' '||key==='k')togglePlay();
    else if(key==='ArrowRight'||key==='l')seekBy(10);
    else if(key==='ArrowLeft'||key==='j')seekBy(-10);
    else if(key==='ArrowUp'||key==='ArrowDown'){
      const level=stepVolume(muted?0:volume,key==='ArrowUp'?.1:-.1);
      applyVolume(level,level===0);showFlash(level===0?'mute':'volume',`${Math.round(level*100)} %`);
    }
    else if(key==='m')toggleMute();
    else if(key==='f')void setScreen(!fullscreen);
    else if(key==='n')playNext();
    else if(key==='?')setHelp(open=>!open);
    else if(/^[0-9]$/.test(key)&&Number.isFinite(video.duration))seekTo(video.duration*Number(key)/10);
  };

  const fractionAt=(clientX:number)=>{
    const box=scrubRef.current?.getBoundingClientRect();
    return box&&box.width?Math.max(0,Math.min(1,(clientX-box.left)/box.width)):0;
  };
  const scrubDown=(event:ReactPointerEvent<HTMLDivElement>)=>{
    event.currentTarget.setPointerCapture(event.pointerId);
    setScrub({fraction:fractionAt(event.clientX),dragging:true});
  };
  const scrubMove=(event:ReactPointerEvent<HTMLDivElement>)=>{
    setScrub(previous=>({fraction:fractionAt(event.clientX),dragging:previous?.dragging??false}));
  };
  const scrubUp=(event:ReactPointerEvent<HTMLDivElement>)=>{
    if(scrub?.dragging&&duration)seekTo(fractionAt(event.clientX)*duration);
    setScrub({fraction:fractionAt(event.clientX),dragging:false});
  };

  const shown=scrub?.dragging&&duration?scrub.fraction*duration:current;
  const played=duration?Math.min(1,shown/duration):0;
  const loading=state==='loading'||state==='buffering';
  const controlsHidden=idle&&!paused&&!help&&state==='ready';
  const VolumeIcon=muted||volume===0?VolumeX:volume<.5?Volume1:Volume2;
  const flashIcon=flash&&{play:<Play size={30} fill="currentColor"/>,pause:<Pause size={30} fill="currentColor"/>,
    back:<RotateCcw size={28}/>,forward:<RotateCw size={28}/>,mute:<VolumeX size={28}/>,volume:<Volume2 size={28}/>}[flash.icon];

  return <div className={`coco-player-shell ${native?'is-native':''} ${closing?'is-closing':''} ${controlsHidden?'is-idle':''} ${paused?'is-paused':''}`}
    role="dialog" aria-modal="true" aria-label={`Reproduciendo ${title}`} ref={dialogRef} tabIndex={-1} onKeyDown={handleKey}
    onPointerMove={wake} onPointerDown={wake} onContextMenu={event=>event.preventDefault()}>
    <div className="coco-player-frame">
      {native&&<canvas ref={canvasRef} className="coco-native-canvas" aria-label={title}
        onClick={togglePlay} onDoubleClick={()=>void setScreen(!fullscreen)}/>}
      <video ref={videoRef} key={url} src={native?undefined:url} title={title} playsInline preload="metadata" crossOrigin="anonymous"
        controlsList="nodownload noremoteplayback" disablePictureInPicture disableRemotePlayback
        onClick={togglePlay} onDoubleClick={()=>void setScreen(!fullscreen)}
        onLoadStart={event=>videoEvent(event,'loading')}
        onLoadedMetadata={event=>{
          if(event.currentTarget!==videoRef.current)return;
          const video=event.currentTarget;
          setDuration(Number.isFinite(video.duration)?video.duration:0);
          video.volume=volume;video.muted=muted;video.playbackRate=rate;
          const position=resumeAfterRefresh.current;
          // An old media node may still dispatch events while Rust prepares a
          // new token. Only a new URL may consume the pending resume position.
          if(position!==null&&resumeFromUrl.current!==url){
            resumeAfterRefresh.current=null;
            resumeFromUrl.current=null;
            const target=resumeMediaPosition(position,video.duration);
            if(target!==null)try{video.currentTime=target;}catch{/* stream does not support seeking */}
            return;
          }
          // First open: pick up where the viewer left it last time.
          const start=pendingStart.current;
          pendingStart.current=null;
          const target=start===null?null:resumeMediaPosition(start,video.duration);
          if(target!==null){
            try{video.currentTime=target;setResumedFrom(target);}catch{/* stream does not support seeking */}
            window.clearTimeout(toastTimer.current);
            toastTimer.current=window.setTimeout(()=>setResumedFrom(null),6500);
          }
        }}
        onTimeUpdate={event=>{
          if(event.currentTarget!==videoRef.current)return;
          const position=event.currentTarget.currentTime;
          if(Number.isFinite(position)&&position>=1)lastPosition.current=position;
          if(Number.isFinite(position))setCurrent(position);
          remember();
        }}
        onProgress={event=>{
          if(event.currentTarget!==videoRef.current)return;
          const video=event.currentTarget;
          for(let index=0;index<video.buffered.length;index++){
            if(video.buffered.start(index)<=video.currentTime+.5)setBuffered(video.buffered.end(index));
          }
        }}
        onCanPlay={event=>{
          if(event.currentTarget===videoRef.current)setState(previous=>previous==='error'?previous:'ready');
        }}
        onPlay={event=>{if(event.currentTarget===videoRef.current){setPaused(false);setEnded(false);wake();}}}
        onPause={event=>{if(event.currentTarget===videoRef.current){setPaused(true);setIdle(false);remember(true);}}}
        onEnded={event=>{
          if(event.currentTarget!==videoRef.current)return;
          remember(true);
          if(next){
            setUpNext(UP_NEXT_SECONDS);
            window.clearInterval(upNextTimer.current);
            upNextTimer.current=window.setInterval(()=>setUpNext(left=>{
              if(left===null)return null;
              if(left<=1){window.clearInterval(upNextTimer.current);playNext();return null;}
              return left-1;
            }),1000);
          }else setEnded(true);
        }}
        onPlaying={event=>videoEvent(event,'ready')} onWaiting={event=>videoEvent(event,'buffering')}
        onStalled={event=>videoEvent(event,'buffering')} onSeeking={event=>videoEvent(event,'buffering')}
        onError={event=>videoEvent(event,'error')} />

      {flash&&<span key={flash.key} className="coco-player-flash" aria-hidden="true">{flashIcon}{flash.label&&<small>{flash.label}</small>}</span>}
      {loading&&<div className="coco-player-state" role="status"><i className="coco-player-ring"/><span>{state==='loading'?'Preparando':'Cargando'}</span></div>}
      {state==='blocked'&&<button className="coco-player-bigplay" aria-label="Reproducir" onClick={togglePlay}><Play size={34} fill="currentColor"/></button>}
      {state==='error'&&<div className="coco-player-error" role="alert">
        <AlertCircle size={26}/><strong>No se pudo reproducir</strong>
        <span>Comprueba la conexión. Si el acceso caducó, Coco abre uno nuevo y sigue donde ibas.</span>
        <button onClick={()=>void retry()} disabled={retrying} aria-busy={retrying}><RefreshCw size={15}/>{retrying?'Restableciendo…':'Reintentar'}</button>
      </div>}
      {resumedFrom!==null&&<div className="coco-player-toast" role="status">
        <span>Continuando desde <b>{formatClock(resumedFrom)}</b></span>
        <button onClick={()=>{seekTo(0);setResumedFrom(null);}}>Desde el inicio</button>
      </div>}
      {upNext!==null&&next&&<div className="coco-player-upnext" role="status" style={{['--left' as string]:upNext/UP_NEXT_SECONDS}}>
        <span className="coco-player-eyebrow">A continuación · {upNext} s</span>
        <strong>{next.title}</strong>
        <i aria-hidden="true"/>
        <div><button className="is-primary" onClick={playNext}><SkipForward size={15}/> Ver ahora</button><button onClick={cancelUpNext}>Cancelar</button></div>
      </div>}
      {ended&&<div className="coco-player-end" role="status">
        <span className="coco-player-eyebrow">Fin</span>
        <strong>{subtitle&&subtitle!=='Película'?subtitle:title}</strong>
        <div><button className="is-primary" onClick={()=>{seekTo(0);togglePlay();}}><RotateCcw size={15}/> Volver a ver</button><button onClick={requestClose}>Cerrar</button></div>
      </div>}
      {help&&<div className="coco-player-help" role="dialog" aria-label="Atajos de teclado">
        <span className="coco-player-eyebrow">Atajos</span>
        <dl>
          <dt>Espacio · K</dt><dd>Reproducir o pausar</dd>
          <dt>← → · J L</dt><dd>10 segundos</dd>
          <dt>↑ ↓</dt><dd>Volumen</dd>
          <dt>M</dt><dd>Silenciar</dd>
          <dt>F · doble clic</dt><dd>Pantalla completa</dd>
          <dt>0 – 9</dt><dd>Saltar al 0–90 %</dd>
          {next&&<><dt>N</dt><dd>Siguiente episodio</dd></>}
          <dt>Esc</dt><dd>Salir</dd>
        </dl>
      </div>}
    </div>

    <header className="coco-player-top">
      <button className="coco-player-back" aria-label="Volver" onClick={requestClose}><ArrowLeft size={19}/></button>
      <div className="coco-player-heading">
        <strong>{title}</strong>
      </div>
    </header>

    <div className="coco-player-controls" onPointerEnter={()=>{overControls.current=true;wake();}} onPointerLeave={()=>{overControls.current=false;wake();}}>
      <div ref={scrubRef} className={`coco-player-scrub ${scrub?.dragging?'is-dragging':''}`} role="slider" tabIndex={0}
        aria-label="Posición" aria-valuemin={0} aria-valuemax={Math.round(duration)} aria-valuenow={Math.round(shown)}
        aria-valuetext={`${formatClock(shown)} de ${formatClock(duration)}`}
        onPointerDown={scrubDown} onPointerMove={scrubMove} onPointerUp={scrubUp}
        onPointerLeave={()=>setScrub(previous=>previous?.dragging?previous:null)}>
        <i className="coco-player-buffered" style={{width:`${duration?Math.min(100,buffered/duration*100):0}%`}}/>
        <i className="coco-player-played" style={{width:`${played*100}%`}}/>
        <i className="coco-player-thumb" style={{left:`${played*100}%`}}/>
        {scrub&&duration>0&&<span className="coco-player-bubble" style={{left:`${scrub.fraction*100}%`}}>{formatClock(scrub.fraction*duration)}</span>}
      </div>
      <div className="coco-player-bar">
        <button className="coco-player-play" aria-label={paused?'Reproducir':'Pausar'} onClick={togglePlay}>{paused?<Play size={20} fill="currentColor"/>:<Pause size={20} fill="currentColor"/>}</button>
        <button aria-label="Retroceder 10 segundos" title="Retroceder 10 s (←)" onClick={()=>seekBy(-10)}><RotateCcw size={18}/></button>
        <button aria-label="Avanzar 10 segundos" title="Avanzar 10 s (→)" onClick={()=>seekBy(10)}><RotateCw size={18}/></button>
        <div className="coco-player-volume">
          <button aria-label={muted?'Activar sonido':'Silenciar'} title="Silenciar (M)" onClick={toggleMute}><VolumeIcon size={19}/></button>
          <input type="range" min={0} max={1} step={.05} aria-label="Volumen" value={muted?0:volume}
            style={{['--level' as string]:`${(muted?0:volume)*100}%`}}
            onChange={event=>{const level=Number(event.currentTarget.value);applyVolume(level,level===0);}}/>
        </div>
        <span className="coco-player-time"><b>{formatClock(shown)}</b> / {formatClock(duration)}</span>
        <span className="coco-player-spacer"/>
        {next&&<button className="coco-player-next" title={`Siguiente: ${next.title} (N)`} onClick={playNext}><SkipForward size={17}/><span>Siguiente</span></button>}
        <button className="coco-player-rate" aria-label={`Velocidad ${rate}×`} title="Velocidad" onClick={cycleRate}>{rate}×</button>
        <button aria-label="Atajos de teclado" aria-pressed={help} title="Atajos (?)" onClick={()=>setHelp(open=>!open)}><Keyboard size={18}/></button>
        <button aria-label={fullscreen?'Salir de pantalla completa':'Pantalla completa'} title="Pantalla completa (F)" onClick={()=>void setScreen(!fullscreen)}>{fullscreen?<Minimize size={18}/>:<Maximize size={18}/>}</button>
      </div>
    </div>
  </div>;
}
