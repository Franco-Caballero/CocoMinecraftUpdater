/** Frontend-only fencing for native offline media downloads. Rust remains the
 * authority for file locking, cancellation, resume and SHA verification. This
 * gate prevents same-tick duplicate clicks and stale cross-episode progress. */
export type MediaDownloadTicket={sequence:number;id:string;episodeId:string};
export type MediaDownloadNativeProgress={
  id:string;episodeId:string;phase:string;downloadedBytes:number;totalBytes:number;percent:number;
};

export class NativeMediaDownloadGate{
  private serial=0;
  private active:MediaDownloadTicket|null=null;
  private latest:MediaDownloadTicket|null=null;
  private cancellationRequested=false;
  private lastProgress:MediaDownloadNativeProgress|null=null;
  private lastProgressAt=Number.NEGATIVE_INFINITY;

  begin(id:string,episodeId:string):MediaDownloadTicket|null{
    if(this.active||typeof id!=='string'||typeof episodeId!=='string'||!id||!episodeId||
      id.length>128||episodeId.length>128)return null;
    const ticket={sequence:++this.serial,id,episodeId};
    this.active=ticket;this.latest=ticket;this.cancellationRequested=false;
    this.lastProgress=null;this.lastProgressAt=Number.NEGATIVE_INFINITY;
    return ticket;
  }
  busy(){return this.active!==null;}
  isLatest(ticket:MediaDownloadTicket){return this.latest===ticket;}
  current(){return this.active;}
  finish(ticket:MediaDownloadTicket):boolean{
    if(this.active!==ticket)return false;
    this.active=null;this.cancellationRequested=false;
    this.lastProgress=null;return true;
  }
  requestCancel():MediaDownloadTicket|null{
    if(!this.active||this.cancellationRequested)return null;
    this.cancellationRequested=true;return this.active;
  }
  cancellationFailed(ticket:MediaDownloadTicket){
    if(this.active===ticket)this.cancellationRequested=false;
  }
  acceptProgress(event:MediaDownloadNativeProgress,atMs:number):boolean{
    const active=this.active;
    if(!active||!event||event.id!==active.id||event.episodeId!==active.episodeId||
      typeof event.phase!=='string'||!event.phase||event.phase.length>64||
      !Number.isSafeInteger(event.downloadedBytes)||!Number.isSafeInteger(event.totalBytes)||
      event.downloadedBytes<0||event.totalBytes<0||event.downloadedBytes>event.totalBytes||
      !Number.isInteger(event.percent)||event.percent<0||event.percent>100||
      !Number.isFinite(atMs))return false;
    const previous=this.lastProgress;
    const newPhase=!previous||previous.phase!==event.phase;
    if(!newPhase&&(event.totalBytes!==previous.totalBytes||
      event.downloadedBytes<previous.downloadedBytes||event.percent<previous.percent))return false;
    if(!newPhase&&event.downloadedBytes===previous.downloadedBytes&&event.percent===previous.percent)return false;
    const terminal=event.percent===100||event.phase==='cancelled'||event.phase==='failed'||event.phase==='complete';
    if(!newPhase&&!terminal&&atMs-this.lastProgressAt<90)return false;
    this.lastProgress={...event};this.lastProgressAt=atMs;
    return true;
  }
}
