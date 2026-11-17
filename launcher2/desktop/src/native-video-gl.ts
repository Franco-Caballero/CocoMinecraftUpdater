import type {FrameHeader} from './native-video-frame';

/** Draws the decoder's I420 planes with the graphics card: colour conversion and
 * scaling cost the processor nothing, and each frame is 1.5 bytes per pixel, not 4. */
/** `onLost` is replaceable: a remounted player reuses the canvas's renderer and takes over the warning. */
export type YuvRenderer={draw:(buffer:ArrayBuffer,frame:FrameHeader)=>void;dispose:()=>void;onLost:()=>void};
const renderers=new WeakMap<HTMLCanvasElement,YuvRenderer>();

/** A canvas keeps one WebGL context for life: a second getContext returns the same one, and
 * once it has been released it can never draw again. Remounts (React, «Reintentar») reuse it. */
export function yuvRendererFor(canvas:HTMLCanvasElement,onLost:()=>void):YuvRenderer|'unavailable'|{broken:string}{
  const known=renderers.get(canvas);
  if(known){known.onLost=onLost;return known;}
  const made=createYuvRenderer(canvas,onLost);
  if(typeof made==='object'&&'draw' in made)renderers.set(canvas,made);
  return made;
}

const VERTEX=`attribute vec2 aPosition;varying vec2 vUv;
void main(){vUv=vec2((aPosition.x+1.0)*0.5,(1.0-aPosition.y)*0.5);gl_Position=vec4(aPosition,0.0,1.0);}`;
// Limited-range YUV to RGB. HD video is BT.709; anything smaller is BT.601.
const FRAGMENT=`precision highp float;varying vec2 vUv;
uniform sampler2D uY;uniform sampler2D uU;uniform sampler2D uV;uniform vec4 uEdges;uniform float uHd;
void main(){
  vec2 luma=vec2(min(vUv.x*uEdges.x,uEdges.y),vUv.y);
  vec2 chroma=vec2(min(vUv.x*uEdges.z,uEdges.w),vUv.y);
  float y=1.16438*(texture2D(uY,luma).r-0.0627451);
  float u=texture2D(uU,chroma).r-0.5019608;
  float v=texture2D(uV,chroma).r-0.5019608;
  vec3 hd=vec3(y+1.79274*v,y-0.21325*u-0.53291*v,y+2.11240*u);
  vec3 sd=vec3(y+1.59603*v,y-0.39176*u-0.81297*v,y+2.01723*u);
  gl_FragColor=vec4(mix(sd,hd,uHd),1.0);
}`;

/** 'unavailable': this PC has no usable WebGL and the canvas is untouched (a 2D context still works).
 * `{broken}`: a context exists but cannot draw (the reason is for the log); the canvas has to be replaced. */
export function createYuvRenderer(canvas:HTMLCanvasElement,onLost:()=>void):YuvRenderer|'unavailable'|{broken:string}{
  const options={alpha:false,antialias:false,depth:false,stencil:false,premultipliedAlpha:false,preserveDrawingBuffer:false,
    powerPreference:'high-performance' as const,failIfMajorPerformanceCaveat:true,desynchronized:true};
  let gl:WebGLRenderingContext|null=null;
  try{gl=(canvas.getContext('webgl2',options)??canvas.getContext('webgl',options)) as WebGLRenderingContext|null;}catch{gl=null;}
  if(!gl)return 'unavailable';
  const context=gl;
  try{
    const shader=(type:number,source:string)=>{
      const value=context.createShader(type);if(!value)throw Error('shader');
      context.shaderSource(value,source);context.compileShader(value);
      if(!context.getShaderParameter(value,context.COMPILE_STATUS))throw Error(context.getShaderInfoLog(value)||'shader');
      return value;
    };
    const program=context.createProgram();if(!program)throw Error('program');
    context.attachShader(program,shader(context.VERTEX_SHADER,VERTEX));context.attachShader(program,shader(context.FRAGMENT_SHADER,FRAGMENT));
    context.linkProgram(program);
    if(!context.getProgramParameter(program,context.LINK_STATUS))throw Error(context.getProgramInfoLog(program)||'program');
    context.useProgram(program);
    const quad=context.createBuffer();context.bindBuffer(context.ARRAY_BUFFER,quad);
    context.bufferData(context.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),context.STATIC_DRAW);
    const position=context.getAttribLocation(program,'aPosition');
    context.enableVertexAttribArray(position);context.vertexAttribPointer(position,2,context.FLOAT,false,0,0);
    const textures=['uY','uU','uV'].map((name,unit)=>{
      const texture=context.createTexture();if(!texture)throw Error('texture');
      context.activeTexture(context.TEXTURE0+unit);context.bindTexture(context.TEXTURE_2D,texture);
      for(const [key,value]of [[context.TEXTURE_MIN_FILTER,context.LINEAR],[context.TEXTURE_MAG_FILTER,context.LINEAR],
        [context.TEXTURE_WRAP_S,context.CLAMP_TO_EDGE],[context.TEXTURE_WRAP_T,context.CLAMP_TO_EDGE]])context.texParameteri(context.TEXTURE_2D,key,value);
      context.uniform1i(context.getUniformLocation(program,name),unit);
      return texture;
    });
    const edges=context.getUniformLocation(program,'uEdges'),hd=context.getUniformLocation(program,'uHd');
    context.pixelStorei(context.UNPACK_ALIGNMENT,1);
    const lost=(event:Event)=>{event.preventDefault();renderer.onLost();};
    canvas.addEventListener('webglcontextlost',lost);
    let allocated='';
    const renderer:YuvRenderer={
      onLost,
      draw(buffer,frame){
        const {width,height,stride,chromaStride,offset}=frame,half=height>>1,luma=stride*height,chroma=chromaStride*half;
        // Rows are padded to the stride: the texture holds the padding and the shader stops at the last real pixel.
        const planes:Array<[number,number,number,number]>=[[offset,stride,height,luma],[offset+luma,chromaStride,half,chroma],[offset+luma+chroma,chromaStride,half,chroma]];
        const layout=`${stride}x${height}/${chromaStride}`;
        planes.forEach(([start,columns,rows,bytes],unit)=>{
          const pixels=new Uint8Array(buffer,start,bytes);
          context.activeTexture(context.TEXTURE0+unit);context.bindTexture(context.TEXTURE_2D,textures[unit]);
          if(layout===allocated)context.texSubImage2D(context.TEXTURE_2D,0,0,0,columns,rows,context.LUMINANCE,context.UNSIGNED_BYTE,pixels);
          else context.texImage2D(context.TEXTURE_2D,0,context.LUMINANCE,columns,rows,0,context.LUMINANCE,context.UNSIGNED_BYTE,pixels);
        });
        allocated=layout;
        context.viewport(0,0,width,height);
        context.uniform4f(edges,width/stride,(width-.5)/stride,(width/2)/chromaStride,(width/2-.5)/chromaStride);
        context.uniform1f(hd,height>576||width>1024?1:0);
        context.drawArrays(context.TRIANGLE_STRIP,0,4);
      },
      /** Stops drawing; the context stays with the canvas for the next mount and goes away with it. */
      dispose(){renderer.onLost=()=>{};},
    };
    return renderer;
  }catch(error){return {broken:error instanceof Error?error.message:String(error)};}
}
