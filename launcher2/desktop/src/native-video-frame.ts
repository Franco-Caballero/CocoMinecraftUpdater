export type FrameImage=ImageData;
const HEADER=64,SLOT=1920*1080*4;

/** Contain: one dimension meets the viewport, neither exceeds it. */
export function fitVideoSize(width:number,height:number,availableWidth:number,availableHeight:number){
  if(![width,height,availableWidth,availableHeight].every(n=>Number.isFinite(n)&&n>0))return {width:1,height:1};
  const scale=Math.min(availableWidth/width,availableHeight/height);
  return {width:width*scale,height:height*scale};
}

/** Copy a complete, stable frame before painting. The decoder may publish
 * concurrently; an odd or changed sequence is retried next animation frame. */
export function paintSharedFrame(buffer:ArrayBuffer,lastSequence:number,previous:FrameImage|null){
  if(buffer.byteLength!==HEADER+2*SLOT)throw Error('Invalid shared frame mapping');
  const header=new DataView(buffer,0,HEADER);
  const sequence=header.getUint32(0,true);
  if(!sequence||sequence%2||sequence===lastSequence)return null;
  const slot=header.getUint32(4,true),width=header.getUint32(8,true),height=header.getUint32(12,true),stride=header.getUint32(16,true);
  if(slot>1||width<1||width>1920||height<1||height>1080||stride<width*4||stride%32||stride*height>SLOT)throw Error('Invalid decoded frame dimensions');
  const image=previous?.width===width&&previous.height===height?previous:new ImageData(width,height);
  const bytes=new Uint8ClampedArray(buffer,HEADER+slot*SLOT,stride*height);
  if(stride===width*4)image.data.set(bytes);
  else for(let row=0;row<height;row++)image.data.set(bytes.subarray(row*stride,row*stride+width*4),row*width*4);
  if(header.getUint32(0,true)!==sequence)return null;
  return {sequence,image};
}
