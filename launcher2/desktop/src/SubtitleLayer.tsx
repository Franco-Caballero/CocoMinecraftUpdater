import {useEffect,useLayoutEffect,useRef,useState,type CSSProperties} from 'react';
import {Check,LoaderCircle,MoveVertical,RefreshCw,RotateCcw} from 'lucide-react';
import {activeCues,clampOffset,clampScale,trackDetail,SUBTITLE_PRESETS,SUBTITLE_SCALE,type Cue,type CueLook,type SubtitlePreset,type SubtitlePrefs,type SubtitleTrack} from './subtitles';

/** Text height of a dialogue line, as a share of the picture height, at the «Mediano» size. */
const LINE_SHARE=.054;
/** Space the controls take at the bottom of the window while they are visible. */
const CONTROLS_PX=122;
/** Where the bottom lines sit: a share of the picture plus a fixed lift, matching `.coco-sub-group.is-bottom`. */
const BOTTOM_SHARE=.055,BOTTOM_PX=30;

type Box={left:number;top:number;width:number;height:number;frameHeight:number};

const sameBox=(a:Box|null,b:Box|null)=>!!a&&!!b&&a.left===b.left&&a.top===b.top&&a.width===b.width&&a.height===b.height&&a.frameHeight===b.frameHeight;

/** Where the picture really is inside the player: the canvas is fitted, a video letterboxes itself. */
function measure(target:HTMLElement|null):Box|null{
  const frame=target?.parentElement;
  if(!target||!frame)return null;
  const outer=frame.getBoundingClientRect(),inner=target.getBoundingClientRect();
  let {left,top,width,height}={left:inner.left-outer.left,top:inner.top-outer.top,width:inner.width,height:inner.height};
  if(target instanceof HTMLVideoElement&&target.videoWidth&&target.videoHeight){
    const scale=Math.min(width/target.videoWidth,height/target.videoHeight);
    const w=target.videoWidth*scale,h=target.videoHeight*scale;
    left+=(width-w)/2;top+=(height-h)/2;width=w;height=h;
  }
  if(width<20||height<20)return null;
  return {left:Math.round(left),top:Math.round(top),width:Math.round(width),height:Math.round(height),frameHeight:Math.round(outer.height)};
}

const outline=(color:string,px:number)=>{
  const d=`${px.toFixed(2)}px`;
  return `${d} 0 0 ${color},-${d} 0 0 ${color},0 ${d} 0 ${color},0 -${d} 0 ${color},${d} ${d} 0 ${color},-${d} ${d} 0 ${color},${d} -${d} 0 ${color},-${d} -${d} 0 ${color},0 0 ${(px*2.4).toFixed(1)}px ${color}`;
};

/** The file's own look, for the «Original» style and for on-screen signs. */
function lookStyle(look:CueLook,height:number,scale:number,fallbackPx:number):CSSProperties{
  const px=look.size?look.size*height*scale:fallbackPx;
  return {fontSize:`${px.toFixed(1)}px`,color:look.color,fontFamily:look.font?`"${look.font}",var(--body)`:undefined,
    textShadow:outline(look.outline??'#000',Math.max(1,px*.065))};
}

function CueLines({cue}:{cue:Cue}){
  return <>{cue.lines.map((line,index)=><span key={index} className="coco-sub-line"><span className="coco-sub-text">
    {line.map((span,at)=><span key={at} className={`${span.italic?'is-italic':''}${span.bold?' is-bold':''}`||undefined}>{span.text}</span>)}
  </span></span>)}</>;
}

const horizontal=(align:number)=>align%3===1?'left':align%3===0?'right':'center';

/** Subtitles drawn over the picture, in sync with the player clock. `lifted` moves the bottom
 * lines above the controls while they are visible, like the controls themselves move. The bottom
 * lines can be dragged up or down by hand (`offset`); a double click puts them back. */
export function SubtitleOverlay({cues,clock,target,preset,scale,lifted,offset,onMove}:{cues:readonly Cue[];clock:()=>number;
  target:()=>HTMLElement|null;preset:SubtitlePreset;scale:number;lifted:boolean;offset:number;onMove:(offset:number)=>void}){
  const [shown,setShown]=useState<number[]>([]);
  const [box,setBox]=useState<Box|null>(null);
  const [dragging,setDragging]=useState<number|null>(null);
  const dragFrom=useRef<{y:number;offset:number;moved:boolean}|null>(null);
  const clockRef=useRef(clock);clockRef.current=clock;
  const targetRef=useRef(target);targetRef.current=target;
  useEffect(()=>{
    let raf=0,key='';
    const tick=()=>{
      const indexes=activeCues(cues,clockRef.current());
      const next=indexes.join(',');
      if(next!==key){key=next;setShown(indexes);}
      raf=requestAnimationFrame(tick);
    };
    raf=requestAnimationFrame(tick);
    return()=>cancelAnimationFrame(raf);
  },[cues]);
  useLayoutEffect(()=>{
    let raf=0;
    const update=()=>{cancelAnimationFrame(raf);raf=requestAnimationFrame(()=>{const next=measure(targetRef.current());setBox(old=>sameBox(old,next)?old:next);});};
    update();
    const element=targetRef.current();
    const observer=new ResizeObserver(update);
    if(element){observer.observe(element);if(element.parentElement)observer.observe(element.parentElement);}
    window.addEventListener('resize',update);
    // The canvas only gets its size once the first picture arrives.
    const poll=window.setInterval(update,500);
    return()=>{cancelAnimationFrame(raf);observer.disconnect();window.removeEventListener('resize',update);window.clearInterval(poll);};
  },[]);
  if(!box||!shown.length)return null;
  const linePx=box.height*LINE_SHARE*scale;
  const bottomGap=box.frameHeight-(box.top+box.height);
  const placed=dragging??offset;
  // Only as much lift as it takes to clear the controls from where the viewer put the lines.
  const clearance=bottomGap+box.height*BOTTOM_SHARE+BOTTOM_PX-placed*box.height;
  const lift=lifted?Math.max(0,CONTROLS_PX-clearance):0;
  const shift=placed*box.height-lift;
  const grab=(event:React.PointerEvent<HTMLDivElement>)=>{
    if(event.button!==0)return;
    event.stopPropagation();event.currentTarget.setPointerCapture(event.pointerId);
    dragFrom.current={y:event.clientY,offset:placed,moved:false};setDragging(placed);
  };
  const drag=(event:React.PointerEvent<HTMLDivElement>)=>{
    const from=dragFrom.current;if(!from)return;
    if(Math.abs(event.clientY-from.y)>2)from.moved=true;
    setDragging(clampOffset(from.offset+(event.clientY-from.y)/box.height));
  };
  const drop=(event:React.PointerEvent<HTMLDivElement>)=>{
    const from=dragFrom.current;if(!from)return;
    event.stopPropagation();dragFrom.current=null;
    const next=clampOffset(from.offset+(event.clientY-from.y)/box.height);
    setDragging(null);if(from.moved)onMove(next);
  };
  const original=preset==='original';
  const groups:Record<'top'|'middle'|'bottom',Cue[]>={top:[],middle:[],bottom:[]};
  const signs:Cue[]=[];
  for(const index of shown){
    const cue=cues[index];
    if(cue.sign&&cue.pos)signs.push(cue);
    else groups[cue.align>=7?'top':cue.align>=4?'middle':'bottom'].push(cue);
  }
  return <div className={`coco-subs coco-subs-look-${preset}`} aria-hidden="true"
    style={{left:box.left,top:box.top,width:box.width,height:box.height,['--sub-px' as string]:`${linePx.toFixed(1)}px`,['--sub-lift' as string]:`${shift.toFixed(1)}px`} as CSSProperties}>
    {(['top','middle','bottom'] as const).map(place=>groups[place].length>0&&<div key={place} className={`coco-sub-group is-${place}${place==='bottom'&&dragging!==null?' is-dragging':''}`}
      {...(place==='bottom'?{onPointerDown:grab,onPointerMove:drag,onPointerUp:drop,onPointerCancel:drop,
        onClick:(event:React.MouseEvent)=>event.stopPropagation(),
        onDoubleClick:(event:React.MouseEvent)=>{event.stopPropagation();onMove(0);}}:{})}>
      {place==='bottom'&&<span className="coco-sub-handle"><MoveVertical size={13}/>{placed!==0?'Arrastra · doble clic para volver':'Arrastra para mover'}</span>}
      {(place==='bottom'?[...groups[place]].reverse():groups[place]).map((cue,index)=><p key={`${cue.start}-${index}`} className={`coco-sub-cue is-${horizontal(cue.align)}`}
        style={original?lookStyle(cue.look,box.height,scale,linePx):undefined}><CueLines cue={cue}/></p>)}
    </div>)}
    {signs.map((cue,index)=>{
      const x=cue.align%3===1?'0%':cue.align%3===0?'-100%':'-50%',y=cue.align>=7?'0%':cue.align>=4?'-50%':'-100%';
      return <p key={`sign-${cue.start}-${index}`} className="coco-sub-sign"
        style={{left:`${cue.pos!.x*100}%`,top:`${cue.pos!.y*100}%`,translate:`${x} ${y}`,
          ...lookStyle(original?cue.look:{size:cue.look.size,outline:'#000'},box.height,Math.min(scale,1.1),linePx*.8)}}><CueLines cue={cue}/></p>;
    })}
  </div>;
}

type PanelProps={tracks:readonly SubtitleTrack[];chosen:string|null;status:'idle'|'loading'|'error';prefs:SubtitlePrefs;
  sample?:CueLook;onChoose:(track:SubtitleTrack|null)=>void;onPrefs:(prefs:SubtitlePrefs)=>void;onRetry:()=>void;onClose:()=>void};

/** The subtitle menu: which track, how it looks and how big. Every choice applies at once. */
export function SubtitlePanel({tracks,chosen,status,prefs,sample,onChoose,onPrefs,onRetry,onClose}:PanelProps){
  const panel=useRef<HTMLDivElement>(null);
  useEffect(()=>{
    // The menu takes the keyboard without lighting a focus ring on a mouse click; Tab goes to the tracks.
    panel.current?.focus({preventScroll:true});
    const outside=(event:PointerEvent)=>{
      const target=event.target as Node|null;
      if(target&&(panel.current?.contains(target)||(target as Element).closest?.('.coco-player-subs-toggle')))return;
      onClose();
    };
    document.addEventListener('pointerdown',outside,true);
    return()=>document.removeEventListener('pointerdown',outside,true);
  },[]);
  const row=(track:SubtitleTrack|null)=>{
    const checked=(track?.id??null)===chosen;
    const detail=track?trackDetail(track):'';
    return <button key={track?.id??'off'} role="menuitemradio" aria-checked={checked} className={`coco-subs-track${checked?' is-on':''}`}
      onClick={()=>onChoose(track)}>
      <i className="coco-subs-radio" aria-hidden="true">{checked&&<Check size={12} strokeWidth={3}/>}</i>
      <span className="coco-subs-track-copy"><strong>{track?track.label:'Desactivados'}</strong>
        {detail&&<small>{detail}</small>}</span>
      {checked&&track&&status==='loading'&&<LoaderCircle className="spin" size={15} aria-label="Cargando"/>}
    </button>;
  };
  return <div ref={panel} className="coco-player-subs" role="menu" aria-label="Subtítulos" tabIndex={-1} onKeyDown={event=>{
    if(event.key==='Escape'){event.preventDefault();event.stopPropagation();onClose();}
  }}>
    <span className="coco-player-eyebrow">Subtítulos</span>
    <section className="coco-subs-section" aria-label="Pista">
      <h3>Pista</h3>
      <div className="coco-subs-tracks">{row(null)}{tracks.map(row)}</div>
      {status==='error'&&chosen&&<p className="coco-subs-problem">No se pudieron cargar.<button onClick={onRetry}><RefreshCw size={13}/> Reintentar</button></p>}
    </section>
    <section className="coco-subs-section" aria-label="Estilo">
      <h3>Estilo</h3>
      <div className="coco-subs-presets">{SUBTITLE_PRESETS.map(preset=>{
        const on=prefs.preset===preset.id;
        return <button key={preset.id} aria-pressed={on} className={`coco-subs-preset${on?' is-on':''}`} title={preset.hint}
          onClick={()=>onPrefs({...prefs,preset:preset.id})}>
          <span className={`coco-subs-sample coco-subs-look-${preset.id}`} aria-hidden="true">
            <span className="coco-sub-text" style={preset.id==='original'&&sample?{color:sample.color,fontFamily:sample.font?`"${sample.font}",var(--body)`:undefined,textShadow:outline(sample.outline??'#000',1.4)}:undefined}>Aa</span>
          </span>
          <span className="coco-subs-preset-copy"><strong>{preset.label}</strong><small>{preset.hint}</small></span>
        </button>;
      })}</div>
    </section>
    {prefs.offset!==0&&<button className="coco-subs-reset" onClick={()=>onPrefs({...prefs,offset:0})}>
      <RotateCcw size={13}/> Subtítulos en su lugar original</button>}
    <section className="coco-subs-section" aria-label="Tamaño">
      <h3>Tamaño <b>{Math.round(prefs.scale*100)} %</b></h3>
      {/* Applies while dragging; a double click goes back to the usual size. */}
      <div className="coco-subs-size" onDoubleClick={()=>onPrefs({...prefs,scale:1})}>
        <span className="is-small" aria-hidden="true">A</span>
        <input type="range" min={SUBTITLE_SCALE.min} max={SUBTITLE_SCALE.max} step={SUBTITLE_SCALE.step} value={prefs.scale}
          aria-label="Tamaño de los subtítulos" aria-valuetext={`${Math.round(prefs.scale*100)} %`}
          style={{['--level' as string]:`${(prefs.scale-SUBTITLE_SCALE.min)/(SUBTITLE_SCALE.max-SUBTITLE_SCALE.min)*100}%`}}
          onChange={event=>onPrefs({...prefs,scale:clampScale(Number(event.currentTarget.value))})}/>
        <span className="is-large" aria-hidden="true">A</span>
      </div>
    </section>
  </div>;
}
