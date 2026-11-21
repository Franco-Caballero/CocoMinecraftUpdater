#!/usr/bin/env node
// Copies every text subtitle track out of a film (the video file is only read, never changed)
// and prints the `subtitles` entries for launcher/catalog.template.json.
//
//   node scripts/Extract-CocoSubtitles.mjs <video> <outDir> --release-base <https://github.com/.../releases/download/<tag>/> [--name <asset base>]
//
// ASS/SSA and SRT are copied byte for byte; WebVTT and MP4 text become SRT. Picture subtitles
// (PGS, VobSub) cannot be drawn by Coco and are reported as skipped. Upload the files to the
// film's own prerelease with exactly the printed names, then paste the JSON into the episode.
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdirSync,readFileSync} from 'node:fs';
import {basename,extname,join,resolve} from 'node:path';

const [video,outDir,...rest]=process.argv.slice(2);
const option=name=>{const at=rest.indexOf(name);return at>=0?rest[at+1]:undefined;};
const releaseBase=option('--release-base');
if(!video||!outDir||!releaseBase||!/^https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/download\/[^/]+\/$/.test(releaseBase)){
  console.error('Uso: node scripts/Extract-CocoSubtitles.mjs <video> <carpeta> --release-base https://github.com/<owner>/<repo>/releases/download/<tag>/ [--name <base>]');
  process.exit(2);
}
const name=(option('--name')||basename(video,extname(video))).replace(/[^A-Za-z0-9.-]+/g,'.').replace(/\.{2,}/g,'.').replace(/^\.|\.$/g,'');
const run=(command,args)=>{
  const result=spawnSync(command,args,{encoding:'buffer',maxBuffer:64*1024*1024});
  if(result.status!==0)throw Error(`${command} falló: ${result.stderr?.toString()||result.error}`);
  return result.stdout;
};
const probe=JSON.parse(run('ffprobe',['-v','error','-select_streams','s','-show_entries','stream=index,codec_name:stream_tags=language,title:stream_disposition=default,forced','-of','json',resolve(video)]).toString());
mkdirSync(outDir,{recursive:true});
const formats={ass:['ass','ass','copy'],ssa:['ssa','ass','copy'],subrip:['srt','srt','copy'],webvtt:['srt','srt','srt'],mov_text:['srt','srt','srt']};
const tracks=[],skipped=[],ids=new Set();
(probe.streams||[]).forEach((stream,order)=>{
  const format=formats[stream.codec_name];
  if(!format){skipped.push(`#${order} ${stream.codec_name} (imagen, Coco no puede dibujarla)`);return;}
  const [kind,muxer,codec]=format;
  const language=String(stream.tags?.language||'').replace(/[^A-Za-z0-9_-]/g,'').slice(0,35);
  const label=String(stream.tags?.title||'').trim().slice(0,80)||language||`Pista ${order+1}`;
  let id=(language||`s${order+1}`).toLowerCase().replace(/[^a-z0-9_-]/g,'')||`s${order+1}`;
  while(ids.has(id))id=`${id}-${order+1}`;ids.add(id);
  const file=`${name}.${order+1}.${id}.${kind}`;
  const target=join(outDir,file);
  run('ffmpeg',['-v','error','-y','-i',resolve(video),'-map',`0:${stream.index}`,'-c:s',codec,'-f',muxer,target]);
  const bytes=readFileSync(target);
  tracks.push({id,label,language,format:kind,url:releaseBase+file,size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),
    ...(stream.disposition?.default?{default:true}:{}),...(stream.disposition?.forced?{forced:true}:{})});
});
if(skipped.length)console.error(`Omitidas: ${skipped.join(', ')}`);
console.log(JSON.stringify(tracks,null,2));
