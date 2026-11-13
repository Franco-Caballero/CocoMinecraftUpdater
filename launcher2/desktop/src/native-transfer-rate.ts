import type {NativeProgress} from './native-progress-sampler';

export type NativeTransferRate={bytesPerSecond:number;remainingSeconds:number|null};

/** Observe native bytes while acquiring archive data, never ZIP extraction/hash
 * counters. Archive acquisition can reuse verified cache, so this is a rate
 * of file preparation rather than a claim about physical network throughput.
 * Reset across stale IDs, phase resets and long pauses/hidden sessions. */
export class NativeTransferRateMeter{
  private from:NativeProgress|null=null;
  private fromAt=0;
  private speed:number|null=null;

  reset(){this.from=null;this.fromAt=0;this.speed=null;}
  observe(event:NativeProgress,nowMs:number):NativeTransferRate|null{
    if(!event||!Number.isFinite(nowMs)||!event.phase.endsWith('downloading')||
      !Number.isSafeInteger(event.downloadedBytes)||!Number.isSafeInteger(event.totalBytes)||
      event.totalBytes<=0||event.downloadedBytes<0||event.downloadedBytes>event.totalBytes){
      this.reset();return null;
    }
    if(!this.from||this.from.id!==event.id||this.from.phase!==event.phase||
      event.totalBytes!==this.from.totalBytes||event.downloadedBytes<this.from.downloadedBytes||
      nowMs<=this.fromAt){
      this.from={...event};this.fromAt=nowMs;this.speed=null;return null;
    }
    const deltaMs=nowMs-this.fromAt;
    const deltaBytes=event.downloadedBytes-this.from.downloadedBytes;
    if(deltaMs>=12000){
      this.from={...event};this.fromAt=nowMs;this.speed=null;return null;
    }
    if(deltaMs>=400&&deltaBytes>0){
      const measured=deltaBytes*1000/deltaMs;
      this.speed=this.speed===null?measured:this.speed*0.6+measured*0.4;
      this.from={...event};this.fromAt=nowMs;
    }
    if(event.downloadedBytes===event.totalBytes)return null;
    if(this.speed===null||this.speed<1024)return null;
    const remaining=(event.totalBytes-event.downloadedBytes)/this.speed;
    return {bytesPerSecond:Math.round(this.speed),
      remainingSeconds:Number.isFinite(remaining)&&remaining>=0&&remaining<=7*86400?Math.ceil(remaining):null};
  }
}

/** Compact form for the status panel: "14.1 MB/s · 16 s". */
export function nativeTransferRateCompact(rate:NativeTransferRate|null):string{
  if(!rate||!Number.isFinite(rate.bytesPerSecond)||rate.bytesPerSecond<1024)return '';
  const speed=rate.bytesPerSecond>=1048576
    ?`${(rate.bytesPerSecond/1048576).toFixed(1)} MB/s`
    :`${(rate.bytesPerSecond/1024).toFixed(0)} KB/s`;
  if(rate.remainingSeconds===null||rate.remainingSeconds>3600)return speed;
  if(rate.remainingSeconds>=60)return `${speed} · ${Math.ceil(rate.remainingSeconds/60)} min`;
  return `${speed} · ${Math.max(1,rate.remainingSeconds)} s`;
}

export function nativeTransferRateText(rate:NativeTransferRate|null):string{
  if(!rate||!Number.isFinite(rate.bytesPerSecond)||rate.bytesPerSecond<1024)return '';
  const speed=rate.bytesPerSecond>=1048576
    ?`${(rate.bytesPerSecond/1048576).toFixed(1)} MB/s`
    :`${(rate.bytesPerSecond/1024).toFixed(0)} KB/s`;
  if(rate.remainingSeconds===null||rate.remainingSeconds>3600)return `${speed} de avance`;
  if(rate.remainingSeconds>=60)return `${speed} de avance · aprox. ${Math.ceil(rate.remainingSeconds/60)} min`;
  return `${speed} de avance · aprox. ${Math.max(1,rate.remainingSeconds)} s`;
}
