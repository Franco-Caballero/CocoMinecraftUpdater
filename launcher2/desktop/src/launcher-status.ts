/** Everything the launcher is doing, reduced to the one line the side panel shows.
 * Order is priority: what can affect the player most always wins the panel. */
export type StatusTone='ready'|'busy'|'playing'|'attention'|'installed';
/** subject: what the operation acts on, on its own line. metrics: one fixed-format line of figures. */
export type LauncherStatus={tone:StatusTone;label:string;detail:string;percent:number|null;subject?:string;metrics?:string};
export type CatalogSyncState='idle'|'syncing'|'current'|'updated'|'local';

export type StatusInput={
  update:{stage:string;version:string;percent:number;message:string};
  operation:{kind:'install'|'upgrade'|'repair'|'recover'|'move';name:string;description:string;percent:number;rate:string;metrics?:string}|null;
  mediaDownload:{title:string;percent:number;verifying:boolean}|null;
  launching:string|null;
  playing:string[];
  processUncertain:boolean;
  uninstalling:string|null;
  authorizing:boolean;
  startingSteam:boolean;
  /** The fix's one-time setup for this PC, run out of sight before the game opens. */
  firstGameRun?:boolean;
  /** A game this session just finished installing: it stays until played or dismissed. */
  installed?:{name:string}|null;
  pendingRecovery:number;
  arrival:string|null;
  catalog:CatalogSyncState;
  catalogLoaded:boolean;
};

const operationLabels={install:'Instalando',upgrade:'Actualizando',repair:'Reparando',recover:'Recuperando',move:'Moviendo'} as const;

export function deriveLauncherStatus(input:StatusInput):LauncherStatus{
  const {update,operation}=input;
  if(input.authorizing)
    return {tone:'attention',label:'Autorización de Windows',detail:'Pulsa «Sí» en el aviso de Windows',percent:null};
  if(input.startingSteam)
    return {tone:'busy',label:'Abriendo Steam',detail:'Tu juego parte en cuanto esté listo',percent:null};
  if(input.firstGameRun)
    return {tone:'busy',label:'Preparando el juego',detail:'Solo la primera vez en este PC',percent:null};
  if(update.stage==='installing')
    return {tone:'busy',label:'Reiniciando Coco',detail:`Instalando la versión ${update.version}`,percent:100};
  if(update.stage==='downloading')
    return {tone:'busy',label:'Actualizando Coco',detail:`Descargando la versión ${update.version}`,percent:update.percent};
  if(operation)
    return {tone:'busy',label:operationLabels[operation.kind],subject:operation.name,
      detail:operation.description,metrics:operation.metrics||operation.rate,percent:Math.round(operation.percent)};
  if(input.mediaDownload)
    return {tone:'busy',label:input.mediaDownload.verifying?'Comprobando video':'Guardando video',
      detail:input.mediaDownload.title,percent:input.mediaDownload.percent};
  if(input.uninstalling)
    return {tone:'busy',label:`Desinstalando ${input.uninstalling}`,detail:'Liberando espacio',percent:null};
  if(input.launching)
    return {tone:'busy',label:`Abriendo ${input.launching}`,detail:'Comprobando sus archivos',percent:null};
  if(input.playing.length)
    return {tone:'playing',label:input.playing.length===1?`Jugando ${input.playing[0]}`:`${input.playing.length} juegos abiertos`,
      detail:'',percent:null};
  if(input.installed)
    return {tone:'installed',label:'Instalado',subject:input.installed.name,detail:'Listo para jugar',percent:100};
  if(input.pendingRecovery>0)
    return {tone:'attention',label:input.pendingRecovery===1?'Un juego necesita revisión':`${input.pendingRecovery} juegos necesitan revisión`,
      detail:'Tus archivos están protegidos',percent:null};
  if(update.stage==='deferred'&&update.version)
    return {tone:'attention',label:'Hay una versión nueva',detail:`Coco ${update.version} está lista para instalar`,percent:null};
  if(input.arrival)
    return {tone:'ready',label:'Juego nuevo',detail:input.arrival,percent:null};
  if(!input.catalogLoaded)
    return {tone:'busy',label:'Abriendo biblioteca',detail:'Un momento',percent:null};
  // Background catalog checks stay silent: the panel only changes when something actually arrives.
  return {tone:'ready',label:'Listo para jugar',
    detail:input.processUncertain?'No pude revisar los juegos abiertos':'',percent:null};
}
