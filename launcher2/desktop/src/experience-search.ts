/** Search keys are built once per verified catalog revision, not on each keystroke. */
export type SearchableExperience={id:string;name:string;description:string};

export const normalizeExperienceQuery=(value:string):string=>
  value.toLocaleLowerCase('es').normalize('NFD').replace(/[\u0300-\u036f]/g,'');

export function indexExperiences<T extends SearchableExperience>(
  entries:readonly T[],metadata:(entry:T)=>string,
):ReadonlyMap<string,string>{
  return new Map(entries.map(entry=>[
    entry.id,normalizeExperienceQuery(`${entry.name} ${entry.description} ${metadata(entry)}`),
  ]));
}

export function matchesExperienceQuery(index:ReadonlyMap<string,string>,id:string,query:string):boolean{
  return !query || (index.get(id)?.includes(query)??false);
}

export const EXPERIENCE_PAGE_SIZE=48;
export const nextExperiencePage=(current:number,total:number):number=>
  Math.min(total,Math.max(0,current)+EXPERIENCE_PAGE_SIZE);
