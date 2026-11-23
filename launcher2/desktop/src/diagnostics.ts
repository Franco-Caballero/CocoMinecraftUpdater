import { invoke as nativeInvoke, type InvokeArgs } from '@tauri-apps/api/core';

/** Operations worth a line in the log even when they work, so a failure has its context. */
const MILESTONES=new Set(['install_standalone','upgrade_standalone','launch_standalone','uninstall_standalone',
  'move_installation','commit_standalone_repair','prepare_windows','ensure_defender_exclusions','repair_zerotier']);
const QUIET=new Set(['log_event','get_diagnostic_report','copy_diagnostic_file']);

const describe=(args?:InvokeArgs)=>{
  const id=args&&typeof args==='object'&&!Array.isArray(args)&&'id' in args?String((args as Record<string,unknown>).id):'';
  return id?` ${id}`:'';
};

export function logEvent(area:string,message:string){
  void nativeInvoke('log_event',{area,message}).catch(()=>{});
}

/** Same as Tauri's invoke, but every failure lands in Coco's log with the command that failed. */
export async function invoke<T>(command:string,args?:InvokeArgs):Promise<T>{
  if(MILESTONES.has(command))logEvent('op',`→ ${command}${describe(args)}`);
  try{
    const result=await nativeInvoke<T>(command,args);
    if(MILESTONES.has(command)){
      const status=result&&typeof result==='object'&&'status' in (result as object)?` (${String((result as unknown as {status:unknown}).status)})`:'';
      logEvent('op',`✓ ${command}${describe(args)}${status}`);
    }
    return result;
  }catch(error){
    if(!QUIET.has(command))logEvent('error',`✗ ${command}${describe(args)}: ${String(error)}`);
    throw error;
  }
}

let installed=false;
/** Errors that never reach a handler would otherwise vanish on a friend's PC. */
export function captureUnexpectedErrors(){
  if(installed)return;
  installed=true;
  window.addEventListener('error',event=>logEvent('crash',`${event.message} @ ${event.filename}:${event.lineno}`));
  window.addEventListener('unhandledrejection',event=>logEvent('crash',`promesa sin manejar: ${String(event.reason)}`));
}

/** Saves the full report as coco-diagnostico.txt and puts that file on the clipboard,
 * to paste in the chat as an attachment. `copied` is false when Windows refused the clipboard. */
export async function copyDiagnosticReport(extra:string[]):Promise<{path:string,copied:boolean}>{
  return nativeInvoke<{path:string,copied:boolean}>('copy_diagnostic_file',{extra});
}
