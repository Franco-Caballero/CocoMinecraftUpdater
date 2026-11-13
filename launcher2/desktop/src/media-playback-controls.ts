/** Pure input helpers. Never translate an unknown duration to Infinity/NaN or
 * hijack typing/button activation in the playback dialog. */
export function seekRelative(current:number,duration:number,seconds:number):number|null{
  if(!Number.isFinite(current)||current<0||!Number.isFinite(duration)||duration<=0||!Number.isFinite(seconds))return null;
  return Math.max(0,Math.min(Math.max(0,duration-.05),current+seconds));
}

/** Keep a viewer's position only for a fresh token for the same episode.
 * Seek after the new video's metadata confirms a finite duration: a stale
 * 90-minute position must not poison a shorter revised stream. */
export function resumeMediaPosition(previous:number,duration:number):number|null{
  if(!Number.isFinite(previous)||previous<1||!Number.isFinite(duration)||duration<=1)return null;
  return Math.max(0,Math.min(previous,Math.max(0,duration-0.15)));
}

const PLAYBACK_KEYS=new Set([' ','k','K','j','J','l','L','ArrowLeft','ArrowRight','ArrowUp','ArrowDown',
  'm','M','f','F','n','N','?','0','1','2','3','4','5','6','7','8','9']);
/** Keys a focused button already answers by itself: handling them too would act twice. */
const BUTTON_KEYS=new Set([' ','Enter']);

export function shouldHandlePlaybackKey(key:string,target:EventTarget|null,withModifier=false):boolean{
  if(withModifier||!PLAYBACK_KEYS.has(key))return false;
  const element=target as Element|null;
  const tag=element?.tagName?.toLowerCase();
  if(tag==='input'||tag==='textarea'||tag==='select'||element?.hasAttribute?.('contenteditable'))return false;
  // The player's own buttons keep focus after a click; arrows and letters still drive playback.
  if(tag==='button')return !BUTTON_KEYS.has(key);
  // Native video controls use their own key handling; avoid two seeks for a
  // single ArrowRight when focus is inside the WebView's native control tree.
  if(tag==='video')return false;
  return true;
}

/** Volume steps for ArrowUp/ArrowDown, kept inside 0..1 and rounded so 0.1 steps stay exact. */
export function stepVolume(current:number,delta:number){
  const base=Number.isFinite(current)?current:1;
  return Math.round(Math.max(0,Math.min(1,base+delta))*20)/20;
}

/** The speeds a viewer actually uses, in the order the button cycles through them. */
export const PLAYBACK_RATES=[1,1.25,1.5,2,0.75] as const;
export function nextPlaybackRate(current:number){
  const index=PLAYBACK_RATES.findIndex(rate=>Math.abs(rate-current)<.01);
  return PLAYBACK_RATES[(index+1)%PLAYBACK_RATES.length];
}
