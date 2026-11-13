/** Native Rust reports real bytes, sometimes every 0.1% of multi-GiB ZIP
 * extraction. Keep the first and final updates and every phase transition,
 * without forcing a whole React catalog render on each native event. */
export type NativeProgress={id:string;phase:string;file:string;downloadedBytes:number;totalBytes:number;percent:number};
export class NativeProgressSampler {
  private previous:NativeProgress|null=null;
  private previousAt=Number.NEGATIVE_INFINITY;
  constructor(private readonly minIntervalMs=90){}

  accept(event:NativeProgress,nowMs:number):boolean{
    if(!event||typeof event.id!=='string'||!event.id||typeof event.phase!=='string'||!event.phase||
      !Number.isSafeInteger(event.downloadedBytes)||!Number.isSafeInteger(event.totalBytes)||
      event.downloadedBytes<0||event.totalBytes<0||event.downloadedBytes>event.totalBytes||
      !Number.isInteger(event.percent)||event.percent<0||event.percent>100||
      !Number.isFinite(nowMs))return false;
    const previous=this.previous;
    // A ZIP may contain thousands of tiny entries with different file names.
    // The UI never displays a private path, so a new filename alone must NOT
    // bypass the rate limit or force another entire catalog render.
    const newStep=!previous||previous.id!==event.id||previous.phase!==event.phase;
    // Every Rust phase reports cumulative bytes, even if the ZIP entry
    // filename changes. A late callback for a prior file must never make the
    // progress bar jump backwards or displace a newer total.
    if(!newStep&&(
      event.downloadedBytes<previous.downloadedBytes||
      event.percent<previous.percent||
      // Once the native phase has declared a known total, an asynchronous
      // callback from another cursor/revision must not quietly rewrite it.
      // Unknown (0) -> known is a legitimate metadata arrival.
      (previous.totalBytes>0&&event.totalBytes!==previous.totalBytes)
    ))return false;
    if(!newStep&&event.downloadedBytes===previous.downloadedBytes&&event.percent===previous.percent&&
      event.file===previous.file)return false;
    const completed=event.totalBytes>0&&event.downloadedBytes===event.totalBytes||event.percent===100;
    if(!newStep&&!completed&&nowMs-this.previousAt<this.minIntervalMs)return false;
    this.previous={...event};this.previousAt=nowMs;
    return true;
  }

  reset(){this.previous=null;this.previousAt=Number.NEGATIVE_INFINITY;}
}

export function nativeProgressDescription(phase:string):string{
  switch(phase){
    case 'downloading':case 'repair-downloading':case 'upgrade-downloading':return 'Descargando archivos';
    case 'moving':return 'Copiando y comprobando archivos';
    case 'extracting':return 'Descomprimiendo juego';
    case 'repair-extracting':return 'Descomprimiendo reparación';
    case 'upgrade-extracting':return 'Descomprimiendo actualización';
    case 'verifying':case 'repair-verifying':case 'upgrade-verifying':return 'Verificando archivos';
    case 'repair-committing':return 'Aplicando reparación protegida';
    case 'upgrade-committing':return 'Aplicando versión nueva';
    case 'repair-recovered':case 'upgrade-recovered':return 'Recuperación completada';
    case 'cancelled':return 'Cancelación atendida';
    case 'failed':return 'Operación interrumpida';
    default:return 'Preparando archivos';
  }
}
