import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { open, save } from '@tauri-apps/plugin-dialog';
import { Archive, ArrowRight, Check, CircleAlert, ClipboardCheck, Copy, FileArchive, FolderOpen, LoaderCircle, PackagePlus, ShieldCheck, X } from 'lucide-react';
import { isMatchingPortableReview } from './portable-format';
import './host-studio-v9.css';

type Inspection = {suggestedId:string;suggestedName:string;executables:string[];filesCount:number;uncompressedBytes:number;archiveSize:number;sha256:string};
type Draft = {id:string;draftPath:string;catalogCandidatePath:string;sourceLockPath:string;coverPath:string;requiredFilesCount:number;archiveSha256:string;nextAction:string};
type PromotionReview = {id:string;name:string;version:string;catalogSha256:string;archiveSha256:string;archiveSize:number;requiredFilesCount:number;sourceZipPath:string;sourceArchiveUrl:string;coverTarget:string;lockTarget:string;catalogTarget:string;status:string};
type PromotionResult = {id:string;status:string;catalogSha256Before:string;catalogSha256After:string;catalogPath:string;sourceLockPath:string;coverPath:string};
type PublishPreview = {id:string;mode:'new'|'update';oldVersion?:string|null;newVersion:string;sourceCatalogSha256:string;archiveSha256:string;archiveSize:number;previewSha256:string;catalogDiff:string;status:string};
type PublishArtifact = {id:string;mode:string;artifactPath:string;archivePath:string;manifestPath:string;catalogPath:string;lockPath:string;coverPath:string;archiveSha256:string;artifactSha256:string;status:string};
type PublishProgress = {id:string;phase:'preflight'|'copying'|'verifying'|'rechecking'|'sealing'|'complete'|'error';processedBytes:number;totalBytes:number;percent:number|null};
type LocalPackageReview = {id:string;mode:string;oldVersion?:string|null;newVersion:string;archiveSha256:string;manifestSha256:string;reviewToken:string;sourcePath:string;status:string};
type ChannelDraft = {id:string;sequence:number;entries:number;channelDraftPath:string;signaturePath:string;channelSha256:string;sourceManifestSha256:string;releaseCatalogUrl:string;releaseSignatureUrl:string;status:string;reviewNote:string;readyForSignature:boolean;archivePath:string;publicationAssets:{name:string;localPath:string;expectedUrl:string;sha256:string;size:number;uploaded:boolean}[]};
type PortableExport = {id:string;path:string;size:number;sha256:string;status:string};
type ChannelDeliveryReview = {id:string;sequence:number;draftPath:string;channelSha256:string;sourceSnapshotSha256?:string|null;provenance:string;status:'invalid'|'unsigned'|'signature-invalid'|'signed-local'|'remote-verified'|'stale'|string;signatureTrusted:boolean;readyForSignature:boolean;readyForUpload:boolean;allRemoteVerified:boolean;remoteChecked:boolean;assets:{name:string;expectedUrl:string;expectedSha256?:string|null;expectedSize?:number|null;presentLocal:boolean;verifiedLocal:boolean;remoteAvailable:boolean;message:string}[];issues:string[]};

// A shareable delivery has exactly one extension. The backend still validates
// the absolute destination and prevents overwrites; these helpers only give
// the host useful labels before calling the native Save As dialog.
export function suggestedPortableFileName(id:string,version:string):string {
  const base=[id,version].map(part=>part.normalize('NFKD')
    .replace(/[^A-Za-z0-9._-]/g,'-').replace(/^[._-]+|[._-]+$/g,'').slice(0,48))
    .filter(Boolean).join('-')||'experiencia-coco';
  return `${base}.coco2pack`;
}

export function isPortableSavePath(path:string):boolean {
  const filename=path.split(/[\\/]/).at(-1)||'';
  return filename.length>'x.coco2pack'.length-1
    && filename.toLowerCase().endsWith('.coco2pack')
    && !/[<>:"/\\|?*\u0000-\u001f]/.test(filename)
    && !/[. ]$/.test(filename);
}

/** UX preflight for Windows Save As. Rust still authoritatively validates
 * normalized paths, reparse points, destination ownership and no-replace. */
export function isLocalPortableSavePath(path:string):boolean {
  if(!isPortableSavePath(path))return false;
  const local=path.replace(/\//g,'\\');
  if(!/^[A-Za-z]:\\/.test(local))return false;
  const segments=local.slice(3).split('\\');
  return segments.length>0&&segments.every(part=>
    part.length>0&&part!=='.'&&part!=='..'&&
    !/[<>:"|?*\u0000-\u001f]/.test(part)&&
    !/[. ]$/.test(part));
}

/** The native response is a receipt, not permission to claim that any
 * similarly named file was exported. Windows canonicalize can add \\?\
 * to an otherwise identical local path; do not accept another file, ID,
 * size or status. A mismatch is ambiguous, NEVER automatically retry. */
export function isConfirmedPortableExport(receipt:PortableExport,id:string,selectedPath:string):boolean {
  if(!receipt||receipt.id!==id||receipt.status!=='exported-local-untrusted-unpublished'||
    !Number.isSafeInteger(receipt.size)||receipt.size<=0||
    !isLocalPortableSavePath(selectedPath)||typeof receipt.path!=='string')return false;
  const canonical=receipt.path.replace(/^\\\\\?\\/,'');
  return isLocalPortableSavePath(canonical)&&
    canonical.replace(/\//g,'\\').toLowerCase()===
      selectedPath.replace(/\//g,'\\').toLowerCase();
}

export function portableExportError(error:unknown,step:'picker'|'export'):string {
  const detail=String(error).toLowerCase();
  if(/already exists|already exported|never overwrite|file exists|ya existe/.test(detail))
    return 'Ya existe un archivo con ese nombre. Elige otro nombre o carpeta: Coco no reemplaza archivos anteriores.';
  if(/no space|not enough space|disk full|space budget|os error 112|os error 28/.test(detail))
    return 'No hay espacio suficiente en esa unidad. Elige otra carpeta o libera espacio.';
  if(/directory does not exist|parent is not a directory|cannot export inside|path not found|symlink|reparse point/.test(detail))
    return 'La carpeta elegida no está disponible o no es adecuada. Selecciona otra carpeta local.';
  if(/permission|access.denied|os error 5|readonly|read.only|cannot create|cannot stage|cannot persist/.test(detail))
    return 'No se puede escribir en esa carpeta. Elige una ubicación local con permisos de escritura.';
  if(/destination|filename|must use|local file|absolute|unc|device paths|normalized|invalid path/.test(detail))
    return 'Elige una carpeta de tu equipo y un nombre terminado en .coco2pack.';
  if(/changed|missing|verification|verify|hash|sealed|stale|archive|source package/.test(detail))
    return 'El paquete preparado cambió o ya no está disponible. Revisa la preparación antes de intentar guardarlo.';
  return step==='picker'
    ? 'No pude abrir Guardar como. Vuelve a intentarlo desde Host Studio.'
    : 'No pude completar la copia. Revisa el destino y prueba con otro nombre o carpeta.';
}

export function portableFriendMessage(path:string):string {
  const filename=path.split(/[\\/]/).at(-1)||'paquete.coco2pack';
  return `Te comparto ${filename}. Instala Coco Launcher 2, abre el archivo con doble clic o entra en Juegos → Abrir paquete Coco. Revisa el contenido y acepta añadirlo a tu biblioteca. No necesitas extraer el archivo.`;
}

/** A native operation cannot be canceled after Rust starts writing.
 * Invalidate its UI ticket immediately, then honor close/new only on settle.
 * This also fences late file-picker, inspection and clipboard results. */
export function createHostStudioFlowGate(){
  let serial=0;
  let active:number|null=null;
  let deferred:'close'|'new'|null=null;
  let disposed=false;
  return {
    begin():number|null{
      if(disposed||active!==null)return null;
      active=++serial;
      return active;
    },
    owns(ticket:number):boolean{
      return !disposed&&active===ticket&&serial===ticket&&deferred===null;
    },
    request(action:'close'|'new'):boolean{
      if(disposed)return false;
      ++serial;
      if(active!==null){deferred=action;return false;}
      return true;
    },
    finish(ticket:number):'close'|'new'|null{
      if(active!==ticket)return null;
      active=null;
      const next=deferred;
      deferred=null;
      return disposed?null:next;
    },
    isActive():boolean{return active!==null;},
    isLive():boolean{return !disposed;},
    revision():number{return serial;},
    isRevision(revision:number):boolean{return !disposed&&serial===revision;},
    dispose():void{disposed=true;++serial;deferred=null;}
  };
}

export function hostStudioOperationError(error:unknown,stage:'inspect'|'draft'|'review'|'prepare'|'advanced'):string{
  const detail=String(error).toLowerCase();
  if(/already exists|duplicate|never overwrite/.test(detail))
    return 'Ya existe una preparación con esos datos. Cambia el identificador o selecciona otro juego; no se reemplazó nada.';
  if(/cannot open|not found|missing|does not exist|permission|access denied/.test(detail))
    return 'No puedo leer uno de los archivos elegidos. Comprueba que siga disponible y vuelve a intentarlo.';
  if(/changed|stale|mismatch|integrity|sha|verification|verify/.test(detail))
    return 'El contenido cambió desde la última comprobación. Revisa de nuevo el ZIP antes de continuar.';
  if(/invalid|unsafe|unsupported|zip|archive|executable|empty/.test(detail))
    return 'El archivo no cumple los requisitos para crear un paquete Coco. Revisa el ZIP y el ejecutable.';
  if(/disk full|no space|not enough space|os error 112|os error 28/.test(detail))
    return 'Falta espacio libre para preparar este juego. Comprueba la unidad y vuelve a intentarlo.';
  if(stage==='inspect')return 'No pude revisar este ZIP. Elige un ZIP válido y vuelve a intentarlo.';
  if(stage==='draft')return 'No pude crear el borrador. Comprueba el nombre, la versión y los archivos elegidos.';
  if(stage==='review')return 'No se completó la revisión. Los archivos existentes permanecen intactos.';
  if(stage==='prepare')return 'No se pudo preparar el paquete local. No se publicó ni se envió nada.';
  return 'No se pudo completar esta operación del host. No se publicó ningún archivo.';
}

export function suggestedFutureZipName(path:string):string{
  const original=(path.split(/[\\/]/).at(-1)||'juego').replace(/\.zip$/i,'');
  const safe=original.normalize('NFKD').replace(/[^A-Za-z0-9._-]/g,'-')
    .replace(/^[._-]+|[._-]+$/g,'').slice(0,120)||'juego';
  return `${safe}.zip`;
}

/** ZIP is required. The cover is optional: Rust generates a neutral original
 * PNG if the host did not choose an image, without claiming real game art. */
export function classifyStudioSelection(selected:string|string[]|null):{
  zip:string;cover:string;error:string
}{
  if(!selected)return {zip:'',cover:'',error:''};
  const files=typeof selected==='string'?[selected]:selected;
  if(!Array.isArray(files)||files.length<1||files.length>2||
    files.some(path=>typeof path!=='string'||!path.trim()||
      /[\0\r\n]/.test(path)||path.length>32767))
    return {zip:'',cover:'',error:'Selecciona un ZIP y, si quieres, una portada de imagen.'};
  const zipFiles=files.filter(path=>/\.zip$/i.test(path));
  const covers=files.filter(path=>/\.(png|jpe?g|webp)$/i.test(path));
  if(zipFiles.length!==1||covers.length>1||zipFiles.length+covers.length!==files.length)
    return {zip:'',cover:'',error:'Elige exactamente un ZIP; puedes acompañarlo con una portada PNG, JPG o WebP.'};
  return {zip:zipFiles[0],cover:covers[0]||'',error:''};
}

/** Ranking only; this helper never launches a game. Prefer its main binary
 * over setup, uninstall and runtime prerequisite executables. */
export function suggestStudioExecutable(paths:string[],zipPath:string):string{
  if(!Array.isArray(paths)||!paths.length)return '';
  const stem=(value:string)=>value.split(/[\\/]/).at(-1)?.replace(/\.(exe|zip)$/i,'')
    .normalize('NFKD').toLowerCase().replace(/[^a-z0-9]/g,'')||'';
  const zipStem=stem(zipPath);
  const viable=paths.filter(path=>typeof path==='string'&&/\.exe$/i.test(path));
  const ranked=viable.map((path,index)=>{
    const base=stem(path);
    const leaf=path.split(/[\\/]/).at(-1)?.toLowerCase()||'';
    const risky=/(^|[-_. ])(?:unins|uninstall|setup|install|redist|vcredist|dxsetup|crashreport|updater|patcher)(?:[-_. 0-9]|$)/i.test(leaf);
    const same=Boolean(zipStem)&&base===zipStem;
    const contains=Boolean(zipStem)&&base.includes(zipStem);
    const depth=(path.match(/[\\/]/g)||[]).length;
    return {path,index,score:(risky?-150:0)+(same?100:contains?30:0)+
      (/(?:game|launcher|main)\.exe$/i.test(leaf)?15:0)-depth*3};
  }).sort((a,b)=>b.score-a.score||a.index-b.index);
  return ranked[0]&&ranked[0].score>-100?ranked[0].path:'';
}

/** Auto-detection is only a suggestion. A human must explicitly confirm the
 * exact executable *and* the SHA of the ZIP that was actually inspected.
 * Choosing another executable or another archive invalidates that consent.
 * Rust still independently checks the chosen executable inside the archive. */
export function studioExecutableReviewKey(archiveSha256:string,executable:string):string{
  return archiveSha256&&executable?`${archiveSha256.toLowerCase()}\u0000${executable}`:'';
}
export function isStudioExecutableReviewed(
  inspection:{sha256:string;executables:string[]}|null,executable:string,reviewKey:string
):boolean{
  return Boolean(inspection&&executable&&inspection.executables.includes(executable)&&
    reviewKey&&reviewKey===studioExecutableReviewKey(inspection.sha256,executable));
}
export function studioExecutableWarning(path:string):string{
  const leaf=path.split(/[\\/]/).at(-1)||'';
  if(/(?:^|[-_. ])(?:uninstall|unins\w*|setup|install|vcredist|redist|dxsetup|crashreport|updater|patcher)(?:[-_. 0-9]|$)/i.test(leaf))
    return 'Este archivo parece un instalador, desinstalador o herramienta auxiliar. Confirma el ejecutable correcto antes de compartir.';
  return 'Comprueba que al abrir este archivo se inicia el juego, no un instalador ni un programa auxiliar.';
}

/** Actionable checklist rather than exposing hash, paths and future URL. */
export function studioMissingItems(input:{
  zip:string;cover:string;executable:string;name:string;id:string;version:string;urlValid:boolean
}):string[]{
  const missing:string[]=[];
  if(!input.zip)missing.push('ZIP');
  if(!input.name.trim()||!input.id.trim()||!input.version.trim()||!input.urlValid)
    missing.push('datos del juego');
  if(!input.executable)missing.push('ejecutable principal');
  return missing;
}

/** A successful draft is enough to start the read-only preview: don't make
 * the host click a second time. A preview failure leaves the draft usable for
 * explicit retry, without repeating the potentially costly draft operation. */
export async function createDraftWithPreview<TDraft extends {id:string},TPreview>(
  makeDraft:()=>Promise<TDraft>,
  checkPreview:(id:string)=>Promise<TPreview>,
  isCurrent:()=>boolean,
  onDraft:(draft:TDraft)=>void,
  onReviewing:()=>void,
  onPreview:(preview:TPreview)=>void,
  onPreviewError:(error:unknown)=>void
):Promise<void>{
  const draft=await makeDraft();
  if(!isCurrent())return;
  onDraft(draft);
  onReviewing();
  try{
    const preview=await checkPreview(draft.id);
    if(isCurrent())onPreview(preview);
  }catch(error){
    if(isCurrent())onPreviewError(error);
  }
}

/** Native publishes real byte progress for each block. Limit React updates
 * during large copies, always preserving first/changed/terminal phases; never
 * fabricate bytes, percentages or completion when the native event is absent. */
export function createHostStudioProgressSampler(intervalMs=125){
  let lastId:string|null=null;
  let lastPhase:PublishProgress['phase']|null=null;
  let lastAt=Number.NEGATIVE_INFINITY;
  let lastProcessed=0;
  return {
    accept(progress:PublishProgress,atMs:number):boolean{
      if(!Number.isFinite(atMs)||!Number.isFinite(progress.processedBytes)||
        !Number.isFinite(progress.totalBytes)||progress.processedBytes<0||
        progress.totalBytes<0||(progress.percent!==null&&!Number.isFinite(progress.percent)))return false;
      const changed=progress.id!==lastId||progress.phase!==lastPhase;
      if(!changed&&(progress.phase==='complete'||progress.phase==='error'||
        progress.processedBytes<lastProcessed||atMs-lastAt<intervalMs))return false;
      lastId=progress.id;lastPhase=progress.phase;lastAt=atMs;
      lastProcessed=progress.processedBytes;
      return true;
    },
    reset():void{
      lastId=null;lastPhase=null;lastAt=Number.NEGATIVE_INFINITY;
      lastProcessed=0;
    }
  };
}

export default function HostStudio({close,onCatalogChanged}:{close:()=>void;onCatalogChanged?:()=>Promise<void>}) {
  const [zip,setZip]=useState('');
  const [cover,setCover]=useState('');
  const [inspection,setInspection]=useState<Inspection|null>(null);
  const [id,setId]=useState('');
  const [name,setName]=useState('');
  const [version,setVersion]=useState('1.0.0');
  const [releaseTag,setReleaseTag]=useState('coco-games-pending');
  const [assetName,setAssetName]=useState('');
  const urlValid=/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(releaseTag)
    &&/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.zip$/i.test(assetName);
  const url=urlValid?`https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/${releaseTag}/${assetName}`:'';
  const [mode,setMode]=useState<'new'|'update'>('new');
  const [executable,setExecutable]=useState('');
  const [executableReviewKey,setExecutableReviewKey]=useState('');
  const executableReviewed=isStudioExecutableReviewed(inspection,executable,executableReviewKey);
  const missingItems=studioMissingItems({zip,cover,executable,name,id,version,urlValid})
    .concat(executable&&!executableReviewed?['confirmar archivo que inicia el juego']:[]);
  const [busy,setBusy]=useState(false);
  const [busyLabel,setBusyLabel]=useState('');
  const [error,setError]=useState('');
  const [result,setResult]=useState<Draft|null>(null);
  const [review,setReview]=useState<PromotionReview|null>(null);
  const [rightsReviewed,setRightsReviewed]=useState(false);
  const [promotionRightsReviewed,setPromotionRightsReviewed]=useState(false);
  const [promoted,setPromoted]=useState<PromotionResult|null>(null);
  const [publishPreview,setPublishPreview]=useState<PublishPreview|null>(null);
  const [publishArtifact,setPublishArtifact]=useState<PublishArtifact|null>(null);
  const [publishProgress,setPublishProgress]=useState<PublishProgress|null>(null);
  const [localReview,setLocalReview]=useState<LocalPackageReview|null>(null);
  const [localConsent,setLocalConsent]=useState(false);
  const [localImported,setLocalImported]=useState(false);
  const [channelDraft,setChannelDraft]=useState<ChannelDraft|null>(null);
  const [portableExport,setPortableExport]=useState<PortableExport|null>(null);
  const [copiedExport,setCopiedExport]=useState(false);
  const [exportPhase,setExportPhase]=useState<'idle'|'choosing'|'exporting'>('idle');
  const [exportNotice,setExportNotice]=useState('');
  const [restoreExportFocus,setRestoreExportFocus]=useState(false);
  const [exitNotice,setExitNotice]=useState('');
  const [deliveryReview,setDeliveryReview]=useState<ChannelDeliveryReview|null>(null);
  const flowGate=useRef(createHostStudioFlowGate());
  const prepareTicket=useRef<number|null>(null);
  const autoSavePendingRef=useRef(false);
  const progressSampler=useRef(createHostStudioProgressSampler());
  const exportPendingRef=useRef(false);
  const closeButtonRef=useRef<HTMLButtonElement>(null);
  const exportButtonRef=useRef<HTMLButtonElement>(null);
  const exportedResultRef=useRef<HTMLDivElement>(null);
  const previewConsentRef=useRef<HTMLInputElement>(null);
  const focusedPreviewRef=useRef('');
  const exportPathRef=useRef<HTMLElement>(null);
  const friendInstructionsRef=useRef<HTMLParagraphElement>(null);
  const resetForNewGame=()=>{
    setZip('');setCover('');setInspection(null);setId('');setName('');
    setVersion('1.0.0');setReleaseTag('coco-games-pending');setAssetName('');
    setMode('new');setExecutable('');setExecutableReviewKey('');setResult(null);setReview(null);
    setRightsReviewed(false);setPromotionRightsReviewed(false);setPromoted(null);setPublishPreview(null);
    setPublishArtifact(null);setPublishProgress(null);setLocalReview(null);
    setLocalConsent(false);setLocalImported(false);setChannelDraft(null);
    setPortableExport(null);setCopiedExport(false);setDeliveryReview(null);
    setExportPhase('idle');setExportNotice('');setError('');setExitNotice('');
    setRestoreExportFocus(false);
    setBusy(false);setBusyLabel('');prepareTicket.current=null;
    autoSavePendingRef.current=false;
    focusedPreviewRef.current='';
    closeButtonRef.current?.focus();
  };
  const safelyClose=()=>{
    if(flowGate.current.request('close'))close();
    else setExitNotice('Cerraré Host Studio al terminar la operación en curso. No se interrumpirá una escritura que ya comenzó.');
  };
  const changeGame=()=>{
    if(flowGate.current.request('new'))resetForNewGame();
    else setExitNotice('Cambiaré al juego nuevo cuando termine el paso actual. Su resultado anterior no se mostrará.');
  };
  const beginOperation=(label:string):number|null=>{
    const ticket=flowGate.current.begin();
    if(ticket===null)return null;
    setBusy(true);setBusyLabel(label);setError('');setExitNotice('');
    return ticket;
  };
  const completeOperation=(ticket:number)=>{
    const action=flowGate.current.finish(ticket);
    if(!flowGate.current.isLive())return;
    setBusy(false);setBusyLabel('');prepareTicket.current=null;
    if(action==='new')resetForNewGame();
    else if(action==='close')close();
  };
  const showOperationError=(ticket:number,problem:unknown,stage:'inspect'|'draft'|'review'|'prepare'|'advanced')=>{
    if(flowGate.current.owns(ticket))setError(hostStudioOperationError(problem,stage));
  };

  // Host Studio is modal; restore focus to the caller on close and keep Tab
  // within the dialog, including its native-looking Save As controls.
  useEffect(()=>{
    // React StrictMode may run an effect cleanup/re-setup without a fresh
    // component instance. Re-arm the ticket guard for that second setup.
    if(!flowGate.current.isLive())flowGate.current=createHostStudioFlowGate();
    const previous=document.activeElement;
    closeButtonRef.current?.focus();
    return()=>{
      flowGate.current.dispose();
      if(previous instanceof HTMLElement&&previous.isConnected)previous.focus();
    };
  },[]);
  useEffect(()=>{if(portableExport)exportedResultRef.current?.focus();},[portableExport?.path]);
  // The Save As button is disabled while native dialog/export is in flight.
  // Do not try to focus it inside the await continuation: wait until React
  // has committed the idle state and enabled it again.
  useEffect(()=>{
    if(!busy&&restoreExportFocus&&!flowGate.current.isActive()){
      exportButtonRef.current?.focus();
      setRestoreExportFocus(false);
    }
  },[busy,restoreExportFocus]);
  useEffect(()=>{
    if(!busy&&publishPreview&&!publishArtifact&&
      focusedPreviewRef.current!==publishPreview.previewSha256){
      focusedPreviewRef.current=publishPreview.previewSha256;
      previewConsentRef.current?.focus();
    }
  },[busy,publishPreview?.previewSha256,publishArtifact]);
  const handleDialogKeys=(event:KeyboardEvent<HTMLDivElement>)=>{
    if(event.key==='Escape'&&!busy&&!exportPendingRef.current){
      event.preventDefault();event.stopPropagation();safelyClose();
    }else if(event.key==='Escape'){
      // A native write is not cancelable; defer closing until it settles.
      event.preventDefault();event.stopPropagation();safelyClose();
    }
    if(event.key!=='Tab')return;
    const available=Array.from(event.currentTarget.querySelectorAll<HTMLElement>(
      'button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),a[href],summary,[tabindex]:not([tabindex="-1"])'))
      .filter(element=>element.getClientRects().length>0&&element.getAttribute('aria-hidden')!=='true');
    if(available.length===0)return;
    const first=available[0],last=available[available.length-1];
    if(event.shiftKey&&(document.activeElement===first||!event.currentTarget.contains(document.activeElement))){
      event.preventDefault();last.focus();
    }else if(!event.shiftKey&&(document.activeElement===last||!event.currentTarget.contains(document.activeElement))){
      event.preventDefault();first.focus();
    }
  };

  useEffect(()=>{
    let disposed=false;let unsubscribe:(()=>void)|undefined;
    void listen<PublishProgress>('coco2://host-publish-progress',event=>{
      const ticket=prepareTicket.current;
      if(!disposed&&ticket!==null&&flowGate.current.owns(ticket)&&
        event.payload.id===result?.id&&
        progressSampler.current.accept(event.payload,Date.now()))setPublishProgress(event.payload);
    }).then(stop=>{if(disposed)stop();else unsubscribe=stop;}).catch(console.warn);
    return()=>{disposed=true;unsubscribe?.();};
  },[result?.id]);

  const browse=async(type:'zip'|'cover')=>{
    const ticket=beginOperation(type==='zip'?'Elige el ZIP original…':'Elige una portada…');
    if(ticket===null)return;
    try {
      const selected=await open({
        multiple:type==='zip',directory:false,
        title:type==='zip'?'Elegir ZIP (y portada si está en la misma carpeta)':'Elegir portada para este juego',
        filters:[type==='zip'?{name:'ZIP y portada opcional',extensions:['zip','png','jpg','jpeg','webp']}:{name:'Portada',extensions:['png','jpg','jpeg','webp']}]
      });
      if(!flowGate.current.owns(ticket))return;
      if(!selected)return;
      if(type==='cover'){
        if(typeof selected!=='string'||!/\.(png|jpe?g|webp)$/i.test(selected)||
          /[\0\r\n]/.test(selected)||selected.length>32767){
          setError('Elige una portada PNG, JPG o WebP válida.');
          return;
        }
        setCover(selected);
        return;
      }
      const chosen=classifyStudioSelection(selected);
      if(chosen.error){setError(chosen.error);return;}
      // Keep the current usable ZIP and its executable confirmation until the
      // replacement has passed native inspection. A corrupt ZIP must not
      // destroy the last successfully reviewed selection.
      setBusyLabel('Inspeccionando el contenido del ZIP…');
      const inspected=await invoke<Inspection>('inspect_standalone_archive',{zipPath:chosen.zip});
      if(flowGate.current.owns(ticket)){
        setZip(chosen.zip);setCover(chosen.cover);setExecutableReviewKey('');setResult(null);
        setReview(null);setPromoted(null);setPublishPreview(null);setPublishArtifact(null);
        setChannelDraft(null);setPortableExport(null);setCopiedExport(false);
        setExportNotice('');setAssetName(suggestedFutureZipName(chosen.zip));
        setInspection(inspected);setId(inspected.suggestedId);setName(inspected.suggestedName);
        setExecutable(suggestStudioExecutable(inspected.executables,chosen.zip));
      }
    }catch(e){showOperationError(ticket,e,'inspect');}
    finally{completeOperation(ticket);}
  };
  const create=async()=>{
    if(!inspection||!executableReviewed||busy)return;
    const ticket=beginOperation('Creando un borrador seguro…');
    if(ticket===null)return;
    try{
      await createDraftWithPreview(
        ()=>invoke<Draft>(mode==='update'?'create_standalone_update_draft':'create_standalone_draft',{
          zipPath:zip,id,name,version,archiveUrl:url,coverPath:cover,executable,expectedSha256:inspection.sha256,
        }),
        draftId=>invoke<PublishPreview>('preview_standalone_publish',{id:draftId,originalZipPath:zip}),
        ()=>flowGate.current.owns(ticket),
        draft=>{setResult(draft);setPublishPreview(null);setRightsReviewed(false);setPromotionRightsReviewed(false);},
        ()=>setBusyLabel('Borrador listo. Revisando versión y archivos…'),
        preview=>{setPublishPreview(preview);setPublishArtifact(null);setRightsReviewed(false);},
        error=>setError(`El borrador está listo, pero falta comprobarlo. Puedes reintentar la revisión sin crearlo de nuevo. ${hostStudioOperationError(error,'review')}`)
      );
    }catch(e){showOperationError(ticket,e,'draft');}
    finally{completeOperation(ticket);}
  };
  const reviewForCatalog=async()=>{
    if(!result||busy||mode==='update')return;
    const ticket=beginOperation('Revisando los archivos del juego…');
    if(ticket===null)return;
    try{
      const checked=await invoke<PromotionReview>('review_standalone_draft',{id:result.id,originalZipPath:zip});
      if(flowGate.current.owns(ticket)){setReview(checked);setPromotionRightsReviewed(false);}
    }catch(e){showOperationError(ticket,e,'review');}
    finally{completeOperation(ticket);}
  };
  const previewPublish=async()=>{
    if(!result||busy)return;
    const ticket=beginOperation('Comprobando versión, archivos y portada…');
    if(ticket===null)return;
    try{
      const preview=await invoke<PublishPreview>('preview_standalone_publish',{id:result.id,originalZipPath:zip});
      if(flowGate.current.owns(ticket)){setPublishPreview(preview);setPublishArtifact(null);setRightsReviewed(false);}
    }catch(e){showOperationError(ticket,e,'review');}
    finally{completeOperation(ticket);}
  };
  const preparePublish=async()=>{
    if(!result||!publishPreview||!rightsReviewed||busy)return;
    const ticket=beginOperation('Preparando los archivos del paquete…');
    if(ticket===null)return;
    prepareTicket.current=ticket;progressSampler.current.reset();setPublishProgress(null);
    try{
      const artifact=await invoke<PublishArtifact>('prepare_standalone_publish',{
        id:result.id,originalZipPath:zip,
        expectedPreviewSha256:publishPreview.previewSha256,reviewedRights:true,
      });
      if(flowGate.current.owns(ticket))setPublishArtifact(artifact);
      // Save As is the next step of the SAME user action, with a second
      // exclusive ticket acquired after the native preparation settles.
      if(flowGate.current.owns(ticket))autoSavePendingRef.current=true;
    }catch(e){showOperationError(ticket,e,'prepare');}
    finally{completeOperation(ticket);}
  };
  const reviewForMyLibrary=async()=>{
    if(!publishArtifact||busy)return;
    const ticket=beginOperation('Revisando el paquete antes de añadirlo…');
    if(ticket===null)return;
    try{
      const checked=await invoke<LocalPackageReview>('review_local_publish_package',{path:publishArtifact.artifactPath});
      if(flowGate.current.owns(ticket)){
        setLocalConsent(false);
        // A native review is consent for EXACTLY the prepared package, not
        // for another pending review/IPC result with a plausible token.
        if(isMatchingPortableReview(checked,publishArtifact.artifactPath)&&
          checked.id===publishArtifact.id)setLocalReview(checked);
        else{
          setLocalReview(null);
          setError('La revisión no coincide con el paquete preparado. Vuelve a comprobarlo antes de autorizar su incorporación.');
        }
      }
    }catch(e){showOperationError(ticket,e,'advanced');}
    finally{completeOperation(ticket);}
  };
  const addToMyLibrary=async()=>{
    if(!localReview||!publishArtifact||!localConsent||busy)return;
    const ticket=beginOperation('Incorporando la copia que autorizaste…');
    if(ticket===null)return;
    try{
      const receipt=await invoke<{status:string}>('import_local_publish_package',{
        path:publishArtifact.artifactPath,reviewToken:localReview.reviewToken,confirmed:true,
      });
      if(flowGate.current.owns(ticket)){
        if(receipt?.status!=='updated'&&receipt?.status!=='unchanged'){
          setLocalReview(null);setLocalConsent(false);
          setError('La aplicación no confirmó la incorporación. Revisa de nuevo el paquete antes de volver a aceptarlo.');
          return;
        }
        setLocalImported(true);setLocalReview(null);
        try{await onCatalogChanged?.();}catch(error){console.warn('Import accepted; library refresh unavailable:',error);}
      }
    }catch(e){showOperationError(ticket,e,'advanced');}
    finally{completeOperation(ticket);}
  };
  const prepareChannel=async()=>{
    if(!publishArtifact||busy)return;
    const ticket=beginOperation('Revisando opciones avanzadas del host…');
    if(ticket===null)return;
    try{
      const draft=await invoke<ChannelDraft>('prepare_catalog_channel',{packagePath:publishArtifact.artifactPath});
      if(flowGate.current.owns(ticket)){setChannelDraft(draft);setDeliveryReview(null);}
    }catch(e){showOperationError(ticket,e,'advanced');}
    finally{completeOperation(ticket);}
  };
  const checkDelivery=async(online=false)=>{
    if(!channelDraft||busy)return;
    const ticket=beginOperation(online?'Comprobando archivos remotos…':'Revisando los archivos locales…');
    if(ticket===null)return;
    try{
      const checked=await invoke<ChannelDeliveryReview>(online?'verify_channel_delivery_online':'review_channel_delivery',{
        draftPath:channelDraft.channelDraftPath,
      });
      if(flowGate.current.owns(ticket))setDeliveryReview(checked);
    }catch(error){
      if(flowGate.current.owns(ticket))setDeliveryReview(null);
      showOperationError(ticket,error,'advanced');
    }finally{completeOperation(ticket);}
  };
  const exportPortable=async()=>{
    if(!publishArtifact||busy||exportPendingRef.current)return;
    const ticket=beginOperation('Elige dónde guardar el archivo…');
    if(ticket===null)return;
    exportPendingRef.current=true;
    setExportPhase('choosing');setExportNotice('');setCopiedExport(false);setRestoreExportFocus(false);
    let step:'picker'|'export'='picker';
    try{
      const destination=await save({
        title:'Guardar como · Archivo para compartir con un amigo',
        defaultPath:suggestedPortableFileName(publishArtifact.id,publishPreview?.newVersion||'1.0.0'),
        filters:[{name:'Paquete Coco 2 (.coco2pack)',extensions:['coco2pack']}],
      });
      if(!flowGate.current.owns(ticket))return;
      if(!destination){
        setExportNotice('Guardado cancelado. No se creó una copia nueva.');
        setRestoreExportFocus(true);
        return;
      }
      if(!isPortableSavePath(destination)){
        setError('El nombre debe terminar en .coco2pack. Vuelve a abrir Guardar como y elige un nombre válido.');
        setRestoreExportFocus(true);
        return;
      }
      if(!isLocalPortableSavePath(destination)){
        setError('Selecciona una ruta completa de una unidad local y evita carpetas especiales o rutas relativas.');
        setRestoreExportFocus(true);
        return;
      }
      setExportPhase('exporting');setBusyLabel('Creando y comprobando tu archivo .coco2pack…');
      step='export';
      const exported=await invoke<PortableExport>('export_portable_standalone_package',{
        id:publishArtifact.id,artifactPath:publishArtifact.artifactPath,destinationPath:destination,
      });
      if(!flowGate.current.owns(ticket))return;
      if(!isConfirmedPortableExport(exported,publishArtifact.id,destination)){
        setError('No puedo confirmar que el recibo corresponda al archivo elegido. Es posible que ya se haya guardado: revisa esa carpeta antes de intentar otra copia.');
        setRestoreExportFocus(true);
        return;
      }
      setPortableExport(exported);
      setCopiedExport(false);
      setExportNotice('Archivo guardado en tu equipo. Ya puedes enviarlo; nada se publicó ni se importó.');
    }catch(error){
      if(flowGate.current.owns(ticket)){
        setError(portableExportError(error,step));
        setRestoreExportFocus(true);
      }
    }finally{
      if(flowGate.current.owns(ticket)){
        exportPendingRef.current=false;setExportPhase('idle');setBusyLabel('');setBusy(false);
      }else exportPendingRef.current=false;
      completeOperation(ticket);
    }
  };
  useEffect(()=>{
    if(!busy&&autoSavePendingRef.current&&publishArtifact&&!flowGate.current.isActive()&&
      flowGate.current.isLive()){
      // Clear synchronously, before launching the picker, so React StrictMode
      // or a fast rerender cannot start another Save As.
      autoSavePendingRef.current=false;
      void exportPortable();
    }
  },[busy,publishArtifact]);
  const copyExportLocation=async()=>{
    if(!portableExport||busy)return;
    const revision=flowGate.current.revision();
    setCopiedExport(false);
    try{
      if(!navigator.clipboard?.writeText)throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(portableExport.path);
      if(!flowGate.current.isRevision(revision))return;
      setCopiedExport(true);setExportNotice('Ubicación copiada. Pégala en el Explorador de archivos para encontrar tu paquete.');
    }catch{
      if(!flowGate.current.isRevision(revision))return;
      const element=exportPathRef.current;
      if(element){
        const range=document.createRange();
        range.selectNodeContents(element);
        const selection=window.getSelection();
        selection?.removeAllRanges();selection?.addRange(range);element.focus();
      }
      setExportNotice('La ubicación está seleccionada. Pulsa Ctrl+C para copiarla.');
    }
  };
  const copyFriendInstructions=async()=>{
    if(!portableExport||busy)return;
    const revision=flowGate.current.revision();
    try{
      if(!navigator.clipboard?.writeText)throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(portableFriendMessage(portableExport.path));
      if(!flowGate.current.isRevision(revision))return;
      setExportNotice('Instrucciones copiadas. Pégalas junto al archivo cuando se lo envíes a tu amigo.');
    }catch{
      if(!flowGate.current.isRevision(revision))return;
      const paragraph=friendInstructionsRef.current;
      if(paragraph){
        const range=document.createRange();range.selectNodeContents(paragraph);
        const selection=window.getSelection();
        selection?.removeAllRanges();selection?.addRange(range);paragraph.focus();
      }
      setExportNotice('Seleccioné las instrucciones. Pulsa Ctrl+C para copiarlas.');
    }
  };
  const promote=async()=>{
    if(!result||!review||!promotionRightsReviewed||busy)return;
    const ticket=beginOperation('Incorporando al catálogo del host…');
    if(ticket===null)return;
    try{
      const value=await invoke<PromotionResult>('promote_standalone_draft',{
        id:result.id,reviewedRights:true,originalZipPath:zip,
      });
      if(flowGate.current.owns(ticket))setPromoted(value);
    }catch(e){showOperationError(ticket,e,'advanced');}
    finally{completeOperation(ticket);}
  };
  return <div className="coco-studio-backdrop" role="presentation" onClick={safelyClose}>
    <div className="coco-studio" role="dialog" aria-modal="true" aria-label="Crear nueva experiencia" aria-busy={busy} onClick={event=>event.stopPropagation()} onKeyDown={handleDialogKeys} tabIndex={-1}>
      <header className="coco-studio-head"><span className="eyebrow"><PackagePlus size={15}/> HOST STUDIO</span><h2>{mode==='update'?'Actualizar experiencia':'Nueva experiencia'}</h2><p className="studio-head-caption">Del ZIP a un único archivo .coco2pack para tu amigo. No se publica nada.</p><button ref={closeButtonRef} aria-label={busy?'Cerrar al terminar la operación':'Cerrar'} title={busy?'Cerrar cuando termine el paso actual':'Cerrar Host Studio'} onClick={safelyClose}><X size={19}/></button></header>
      <div className="coco-studio-content">
        <div className="studio-steps" aria-label="Pasos para compartir"><span className={!inspection?'current':undefined} aria-current={!inspection?'step':undefined}>1 · ZIP</span><ArrowRight size={13}/><span className={inspection&&!result?'current':undefined} aria-current={inspection&&!result?'step':undefined}>2 · Datos</span><ArrowRight size={13}/><span className={result&&!publishArtifact?'current':undefined} aria-current={result&&!publishArtifact?'step':undefined}>3 · Preparar</span><ArrowRight size={13}/><span className={publishArtifact?'current':undefined} aria-current={publishArtifact?'step':undefined}>4 · Guardar</span></div>
        {(inspection||zip||result)&&<button className="filter-button" onClick={changeGame} aria-label={busy?'Cambiar juego al terminar el proceso':'Cambiar de juego'}><ArrowRight size={14}/> {busy?'Cambiar juego al terminar':'Elegir otro juego'}</button>}
        {exitNotice&&<p className="operation-message" role="status" aria-live="polite"><CircleAlert size={15}/>{exitNotice}</p>}
        {!result&&<div className="studio-mode" role="group" aria-label="Tipo de experiencia"><button className={mode==='new'?'active':''} aria-pressed={mode==='new'} disabled={busy} onClick={()=>setMode('new')}>Añadir juego</button><button className={mode==='update'?'active':''} aria-pressed={mode==='update'} disabled={busy} onClick={()=>setMode('update')}>Nueva versión</button></div>}
        {!result&&<button className="studio-picker" disabled={busy} onClick={()=>void browse('zip')} aria-label={zip?'Cambiar ZIP del juego':'Seleccionar ZIP del juego y portada opcional'}><Archive size={21}/><span>{zip?zip.split(/[\\/]/).at(-1):'Elegir ZIP del juego (y portada si la tienes)'}</span><FolderOpen size={18}/></button>}
        {busy&&<div className="studio-progress" role="status" aria-live="polite"><LoaderCircle className="spin" size={17}/> {busyLabel||'Procesando…'}</div>}
        {busy&&publishProgress&&publishProgress.id===result?.id&&prepareTicket.current!==null&&flowGate.current.owns(prepareTicket.current)&&<div className="studio-byte-progress" role="status" aria-live="polite"><div><span>{publishProgress.phase==='copying'?'Copiando el juego':publishProgress.phase==='verifying'?'Comprobando el contenido':publishProgress.phase==='sealing'?'Terminando paquete':'Preparando paquete'}</span><strong>{publishProgress.percent===null?'En curso':`${Math.max(0,Math.min(100,Math.floor(publishProgress.percent)))}%`}</strong></div><div className={`progress-track ${publishProgress.percent===null?'progress-indeterminate':''}`} role="progressbar" aria-label="Preparación del paquete" aria-valuemin={0} aria-valuemax={100} aria-valuenow={publishProgress.percent===null?undefined:Math.max(0,Math.min(100,Math.round(publishProgress.percent)))}><div className="progress-fill progress-real" style={publishProgress.percent===null?undefined:{width:`${Math.max(0,Math.min(100,publishProgress.percent))}%`}}/></div>{publishProgress.totalBytes>0&&<small>{(publishProgress.processedBytes/1048576).toFixed(0)} / {(publishProgress.totalBytes/1048576).toFixed(0)} MB</small>}</div>}
        {inspection&&!publishArtifact&&<div className="studio-stats"><span>{inspection.filesCount} archivos</span><span>{(inspection.archiveSize/1048576).toFixed(0)} MB</span><span>{inspection.executables.length} ejecutables</span></div>}
        {inspection&&!result&&<div className="studio-form studio-v9-form" aria-label="Preparación de la experiencia">
          <div className="studio-v9-intro studio-wide"><strong><Check size={16}/> ZIP analizado, listo para configurar</strong><p>Confirma el nombre, el ejecutable y la portada. Coco no ejecutará el juego ni subirá archivos.</p></div>
          <label>Nombre del juego<input value={name} disabled={busy} onChange={event=>setName(event.target.value)} maxLength={120} autoComplete="off"/></label>
          <label>Versión<input value={version} disabled={busy} onChange={event=>setVersion(event.target.value)} maxLength={100} autoComplete="off"/></label>
          <label className="studio-wide">Archivo que inicia el juego
            <select value={executable} disabled={busy} onChange={event=>{setExecutableReviewKey('');setExecutable(event.target.value);}} aria-describedby="studio-executable-hint"><option value="">Elige un ejecutable del ZIP…</option>{inspection.executables.map(e=><option key={e} value={e}>{e}</option>)}</select>
            <small id="studio-executable-hint">{executable?studioExecutableWarning(executable):'No hay una propuesta segura. Revisa los ejecutables antes de preparar el paquete.'}</small>
          </label>
          {executable&&<label className="studio-executable-confirm studio-wide"><input type="checkbox" checked={executableReviewed} disabled={busy} onChange={event=>setExecutableReviewKey(event.target.checked?studioExecutableReviewKey(inspection.sha256,executable):'')}/><span><strong>Confirmo que este es el ejecutable principal</strong><small>{executable}</small></span></label>}
          <div className="studio-wide studio-v9-cover">
            <div><strong>Portada (opcional)</strong><p>Puedes incluir una imagen con el ZIP o elegirla ahora. Si no tienes, Coco crea una portada neutra original, sin usar imágenes ajenas.</p></div>
            <button className="studio-picker" disabled={busy} onClick={()=>void browse('cover')}><FolderOpen size={17}/><span>{cover?cover.split(/[\\/]/).at(-1):'Elegir portada propia (opcional)'}</span></button>
          </div>
          {mode==='update'&&<label className="studio-wide">Identificador del juego existente<input value={id} disabled={busy} onChange={event=>setId(event.target.value)} maxLength={48} autoComplete="off"/></label>}
          <details className="studio-release-fields studio-wide"><summary>Configuración avanzada (opcional)</summary><p>El identificador nuevo y el destino previsto ya vienen propuestos. Coco no crea releases ni sube archivos; Guardar como .coco2pack conserva todo en tu equipo.</p><div className="studio-release-inputs">{mode==='new'&&<label>Identificador del juego<input value={id} disabled={busy} maxLength={48} onChange={event=>setId(event.target.value)} autoComplete="off"/></label>}<label>Referencia de versión futura<input value={releaseTag} disabled={busy} maxLength={80} onChange={event=>setReleaseTag(event.target.value)}/></label><label>Nombre del ZIP futuro<input value={assetName} disabled={busy} maxLength={132} onChange={event=>setAssetName(event.target.value)}/></label></div>{!urlValid&&<small>Revisa los valores avanzados: se necesita un destino sintácticamente válido, aunque no se publique.</small>}</details>
          {missingItems.length>0&&<p className="studio-v9-missing studio-wide" role="status">Falta completar: {missingItems.join(' · ')}.</p>}
          <button className="primary-button studio-wide studio-v9-action" disabled={busy||!urlValid||missingItems.length>0} onClick={()=>void create()}><ClipboardCheck size={17}/> {mode==='update'?'Crear y revisar actualización':'Crear y revisar el juego'}<ArrowRight size={16}/></button>
        </div>}
        {result&&!promoted&&<div className={publishArtifact?'studio-v9-ready':'studio-complete'}>{!publishArtifact&&<><Check size={25}/><strong>Borrador preparado</strong><p>{result.requiredFilesCount} archivos esenciales · El ZIP original permanece intacto.</p></>}
          {!publishPreview&&<button className="primary-button" disabled={busy} onClick={()=>void previewPublish()}><ClipboardCheck size={17}/> {busy?'Revisando automáticamente…':error?'Reintentar revisión':'Comprobar para compartir'}</button>}
          {publishPreview&&!publishArtifact&&<div className="studio-publish-review"><div className="studio-publish-head"><ShieldCheck size={18}/><strong>{publishPreview.mode==='update'?'Actualización':'Nueva experiencia'} · {publishPreview.newVersion}</strong></div>{publishPreview.oldVersion&&<p>Versión anterior: {publishPreview.oldVersion}</p>}<p>Se comprobó la información y el contenido del juego. El siguiente paso prepara los archivos para compartirlos localmente; no publica nada.</p>
            {!publishArtifact&&<><label className="studio-rights"><input ref={previewConsentRef} type="checkbox" checked={rightsReviewed} disabled={busy} onChange={event=>setRightsReviewed(event.target.checked)}/> He revisado los datos y confirmo que tengo permiso para compartir estos archivos.</label><button className="primary-button studio-v9-action" disabled={busy||!rightsReviewed} onClick={()=>void preparePublish()}><FileArchive size={17}/> Preparar y guardar como .coco2pack<ArrowRight size={15}/></button></>}
          </div>}
          {publishArtifact&&<div className="studio-package-result" role="group" aria-label="Compartir experiencia"><Check size={18} aria-hidden="true"/><strong>{portableExport?'Paquete exportado · Preparado para compartir':'Preparación terminada · Falta guardar la copia para tu amigo'}</strong><p>{portableExport?'Puedes compartir el archivo guardado o crear otra copia con otro nombre.':'El contenido está listo para exportar. Elige carpeta y nombre con Guardar como; Coco creará un único archivo .coco2pack, sin sustituir los que ya existan.'}</p>
            <button ref={exportButtonRef} className={portableExport?'filter-button':'primary-button'} disabled={busy} onClick={()=>void exportPortable()}><FileArchive size={15}/>{portableExport?'Guardar otra copia…':'Guardar como .coco2pack…'}</button>
            {exportPhase==='choosing'&&<p role="status">Elige una carpeta en la ventana de Guardar como. Puedes pulsar Cancelar sin crear archivos.</p>}
            {exportPhase==='exporting'&&<p role="status">Creando una copia y comprobando su contenido. Deja abierta esta ventana hasta que termine.</p>}
            {exportNotice&&<p role="status" aria-live="polite">{exportNotice}</p>}
            {portableExport&&<div className="studio-portable-export" ref={exportedResultRef} tabIndex={-1} role="region" aria-label="Paquete exportado correctamente"><Check size={15} aria-hidden="true"/><div><strong>Exportado · Un archivo listo para enviar</strong><p><b>{portableExport.path.split(/[\\/]/).at(-1)}</b> · {(portableExport.size/1048576).toFixed(1)} MB. Guardado en tu equipo; todavía no está publicado ni se ha importado en ninguna biblioteca.</p><p ref={friendInstructionsRef} tabIndex={0}>Para tu amigo: envíale solo este <b>.coco2pack</b>. Con Coco 2 instalado, puede abrirlo con doble clic o ir a <b>Juegos → Abrir paquete Coco</b>, revisar su origen y aceptar la incorporación. No necesita extraer nada.</p><p>Ubicación del archivo:</p><code ref={exportPathRef} tabIndex={0} aria-label="Ubicación del paquete exportado">{portableExport.path}</code><div className="studio-portable-tools"><button className="filter-button" disabled={busy} onClick={()=>void copyExportLocation()} aria-label="Copiar ubicación del paquete"><Copy size={14}/>{copiedExport?'Ubicación copiada':'Copiar ubicación'}</button><button className="filter-button" disabled={busy} onClick={()=>void copyFriendInstructions()} aria-label="Copiar instrucciones para tu amigo"><Copy size={14}/> Copiar instrucciones</button></div><button className="primary-button" disabled={busy} onClick={safelyClose}><Check size={15}/> Listo, cerrar Host Studio</button></div></div>}
            <details className="studio-local-promote"><summary>Opciones avanzadas del host (opcionales)</summary><p>Estas opciones son para revisar el catálogo y la distribución del host. Guardar el archivo para tu amigo no las necesita.</p>
            {!channelDraft&&<button className="filter-button" disabled={busy} onClick={()=>void prepareChannel()}><ClipboardCheck size={15}/> Preparar canal GitHub</button>}
            {channelDraft&&<div className="studio-channel-review"><strong><ClipboardCheck size={16}/> Entrega preparada · revisión {channelDraft.sequence}</strong><p>{channelDraft.entries} experiencias en la propuesta. Nada se ha subido: antes de distribuir a otros usuarios falta comprobar los archivos remotos y autorizar la firma del canal.</p>
              <div className="studio-delivery-actions"><button className="filter-button" disabled={busy} onClick={()=>void checkDelivery()}><ShieldCheck size={15}/> Verificar entrega local</button>{deliveryReview?.signatureTrusted&&<button className="filter-button" disabled={busy} onClick={()=>void checkDelivery(true)}><ClipboardCheck size={15}/> Comprobar archivos remotos</button>}</div>
              {deliveryReview&&<div className="studio-delivery-verdict" role="status"><strong>{deliveryReview.status==='remote-verified'?'Distribución remota verificada':deliveryReview.readyForSignature?'Archivos locales correctos · falta firma y publicación':deliveryReview.signatureTrusted?'Firma oficial verificada · comprobar entrega remota':'Entrega todavía no publicable'}</strong><p>{deliveryReview.issues.length?'Hay elementos pendientes de revisión. Ningún archivo se publicó automáticamente.':'Los archivos locales fueron comprobados. Esto no demuestra que estén publicados.'}</p><div className="studio-delivery-assets">{deliveryReview.assets.map((asset,index)=><span key={index}>{asset.verifiedLocal?<Check size={13}/>:<CircleAlert size={13}/>} {asset.verifiedLocal?'Archivo local comprobado':'Archivo pendiente'}{asset.remoteAvailable?' · Disponible remotamente':''}</span>)}</div></div>}
              <div className="studio-release-checklist"><span><Check size={15}/> Paquete y catálogo preparados</span><span><CircleAlert size={15}/> Publicación GitHub pendiente</span><span><CircleAlert size={15}/> Firma oficial pendiente</span></div>
              <p>{channelDraft.publicationAssets.length} archivos de distribución reservados para revisión manual del host. Esta pantalla no los publica.</p>
            </div>}
            {!localReview&&!localImported&&<button className="filter-button" disabled={busy} onClick={()=>void reviewForMyLibrary()}><ShieldCheck size={15}/> Probar en mi biblioteca</button>}
            {localReview&&<div className="studio-local-import"><p>{localReview.id} · {localReview.mode==='update'?`${localReview.oldVersion} → `:''}{localReview.newVersion}</p><label className="studio-rights"><input type="checkbox" checked={localConsent} disabled={busy} onChange={event=>setLocalConsent(event.target.checked)}/> Confío en este paquete y quiero incorporarlo solo a mi Coco 2. No actualizar juegos instalados todavía.</label><button className="primary-button" disabled={!localConsent||busy} onClick={()=>void addToMyLibrary()}><PackagePlus size={15}/> Añadir a mi catálogo</button></div>}
            </details>
            {localImported&&<p className="studio-local-success"><Check size={15}/> Disponible en tu biblioteca para instalar o actualizar.</p>}
          </div>}
          {mode==='new'&&!promoted&&<details className="studio-local-promote"><summary>Agregar al catálogo fuente del host</summary>{!review&&<button className="filter-button" disabled={busy} onClick={()=>void reviewForCatalog()}>Revisar catálogo local</button>}{review&&<><p>{review.name} · {review.version} · {review.requiredFilesCount} archivos verificados</p><label className="studio-rights"><input type="checkbox" checked={promotionRightsReviewed} disabled={busy} onChange={event=>setPromotionRightsReviewed(event.target.checked)}/> Tengo derecho a distribuir esta experiencia.</label><button className="primary-button" disabled={busy||!promotionRightsReviewed} onClick={()=>void promote()}>Incorporar al catálogo</button></>}</details>}
        </div>}
        {promoted&&<div className="studio-complete"><Check size={25}/><strong>Agregado al catálogo</strong><p>La experiencia quedó incorporada a los archivos fuente del host. Esta acción no la publicó ni la envió a nadie.</p></div>}
        {error&&<p className="operation-message" role="alert"><CircleAlert size={16}/> {error}</p>}
      </div>
    </div>
  </div>;
}
