import {normalizeExperienceQuery} from './experience-search';

export type DiscoveryEntry={id:string;name:string;workflow:string;description:string};

/** Construct once per verified catalog revision, not on every keystroke. */
export function indexDiscoveryNames<T extends DiscoveryEntry>(entries:readonly T[]):ReadonlyMap<string,string>{
  return new Map(entries.map(entry=>[entry.id,normalizeExperienceQuery(entry.name)]));
}

/** Small, stable, trusted-catalog top-k search; never sort or mount thousands
 * of cards while typing. Search crosses Juegos and Videos (unlike a filtered
 * library view). Recent/favorite entries influence ordering, not permissions. */
export function quickDiscovery<T extends DiscoveryEntry>(
  entries:readonly T[], indexed:ReadonlyMap<string,string>,rawQuery:string,
  favorites:ReadonlySet<string>,recent:ReadonlySet<string>,limit=6,
  names:ReadonlyMap<string,string>|null=null,
):T[]{
  const query=normalizeExperienceQuery(rawQuery.trim());
  const cap=Number.isInteger(limit)?Math.max(0,Math.min(12,limit)):6;
  if(!cap)return [];
  const candidates:{entry:T;score:number;position:number}[]=[];
  for(let position=0;position<entries.length;position++){
    const entry=entries[position];
    const workflow=entry.workflow;
    if(workflow!=='coco-standalone'&&workflow!=='coco-media')continue;
    const name=names?.get(entry.id)??normalizeExperienceQuery(entry.name);
    const matches=query.length===0||name.includes(query)||Boolean(indexed.get(entry.id)?.includes(query));
    if(!matches)continue;
    const score=(query?(name===query?300:name.startsWith(query)?220:name.includes(query)?150:70):0)+
      (recent.has(entry.id)?22:0)+(favorites.has(entry.id)?14:0)+
      (workflow==='coco-standalone'?1:0);
    // Fixed-size ordered insertion, O(entries*limit), no all-results sort.
    const insert=candidates.findIndex(other=>score>other.score||score===other.score&&position<other.position);
    if(insert<0){if(candidates.length<cap)candidates.push({entry,score,position});}
    else candidates.splice(insert,0,{entry,score,position});
    if(candidates.length>cap)candidates.pop();
    // A blank first-run search with no favorites/recent history has a strict
    // maximum score of 1 (standalone) and the catalog's original tie order.
    // Once the top-k are all games, inspecting thousands more entries cannot
    // change those suggestions. This is especially useful on first Ctrl+K.
    if(!query&&favorites.size===0&&recent.size===0&&candidates.length===cap&&
      candidates[cap-1].score===1)break;
  }
  return candidates.map(candidate=>candidate.entry);
}

/** Cyclic keyboard selection; handles catalog refreshes and empty results. */
export function nextDiscoveryIndex(current:number,key:'ArrowDown'|'ArrowUp',count:number):number{
  if(!Number.isSafeInteger(count)||count<=0)return -1;
  if(key==='ArrowDown')return current<0||current>=count-1?0:current+1;
  return current<0||current>=count?count-1:current===0?count-1:current-1;
}
