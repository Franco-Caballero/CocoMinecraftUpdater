import React from 'react';
import {ChevronLeft,ChevronRight} from 'lucide-react';

/** How long each screenshot stays. The active dot fills over this time and its animation's end is
 * what advances, so hovering, focus or a hidden window pause it for free, and with reduced motion
 * there is no animation and so no autoplay. */
const SHOW_MS=2600;

type Direction='next'|'prev';

export function ScreenshotGallery({shots,name}:{shots:string[];name:string}){
  const [failed,setFailed]=React.useState<ReadonlySet<string>>(()=>new Set());
  const [ready,setReady]=React.useState<ReadonlySet<string>>(()=>new Set());
  const usable=React.useMemo(()=>shots.filter(shot=>!failed.has(shot)),[shots,failed]);
  const count=usable.length;
  const [index,setIndex]=React.useState(0);
  // The slide we came from stays painted underneath, and only starts leaving once the new one has
  // loaded, so a slow image never shows an empty frame.
  const [from,setFrom]=React.useState<number|null>(null);
  const [direction,setDirection]=React.useState<Direction>('next');
  const [held,setHeld]=React.useState(false);
  React.useEffect(()=>{setIndex(0);setFrom(null);},[shots]);
  const current=count?index%count:0;
  const go=React.useCallback((target:number,toward:Direction)=>{
    if(count<2)return;
    setFrom(current);
    setDirection(toward);
    setIndex((target+count)%count);
  },[count,current]);
  if(!count)return null;
  const mounted=new Set([current,(current+1)%count,(current-1+count)%count]);
  if(from!==null&&from<count&&from!==current)mounted.add(from);
  const currentReady=ready.has(usable[current]);
  return <section className="drawer-gallery" aria-roledescription="carrusel" aria-label={`Capturas de ${name}`}>
    <div className={`gallery-frame is-${direction} ${held?'is-held':''}`} tabIndex={0}
      onPointerEnter={()=>setHeld(true)} onPointerLeave={()=>setHeld(false)}
      onKeyDown={event=>{
        if(event.key==='ArrowLeft'){event.preventDefault();go(current-1,'prev');}
        else if(event.key==='ArrowRight'){event.preventDefault();go(current+1,'next');}
      }}>
      {[...mounted].map(slide=>{
        const shot=usable[slide];
        const role=slide===current?'is-current':slide===from?(currentReady?'is-leaving':'is-behind'):'';
        return <img key={shot} src={shot} alt={slide===current?`Captura ${current+1} de ${count} de ${name}`:''} draggable={false}
          decoding="async" className={`gallery-slide ${role} ${ready.has(shot)?'is-ready':''}`}
          onLoad={()=>setReady(previous=>new Set(previous).add(shot))}
          onError={()=>setFailed(previous=>new Set(previous).add(shot))}/>;
      })}
      {from!==null&&currentReady&&<span key={`sweep-${current}`} className="gallery-sweep" aria-hidden="true"/>}
      {count>1&&<>
        <button type="button" className="gallery-nav is-prev" aria-label="Captura anterior" onClick={()=>go(current-1,'prev')}><span><ChevronLeft size={22}/></span></button>
        <button type="button" className="gallery-nav is-next" aria-label="Captura siguiente" onClick={()=>go(current+1,'next')}><span><ChevronRight size={22}/></span></button>
        <div className="gallery-dots">{usable.map((shot,slide)=><button type="button" key={shot} aria-label={`Ver captura ${slide+1}`}
          aria-current={slide===current||undefined} className={slide===current?'is-active':''} onClick={()=>slide!==current&&go(slide,slide>current?'next':'prev')}>
          {slide===current&&<i key={`${current}-${currentReady}`} className={currentReady?'is-running':''}
            style={{animationDuration:`${SHOW_MS}ms`}} onAnimationEnd={()=>go(current+1,'next')}/>}
        </button>)}</div>
        <span className="gallery-count" aria-hidden="true">{current+1} / {count}</span>
      </>}
    </div>
  </section>;
}
