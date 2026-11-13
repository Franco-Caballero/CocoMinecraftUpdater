/** A media access URL is a short-lived capability, not an evergreen replay
 * address. Retry may request a *new* native token, but a late response after
 * closing the player must be revoked, never displayed. */
export type RefreshTicket={id:number;session:number;cancelled:boolean};

export class MediaSessionRefreshGate {
  private serial=0;
  private pending:RefreshTicket|null=null;

  begin(session:number):RefreshTicket|null{
    if(this.pending||!Number.isSafeInteger(session)||session<0)return null;
    const ticket={id:++this.serial,session,cancelled:false};
    this.pending=ticket;
    return ticket;
  }
  cancel(){if(this.pending)this.pending.cancelled=true;}
  /** A new playback session must not be blocked forever by a stalled native
   * token renewal from the previous, now-closed player. Drop UI ownership only;
   * the old promise still resolves into its caller, which revokes that exact
   * stale loopback capability instead of displaying it. Same-session retries
   * remain single-flight. */
  supersedeSession(session:number):boolean{
    if(!Number.isSafeInteger(session)||session<0||!this.pending||this.pending.session===session)
      return false;
    this.pending.cancelled=true;
    this.pending=null;
    return true;
  }
  canUse(ticket:RefreshTicket,currentSession:number){
    return this.pending===ticket&&!ticket.cancelled&&ticket.session===currentSession;
  }
  finish(ticket:RefreshTicket){
    if(this.pending!==ticket)return false;
    this.pending=null;
    return true;
  }
  busy(){return this.pending!==null;}
}
