/** Native Tauri updater emits many small chunks. Aggregate every byte while
 * throttling React writes, keep unknown totals honest and never interpret a
 * finished *download* as a finished Windows installer. */
export type UpdaterChunkEvent=
  |{event:'Started';data:{contentLength?:number|null}}
  |{event:'Progress';data:{chunkLength:number}}
  |{event:'Finished';data?:unknown};
export type UpdaterTransfer={downloaded:number;total:number;percent:number;message:string};

export class AppUpdaterProgressMeter{
  private started=false;
  private finished=false;
  private total=0;
  private downloaded=0;
  private previousDisplayAt=Number.NEGATIVE_INFINITY;
  private displayed=-1;

  consume(event:UpdaterChunkEvent,atMs:number):UpdaterTransfer|null{
    if(!event||!Number.isFinite(atMs)||this.finished)return null;
    let important=false;
    if(event.event==='Started'){
      if(this.started)return null;
      this.started=true;
      const reported=event.data?.contentLength;
      this.total=typeof reported==='number'&&Number.isSafeInteger(reported)&&reported>0?reported:0;
      important=true;
    }else if(event.event==='Progress'){
      const bytes=event.data?.chunkLength;
      if(!Number.isSafeInteger(bytes)||bytes<=0)return null;
      this.started=true;
      this.downloaded=Math.min(Number.MAX_SAFE_INTEGER,this.downloaded+bytes);
    }else if(event.event==='Finished'){
      this.finished=true;important=true;
    }else return null;
    // Do not show a misleading 100% merely because the plugin's approximate
    // contentLength was reached; only Finished confirms end of the transfer.
    const percent=this.finished?100:this.total>0?Math.min(99,Math.floor(this.downloaded/this.total*100)):0;
    if(!important&&atMs-this.previousDisplayAt<120)return null;
    if(!important&&percent===this.displayed&&this.total>0&&atMs-this.previousDisplayAt<600)return null;
    this.previousDisplayAt=atMs;this.displayed=percent;
    return {downloaded:this.downloaded,total:this.total,percent,
      message:this.finished?'Transferencia terminada; comprobando juegos…':'Descargando actualización…'};
  }
  snapshot(){return {downloaded:this.downloaded,total:this.total,percent:this.finished?100:this.total?Math.min(99,Math.floor(this.downloaded/this.total*100)):0};}
}
