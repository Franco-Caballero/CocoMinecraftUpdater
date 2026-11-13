/** UX-only fast rejection for file-picker input. Security and provenance are
 * always rechecked by the native Rust ZIP reviewer before any import. */
export function isPortablePackageFile(path:string):boolean{
  const filename=path.split(/[\\/]/).at(-1)||'';
  return path.length>0&&path.length<=32767&&!/[\0\r\n]/.test(path)&&
    filename.length>'x.coco2pack'.length-1&&
    /^[^<>:"|?*\u0000-\u001f]+\.coco2pack(?:\.zip)?$/i.test(filename);
}

/** The dialog can display .zip files for compatibility; it must never pass
 * an arbitrary ZIP to the native reviewer. Use only one of these two names. */
export function portablePackageKind(path:string):'coco2pack'|'legacy'|null{
  if(!isPortablePackageFile(path))return null;
  return /\.coco2pack\.zip$/i.test(path)?'legacy':'coco2pack';
}

export function recipientPackageError(error:unknown,stage:'review'|'import'):string{
  const details=String(error).toLowerCase();
  if(/not found|missing|does not exist|cannot open|access denied|permission|os error 2|os error 5/.test(details))
    return 'El archivo ya no está disponible o no se puede leer. Pide otra copia o elige el archivo nuevamente.';
  if(/stale|changed|mismatch|review token|invalid token|expired/.test(details))
    return 'El paquete cambió después de revisarlo. Por seguridad, vuelve a seleccionarlo y revisarlo.';
  if(/zip|archive|manifest|checksum|sha|invalid|unsupported|format|signature/.test(details))
    return 'El paquete no pasó la comprobación de seguridad o tiene un formato incompatible. Solicita una copia nueva.';
  if(/disk|space|full|os error 112|os error 28/.test(details))
    return 'No hay espacio suficiente para guardar la experiencia en la biblioteca.';
  return stage==='review'
    ? 'No fue posible revisar este paquete. Tu biblioteca sigue intacta; intenta seleccionarlo otra vez.'
    : 'No se pudo incorporar este paquete. Revisa nuevamente el archivo antes de volver a intentar.';
}

/** Windows native review returns a canonical \\?\C:\... path. The preview
 * must still refer to the exact selection (or legacy folder) that launched
 * the review; a valid-looking token alone is not UI proof of that identity. */
export function isMatchingPortableReview(
  review:{sourcePath?:string;reviewToken?:string;id?:string;newVersion?:string;status?:string}|null,
  requestedPath:string
):boolean{
  if(!review||typeof requestedPath!=='string'||!requestedPath||
    typeof review.sourcePath!=='string'||!review.sourcePath||
    typeof review.reviewToken!=='string'||!review.reviewToken.trim()||
    typeof review.id!=='string'||!review.id.trim()||
    typeof review.newVersion!=='string'||!review.newVersion.trim()||
    (review.status!=='ready-for-review'&&review.status!=='unchanged'))return false;
  const canonical=(path:string)=>path.replace(/^\\\\\?\\/,'').replace(/\//g,'\\').toLowerCase();
  return canonical(requestedPath)===canonical(review.sourcePath);
}

/** Native commit is irreversible. Even if a warm Explorer activation changes
 * the visible request or React unmounts during the await, the successful
 * commit still needs its catalog refresh and acknowledgement exactly once.
 * Navigation is decided by the caller using the CURRENT visible request. */
export async function settleAcceptedPortableImport(
  result:{status:string}|null,
  refresh:()=>Promise<void>,
  openDetails:()=>void,
  acknowledge:()=>void,
  onCallbackError:(stage:'refresh'|'open'|'ack',error:unknown)=>void
):Promise<'updated'|'unchanged'|null>{
  if(result?.status!=='updated'&&result?.status!=='unchanged')return null;
  if(result.status==='updated'){
    try{await refresh();}catch(error){onCallbackError('refresh',error);}
  }
  try{openDetails();}catch(error){onCallbackError('open',error);}
  try{acknowledge();}catch(error){onCallbackError('ack',error);}
  return result.status;
}

/** Revision fence used across native dialogs and in-flight Rust promises.
 * A token is valid only for the exact path and review returned by Rust.
 * Committing is exclusive and cannot be canceled by a late UI event. */
export function createPortableReviewGate(){
  let generation=0;
  let accepted:{generation:number;path:string;token:string}|null=null;
  let committing=false;
  return {
    begin():number|null{
      if(committing)return null;
      accepted=null;
      return ++generation;
    },
    isCurrent(ticket:number):boolean{
      return !committing&&ticket===generation;
    },
    accept(ticket:number,path:string,token:string):boolean{
      if(!this.isCurrent(ticket)||typeof path!=='string'||!path||
        typeof token!=='string'||!token.trim())return false;
      accepted={generation:ticket,path,token};
      return true;
    },
    isReviewed(ticket:number,path:string,token:string):boolean{
      return !committing&&ticket===generation&&accepted?.generation===ticket&&
        accepted.path===path&&accepted.token===token;
    },
    beginCommit(ticket:number,path:string,token:string):boolean{
      if(!this.isReviewed(ticket,path,token))return false;
      committing=true;
      return true;
    },
    finishCommit():void{
      if(!committing)return;
      committing=false;
      accepted=null;
      ++generation;
    },
    discard():boolean{
      if(committing)return false;
      accepted=null;
      ++generation;
      return true;
    },
    isCommitting():boolean{return committing;}
  };
}
