/** Keep the page behind a modal fixed while its own content remains scrollable.
 * The exact inline styles are restored when the last owning modal is gone.
 * Scrollbar compensation avoids a sideways jump in the game/card grid. */
export function lockBackgroundScroll(doc:Document, win:Window):()=>void{
  const root=doc.documentElement;
  const previousOverflow=root.style.overflow;
  const previousPadding=root.style.paddingRight;
  const scrollbarWidth=Math.max(0,win.innerWidth-root.clientWidth);
  if(scrollbarWidth>0){
    const computed=parseFloat(win.getComputedStyle(root).paddingRight);
    const original=Number.isFinite(computed)?computed:0;
    root.style.paddingRight=`${original+scrollbarWidth}px`;
  }
  root.style.overflow='hidden';
  return ()=>{
    root.style.overflow=previousOverflow;
    root.style.paddingRight=previousPadding;
  };
}
