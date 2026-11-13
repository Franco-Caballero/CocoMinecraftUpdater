/** One library for every experience: pure filtering, ordering and "new" rules. */
export type LibraryEntry={id:string;name:string;workflow:string};
export type LibraryFilter='all'|'games'|'movies'|'installed'|'favorites';
export type LibrarySort='recent'|'name';

/** Minecraft packs share the library, but Coco 2 cannot launch them yet. */
export const isComingSoon=(entry:LibraryEntry):boolean=>
  entry.workflow!=='coco-standalone'&&entry.workflow!=='coco-media';

export function matchesLibraryFilter(entry:LibraryEntry,filter:LibraryFilter,
  favorites:ReadonlySet<string>,installed:ReadonlySet<string>):boolean{
  if(filter==='games')return entry.workflow!=='coco-media';
  if(filter==='movies')return entry.workflow==='coco-media';
  if(filter==='installed')return installed.has(entry.id);
  if(filter==='favorites')return favorites.has(entry.id);
  return true;
}

/** The catalog appends each approved entry, so a later index is a newer one. */
export function sortLibrary<T extends LibraryEntry>(entries:readonly T[],sort:LibrarySort):T[]{
  const order=new Map(entries.map((entry,index)=>[entry.id,index]));
  return [...entries].sort((a,b)=>{
    const soon=Number(isComingSoon(a))-Number(isComingSoon(b));
    if(soon)return soon;
    return sort==='name'?a.name.localeCompare(b.name,'es',{sensitivity:'base'})
      :order.get(b.id)!-order.get(a.id)!;
  });
}

export function latestAddition<T extends LibraryEntry>(entries:readonly T[]):T|null{
  for(let index=entries.length-1;index>=0;index--)
    if(!isComingSoon(entries[index]))return entries[index];
  return null;
}

/** The first catalog ever seen is the baseline: nothing in it counts as new. */
export function unseenEntries(ids:readonly string[],seen:ReadonlySet<string>|null):string[]{
  return seen?ids.filter(id=>!seen.has(id)):[];
}

export function formatBytes(bytes:number){
  if(bytes>=1024**3)return `${(bytes/1024**3).toLocaleString('es-CL',{maximumFractionDigits:1})} GB`;
  return `${Math.max(1,Math.round(bytes/1024**2)).toLocaleString('es-CL')} MB`;
}

/** "167 / 388 MB": the unit once when both sides share it. */
export function formatBytePair(done:number,total:number){
  const [left,right]=[formatBytes(done),formatBytes(total)];
  const unit=right.slice(right.lastIndexOf(" "));
  return `${left.endsWith(unit)?left.slice(0,-unit.length):left} / ${right}`;
}

/** Long paths keep the drive and the end, which is what tells two folders apart. */
export function shortPath(path:string,maxLength=44){
  if(path.length<=maxLength)return path;
  const parts=path.split('\\');
  const head=parts[0];
  let tail=parts[parts.length-1];
  for(let index=parts.length-2;index>0;index--){
    if(head.length+tail.length+parts[index].length+6>maxLength)break;
    tail=`${parts[index]}\\${tail}`;
  }
  return `${head}\\…\\${tail}`;
}
