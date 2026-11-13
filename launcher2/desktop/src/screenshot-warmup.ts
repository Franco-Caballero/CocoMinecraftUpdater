/** Keeps every game's Steam screenshots warm, so a gallery shows them instantly. Steam serves
 * them with a ten-year cache, so once fetched WebView2 keeps them on disk by itself and later
 * launches re-read them from there; nothing is saved by Coco. Two at a time, always running. */
const PARALLEL=2;
const queue:string[]=[];
const warmed=new Set<string>();
let active=0;

function pump(){
  while(active<PARALLEL&&queue.length){
    const url=queue.shift()!;
    if(warmed.has(url))continue;
    warmed.add(url);
    active++;
    const image=new Image();
    image.decoding='async';
    image.src=url;
    // decode() also settles on a failed load; a failure is retried the next time it is asked for.
    image.decode().catch(()=>warmed.delete(url)).finally(()=>{active--;pump();});
  }
}

/** `urgent` puts these first: the game the player is looking at matters more than the backlog. */
export function warmScreenshots(urls:readonly string[],urgent=false){
  const fresh=urls.filter(url=>!warmed.has(url));
  for(const url of fresh){const at=queue.indexOf(url);if(at>=0)queue.splice(at,1);}
  if(urgent)queue.unshift(...fresh);else queue.push(...fresh);
  pump();
}

/** The opening shots of every game first, newest game first, then everything else. */
export function warmAllScreenshots(byGame:Record<string,readonly string[]>,newestFirst:readonly string[]){
  const order=[...newestFirst.filter(id=>id in byGame),...Object.keys(byGame).filter(id=>!newestFirst.includes(id))];
  warmScreenshots(order.flatMap(id=>byGame[id].slice(0,3)));
  warmScreenshots(order.flatMap(id=>byGame[id].slice(3)));
}
