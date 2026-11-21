import {useEffect,useLayoutEffect,useRef,type RefObject} from 'react';

/** Cards glide to their new slot instead of snapping when the grid changes, and
 * a game that just arrived grows into the space opened for it. */
export type Slot={left:number;top:number};
export type FlipPlan={moved:{id:string;dx:number;dy:number}[];entered:string[]};

export function planFlip(previous:ReadonlyMap<string,Slot>,next:ReadonlyMap<string,Slot>):FlipPlan{
  const moved:FlipPlan['moved']=[],entered:string[]=[];
  for(const [id,slot] of next){
    const before=previous.get(id);
    if(!before){entered.push(id);continue;}
    const dx=before.left-slot.left,dy=before.top-slot.top;
    if(Math.abs(dx)>=1||Math.abs(dy)>=1)moved.push({id,dx,dy});
  }
  return {moved,entered};
}

const EASE='cubic-bezier(.2,.9,.25,1)';
// Leave room for a row just outside the viewport and for hover/entry overflow.
const VIEWPORT_MARGIN=180;

export function crossesVerticalRange(fromTop:number,toTop:number,height:number,top:number,bottom:number){
  return Math.min(fromTop,toTop)<bottom&&Math.max(fromTop,toTop)+height>top;
}

function measure(container:HTMLElement){
  const cards=new Map<string,HTMLElement>(),slots=new Map<string,Slot>();
  for(const child of container.children){
    const card=child as HTMLElement;
    const id=card.dataset.flipId;
    if(!id)continue;
    // The positioned grid is the offset parent, including the first row/column at zero.
    cards.set(id,card);
    slots.set(id,{left:card.offsetLeft,top:card.offsetTop});
  }
  return {cards,slots};
}

export function useFlipGrid(container:RefObject<HTMLElement|null>,signature:string,enabled:boolean,suspended?:()=>boolean){
  const slots=useRef<Map<string,Slot>|null>(null);
  const animations=useRef(new WeakMap<HTMLElement,Animation>());
  useLayoutEffect(()=>{
    const element=container.current;
    if(!element||!enabled){slots.current=null;return;}
    const current=measure(element);
    const previous=slots.current;
    slots.current=current.slots;
    // A view transition already moves every card: gliding them again would move them twice.
    if(suspended?.()||typeof Element.prototype.animate!=='function')return;

    const origin=element.getBoundingClientRect().top;
    const top=-origin-VIEWPORT_MARGIN;
    const bottom=element.ownerDocument.documentElement.clientHeight-origin+VIEWPORT_MARGIN;
    const visibleDuringMove=(id:string,dy=0)=>{
      const {top:destination}=current.slots.get(id)!;
      return crossesVerticalRange(destination+dy,destination,current.cards.get(id)!.offsetHeight,top,bottom);
    };
    const plan=previous?planFlip(previous,current.slots):{moved:[],entered:[...current.cards.keys()]};
    // Read geometry for the full batch before changing styles or starting animations.
    const moves=plan.moved.map(move=>({...move,visible:visibleDuringMove(move.id,move.dy)}));
    const entries=plan.entered.map(id=>({id,visible:visibleDuringMove(id)}));
    const running=animations.current;
    for(const {id,dx,dy,visible} of moves){
      const card=current.cards.get(id)!;
      running.get(card)?.cancel();
      if(!visible)continue;
      running.set(card,card.animate(
        [{transform:`translate(${dx}px,${dy}px)`},{transform:'none'}],
        {duration:440,easing:EASE}));
    }
    entries.forEach(({id,visible},index)=>{
      const card=current.cards.get(id)!;
      // Keep the CSS entrance on first paint. Later entries use one animation.
      if(!previous&&visible)return;
      card.dataset.flipEntry='managed';
      if(!visible)return;
      running.set(card,card.animate(
        [{opacity:0,transform:'translateY(14px) scale(.94)'},{opacity:1,transform:'none'}],
        {duration:480,delay:Math.min(index,10)*26,easing:EASE,fill:'backwards'}));
    });
  },[signature,enabled]);
  // A window resize moves every card legitimately: it must not read as a move.
  useEffect(()=>{
    if(!enabled)return;
    const resize=()=>{
      const element=container.current;
      slots.current=element?measure(element).slots:null;
    };
    window.addEventListener('resize',resize);
    return()=>window.removeEventListener('resize',resize);
  },[container,enabled]);
}
