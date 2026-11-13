/**
 * One persistent, inert <video> per curated preview, shared between screens.
 * All clips are queued for opportunistic preload instead of issuing 18
 * simultaneous requests or creating a second decoder on each navigation.
 * Playback is only triggered by pointer or keyboard focus.
 */
export type HoverPreviewSource = {url:string;bytes:number};
/** The only proximity tiers are visible (2) and near-viewport (1).
 * Select the same stable top-k as Array.sort without allocating and sorting
 * thousands of entries after every tiny metadata response. */
export function topVisibleIds(proximity:ReadonlyMap<string,number>,limit:number):string[]{
  if(!Number.isSafeInteger(limit)||limit<=0)return [];
  const result:string[]=[];
  for(const tier of [2,1]){
    for(const [id,value] of proximity){
      if(value!==tier)continue;
      result.push(id);
      if(result.length>=limit)return result;
    }
  }
  return result;
}
type MediaConnection = {saveData?:boolean;effectiveType?:string;downlink?:number;rtt?:number;
  addEventListener?:(type:string,listener:()=>void)=>void;
  removeEventListener?:(type:string,listener:()=>void)=>void};
type Clip = {
  video:HTMLVideoElement;
  host:HTMLElement|null;
  playEpoch:number;
  hoverStartedAt:number|null;
  rebuffering:boolean;
  loading:boolean;
  settled:boolean;
  timer:number|undefined;
  foregroundTimer:number|undefined;
  frameCallbackId:number|null;
  requestFirstFrame:()=>void;
  tier:'none'|'metadata'|'warm';
  everRequested:boolean;
  lastUsed:number;
  retryAfter:number;
  failed:boolean;
  attempts:number;
};

export class HoverVideoPool {
  private readonly clips=new Map<string,Clip>();
  private readonly sourceIds:string[];
  private readonly requestedEver=new Set<string>();
  private readonly metadataCovered=new Set<string>();
  private readonly retryAfterEviction=new Map<string,number>();
  private scanCursor=0;
  private readonly priorities:string[]=[];
  private readonly proximity=new Map<string,number>();
  private readonly observed=new Map<Element,string>();
  private readonly visibilityById=new Map<string,Map<Element,number>>();
  private readonly slotByObserverHost=new Map<Element,HTMLElement>();
  private readonly registeredSlots=new Map<string,Set<HTMLElement>>();
  private readonly warmEvicted=new Set<string>();
  private observer:IntersectionObserver|undefined;
  private activeId:string|null=null;
  private enabled=true;
  private backgroundBusy=false;
  /** Off while Coco is saving the clips to disk: preloading the same files from the network at
   * the same time would only split the connection between two copies. A hover still streams. */
  private networkWarmup=true;
  /** Told when a card whose clip is not on disk comes into view, so its download goes first. */
  onVisibleWithoutFile:((id:string)=>void)|null=null;
  private started=false;
  private inflight=0;
  private workTimer:number|undefined;
  private stage:HTMLElement|null=null;
  private readonly maxConcurrent=2;
  // Bound the *known compressed media bytes* of resident warm clips.
  // The WebView2 HTTP cache and decoder allocations remain browser-owned.
  private readonly maxWarmBytes=12*1024*1024;
  private readonly maxWarmClips=6;
  // A clip on local disk costs no network and starts in milliseconds, so every
  // visible card may hold one ready. Only the decoder cap applies to them.
  private readonly localFiles=new Map<string,string>();
  private readonly maxLocalWarmClips=24;
  private readonly maxLocalLoads=6;
  // A large catalog must never imply one persistent decoder/DOM video per
  // entry. Metadata coverage survives eviction; the player does not.
  private readonly maxResidentPlayers=32;
  // Foreground loads are not charged to the background concurrency budget.
  // They still require a deadline: a lost "playing"/frame/error event must
  // never leave an infinite spinner and a live network request behind.
  private readonly firstFrameDeadlineMs=15_000;
  private readonly frameLatenciesMs:number[]=[];
  private hoverAttempts=0;
  private readyOnHover=0;
  private bufferEvents=0;
  private sourceEvictions=0;
  private backgroundAborts=0;

  constructor(private readonly sources:Record<string,HoverPreviewSource>){
    this.sourceIds=Object.keys(sources);
  }

  /** Native cache finished this clip: use it from now on. */
  setLocalFile(id:string,url:string){
    if(!Object.hasOwn(this.sources,id)||this.localFiles.get(id)===url)return;
    this.localFiles.set(id,url);
    this.retryAfterEviction.delete(id);
    this.warmEvicted.delete(id);
    const clip=this.clips.get(id);
    if(clip){
      clip.failed=false;clip.retryAfter=0;clip.attempts=0;
      // A playing or still-fetching stream keeps going; the idle one switches.
      if(clip.video.src&&this.activeId!==id&&!clip.loading){
        clip.video.removeAttribute('src');
        clip.tier='none';clip.settled=false;
      }
    }
    this.schedule(0,true);
  }
  private sourceUrl(id:string){return this.localFiles.get(id)||this.sources[id].url;}
  private usesLocalFile(id:string){return this.localFiles.has(id);}

  start(){
    if(this.started)return;
    this.started=true;
    document.addEventListener('visibilitychange',this.visibilityChanged);
    this.connection()?.addEventListener?.('change',this.connectionChanged);
    this.schedule(650);
  }

  stop(){
    // Slots may mount before the parent start() effect (React StrictMode or
    // interrupted navigation). stop() must still release those players.
    this.started=false;
    document.removeEventListener('visibilitychange',this.visibilityChanged);
    this.connection()?.removeEventListener?.('change',this.connectionChanged);
    if(this.workTimer!==undefined){window.clearTimeout(this.workTimer);this.workTimer=undefined;}
    this.pauseAll();
    this.suspendBackground();
    this.releaseIdleWarm();
    this.observer?.disconnect();
    this.observer=undefined;
    this.observed.clear();
    this.visibilityById.clear();
    this.slotByObserverHost.clear();
    this.registeredSlots.clear();
    this.proximity.clear();
    // A closed view must not leave 32 live HTMLMediaElements or suspended
    // decoder resources behind. React StrictMode may start the pool again;
    // immutable source/coverage metadata survives and players are recreated.
    for(const clip of this.clips.values()){
      clip.playEpoch++;
      if(clip.frameCallbackId!==null){
        try{clip.video.cancelVideoFrameCallback?.(clip.frameCallbackId);}catch{}
        clip.frameCallbackId=null;
      }
      if(clip.timer!==undefined)window.clearTimeout(clip.timer);
      this.clearForegroundDeadline(clip);
      clip.video.pause();
      clip.video.removeAttribute('src');
      clip.video.load();
      clip.video.remove();
    }
    this.clips.clear();
    this.inflight=0;
    this.activeId=null;
    this.stage?.remove();
    this.stage=null;
  }

  setEnabled(enabled:boolean){
    if(this.enabled===enabled)return;
    this.enabled=enabled;
    if(!enabled){
      this.pauseAll();this.suspendBackground();
      // Accessibility 'no motion' should release warm decoders and network
      // streams too, not merely pause a video that may be several MiB.
      for(const clip of this.clips.values()){
        if(!clip.video.src)continue;
        clip.video.pause();
        clip.video.removeAttribute('src');
        clip.video.load();
        clip.tier='none';
        clip.settled=false;
        clip.hoverStartedAt=null;
      }
    }
    // A prior 30-second error/backoff scheduler may still be queued while
    // motion was disabled. Do not make a recovered idle view wait for it.
    else this.schedule(0,true);
  }

  setNetworkWarmup(enabled:boolean){
    this.networkWarmup=enabled;
    if(enabled)this.schedule(0,true);
  }

  setBackgroundBusy(busy:boolean){
    if(this.backgroundBusy===busy)return;
    this.backgroundBusy=busy;
    if(busy){
      // A game, installation, media playback or archive review must not
      // compete with a trailer left running under the pointer. Reproduction
      // resumes only on a fresh intentional hover/focus once Coco is idle.
      this.pauseAll();
      // Pause in-flight background fetches, not only future scheduling.
      // Never abort the foreground clip; Chromium can reuse cached ranges.
      this.suspendBackground();
      this.releaseIdleWarm();
    }else this.schedule(400,true);
  }

  private suspendBackground(){
    for(const [id,clip] of this.clips){
      if(clip.loading&&this.activeId!==id)this.cancelBackground(clip);
    }
  }

  private releaseIdleWarm(){
    // A canplay event can clear the scheduler slot while preload='auto'
    // continues fetching in Chromium. Release those idle sources when a game,
    // an installer or a foreground movie takes precedence (or on hide).
    for(const [id,clip] of this.clips){
      if(id===this.activeId||clip.loading||clip.tier!=='warm'||!clip.video.src)continue;
      clip.video.pause();
      clip.video.removeAttribute('src');
      clip.video.load();
      clip.tier='none';
      clip.settled=false;
    }
  }

  private clearForegroundDeadline(clip:Clip){
    if(clip.foregroundTimer!==undefined){
      window.clearTimeout(clip.foregroundTimer);
      clip.foregroundTimer=undefined;
    }
  }
  private failForeground(id:string,clip:Clip,epoch:number,retryMs:number,hardDecodeError=false){
    // A delayed play() rejection from a previous hover or a stopped/evicted
    // player must not abort a newer clip, nor erase a frame already displayed.
    if(this.clips.get(id)!==clip||this.activeId!==id||
      clip.playEpoch!==epoch||(!hardDecodeError&&clip.hoverStartedAt===null&&!clip.rebuffering))return;
    this.clearForegroundDeadline(clip);
    clip.playEpoch++;
    if(clip.frameCallbackId!==null){
      try{clip.video.cancelVideoFrameCallback?.(clip.frameCallbackId);}catch{}
      clip.frameCallbackId=null;
    }
    clip.video.pause();
    clip.video.removeAttribute('src');
    clip.video.load();
    clip.tier='none';
    clip.settled=true;
    clip.failed=true;
    clip.retryAfter=Date.now()+retryMs;
    this.retryAfterEviction.set(id,clip.retryAfter);
    clip.hoverStartedAt=null;
    clip.rebuffering=false;
    clip.host?.closest('.card-image-button')?.classList.remove('card-video-loading','card-video-playing');
    clip.host?.closest('.card-image-button')?.classList.add('card-video-unavailable');
    this.activeId=null;
    this.schedule(100);
  }
  private armForegroundDeadline(id:string,clip:Clip,epoch:number){
    this.clearForegroundDeadline(clip);
    clip.foregroundTimer=window.setTimeout(()=>{
      clip.foregroundTimer=undefined;
      // Abort only the still-pending foreground epoch. This is not a decoded
      // frame and must NEVER reveal the transparent video over its poster.
      this.failForeground(id,clip,epoch,60_000);
    },this.firstFrameDeadlineMs);
  }

  prioritize(ids:string[]){
    for(const id of ids){
      if(!Object.hasOwn(this.sources,id))continue;
      const prior=this.priorities.indexOf(id);
      if(prior>=0)this.priorities.splice(prior,1);
      this.priorities.push(id);
    }
    if(this.priorities.length>32)this.priorities.splice(0,this.priorities.length-32);
    this.schedule(0,true);
  }

  // React may render thousands of off-screen cards. Register lightweight
  // placeholders and let one pooled IntersectionObserver attach media near
  // the viewport, instead of creating a video/decoder for every card.
  registerSlot(id:string,slot:HTMLElement):()=>void{
    if(!Object.hasOwn(this.sources,id))return()=>{};
    let slots=this.registeredSlots.get(id);
    if(!slots){slots=new Set();this.registeredSlots.set(id,slots);}
    slots.add(slot);
    const host=slot.closest<HTMLElement>('.experience-card')||slot;
    this.slotByObserverHost.set(host,slot);
    const dispose=this.observe(id,host);
    return()=>{
      dispose();
      if(this.slotByObserverHost.get(host)===slot)this.slotByObserverHost.delete(host);
      const current=this.registeredSlots.get(id);
      current?.delete(slot);
      if(current?.size===0)this.registeredSlots.delete(id);
      this.detach(id,slot);
    };
  }

  observe(id:string,host:HTMLElement):()=>void{
    if(!Object.hasOwn(this.sources,id)||typeof IntersectionObserver==='undefined')return()=>{};
    if(!this.observer){
      this.observer=new IntersectionObserver(entries=>{
        let urgent=false;
        const attachments:{id:string;slot:HTMLElement;ratio:number}[]=[];
        for(const entry of entries){
          const observedId=this.observed.get(entry.target);
          if(!observedId)continue;
          const ratios=this.visibilityById.get(observedId)||new Map<Element,number>();
          if(entry.isIntersecting){
            // A player evicted under memory pressure may become important
            // again after scrolling. Permit one new warm attempt on a genuine
            // offscreen→visible transition, not on every observer callback.
            if(!ratios.has(entry.target)&&entry.intersectionRatio>=0.15){
              this.warmEvicted.delete(observedId);
            }
            ratios.set(entry.target,entry.intersectionRatio);
            this.visibilityById.set(observedId,ratios);
            const slot=this.slotByObserverHost.get(entry.target);
            // One game can be present in the hero and in the grid at once.
            // Scrolling either card must never steal its shared video from the
            // card the player is currently hovering/focusing; only an actual
            // pointer/focus play() may transfer the active decoder.
            if(slot&&this.activeId!==observedId&&this.clips.get(observedId)?.host!==slot&&
              // v10's eviction fence must also apply to repeated IO ratio
              // callbacks, not only the scheduler: remaining in viewport is
              // NOT permission to reconstruct an already-evicted decoder.
              !(this.warmEvicted.has(observedId)&&!this.clips.has(observedId)))
              attachments.push({id:observedId,slot,ratio:entry.intersectionRatio});
            if(entry.intersectionRatio>=0.15)urgent=true;
          }else ratios.delete(entry.target);
          if(ratios.size){
            const visible=Math.max(...ratios.values())>=0.15;
            this.proximity.set(observedId,visible?2:1);
            if(visible&&!this.usesLocalFile(observedId))this.onVisibleWithoutFile?.(observedId);
          }else{
            this.visibilityById.delete(observedId);
            this.proximity.delete(observedId);
          }
        }
        // IntersectionObserver can deliver >1,000 visible entries after a
        // filter/navigation or a large WebView resize. Never allocate one
        // decoder/player for every entry before checking the 32-player cap.
        // Keep all visibility metadata for the scheduler, but materialize
        // only the nearest/recent/high-priority visible cards in this batch.
        attachments.sort((a,b)=>b.ratio-a.ratio
          ||(this.clips.get(b.id)?.lastUsed||0)-(this.clips.get(a.id)?.lastUsed||0)
          ||this.priorities.indexOf(b.id)-this.priorities.indexOf(a.id));
        for(const {id,slot} of attachments.slice(0,this.maxResidentPlayers)){
          this.attach(id,slot,true);
          this.limitPlayers();
        }
        if(urgent&&this.inflight>=this.maxSlots()){
          // A just-visible card must not wait behind two 12-second requests
          // for far-away previews. Cancel one low-priority background fetch.
          for(const [id,clip] of this.clips){
            if(!clip.loading||id===this.activeId||(this.proximity.get(id)||0)>0)continue;
            this.cancelBackground(clip);
            break;
          }
        }
        // A card can stay mounted long after it leaves the viewport. It is
        // still a registered placeholder, not a reason to retain a decoder.
        // Enforce the actual player cap after visibility priorities settle.
        this.limitPlayers();
        this.schedule(0,urgent);
      },{rootMargin:'350px 0px',threshold:[0,0.15,0.5]});
    }
    this.observed.set(host,id);
    this.observer.observe(host);
    return()=>{
      this.observer?.unobserve(host);
      this.observed.delete(host);
      const ratios=this.visibilityById.get(id);
      ratios?.delete(host);
      if(!ratios?.size){this.visibilityById.delete(id);this.proximity.delete(id);}
      else this.proximity.set(id,Math.max(...ratios.values())>=0.15?2:1);
    };
  }

  private visibilityChanged=()=>{
    if(document.hidden){this.pauseAll();this.suspendBackground();this.releaseIdleWarm();}
    else this.schedule(400,true);
  };
  private connection=():MediaConnection|undefined=>
    (navigator as Navigator&{connection?:MediaConnection}).connection;
  private slowConnection(){
    const connection=this.connection();
    return connection?.effectiveType==='slow-2g'||connection?.effectiveType==='2g'||
      (typeof connection?.downlink==='number'&&connection.downlink<1.5)||
      (typeof connection?.rtt==='number'&&connection.rtt>600);
  }
  private maxSlots(){return this.slowConnection()?1:this.maxConcurrent;}
  private connectionChanged=()=>{
    if(this.connection()?.saveData){this.suspendBackground();this.releaseIdleWarm();return;}
    if(this.slowConnection()){
      let active=0;
      for(const [id,clip] of this.clips){
        if(!clip.loading)continue;
        if(id!==this.activeId&&active>=1)this.cancelBackground(clip);
        else active++;
      }
    }
    this.schedule(0,true);
  };

  private canPreload(){
    // Respect OS/browser metered-data preference and a hidden window. A
    // foreground hover always remains available despite these restrictions.
    const connection=this.connection();
    return this.started&&this.enabled&&!this.backgroundBusy&&!document.hidden&&!connection?.saveData;
  }

  private ensure(id:string):Clip|undefined{
    if(!Object.hasOwn(this.sources,id))return;
    const existing=this.clips.get(id);
    if(existing)return existing;
    // Evict BEFORE document.createElement('video'), not after: a single
    // IntersectionObserver batch can otherwise briefly exceed the decoder
    // cap on every replacement, amplifying peak CPU/GPU memory churn.
    if(this.clips.size>=this.maxResidentPlayers){
      this.limitPlayers(this.maxResidentPlayers-1);
      if(this.clips.size>=this.maxResidentPlayers)return;
    }
    const video=document.createElement('video');
    video.className='card-hover-video';
    video.preload='none';
    video.muted=true;
    video.playsInline=true;
    video.loop=true;
    video.disablePictureInPicture=true;
    video.setAttribute('aria-hidden','true');
    video.tabIndex=-1;
    const clip:Clip={video,host:null,playEpoch:0,hoverStartedAt:null,rebuffering:false,
      loading:false,settled:false,timer:undefined,foregroundTimer:undefined,
      frameCallbackId:null,requestFirstFrame:()=>{},
      tier:'none',everRequested:this.requestedEver.has(id),lastUsed:0,
      retryAfter:this.retryAfterEviction.get(id)||0,
      failed:(this.retryAfterEviction.get(id)||0)>Date.now(),attempts:0};
    const card=()=>clip.host?.closest('.card-image-button');
    const buffering=()=>{
      if(this.clips.get(id)!==clip||this.activeId!==id||!clip.host)return;
      this.bufferEvents++;
      // Before the first frame the hover deadline is already armed. After a
      // decoded frame it was cleared: an endless waiting/stalled event used to
      // leave the poster spinner and an HTTP range alive indefinitely. Arm a
      // separate bounded rebuffer watchdog, but don't count it as a fresh hover
      // latency sample or allow repeated waiting events to extend its timer.
      if(clip.hoverStartedAt===null&&!clip.rebuffering){
        clip.rebuffering=true;
        this.armForegroundDeadline(id,clip,clip.playEpoch);
      }
      card()?.classList.remove('card-video-playing');
      card()?.classList.add('card-video-loading');
    };
    const visible=(epoch:number)=>{
      if(this.clips.get(id)!==clip||epoch!==clip.playEpoch||this.activeId!==id||!this.enabled||!clip.host)return;
      this.clearForegroundDeadline(clip);
      clip.rebuffering=false;
      if(clip.hoverStartedAt!==null){
        const latency=Math.max(0,this.now()-clip.hoverStartedAt);
        this.frameLatenciesMs.push(Math.min(60_000,latency));
        if(this.frameLatenciesMs.length>64)this.frameLatenciesMs.shift();
        clip.hoverStartedAt=null;
      }
      card()?.classList.remove('card-video-loading');
      card()?.classList.add('card-video-playing');
    };
    const cancelFirstFrame=()=>{
      const pending=clip.frameCallbackId;
      clip.frameCallbackId=null;
      if(pending!==null)try{video.cancelVideoFrameCallback?.(pending);}catch{/* media removed */}
    };
    clip.requestFirstFrame=()=>{
      if(this.clips.get(id)!==clip||this.activeId!==id||!this.enabled||!clip.host)return;
      cancelFirstFrame();
      const epoch=clip.playEpoch;
      const callback=video.requestVideoFrameCallback;
      if(typeof callback==='function'){
        const frameId=callback.call(video,()=>{
          if(clip.frameCallbackId===frameId)clip.frameCallbackId=null;
          visible(epoch);
        });
        clip.frameCallbackId=frameId;
      }else if(video.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA){
        visible(epoch);
      }
    };
    video.addEventListener('waiting',buffering);
    video.addEventListener('stalled',buffering);
    video.addEventListener('seeking',buffering);
    video.addEventListener('playing',()=>{
      if(this.clips.get(id)!==clip||this.activeId!==id||!this.enabled||!clip.host)return;
      // A single cancellable callback survives rapid focus transitions; only
      // a confirmed new decoded frame can reveal the video over the poster.
      clip.requestFirstFrame();
    });
    video.addEventListener('seeked',()=>{
      // readyState means data is available, not that the compositor has
      // displayed the newly sought frame. Preserve the poster until the
      // *new* requestVideoFrameCallback confirms decoding in this epoch.
      if(!video.paused&&video.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA)
        clip.requestFirstFrame();
    });
    video.addEventListener('error',()=>{
      // Async abort/error from a cancelled background request must not mark
      // a source permanently broken after its src was deliberately removed.
      if(this.clips.get(id)!==clip||!clip.video.src)return;
      if(this.usesLocalFile(id)){
        // An unreadable cached file must not cost the preview: stream instead.
        this.localFiles.delete(id);
        const wasActive=this.activeId===id;
        this.finish(id,clip);
        clip.video.removeAttribute('src');
        clip.tier='none';clip.settled=false;
        if(wasActive&&clip.host){
          clip.video.src=this.sources[id].url;clip.tier='warm';clip.video.load();
          void clip.video.play().catch(()=>this.failForeground(id,clip,clip.playEpoch,5_000));
        }
        return;
      }
      if(this.activeId===id&&clip.host){
        // A decoder may fail AFTER the first successfully displayed frame.
        // The first-frame watchdog has already been cleared at that point;
        // the old generic handler left activeId and frame callbacks alive,
        // so later 'playing' events could revive a corrupt player. Release
        // only this epoch, keep the poster, and require explicit later hover.
        this.failForeground(id,clip,clip.playEpoch,60_000,true);
        return;
      }
      this.clearForegroundDeadline(clip);
      clip.rebuffering=false;
      this.finish(id,clip);
      clip.failed=true;
      clip.retryAfter=Date.now()+60_000;
      this.retryAfterEviction.set(id,clip.retryAfter);
      clip.video.removeAttribute('src');
      card()?.classList.remove('card-video-playing','card-video-loading');
      card()?.classList.add('card-video-unavailable');
      this.schedule(60_000);
    });
    video.addEventListener('loadeddata',()=>{
      if(this.clips.get(id)===clip&&clip.video.src){this.metadataCovered.add(id);this.finish(id,clip);}
    });
    video.addEventListener('canplay',()=>{
      if(this.clips.get(id)===clip&&clip.video.src){this.metadataCovered.add(id);this.finish(id,clip);}
    });
    video.addEventListener('loadedmetadata',()=>{
      if(this.clips.get(id)!==clip||!clip.video.src)return;
      this.metadataCovered.add(id);
      // Metadata is useful, but keep the slot until the opening frame can
      // play or the browser suspends transfer to avoid 18 hungry downloads.
      if(clip.tier==='metadata'||video.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA)this.finish(id,clip);
    });
    video.addEventListener('suspend',()=>{
      if(this.clips.get(id)!==clip)return;
      // Chromium may suspend a hidden video before fetching even the first
      // frame. Treat that as ready only when real decoded data exists.
      if(video.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA)this.finish(id,clip);
    });
    video.addEventListener('canplaythrough',()=>{
      if(this.clips.get(id)===clip&&clip.video.src){this.metadataCovered.add(id);this.finish(id,clip);}
    });
    video.addEventListener('progress',()=>{
      if(this.clips.get(id)!==clip)return;
      if(!Number.isFinite(video.duration)||video.duration<=0||!video.buffered.length)return;
      try{
        if(video.buffered.end(video.buffered.length-1)>=video.duration-0.2)this.finish(id,clip);
      }catch{/* media ranges can become invalid as the browser evicts data */}
    });
    this.clips.set(id,clip);
    // Keep offscreen previews connected to the document between navigation;
    // Chromium is free to suspend a detached element's preload.
    this.stageElement().appendChild(video);
    return clip;
  }

  private stageElement(){
    if(!this.stage){
      this.stage=document.createElement('div');
      this.stage.setAttribute('aria-hidden','true');
      this.stage.style.cssText='position:fixed;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none;z-index:-1';
      document.body.appendChild(this.stage);
    }
    return this.stage;
  }

  attach(id:string,host:HTMLElement,alreadyObserved=false):()=>void{
    const clip=this.ensure(id);
    if(!clip)return()=>{};
    if(clip.host&&clip.host!==host){
      // A transferred clip leaves the previous card behind. Remove its
      // playing/loading markers so the poster is visible there immediately.
      // Without this, the prior card could show an empty black video area.
      clip.host.closest('.card-image-button')?.classList.remove('card-video-playing','card-video-loading');
    }
    clip.host=host;
    host.appendChild(clip.video);
    const disposeObserver=alreadyObserved?()=>{}:this.observe(id,host.closest<HTMLElement>('.experience-card')||host);
    if(!alreadyObserved)this.limitPlayers();
    return()=>{
      disposeObserver();
      this.detach(id,host);
    };
  }
  private detach(id:string,host:HTMLElement){
    const clip=this.clips.get(id);
    if(!clip||clip.host!==host)return;
    if(this.activeId===id)this.pause(id);
    clip.host=null;
    this.stageElement().appendChild(clip.video);
    this.limitPlayers();
  }

  play(id:string,requestedSlot?:HTMLElement|null){
    if(!this.enabled||(this.backgroundBusy&&!this.usesLocalFile(id)))return;
    if(requestedSlot&&!this.registeredSlots.get(id)?.has(requestedSlot)){
      // A detached card may dispatch a late pointerenter/focus event after
      // React navigation. Never redirect it to an unrelated mounted slot.
      return;
    }
    const slots=this.registeredSlots.get(id);
    const slot=requestedSlot&&slots?.has(requestedSlot)?requestedSlot:
      [...(slots||[])][0];
    if(slot&&this.clips.get(id)?.host!==slot)this.attach(id,slot,true);
    const clip=this.ensure(id);
    if(!clip||!clip.host)return;
    // WebView2 can dispatch duplicate pointer/focus transitions for the same
    // visible card. Repeating play()/load()/priority work does not improve
    // latency when the very same shared decoder is already running. Keep the
    // pending first-frame callback and buffering indicator intact instead.
    if(this.activeId===id&&!clip.video.paused&&!clip.failed&&
      (!requestedSlot||clip.host===requestedSlot))return;
    if(this.activeId&&this.activeId!==id)this.pause(this.activeId);
    this.activeId=id;
    const epoch=++clip.playEpoch;
    clip.rebuffering=false;
    this.hoverAttempts++;
    if(clip.tier==='warm'&&clip.video.readyState>=HTMLMediaElement.HAVE_CURRENT_DATA)this.readyOnHover++;
    clip.hoverStartedAt=this.now();
    clip.lastUsed=Date.now();
    this.prioritize([id]);
    if(clip.failed){
      if(Date.now()<clip.retryAfter){
        clip.host.closest('.card-image-button')?.classList.add('card-video-unavailable');
        this.activeId=null;
        clip.hoverStartedAt=null;
        return;
      }
      clip.failed=false;
      clip.video.removeAttribute('src');
      clip.video.load();
    }
    clip.host.closest('.card-image-button')?.classList.remove('card-video-unavailable');
    clip.host.closest('.card-image-button')?.classList.add('card-video-loading');
    this.armForegroundDeadline(id,clip,epoch);
    // A background request that becomes foreground must not retain a 12s
    // cancellation timer. Stop accounting for the prefetch, keep its bytes.
    if(clip.loading)this.finish(id,clip);
    this.load(id,false,'warm');
    // play() is called synchronously from pointerenter/focus to preserve the
    // Chromium user-activation window. It never waits for background work.
    clip.video.muted=true;
    void clip.video.play().catch(()=>{
      // WebView2 can reject play() immediately (policy/decoder failure).
      // Previously this left src/network and a 15-second watchdog alive after
      // the failure was already known. Abort this epoch and permit an explicit
      // retry after a short, bounded cooldown instead of spamming the decoder.
      this.failForeground(id,clip,epoch,5_000);
    });
    // Calling play() on an already playing shared node need not dispatch a
    // fresh playing event. Arm a frame check for the new hover epoch anyway.
    if(!clip.video.paused)clip.requestFirstFrame();
    // Rapid pointer traversal can promote many metadata-only entries before
    // any loadeddata event arrives. Enforce residency after every promotion,
    // not only when a network event or pause happens.
    this.limitResidence();
    this.limitPlayers();
  }

  pause(id:string,requestedSlot?:HTMLElement|null){
    const clip=this.clips.get(id);
    if(!clip)return;
    // Several cards can represent the same experience. An old card's pointer
    // leave/blur must not stop the preview newly attached to another card.
    if(requestedSlot&&clip.host!==requestedSlot)return;
    if(this.activeId===id)this.activeId=null;
    clip.playEpoch++;
    this.clearForegroundDeadline(clip);
    if(clip.frameCallbackId!==null){
      try{clip.video.cancelVideoFrameCallback?.(clip.frameCallbackId);}catch{}
      clip.frameCallbackId=null;
    }
    clip.hoverStartedAt=null;
    clip.rebuffering=false;
    clip.host?.closest('.card-image-button')?.classList.remove('card-video-playing','card-video-loading');
    clip.video.pause();
    // Re-prime the opening frame without losing the already downloaded clip.
    if(clip.video.readyState>0&&clip.video.currentTime>0.15){
      try{clip.video.currentTime=0;}catch{/* remote media may be unavailable */}
    }
    this.limitResidence();
  }

  pauseActive(){this.pauseAll();}

  private pauseAll(){
    if(this.activeId)this.pause(this.activeId);
  }

  private load(id:string,background:boolean,tier:'metadata'|'warm'='warm'){
    const clip=this.ensure(id);
    if(!clip)return;
    if(clip.video.src&&clip.tier==='warm')return;
    if(clip.video.src&&clip.tier==='metadata'&&tier==='metadata')return;
    if(clip.failed&&Date.now()<clip.retryAfter)return;
    const promoteExisting=Boolean(clip.video.src&&clip.tier==='metadata'&&tier==='warm');
    if(clip.loading){
      if(clip.timer!==undefined){window.clearTimeout(clip.timer);clip.timer=undefined;}
      clip.loading=false;
      this.inflight=Math.max(0,this.inflight-1);
    }
    clip.tier=tier;
    clip.settled=false;
    clip.everRequested=true;
    this.requestedEver.add(id);
    clip.video.preload=tier==='metadata'?'metadata':'auto';
    if(!clip.video.src)clip.video.src=this.sourceUrl(id);
    // Promoting metadata to warm preserves the existing Resource Selection
    // algorithm and HTTP ranges; forcing load() here discards decoded state
    // and can re-request the first segment. play() itself resumes fetching if
    // a WebView ignores the preload hint.
    if(!promoteExisting)clip.video.load();
    if(background){
      clip.loading=true;
      this.inflight++;
      clip.attempts++;
      // Real transfer deadline: do not merely release a concurrency counter
      // while Chrome keeps all 18 stalled downloads open. A failed clip is
      // retried later, foreground hover always remains independent.
      clip.timer=window.setTimeout(()=>{
        if(!clip.loading)return;
        this.cancelBackground(clip);
        clip.retryAfter=Date.now()+15_000;
        if(clip.attempts>=3){clip.failed=true;clip.retryAfter=Date.now()+60_000;}
        this.retryAfterEviction.set(id,clip.retryAfter);
        this.schedule(100);
      },12_000);
    }
  }

  private cancelBackground(clip:Clip){
    if(clip.loading)this.backgroundAborts++;
    if(clip.timer!==undefined){window.clearTimeout(clip.timer);clip.timer=undefined;}
    clip.loading=false;
    this.inflight=Math.max(0,this.inflight-1);
    clip.video.removeAttribute('src');
    clip.video.load();
    clip.settled=false;
    clip.tier='none';
  }

  private finish(id:string,expected?:Clip){
    const clip=this.clips.get(id);
    if(!clip||clip.settled||(expected&&clip!==expected))return;
    clip.settled=true;
    if(clip.timer!==undefined){window.clearTimeout(clip.timer);clip.timer=undefined;}
    if(clip.loading){clip.loading=false;this.inflight=Math.max(0,this.inflight-1);}
    this.limitResidence();
    this.limitPlayers();
    this.schedule(100);
  }

  private limitPlayers(maximum=this.maxResidentPlayers){
    if(this.clips.size<=maximum)return;
    // A mounted, *offscreen* card must not pin its decoder forever. If more
    // than 32 cards are simultaneously visible, preserve the active card and
    // higher-priority/recent visible ones and leave posters on the remainder.
    const victims=[...this.clips].filter(([id,c])=>
      !c.loading&&id!==this.activeId);
    victims.sort(([a,ca],[b,cb])=>{
      const importance=([id,clip]:[string,Clip])=>
        (this.proximity.get(id)||0)*100_000+
        (clip.host?200:0)+
        (clip.lastUsed&&Date.now()-clip.lastUsed<120_000?10_000:0)+
        Math.max(0,this.priorities.indexOf(id))*10;
      return importance([a,ca])-importance([b,cb]);
    });
    for(const [id,clip] of victims){
      if(this.clips.size<=maximum)break;
      if(clip.timer!==undefined)window.clearTimeout(clip.timer);
      this.clearForegroundDeadline(clip);
      if(clip.frameCallbackId!==null){
        try{clip.video.cancelVideoFrameCallback?.(clip.frameCallbackId);}catch{}
        clip.frameCallbackId=null;
      }
      clip.host?.closest('.card-image-button')?.classList.remove('card-video-playing','card-video-loading');
      clip.host=null;
      clip.video.pause();
      clip.video.removeAttribute('src');
      clip.video.load();
      clip.video.remove();
      this.clips.delete(id);
      // A card that stays continuously visible must not immediately
      // reinstantiate the decoder evicted for the 32-player cap, even if
      // the first metadata request has not happened yet. The scheduler will
      // still probe missing metadata using the low-memory tier below.
      // A genuine viewport reentry or an explicit hover can rewarm it.
      this.warmEvicted.add(id);
      this.sourceEvictions++;
    }
  }

  private limitResidence(){
    // Keep only a bounded number of full-quality warm players. The browser
    // owns and may still reuse HTTP ranges; no app-owned disk cache exists.
    const allWarm=[...this.clips].filter(([,clip])=>clip.tier==='warm'&&Boolean(clip.video.src));
    const local=allWarm.filter(([id])=>this.usesLocalFile(id));
    const warm=allWarm.filter(([id])=>!this.usesLocalFile(id));
    for(const [id,clip] of local.slice(0,Math.max(0,local.length-this.maxLocalWarmClips))){
      if(id===this.activeId)continue;
      clip.video.pause();
      clip.video.removeAttribute('src');
      clip.video.load();
      clip.tier='none';
      this.warmEvicted.add(id);
    }
    let bytes=warm.reduce((sum,[id])=>sum+(this.sources[id]?.bytes||0),0);
    let count=warm.length;
    warm.sort((a,b)=>{
      const score=([id,clip]:[string,Clip])=>
        (this.activeId===id?1000:0)+(this.proximity.get(id)||0)*100+
        (clip.lastUsed?25:0)+this.priorities.indexOf(id)/Math.max(1,this.priorities.length);
      return score(a)-score(b);
    });
    for(const [id,clip] of warm){
      if(bytes<=this.maxWarmBytes&&count<=this.maxWarmClips)break;
      if(id===this.activeId)continue;
      clip.video.pause();
      if(clip.loading)this.cancelBackground(clip);
      else{
        clip.video.removeAttribute('src');
        clip.video.load();
        clip.tier='none';
      }
      clip.settled=true;
      this.warmEvicted.add(id);
      this.sourceEvictions++;
      bytes-=this.sources[id]?.bytes||0;
      count--;
    }
  }

  private schedule(delay:number,urgent=false){
    if(!this.canPreload())return;
    if(this.workTimer!==undefined){
      if(!urgent)return;
      window.clearTimeout(this.workTimer);
      this.workTimer=undefined;
    }
    this.workTimer=window.setTimeout(()=>{
      this.workTimer=undefined;
      if(!this.canPreload())return;
      // Small priority working set plus a rolling scan: a 2,000-game catalog
      // does not sort/allocate 2,000 media nodes on every completion event.
      // Every source eventually receives metadata when idle; retry backoffs
      // are honored and foreground requests bypass background slots.
      const distant:string[]=[];
      const batch=Math.min(this.sourceIds.length,64);
      for(let i=0;i<batch;i++){
        const id=this.sourceIds[this.scanCursor];
        this.scanCursor=(this.scanCursor+1)%this.sourceIds.length;
        if(!this.metadataCovered.has(id))distant.push(id);
      }
      const order=[...new Set([
        ...topVisibleIds(this.proximity,this.maxResidentPlayers),
        ...this.priorities.slice().reverse(),
        ...[...this.clips].sort((a,b)=>b[1].lastUsed-a[1].lastUsed).map(([id])=>id),
        ...distant,
      ])];
      let retryDelay=Infinity;
      for(const id of order){
        const local=this.usesLocalFile(id);
        if(!local&&!this.networkWarmup)continue;
        if(this.inflight>=(local?this.maxLocalLoads:this.maxSlots())){
          if(local)break;
          continue;
        }
        const clip=this.clips.get(id);
        const retryAt=Math.max(clip?.retryAfter||0,this.retryAfterEviction.get(id)||0);
        if(Date.now()<retryAt){
          retryDelay=Math.min(retryDelay,retryAt-Date.now());
          continue;
        }
        if(clip?.failed){
          clip.failed=false;
          clip.settled=false;
          clip.video.removeAttribute('src');
          clip.video.load();
        }
        const near=(this.proximity.get(id)||0)>0;
        const recentlyUsed=Boolean(clip?.lastUsed)&&Date.now()-clip!.lastUsed<120_000;
        const startup=this.priorities.includes(id)&&this.priorities.indexOf(id)>=Math.max(0,this.priorities.length-4);
        const needsMetadata=this.warmEvicted.has(id)&&!this.metadataCovered.has(id);
        const target:'metadata'|'warm'=local?'warm':this.slowConnection()||needsMetadata?
          'metadata':near||recentlyUsed||startup?'warm':'metadata';
        // Avoid an endless evict→reload loop if the preferred warm set is
        // bigger than the memory budget. Foreground hover always bypasses it.
        if(target==='warm'&&this.warmEvicted.has(id))continue;
        if(clip?.loading||clip?.tier==='warm'&&clip.video.src)continue;
        if(clip?.settled&&!(target==='warm'&&(clip.tier==='metadata'||!clip.video.src)))continue;
        if(clip?.video.src&&clip.tier==='metadata'&&target==='metadata')continue;
        if(this.metadataCovered.has(id)&&target==='metadata')continue;
        this.load(id,true,target);
        this.limitResidence();
        this.limitPlayers();
      }
      // No in-flight callbacks remain to advance the scan if this batch only
      // contained completed/temporarily unavailable entries.
      if(this.inflight===0){
        // Merely having attempted every URL is not metadata coverage. Every
        // request may have stalled before loadedmetadata, been preempted by
        // foreground navigation, or suffered a transient network failure.
        // Rescan uncovered IDs under per-source cooldown, even after 100%
        // "requested", without a tight timer loop when all peers are offline.
        if(this.metadataCovered.size<this.sourceIds.length)
          this.schedule(this.requestedEver.size<this.sourceIds.length?150:
            Number.isFinite(retryDelay)?Math.max(150,Math.min(30_000,retryDelay)):1500);
        else if(Number.isFinite(retryDelay))this.schedule(Math.max(100,retryDelay));
      }
    },delay);
  }

  getStatus(){
    const ordered=[...this.frameLatenciesMs].sort((a,b)=>a-b);
    const quantile=(fraction:number)=>ordered.length?Math.round(ordered[Math.ceil(ordered.length*fraction)-1]):null;
    return {total:this.sourceIds.length,
      requested:this.requestedEver.size,
      metadataCovered:this.metadataCovered.size,
      residentPlayers:this.clips.size,
      loading:this.inflight,
      localFiles:this.localFiles.size,
      warm:[...this.clips.values()].filter(c=>c.tier==='warm'&&Boolean(c.video.src)).length,
      warmBytes:[...this.clips].reduce((total,[id,clip])=>total+(clip.tier==='warm'&&clip.video.src?this.sources[id]?.bytes||0:0),0),
      hoverAttempts:this.hoverAttempts,readyOnHover:this.readyOnHover,
      firstFrameSamples:ordered.length,firstFrameP50Ms:quantile(.5),firstFrameP95Ms:quantile(.95),
      bufferEvents:this.bufferEvents,sourceEvictions:this.sourceEvictions,
      backgroundAborts:this.backgroundAborts};
  }
  private now(){return typeof performance!=='undefined'?performance.now():Date.now();}
}
