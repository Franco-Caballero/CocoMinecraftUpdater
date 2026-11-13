/** Small, local-only player history. IDs and event types only: never paths,
 * command lines, hashes, network addresses or personal file metadata. */
export type ActivityKind='played'|'installed'|'upgraded'|'repaired'|'recovered'|'watched'|'downloaded'|'uninstalled'|
  'install-interrupted'|'upgrade-interrupted'|'repair-interrupted'|'recover-interrupted';
export type ActivityEntry={id:string;kind:ActivityKind;at:number};
type StoragePort=Pick<Storage,'getItem'|'setItem'|'removeItem'>;
const KEY='coco2-activity-v1';
const MAX_ENTRIES=60;
const MAX_AGE_MS=90*24*60*60*1000;
const KINDS=new Set<ActivityKind>(['played','installed','upgraded','repaired','recovered','watched','downloaded','uninstalled',
  'install-interrupted','upgrade-interrupted','repair-interrupted','recover-interrupted']);
const validId=(id:unknown):id is string=>typeof id==='string'&&/^[a-z0-9][a-z0-9._-]{0,95}$/i.test(id);
function safeStore(store?:StoragePort):StoragePort|undefined{
  if(store)return store;
  try{return localStorage;}catch{return undefined;}
}
export function readActivity(store?:StoragePort,now=Date.now()):ActivityEntry[]{
  try{
    const raw=safeStore(store)?.getItem(KEY);
    if(!raw)return [];
    const parsed:unknown=JSON.parse(raw);
    if(!Array.isArray(parsed))return [];
    return parsed.filter((value):value is ActivityEntry=>
      value!==null&&typeof value==='object'&&
      validId((value as ActivityEntry).id)&&KINDS.has((value as ActivityEntry).kind)&&
      Number.isSafeInteger((value as ActivityEntry).at)&&
      (value as ActivityEntry).at<=now+60_000&&(value as ActivityEntry).at>=now-MAX_AGE_MS)
      .sort((a,b)=>b.at-a.at).slice(0,MAX_ENTRIES);
  }catch{return [];}
}
export function recordActivity(kind:ActivityKind,id:string,store?:StoragePort,now=Date.now()):ActivityEntry[]{
  const current=readActivity(store,now);
  if(!KINDS.has(kind)||!validId(id))return current;
  // Suppress duplicate callbacks and hot re-mounts while preserving distinct
  // play sessions and distinct operations across app restarts.
  const recent=current[0];
  if(recent?.kind===kind&&recent.id===id&&now-recent.at<10_000)return current;
  const next=[{id,kind,at:now},...current].slice(0,MAX_ENTRIES);
  try{safeStore(store)?.setItem(KEY,JSON.stringify(next));}catch{/* storage blocked/full */}
  return next;
}
export function clearActivity(store?:StoragePort){
  try{safeStore(store)?.removeItem(KEY);}catch{/* storage disabled */}
}
