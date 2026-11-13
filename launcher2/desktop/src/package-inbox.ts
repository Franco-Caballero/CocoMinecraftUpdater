/** File associations and Win32 handoff are *requests for review* only.
 * Bound the React inbox to the native activation queue's maximum of 96,
 * never silently discard an overflow, and preserve FIFO for unique paths. */
export type PackageInboxState={paths:string[];dropped:number};
export const MAX_PENDING_PACKAGES=96;
// Even an authenticated native request must not make the WebView materialize
// an unbounded array from a malformed/buggy activation event. The native FIFO
// is smaller than this cap. Anything beyond it is visibly counted as overflow
// so legitimate files can be manually reopened rather than silently lost.
export const MAX_BATCH_INSPECT=512;
export const emptyPackageInbox=():PackageInboxState=>({paths:[],dropped:0});

function nativePayloadItems(payload:unknown):unknown[]{
  return typeof payload==='string'?[payload]:Array.isArray(payload)?payload:
    payload&&typeof payload==='object'&&'paths' in payload&&Array.isArray(payload.paths)?payload.paths:
    payload&&typeof payload==='object'&&'path' in payload?[payload.path]:[];
}
export function extractPackagePaths(payload:unknown):string[]{
  const raw=nativePayloadItems(payload),result:string[]=[];
  // Do not use `raw.map` or a giant Set here. Limit work before constructing
  // intermediates; 100k malformed paths are an expected adversarial fixture.
  for(let i=0;i<Math.min(raw.length,MAX_BATCH_INSPECT);i++){
    const item=raw[i];
    const path=typeof item==='string'?item:
      item&&typeof item==='object'&&'path' in item&&typeof item.path==='string'?item.path:null;
    if(path&&path.length<=32767&&!/[\r\n\0]/.test(path))result.push(path);
  }
  return result;
}

export function enqueuePackageRequests(state:PackageInboxState,payload:unknown):PackageInboxState{
  const overLimit=Math.max(0,nativePayloadItems(payload).length-MAX_BATCH_INSPECT);
  const incoming=extractPackagePaths(payload);
  if(!incoming.length&&!overLimit)return state;
  const paths=[...state.paths];
  const seen=new Set(paths);
  let dropped=Math.min(999,state.dropped+overLimit);
  for(const path of incoming){
    if(seen.has(path))continue;
    seen.add(path);
    if(paths.length<MAX_PENDING_PACKAGES)paths.push(path);
    else dropped=Math.min(999,dropped+1);
  }
  return dropped===state.dropped&&paths.length===state.paths.length?state:{paths,dropped};
}

export function dismissPackageRequest(state:PackageInboxState,path:string):PackageInboxState{
  const paths=state.paths.filter(item=>item!==path);
  return paths.length===state.paths.length?state:{...state,paths};
}

export function acknowledgePackageOverflow(state:PackageInboxState):PackageInboxState{
  return state.dropped?{...state,dropped:0}:state;
}
