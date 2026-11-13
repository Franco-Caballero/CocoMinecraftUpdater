/** Windows Explorer may send a package while React's native event listener is
 * still installing (or fail to install one). The authoritative native queue
 * must therefore be drained independently of event subscription success.
 *
 * A focus event arriving DURING an async read used to be dropped, potentially
 * leaving a package invisible until the next focus. This single-flight pump
 * remembers follow-up signals and makes up to four bounded passes per burst.
 * If the last pass overlaps another delivery, a deferred bounded drain is
 * scheduled: a busy Explorer surge must not strand its last package until
 * somebody manually focuses the window again.
 * It does not poll, import, install, execute, or trust a path. */
export class PackageActivationDrain<T=unknown>{
  private running:Promise<void>|null=null;
  private rerun=false;
  private disposed=false;
  private followup:ReturnType<typeof setTimeout>|null=null;

  constructor(
    private readonly readNative:()=>Promise<T>,
    private readonly presentForReview:(value:T)=>void,
    private readonly onError:(error:unknown)=>void,
    private readonly maxPasses=4,
    private readonly acknowledgeNative?:(value:T)=>Promise<void>,
  ){}

  trigger():Promise<void>{
    if(this.disposed)return Promise.resolve();
    if(this.running){this.rerun=true;return this.running;}
    if(this.followup!==null){clearTimeout(this.followup);this.followup=null;}
    const task=(async()=>{
      let pass=0;
      do{
        this.rerun=false;
        try{
          const pending=await this.readNative();
          if(!this.disposed){
            // An RPC snapshot is NOT an acknowledgement. Let React first
            // latch the paths synchronously; only then release the native
            // FIFO prefix. A stale response after unmount has no ACK and can
            // be recovered by the next mounted subscriber.
            this.presentForReview(pending);
            if(!this.disposed&&this.acknowledgeNative)
              await this.acknowledgeNative(pending);
          }
        }catch(error){
          if(!this.disposed)this.onError(error);
        }
        pass++;
      }while(!this.disposed&&this.rerun&&pass<this.maxPasses);
    })();
    this.running=task;
    // A focus event can arrive between the last read and this finalizer;
    // inspect rerun here, not solely in the bounded loop condition. Defer
    // rather than spin to avoid saturating native IPC on an event storm.
    void task.then(()=>{},()=>{}).finally(()=>{
      if(this.running!==task)return;
      this.running=null;
      if(this.rerun&&!this.disposed){
        this.rerun=false;
        this.followup=setTimeout(()=>{
          this.followup=null;
          if(!this.disposed)void this.trigger();
        },30);
      }
    });
    return task;
  }

  dispose(){
    this.disposed=true;this.rerun=false;
    if(this.followup!==null){clearTimeout(this.followup);this.followup=null;}
  }
}

/** The first-run "Open package" button is an explicit human intent, not a
 * persisted auto-import flag. Consume each increasing request exactly once,
 * even when React StrictMode runs effects twice. */
export class ManualPackagePickerGate{
  private last=0;
  consume(request:number):boolean{
    if(!Number.isSafeInteger(request)||request<=this.last||request<=0)return false;
    this.last=request;return true;
  }
}
