export type FrameImage=ImageData;
const HEADER=64,SLOT=1920*1080*4;
export const FRAME_BYTES=HEADER+2*SLOT;
/** One published frame. `yuv`: I420 planes (luma, then two half-size chroma planes); otherwise RGBA. */
export type FrameHeader={sequence:number;width:number;height:number;stride:number;yuv:boolean;chromaStride:number;offset:number};

/** Contain: one dimension meets the viewport, neither exceeds it. */
export function fitVideoSize(width:number,height:number,availableWidth:number,availableHeight:number){
  if(![width,height,availableWidth,availableHeight].every(n=>Number.isFinite(n)&&n>0))return {width:1,height:1};
  const scale=Math.min(availableWidth/width,availableHeight/height);
  return {width:width*scale,height:height*scale};
}

export const frameSequence=(buffer:ArrayBuffer)=>new DataView(buffer,0,4).getUint32(0,true);

/** The newest complete frame, or null while the decoder is publishing or nothing changed.
 * An odd sequence means a frame is being written; it is retried next animation frame. */
export function readFrameHeader(buffer:ArrayBuffer,lastSequence:number):FrameHeader|null{
  if(buffer.byteLength!==FRAME_BYTES)throw Error('Invalid shared frame mapping');
  const header=new DataView(buffer,0,HEADER);
  const sequence=header.getUint32(0,true);
  if(!sequence||sequence%2||sequence===lastSequence)return null;
  const slot=header.getUint32(4,true),width=header.getUint32(8,true),height=header.getUint32(12,true),stride=header.getUint32(16,true);
  const yuv=header.getUint32(20,true)===1,chromaStride=header.getUint32(24,true);
  const valid=slot<=1&&width>=1&&width<=1920&&height>=1&&height<=1080&&stride%32===0&&(yuv
    ?width%2===0&&height%2===0&&stride>=width&&chromaStride>=width/2&&chromaStride%32===0&&stride*height+chromaStride*height<=SLOT
    :stride>=width*4&&stride*height<=SLOT);
  if(!valid)throw Error('Invalid decoded frame dimensions');
  return {sequence,width,height,stride,yuv,chromaStride,offset:HEADER+slot*SLOT};
}

/** Copy a complete, stable RGBA frame before painting. The decoder may publish
 * concurrently; an odd or changed sequence is retried next animation frame. */
export function paintSharedFrame(buffer:ArrayBuffer,lastSequence:number,previous:FrameImage|null){
  const frame=readFrameHeader(buffer,lastSequence);
  if(!frame)return null;
  if(frame.yuv)throw Error('Invalid decoded frame dimensions');
  const {sequence,width,height,stride}=frame;
  const image=previous?.width===width&&previous.height===height?previous:new ImageData(width,height);
  const bytes=new Uint8ClampedArray(buffer,frame.offset,stride*height);
  if(stride===width*4)image.data.set(bytes);
  else for(let row=0;row<height;row++)image.data.set(bytes.subarray(row*stride,row*stride+width*4),row*width*4);
  if(frameSequence(buffer)!==sequence)return null;
  return {sequence,image};
}
