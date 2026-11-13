/** Native filesystem mutations, recovery and launch must be single-flight
 * even within the same React event loop turn, before state updates commit.
 * Rust's own cross-process locks remain authoritative for disk safety. */
export type NativeOperationTicket={id:number;experienceId:string;kind:string};

export class NativeOperationGate {
  private serial=0;
  private active:NativeOperationTicket|null=null;
  private latest:NativeOperationTicket|null=null;

  begin(experienceId:string,kind:string):NativeOperationTicket|null{
    if(this.active||!experienceId||!kind)return null;
    const ticket={id:++this.serial,experienceId,kind};
    this.active=ticket;
    this.latest=ticket;
    return ticket;
  }
  finish(ticket:NativeOperationTicket):boolean{
    if(this.active!==ticket)return false;
    this.active=null;
    return true;
  }
  busy(){return this.active!==null;}
  /** Late read-only recovery checks cannot replace a later operation's state,
   * even if that later operation has already finished. */
  isLatest(ticket:NativeOperationTicket){return this.latest===ticket;}
  /** Verification progress is a separate event stream, matched to the exact
   * currently running verification. Other operations must never display it. */
  acceptsVerificationProgress(experienceId:string){
    return this.active?.kind==='verify'&&this.active.experienceId===experienceId;
  }
  acceptsProgress(experienceId:string){
    return this.active?.experienceId===experienceId&&[
      'install','prepare-repair','commit-repair','recover-repair','upgrade','recover-upgrade','move',
    ].includes(this.active.kind);
  }
}
