/** A Win32 process enumeration is an unordered snapshot, not a new user
 * interaction. Keep the previous React array when the same set of registered
 * game IDs is observed, so a 30s read-only safety poll never invalidates the
 * whole grid and its hover media solely due to reordered PIDs. */
export function retainObservedGameIds(previous:readonly string[],incoming:readonly string[]):string[]{
  const fresh=[...new Set(incoming)];
  if(previous.length!==fresh.length)return fresh;
  const existing=new Set(previous);
  return existing.size===fresh.length&&fresh.every(id=>existing.has(id))
    ? previous as string[]:fresh;
}
