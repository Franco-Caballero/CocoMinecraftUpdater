/** The same prominent button evolves from installation to play. Never infer a
 * usable install from a missing/stale presence read, nor enable a second
 * native action during verification or a running game. */
export type GamePrimaryAction={kind:'install'|'launch'|'disabled';label:string;reason:string;pending?:boolean};
export function gamePrimaryAction(input:{
  localState?:'folder-present'|'not-found'|'unknown'|'unmanaged';
  planStatus?:string;planMessage?:string;nativeAvailable:boolean;
  busy:boolean;gameActive:boolean;processUnknown:boolean;hostingMode:string;
  /** This game is being opened right now; firstRun = per-PC preparation. */
  opening?:boolean;firstRun?:boolean;
}):GamePrimaryAction{
  if(!input.nativeAvailable)return {kind:'disabled',label:'Disponible en Windows',reason:'Instala Coco Launcher 2 en Windows para continuar.'};
  if(input.hostingMode!=='p2p')return {kind:'disabled',label:'Próximamente',reason:'Este juego todavía no permite iniciarse desde Coco.'};
  if(input.localState==='folder-present'){
    if(input.opening&&input.firstRun)return {kind:'disabled',pending:true,label:'Preparando el juego',reason:'Solo la primera vez en este PC. El juego se abrirá en unos segundos.'};
    if(input.opening)return {kind:'disabled',pending:true,label:'Abriendo…',reason:'Verificando archivos y abriendo el juego.'};
    if(input.gameActive)return {kind:'disabled',label:'Juego activo',reason:'El juego ya está abierto. Puedes volver a él desde Windows.'};
    if(input.processUnknown)return {kind:'disabled',label:'Comprobando procesos',reason:'Coco no puede confirmar que los ejecutables estén cerrados. Inténtalo después.'};
    if(input.busy)return {kind:'disabled',pending:true,label:'Un momento…',reason:'Coco está terminando otra tarea. Podrás jugar en unos segundos.'};
    return {kind:'launch',label:'Jugar',reason:'Verifica los archivos y abre el juego.'};
  }
  if(input.localState==='unknown'||input.localState==='unmanaged')
    return {kind:'disabled',label:'Revisar instalación',reason:'La carpeta existente no es una instalación verificada por Coco. No se reemplazará.'};
  if(input.busy)return {kind:'disabled',pending:true,label:'Un momento…',reason:'Coco está terminando otra tarea. Podrás instalar en unos segundos.'};
  if(input.planStatus==='ready')return {kind:'install',label:'Instalar juego',reason:'Descarga y prepara archivos verificados con progreso y cancelación.'};
  if(input.planStatus)return {kind:'disabled',label:'Revisar disponibilidad',reason:input.planMessage||'La instalación no está lista para empezar.'};
  return {kind:'disabled',label:'Preparando instalación',reason:'Comprobando archivos y espacio disponible.'};
}
