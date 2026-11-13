import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { invoke, isTauri } from '@tauri-apps/api/core';
import { open } from '@tauri-apps/plugin-dialog';
import { ArrowRight, Check, CircleAlert, DownloadCloud, FileArchive, FolderOpen, Globe2, LoaderCircle, PackagePlus, RefreshCw, ShieldCheck, X } from 'lucide-react';
import { createPortableReviewGate, isMatchingPortableReview, isPortablePackageFile, portablePackageKind, recipientPackageError, settleAcceptedPortableImport } from './portable-format';
import {ManualPackagePickerGate} from './package-activation-drain';

type ChannelStatus = {
  status:'embedded'|'cached'|'updated'|'degraded'|'offline'|'unchanged'; revision:number;
  localEntries:number; remoteEntries:number; remoteSequence:number; message:string;
};
type LocalPackageReview = {
  id:string; mode:string; oldVersion?:string|null; newVersion:string;
  archiveSha256:string; manifestSha256:string; reviewToken:string;
  sourcePath:string; status:string; name?:string;description?:string;
  coverDataUrl?:string;executable?:string; requiredFilesCount?:number;
  changedFields?:string[]; changeSummary?:string;
};

// Native owns all paths, trust decisions, SHA verification and crash-safe disk
// changes. This UI never treats a file-picker result as an installer manifest.
export default function CatalogHub({onChanged,onImported,compact=false,incomingPath,onInboxDone,pendingCount=1,pickerRequestId=0,onPickerRequestConsumed,hostStudioAvailable=false}:{onChanged:()=>Promise<void>;onImported?:(id:string)=>void;compact?:boolean;incomingPath?:string;onInboxDone?:(path:string)=>void;pendingCount?:number;pickerRequestId?:number;onPickerRequestConsumed?:()=>void;hostStudioAvailable?:boolean}) {
  // An unknown capability is NOT permission. Only the development host can
  // open unsigned local packages; clients receive host-curated catalog data.
  const hostCanImport=hostStudioAvailable===true;
  const hostCanImportNow=useRef(hostCanImport);
  hostCanImportNow.current=hostCanImport;
  const [status,setStatusState]=useState<ChannelStatus|null>(null);
  const [checking,setChecking]=useState(false);
  const [importing,setImporting]=useState(false);
  const [reviewState,setReview]=useState<LocalPackageReview|null>(null);
  const [reviewTicket,setReviewTicket]=useState(0);
  const [sourcePath,setSourcePath]=useState('');
  const [confirmed,setConfirmed]=useState(false);
  const [message,setMessage]=useState('');
  const [error,setError]=useState('');
  const [stage,setStage]=useState<'idle'|'reviewing'|'committing'>('idle');
  const [inboxReplay,setInboxReplay]=useState(0);
  const [pickerOpen,setPickerOpen]=useState(false);
  const reviewGate=useRef(createPortableReviewGate());
  const pendingReview=useRef<number|null>(null);
  const pickerPendingRef=useRef(false) as {current:boolean;owner?:number};
  const syncPendingRef=useRef(false);
  const statusEpoch=useRef(0);
  // Every accepted native catalog update advances the epoch; callers use
  // one setter so late initial status reads cannot undo sync OR import.
  const setStatus=(value:ChannelStatus)=>{
    statusEpoch.current++;
    setStatusState(value);
  };
  const mounted=useRef(true);
  const incomingNow=useRef(incomingPath);
  const reviewFocus=useRef<HTMLDivElement>(null);
  const openPackageButtonRef=useRef<HTMLButtonElement>(null);
  const firstRunPickerGate=useRef(new ManualPackagePickerGate());
  incomingNow.current=incomingPath;
  // Discarded/older previews cannot be used even for one render after the
  // parent's incomingPath changes. A commit already underway remains locked.
  const visibleReview=reviewState&&(!incomingPath||sourcePath===incomingPath)&&
    (reviewGate.current.isReviewed(reviewTicket,sourcePath,reviewState.reviewToken)||
      (stage==='committing'&&reviewGate.current.isCommitting()))?reviewState:null;
  const review=visibleReview;
  useEffect(()=>{
    mounted.current=true;
    return()=>{mounted.current=false;reviewGate.current.discard();};
  },[]);
  useEffect(()=>{if(visibleReview)reviewFocus.current?.focus();},[visibleReview?.reviewToken]);
  useEffect(()=>{
    if(!incomingPath&&!review&&!importing&&!pickerOpen&&
      (message.startsWith('Solicitud descartada')||message.startsWith('Selección cancelada')))
      openPackageButtonRef.current?.focus();
  },[incomingPath,review,importing,pickerOpen,message]);

  const clearReview=()=>{
    setReview(null);setReviewTicket(0);setConfirmed(false);setSourcePath('');
  };
  const discardReview=()=>{
    if(!reviewGate.current.discard())return;
    pendingReview.current=null;
    clearReview();setImporting(false);setStage('idle');setError('');
    setMessage('Solicitud descartada. No se importó ni se ejecutó ningún archivo.'+
      (pickerPendingRef.current?' El selector de Windows puede seguir abierto; ciérralo con Cancelar.':''));
    if(incomingPath){
      try{onInboxDone?.(incomingPath);}catch(error){console.warn('Could not dismiss package request:',error);}
    }
  };
  const handleReviewKeys=(event:KeyboardEvent<HTMLDivElement>)=>{
    if(event.key==='Escape'&&!reviewGate.current.isCommitting()){
      event.preventDefault();event.stopPropagation();discardReview();
    }
  };
  // File association delivery is only a request for read-only verification.
  // Neither launch arguments nor events are permission to import or execute.
  useEffect(()=>{
    if(!incomingPath)return;
    const ticket=reviewGate.current.begin();
    if(ticket===null)return;
    let live=true;
    pendingReview.current=ticket;
    clearReview();setMessage('');setError('');
    setImporting(false);setStage('idle');
    if(!isPortablePackageFile(incomingPath)){
      setError('Este archivo no es un paquete Coco 2. Pide un archivo .coco2pack a quien lo compartió.');
      pendingReview.current=null;
      return()=>{live=false;if(reviewGate.current.isCurrent(ticket))reviewGate.current.discard();};
    }
    if(!isTauri()){
      pendingReview.current=null;
      setError('Abre este paquete desde la aplicación Coco Launcher 2 para Windows.');
      return()=>{live=false;if(reviewGate.current.isCurrent(ticket))reviewGate.current.discard();};
    }
    if(!hostCanImportNow.current){
      // The public Rust command intentionally rejects unsigned local review
      // and import. Do not call it as a speculative read: an Explorer open is
      // not an authorized catalog source. Give an immediate, deterministic
      // explanation and let the user dismiss without opening the archive.
      pendingReview.current=null;
      setMessage('Archivo externo sin aprobación del anfitrión. Coco no lo abrirá ni lo instalará. Tus juegos provienen exclusivamente del catálogo aprobado.');
      return()=>{live=false;if(reviewGate.current.isCurrent(ticket))reviewGate.current.discard();};
    }
    setImporting(true);setStage('reviewing');
    void invoke<LocalPackageReview>('review_local_publish_package',{path:incomingPath})
      .then(result=>{
        if(live&&isMatchingPortableReview(result,incomingPath)&&
          reviewGate.current.accept(ticket,incomingPath,result.reviewToken)){
          setSourcePath(incomingPath);setReview(result);setReviewTicket(ticket);
        }else if(live&&reviewGate.current.isCurrent(ticket)){
          setError('No se recibió una revisión válida. Descarta el archivo o vuelve a comprobarlo.');
        }
      })
      .catch(error=>{
        if(live&&reviewGate.current.isCurrent(ticket))
          setError(recipientPackageError(error,'review'));
      })
      .finally(()=>{
        if(live&&pendingReview.current===ticket){
          pendingReview.current=null;setImporting(false);setStage('idle');
        }
      });
    return()=>{
      live=false;
      if(reviewGate.current.isCurrent(ticket))reviewGate.current.discard();
      if(pendingReview.current===ticket)pendingReview.current=null;
    };
  // When Explorer delivers B while A commits, begin() refuses B. The commit
  // release schedules another read of this request after the native settle.
  },[incomingPath,inboxReplay]);
  useEffect(()=>{
    if(!isTauri())return;
    let active=true;
    const epoch=statusEpoch.current;
    void invoke<ChannelStatus>('get_catalog_channel_status')
      .then(value=>{if(active&&epoch===statusEpoch.current)setStatusState(value);})
      .catch(e=>{if(active&&epoch===statusEpoch.current)setError(String(e));});
    return()=>{active=false;};
  },[]);

  const synchronize=async()=>{
    if(syncPendingRef.current||checking||importing||!isTauri())return;
    syncPendingRef.current=true;
    setChecking(true);setError('');setMessage('');
    try{
      const result=await invoke<ChannelStatus>('sync_catalog_channel');
      // A slower initial status fetch must not roll back the result of a
      // successful explicit sync or a newly committed local package.
      setStatus(result);
      if(result.status==='updated'){
        try{await onChanged();}
        catch{
          // The native sync already committed; a subsequent React/catalog
          // refresh failure must not claim it rolled back or invite a second
          // unnecessary sync. The next catalog view may refresh independently.
          console.warn('Catalog sync accepted; visual refresh unavailable.');
          setMessage('Catálogo sincronizado. No se pudo actualizar la vista automáticamente; vuelve a abrir Juegos para verlo.');
          return;
        }
      }
      setMessage(result.status==='offline'?'Sin conexión. Tu biblioteca está disponible.':result.status==='unchanged'?'Tu biblioteca está al día.':result.message||'Catálogo comprobado. Tus juegos anteriores siguen disponibles.');
    }catch(e){
      setError(`No se pudo sincronizar. Se conserva el catálogo anterior. ${String(e)}`);
    }finally{syncPendingRef.current=false;setChecking(false);}
  };
  const choosePackage=async(legacyFolder=false)=>{
    if(!hostCanImportNow.current||checking||importing||pickerPendingRef.current||pendingReview.current!==null||
      reviewGate.current.isCommitting()||!isTauri())return;
    const ticket=reviewGate.current.begin();
    if(ticket===null)return;
    pendingReview.current=ticket;
    setError('');setMessage('');clearReview();setImporting(true);setStage('reviewing');
    const releasePicker=()=>{
      // A dismissed review may still settle after another picker is opened.
      // Only the ticket that owns the native dialog may release its lock.
      if(pickerPendingRef.owner!==ticket)return;
      delete pickerPendingRef.owner;
      pickerPendingRef.current=false;
      if(mounted.current)setPickerOpen(false);
    };
    try{
      pickerPendingRef.owner=ticket;pickerPendingRef.current=true;setPickerOpen(true);
      const selected=await open(legacyFolder
        ?{directory:true,multiple:false,title:'Elegir carpeta de un paquete antiguo'}
        :{directory:false,multiple:false,title:'Elegir paquete Coco 2',filters:[{name:'Paquete Coco 2',extensions:['coco2pack','zip']}]});
      releasePicker();
      if(!reviewGate.current.isCurrent(ticket))return;
      if(!hostCanImportNow.current)return;
      if(typeof selected!=='string'){
        setMessage('Selección cancelada. No se realizó ninguna importación.');
        return;
      }
      if(!legacyFolder&&!isPortablePackageFile(selected)){
        setError('Selecciona un archivo .coco2pack o uno antiguo .coco2pack.zip. No se aceptan ZIP genéricos.');
        return;
      }
      const result=await invoke<LocalPackageReview>('review_local_publish_package',{path:selected});
      if(hostCanImportNow.current&&isMatchingPortableReview(result,selected)&&
        reviewGate.current.accept(ticket,selected,result.reviewToken)){
        setSourcePath(selected);setReview(result);setReviewTicket(ticket);
      }else if(reviewGate.current.isCurrent(ticket)){
        setError('No se recibió una revisión válida. Selecciona el paquete nuevamente.');
      }
    }catch(e){
      if(reviewGate.current.isCurrent(ticket))
        setError(`No se modificó tu biblioteca. ${recipientPackageError(e,'review')}`);
    }finally{
      releasePicker();
      if(pendingReview.current===ticket){
        pendingReview.current=null;setImporting(false);setStage('idle');
      }
    }
  };
  // Human clicked "Recibí un paquete" in the welcome screen. Open only the
  // native file selector, never auto-review/import without a chosen path and
  // never auto-commit after review. Native Explorer requests take priority.
  useEffect(()=>{
    if(!firstRunPickerGate.current.consume(pickerRequestId))return;
    onPickerRequestConsumed?.();
    if(!hostCanImportNow.current||incomingPath||!isTauri())return;
    void choosePackage();
  },[pickerRequestId,incomingPath]);
  const retryIncomingReview=async()=>{
    if(!hostCanImportNow.current||!incomingPath||!isPortablePackageFile(incomingPath)||pendingReview.current!==null||
      reviewGate.current.isCommitting()||!isTauri())return;
    const ticket=reviewGate.current.begin();
    if(ticket===null)return;
    pendingReview.current=ticket;
    clearReview();setError('');setMessage('');setImporting(true);setStage('reviewing');
    try{
      const checked=await invoke<LocalPackageReview>('review_local_publish_package',{path:incomingPath});
      if(mounted.current&&incomingNow.current===incomingPath&&
        isMatchingPortableReview(checked,incomingPath)&&
        reviewGate.current.accept(ticket,incomingPath,checked.reviewToken)){
        setSourcePath(incomingPath);setReview(checked);setReviewTicket(ticket);
      }else if(mounted.current&&incomingNow.current===incomingPath&&
        reviewGate.current.isCurrent(ticket)){
        setError('No se recibió una revisión válida. Puedes descartar este paquete.');
      }
    }catch(error){
      if(mounted.current&&reviewGate.current.isCurrent(ticket)&&incomingNow.current===incomingPath)
        setError(recipientPackageError(error,'review'));
    }finally{
      if(mounted.current&&pendingReview.current===ticket){
        pendingReview.current=null;setImporting(false);setStage('idle');
      }
    }
  };
  const confirmImport=async()=>{
    if(!hostCanImportNow.current||!review||!confirmed||checking||importing||!isTauri()||
      (incomingPath!==undefined&&sourcePath!==incomingPath)||
      !reviewGate.current.beginCommit(reviewTicket,sourcePath,review.reviewToken))return;
    setImporting(true);setStage('committing');setError('');
    const importedId=review.id;
    const committedPath=sourcePath;
    const wasInbox=incomingPath===committedPath;
    try{
      const result=await invoke<ChannelStatus>('import_local_publish_package',{
        path:sourcePath,reviewToken:review.reviewToken,confirmed:true,
      });
      if(result.status!=='updated'&&result.status!=='unchanged'){
        if(mounted.current&&
          (incomingNow.current===committedPath||(!wasInbox&&!incomingNow.current))){
          setReview(null);setConfirmed(false);
          setError('La aplicación no confirmó la incorporación. Revisa de nuevo el paquete antes de intentar otra vez.');
        }
        return;
      }
      const outcome=await settleAcceptedPortableImport(
        result,
        ()=>onChanged(),
        ()=>{
          // Explorer may queue B while A is committing. Never navigate to
          // A's details on B, but do retain A's successfully committed data.
          if(mounted.current&&
            (incomingNow.current===committedPath||(!wasInbox&&!incomingNow.current))){
            try{onImported?.(importedId);}catch(error){console.warn('Accepted package details callback failed:',error);}
          }
        },
        ()=>{
          if(wasInbox){
            try{onInboxDone?.(committedPath);}catch(error){console.warn('Accepted inbox callback failed:',error);}
          }
        },
        (where,error)=>console.warn('Accepted package '+where+' callback failed:',error)
      );
      if(!mounted.current)return;
      if(!outcome){
        setReview(null);setConfirmed(false);
        if(incomingNow.current===committedPath||(!wasInbox&&!incomingNow.current))
          setError('La aplicación no confirmó la incorporación. Revisa de nuevo el paquete antes de intentar otra vez.');
        return;
      }
      setStatus(result);setReview(null);setConfirmed(false);
      if(incomingNow.current===committedPath||(!wasInbox&&!incomingNow.current))
        setMessage(result.status==='unchanged'?'Sin cambios. Ya tienes esta versión comprobada.':'Experiencia añadida. Puedes instalarla o consultar sus archivos.');
    }catch(e){
      if(mounted.current&&
        (incomingNow.current===committedPath||(!wasInbox&&!incomingNow.current))){
        setReview(null);setConfirmed(false);
        setError(`Importación detenida. ${recipientPackageError(e,'import')} Revisa de nuevo antes de aceptar.`);
      }
    }finally{
      reviewGate.current.finishCommit();
      if(mounted.current){
        setImporting(false);setStage('idle');
        if(wasInbox&&incomingNow.current&&incomingNow.current!==sourcePath)
          setInboxReplay(value=>value+1);
      }
    }
  };

  return <section className={`catalog-hub ${compact?'catalog-hub-compact':''} ${incomingPath?'catalog-hub-incoming':''}`} aria-label="Catálogo de experiencias">
    <div className="catalog-hub-head"><span className="catalog-hub-icon">{incomingPath?<FileArchive size={21}/>:<Globe2 size={20}/>}</span><div><span className="eyebrow">{incomingPath?'PAQUETE RECIBIDO':'BIBLIOTECA VIVA'}</span><strong>{incomingPath?'Coco recibió un paquete':!hostCanImport?'Juegos aprobados por el anfitrión':compact?'Revisar juegos locales del anfitrión':'Más juegos, sin reinstalar Coco.'}</strong><small>{incomingPath?`${pendingCount>1?`${pendingCount} paquetes pendientes · `:''}${hostCanImport?'Revisa su origen y contenido antes de aceptarlo.':'Puedes revisar este archivo, pero solo el anfitrión aprueba juegos para el catálogo.'}`:!hostCanImport?'Coco conserva el catálogo incluido y recibe actualizaciones oficiales verificadas con firma Ed25519. No puedes añadir paquetes locales.':compact?'Abre aquí un paquete local del anfitrión.':'El catálogo local permanece disponible sin conexión.'}</small></div></div>
    <div className="catalog-hub-actions">
      {incomingPath?<button className="filter-button catalog-inbox-dismiss" disabled={stage==='committing'} onClick={discardReview}><X size={16}/> {stage==='reviewing'?'Descartar solicitud':'Ahora no'}</button>:<>
        {!compact&&<button className="filter-button" disabled={!isTauri()||checking||importing} onClick={()=>void synchronize()}>{checking?<LoaderCircle size={15} className="spin"/>:<RefreshCw size={15}/>} {checking?'Sincronizando…':'Sincronizar'}</button>}
        {hostCanImport&&<button ref={openPackageButtonRef} className="filter-button catalog-import" disabled={!isTauri()||checking||importing||pickerOpen} onClick={()=>void choosePackage()}>{importing?<LoaderCircle size={15} className="spin"/>:<FileArchive size={16}/>} {stage==='reviewing'?'Revisando…':stage==='committing'?'Incorporando…':'Abrir paquete Coco'}</button>}
        {hostCanImport&&stage==='reviewing'&&<button className="filter-button" onClick={discardReview}><X size={14}/> Cancelar revisión</button>}
        {hostCanImport&&pickerOpen&&<p role="status" aria-live="polite">Si descartas la solicitud, cierra también el selector de Windows con Cancelar. No se importará el archivo.</p>}
        {hostCanImport&&!compact&&<details className="catalog-legacy-import"><summary>Paquete anterior</summary><button className="filter-button" disabled={!isTauri()||checking||importing} onClick={()=>void choosePackage(true)}><FolderOpen size={14}/> Elegir carpeta</button></details>}
      </>}
    </div>
    {incomingPath&&importing&&stage==='reviewing'&&<div className="catalog-inbox-progress" role="status"><LoaderCircle size={18} className="spin"/> Verificando el paquete sin incorporarlo…</div>}
    {stage==='committing'&&<p className="catalog-trust-note" role="status" aria-live="polite"><LoaderCircle size={16} className="spin"/> Incorporando la copia autorizada. Este paso no se puede interrumpir con seguridad.</p>}
    {review&&<div className="catalog-package-preview" role="dialog" aria-label={hostCanImport?'Confirmar importación local':'Revisión de paquete sin importar'} onKeyDown={handleReviewKeys} tabIndex={-1} ref={reviewFocus}>
      <div className="catalog-package-title"><PackagePlus size={18}/><strong>{hostCanImport?'Revisar antes de incorporar':'Revisión informativa del paquete'}</strong><span>{!hostCanImport?'No aprobado':review.status==='unchanged'?'Ya disponible':review.mode==='update'?'Nueva versión':'Juego nuevo'}</span><button aria-label="Cerrar revisión sin importar" disabled={importing} onClick={discardReview}><X size={16}/></button></div>
      <div className="catalog-preview-body">
        {review.coverDataUrl?.startsWith('data:image/')&&<img className="catalog-preview-art" alt={`Portada de ${review.name||review.id}`} src={review.coverDataUrl}/>}
        <div className="catalog-preview-info"><strong>{review.name||review.id}</strong><span className="catalog-version-pill">{review.mode==='update'?`${review.oldVersion||'Antes'} → ${review.newVersion}`:`Versión ${review.newVersion}`}</span>
          {review.description&&<p>{review.description}</p>}
          <div className="catalog-review-tags"><span><ShieldCheck size={13}/> {hostCanImport?'Comprobado localmente':'Archivo externo · Sin aprobación'}</span>{typeof review.requiredFilesCount==='number'&&<span>{review.requiredFilesCount} archivos esenciales</span>}<span>{portablePackageKind(sourcePath)==='legacy'?'Formato anterior .coco2pack.zip':portablePackageKind(sourcePath)==='coco2pack'?'Archivo .coco2pack':'Carpeta de paquete anterior'}</span></div>
          {review.executable&&<details><summary>Información del ejecutable</summary><p>{review.executable}</p></details>}
          {review.changeSummary&&<p>{review.changeSummary}</p>}
          {review.changedFields&&review.changedFields.length>0&&<details><summary>Cambios de esta versión</summary><p>{review.changedFields.slice(0,12).join(' · ')}</p></details>}
        </div>
      </div>
      <p className="catalog-trust-note"><CircleAlert size={15}/> {hostCanImport?'Compartido por otra persona. No equivale a un juego del canal oficial firmado. Puedes descartarlo sin modificar la biblioteca. Añadirlo no ejecuta el juego ni modifica instalaciones existentes.':'Este archivo no demuestra aprobación del anfitrión. Solo el anfitrión puede agregar juegos al catálogo firmado. Revisarlo no permite instalarlo ni incorporarlo a tu biblioteca.'}</p>
      {hostCanImport&&<label className="catalog-consent"><input type="checkbox" checked={confirmed} disabled={importing} onChange={event=>setConfirmed(event.target.checked)}/> Revisé el nombre, la versión y el origen. Confío en quien compartió este paquete y quiero añadirlo a mi biblioteca.</label>}
      {hostCanImport&&<button className="primary-button" disabled={!confirmed||importing} onClick={()=>void confirmImport()}><ShieldCheck size={16}/>{importing?'Comprobando y guardando…':review.status==='unchanged'?'Ver juego en mi biblioteca':'Añadir y ver juego'}<ArrowRight size={14}/></button>}
      {!importing&&<button className="filter-button catalog-inbox-dismiss" onClick={discardReview}><X size={14}/> Descartar sin importar</button>}
    </div>}
    {message&&<p className="catalog-message" role="status"><Check size={15}/>{message}</p>}
    {error&&<p className="catalog-error" role="alert"><CircleAlert size={15}/>{error}</p>}
    {error&&incomingPath&&!review&&!importing&&isPortablePackageFile(incomingPath)&&<button className="filter-button" onClick={()=>void retryIncomingReview()}><RefreshCw size={14}/> Volver a revisar</button>}
    {status&&<div className="catalog-source"><DownloadCloud size={13}/>{status.status==='embedded'?'Biblioteca incluida':status.status==='cached'?'Biblioteca guardada':status.status==='updated'||status.status==='unchanged'?'Biblioteca comprobada':'Sin conexión: biblioteca disponible'}{status.localEntries+status.remoteEntries>0?` · ${status.localEntries+status.remoteEntries} experiencias añadidas`:''}</div>}
  </section>;
}
