/** A focus event is an opportunity for read-only reconciliation, never for
 * automatically repairing/installing an interrupted game. Suppress the burst
 * of focus+visibility events Win32/WebView2 emits during window activation. */
export class ForegroundRecoveryGate {
  private serial=0;
  private pending:number|null=null;
  private lastCheck=Number.NEGATIVE_INFINITY;
  constructor(private readonly intervalMs=4000){}

  begin(now:number):number|null{
    if(!Number.isFinite(now)||this.pending!==null||now-this.lastCheck<this.intervalMs)return null;
    this.lastCheck=now;
    const ticket=++this.serial;
    this.pending=ticket;
    return ticket;
  }
  isCurrent(ticket:number){return ticket===this.pending;}
  finish(ticket:number){if(this.pending!==ticket)return false;this.pending=null;return true;}
  cancel(){this.pending=null;this.serial++;}
  // A completed write/rollback deserves a fresh read even when the user
  // activates the window inside the debounce interval.
  allowImmediateRetry(){this.lastCheck=Number.NEGATIVE_INFINITY;}
}
