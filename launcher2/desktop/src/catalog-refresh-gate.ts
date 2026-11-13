/** Native get_catalog is the authority for visible entries. Optional disk
 * probes (presence, provenance) may take seconds or fail independently.
 * Results from an older overlapping refresh never restore stale entries or
 * badges after a newer signed/local catalog revision is accepted. */
export class CatalogRefreshGate {
  private revision=0;

  begin():number{return ++this.revision;}
  current(ticket:number):boolean{return ticket===this.revision;}
  /** Capture read-only revision when starting optional native work. */
  snapshot():number{return this.revision;}
  invalidate():void{this.revision++;}
}

/** Commit the verified catalog immediately, then enrich asynchronously.
 * `enrich` errors do not revert an accepted import or defer the first card.
 * Keeps the same ticket for all fields; a later refresh supersedes all of them. */
export async function publishVerifiedCatalog<T>(
  gate:CatalogRefreshGate,
  read:()=>Promise<readonly T[]>,
  valid:(entries:readonly T[])=>boolean,
  paint:(entries:readonly T[])=>void|Promise<void>,
  enrich:(isCurrent:()=>boolean)=>Promise<void>,
):Promise<boolean>{
  const ticket=gate.begin();
  const entries=await read();
  if(!gate.current(ticket))return false;
  if(!valid(entries))throw new Error('Catálogo nativo inválido');
  // A paint may run inside a view transition: enrichment waits until the new cards exist.
  await paint(entries);
  // Starts after the trusted catalog is ready. Independent read-only hints
  // should never delay a successful import, navigation, or catalogue paint.
  void enrich(()=>gate.current(ticket)).catch(error=>console.warn('Optional catalog hints unavailable:',error));
  return true;
}
