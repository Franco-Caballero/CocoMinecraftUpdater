/** The Win32 read-only process inventory can corroborate a native launch
 * after the response was lost, but cannot prove the request failed. No command
 * here retries launch, trusts error strings, reads user paths or starts games. */
export type LaunchProcessReport={status:string;safeToUpdate:boolean;gameIds:readonly string[]};
export function reconcileLaunchObservation(
  report:LaunchProcessReport|null,targetId:string
):'running'|'absent'|'unknown'{
  if(!report||!targetId||!Array.isArray(report.gameIds)||report.status==='unknown')return 'unknown';
  if(report.gameIds.includes(targetId))return 'running';
  return report.status==='none'&&report.safeToUpdate===true&&report.gameIds.length===0
    ?'absent':'unknown';
}
