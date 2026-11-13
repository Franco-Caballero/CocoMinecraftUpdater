/** A delayed native child-process event is not an instruction to overwrite the
 * current game. In particular, an exit from the previous PID after a fast
 * relaunch must never erase a running or still-verifying new process. */
export type RuntimeProcessEvent={
  id:string;
  state:'verifying'|'running'|'exited';
  pid:number|null;
  exitCode:number|null;
};

export function reconcileRuntimeEvent<T extends RuntimeProcessEvent>(
  current:T|null,incoming:T,
):T|null{
  if(!incoming||!incoming.id)return current;
  if(!current){
    // A background exit is not evidence of a currently tracked game, and
    // should not create an unsolicited toast or hide a library operation.
    return incoming.state==='exited'?null:incoming;
  }
  if(current.state==='verifying'){
    if(incoming.state==='exited'||incoming.id!==current.id)return current;
  }
  if(current.state==='running'&&incoming.state==='exited'){
    if(incoming.id!==current.id)return current;
    // A missing PID may represent a restored child/process observation; it
    // cannot safely be paired with an asynchronous exit signal.
    if(current.pid===null||incoming.pid===null||current.pid!==incoming.pid)return current;
  }
  return incoming;
}
