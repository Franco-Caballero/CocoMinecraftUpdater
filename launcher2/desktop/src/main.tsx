import React, { useDeferredValue, useEffect, useLayoutEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { convertFileSrc, isTauri } from '@tauri-apps/api/core';
import { invoke, captureUnexpectedErrors, copyDiagnosticReport } from './diagnostics';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { Activity, ClipboardCopy, ArrowDownAZ, ArrowRight, ArrowUpRight, Check, CircleAlert, Clock3, Download, FileArchive, Heart, LoaderCircle, Maximize2, Minus, PackagePlus, Play, Search, Settings2, ShieldCheck, Sparkles, X, Camera, HardDrive, Trash2, FolderOpen, FolderInput } from 'lucide-react';
import '@fontsource-variable/big-shoulders-display';
import '@fontsource-variable/instrument-sans';
import '../../prototype/styles.css';
import '../../prototype/reyna-theme.css';
import './shell.css';
import './experience-v2.css';
import './discovery-v9.css';
import './coco-ui.css';
import './cinema.css';
import hoverPreviews from './game-hover-previews.json';
import screenshotList from './game-screenshots.json';
import {ScreenshotGallery} from './ScreenshotGallery';
import {EpisodePicker,episodeLabels,mediaPlan,type MediaEpisode} from './EpisodePicker';
import {formatRemaining,progressFor,resumePoint,watchedFraction} from './media-progress';
import {warmAllScreenshots,warmScreenshots} from './screenshot-warmup';
import { HoverVideoPool } from './hover-video-pool';
import { clearActivity, readActivity, recordActivity, type ActivityKind } from './activity-ledger';
import {MediaPreparationGate} from './media-preparation-gate';
import {MediaSessionRefreshGate} from './media-session-refresh';
import {confirmedOperationMessage,refreshAfterConfirmedWrite} from './native-operation-settlement';
import {ForegroundRecoveryGate} from './foreground-recovery-gate';
import {NativeOperationGate,type NativeOperationTicket} from './native-operation-gate';
import {MAX_PENDING_PACKAGES,acknowledgePackageOverflow,dismissPackageRequest,enqueuePackageRequests,extractPackagePaths} from './package-inbox';
import {persistPackageInbox,readPersistedPackageInbox} from './package-inbox-persistence';
import type {PackageInboxState} from './package-inbox';
import {PackageActivationDrain} from './package-activation-drain';
import {isPortablePackageFile} from './portable-format';
import {EXPERIENCE_PAGE_SIZE,indexExperiences,matchesExperienceQuery,nextExperiencePage,normalizeExperienceQuery} from './experience-search';
import {indexDiscoveryNames,nextDiscoveryIndex,quickDiscovery} from './quick-discovery';
import {gamePrimaryAction} from './game-primary-action';
import {trapDialogTab} from './dialog-focus';
import {CatalogRefreshGate,publishVerifiedCatalog} from './catalog-refresh-gate';
import {NativeProgressSampler,nativeProgressDescription} from './native-progress-sampler';
import {nativeFailureGuidance,type NativeFailureAdvice} from './native-failure-guidance';
import {inspectAfterNativeFailure} from './native-failure-reconciliation';
import {NativeTransferRateMeter,nativeTransferRateText,nativeTransferRateCompact,type NativeTransferRate} from './native-transfer-rate';
import {NativeMediaDownloadGate} from './native-media-download-gate';
import {nativeStageView} from './native-stage-ui';
import {AppUpdaterProgressMeter} from './app-updater-progress';
import {affectedRegisteredGamePath} from './native-affected-path';
import {retainObservedGameIds} from './game-process-observation';
import {reconcileLaunchObservation} from './launch-observation';
import {reconcileRuntimeEvent} from './runtime-event-fence';
import {lockBackgroundScroll} from './modal-scroll-lock';
import {formatBytes,formatBytePair,shortPath,isComingSoon,latestAddition,matchesLibraryFilter,sortLibrary,unseenEntries,type LibraryFilter,type LibrarySort} from './library-view';
import {attachCardTilt,attachStageParallax} from './stage-motion';
import LauncherIntro from './LauncherIntro';
import {deriveLauncherStatus,type CatalogSyncState} from './launcher-status';
import {useFlipGrid} from './flip-grid';

type View = 'library' | 'settings';
type Category = 'all' | 'minecraft' | 'standalone' | 'media';
type Experience = {
  id: string;
  instanceId: string;
  name: string;
  image: string;
  description: string;
  workflow: string;
  minecraftVersion: string;
  loader: string;
  requiredFiles: {path:string;sha256:string;size:number}[];
  executable: string;
  launchArguments:string[];
  hostingMode:string;
};
type LocalInstance = {id:string;state:'folder-present'|'not-found'|'unknown'|'unmanaged';location:'default'|'custom'|'none'};
type CatalogProvenance = {id:string;source:'embedded'|'official'|'local';version:string};
type CatalogSyncResult = {status:'updated'|'unchanged'|'offline'|'cached'|'embedded'|'degraded';message:string};
type RuntimeEvent = {id:string;state:'verifying'|'running'|'exited';pid:number|null;exitCode:number|null};
type ActiveGameProcessReport = {status:string;safeToUpdate:boolean;gameIds:string[];processCount:number;unknownCandidates:number;matchedProcesses:{pid:number;gameId:string}[]};
type LocalIdentity = {configured:boolean;username:string|null};
type InstallPlan = {id:string;status:'ready'|'needs-repair'|'unsupported-extras';message:string;instancePath:string;archiveCount:number;totalDownloadBytes:number;requiredFileCount:number};
type InstallProgress = {id:string;phase:string;file:string;downloadedBytes:number;totalBytes:number;percent:number};
type InstallLocation = {id:string;path:string;custom:boolean;freeBytes:number|null};
type LocationCheck = {id:string;root:string;sameDrive:boolean;freeBytes:number|null;neededBytes:number};
type MoveDraft = {id:string;parent:string|null;check:LocationCheck};
type MoveOutcome = {id:string;path:string;copied:boolean;leftovers:boolean};
type UninstallOutcome = {id:string;freedBytes:number;keptFiles:number;leftovers:boolean};
type InstallOutcome = {id:string;status:string;instancePath:string;message:string};
type RepairRecoveryStatus = {id:string;pending:boolean;cleanupPending:boolean;message:string};
type UpgradePlan = {id:string;status:'upgrade-ready'|'already-current'|'downgrade-blocked'|'not-installed'|'unsupported-extras'|'untrusted-existing'|string;fromVersion:string|null;toVersion:string;neededBytes:number;instancePath:string;message:string};
type UpgradeOutcome = {id:string;status:string;fromVersion:string|null;toVersion:string;neededBytes:number;instancePath:string;message:string};
type PendingStandaloneOperation = {id:string;instancePath:string;kind:string;status:'recovery-required'|'cleanup-pending'|'blocked-unsafe'|string;fromVersion?:string|null;toVersion?:string|null;message:string};
type MediaEntry = {id:string;name:string;type:string;episodes:{id:string;title:string;fileName:string;size:number;mimeType:string}[]};
type PreparedMediaStream = {id:string;episodeId:string;url:string;mimeType:string;expiresInSeconds:number};
type MediaDownloadProgress = {id:string;episodeId:string;phase:string;downloadedBytes:number;totalBytes:number;percent:number};
type UpdateStage = 'idle'|'checking'|'current'|'downloading'|'installing'|'deferred'|'error';
type AppUpdateProgress = {stage:UpdateStage;version:string;percent:number;downloaded:number;total:number;message:string};
type GameSecurityGuide = {id:string;folder:string;warning:string};
const LazyMediaPlayer=React.lazy(()=>import('./MediaPlayer'));
const LazyHostStudio=React.lazy(()=>import('./HostStudio'));
const LazyCatalogHub=React.lazy(()=>import('./CatalogHub'));
const LazyFirstRun=React.lazy(()=>import('./FirstRun'));

const catLabels: Record<Category,string> = {all:'Todo',minecraft:'Minecraft',standalone:'Juego',media:'Película'};
const libraryFilters:{id:LibraryFilter;label:string}[]=[
  {id:'all',label:'Todo'},{id:'games',label:'Juegos'},{id:'movies',label:'Películas'},
  {id:'installed',label:'Instalados'},{id:'favorites',label:'Favoritos'},
];
const CATALOG_SYNC_INTERVAL_MS=15*60_000;
const CATALOG_SYNC_FOCUS_GAP_MS=5*60_000;
const ARRIVAL_NOTICE_MS=9000;
const catalogSnapshotKey='coco2-catalog-snapshot';
const seenCatalogKey='coco2-seen-catalog';
const validCatalog=(value:unknown):value is Experience[]=>Array.isArray(value)&&value.length>0&&
  value.every(x=>typeof x?.id==='string'&&typeof x?.name==='string'&&typeof x?.workflow==='string');
/** Painted before native answers so the library is there on the very first
 * frame. Display only: installing or launching always re-reads native manifests. */
function restoreCatalogSnapshot():Experience[]{
  try{
    const value:unknown=JSON.parse(localStorage.getItem(catalogSnapshotKey)||'null');
    return validCatalog(value)?value:[];
  }catch{return [];}
}
function saveCatalogSnapshot(entries:readonly Experience[]){
  try{
    const text=JSON.stringify(entries);
    // Signed entries can embed a cover; the native read is the fallback then.
    if(text.length<1_500_000)localStorage.setItem(catalogSnapshotKey,text);
    else localStorage.removeItem(catalogSnapshotKey);
  }catch{}
}
function restoreSeenCatalog():Set<string>|null{
  try{
    const value:unknown=JSON.parse(localStorage.getItem(seenCatalogKey)||'null');
    return Array.isArray(value)?new Set(value.filter((id):id is string=>typeof id==='string')):null;
  }catch{return null;}
}
const saveSeenCatalog=(ids:Iterable<string>)=>{try{localStorage.setItem(seenCatalogKey,JSON.stringify([...ids]));}catch{}};
const favoriteKey = 'coco2-desktop-favorites';
const activityTitles:Record<ActivityKind,string>={
  played:'Iniciaste',installed:'Instalaste',upgraded:'Actualizaste',
  repaired:'Reparaste',recovered:'Recuperaste',watched:'Abriste un video de',
  downloaded:'Guardaste sin conexión',uninstalled:'Desinstalaste',
  'install-interrupted':'Se interrumpió la instalación de',
  'upgrade-interrupted':'Se interrumpió la actualización de',
  'repair-interrupted':'Se interrumpió la preparación o reparación de',
  'recover-interrupted':'Se interrumpió la recuperación de',
};
const category = (entry: Experience): Exclude<Category,'all'> => entry.workflow==='coco-media'?'media':entry.workflow==='coco-standalone'?'standalone':'minecraft';
const meta = (entry:Experience) => category(entry)==='minecraft' ? ['Minecraft',entry.minecraftVersion].filter(Boolean).join(' ') : catLabels[category(entry)];

// Curated Steam promotional microtrailers, never video URLs from untrusted imports.
const gameHoverPreviews:Record<string,{url:string;bytes:number}> = hoverPreviews;
const gameScreenshots:Record<string,string[]> = screenshotList;
const hoverVideoPool=new HoverVideoPool(gameHoverPreviews);
/** Clips already on disk; any other one the player reaches for jumps the download line. */
const previewsOnDisk=new Set<string>();
function prioritizePreview(id:string){
  if(isTauri()&&Object.hasOwn(gameHoverPreviews,id)&&!previewsOnDisk.has(id))void invoke('prioritize_preview',{id}).catch(()=>{});
}
// What is on screen downloads first.
hoverVideoPool.onVisibleWithoutFile=prioritizePreview;
function previewVideoInCard(card:HTMLElement,shouldPlay:boolean){
  const id=card.dataset.previewId;
  if(!id)return;
  if(shouldPlay)prioritizePreview(id);
  if(shouldPlay)hoverVideoPool.play(id,card.querySelector<HTMLElement>('.card-hover-slot'));
  else hoverVideoPool.pause(id,card.querySelector<HTMLElement>('.card-hover-slot'));
}
function HoverPreview({id}:{id:string}){
  const target=React.useRef<HTMLSpanElement>(null);
  useEffect(()=>{
    if(target.current)return hoverVideoPool.registerSlot(id,target.current);
  },[id]);
  return <span ref={target} className="card-hover-slot" aria-hidden="true"/>;
}

/** Stage counters are independent. A full download bar cannot imply that an
 * extraction, verification or atomic commit has already finished. */
const AVATAR_CACHE='coco2-avatar-v1';
function readCachedAvatar(){try{return localStorage.getItem(AVATAR_CACHE);}catch{return null;}}
function cacheAvatar(value:string|null){
  try{if(value)localStorage.setItem(AVATAR_CACHE,value);else localStorage.removeItem(AVATAR_CACHE);}
  catch{/* the file on disk stays the source of truth */}
}
/** Any picture becomes one small square WebP, so a huge photo never reaches disk. */
async function squareAvatar(file:File){
  if(file.size>40*1024*1024)throw new Error('Image too large');
  const bitmap=await createImageBitmap(file);
  try{
    const side=Math.min(bitmap.width,bitmap.height);
    if(!side)throw new Error('Empty image');
    const canvas=document.createElement('canvas');
    canvas.width=canvas.height=AVATAR_SIDE;
    const context=canvas.getContext('2d');
    if(!context)throw new Error('Canvas unavailable');
    context.imageSmoothingQuality='high';
    context.drawImage(bitmap,(bitmap.width-side)/2,(bitmap.height-side)/2,side,side,0,0,AVATAR_SIDE,AVATAR_SIDE);
    return canvas.toDataURL('image/webp',.86);
  }finally{bitmap.close();}
}
const AVATAR_SIDE=256;
function ProfileAvatar({src,name}:{src:string|null;name:string|null|undefined}){
  return <span className="coco-avatar">{src?<img src={src} alt=""/>:<b aria-hidden="true">{(name||'?').charAt(0).toUpperCase()}</b>}</span>;
}
/** Fixed positions, so the panel looks the same every time and never re-renders. */
const StageAmbience=React.memo(function StageAmbience(){
  return <div className="coco-ambience" aria-hidden="true"><i className="coco-halo"/><i className="coco-sweep"/><i className="coco-ruler"/>{Array.from({length:16},(_,index)=><i key={index} className="coco-ember" style={{'--x':`${(index*37+11)%100}%`,'--size':`${2+index%3}px`,'--rise':`${9+(index*7)%11}s`,'--delay':`${-(index*1.7)}s`,'--sway':`${index%2?14:-14}px`,'--ember':index%4===0?'var(--gold)':'var(--hot)'} as React.CSSProperties}/>)}</div>;
});
function NativeStageRail({phase}:{phase:string|undefined}){
  const view=nativeStageView(phase||'');
  if(!view)return null;
  // Equal segments in one row: the current one breathes, finished ones fill. No caption
  // line, the segment says where it is; screen readers still get the full sentence.
  return <div className="coco-native-stages" aria-label={`Progreso de la operación: ${view.currentLabel}`}>
    <ol className="coco-native-stage-list" style={{'--stages':view.steps.length} as React.CSSProperties}>{view.steps.map(step=><li
      key={step.id} className={`coco-native-stage-${step.state}`}
      aria-current={step.state==='current'?'step':undefined}>
      <span className="coco-native-stage-marker" aria-hidden="true"/><span className="coco-native-stage-name">{step.label}</span>
    </li>)}</ol>
  </div>;
}

function restoreFavorites(): Set<string> {
  try {
    const value:unknown=JSON.parse(localStorage.getItem(favoriteKey)||'[]');
    return new Set(Array.isArray(value)?value.filter((id):id is string=>typeof id==='string'):[]);
  }catch{return new Set();}
}

function App(){
  const [items,setItems]=useState<Experience[]>(restoreCatalogSnapshot);
  const itemsLive=React.useRef(items);
  itemsLive.current=items;
  const [catalogLoaded,setCatalogLoaded]=useState(false);
  const [catalogSync,setCatalogSync]=useState<CatalogSyncState>('idle');
  const lastCatalogSync=React.useRef(0);
  const [seenCatalog,setSeenCatalog]=useState(restoreSeenCatalog);
  const [arrival,setArrival]=useState<string|null>(null);
  const [cachedPreviews,setCachedPreviews]=useState<Map<string,string>>(new Map());
  const [filter,setFilter]=useState<LibraryFilter>('all');
  const [sort,setSort]=useState<LibrarySort>('recent');
  const stageArt=React.useRef<HTMLDivElement>(null);
  const [loadError,setLoadError]=useState('');
  const [localInstances,setLocalInstances]=useState<Map<string,LocalInstance>>(new Map());
  const [catalogSources,setCatalogSources]=useState<Map<string,CatalogProvenance>>(new Map());
  const [view,setView]=useState<View>('library');
  const [search,setSearch]=useState('');
  const [searchOpen,setSearchOpen]=useState(false);
  const [searchActiveIndex,setSearchActiveIndex]=useState(-1);
  const searchBoxRef=React.useRef<HTMLDivElement>(null);
  const priorSearchFocus=React.useRef<HTMLElement|null>(null);
  const [favorites,setFavorites]=useState(restoreFavorites);
  const [activity,setActivity]=useState(readActivity);
  const [selected,setSelected]=useState<Experience|null>(null);
  const detailFocusReturn=React.useRef<HTMLElement|null>(null);
  const openDetails=(entry:Experience)=>{
    prioritizePreview(entry.id);
    if(Object.hasOwn(gameScreenshots,entry.id))warmScreenshots(gameScreenshots[entry.id],true);
    if(!selected)detailFocusReturn.current=document.activeElement instanceof HTMLElement?document.activeElement:null;
    stageArt.current?.classList.remove('is-lit');
    setSelected(entry);setOperationMessage('');
    setSeenCatalog(previous=>{
      if(!previous||previous.has(entry.id))return previous;
      const next=new Set(previous).add(entry.id);saveSeenCatalog(next);return next;
    });
  };
  const closeDetails=()=>{
    setSelected(null);
    const previous=detailFocusReturn.current;
    detailFocusReturn.current=null;
    // Explorer review takes modal focus as soon as this sheet closes. A queued
    // animation-frame restoration to the old game card can steal it back after
    // the inbox has already mounted, leaving its dialog keyboard-inaccessible.
    if(previous&&!pendingPackageInboxRef.current)
      window.requestAnimationFrame(()=>{
        if(!pendingPackageInboxRef.current&&previous.isConnected)previous.focus();
      });
  };
  const onDetailKey=(event:React.KeyboardEvent<HTMLElement>)=>{
    if(event.key==='Escape'){
      event.preventDefault();event.stopPropagation();closeDetails();
    }else if(event.key==='Tab'&&trapDialogTab(event.currentTarget,document.activeElement,event.shiftKey)){
      event.preventDefault();
    }
  };
  const [systemReducedMotion,setSystemReducedMotion]=useState(()=>{
    try{return window.matchMedia('(prefers-reduced-motion: reduce)').matches;}
    catch{return false;}
  });
  // Never expose an animation-off button. Honor OS accessibility immediately,
  // including suspension of resource-intensive video previews.
  const motion=!systemReducedMotion;
  const [introStage,setIntroStage]=useState<'hold'|'reveal'|'done'|'none'>(motion?'hold':'none');
  // The window starts in the presentation's color; afterwards resizing must not show it.
  const introCovering=introStage==='hold';
  useEffect(()=>{
    if(introCovering)return;
    document.documentElement.classList.remove('coco-booting');
    if(isTauri())void getCurrentWindow().setBackgroundColor('#0b0a0f').catch(console.warn);
  },[introCovering]);
  useEffect(()=>{
    if(typeof window.matchMedia!=='function')return;
    const query=window.matchMedia('(prefers-reduced-motion: reduce)');
    const changed=()=>setSystemReducedMotion(query.matches);
    changed();
    if(typeof query.addEventListener==='function'){
      query.addEventListener('change',changed);return()=>query.removeEventListener('change',changed);
    }
    query.addListener?.(changed);return()=>query.removeListener?.(changed);
  },[]);
  useEffect(()=>{
    hoverVideoPool.start();
    return()=>hoverVideoPool.stop();
  },[]);
  useEffect(()=>hoverVideoPool.setEnabled(motion),[motion]);
  useEffect(()=>{
    hoverVideoPool.prioritize(items.filter(entry=>category(entry)==='standalone').slice(-4).map(entry=>entry.id));
  },[items]);
  // Clips already on disk play instantly from this launch on; whatever is
  // missing downloads now, newest game first, and joins as soon as it lands.
  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;let stop:(()=>void)|undefined;
    const accept=(entries:{id:string;path:string}[])=>{
      if(disposed||!entries.length)return;
      setCachedPreviews(previous=>{
        const next=new Map(previous);
        for(const {id,path} of entries){
          const url=convertFileSrc(path);
          next.set(id,url);hoverVideoPool.setLocalFile(id,url);previewsOnDisk.add(id);
        }
        return next;
      });
    };
    let stopFinished:(()=>void)|undefined;
    let fallback:number|undefined;
    const newestFirst=restoreCatalogSnapshot().map(entry=>entry.id).reverse();
    // The clips come first: screenshots, and network preloading of clips not yet on disk, wait
    // until the clips are saved instead of splitting the connection with them.
    let released=false;
    const release=()=>{
      if(released||disposed)return;
      released=true;
      hoverVideoPool.setNetworkWarmup(true);
      warmAllScreenshots(gameScreenshots,newestFirst);
    };
    void (async()=>{
      try{
        const unlisten=await listen<{id:string;path:string}>('coco2://preview-ready',event=>accept([event.payload]));
        if(disposed){unlisten();return;}
        stop=unlisten;
        const finished=await listen('coco2://preview-cache-finished',release);
        if(disposed){finished();return;}
        stopFinished=finished;
        accept(await invoke<{id:string;path:string}[]>('get_preview_cache'));
        if(disposed)return;
        hoverVideoPool.setNetworkWarmup(false);
        const queued=await invoke<number>('start_preview_cache',{priority:newestFirst});
        // Nothing left to fetch, or another start already owns it: go on now, and never wait forever.
        if(queued===0)release();else fallback=window.setTimeout(release,90_000);
      }catch(error){console.warn('Preview cache unavailable, streaming instead:',error);release();}
    })();
    return()=>{disposed=true;stop?.();stopFinished?.();window.clearTimeout(fallback);};
  },[]);
  // The card under the pointer must not keep playing behind an opened sheet.
  useEffect(()=>{if(selected)hoverVideoPool.pauseActive();},[selected?.id]);
  useEffect(()=>{
    if(!motion)document.querySelectorAll<HTMLElement>('.experience-card').forEach(card=>previewVideoInCard(card,false));
  },[motion]);
  const [runtime,setRuntime]=useState<RuntimeEvent|null>(null);
  const [observedGameIds,setObservedGameIds]=useState<string[]>([]);
  const [gameProcessUncertain,setGameProcessUncertain]=useState(false);
  const [identity,setIdentity]=useState<LocalIdentity>({configured:false,username:null});
  const [identityName,setIdentityName]=useState('');
  const [confirmIdentity,setConfirmIdentity]=useState(false);
  const [savingIdentity,setSavingIdentity]=useState(false);
  const [identityError,setIdentityError]=useState('');
  const [installPlan,setInstallPlan]=useState<InstallPlan|null>(null);
  const [installing,setInstalling]=useState<string|null>(null);
  const [installProgress,setInstallProgress]=useState<InstallProgress|null>(null);
  const [installTransferRate,setInstallTransferRate]=useState<NativeTransferRate|null>(null);
  const [repairRecovering,setRepairRecovering]=useState<string|null>(null);
  const [autoRepairing,setAutoRepairing]=useState<string|null>(null);
  const autoRepairTried=React.useRef(new Set<string>());
  const [upgradePlan,setUpgradePlan]=useState<UpgradePlan|null>(null);
  const [installedSizes,setInstalledSizes]=useState<Map<string,number>>(new Map());
  const [uninstallConfirm,setUninstallConfirm]=useState<string|null>(null);
  const [uninstalling,setUninstalling]=useState<string|null>(null);
  const [installLocation,setInstallLocation]=useState<InstallLocation|null>(null);
  const [locationBusy,setLocationBusy]=useState(false);
  const [locationError,setLocationError]=useState('');
  const [moveDraft,setMoveDraft]=useState<MoveDraft|null>(null);
  const [moving,setMoving]=useState<string|null>(null);
  const [authorizing,setAuthorizing]=useState(false);
  const [startingSteam,setStartingSteam]=useState(false);
  const [firstGameRun,setFirstGameRun]=useState(false);
  const [defenderOutcome,setDefenderOutcome]=useState('');
  const [diagnosticNote,setDiagnosticNote]=useState('');
  const [defenderBusy,setDefenderBusy]=useState(false);
  const [avatar,setAvatar]=useState<string|null>(readCachedAvatar);
  const [avatarBusy,setAvatarBusy]=useState(false);
  const [avatarError,setAvatarError]=useState('');
  const [upgrading,setUpgrading]=useState<string|null>(null);
  const [upgradeRecovering,setUpgradeRecovering]=useState<string|null>(null);
  const [upgradeOutcome,setUpgradeOutcome]=useState<UpgradeOutcome|null>(null);
  const [repairRecoveryStatus,setRepairRecoveryStatus]=useState<Map<string,RepairRecoveryStatus>>(new Map());
  const [pendingOperations,setPendingOperations]=useState<PendingStandaloneOperation[]>([]);
  const foregroundRecoveryGate=React.useRef(new ForegroundRecoveryGate());
  const [busy,setBusy]=useState(false);
  const nativeOperationGate=React.useRef(new NativeOperationGate());
  const nativeProgressSampler=React.useRef(new NativeProgressSampler());
  const nativeTransferRateMeter=React.useRef(new NativeTransferRateMeter());
  const [operationMessage,setOperationMessage]=useState('');
  const [nativeFailure,setNativeFailure]=useState<NativeFailureAdvice|null>(null);
  const [mediaCatalog,setMediaCatalog]=useState<MediaEntry[]>([]);
  const [mediaLoading,setMediaLoading]=useState(false);
  const [mediaPlaying,setMediaPlaying]=useState<{stream:PreparedMediaStream;title:string;subtitle:string;startAt:number|null}|null>(null);
  // The next episode waits for the current stream to close before it opens its own.
  const [queuedEpisode,setQueuedEpisode]=useState<{entry:Experience;episode:MediaEpisode}|null>(null);
  const [mediaError,setMediaError]=useState('');
  const [streamLoading,setStreamLoading]=useState('');
  const mediaPrepareGate=React.useRef(new MediaPreparationGate());
  const mediaSessionEpoch=React.useRef(0);
  const mediaRefreshGate=React.useRef(new MediaSessionRefreshGate());
  // Downloading films for offline viewing is no longer offered; one already on disk still plays from it.
  const [mediaDownloadActive]=useState<{id:string;episodeId:string;title:string}|null>(null);
  const mediaDownloadGate=React.useRef(new NativeMediaDownloadGate());
  const [mediaDownloadProgress,setMediaDownloadProgress]=useState<MediaDownloadProgress|null>(null);
  const [mediaCancelPending,setMediaCancelPending]=useState(false);
  const [appUpdate,setAppUpdate]=useState<AppUpdateProgress>({stage:'idle',version:'',percent:0,downloaded:0,total:0,message:''});
  const [hostStudioAvailable,setHostStudioAvailable]=useState(false);
  const [securityGuide,setSecurityGuide]=useState<GameSecurityGuide|null>(null);
  const [securityBusy,setSecurityBusy]=useState(false);
  const [securityError,setSecurityError]=useState('');
  const [securityCopied,setSecurityCopied]=useState(false);
  const securityRequestEpoch=React.useRef(0);
  const [hostStudioOpen,setHostStudioOpen]=useState(false);
  const [catalogEpoch,setCatalogEpoch]=useState(0);
  const catalogRefreshGate=React.useRef(new CatalogRefreshGate());
  const trustedCatalogSnapshot=React.useRef(new Map<string,Experience>());
  const [inbox,setInbox]=useState(readPersistedPackageInbox);
  const [inboxPersistenceError,setInboxPersistenceError]=useState(false);
  const incomingPackages=inbox.paths;
  // Keep the authoritative UI queue synchronized *before* scheduling React.
  // A native Explorer event can arrive during an unrelated concurrent render;
  // deriving this gate from the last rendered inbox would briefly clear it
  // while the uncommitted new path is still awaiting a React commit.
  const inboxLive=React.useRef(inbox);
  const activationDrainRef=React.useRef<PackageActivationDrain<unknown>|null>(null);
  const pendingPackageInboxRef=React.useRef(Boolean(inbox.paths.length||inbox.dropped));
  const commitInbox=(next:PackageInboxState):boolean=>{
    // The durable record must precede the native FIFO ACK. A WebView restart
    // after a successful ACK recovers the review-only path, never an import
    // approval. Failed storage means native retains the unconfirmed request.
    const persisted=persistPackageInbox(next);
    setInboxPersistenceError(!persisted&&next.paths.length>0);
    inboxLive.current=next;
    // Overflow counts represent packages the UI could not retain. Keep the
    // updater fenced until the user acknowledges that warning explicitly.
    pendingPackageInboxRef.current=Boolean(next.paths.length||next.dropped);
    setInbox(next);
    return persisted;
  };
  // Windows can deliver a new package while the game-details modal owns focus,
  // Host Studio is writing, a game is installing or a movie is playing.
  // Defer its visual review: overlapping aria-modal dialogs would compete for
  // keyboard focus and could obscure an unconfirmed game operation.
  const packageReviewDeferred=Boolean(selected||hostStudioOpen||nativeOperationGate.current.busy()||
    installing||upgrading||upgradeRecovering||repairRecovering||
    mediaPlaying||streamLoading||mediaDownloadActive||
    appUpdate.stage==='downloading'||appUpdate.stage==='installing');
  // A fixed overlay does not prevent wheel events from scrolling the library
  // beneath it. Use one shared lock for all four modal surfaces; the sheet,
  // video player and Host Studio retain their own scrolling and keyboard focus.
  useLayoutEffect(()=>{
    if(!(selected||mediaPlaying||hostStudioOpen||
      (incomingPackages.length>0&&!packageReviewDeferred)))return;
    return lockBackgroundScroll(document,window);
  },[selected,mediaPlaying,hostStudioOpen,incomingPackages.length,packageReviewDeferred]);
  // Hover clips stop playing while a game, a movie or heavy work is on screen. Their download to
  // disk and the screenshot warm-up keep going regardless: the host wants them always ready.
  useEffect(()=>{
    const heavyWork=Boolean(
      runtime?.state==='running'||observedGameIds.length||
      installing||upgrading||repairRecovering||
      upgradeRecovering||mediaPlaying||streamLoading||mediaDownloadActive||busy||
      incomingPackages.length||hostStudioOpen||
      appUpdate.stage==='downloading'||appUpdate.stage==='installing'
    );
    hoverVideoPool.setBackgroundBusy(heavyWork);
  },[runtime?.state,observedGameIds.length,installing,upgrading,repairRecovering,upgradeRecovering,mediaPlaying,streamLoading,
    mediaDownloadActive,busy,incomingPackages.length,hostStudioOpen,
    appUpdate.stage]);
  const inboxDialogRef=React.useRef<HTMLDivElement>(null);
  const priorInboxFocus=React.useRef<HTMLElement|null>(null);
  const wasInboxOpen=React.useRef(false);
  const [bootstrapLoaded,setBootstrapLoaded]=useState(false);
  // The host asked for no welcome at all: the library is the first thing anyone sees.
  const [firstRunDone,setFirstRunDone]=useState(true);
  // The welcome is a real modal, not a background decoration. A cold Explorer
  // open can arrive before the new user's first render; presenting the Reyna
  // welcome and package consent dialog together creates competing focus traps.
  // Prioritize the authenticated review, then resume onboarding unchanged.
  // With games in the catalog they are the welcome: it only explains an empty or unreachable one.
  const welcomeVisible=view==='library'&&bootstrapLoaded&&!firstRunDone&&isTauri()&&
    (items.length===0||Boolean(loadError))&&
    incomingPackages.length===0&&!selected&&!hostStudioOpen&&!mediaPlaying&&!streamLoading&&
    !nativeOperationGate.current.busy()&&
    appUpdate.stage!=='downloading'&&appUpdate.stage!=='installing';
  const [packagePickerRequest,setPackagePickerRequest]=useState(0);
  const packagePickerSerial=React.useRef(0);
  const updateRunning=React.useRef(false);
  const updateAttempt=React.useRef(0);
  const nativeWriteBusy=React.useRef(false);
  nativeWriteBusy.current=Boolean(runtime?.state==='running'||observedGameIds.length||gameProcessUncertain||
    installing||upgrading||upgradeRecovering||
    repairRecovering||mediaDownloadActive||
    busy||updateRunning.current||
    appUpdate.stage==='downloading'||appUpdate.stage==='installing');

  const refreshNativeCatalog=async()=>{
    if(!isTauri())return;
    // A commit followed by a failed catalog read must never open an older
    // version of the same game using the last in-memory snapshot. The visible
    // previous library remains readable, but is not a post-commit receipt.
    trustedCatalogSnapshot.current=new Map();
    await publishVerifiedCatalog(
      catalogRefreshGate.current,
      ()=>invoke<Experience[]>('get_catalog'),
      result=>Array.isArray(result)&&result.length>0&&result.every(x=>typeof x.id==='string'&&typeof x.name==='string'),
      result=>{
        const nextById=new Map(result.map(entry=>[entry.id,entry]));
        trustedCatalogSnapshot.current=nextById;
        saveCatalogSnapshot(result);
        const known=new Set(itemsLive.current.map(entry=>entry.id));
        const added=result.filter(entry=>!known.has(entry.id));
        if(added.length)setArrival(added.length===1?added[0].name:`${added.length} juegos nuevos`);
        setItems([...result]);
        // Old disk/provenance badges cannot be trusted across a new revision.
        // Their new read-only states arrive independently after first paint.
        setLocalInstances(new Map());
        setCatalogSources(new Map());
        setSelected(previous=>previous?nextById.get(previous.id)||null:null);
        setInstallPlan(null);setUpgradePlan(null);setUpgradeOutcome(null);
        setCatalogEpoch(previous=>previous+1);
      },
      async isCurrent=>{
        const [observed,sources]=await Promise.allSettled([
          invoke<LocalInstance[]>('get_local_instances'),
          invoke<CatalogProvenance[]>('get_catalog_provenance'),
        ]);
        if(!isCurrent())return;
        if(observed.status==='fulfilled')setLocalInstances(new Map(observed.value.map(entry=>[entry.id,entry])));
        else console.warn('Instance presence unavailable:',observed.reason);
        if(sources.status==='fulfilled')setCatalogSources(new Map(sources.value.map(entry=>[entry.id,entry])));
        else console.warn('Verified provenance unavailable:',sources.reason);
      },
    );
  };

  useEffect(()=>{
    let active=true;
    (async()=>{
      try {
        const result:Experience[]=isTauri() ? await invoke<Experience[]>('get_catalog') : await fetch('/catalog.json').then(res=>{if(!res.ok)throw Error(`HTTP ${res.status}`);return res.json() as Promise<Experience[]>;});
        if(!Array.isArray(result)||!result.length||!result.every(x=>typeof x.id==='string'&&typeof x.name==='string'))throw Error('Catálogo inválido');
        if(active){
          // A background sync/accepted import can supersede slow bootstrap.
          if(trustedCatalogSnapshot.current.size===0){
            trustedCatalogSnapshot.current=new Map(result.map(entry=>[entry.id,entry]));
            saveCatalogSnapshot(result);
            setItems(result);
          }
          setSeenCatalog(previous=>{
            if(previous)return previous;
            const baseline=new Set(result.map(entry=>entry.id));
            saveSeenCatalog(baseline);return baseline;
          });
          setCatalogLoaded(true);
          setLoadError('');
        }
        if(isTauri()){
          // Cards may paint immediately after the small verified catalog
          // arrives. Independent native diagnostics are launched concurrently:
          // a slow drive or optional Host Studio check cannot delay the entire
          // library, first-run UI or recovery journal scan by several roundtrips.
          void Promise.allSettled([
            invoke<LocalInstance[]>('get_local_instances')
              .then(value=>{if(active&&catalogRefreshGate.current.current(0))setLocalInstances(new Map(value.map(entry=>[entry.id,entry])));}),
            invoke<CatalogProvenance[]>('get_catalog_provenance')
              .then(value=>{if(active&&catalogRefreshGate.current.current(0))setCatalogSources(new Map(value.map(entry=>[entry.id,entry])));}),
            invoke<LocalIdentity>('get_local_identity')
              .then(value=>{if(active){setIdentity(value);setIdentityName(value.username||'');}}),
            invoke<boolean>('host_studio_available')
              .then(value=>{if(active)setHostStudioAvailable(value);}),
          ]).then(results=>{
            results.forEach((entry,index)=>{
              if(entry.status==='rejected'&&active)
                console.warn('Optional startup diagnostic unavailable:',index,entry.reason);
            });
          });
        }
      } catch(error){if(active)setLoadError(error instanceof Error?error.message:'No se pudo cargar');}
    })().finally(()=>{if(active)setBootstrapLoaded(true);});
    return()=>{active=false;};
  },[]);

  useEffect(()=>{
    if(incomingPackages.length&&!packageReviewDeferred){
      if(!wasInboxOpen.current){
        wasInboxOpen.current=true;
        priorInboxFocus.current=document.activeElement instanceof HTMLElement?document.activeElement:null;
      }
      inboxDialogRef.current?.focus();
    }else if(wasInboxOpen.current){
      wasInboxOpen.current=false;
      const prior=priorInboxFocus.current;
      priorInboxFocus.current=null;
      // When Explorer review is temporarily deferred by another modal, its
      // former focus target belongs to the obscured page. Only restore it if
      // review has actually completed, not when a game/player dialog takes over.
      if(!packageReviewDeferred&&prior?.isConnected)prior.focus();
    }
  },[incomingPackages[0],packageReviewDeferred]);

  // Explorer activation carries untrusted paths, never trusted catalog data.
  // Cold starts must work even if an event subscription is unavailable. The
  // native queue remains authoritative; event callbacks only request review.
  // No file is imported/installed/launched by this effect.
  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;
    let unlisten:(()=>void)|undefined;
    let stagedNativePrefix:string[]=[];
    const enqueue=(payload:unknown)=>{
      if(disposed)return;
      // Explorer takes priority over a not-yet-mounted first-run picker. A
      // click immediately before a cold/warm delivery used to leave its picker
      // intent armed; finishing that inbox review then opened an unexpected
      // Windows file dialog. Empty focus drains and malformed payloads must
      // not consume an explicit manual click.
      const paths=extractPackagePaths(payload);
      // Native may have 96 accepted requests while React already contains
      // 95 unrelated reviews. Never ACK the 96th+ native path merely because
      // a React overflow counter noticed it: keep the undisplayed suffix in
      // the native FIFO until a review is dismissed and space becomes free.
      // Duplicates already present are safe to ACK as a matching FIFO prefix.
      const retained=new Set(inboxLive.current.paths);
      const accepted:string[]=[];
      for(const path of paths){
        if(!retained.has(path)){
          if(retained.size>=MAX_PENDING_PACKAGES)break;
          retained.add(path);
        }
        accepted.push(path);
      }
      stagedNativePrefix=accepted;
      if(accepted.some(isPortablePackageFile))setPackagePickerRequest(0);
      if(accepted.length&&!commitInbox(enqueuePackageRequests(inboxLive.current,accepted)))
        throw new Error('Explorer review could not be saved locally; native request retained');
    };
    const drain=new PackageActivationDrain<unknown>(
      ()=>invoke<unknown>('peek_pending_package_open_requests'),
      enqueue,
      error=>console.warn('Windows package inbox recovery unavailable:',error),
      4,
      async _payload=>{
        // These are precisely the entries just staged in the live React
        // queue, not all entries observed in the native peek snapshot.
        const paths=stagedNativePrefix;
        stagedNativePrefix=[];
        if(!paths.length)return;
        if(disposed)return;
        const acknowledged=await invoke<boolean>('acknowledge_pending_package_open_requests',{paths});
        if(!acknowledged)throw new Error('Native package receipt changed before confirmation; FIFO retained');
      },
    );
    activationDrainRef.current=drain;
    const refocus=()=>{if(!document.hidden)void drain.trigger();};
    // Install focus/visibility fallback BEFORE awaiting subscription. If
    // listen() rejects, the user can still recover any queued cold/warm open.
    window.addEventListener('focus',refocus);
    document.addEventListener('visibilitychange',refocus);
    // Native owns every unacknowledged path. The Tauri event is a wake-up,
    // never a path delivery: app.emit() may succeed without a JS subscriber.
    void listen<unknown>('coco2://package-open-request',_event=>void drain.trigger())
      .then(stop=>{
        if(disposed){stop();return;}
        unlisten=stop;
        // Signal native readiness only after the event listener exists. A
        // cold drain may still be in flight; native retains new requests until
        // an explicit take, so run another pass after the readiness ACK too.
        void (async()=>{
          await drain.trigger();
          if(disposed)return;
          try{
            const confirmed=await invoke<boolean>('confirm_package_open_listener_ready');
            if(!confirmed)console.warn('Windows package listener could not confirm readiness');
          }catch(error){
            console.warn('Windows package listener readiness unavailable:',error);
          }
          if(!disposed)void drain.trigger();
        })();
      })
      .catch(error=>console.warn('Windows package activation unavailable:',error));
    // Crucially independent of the success/failure of native listen().
    void drain.trigger();
    return()=>{
      disposed=true;
      drain.dispose();
      if(activationDrainRef.current===drain)activationDrainRef.current=null;
      unlisten?.();
      window.removeEventListener('focus',refocus);
      document.removeEventListener('visibilitychange',refocus);
    };
  },[]);

  // Reconcile interrupted native operations when Coco becomes foregrounded.
  // This is read-only; no journal is replayed or repaired without a click.
  // A friend can return after an external game exits or a disk reconnects
  // without reopening Coco just to see the recovery action appear.
  useEffect(()=>{
    if(!isTauri()||!bootstrapLoaded)return;
    let live=true;
    const gate=foregroundRecoveryGate.current;
    const inspect=async()=>{
      if(!live||document.hidden||nativeWriteBusy.current||nativeOperationGate.current.busy())return;
      const ticket=gate.begin(Date.now());
      if(ticket===null)return;
      try{
        const [journals,instances]=await Promise.allSettled([
          invoke<PendingStandaloneOperation[]>('recover_pending_standalone_operations'),
          invoke<LocalInstance[]>('get_local_instances'),
        ]);
        if(!live||!gate.isCurrent(ticket)||nativeWriteBusy.current||nativeOperationGate.current.busy())return;
        if(journals.status==='fulfilled')
          setPendingOperations(journals.value.filter(x=>x.status!=='none'));
        else console.warn('Pending native journal inspection unavailable:',journals.reason);
        if(instances.status==='fulfilled')
          setLocalInstances(new Map(instances.value.map(x=>[x.id,x])));
      }finally{gate.finish(ticket);}
    };
    const onFocus=()=>{void inspect();};
    window.addEventListener('focus',onFocus);
    document.addEventListener('visibilitychange',onFocus);
    gate.allowImmediateRetry();
    void inspect();
    return()=>{
      live=false;gate.cancel();
      window.removeEventListener('focus',onFocus);
      document.removeEventListener('visibilitychange',onFocus);
    };
  },[bootstrapLoaded,catalogEpoch]);

  // First paint reads the last verified local catalog; HTTPS synchronization is
  // background-only and never replaces cards on a failed verification. A game
  // the host approves must reach an open launcher, not wait for the next launch.
  const syncCatalog=React.useRef<(()=>Promise<void>)|undefined>(undefined);
  syncCatalog.current=async()=>{
    if(!isTauri()||catalogSync==='syncing'||nativeWriteBusy.current)return;
    lastCatalogSync.current=Date.now();
    setCatalogSync('syncing');
    try{
      const result=await invoke<CatalogSyncResult>('sync_catalog_channel');
      // Do not enumerate game folders/recalculate every card when no accepted
      // channel revision has changed.
      if(result.status==='updated')await refreshNativeCatalog();
      setCatalogSync(result.status==='updated'?'updated':result.status==='unchanged'?'current':'local');
    }catch(error){
      setCatalogSync('local');
      console.warn('Remote catalog update unavailable:',error);
    }
  };
  useEffect(()=>{
    if(!isTauri()||!bootstrapLoaded)return;
    void syncCatalog.current?.();
    const interval=window.setInterval(()=>{
      if(!document.hidden)void syncCatalog.current?.();
    },CATALOG_SYNC_INTERVAL_MS);
    const onFocus=()=>{
      if(!document.hidden&&Date.now()-lastCatalogSync.current>CATALOG_SYNC_FOCUS_GAP_MS)void syncCatalog.current?.();
    };
    window.addEventListener('focus',onFocus);
    return()=>{window.clearInterval(interval);window.removeEventListener('focus',onFocus);};
  },[bootstrapLoaded]);
  useEffect(()=>{
    if(!arrival)return;
    const timer=window.setTimeout(()=>setArrival(null),ARRIVAL_NOTICE_MS);
    return()=>window.clearTimeout(timer);
  },[arrival]);

  useEffect(()=>{
    if(!selected||selected.workflow!=='coco-standalone'||!isTauri()){
      setInstallPlan(null);return;
    }
    let active=true;
    setInstallPlan(null);
    void invoke<InstallPlan>('plan_standalone_install',{id:selected.id})
      .then(plan=>{if(active)setInstallPlan(plan);})
      .catch(error=>{if(active)setOperationMessage(String(error));});
    return()=>{active=false;};
  },[selected?.id,catalogEpoch]);
  useEffect(()=>{
    securityRequestEpoch.current++;
    setSecurityGuide(null);setSecurityBusy(false);setSecurityError('');setSecurityCopied(false);
  },[selected?.id]);
  const requestGameSecurityGuide=async(entry:Experience)=>{
    if(securityBusy||!isTauri()||entry.workflow!=='coco-standalone')return;
    const epoch=++securityRequestEpoch.current;
    setSecurityBusy(true);setSecurityError('');setSecurityGuide(null);
    try{
      const guide=await invoke<GameSecurityGuide>('get_game_security_guide',{id:entry.id});
      if(securityRequestEpoch.current===epoch&&guide.id===entry.id)setSecurityGuide(guide);
    }catch(error){
      if(securityRequestEpoch.current===epoch)
        setSecurityError(`No se pudo comprobar la carpeta del juego. ${String(error)}`);
    }finally{if(securityRequestEpoch.current===epoch)setSecurityBusy(false);}
  };
  const openSecuritySettings=async()=>{
    if(!isTauri())return;
    try{await invoke('open_windows_security');}
    catch(error){setSecurityError(`Abre Seguridad de Windows desde Inicio. ${String(error)}`);}
  };

  useEffect(()=>{
    if(!selected||selected.workflow!=='coco-standalone'||!isTauri()
      ||localInstances.get(selected.id)?.state!=='folder-present')return;
    let active=true;
    void invoke<RepairRecoveryStatus>('get_standalone_repair_recovery_status',{id:selected.id})
      .then(status=>{if(active)setRepairRecoveryStatus(old=>new Map(old).set(status.id,status));})
      .catch(error=>{
        if(active)console.warn('Journal status unavailable; recovery can still be requested:',error);
      });
    return()=>{active=false;};
  },[selected?.id,localInstances,catalogEpoch]);

  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;let stop:(()=>void)|undefined;
    void listen<boolean>('coco2://windows-authorization',event=>{if(!disposed)setAuthorizing(event.payload);})
      .then(unlisten=>{if(disposed)unlisten();else stop=unlisten;}).catch(console.error);
    let stopSteam:(()=>void)|undefined;
    let stopFirstRun:(()=>void)|undefined;
    void listen<boolean>('coco2://first-run',event=>{if(!disposed)setFirstGameRun(event.payload);})
      .then(unlisten=>{if(disposed)unlisten();else stopFirstRun=unlisten;}).catch(console.error);
    void listen<boolean>('coco2://steam-starting',event=>{if(!disposed)setStartingSteam(event.payload);})
      .then(unlisten=>{if(disposed)unlisten();else stopSteam=unlisten;}).catch(console.error);
    return()=>{disposed=true;stop?.();stopSteam?.();stopFirstRun?.();};
  },[]);

  useEffect(()=>{
    setMoveDraft(null);setLocationError('');
    if(!selected||selected.workflow!=='coco-standalone'||!isTauri()){setInstallLocation(null);return;}
    let active=true;
    void invoke<InstallLocation>('get_install_location',{id:selected.id})
      .then(location=>{if(active)setInstallLocation(location);})
      .catch(error=>console.warn('Install location unavailable:',error));
    return()=>{active=false;};
  },[selected?.id,catalogEpoch]);

  useEffect(()=>{
    setUninstallConfirm(null);
    if(!selected||selected.workflow!=='coco-standalone'||!isTauri()
      ||localInstances.get(selected.id)?.state!=='folder-present')return;
    let active=true;
    void invoke<{id:string;bytes:number}>('get_installed_size',{id:selected.id})
      .then(size=>{if(active)setInstalledSizes(old=>new Map(old).set(size.id,size.bytes));})
      .catch(error=>console.warn('Installed size unavailable:',error));
    return()=>{active=false;};
  },[selected?.id,localInstances]);

  useEffect(()=>{
    if(!isTauri())return;
    let active=true;
    void invoke<string|null>('get_profile_avatar')
      .then(saved=>{if(active){setAvatar(saved);cacheAvatar(saved);}})
      .catch(error=>console.warn('Avatar unavailable:',error));
    return()=>{active=false;};
  },[]);

  useEffect(()=>{
    if(!selected||selected.workflow!=='coco-standalone'||!isTauri()
      ||localInstances.get(selected.id)?.state!=='folder-present'){
      setUpgradePlan(null);return;
    }
    let active=true;
    setUpgradePlan(null);setUpgradeOutcome(null);
    void invoke<UpgradePlan>('plan_standalone_upgrade',{id:selected.id})
      .then(plan=>{if(active)setUpgradePlan(plan);})
      .catch(error=>{if(active)console.warn('Native upgrade preflight unavailable:',error);});
    return()=>{active=false;};
  },[selected?.id,localInstances,catalogEpoch]);

  useEffect(()=>{
    if(!selected||selected.workflow!=='coco-media'||!isTauri()||mediaCatalog.length)return;
    let active=true;setMediaLoading(true);setMediaError('');
    void invoke<MediaEntry[]>('get_media_catalog').then(result=>{if(active)setMediaCatalog(result);})
      .catch(error=>{if(active)setMediaError(String(error));})
      .finally(()=>{if(active)setMediaLoading(false);});
    return()=>{active=false;};
  },[selected?.id,mediaCatalog.length]);
  // Navigating away during a slow native stream preparation must never reopen
  // the media player unexpectedly. Keep native work single-flight until its
  // promise settles; dispose its proxy token if the user left meanwhile.
  useEffect(()=>{
    mediaPrepareGate.current.cancelIfChanged(selected?.id);
  },[selected?.id]);

  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;let stop:(()=>void)|undefined;
    void listen<InstallProgress>('coco2://standalone-install-progress',event=>{
      const update=event.payload;
      if(!disposed&&nativeOperationGate.current.acceptsProgress(update.id)&&
        nativeProgressSampler.current.accept(update,performance.now())){
        const observedAt=performance.now();
        setInstallProgress(update);
        setInstallTransferRate(nativeTransferRateMeter.current.observe(update,observedAt));
      }
    }).then(fn=>{if(disposed)fn();else stop=fn;}).catch(console.error);
    return()=>{disposed=true;stop?.();};
  },[]);

  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;let stop:(()=>void)|undefined;
    void listen<MediaDownloadProgress>('coco2://media-download-progress',event=>{
      // Several titles may share one native progress channel. Never display
      // another episode's late report or render thousands of chunk events.
      if(!disposed&&mediaDownloadGate.current.acceptProgress(event.payload,performance.now()))
        setMediaDownloadProgress(event.payload);
    }).then(fn=>{if(disposed)fn();else stop=fn;}).catch(console.error);
    return()=>{disposed=true;stop?.();};
  },[]);

  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;let unlisten:(()=>void)|undefined;
    void listen<RuntimeEvent>('coco2://runtime',event=>{
      // An old process exit (or previous PID from the same game) must not
      // hide a newer launch or overwrite the current install/repair message.
      if(!disposed)setRuntime(current=>reconcileRuntimeEvent(current,event.payload));
    }).then(fn=>{if(disposed)fn();else unlisten=fn;}).catch(console.error);
    void invoke<string[]>('list_running_games').then(ids=>{if(!disposed&&ids.length)setRuntime({id:ids[0],state:'running',pid:null,exitCode:null});}).catch(console.error);
    return()=>{disposed=true;unlisten?.();};
  },[]);

  // Win32 process observations include games opened outside Coco and child
  // processes that outlive a bootstrapper. Poll only while the application is
  // foregrounded; never expose arbitrary process paths, names or identities.
  useEffect(()=>{
    if(!isTauri())return;
    let disposed=false;
    let reading=false;
    const inspect=async()=>{
      if(disposed||reading||document.hidden)return;
      reading=true;
      try{
        const report=await invoke<ActiveGameProcessReport>('get_active_game_processes');
        if(!disposed){
          setObservedGameIds(current=>retainObservedGameIds(current,report.gameIds));
          setGameProcessUncertain(report.status==='unknown');
        }
      }catch{
        if(!disposed)setGameProcessUncertain(true);
      }finally{reading=false;}
    };
    void inspect();
    window.addEventListener('focus',inspect);
    document.addEventListener('visibilitychange',inspect);
    const interval=window.setInterval(()=>void inspect(),30000);
    return()=>{disposed=true;window.clearInterval(interval);window.removeEventListener('focus',inspect);document.removeEventListener('visibilitychange',inspect);};
  },[]);

  useEffect(()=>{try{localStorage.setItem(favoriteKey,JSON.stringify([...favorites]));}catch{}},[favorites]);
  useEffect(()=>{document.body.dataset.motion=motion?'on':'off';},[motion]);
  useEffect(()=>{
    const onKey=(event:KeyboardEvent)=>{
      if(event.key==='Escape'){
        if(incomingPackages.length||hostStudioOpen)return;
        if(searchOpen){setSearchOpen(false);setSearchActiveIndex(-1);return;}
        if(mediaPlaying)closeMedia();else if(selected)closeDetails();
      }
      if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='k'){
        if(incomingPackages.length||hostStudioOpen||selected||mediaPlaying)return;
        priorSearchFocus.current=document.activeElement instanceof HTMLElement?document.activeElement:null;
        event.preventDefault();document.querySelector<HTMLInputElement>('#cocoSearch')?.focus();
        setSearchOpen(true);
      }
    };
    window.addEventListener('keydown',onKey);return()=>window.removeEventListener('keydown',onKey);
  },[selected,mediaPlaying,searchOpen,hostStudioOpen,incomingPackages.length]);

  // Index the trusted catalog once. Typing updates the input instantly while
  // React can defer the heavier list update without blocking keyboard input.
  const searchable=useMemo(()=>indexExperiences(items,meta),[items]);
  const discoveryNames=useMemo(()=>indexDiscoveryNames(items),[items]);
  const deferredSearch=useDeferredValue(search);
  const normalizedQuery=useMemo(()=>normalizeExperienceQuery(deferredSearch.trim()),[deferredSearch]);
  const installedIds=useMemo(()=>new Set([...localInstances.values()].filter(x=>x.state==='folder-present').map(x=>x.id)),[localInstances]);
  // Minecraft is set aside for now: its packs stay in the catalog for a future Coco 2 version.
  const library=useMemo(()=>items.filter(x=>category(x)!=='minecraft'),[items]);
  const unseenIds=useMemo(()=>new Set(unseenEntries(library.map(x=>x.id),seenCatalog)),[library,seenCatalog]);
  const filtered=useMemo(()=>sortLibrary(library.filter(x=>
    matchesLibraryFilter(x,filter,favorites,installedIds)&&
    matchesExperienceQuery(searchable,x.id,normalizedQuery)),sort),[library,filter,sort,favorites,installedIds,normalizedQuery,searchable]);
  // The newest game opens the page, and every other one follows right below it.
  const latest=useMemo(()=>filter==='all'&&!normalizedQuery?latestAddition(library):null,[library,filter,normalizedQuery]);
  const gridEntries=useMemo(()=>latest?filtered.filter(x=>x.id!==latest.id):filtered,[filtered,latest]);
  const recentDiscoveryIds=useMemo(()=>new Set(activity.slice(0,24).map(event=>event.id)),[activity]);
  const discoveryMatches=useMemo(()=>quickDiscovery(items,searchable,search,favorites,recentDiscoveryIds,6,discoveryNames),[items,searchable,search,favorites,recentDiscoveryIds,discoveryNames]);
  useEffect(()=>setSearchActiveIndex(-1),[search]);
  useEffect(()=>{if(selected||mediaPlaying||hostStudioOpen||incomingPackages.length)setSearchOpen(false);},[selected,mediaPlaying,hostStudioOpen,incomingPackages.length]);
  // Thousands of cards/images used to mount at once. Render 48 initially and
  // progressively mount subsequent pages only as the viewport approaches.
  // All entries remain indexed/searchable, and the preview pool still scans
  // the full curated source list for eventual metadata coverage.
  const [visibleCount,setVisibleCount]=useState(EXPERIENCE_PAGE_SIZE);
  const moreCardsRef=React.useRef<HTMLDivElement>(null);
  useEffect(()=>{setVisibleCount(EXPERIENCE_PAGE_SIZE);},[view,filter,normalizedQuery]);
  useEffect(()=>{
    if(visibleCount>=gridEntries.length||view!=='library'||typeof IntersectionObserver==='undefined')return;
    const anchor=moreCardsRef.current;
    if(!anchor)return;
    const observer=new IntersectionObserver(entries=>{
      if(entries.some(entry=>entry.isIntersecting))setVisibleCount(current=>nextExperiencePage(current,gridEntries.length));
    },{rootMargin:'600px 0px'});
    observer.observe(anchor);
    return()=>observer.disconnect();
  },[visibleCount,gridEntries.length,view]);

  const navigate=(next:View)=>{stageArt.current?.classList.remove('is-lit');setView(next);if(selected)closeDetails();setSearchOpen(false);if(next!=='library')setSearch('');window.scrollTo({top:0,behavior:'instant'});};
  const rememberActivity=(kind:ActivityKind,id:string)=>setActivity(recordActivity(kind,id));
  // Native confirms the reviewed package before this callback; cancelling a
  // first-run file picker does not complete onboarding.
  const openImportedGame=(id:string)=>{
    dismissWelcome();
    // onChanged has already accepted a verified native get_catalog revision.
    // Opening from that exact revision avoids a second multi-second IPC read
    // racing navigation, or using the untrusted package preview as authority.
    setView('library');setSearch('');setOperationMessage('');
    const verified=trustedCatalogSnapshot.current.get(id);
    if(verified?.workflow==='coco-standalone')openDetails(verified);
    else setOperationMessage('Paquete aceptado. Revisa tu biblioteca cuando termine de actualizarse.');
  };
  const dismissWelcome=()=>{setFirstRunDone(true);try{localStorage.setItem('coco2-welcome-v1','done');}catch{}};
  const toggleFavorite=(id:string)=>setFavorites(prev=>{const next=new Set(prev);next.has(id)?next.delete(id):next.add(id);return next;});
  const chooseSearch=(value:string)=>{setSearch(value);setSearchOpen(true);};
  const openDiscoveryEntry=(entry:Experience)=>{
    // Selecting a search result only opens its local detail sheet. Never
    // launch, install, import or download a result as a side effect of search.
    setSearchOpen(false);setSearch('');setSearchActiveIndex(-1);
    setView('library');
    openDetails(entry);
    window.scrollTo({top:0,behavior:'instant'});
  };
  const onDiscoveryKey=(event:React.KeyboardEvent<HTMLInputElement>)=>{
    if(event.key==='ArrowDown'||event.key==='ArrowUp'){
      if(!searchOpen)setSearchOpen(true);
      event.preventDefault();
      setSearchActiveIndex(index=>nextDiscoveryIndex(index,event.key as 'ArrowDown'|'ArrowUp',discoveryMatches.length));
    }else if(event.key==='Enter'&&searchOpen&&discoveryMatches.length){
      event.preventDefault();openDiscoveryEntry(discoveryMatches[searchActiveIndex]||discoveryMatches[0]);
    }else if(event.key==='Escape'){
      event.preventDefault();event.stopPropagation();
      setSearchOpen(false);setSearchActiveIndex(-1);setSearch('');
      const previous=priorSearchFocus.current;
      priorSearchFocus.current=null;
      if(previous?.isConnected&&previous!==event.currentTarget)previous.focus();
      else event.currentTarget.blur();
    }
  };
  const checkAppUpdate=async(automatic=false):Promise<boolean>=>{
    if(!isTauri()||updateRunning.current)return false;
    updateRunning.current=true;
    if(!automatic)setAppUpdate(p=>({...p,stage:'checking',message:'Buscando una versión nueva…'}));
    try{
      const {check}=await import('@tauri-apps/plugin-updater');
      const update=await check({timeout:12000});
      if(!update){if(!automatic)setAppUpdate(p=>({...p,stage:'current',message:'Ya tienes la última versión.'}));return false;}
      try{
        setAppUpdate(p=>({...p,stage:'deferred',version:update.version,message:`Versión ${update.version} disponible para instalar.`}));
        return true;
      }finally{
        // Discovery only must never keep a native installer handle alive.
        await update.close().catch(console.error);
      }
    }catch(error){if(!automatic)setAppUpdate(p=>({...p,stage:'error',message:`No se pudo comprobar la actualización: ${String(error)}`}));return false;}
    finally{updateRunning.current=false;}
  };
  const applyAppUpdate=async()=>{
    // Installing the updater is an explicit action: never interrupt playback.
    // State can lag a native mutation until React's next render. These refs
    // transition synchronously at the instant native work is reserved.
    const nativeWorkActive=()=>nativeOperationGate.current.busy()||
      mediaDownloadGate.current.busy()||mediaPrepareGate.current.busy();
    if(!isTauri()||updateRunning.current||pendingPackageInboxRef.current||nativeWorkActive()||mediaPlaying||streamLoading||mediaDownloadActive||installing||upgrading||upgradeRecovering||repairRecovering||busy||savingIdentity||hostStudioOpen)return;
    const hasUnreviewedPackages=async()=>{
      if(pendingPackageInboxRef.current)return true;
      try{
        // The authenticated Win32 sender may have enqueued a path while
        // React's native peek, listener or state commit is still in flight.
        // The in-memory UI latch alone cannot observe that native interval.
        const pending=await invoke<boolean>('has_pending_package_open_requests');
        return pending!==false||pendingPackageInboxRef.current;
      }catch(error){
        console.warn('Windows package inbox status is uncertain; updater deferred:',error);
        return true; // An ambiguous native IPC result cannot authorize restart.
      }
    };
    updateRunning.current=true;
    const attempt=++updateAttempt.current;
    setAppUpdate(p=>({...p,stage:'checking',message:'Verificando si puedes actualizar…'}));
    try {
      if(await hasUnreviewedPackages()){
        setAppUpdate(p=>({...p,stage:'deferred',message:'Hay paquetes pendientes o no se pudo confirmar la cola Windows. Revisa el paquete y vuelve a intentar.'}));return;
      }
      const running=await invoke<string[]>('list_running_games');
      if(running.length || runtime?.state==='running' || runtime?.state==='verifying'){
        setAppUpdate(p=>({...p,stage:'deferred',message:'Cierra el juego antes de actualizar.'}));return;
      }
      const processReport=await invoke<ActiveGameProcessReport>('get_active_game_processes');
      if(processReport.status!=='none'||processReport.safeToUpdate!==true){
        setAppUpdate(p=>({...p,stage:'deferred',message:'Hay juegos activos o procesos sin identificar. Cierra los juegos antes de actualizar.'}));return;
      }
      const {check}=await import('@tauri-apps/plugin-updater');
      const update=await check({timeout:12000});
      if(!update){setAppUpdate(p=>({...p,stage:'current',message:'Ya estás actualizado.'}));return;}
      setAppUpdate({stage:'downloading',version:update.version,percent:0,downloaded:0,total:0,message:'Descargando actualización…'});
      const transfer=new AppUpdaterProgressMeter();
      let installStarted=false;
      let armRequested=false;
      try{
        await update.download(event=>{
          if(attempt!==updateAttempt.current||!updateRunning.current)return;
          const visible=transfer.consume(event,performance.now());
          if(visible)setAppUpdate({stage:'downloading',version:update.version,...visible});
        });
        const {downloaded,total}=transfer.snapshot();
        if(attempt===updateAttempt.current)
          setAppUpdate({stage:'downloading',version:update.version,percent:100,downloaded,total,
            message:'Transferencia terminada; comprobando juegos…'});
        if(await hasUnreviewedPackages()){
          setAppUpdate({stage:'deferred',version:update.version,percent:100,downloaded,total,
            message:'Hay un paquete recibido pendiente de revisar. Termina su revisión antes de actualizar Coco; al reintentar se descargará nuevamente.'});
          return;
        }
        // Tauri separates downloading from installing so we can re-check
        // the operating system immediately before the installer starts.
        const runningAfter=await invoke<string[]>('list_running_games');
        const processReportAfter=await invoke<ActiveGameProcessReport>('get_active_game_processes');
        if(nativeWorkActive()){
          setAppUpdate({stage:'deferred',version:update.version,percent:100,downloaded,total,
            message:'Se inició una instalación, verificación o reproducción durante la descarga. Termina esa operación antes de reiniciar Coco.'});
          return;
        }
        if(runningAfter.length||processReportAfter.status!=='none'||processReportAfter.safeToUpdate!==true){
          setAppUpdate({stage:'deferred',version:update.version,percent:100,downloaded,total,message:'Cierra todos los juegos e intenta de nuevo. La siguiente actualización volverá a descargar.'});
          return;
        }
        // An Explorer delivery can arrive during the awaited native process
        // checks. Never restart Coco with unreviewed package paths only in RAM.
        if(await hasUnreviewedPackages()){
          setAppUpdate({stage:'deferred',version:update.version,percent:100,downloaded,total,
            message:'Hay un paquete pendiente de revisar. Cierra la revisión antes de actualizar Coco; al reintentar se descargará nuevamente.'});
          return;
        }
        // The final JavaScript/native status check still has a race: an
        // authenticated Explorer WM_COPYDATA can arrive in the few moments
        // between that check and update.install() restarting this process.
        // Arm atomically under the same native DELIVERY lock as WM_COPYDATA.
        armRequested=true;
        const armed=await invoke<boolean>('try_arm_app_update_install');
        if(armed!==true||pendingPackageInboxRef.current||nativeWorkActive()){
          setAppUpdate({stage:'deferred',version:update.version,percent:100,downloaded,total,
            message:'Se recibió un paquete durante la preparación del reinicio. Revísalo antes de volver a actualizar Coco.'});
          return;
        }
        setAppUpdate({stage:'installing',version:update.version,percent:100,downloaded,total,message:'Instalando y reiniciando Coco…'});
        // On Windows the signed updater starts NSIS and exits this process.
        await update.install({restartAfterInstall:true});
        installStarted=true;
      }finally{
        // Always unarm if Tauri install() returns (success, error or unknown
        // IPC result). A failed/aborted updater must not block file-open
        // handoffs indefinitely. Normal successful Windows restart exits the
        // process and clears this guard during shutdown.
        if(armRequested){
          try{await invoke('finish_app_update_install_guard');}
          catch(error){console.warn('Could not release Coco updater restart guard:',error);}
        }
        if(!installStarted)await update.close().catch(console.error);
      }
    }catch(error){setAppUpdate(p=>({...p,stage:'error',message:`No se pudo instalar: ${String(error)}`}));}
    finally{updateRunning.current=false;}
  };
  // The updater performs HTTPS discovery, not part of the first useful paint.
  // Begin it after the verified catalog and first-run view have rendered;
  // cancel the scheduled lookup on unmount. Updates are always automatic.
  // Just after opening nothing is playing yet, so a new version installs right
  // away (applyAppUpdate still refuses while any game or operation is active);
  // otherwise a friend stays behind and never sees the games it brings.
  const applyAppUpdateRef=React.useRef(applyAppUpdate);
  applyAppUpdateRef.current=applyAppUpdate;
  // Until this first check is over nothing else may ask Windows for anything: an update would
  // restart Coco in the middle of that prompt and the friend would be asked twice.
  const [startupUpdateSettled,setStartupUpdateSettled]=useState(false);
  useEffect(()=>{
    if(!bootstrapLoaded||!isTauri())return;
    const update=()=>checkAppUpdate(true).then(found=>found?applyAppUpdateRef.current():undefined);
    // Opened hidden (minimised, or behind Coco 1 during its handoff): look as soon as it is shown,
    // so a friend never stays on an old version without its fixes.
    const whenShown=()=>{
      if(document.hidden)return;
      document.removeEventListener('visibilitychange',whenShown);
      void update().finally(()=>setStartupUpdateSettled(true));
    };
    const timer=window.setTimeout(()=>{
      if(document.hidden){setStartupUpdateSettled(true);document.addEventListener('visibilitychange',whenShown);return;}
      void update().finally(()=>setStartupUpdateSettled(true));
    },1800);
    // Coco may stay open for days: keep looking, and offer it with the «Actualizar Coco» button
    // rather than restarting under someone who is browsing. The next opening installs it anyway.
    const periodic=window.setInterval(()=>{if(!document.hidden)void checkAppUpdate(true);},30*60*1000);
    return()=>{window.clearTimeout(timer);window.clearInterval(periodic);document.removeEventListener('visibilitychange',whenShown);};
  },[bootstrapLoaded]);
  const playMedia=async(entry:Experience,episode:MediaEpisode,fromStart=false)=>{
    if(!isTauri()||mediaPrepareGate.current.busy()||mediaPlaying||streamLoading||upgrading||upgradeRecovering||updateRunning.current)return;
    const ticket=mediaPrepareGate.current.begin(entry.id);
    if(!ticket)return;
    setStreamLoading(episode.id);setMediaError('');
    try{
      const stream=await invoke<PreparedMediaStream>('prepare_media_stream',{id:entry.id,episodeId:episode.id});
      if(!mediaPrepareGate.current.canDisplay(ticket)){
        // A stale response may have allocated a loopback server and token.
        // Close only its exact URL; never reanimate a previously closed view.
        void invoke<boolean>('close_media_stream',{url:stream.url}).catch(console.warn);
        return;
      }
      mediaSessionEpoch.current++;
      mediaRefreshGate.current.cancel();
      mediaRefreshGate.current.supersedeSession(mediaSessionEpoch.current);
      const media=mediaCatalog.find(item=>item.id===entry.id);
      const movie=media?.type==='movie';
      const label=media?episodeLabels(media.episodes).labels[media.episodes.findIndex(item=>item.id===episode.id)]:undefined;
      setSelected(null);setMediaPlaying({stream,title:movie?entry.name:(label||episode.title),subtitle:movie?'Película':entry.name,
        startAt:fromStart?null:resumePoint(progressFor(entry.id,episode.id))});
      rememberActivity('watched',entry.id);
    }catch(error){
      if(mediaPrepareGate.current.canDisplay(ticket))
        setMediaError('No se pudo preparar el video. Comprueba tu conexión e inténtalo de nuevo.');
      console.warn('Media preparation unavailable:',error);
    }finally{
      if(mediaPrepareGate.current.finish(ticket)){
        setStreamLoading('');
      }
    }
  };
  const cancelMediaDownload=()=>{
    const ticket=mediaDownloadGate.current.requestCancel();
    if(ticket&&isTauri()){
      setMediaCancelPending(true);
      void invoke<boolean>('cancel_media_download',{id:ticket.id,episodeId:ticket.episodeId})
        .catch(error=>{
          mediaDownloadGate.current.cancellationFailed(ticket);
          if(mediaDownloadGate.current.isLatest(ticket)){
            setMediaError(`No se pudo solicitar la cancelación: ${String(error)}`);setMediaCancelPending(false);
          }
        });
    }
  };
  /** Closing goes back to the title's detail, now showing where the viewer stopped. */
  const closeMedia=(backToDetail=true)=>{
    const watched=mediaPlaying?.stream.id;
    mediaPrepareGate.current.cancel();
    mediaSessionEpoch.current++;
    mediaRefreshGate.current.cancel();
    mediaRefreshGate.current.supersedeSession(mediaSessionEpoch.current);
    const url=mediaPlaying?.stream.url;
    setMediaPlaying(null);
    if(url&&isTauri())void invoke<boolean>('close_media_stream',{url}).catch(console.error);
    const entry=backToDetail&&watched?items.find(item=>item.id===watched):undefined;
    if(entry)openDetails(entry);
  };
  useEffect(()=>{
    if(mediaPlaying||!queuedEpisode)return;
    setQueuedEpisode(null);
    void playMedia(queuedEpisode.entry,queuedEpisode.episode);
  },[mediaPlaying,queuedEpisode]);
  const reopenMedia=async():Promise<boolean>=>{
    const playing=mediaPlaying;
    if(!isTauri()||!playing)return false;
    const ticket=mediaRefreshGate.current.begin(mediaSessionEpoch.current);
    if(!ticket)return false;
    try{
      // Never replay the expired capability URL. Native rechecks the private
      // manifest and creates a fresh token (or selects a verified local file).
      const fresh=await invoke<PreparedMediaStream>('prepare_media_stream',{
        id:playing.stream.id,episodeId:playing.stream.episodeId,
      });
      if(!mediaRefreshGate.current.canUse(ticket,mediaSessionEpoch.current)){
        // Closing or replacing playback while native Rust was preparing its
        // listener must not resurrect that token or leak the server.
        void invoke<boolean>('close_media_stream',{url:fresh.url}).catch(console.warn);
        return false;
      }
      const previousUrl=playing.stream.url;
      setMediaPlaying(current=>current?.stream.url===previousUrl?{...current,stream:fresh}:current);
      if(fresh.url!==previousUrl)
        void invoke<boolean>('close_media_stream',{url:previousUrl}).catch(console.warn);
      return true;
    }catch(error){
      console.warn('No se pudo renovar el acceso temporal al video:',error);
      return false;
    }finally{mediaRefreshGate.current.finish(ticket);}
  };
  const saveIdentity=async()=>{
    if(!isTauri()||savingIdentity||updateRunning.current)return;
    const proposed=identityName;
    if(!/^[A-Za-z0-9_]{3,16}$/.test(proposed)){
      setIdentityError('Usa de 3 a 16 letras, números o _.');return;
    }
    if(identity.username && proposed!==identity.username && !confirmIdentity){
      setConfirmIdentity(true);setIdentityError('');return;
    }
    setSavingIdentity(true);setIdentityError('');
    try{
      const saved=identity.username && proposed!==identity.username
        ? await invoke<LocalIdentity>('confirm_local_identity_change',{username:proposed,confirmedPreviousUsername:identity.username})
        : await invoke<LocalIdentity>('set_local_identity',{username:proposed});
      setIdentity(saved);setConfirmIdentity(false);
    }catch(error){setIdentityError(String(error));}
    finally{setSavingIdentity(false);}
  };
  // Native commands may reject AFTER creating a protected transaction journal.
  // Reconcile immediately with independent, read-only checks, without waiting
  // for a focus event or mutating a journal without the player's consent.
  const explainFailedNativeWrite=(error:unknown,kind:'install'|'repair'|'prepare'|'upgrade'|'recover',ticket:NativeOperationTicket,entry:Experience)=>{
    const guidance=nativeFailureGuidance(error,kind);
    setNativeFailure(guidance);setOperationMessage(guidance.summary);
    // An exception is NOT evidence that no disk mutation occurred: record
    // only an interrupted attempt, never a failed installation verdict.
    // Keep errors/paths/credentials out of persistent storage. The read-only
    // journal reconciliation below remains the source of recovery actions.
    const interruption:ActivityKind=kind==='install'?'install-interrupted':
      kind==='upgrade'?'upgrade-interrupted':kind==='recover'?'recover-interrupted':'repair-interrupted';
    rememberActivity(interruption,entry.id);
    const catalogRevision=catalogRefreshGate.current.snapshot();
    const repairing=['prepare-repair','commit-repair','recover-repair'].includes(ticket.kind);
    const planningInstall=ticket.kind==='install';
    const planningUpgrade=ticket.kind==='upgrade'||ticket.kind==='recover-upgrade';
    void inspectAfterNativeFailure<PendingStandaloneOperation[],LocalInstance[],RepairRecoveryStatus,InstallPlan|UpgradePlan>(
      ()=>invoke<PendingStandaloneOperation[]>('recover_pending_standalone_operations'),
      ()=>invoke<LocalInstance[]>('get_local_instances'),
      repairing?()=>invoke<RepairRecoveryStatus>('get_standalone_repair_recovery_status',{id:entry.id})
        :undefined,
      planningInstall?()=>invoke<InstallPlan>('plan_standalone_install',{id:entry.id}):
        planningUpgrade?()=>invoke<UpgradePlan>('plan_standalone_upgrade',{id:entry.id}):undefined,
    ).then(snapshot=>{
      // An import or another operation may have started during the read.
      if(!nativeOperationGate.current.isLatest(ticket)||
        !catalogRefreshGate.current.current(catalogRevision))return;
      if(snapshot.pending!==null)setPendingOperations(snapshot.pending.filter(x=>x.status!=='none'));
      if(snapshot.instances!==null)setLocalInstances(new Map(snapshot.instances.map(x=>[x.id,x])));
      if(snapshot.repair!==null)setRepairRecoveryStatus(previous=>new Map(previous).set(entry.id,snapshot.repair!));
      if(planningInstall&&snapshot.plan!==null&&'archiveCount' in snapshot.plan)setInstallPlan(snapshot.plan);
      if(planningUpgrade&&snapshot.plan!==null&&'toVersion' in snapshot.plan)setUpgradePlan(snapshot.plan);
      foregroundRecoveryGate.current.allowImmediateRetry();
      if(snapshot.unavailable.length)console.warn('Read-only native failure checks unavailable:',snapshot.unavailable);
    }).catch(error=>console.warn('Native failure inspection unavailable:',error));
  };
  const launchNative=async(entry:Experience)=>{
    if(busy||upgrading||upgradeRecovering||repairRecovering||updateRunning.current||appUpdate.stage==='downloading'||appUpdate.stage==='installing'||!isTauri())return;
    const ticket=nativeOperationGate.current.begin(entry.id,'launch');
    if(!ticket)return;
    setBusy(true);setOperationMessage('');setRuntime({id:entry.id,state:'verifying',pid:null,exitCode:null});
    try {
      const started=await invoke<RuntimeEvent>('launch_standalone',{id:entry.id});
      setRuntime(started);
      setOperationMessage(started.state==='running'?'Juego iniciado':
        started.state==='exited'?'El juego se cerró durante el inicio. Revisa su instalación.':
        'Comprobando el inicio del juego…');
      if(started.state==='running')rememberActivity('played',entry.id);
      if(started.state==='running')autoRepairTried.current.delete(entry.id);
    }catch(launchError){
      // An IPC error is not evidence that the child did not start. Never offer
      // a false "try again" verdict before checking native Win32 processes.
      // Keep the cross-feature gate until this bounded read-only inspection
      // completes, and reject any unknown observation conservatively.
      let observed:'running'|'absent'|'unknown'='unknown';
      let deadline:ReturnType<typeof setTimeout>|undefined;
      try{
        const snapshot=await Promise.race<ActiveGameProcessReport|null>([
          invoke<ActiveGameProcessReport>('get_active_game_processes'),
          new Promise<null>(resolve=>{deadline=window.setTimeout(()=>resolve(null),3500);}),
        ]);
        if(snapshot){
          observed=reconcileLaunchObservation(snapshot,entry.id);
          setObservedGameIds(current=>retainObservedGameIds(current,snapshot.gameIds));
          setGameProcessUncertain(observed==='unknown');
        }else setGameProcessUncertain(true);
      }catch{setGameProcessUncertain(true);}
      finally{if(deadline!==undefined)window.clearTimeout(deadline);}
      if(observed==='running'){
        setRuntime({id:entry.id,state:'running',pid:null,exitCode:null});
        setOperationMessage('No llegó la respuesta de inicio, pero Windows detectó el juego activo. No lo inicies otra vez.');
      }else if(observed==='absent'&&/Archivos no verificados/.test(String(launchError))&&!autoRepairTried.current.has(entry.id)){
        // Usually Defender took a file. Launcher 1 restored it on its own, so does this.
        autoRepairTried.current.add(entry.id);
        setRuntime(null);
        window.setTimeout(()=>void repairThenLaunch(entry),0);
      }else if(observed==='absent'){
        setRuntime(null);
        setOperationMessage('No se confirmó el inicio y Windows no detectó este juego activo. Revisa su instalación antes de intentarlo otra vez.');
      }else{
        setRuntime({id:entry.id,state:'verifying',pid:null,exitCode:null});
        setOperationMessage('El inicio quedó sin confirmar. Revisa los procesos activos antes de intentar nuevamente; Coco volverá a comprobarlos al recuperar el foco.');
      }
    }
    finally{nativeOperationGate.current.finish(ticket);setBusy(false);}
  };
  const installNative=async(entry:Experience)=>{
    if(!isTauri()||installing||upgrading||upgradeRecovering||repairRecovering||mediaDownloadActive||busy||updateRunning.current||appUpdate.stage==='downloading'||appUpdate.stage==='installing'||installPlan?.id!==entry.id||installPlan.status!=='ready')return;
    const ticket=nativeOperationGate.current.begin(entry.id,'install');
    if(!ticket)return;
    nativeProgressSampler.current.reset();
    nativeTransferRateMeter.current.reset();setInstallTransferRate(null);
    setInstalling(entry.id);setInstallProgress(null);setOperationMessage('');
    try{
      const result=await invoke<InstallOutcome>('install_standalone',{id:entry.id});
      setOperationMessage(result.message);
      if(result.status==='installed'){
        rememberActivity('installed',entry.id);
        // The install receipt is authoritative. A read-only refresh failing
        // afterward must not tell the player the installation failed.
        const refresh=await refreshAfterConfirmedWrite([
          async()=>{
            const observed=await invoke<LocalInstance[]>('get_local_instances');
            setLocalInstances(new Map(observed.map(x=>[x.id,x])));
          },
          async()=>setInstallPlan(await invoke<InstallPlan>('plan_standalone_install',{id:entry.id})),
        ]);
        setOperationMessage(confirmedOperationMessage(result.message,refresh.failed));
      }
    }catch(error){explainFailedNativeWrite(error,'install',ticket,entry);}
    finally{nativeOperationGate.current.finish(ticket);setInstalling(null);setInstallProgress(null);}
  };
  const cancelInstall=()=>{if(installing&&isTauri())void invoke('cancel_standalone_install',{id:installing}).catch(console.error);};
  const repairThenLaunch=async(entry:Experience)=>{
    const ticket=nativeOperationGate.current.begin(entry.id,'commit-repair');
    if(!ticket)return;
    nativeProgressSampler.current.reset();
    nativeTransferRateMeter.current.reset();setInstallTransferRate(null);
    setAutoRepairing(entry.id);setInstallProgress(null);setOperationMessage('');
    let ready=false;
    try{
      const outcome=await invoke<InstallOutcome>('commit_standalone_repair',{id:entry.id});
      ready=outcome.status==='repaired'||outcome.status==='already-verified';
      if(outcome.status==='repaired')rememberActivity('repaired',entry.id);
      if(!ready)setOperationMessage('No se pudo reparar. Desinstala el juego y vuelve a instalarlo.');
    }catch(error){explainFailedNativeWrite(error,'repair',ticket,entry);}
    finally{nativeOperationGate.current.finish(ticket);setAutoRepairing(null);setInstallProgress(null);}
    if(ready)void launchNative(entry);
  };
  const recoverRepair=async(entry:Experience)=>{
    if(!isTauri()||repairRecovering||installing||upgrading||upgradeRecovering||busy||updateRunning.current)return;
    const ticket=nativeOperationGate.current.begin(entry.id,'recover-repair');
    if(!ticket)return;
    nativeProgressSampler.current.reset();
    nativeTransferRateMeter.current.reset();setInstallTransferRate(null);
    setRepairRecovering(entry.id);setOperationMessage('Comprobando una reparación interrumpida…');
    try{
      const outcome=await invoke<InstallOutcome>('recover_standalone_repair',{id:entry.id});
      setOperationMessage(outcome.message);
      if(outcome.status==='recovery-complete')rememberActivity('recovered',entry.id);
      const refresh=await refreshAfterConfirmedWrite([
        async()=>{
          const recovery=await invoke<RepairRecoveryStatus>('get_standalone_repair_recovery_status',{id:entry.id});
          setRepairRecoveryStatus(old=>new Map(old).set(entry.id,recovery));
        },
        async()=>{
          const pending=await invoke<PendingStandaloneOperation[]>('recover_pending_standalone_operations');
          setPendingOperations(pending.filter(x=>x.status!=='none'));
        },
      ]);
      if(outcome.status==='recovery-complete')
        setOperationMessage(confirmedOperationMessage(outcome.message,refresh.failed));
    }catch(error){explainFailedNativeWrite(error,'recover',ticket,entry);}
    finally{nativeOperationGate.current.finish(ticket);setRepairRecovering(null);setInstallProgress(null);}
  };
  // The one Windows prompt for Defender comes right after opening, before any game needs it.
  // Rust skips it when the folders are already covered or the player said no recently.
  const defenderPrepared=React.useRef(false);
  const updateInFlight=appUpdate.stage==='checking'||appUpdate.stage==='downloading'||appUpdate.stage==='installing';
  useEffect(()=>{
    if(!isTauri()||defenderPrepared.current||!bootstrapLoaded||!startupUpdateSettled||(introStage!=='done'&&introStage!=='none')||updateInFlight)return;
    const timer=window.setTimeout(()=>{
      defenderPrepared.current=true;
      void invoke<string>('prepare_windows').catch(console.warn);
    },1500);
    return()=>window.clearTimeout(timer);
  },[bootstrapLoaded,startupUpdateSettled,introStage,updateInFlight]);
  // One paste for the host: the native report plus what this screen knows.
  const copyDiagnostic=async()=>{
    setDiagnosticNote('Preparando…');
    try{
      const copied=await copyDiagnosticReport([
        `Juegos instalados: ${[...installedIds].join(', ')||'ninguno'}`,
        `Pantalla: ${view}${selected?` · ${selected.id}`:''}`,
        `Último mensaje: ${operationMessage||'-'}`,
        `Actualización de Coco: ${appUpdate.stage}${appUpdate.message?` · ${appUpdate.message}`:''}`,
      ]);
      setDiagnosticNote(copied?'Copiado. Pégalo en el chat con Coco.':'Windows no dejó copiar. Abre los registros y envía coco.log.');
    }catch(error){setDiagnosticNote(`No se pudo preparar: ${String(error)}`);}
  };
  const checkDefender=async()=>{
    if(!isTauri()||defenderBusy)return;
    setDefenderBusy(true);setDefenderOutcome('');
    try{
      const status=await invoke<string>('ensure_defender_exclusions');
      setDefenderOutcome(status==='declined'?'Windows no lo autorizó. Coco volverá a pedirlo cuando instales o juegues.':
        status==='unavailable'?'Este PC no usa Windows Defender o no permite cambiarlo.':
        status==='failed'?'No se pudo completar. Inténtalo de nuevo.':'Tus carpetas de juegos están protegidas.');
    }catch(error){setDefenderOutcome(String(error));}
    finally{setDefenderBusy(false);}
  };
  const refreshInstallLocation=async(id:string)=>{
    const location=await invoke<InstallLocation>('get_install_location',{id});
    setInstallLocation(location);
  };
  /** Installed games move after a confirmation; for the rest only the record changes. */
  const chooseInstallFolder=async(entry:Experience,useDefault=false)=>{
    if(!isTauri()||locationBusy||nativeOperationGate.current.busy())return;
    setLocationError('');setMoveDraft(null);setOperationMessage('');
    try{
      let parent:string|null=null;
      if(!useDefault){
        const {open}=await import('@tauri-apps/plugin-dialog');
        const picked=await open({directory:true,multiple:false,title:`Elige dónde guardar ${entry.name}`});
        if(typeof picked!=='string')return;
        parent=picked;
      }
      setLocationBusy(true);
      if(installedIds.has(entry.id)){
        const check=await invoke<LocationCheck>('check_install_location',{id:entry.id,parent});
        setMoveDraft({id:entry.id,parent,check});
      }else{
        setInstallLocation(await invoke<InstallLocation>('set_install_location',{id:entry.id,parent}));
        setInstallPlan(await invoke<InstallPlan>('plan_standalone_install',{id:entry.id}));
      }
    }catch(error){setLocationError(String(error));}
    finally{setLocationBusy(false);}
  };
  const moveInstallation=async(entry:Experience,draft:MoveDraft)=>{
    if(!isTauri()||moving)return;
    const ticket=nativeOperationGate.current.begin(entry.id,'move');
    if(!ticket)return;
    nativeProgressSampler.current.reset();
    nativeTransferRateMeter.current.reset();setInstallTransferRate(null);
    setMoving(entry.id);setMoveDraft(null);setInstallProgress(null);setLocationError('');setOperationMessage('');
    try{
      const outcome=await invoke<MoveOutcome>('move_installation',{id:entry.id,parent:draft.parent});
      setOperationMessage(outcome.leftovers?'Listo. Una parte de la carpeta anterior sigue en uso; Coco la borrará la próxima vez que abras.':'');
    }catch(error){
      setLocationError(String(error)==='cancelled'?'Cancelado. El juego sigue donde estaba.':String(error));
    }finally{
      nativeOperationGate.current.finish(ticket);setMoving(null);setInstallProgress(null);
      void refreshInstallLocation(entry.id).catch(console.warn);
      void invoke<LocalInstance[]>('get_local_instances').then(observed=>setLocalInstances(new Map(observed.map(x=>[x.id,x])))).catch(console.warn);
    }
  };
  const uninstallNative=async(entry:Experience)=>{
    if(!isTauri()||uninstalling||nativeOperationGate.current.busy()||updateRunning.current)return;
    const ticket=nativeOperationGate.current.begin(entry.id,'uninstall');
    if(!ticket)return;
    setUninstalling(entry.id);setUninstallConfirm(null);setOperationMessage('');setNativeFailure(null);
    try{
      const outcome=await invoke<UninstallOutcome>('uninstall_standalone',{id:entry.id});
      rememberActivity('uninstalled',entry.id);
      setInstalledSizes(old=>{const next=new Map(old);next.delete(entry.id);return next;});
      const kept=outcome.keptFiles>0?' Tus partidas quedaron a salvo y vuelven si lo reinstalas.':'';
      const refresh=await refreshAfterConfirmedWrite([
        async()=>{
          const observed=await invoke<LocalInstance[]>('get_local_instances');
          setLocalInstances(new Map(observed.map(x=>[x.id,x])));
        },
        async()=>setInstallPlan(await invoke<InstallPlan>('plan_standalone_install',{id:entry.id})),
      ]);
      setOperationMessage(confirmedOperationMessage(`Liberaste ${formatBytes(outcome.freedBytes)}.${kept}`,refresh.failed));
    }catch(error){setOperationMessage(String(error));}
    finally{nativeOperationGate.current.finish(ticket);setUninstalling(null);}
  };
  const chooseAvatar=async(file:File|undefined)=>{
    if(!file||avatarBusy||!isTauri())return;
    setAvatarBusy(true);setAvatarError('');
    try{
      const dataUrl=await squareAvatar(file);
      await invoke('set_profile_avatar',{dataUrl});
      setAvatar(dataUrl);cacheAvatar(dataUrl);
    }catch(error){
      console.warn('Avatar not saved:',error);
      setAvatarError('No pude usar esa imagen. Prueba con una PNG o JPG.');
    }finally{setAvatarBusy(false);}
  };
  const removeAvatar=async()=>{
    if(avatarBusy||!isTauri())return;
    setAvatarBusy(true);setAvatarError('');
    try{await invoke('remove_profile_avatar');setAvatar(null);cacheAvatar(null);}
    catch(error){console.warn('Avatar not removed:',error);setAvatarError('No pude quitar la foto.');}
    finally{setAvatarBusy(false);}
  };
  const performUpgrade=async(entry:Experience)=>{
    if(!isTauri()||upgradePlan?.id!==entry.id||upgradePlan.status!=='upgrade-ready'||upgrading||upgradeRecovering
      ||installing||repairRecovering
      ||mediaDownloadActive||busy||updateRunning.current||appUpdate.stage==='downloading'||appUpdate.stage==='installing')return;
    const ticket=nativeOperationGate.current.begin(entry.id,'upgrade');
    if(!ticket)return;
    nativeProgressSampler.current.reset();
    nativeTransferRateMeter.current.reset();setInstallTransferRate(null);
    setUpgrading(entry.id);setInstallProgress(null);setUpgradeOutcome(null);
    setOperationMessage('Actualizando archivos del juego sin tocar tus partidas…');
    try{
      const outcome=await invoke<UpgradeOutcome>('upgrade_standalone',{id:entry.id});
      setUpgradeOutcome(outcome);setOperationMessage(outcome.message);
      if(outcome.status==='upgraded'||outcome.status==='already-current'){
        if(outcome.status==='upgraded')rememberActivity('upgraded',entry.id);
        const refresh=await refreshAfterConfirmedWrite([
          ()=>refreshNativeCatalog(),
          async()=>setUpgradePlan(await invoke<UpgradePlan>('plan_standalone_upgrade',{id:entry.id})),
        ]);
        setOperationMessage(confirmedOperationMessage(outcome.message,refresh.failed));
      }
    }catch(error){explainFailedNativeWrite(error,'upgrade',ticket,entry);}
    finally{nativeOperationGate.current.finish(ticket);setUpgrading(null);setInstallProgress(null);}
  };
  const recoverUpgrade=async(entry:Experience)=>{
    if(!isTauri()||upgrading||upgradeRecovering||installing||repairRecovering||busy||updateRunning.current)return;
    const ticket=nativeOperationGate.current.begin(entry.id,'recover-upgrade');
    if(!ticket)return;
    nativeProgressSampler.current.reset();
    nativeTransferRateMeter.current.reset();setInstallTransferRate(null);
    setUpgradeRecovering(entry.id);setInstallProgress(null);setOperationMessage('Recuperando el estado anterior del juego…');
    try{
      const outcome=await invoke<UpgradeOutcome>('recover_standalone_upgrade',{id:entry.id});
      setUpgradeOutcome(outcome);setOperationMessage(outcome.message);
      if(outcome.status==='recovery-complete')rememberActivity('recovered',entry.id);
      const refresh=await refreshAfterConfirmedWrite([
        async()=>setUpgradePlan(await invoke<UpgradePlan>('plan_standalone_upgrade',{id:entry.id})),
        async()=>{
          const pending=await invoke<PendingStandaloneOperation[]>('recover_pending_standalone_operations');
          setPendingOperations(pending.filter(x=>x.status!=='none'));
        },
      ]);
      if(outcome.status==='recovery-complete')
        setOperationMessage(confirmedOperationMessage(outcome.message,refresh.failed));
    }catch(error){explainFailedNativeWrite(error,'recover',ticket,entry);}
    finally{nativeOperationGate.current.finish(ticket);setUpgradeRecovering(null);setInstallProgress(null);}
  };
  const primaryGame=selected?.workflow==='coco-standalone'?gamePrimaryAction({
    localState:localInstances.get(selected.id)?.state,
    planStatus:installPlan?.id===selected.id?installPlan.status:undefined,
    planMessage:installPlan?.id===selected.id?installPlan.message:undefined,
    nativeAvailable:isTauri(),hostingMode:selected.hostingMode,
    busy:Boolean(nativeOperationGate.current.busy()||installing||upgrading||upgradeRecovering||
      repairRecovering||mediaDownloadActive||
      streamLoading||mediaPlaying||busy||appUpdate.stage==='downloading'||appUpdate.stage==='installing'),
    gameActive:runtime?.state==='running'||observedGameIds.includes(selected.id),
    processUnknown:gameProcessUncertain,
    opening:runtime?.state==='verifying'&&runtime.id===selected.id,firstRun:firstGameRun,
  }):null;
  const hostStudioBlocked=Boolean(packageReviewDeferred||incomingPackages.length||
    runtime?.state==='running'||observedGameIds.length||gameProcessUncertain||
    mediaPrepareGate.current.busy()||busy||updateRunning.current);
  // All diagnostic paths originate from a registered native manifest/plan.
  // A planned destination is NOT evidence that Defender quarantined a file.
  const nativeDiagnosticPath=selected?.workflow==='coco-standalone'
    ?securityGuide?.id===selected.id?securityGuide.folder
      :installPlan?.id===selected.id?installPlan.instancePath
      :upgradePlan?.id===selected.id?upgradePlan.instancePath:null
    :null;
  const diagnosticPathVerified=Boolean(selected&&securityGuide?.id===selected.id);
  const copyNativeDiagnosticPath=async()=>{
    if(!nativeDiagnosticPath||!selected||selected.workflow!=='coco-standalone')return;
    try{await navigator.clipboard.writeText(nativeDiagnosticPath);setSecurityCopied(true);}
    catch{setSecurityError('No se pudo copiar la ruta. Selecciónala manualmente si es necesario.');}
  };

  // The backdrop follows the game under the pointer without re-rendering the app.
  const showStageArt=(image:string|null)=>{
    const art=stageArt.current;
    if(!art||!motion)return;
    if(image)art.style.setProperty('--stage-art',`url("${image.replace(/"/g,'%22')}")`);
    art.classList.toggle('is-lit',Boolean(image));
  };
  const nativeBusy=Boolean(nativeOperationGate.current.busy()||installing||upgrading||upgradeRecovering||uninstalling||moving||
    repairRecovering||mediaDownloadActive||
    streamLoading||mediaPlaying||busy||appUpdate.stage==='downloading'||appUpdate.stage==='installing');
  const quickPlayAvailable=isTauri()&&!nativeBusy&&!gameProcessUncertain&&runtime?.state!=='running';
  // Progress events arrive many times a second. Cards re-render only when
  // something they show changes, and reach the latest handlers through a ref.
  const cardActions=React.useRef({openDetails,toggleFavorite,launchNative,showStageArt});
  cardActions.current={openDetails,toggleFavorite,launchNative,showStageArt};
  const card=(entry:Experience,index:number,latestCard=false)=>{
    const soon=isComingSoon(entry);
    const installed=installedIds.has(entry.id);
    const isNew=unseenIds.has(entry.id);
    const running=observedGameIds.includes(entry.id)||(runtime?.state==='running'&&runtime.id===entry.id);
    const standing=running?'Jugando':installed?'Instalado':soon?'Desactivado':'';
    return <article className={`experience-card ${latestCard?'coco-latest-card':''} ${soon?'is-soon':''} ${installed?'is-installed':''} ${isNew?'is-new':''}`} data-preview-id={entry.id} data-flip-id={latestCard?undefined:entry.id} key={entry.id} style={{'--index':Math.min(index,12)} as React.CSSProperties} onClick={event=>{
      // The image, play and favorite controls already handle their own clicks.
      if(event.target instanceof Element&&event.target.closest('button,a,input,select,textarea,[role="button"],[contenteditable="true"]'))return;
      cardActions.current.openDetails(entry);
    }} onPointerEnter={event=>{cardActions.current.showStageArt(entry.image);if(motion&&event.pointerType!=='touch')previewVideoInCard(event.currentTarget,true);if(Object.hasOwn(gameScreenshots,entry.id))warmScreenshots(gameScreenshots[entry.id].slice(0,4),true);}} onPointerLeave={event=>{
      cardActions.current.showStageArt(null);
      // Pointer exiting does not interrupt an intentionally keyboard-focused
      // preview; mouse-click focus alone must not keep playback running.
      if(!event.currentTarget.querySelector('.card-image-button')?.matches(':focus-visible'))previewVideoInCard(event.currentTarget,false);
    }}>
      <div className="card-surface">
      <button className="card-image-button" onFocus={event=>{if(motion)previewVideoInCard(event.currentTarget.closest('.experience-card') as HTMLElement,true);}} onBlur={event=>{
        const article=event.currentTarget.closest('.experience-card') as HTMLElement;
        if(!article.matches(':hover'))previewVideoInCard(article,false);
      }} onClick={()=>cardActions.current.openDetails(entry)} aria-label={`Ver ${entry.name}`}><img loading={index>11?'lazy':'eager'} decoding="async" src={entry.image} alt=""/>{category(entry)==='standalone'&&Object.hasOwn(gameHoverPreviews,entry.id)&&<HoverPreview id={entry.id}/>}{(isNew||standing||catalogSources.get(entry.id)?.source==='local')&&<span className="card-badges">{isNew&&<span className="card-new"><Sparkles size={11}/> Nuevo</span>}{standing&&<span className="card-standing">{standing}</span>}{catalogSources.get(entry.id)?.source==='local'&&<span className="card-standing catalog-entry-local">Importación local</span>}</span>}</button>
      <div className="card-body">
        {latestCard&&<span className="coco-latest-label">Último agregado</span>}
        <div className="card-title" title={entry.name}>{entry.name}</div>
        {latestCard&&<p className="coco-latest-copy">{entry.description}</p>}
      </div>
      </div>
      <div className="card-float"><div className="card-actions">
        {installed&&!soon&&!running&&quickPlayAvailable&&<button className="card-play" aria-label={`Jugar ${entry.name}`} onClick={()=>void cardActions.current.launchNative(entry)}><Play size={13} fill="currentColor"/> Jugar</button>}
        <button aria-label={favorites.has(entry.id)?'Quitar favorito':'Añadir favorito'} aria-pressed={favorites.has(entry.id)} className={`favorite-button ${favorites.has(entry.id)?'active':''}`} onClick={()=>cardActions.current.toggleFavorite(entry.id)}><Heart size={14} fill={favorites.has(entry.id)?'currentColor':'none'}/></button>
      </div></div>
    </article>;
  };
  const visibleEntries=gridEntries.slice(0,visibleCount);
  const gridNodes=useMemo(()=>visibleEntries.map((entry,index)=>card(entry,index)),
    [visibleEntries.map(entry=>`${entry.id}:${entry.image}:${entry.name}`).join('|'),installedIds,unseenIds,favorites,observedGameIds,runtime?.state,runtime?.id,quickPlayAvailable,catalogSources,motion]);
  const latestNode=useMemo(()=>latest?card(latest,0,true):null,
    [latest,installedIds,unseenIds,favorites,observedGameIds,runtime?.state,runtime?.id,quickPlayAvailable,catalogSources,motion]);
  const stageRef=React.useRef<HTMLElement>(null);
  const mainRef=React.useRef<HTMLElement>(null);
  const filtersRef=React.useRef<HTMLDivElement>(null);
  useEffect(()=>{
    if(!motion||!stageRef.current||!mainRef.current)return;
    const stopTilt=attachCardTilt(mainRef.current);
    const stopParallax=attachStageParallax(stageRef.current);
    return()=>{stopTilt();stopParallax();};
  },[motion]);
  React.useLayoutEffect(()=>{
    const row=filtersRef.current;
    if(!row)return;
    const place=()=>{
      const active=row.querySelector<HTMLElement>('button.active');
      if(!active)return;
      row.style.setProperty('--ink-left',`${active.offsetLeft+7}px`);
      row.style.setProperty('--ink-width',`${Math.max(0,active.offsetWidth-14)}px`);
    };
    place();
    window.addEventListener('resize',place);
    void document.fonts?.ready.then(place);
    return()=>window.removeEventListener('resize',place);
  },[filter,view,installedIds.size,favorites.size]);
  const gridRef=React.useRef<HTMLDivElement>(null);
  useFlipGrid(gridRef,visibleEntries.map(entry=>entry.id).join('|'),motion&&view==='library');

  const entryName=(id:string|null|undefined)=>items.find(x=>x.id===id)?.name||'el juego';
  const operationId=installing||upgrading||upgradeRecovering||repairRecovering||moving||autoRepairing;
  const launcherStatus=deriveLauncherStatus({
    update:appUpdate,
    operation:operationId?{
      kind:moving?'move':autoRepairing?'repair':installing?'install':upgrading?'upgrade':'recover',
      name:entryName(operationId),
      description:nativeProgressDescription(installProgress?.phase||''),
      percent:Math.max(0,Math.min(100,installProgress?.percent??0)),
      rate:installProgress?.phase.endsWith('downloading')&&installTransferRate?nativeTransferRateText(installTransferRate):'',
      metrics:[
        installProgress&&installProgress.totalBytes>0&&!moving?formatBytePair(installProgress.downloadedBytes,installProgress.totalBytes):'',
        installProgress?.phase.endsWith('downloading')?nativeTransferRateCompact(installTransferRate):'',
      ].filter(Boolean).join(' · '),
    }:null,
    mediaDownload:mediaDownloadActive?{title:mediaDownloadActive.title,percent:mediaDownloadProgress?.percent??0,verifying:mediaDownloadProgress?.phase==='verifying'}:null,
    launching:runtime?.state==='verifying'?entryName(runtime.id):null,
    playing:[...new Set([...observedGameIds,...(runtime?.state==='running'?[runtime.id]:[])])].map(entryName),
    processUncertain:gameProcessUncertain,
    pendingRecovery:pendingOperations.length,
    arrival,
    catalog:catalogSync,
    catalogLoaded,
    uninstalling:uninstalling?entryName(uninstalling):null,
    authorizing,
    startingSteam,
    firstGameRun,
  });
  const cancelCurrentOperation=
    installing?cancelInstall:
    upgrading||moving?()=>{void invoke('cancel_standalone_install',{id:upgrading||moving}).catch(console.error);}:
    mediaDownloadActive?cancelMediaDownload:
    null;

  return <div className={`app-shell coco2-desktop coco-intro-${introStage}`}>
    {(introStage==='hold'||introStage==='reveal')&&<LauncherIntro onReveal={()=>setIntroStage(stage=>stage==='hold'?'reveal':stage)} onDone={()=>setIntroStage('done')}/>}
    <aside className="coco-stage" ref={stageRef} data-tone={launcherStatus.tone} aria-label="Estado de Coco">
      <div className="coco-stage-art" ref={stageArt} aria-hidden="true"/>
      <div className="coco-stage-drag" data-tauri-drag-region aria-hidden="true"/>
      <StageAmbience/>
      <button className="coco-wordmark" onClick={()=>navigate('library')} aria-label="Coco Launcher 2, ir a la biblioteca">{'COCO'.split('').map((letter,index)=><span key={index} style={{'--letter':index} as React.CSSProperties}>{letter}</span>)}</button>
      <div className="coco-reyna-drift"><img className="coco-reyna" src="/reyna-2.webp" alt="" decoding="async"/></div>
      <div className="coco-edition" aria-hidden="true"><i/><span>Launcher</span><b>2</b></div>
      <div className="coco-status" role="status" aria-live="polite">
        <div className="coco-status-line"><span className="coco-status-dot" aria-hidden="true"/><div className="coco-status-copy" key={launcherStatus.label+(launcherStatus.subject||'')}><div className="coco-status-head"><strong>{launcherStatus.label}</strong>{launcherStatus.percent!==null&&<span className="coco-status-percent">{launcherStatus.percent}<i>%</i></span>}</div>{launcherStatus.subject&&<b className="coco-status-subject" title={launcherStatus.subject}>{launcherStatus.subject}</b>}{launcherStatus.detail&&<small>{launcherStatus.detail}</small>}</div></div>
        {launcherStatus.percent!==null?<div className="coco-status-bar"><span style={{width:`${launcherStatus.percent}%`}}/></div>:launcherStatus.tone==='busy'&&<div className="coco-status-bar is-waiting"><span/></div>}
        {launcherStatus.metrics!==undefined&&<div className="coco-status-metrics">{launcherStatus.metrics||' '}</div>}
        {operationId&&<NativeStageRail phase={installProgress?.phase}/>}
        {cancelCurrentOperation&&<button className="coco-status-action" onClick={cancelCurrentOperation}>{mediaCancelPending?'Cancelando…':'Cancelar'}</button>}
        {appUpdate.stage==='deferred'&&<button className="coco-status-action is-primary" disabled={nativeBusy||hostStudioOpen} onClick={()=>void applyAppUpdate()}>Actualizar Coco</button>}
      </div>
      <button className="coco-player" aria-label={`Perfil de ${identity.username||'jugador sin nombre'}`} onClick={()=>navigate('settings')}><ProfileAvatar src={avatar} name={identity.username}/><span>{identity.username||'Elige tu nombre'}</span><ArrowUpRight size={14}/></button>
    </aside>

    <div className="coco-room">
      <header className="coco-bar" aria-label="Biblioteca y ventana">
        {view==='library'?<div className="coco-filters" ref={filtersRef} role="group" aria-label="Filtrar biblioteca">{libraryFilters.map(option=>{const count=option.id==='installed'?installedIds.size:option.id==='favorites'?favorites.size:0;return <button key={option.id} className={filter===option.id?'active':''} aria-pressed={filter===option.id} onClick={()=>setFilter(option.id)}>{option.label}{count>0&&<sup key={count}>{count}</sup>}</button>;})}<i className="coco-filter-ink" aria-hidden="true"/></div>:<button className="coco-back" onClick={()=>navigate('library')}><ArrowRight size={15}/> Volver a la biblioteca</button>}
        <div className="dock-drag" data-tauri-drag-region aria-hidden="true"/>
        <div ref={searchBoxRef} className="discovery-search-wrap" onBlur={event=>{if(!event.currentTarget.contains(event.relatedTarget as Node|null))setSearchOpen(false);}}><div className="search-control"><Search size={15}/><input id="cocoSearch" type="search" role="combobox" aria-autocomplete="list" aria-expanded={searchOpen} aria-controls="cocoDiscoveryResults" aria-activedescendant={searchOpen&&searchActiveIndex>=0&&discoveryMatches[searchActiveIndex]?`cocoDiscoveryResult-${searchActiveIndex}`:undefined} placeholder="Buscar" aria-label="Buscar juegos y películas" value={search} onFocus={()=>setSearchOpen(true)} onKeyDown={onDiscoveryKey} onChange={event=>chooseSearch(event.target.value)}/><kbd>Ctrl K</kbd></div>{searchOpen&&<div id="cocoDiscoveryResults" className="coco-discovery-results" role="listbox" aria-label={search.trim()?'Resultados de búsqueda':'Explora rápidamente'}>{discoveryMatches.length?discoveryMatches.map((entry,index)=><button id={`cocoDiscoveryResult-${index}`} role="option" aria-selected={index===(searchActiveIndex>=0?searchActiveIndex:0)} type="button" key={entry.id} className={`coco-discovery-option ${index===(searchActiveIndex>=0?searchActiveIndex:0)?'active':''}`} onMouseEnter={()=>setSearchActiveIndex(index)} onClick={()=>openDiscoveryEntry(entry)}><img src={entry.image} loading="lazy" alt=""/><span className="coco-discovery-label"><strong>{entry.name}</strong><small>{installedIds.has(entry.id)?'Instalado':meta(entry)}{favorites.has(entry.id)?' · Favorito':''}</small></span><ArrowUpRight size={16}/></button>):<p className="coco-discovery-empty">Nada con ese nombre. Prueba con otro título.</p>}</div>}</div>
        {view==='library'&&<button className="coco-icon-button" aria-label={sort==='recent'?'Ordenar de la A a la Z':'Ordenar por más recientes'} title={sort==='recent'?'Más recientes primero':'De la A a la Z'} onClick={()=>setSort(sort==='recent'?'name':'recent')}>{sort==='recent'?<Clock3 size={16}/>:<ArrowDownAZ size={16}/>}</button>}
        <button className={`coco-icon-button ${view==='settings'?'active':''}`} aria-label="Ajustes" title="Ajustes" onClick={()=>navigate(view==='settings'?'library':'settings')}><Settings2 size={16}/></button>
        {isTauri()&&<div className="window-buttons"><button aria-label="Minimizar" title="Minimizar" onClick={()=>void getCurrentWindow().minimize()}><Minus size={16}/></button><button aria-label="Maximizar o restaurar" title="Maximizar" onClick={()=>void getCurrentWindow().toggleMaximize()}><Maximize2 size={14}/></button><button className="window-close" aria-label="Cerrar" title="Cerrar" onClick={()=>void getCurrentWindow().close()}><X size={17}/></button></div>}
        <i className="coco-scroll-line" aria-hidden="true"/>
      </header>

      <main className="main-content" id="mainContent" ref={mainRef}>
        {loadError&&<div className="notice error" role="alert">No se pudo leer la biblioteca: {loadError}</div>}
        {inboxPersistenceError&&<div className="notice error" role="alert">No se pudo guardar la revisión pendiente. Mantén Coco abierto; si se cierra inesperadamente, vuelve a abrir el paquete desde Explorer. No se importó ni ejecutó nada.</div>}
        {welcomeVisible&&<React.Suspense fallback={null}><LazyFirstRun hostStudioAvailable={hostStudioAvailable} catalogReady={items.length>0&&!loadError} onExplore={()=>{dismissWelcome();navigate('library');if(installedIds.size)setFilter('installed');}} onOpenPackage={()=>{if(hostStudioAvailable){navigate('settings');setPackagePickerRequest(++packagePickerSerial.current);}}} onDismiss={dismissWelcome} installedCount={installedIds.size}/></React.Suspense>}
        {incomingPackages.length>0&&packageReviewDeferred&&<div className="coco-package-deferred" role="status" aria-live="polite"><FileArchive size={16}/><span>{incomingPackages.length===1?'Recibiste un paquete para revisar':`${incomingPackages.length} paquetes esperan revisión`}. Se mostrarán cuando termines la operación actual. No se importó ni ejecutó nada.</span></div>}
        {inbox.dropped>0&&incomingPackages.length===0&&<div className="notice error coco-inbox-overflow" role="alert">Se recibieron más paquetes de los que Coco puede revisar a la vez. Abre nuevamente los archivos pendientes desde Explorer. <button className="filter-button" onClick={()=>commitInbox(acknowledgePackageOverflow(inboxLive.current))}>Entendido</button></div>}
        {pendingOperations.length>0&&<section className="coco-recovery-banner" role="alert" aria-label="Operaciones pendientes de recuperar"><ShieldCheck size={19}/><div><strong>{pendingOperations.length===1?'Hay un juego pendiente de recuperar':`${pendingOperations.length} juegos necesitan revisión`}</strong><p>Los archivos permanecen protegidos. Coco no modificará nada sin que revises la recuperación.</p></div><div className="coco-recovery-buttons">{pendingOperations.slice(0,3).map(operation=><button className="filter-button" key={`${operation.id}/${operation.kind}`} onClick={()=>{const entry=items.find(x=>x.id===operation.id);if(entry){openDetails(entry);setOperationMessage(operation.status==='blocked-unsafe'?'La recuperación automática está bloqueada por seguridad. Revisa la instalación.':'Hay una operación interrumpida: revisa la recuperación disponible.');}else navigate('settings');}}>{items.find(x=>x.id===operation.id)?.name||'Ver juego'} <ArrowRight size={14}/></button>)}</div></section>}

        {view==='library'&&<div className="page-content coco-library" key="library">
          {latestNode}
          {gridEntries.length>0||latest?<div ref={gridRef} className="experience-grid">{gridNodes}</div>:<div className="empty"><Search size={27}/><strong>{normalizedQuery?'Nada con ese nombre':filter==='installed'?'Todavía no instalas nada':filter==='favorites'?'Marca un corazón para verlo aquí':'Nada por aquí'}</strong></div>}
          {visibleCount<gridEntries.length&&<div ref={moreCardsRef} className="coco-more-cards"><button className="filter-button" onClick={()=>setVisibleCount(current=>nextExperiencePage(current,gridEntries.length))}>Ver más <ArrowRight size={15}/></button><span>{Math.min(visibleCount,gridEntries.length)} de {gridEntries.length}</span></div>}
        </div>}

        {view==='settings'&&<div className="page-content coco-settings" key="settings">
          <h1>Ajustes</h1>
          <section className="coco-setting coco-profile"><div className="coco-profile-picture"><label className={`coco-avatar-picker ${avatarBusy?'is-busy':''}`} title="Cambiar foto"><ProfileAvatar src={avatar} name={identity.username}/><span className="coco-avatar-overlay"><Camera size={20}/></span><input className="sr-only" type="file" accept="image/png,image/jpeg,image/webp,image/gif" aria-label="Elegir foto de perfil" disabled={avatarBusy||!isTauri()} onChange={event=>{void chooseAvatar(event.target.files?.[0]);event.target.value='';}}/></label>{avatar&&<button className="coco-avatar-remove" disabled={avatarBusy} onClick={()=>void removeAvatar()}>Quitar foto</button>}</div><div className="coco-profile-copy"><h2>Tu perfil</h2><p>Así te verán tus amigos cuando se conecten.</p><div className="coco-setting-control"><label htmlFor="minecraftIdentity" className="sr-only">Tu nombre de jugador</label><input id="minecraftIdentity" className="settings-input" maxLength={16} placeholder="Tu nombre" value={identityName} onChange={e=>{setIdentityName(e.target.value);setConfirmIdentity(false);setIdentityError('');}}/>
            <button className="toggle-button" disabled={!isTauri()||savingIdentity||identityName===identity.username} onClick={saveIdentity}><Check size={15}/>{confirmIdentity?'Confirmar cambio':'Guardar'}</button>
            {confirmIdentity&&<p className="identity-warning">Cambiar el nombre puede cambiar tu inventario y avances. Confirma el cambio.</p>}{identityError&&<p className="operation-message" role="alert">{identityError}</p>}{avatarError&&<p className="operation-message" role="alert">{avatarError}</p>}</div></div></section>
          <section className="coco-setting"><div><h2>Windows Defender</h2><p>{defenderOutcome||'Coco excluye solo las carpetas de juegos y sus descargas.'}</p></div><div className="coco-setting-control"><button className="filter-button" disabled={!isTauri()||defenderBusy||authorizing} onClick={()=>void checkDefender()}><ShieldCheck size={14}/> {defenderBusy?'Revisando…':'Volver a pedir'}</button></div></section>
          <section className="coco-setting"><div><h2>Ayuda</h2><p>{diagnosticNote||'Si algo falla, copia el diagnóstico y pégalo en el chat con Coco.'}</p></div><div className="coco-setting-control"><button className="filter-button active" disabled={!isTauri()} onClick={()=>void copyDiagnostic()}><ClipboardCopy size={14}/> Copiar diagnóstico</button><button className="filter-button" disabled={!isTauri()} onClick={()=>void invoke('open_log_folder').catch(console.warn)}><FolderOpen size={14}/> Abrir registros</button></div></section>
          {hostStudioAvailable&&<section className="coco-setting coco-host"><div><h2>Anfitrión</h2><p>Solo aparece en tu PC. Prepara juegos y revisa paquetes de prueba.</p></div><div className="coco-setting-control"><button className="host-studio-button" title={hostStudioBlocked?'Termina la operación activa o revisa el paquete pendiente antes de crear otro':'Crear un paquete compartible'} disabled={hostStudioBlocked} onClick={()=>{if(!hostStudioBlocked)setHostStudioOpen(true);}}><PackagePlus size={17}/><span>Crear juego</span></button></div>{incomingPackages.length===0&&isTauri()&&<React.Suspense fallback={null}><LazyCatalogHub hostStudioAvailable={hostStudioAvailable} onChanged={refreshNativeCatalog} onImported={openImportedGame} pickerRequestId={hostStudioAvailable?packagePickerRequest:0} onPickerRequestConsumed={()=>setPackagePickerRequest(0)}/></React.Suspense>}</section>}
          <section className="coco-activity-history" aria-label="Actividad reciente guardada en este PC">
            <div className="coco-activity-history-head"><div><h2>Tu actividad</h2></div>{activity.length>0&&<button className="filter-button" onClick={()=>{clearActivity();setActivity([]);}}>Borrar historial</button>}</div>
            {activity.length===0?<p className="coco-activity-empty">Lo que juegues e instales aparecerá aquí.</p>:
              <div className="coco-activity-entries">{activity.slice(0,12).map((event,index)=>{
                const entry=items.find(x=>x.id===event.id);
                const interrupted=event.kind.endsWith('-interrupted');
                return <div className={`coco-activity-entry ${interrupted?'coco-activity-interrupted':''}`} key={`${event.at}-${event.id}-${event.kind}-${index}`}>
                  <span className="summary-icon">{interrupted?<CircleAlert size={16}/>:<Activity size={16}/>}</span><div><strong>{activityTitles[event.kind]} {entry?.name||'una experiencia'}</strong><time dateTime={new Date(event.at).toISOString()}>{new Date(event.at).toLocaleString('es-CL',{dateStyle:'medium',timeStyle:'short'})}</time>{interrupted&&<small>El resultado en disco se comprobará al abrir la ficha. No se ejecutará una recuperación automática.</small>}</div>
                  {entry&&<button className="filter-button" onClick={()=>openDetails(entry)}>{interrupted?'Revisar':'Ver'} <ArrowRight size={13}/></button>}
                </div>;
              })}</div>}
          </section>
          {operationMessage&&<p className="operation-message">{operationMessage}</p>}
        </div>}
      </main>
    </div>

    {selected&&<><div className="overlay" onClick={closeDetails}/><aside className="detail-drawer" role="dialog" aria-modal="true" aria-label={`Detalles de ${selected.name}`} tabIndex={-1} onKeyDown={onDetailKey}>
      <div className="drawer-hero"><img src={selected.image} alt=""/>{motion&&selected.workflow==='coco-standalone'&&Object.hasOwn(gameHoverPreviews,selected.id)&&<video key={selected.id} className="drawer-hero-video" src={cachedPreviews.get(selected.id)||gameHoverPreviews[selected.id].url} preload="auto" muted loop playsInline aria-hidden="true" tabIndex={-1} onCanPlay={event=>void event.currentTarget.play().catch(()=>{})} onPlaying={event=>event.currentTarget.classList.add('is-playing')}/>}<button autoFocus className="drawer-close" aria-label="Cerrar" onClick={closeDetails}><X size={18}/></button></div>
      <div className="drawer-copy"><h2>{selected.name}</h2><p>{selected.description}</p><div className="drawer-chips">{catalogSources.get(selected.id)?.source==='local'&&<span className="catalog-origin-local" title="Paquete aceptado manualmente en este equipo; no equivale a publicación oficial">Importado en este PC</span>}</div>
        <div className="drawer-actions">
          {primaryGame&&<button className={`primary-button${primaryGame.pending?' is-pending':''}`} aria-busy={primaryGame.pending||undefined} disabled={primaryGame.kind==='disabled'} title={primaryGame.reason} aria-describedby={primaryGame.kind==='disabled'?'gamePrimaryHint':undefined} onClick={()=>primaryGame.kind==='install'?void installNative(selected):primaryGame.kind==='launch'?void launchNative(selected):undefined}>{installing===selected.id||moving===selected.id||primaryGame.pending?<LoaderCircle className="spin" size={16}/>:primaryGame.kind==='install'?<Download size={16}/>:primaryGame.kind==='launch'?<Play size={16}/>:<CircleAlert size={16}/>} {installing===selected.id?'Instalando…':moving===selected.id?'Moviendo…':primaryGame.label}{primaryGame.kind==='install'&&installing!==selected.id&&installPlan?.id===selected.id&&installPlan.status==='ready'&&<span className="primary-size">{formatBytes(installPlan.totalDownloadBytes)}</span>}</button>}
          {isComingSoon(selected)&&<button className="primary-button" disabled>Desactivado</button>}
          {selected.workflow==='coco-media'&&(()=>{
            const media=mediaCatalog.find(x=>x.id===selected.id);
            const plan=media?.episodes.length?mediaPlan(selected.id,media.episodes,media.type==='movie'):null;
            const started=plan&&plan.resume!==null;
            return <button className={`primary-button coco-watch ${started?'is-resuming':''}`} disabled={mediaLoading||!isTauri()||!plan||Boolean(streamLoading)}
              onClick={()=>{if(plan)void playMedia(selected,plan.episode);}}>
              {streamLoading?<LoaderCircle className="spin" size={16}/>:<Play size={16} fill="currentColor"/>} {streamLoading?'Abriendo…':plan?.label??'Ver'}
              {started&&!streamLoading&&<span className="primary-size">Quedan {formatRemaining(plan.remaining)}</span>}
              {started&&<i className="coco-watch-progress" style={{width:`${watchedFraction(plan.progress)*100}%`}}/>}
            </button>;
          })()}
          <button className="secondary-button" aria-label="Favorito" aria-pressed={favorites.has(selected.id)} onClick={()=>toggleFavorite(selected.id)}><Heart size={16} fill={favorites.has(selected.id)?'currentColor':'none'}/></button>
        </div>
        {primaryGame&&primaryGame.kind==='disabled'&&installing!==selected.id&&moving!==selected.id&&<p id="gamePrimaryHint" className="coco-action-hint" role="status">{primaryGame.reason}</p>}
        {selected.workflow==='coco-media'&&(()=>{
          const media=mediaCatalog.find(x=>x.id===selected.id);
          return <>
            {mediaLoading&&!media&&<p className="coco-media-loading"><LoaderCircle className="spin" size={14}/> Cargando…</p>}
            {media&&media.episodes.length>0&&<EpisodePicker key={selected.id} id={selected.id} episodes={media.episodes} movie={media.type==='movie'}
              loadingId={streamLoading} disabled={!isTauri()||Boolean(streamLoading)||Boolean(mediaPlaying)}
              onPlay={(episode,fromStart)=>void playMedia(selected,episode,fromStart)}/>}
            {mediaError&&<p className="operation-message" role="alert">{mediaError}</p>}
          </>;
        })()}
        {selected.workflow==='coco-standalone'&&localInstances.get(selected.id)?.state!=='folder-present'&&<div className="coco-install-summary">{installing===selected.id?<button className="filter-button" onClick={cancelInstall}>Cancelar instalación</button>:installPlan?.id===selected.id&&installPlan.status!=='ready'&&<p>{installPlan.message}</p>}
          {installLocation?.id===selected.id&&<div className="coco-folder-row is-solo"><span className="coco-storage-icon"><FolderOpen size={17}/></span><div className="coco-folder-copy"><small>Se instalará en</small><code key={installLocation.path} title={installLocation.path}>{shortPath(installLocation.path,54)}</code>{installLocation.freeBytes!==null&&<small className={installPlan?.id===selected.id&&installLocation.freeBytes<installPlan.totalDownloadBytes?'is-short':''}>{formatBytes(installLocation.freeBytes)} libres en {installLocation.path.slice(0,2)}</small>}</div><div className="coco-folder-actions">{installLocation.custom&&<button className="coco-link-button" disabled={locationBusy||Boolean(installing)} onClick={()=>void chooseInstallFolder(selected,true)}>Restablecer</button>}<button className="filter-button" disabled={locationBusy||Boolean(installing)} onClick={()=>void chooseInstallFolder(selected)}>Cambiar</button></div></div>}
          {locationError&&<p className="coco-location-error" role="alert">{locationError}</p>}</div>}
        {selected.workflow==='coco-standalone'&&(upgrading===selected.id||upgradeRecovering===selected.id||(upgradePlan?.id===selected.id&&['upgrade-ready','recovery-required','recovery-blocked'].includes(upgradePlan.status)))&&<div className="verify-control upgrade-workspace">
          <div className="verify-title"><Download size={17}/><strong>{upgradePlan?.status==='upgrade-ready'?'Versión nueva':'Actualización interrumpida'}</strong></div>
          {upgradePlan?.status==='upgrade-ready'&&<p className="upgrade-version"><span>{upgradePlan.fromVersion||'Instalado'}</span><ArrowRight size={15}/><strong>{upgradePlan.toVersion}</strong>{upgradePlan.neededBytes>0&&<small>{formatBytes(upgradePlan.neededBytes)}</small>}</p>}
          {upgradePlan?.status==='recovery-required'&&<p>Recupérala para volver a jugar.</p>}
          {upgradePlan?.status==='recovery-blocked'&&<p>Coco no puede recuperarla sola y no tocó tus archivos.</p>}
          {(upgrading===selected.id||upgradeRecovering===selected.id)&&<div className="progress-track"><div className="progress-fill progress-real" style={{width:`${Math.max(0,Math.min(100,installProgress?.percent??0))}%`}}/></div>}
          <div className="repair-actions">{upgradePlan?.status==='upgrade-ready'&&<button className="filter-button active" disabled={Boolean(upgrading||upgradeRecovering||installing||uninstalling||mediaDownloadActive||busy||updateRunning.current)} onClick={()=>void performUpgrade(selected)}>{upgrading===selected.id?'Actualizando…':'Actualizar'}</button>}
          {upgradePlan?.status==='recovery-required'&&<button className="filter-button" disabled={Boolean(upgrading||upgradeRecovering||installing||uninstalling||busy||updateRunning.current)} onClick={()=>void recoverUpgrade(selected)}>{upgradeRecovering===selected.id?'Recuperando…':'Recuperar'}</button>}
          {upgrading===selected.id&&<button className="filter-button" onClick={()=>void invoke('cancel_standalone_install',{id:selected.id}).catch(console.error)}>Cancelar</button>}</div>
          {upgradeOutcome?.id===selected.id&&<p className="drawer-note" role="status">{upgradeOutcome.message}</p>}
        </div>}
        {selected.workflow==='coco-standalone'&&(repairRecoveryStatus.get(selected.id)?.pending||repairRecoveryStatus.get(selected.id)?.cleanupPending||repairRecovering===selected.id)&&<div className="verify-control repair-workspace" role="alert">
          <div className="verify-title"><CircleAlert size={17}/><strong>Reparación interrumpida</strong></div>
          <p>Recupérala para volver a jugar. Tus archivos están protegidos.</p>
          {repairRecovering===selected.id&&installProgress&&<div className="progress-track"><div className="progress-fill progress-real" style={{width:`${Math.max(0,Math.min(100,installProgress.percent))}%`}}/></div>}
          <div className="repair-actions"><button className="filter-button repair-recover-action" disabled={Boolean(repairRecovering||installing||uninstalling||updateRunning.current)} onClick={()=>void recoverRepair(selected)}>{repairRecovering===selected.id?'Recuperando…':'Recuperar'}</button></div>
        </div>}
        {selected.workflow==='coco-standalone'&&localInstances.get(selected.id)?.state==='folder-present'&&<div className={`coco-storage ${uninstallConfirm===selected.id?'is-confirming':''}`}>
          <div className="coco-storage-line"><span className="coco-storage-icon"><HardDrive size={17}/></span><div className="coco-storage-copy"><small>En este PC</small><strong key={installedSizes.get(selected.id)??'measuring'}>{uninstalling===selected.id?'Desinstalando…':installedSizes.has(selected.id)?formatBytes(installedSizes.get(selected.id)!):'Midiendo…'}</strong></div>
            {uninstallConfirm!==selected.id&&<button className="coco-uninstall" disabled={nativeBusy||runtime?.state==='running'||observedGameIds.includes(selected.id)||gameProcessUncertain} title={runtime?.state==='running'||observedGameIds.includes(selected.id)?'Cierra el juego para desinstalarlo':undefined} onClick={()=>{setMoveDraft(null);setUninstallConfirm(selected.id);}}><Trash2 size={14}/> Desinstalar</button>}</div>
          {installLocation?.id===selected.id&&<div className="coco-folder-row"><span className="coco-storage-icon"><FolderOpen size={17}/></span><div className="coco-folder-copy"><small>Carpeta</small><code key={installLocation.path} title={installLocation.path}>{shortPath(installLocation.path,installLocation.custom?38:48)}</code></div><div className="coco-folder-actions"><button className="coco-link-button" onClick={()=>void invoke('open_game_folder',{id:selected.id}).catch(error=>setLocationError(String(error)))}>Abrir</button>{installLocation.custom&&<button className="coco-link-button" disabled={nativeBusy||locationBusy} title="Volver a la carpeta de Coco Launcher 2" onClick={()=>void chooseInstallFolder(selected,true)}>Restablecer</button>}<button className="coco-uninstall" disabled={nativeBusy||locationBusy||runtime?.state==='running'||observedGameIds.includes(selected.id)||gameProcessUncertain} title={runtime?.state==='running'||observedGameIds.includes(selected.id)?'Cierra el juego para moverlo':undefined} onClick={()=>void chooseInstallFolder(selected)}><FolderInput size={14}/> Mover</button></div></div>}
          {moving===selected.id&&<div className="coco-move-live" role="status"><div className="coco-move-live-head"><span>{nativeProgressDescription(installProgress?.phase||'moving')}</span><strong>{installProgress?.percent??0}%</strong></div><div className={`coco-status-bar ${installProgress?'':'is-waiting'}`}><span style={installProgress?{width:`${installProgress.percent}%`}:undefined}/></div><button className="filter-button" onClick={()=>void invoke('cancel_standalone_install',{id:selected.id}).catch(console.error)}>Cancelar</button></div>}
          {moveDraft?.id===selected.id&&installLocation&&(()=>{
            const short=moveDraft.check.freeBytes!==null&&moveDraft.check.freeBytes<moveDraft.check.neededBytes;
            return <div className="coco-move-confirm" role="group" aria-label={`Confirmar nueva carpeta de ${selected.name}`}>
              <div className="coco-move-route"><div><small>Desde</small><code title={installLocation.path}>{shortPath(installLocation.path)}</code></div><i className="coco-move-rail" aria-hidden="true"><b/><b/><b/></i><div><small>Hacia</small><code title={moveDraft.check.root}>{shortPath(moveDraft.check.root)}</code></div></div>
              <p className={short?'is-short':''}>{moveDraft.check.sameDrive?'Es la misma unidad, así que será al instante.':short?`No alcanza: necesita ${formatBytes(moveDraft.check.neededBytes)} y hay ${formatBytes(moveDraft.check.freeBytes!)} libres.`:`Copia ${formatBytes(moveDraft.check.neededBytes)} a otra unidad y borra el original solo cuando todo esté comprobado.`}</p>
              <div className="coco-move-buttons"><button autoFocus className="filter-button" onClick={()=>setMoveDraft(null)}>Dejarlo aquí</button><button className="filter-button active" disabled={short||nativeBusy} onClick={()=>void moveInstallation(selected,moveDraft)}>Mover</button></div>
            </div>;
          })()}
          {locationError&&<p className="coco-location-error" role="alert">{locationError}</p>}
          {uninstallConfirm===selected.id&&<div className="coco-uninstall-confirm" role="group" aria-label={`Confirmar desinstalación de ${selected.name}`}><p>Se borran los archivos del juego{installedSizes.has(selected.id)?` y se liberan ${formatBytes(installedSizes.get(selected.id)!)}`:''}. Coco guarda las carpetas de partidas que encuentre y las devuelve si lo reinstalas.</p><div><button autoFocus className="filter-button" onClick={()=>setUninstallConfirm(null)}>Conservar</button><button className="coco-uninstall-yes" disabled={nativeBusy} onClick={()=>void uninstallNative(selected)}>Sí, desinstalar</button></div></div>}
        </div>}
        {operationMessage&&<p className="operation-message" role={nativeFailure&&nativeFailure.summary===operationMessage?'alert':'status'}>{nativeFailure&&nativeFailure.summary===operationMessage&&<CircleAlert size={15}/>}{operationMessage}</p>}
        {nativeFailure&&nativeFailure.summary===operationMessage&&<div className="coco-native-failure-card" role="group" aria-label="Revisar fallo y siguientes pasos">
          <strong>Revisar antes de reintentar</strong>
          <p>{nativeFailure.kind==='space'?'Comprueba el espacio libre en la misma unidad del juego. La preparación se mantiene independiente de las partidas.':
            nativeFailure.kind==='network'?'Comprueba tu conexión. El próximo intento podrá aprovechar únicamente bytes de caché verificados.':
            nativeFailure.kind==='source'?'La fuente remota respondió de forma incompatible: Coco no utilizará esos bytes. Reintenta más tarde sin modificar los archivos parciales.':
            nativeFailure.kind==='locked'?'Cierra juegos y procesos que usen estos archivos. Un bloqueo de Windows no demuestra por sí solo una detección antivirus.':
            nativeFailure.kind==='permissions'?'Puedes verificar la carpeta registrada y consultar el Historial de protección. Una denegación de acceso no prueba una cuarentena.':
            nativeFailure.kind==='integrity'?'Sus archivos no coinciden con los publicados. Desinstálalo y vuelve a instalarlo.':
            'Revisa el estado actual y utiliza los botones de recuperación solo si Coco detecta una operación interrumpida.'}</p>
          <div className="coco-native-failure-actions">
            {installPlan?.id===selected.id&&installPlan.status==='ready'&&
              localInstances.get(selected.id)?.state!=='folder-present'&&
              !['integrity','recovery'].includes(nativeFailure.kind)&&
              <button className="filter-button" type="button"
                disabled={Boolean(nativeOperationGate.current.busy()||installing||upgrading||
                  repairRecovering||mediaDownloadActive||updateRunning.current)}
                onClick={()=>void installNative(selected)}><Download size={14}/> Reintentar instalación</button>}
            {localInstances.get(selected.id)?.state==='folder-present'&&<button className="filter-button" type="button"
              disabled={securityBusy} onClick={()=>void requestGameSecurityGuide(selected)}>
              {securityBusy?'Verificando ruta…':'Comprobar ruta del juego'}</button>}
            {(nativeFailure.kind==='permissions'||nativeFailure.kind==='locked')&&<button className="filter-button" type="button"
              onClick={()=>void openSecuritySettings()}>Seguridad de Windows</button>}
          </div>
          {nativeDiagnosticPath&&<div className="coco-native-failure-path"><small>{diagnosticPathVerified?'Carpeta registrada y verificada (no necesariamente el archivo bloqueado)':'Ruta de destino prevista por el motor de Coco (no demuestra que exista o esté bloqueada)'}</small><code>{nativeDiagnosticPath}</code><button className="filter-button" type="button" onClick={()=>void copyNativeDiagnosticPath()}>{securityCopied?'Ruta copiada':'Copiar ruta'}</button>
            {securityGuide?.id===selected.id&&affectedRegisteredGamePath(nativeFailure.detail,securityGuide.folder)&&<div className="coco-native-quoted-file"><small>Ruta mencionada por el error, no confirma cuarentena</small><code>{affectedRegisteredGamePath(nativeFailure.detail,securityGuide.folder)}</code></div>}
          </div>}
          {(nativeFailure.kind==='locked'||nativeFailure.kind==='permissions')&&<p className="coco-defender-evidence">Para saber si Defender intervino, abre Seguridad de Windows → Protección contra virus y amenazas → Historial de protección. Compara allí el nombre y la ruta del evento con el archivo afectado. Si no aparece, investiga permisos y procesos que usan el archivo antes de atribuirlo al antivirus.</p>}
          {securityError&&<p role="alert" className="operation-message">{securityError}</p>}
          <div className="coco-failure-help"><button className="filter-button" onClick={()=>void copyDiagnostic()}><ClipboardCopy size={14}/> Copiar diagnóstico</button>{diagnosticNote&&<small role="status">{diagnosticNote}</small>}</div>
          <details className="repair-advanced"><summary>Ver detalle del fallo y su origen</summary><p>{nativeFailure.detail}</p><p>Coco solo agrega a Defender las carpetas de juegos, con tu autorización de Windows. No lo desactiva.</p></details>
        </div>}
      </div>
      {Object.hasOwn(gameScreenshots,selected.id)&&<ScreenshotGallery key={selected.id} shots={gameScreenshots[selected.id]} name={selected.name}/>}
    </aside></>}
    {mediaPlaying&&<React.Suspense fallback={<div className="coco-player-loading"><LoaderCircle className="spin"/> Preparando reproductor…</div>}><LazyMediaPlayer title={mediaPlaying.title} subtitle={mediaPlaying.subtitle} startAt={mediaPlaying.startAt}
      url={mediaPlaying.stream.url} mimeType={mediaPlaying.stream.mimeType} onClose={closeMedia} onReopen={reopenMedia}
      progress={{id:mediaPlaying.stream.id,episodeId:mediaPlaying.stream.episodeId}} next={(()=>{
        const media=mediaCatalog.find(item=>item.id===mediaPlaying.stream.id);
        const at=media?media.episodes.findIndex(item=>item.id===mediaPlaying.stream.episodeId):-1;
        const following=media&&at>=0?media.episodes[at+1]:undefined;
        const entry=items.find(item=>item.id===mediaPlaying.stream.id);
        if(!media||!following||!entry)return undefined;
        return {title:episodeLabels(media.episodes).labels[at+1],play:()=>{setQueuedEpisode({entry,episode:following});closeMedia(false);}};
      })()}/></React.Suspense>}
    {hostStudioOpen&&<React.Suspense fallback={<div className="coco-player-loading"><LoaderCircle className="spin"/> Cargando…</div>}><LazyHostStudio close={()=>setHostStudioOpen(false)} onCatalogChanged={refreshNativeCatalog}/></React.Suspense>}
    {incomingPackages.length>0&&!packageReviewDeferred&&isTauri()&&<div className="coco-inbox-overlay" role="presentation"><div className="coco-inbox-dialog" role="dialog" aria-modal="true" aria-label="Revisar paquete recibido" tabIndex={-1} ref={inboxDialogRef} onKeyDown={event=>{
      if(event.key==='Escape'){
        const dismiss=event.currentTarget.querySelector<HTMLButtonElement>('.catalog-inbox-dismiss:not(:disabled)');
        if(dismiss){event.preventDefault();dismiss.click();}
      }else if(event.key==='Tab'){
        const elements=Array.from(event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),summary,[tabindex="0"]')).filter(element=>element.getClientRects().length>0);
        if(elements.length){const first=elements[0],last=elements[elements.length-1];if(document.activeElement===event.currentTarget){event.preventDefault();(event.shiftKey?last:first).focus();}else if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}
      }
    }}>
      <div className="coco-inbox-brand"><span className="eyebrow">PAQUETE RECIBIDO</span><span>{incomingPackages.length>1?`${incomingPackages.length} entregas`:'Nueva entrega'}</span></div>
      {inbox.dropped>0&&<p className="catalog-trust-note" role="alert">La cola está llena. Cuando termines, vuelve a abrir desde Explorer los archivos adicionales que no aparezcan aquí.</p>}
      <React.Suspense fallback={<div className="coco-inbox-loading" role="status"><LoaderCircle className="spin" size={22}/> Abriendo revisión segura…</div>}>
          <LazyCatalogHub key={incomingPackages[0]} hostStudioAvailable={hostStudioAvailable} incomingPath={incomingPackages[0]} pendingCount={incomingPackages.length} onChanged={refreshNativeCatalog} onImported={openImportedGame} onInboxDone={path=>{
            // Completion/discard is the user's action, never Explorer's open.
            // Save the finished review first. Without this release, React
            // dismisses the card but a second explicit double-click within
            // the native replay window is silently suppressed.
            const persisted=commitInbox(dismissPackageRequest(inboxLive.current,path));
            void (async()=>{
              try{
                if(persisted){
                  await invoke<boolean>('release_reviewed_package_replay_suppression',{path});
                }else{
                  // If storage was unavailable when this path originally
                  // arrived, native may still own it. User dismissal is the
                  // one explicit action allowed to discard that request.
                  await invoke<boolean>('cancel_pending_package_open_request',{path});
                }
              }catch(error){console.warn('Could not finalize reviewed Explorer request:',error);}
              finally{void activationDrainRef.current?.trigger();}
            })();
          }}/>
      </React.Suspense>
    </div></div>}
  </div>;
}

captureUnexpectedErrors();
createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
