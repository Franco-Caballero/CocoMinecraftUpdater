/** Keep keyboard Tab within a detail dialog while it is modal. Only changes
 * focus at the boundary; normal Tab through controls stays browser-native. */
export function trapDialogTab(container:HTMLElement,active:Element|null,reverse:boolean):boolean{
  const controls=Array.from(container.querySelectorAll<HTMLElement>(
    'button:not(:disabled),a[href],input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]',
  )).filter(element=>element.getClientRects().length>0);
  if(!controls.length){container.focus();return true;}
  const first=controls[0],last=controls[controls.length-1];
  if(active===container){(reverse?last:first).focus();return true;}
  if(reverse&&active===first){last.focus();return true;}
  if(!reverse&&active===last){first.focus();return true;}
  if(!active||!container.contains(active)){
    (reverse?last:first).focus();return true;
  }
  return false;
}
