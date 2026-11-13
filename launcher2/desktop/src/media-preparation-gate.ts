/** Protect tokenized media streams from stale async completions. A cancelled
 * native preparation remains single-flight until it actually settles; then
 * its exact loopback URL can be released without affecting a newer session. */
export type MediaPrepareTicket={id:number;experienceId:string;cancelled:boolean};

export class MediaPreparationGate {
  private sequence=0;
  private pending:MediaPrepareTicket|null=null;

  begin(experienceId:string):MediaPrepareTicket|null{
    if(this.pending)return null;
    const ticket={id:++this.sequence,experienceId,cancelled:false};
    this.pending=ticket;
    return ticket;
  }
  cancelIfChanged(experienceId:string|undefined){
    if(this.pending&&this.pending.experienceId!==experienceId)this.pending.cancelled=true;
  }
  cancel(){if(this.pending)this.pending.cancelled=true;}
  canDisplay(ticket:MediaPrepareTicket):boolean{
    return this.pending===ticket&&!ticket.cancelled;
  }
  finish(ticket:MediaPrepareTicket):boolean{
    if(this.pending!==ticket)return false;
    this.pending=null;
    return true;
  }
  busy(){return this.pending!==null;}
}
