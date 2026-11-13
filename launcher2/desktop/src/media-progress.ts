/** Where the viewer left each movie or episode, kept per viewer in this WebView only. Storage can
 * be missing or full (private profile, cleared data), so every access is best effort and a
 * failure just means starting from the beginning. */
export type MediaProgress={position:number;duration:number;finished:boolean;at:number};

const KEY='coco2.media-progress.v1';
/** Closer than this to the start is not worth offering a resume. */
const MIN_RESUME_SECONDS=30;
/** Within this of the end (or past 95%) counts as watched: credits are not a story. */
const END_MARGIN_SECONDS=90;

const progressKey=(id:string,episodeId:string)=>`${id}/${episodeId}`;

function readAll():Record<string,MediaProgress>{
  try{
    const parsed=JSON.parse(localStorage.getItem(KEY)||'{}');
    return parsed&&typeof parsed==='object'?parsed:{};
  }catch{return {};}
}

export function progressFor(id:string,episodeId:string):MediaProgress|null{
  const entry=readAll()[progressKey(id,episodeId)];
  if(!entry||!Number.isFinite(entry.position)||!Number.isFinite(entry.duration)||entry.duration<=0)return null;
  return entry;
}

export function isFinishedAt(position:number,duration:number){
  return duration>0&&(position>=duration*.95||duration-position<=END_MARGIN_SECONDS);
}

export function saveProgress(id:string,episodeId:string,position:number,duration:number){
  if(!Number.isFinite(position)||!Number.isFinite(duration)||duration<=0)return;
  try{
    const all=readAll();
    all[progressKey(id,episodeId)]={position,duration,finished:isFinishedAt(position,duration),at:Date.now()};
    localStorage.setItem(KEY,JSON.stringify(all));
  }catch{/* storage unavailable: playback still works, it just will not resume */}
}

export function clearProgress(id:string,episodeId:string){
  try{
    const all=readAll();
    delete all[progressKey(id,episodeId)];
    localStorage.setItem(KEY,JSON.stringify(all));
  }catch{/* nothing to clear */}
}

/** Where to pick up again, or null to start from the beginning. */
export function resumePoint(progress:MediaProgress|null):number|null{
  if(!progress||progress.finished||progress.position<MIN_RESUME_SECONDS)return null;
  return progress.position;
}

/** 0..1 for a progress bar; a finished one reads as complete. */
export function watchedFraction(progress:MediaProgress|null){
  if(!progress)return 0;
  return progress.finished?1:Math.max(0,Math.min(1,progress.position/progress.duration));
}

/** 1:05:09, 5:09 or 0:09, like every player. */
export function formatClock(seconds:number){
  if(!Number.isFinite(seconds)||seconds<0)return '0:00';
  const total=Math.floor(seconds);
  const h=Math.floor(total/3600),m=Math.floor(total/60)%60,s=total%60;
  const pad=(value:number)=>String(value).padStart(2,'0');
  return h?`${h}:${pad(m)}:${pad(s)}`:`${m}:${pad(s)}`;
}

/** «1 h 12 min» or «8 min»: how much is left, in words. */
export function formatRemaining(seconds:number){
  const minutes=Math.max(1,Math.round(seconds/60));
  const h=Math.floor(minutes/60),m=minutes%60;
  return h?(m?`${h} h ${m} min`:`${h} h`):`${m} min`;
}
