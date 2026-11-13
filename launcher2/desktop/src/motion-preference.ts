/** Keeps explicit player motion preferences, otherwise follows Windows
 * reduced-motion changes live. No background media work is required to honor
 * a new OS accessibility preference; the preview pool is toggled by React. */
export type MotionPreference='system'|'on'|'off';
export function parseMotionPreference(value:unknown):MotionPreference{
  return value==='on'||value==='off'||value==='system'?value:'system';
}
export function motionEnabled(choice:MotionPreference,reduced:boolean):boolean{
  return choice==='on'?true:choice==='off'?false:!reduced;
}
export function toggleMotionPreference(enabled:boolean):MotionPreference{
  return enabled?'off':'on';
}
