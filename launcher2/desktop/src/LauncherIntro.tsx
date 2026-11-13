import {useEffect,useRef} from 'react';

/** The launcher opens as solid color with a giant 2. The color is the title's own chip, enlarged
 * until it covers the window, so it has that slanted shape from the first moment it is visible
 * and lands as exactly the same geometry. Any click or key skips it. */
const CHIP_SLANT_PX=6;
const RISE_MS=300;
const HOLD_MS=420;
const FOLD_MS=780;
const STEPS=44;
const SETTLE_AT=.88;
const UNDERSHOOT=.9;
const ECHOES=[{name:'gold',delay:70},{name:'deep',delay:35}];

type Box={left:number;top:number;width:number;height:number};
type View={width:number;height:number};

const easeInOut=(t:number)=>t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;

/** Scale that takes the slanted chip just past every corner of the window. */
export function coverScale(chip:Box,view:View){
  const cx=chip.left+chip.width/2,cy=chip.top+chip.height/2;
  const farX=Math.max(cx,view.width-cx),farY=Math.max(cy,view.height-cy);
  const halfWidth=chip.width/2,halfHeight=chip.height/2,lean=CHIP_SLANT_PX/2;
  return 1.04*Math.max((farX+lean*farY/halfHeight)/(halfWidth-lean),farY/halfHeight);
}

/** Shrinks evenly to the eye (geometric, not linear), dips just under its size and settles at 1. */
export function foldProgress(p:number,from:number){
  if(p>=1)return 1;
  if(p>=SETTLE_AT){
    const t=(p-SETTLE_AT)/(1-SETTLE_AT);
    return UNDERSHOOT+(1-UNDERSHOOT)*(1-Math.pow(1-t,3));
  }
  return Math.exp(Math.log(from)+(Math.log(UNDERSHOOT)-Math.log(from))*easeInOut(p/SETTLE_AT));
}

/** The 2 waits at the center until the shape reaches its size, then rides inside it:
 * never bigger than the shape, and pulled in fast enough to never fall outside it. */
export function twoPose(shapeScale:number,giantScale:number,reachX:number,reachY:number){
  const grown=Math.max(0,shapeScale-1)*.7;
  return {scale:Math.min(giantScale,shapeScale),away:Math.min(1,grown*reachX,grown*reachY)};
}

function shapeKeyframes(from:number){
  return Array.from({length:STEPS+1},(_,index)=>({transform:`scale(${foldProgress(index/STEPS,from)})`}));
}

function twoKeyframes(from:number,giantScale:number,dx:number,dy:number,chip:Box){
  const reachX=chip.width/2/Math.max(1,Math.abs(dx)),reachY=chip.height/2/Math.max(1,Math.abs(dy));
  return Array.from({length:STEPS+1},(_,index)=>{
    const {scale,away}=twoPose(foldProgress(index/STEPS,from),giantScale,reachX,reachY);
    return {transform:`translate(${dx*away}px,${dy*away}px) rotate(${-7*(1-away)*away*4}deg) scale(${scale})`};
  });
}

export default function LauncherIntro({onReveal,onDone}:{onReveal:()=>void;onDone:()=>void}){
  const root=useRef<HTMLDivElement>(null);
  const solid=useRef<HTMLDivElement>(null);
  const two=useRef<HTMLSpanElement>(null);
  const callbacks=useRef({onReveal,onDone});
  callbacks.current={onReveal,onDone};

  useEffect(()=>{
    let stopped=false;
    let timer=0;
    const running:Animation[]=[];
    const finish=()=>{
      if(stopped)return;
      stopped=true;
      window.clearTimeout(timer);
      window.removeEventListener('keydown',finish);
      callbacks.current.onReveal();
      callbacks.current.onDone();
    };
    window.addEventListener('keydown',finish);
    const fold=()=>{
      const chip=document.querySelector('.coco-edition b');
      if(stopped||!chip||!root.current||!solid.current||!two.current){finish();return;}
      const box=chip.getBoundingClientRect();
      const view={width:window.innerWidth,height:window.innerHeight};
      const from=coverScale(box,view);
      const place=(element:HTMLElement)=>Object.assign(element.style,{left:`${box.left}px`,top:`${box.top}px`,width:`${box.width}px`,height:`${box.height}px`});
      const options={duration:FOLD_MS,easing:'linear',fill:'both'} as const;
      const shape=(name:string,delay:number)=>{
        const layer=document.createElement('div');
        layer.className=`coco-intro-shape is-${name}`;
        place(layer);
        root.current!.insertBefore(layer,two.current);
        running.push(layer.animate(shapeKeyframes(from),{...options,delay}));
      };
      ECHOES.forEach(echo=>shape(echo.name,echo.delay));
      shape('hot',0);
      solid.current.style.display='none';
      callbacks.current.onReveal();
      const giant=parseFloat(getComputedStyle(two.current).fontSize);
      const small=parseFloat(getComputedStyle(chip).fontSize);
      place(two.current);
      two.current.style.fontSize=`${small}px`;
      const dx=view.width/2-(box.left+box.width/2),dy=view.height/2-(box.top+box.height/2);
      const landed=two.current.animate(twoKeyframes(from,giant/small,dx,dy,box),options);
      running.push(landed);
      landed.onfinish=finish;
    };
    const rise=()=>{
      if(stopped||!two.current)return;
      running.push(two.current.animate([{opacity:0,transform:'scale(1.22)'},{opacity:1,transform:'scale(1)'}],{duration:RISE_MS,easing:'cubic-bezier(.16,1,.3,1)'}));
      two.current.style.opacity='1';
      timer=window.setTimeout(fold,HOLD_MS);
    };
    // The giant 2 must never appear in a fallback font, nor can the font hold the launcher back.
    const fontReady=document.fonts?document.fonts.load('900 100px "Big Shoulders Display Variable"',"2").catch(()=>[]):Promise.resolve([]);
    void Promise.race([fontReady,new Promise(resolve=>window.setTimeout(resolve,200))]).then(rise);
    return()=>{
      stopped=true;
      window.clearTimeout(timer);
      window.removeEventListener('keydown',finish);
      running.forEach(animation=>animation.cancel());
    };
  },[]);

  return <div className="coco-intro" ref={root} aria-hidden="true" onPointerDown={()=>{callbacks.current.onReveal();callbacks.current.onDone();}}>
    <div className="coco-intro-solid" ref={solid}/>
    <span className="coco-intro-two" ref={two}>2</span>
  </div>;
}
