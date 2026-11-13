import {MAX_PENDING_PACKAGES,emptyPackageInbox,type PackageInboxState} from './package-inbox';

/** Review-only paths. A native WM_COPYDATA ACK is allowed after React has
 * safely persisted the accepted request; neither persistence nor restoration
 * ever authorizes a package import, install, execution or signed-catalog edit.
 * Stored paths are untrusted and must pass the native package reviewer again.
 */
export const EXPLORER_INBOX_STORAGE_KEY='coco2-explorer-review-inbox-v1';
type InboxStorage={getItem:(key:string)=>string|null;setItem:(key:string,value:string)=>void};
const MAX_PATH_LENGTH=8192;
const MAX_STORAGE_LENGTH=MAX_PENDING_PACKAGES*(MAX_PATH_LENGTH*2+80)+512;

function storageOrNull(provided?:InboxStorage|null):InboxStorage|null{
  if(provided!==undefined)return provided;
  try{return typeof localStorage==='undefined'?null:localStorage;}
  catch{return null;}
}
function validReviewPath(path:unknown):path is string{
  if(typeof path!=='string'||!path||path.length>MAX_PATH_LENGTH||/[\r\n\0]/.test(path))return false;
  // The native canonical file-open receiver allows drive-local, non-reparse
  // paths, including Win32 extended-length names. Reject URLs, relative and
  // UNC paths from corrupted/tampered storage before creating any UI review.
  const ordinary=path.replace(/^\\\\\?\\/,'');
  if(!/^[a-zA-Z]:[\\/]/.test(ordinary))return false;
  const filename=ordinary.split(/[\\/]/).at(-1)||'';
  return filename.length>'x.coco2pack'.length-1&&
    /^[^<>:"|?*\u0000-\u001f]+\.coco2pack(?:\.zip)?$/i.test(filename);
}

/** Reading a persisted inbox does not trust its schema or source. Invalid
 * entries are ignored with bounded work and no native side effects. */
export function readPersistedPackageInbox(provided?:InboxStorage|null):PackageInboxState{
  const store=storageOrNull(provided);
  if(!store)return emptyPackageInbox();
  try{
    const raw=store.getItem(EXPLORER_INBOX_STORAGE_KEY);
    if(!raw||raw.length>MAX_STORAGE_LENGTH)return emptyPackageInbox();
    const saved:unknown=JSON.parse(raw);
    if(!saved||typeof saved!=='object'||!('version' in saved)||saved.version!==1||
      !('paths' in saved)||!Array.isArray(saved.paths))return emptyPackageInbox();
    const paths:string[]=[];const seen=new Set<string>();
    for(const path of saved.paths){
      if(paths.length>=MAX_PENDING_PACKAGES)break;
      if(validReviewPath(path)&&!seen.has(path)){
        paths.push(path);seen.add(path);
      }
    }
    const dropped=('dropped' in saved&&typeof saved.dropped==='number'&&Number.isSafeInteger(saved.dropped)&&
      saved.dropped>=0&&saved.dropped<=999)?saved.dropped:0;
    return {paths,dropped};
  }catch{return emptyPackageInbox();}
}

/** Must complete synchronously BEFORE native ACK. If app storage is disabled,
 * full or inaccessible, return false; native still owns the unconfirmed FIFO
 * and the caller must not acknowledge a receipt that cannot survive restart.
 */
export function persistPackageInbox(inbox:PackageInboxState,provided?:InboxStorage|null):boolean{
  const store=storageOrNull(provided);
  if(!store||!Array.isArray(inbox.paths)||inbox.paths.length>MAX_PENDING_PACKAGES||
    !Number.isSafeInteger(inbox.dropped)||inbox.dropped<0||inbox.dropped>999)return false;
  const seen=new Set<string>();
  for(const path of inbox.paths){
    if(!validReviewPath(path)||seen.has(path))return false;
    seen.add(path);
  }
  try{
    const raw=JSON.stringify({version:1,paths:inbox.paths,dropped:inbox.dropped});
    if(raw.length>MAX_STORAGE_LENGTH)return false;
    store.setItem(EXPLORER_INBOX_STORAGE_KEY,raw);
    return true;
  }catch{return false;}
}
