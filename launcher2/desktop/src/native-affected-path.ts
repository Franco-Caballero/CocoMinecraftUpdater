/** Extract only a path explicitly present in a native error and inside the
 * catalog-registered, Rust-checked game root. Do not guess a Defender event or
 * display arbitrary personal/network paths from untrusted error strings. */
export function affectedRegisteredGamePath(detail:string,registeredRoot:string):string|null{
  if(typeof detail!=='string'||typeof registeredRoot!=='string')return null;
  const root=registeredRoot.replace(/\//g,'\\').replace(/\\+$/,'');
  if(!/^[A-Za-z]:\\/.test(root)||root.length>1024||
    root.split('\\').includes('..')||root.includes('\\\\'))return null;
  // Unquoted Windows error text has no unambiguous filename boundary. Accept
  // quoted paths only; this is diagnostics, never used for filesystem access.
  const quoted=/(['"`])([A-Za-z]:\\[^'"`\r\n<>|?*\u0000-\u001f]{1,1024})\1/g;
  for(const match of detail.matchAll(quoted)){
    const candidate=match[2].replace(/\//g,'\\');
    const segments=candidate.split('\\');
    if(segments.some((segment,index)=>index>0&&(!segment||segment==='.'||segment==='..'||segment.endsWith(' '))))continue;
    if(candidate.toLocaleLowerCase('en-US')===root.toLocaleLowerCase('en-US'))continue;
    if(candidate.slice(0,root.length+1).toLocaleLowerCase('en-US')!==
      (root+'\\').toLocaleLowerCase('en-US'))continue;
    return candidate;
  }
  return null;
}
