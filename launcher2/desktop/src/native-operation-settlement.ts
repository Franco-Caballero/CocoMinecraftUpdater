/** A native commit may be complete even when an optional read-only UI
 * refresh fails (offline device, unmounted volume, stale catalog channel).
 * Never turn a successful install/upgrade/recovery into a false failed write.
 * Run independent refreshes in order so an earlier catalog refresh cannot
 * clear a newer plan written by the next step. */
export async function refreshAfterConfirmedWrite(
  steps:ReadonlyArray<()=>Promise<unknown>>,
):Promise<{failed:number;completed:number}>{
  let failed=0;
  for(const step of steps){
    try{await step();}catch{failed++;}
  }
  return {failed,completed:steps.length-failed};
}

export function confirmedOperationMessage(message:string,failedRefreshes:number):string{
  if(!failedRefreshes)return message;
  const confirmed=message.trim().replace(/[.!\s]+$/,'')||'Operación completada';
  return `${confirmed}. Los cambios ya están guardados, pero no se pudo actualizar toda la pantalla. Vuelve a abrir la ficha para comprobar su estado.`;
}
