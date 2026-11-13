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
const MAX_ANIMATED=60;

function measure(container:HTMLElement){
  const origin=container.getBoundingClientRect();
  const cards=new Map<string,HTMLElement>(),slots=new Map<string,Slot>();
  container.querySelectorAll<HTMLElement>('[data-flip-id]').forEach(card=>{
    const id=card.dataset.flipId!;
    // offset* ignores a running lift or glide, so the slot stays the real one.
    const rect=card.getBoundingClientRect();
    cards.set(id,card);
    slots.set(id,{left:card.offsetLeft||rect.left-origin.left,top:card.offsetTop||rect.top-origin.top});
  });
  return {cards,slots};
}

export function useFlipGrid(container:RefObject<HTMLElement|null>,signature:string,enabled:boolean,suspended?:()=>boolean){
  const slots=useRef<Map<string,Slot>|null>(null);
  useLayoutEffect(()=>{
    const element=container.current;
    if(!element)return;
    const current=measure(element);
    const previous=slots.current;
    slots.current=current.slots;
    // A view transition already moves every card: gliding them again would move them twice.
    if(!previous||!enabled||suspended?.()||typeof Element.prototype.animate!=='function')return;
    const plan=planFlip(previous,current.slots);
    plan.moved.slice(0,MAX_ANIMATED).forEach(({id,dx,dy})=>{
      current.cards.get(id)?.animate(
        [{transform:`translate(${dx}px,${dy}px)`},{transform:'none'}],
        {duration:440,easing:EASE});
    });
    plan.entered.slice(0,MAX_ANIMATED).forEach((id,index)=>{
      current.cards.get(id)?.animate(
        [{opacity:0,transform:'translateY(14px) scale(.94)'},{opacity:1,transform:'none'}],
        {duration:480,delay:Math.min(index,10)*26,easing:EASE,fill:'backwards'});
    });
  },[signature,enabled]);
  // A window resize moves every card legitimately: it must not read as a move.
  useEffect(()=>{
    const element=container.current;
    if(!element||typeof ResizeObserver==='undefined')return;
    const observer=new ResizeObserver(()=>{slots.current=measure(element).slots;});
    observer.observe(element);
    return()=>observer.disconnect();
  },[]);
}
