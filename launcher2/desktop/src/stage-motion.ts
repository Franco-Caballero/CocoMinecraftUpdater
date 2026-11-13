/** Pointer-driven polish: cards lean toward the pointer and Reyna drifts against it.
 * Everything runs through CSS variables once per frame, so no React render happens
 * and a compositor-only transform is the only cost. */
const MAX_TILT_DEGREES=12.65;

export function tiltFor(x:number,y:number,width:number,height:number){
  const nx=Math.max(0,Math.min(1,width?x/width:.5));
  const ny=Math.max(0,Math.min(1,height?y/height:.5));
  return {
    rotateX:(.5-ny)*MAX_TILT_DEGREES*2,
    rotateY:(nx-.5)*MAX_TILT_DEGREES*2,
    glareX:nx*100,
    glareY:ny*100,
  };
}

/** Delegated, so a grid of any size costs one listener. */
export function attachCardTilt(root:HTMLElement){
  let card:HTMLElement|null=null;
  let event:PointerEvent|null=null;
  let frame=0;
  const clear=()=>{
    if(!card)return;
    for(const name of ['--tilt-x','--tilt-y','--glare-x','--glare-y'])card.style.removeProperty(name);
    card=null;
  };
  const paint=()=>{
    frame=0;
    if(!event)return;
    const target=(event.target as Element|null)?.closest<HTMLElement>('.experience-card')??null;
    if(target!==card)clear();
    card=target;
    if(!card)return;
    const box=card.getBoundingClientRect();
    const tilt=tiltFor(event.clientX-box.left,event.clientY-box.top,box.width,box.height);
    card.style.setProperty('--tilt-x',`${tilt.rotateX.toFixed(2)}deg`);
    card.style.setProperty('--tilt-y',`${tilt.rotateY.toFixed(2)}deg`);
    card.style.setProperty('--glare-x',`${tilt.glareX.toFixed(0)}%`);
    card.style.setProperty('--glare-y',`${tilt.glareY.toFixed(0)}%`);
  };
  const move=(next:PointerEvent)=>{event=next;if(!frame)frame=requestAnimationFrame(paint);};
  const leave=()=>{event=null;clear();};
  root.addEventListener('pointermove',move,{passive:true});
  root.addEventListener('pointerleave',leave);
  return ()=>{
    cancelAnimationFrame(frame);
    root.removeEventListener('pointermove',move);
    root.removeEventListener('pointerleave',leave);
    clear();
  };
}

export function attachStageParallax(stage:HTMLElement){
  let frame=0;
  let x=0,y=0;
  const paint=()=>{
    frame=0;
    stage.style.setProperty('--drift-x',x.toFixed(3));
    stage.style.setProperty('--drift-y',y.toFixed(3));
  };
  const move=(event:PointerEvent)=>{
    x=event.clientX/Math.max(1,window.innerWidth)-.5;
    y=event.clientY/Math.max(1,window.innerHeight)-.5;
    if(!frame)frame=requestAnimationFrame(paint);
  };
  window.addEventListener('pointermove',move,{passive:true});
  return ()=>{cancelAnimationFrame(frame);window.removeEventListener('pointermove',move);};
}
