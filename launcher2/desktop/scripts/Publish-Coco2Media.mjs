#!/usr/bin/env node
// Publishes every movie and series of the catalog through their own signed channel, so a new
// episode or film reaches every open Coco (0.6.76 or later) within minutes, without a Setup.
//
//   node scripts/Publish-Coco2Media.mjs --dry-run   builds, signs and checks; uploads nothing
//   node scripts/Publish-Coco2Media.mjs             also uploads and verifies what GitHub serves
//
// Separate from the games channel on purpose: Coco versions before 0.6.76 reject a games
// channel holding anything but games, and never read these file names.
// Source of truth: launcher/catalog.template.json (episodes, subtitles, covers). Upload each
// video and subtitle file to its prerelease first; this script checks that GitHub serves them.
// The signing key is unwrapped from the host's DPAPI vault in memory, used once and dropped.
import {readFile,writeFile,mkdir,rm} from 'node:fs/promises';
import {createHash,sign,verify} from 'node:crypto';
import {tmpdir} from 'node:os';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {REPOSITORY,TAG,CHANNEL_BASE,coverDataUrl,decodeTauriSecretKey,ed25519Keys,fetchBytes,gh,publicKeyObject,readHostKey,updaterPublicKey} from './Publish-Coco2Catalog.mjs';
import {toExperience,toMediaManifest} from './sync-catalog.mjs';

const desktopRoot=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const repoRoot=resolve(desktopRoot,'../..');
export const MEDIA_HEAD='coco2-media-head.json';
export const mediaBodyName=sequence=>`coco2-media-s${sequence}.json`;
const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');

/** Every coco-media entry, as the public card plus its private manifest. */
export function mediaRecords(experiences,cover){
  return Promise.all(experiences.filter(entry=>entry?.launch?.workflow==='coco-media').map(async source=>{
    if(!/^[a-z][a-z0-9-]{1,47}$/.test(source.id))throw new Error(`Id de medio no apto para el canal: ${source.id}`);
    // Coco 0.6.76 requires instanceId to equal id on this channel; a title has no install folder.
    return {entry:{...toExperience(source),instanceId:source.id,image:await cover(source.ui.imagePath)},manifest:toMediaManifest(source)};
  }));
}

export const mediaPayload=(sequence,media)=>({schemaVersion:1,sequence,media});

/** A HEAD on every video part and subtitle file: the size GitHub serves must be the catalog's. */
async function served(url,size){
  const response=await fetch(url,{method:'HEAD',redirect:'follow'});
  const length=Number(response.headers.get('content-length'));
  if(!response.ok||length!==size)throw new Error(`GitHub no sirve ${url} con ${size} bytes (HTTP ${response.status}, ${length})`);
}

export async function main(argv=process.argv.slice(2)){
  const dryRun=argv.includes('--dry-run');
  const template=JSON.parse(await readFile(resolve(repoRoot,'launcher/catalog.template.json'),'utf8'));
  const config=JSON.parse(await readFile(resolve(desktopRoot,'src-tauri/tauri.conf.json'),'utf8'));
  const media=await mediaRecords(template.experiences||[],coverDataUrl);
  if(!media.length)throw new Error('No hay películas ni series en el catálogo');
  if(media.length>128)throw new Error('El canal de medios admite hasta 128 títulos');
  for(const {manifest} of media)for(const episode of manifest.episodes){
    const parts=episode.parts??[{url:episode.streamUrl,size:episode.size}];
    for(const part of parts)await served(part.url,part.size);
    for(const track of episode.subtitles??[])await served(track.url,track.size);
  }

  const headBytes=await fetchBytes(CHANNEL_BASE+MEDIA_HEAD);
  const head=headBytes?JSON.parse(headBytes.toString('utf8')):null;
  const expected=updaterPublicKey(config);
  if(head){
    const published=await fetchBytes(CHANNEL_BASE+mediaBodyName(head.sequence));
    const servedSig=published&&await fetchBytes(`${CHANNEL_BASE}${mediaBodyName(head.sequence)}.sig`);
    if(published&&sha256(published)===head.sha256&&servedSig
      &&verify(null,published,publicKeyObject(expected.publicKey),Buffer.from(servedSig.toString('utf8').trim(),'base64'))
      &&JSON.stringify(JSON.parse(published.toString('utf8')).media)===JSON.stringify(media)){
      console.log(JSON.stringify({status:'unchanged',sequence:head.sequence,media:media.map(m=>`${m.entry.id} (${m.manifest.episodes.length})`)},null,2));
      return;
    }
  }
  const sequence=(head?.sequence||0)+1;
  const body=Buffer.from(JSON.stringify(mediaPayload(sequence,media)),'utf8');
  if(body.length>16*1024*1024)throw new Error('El canal de medios supera 16 MiB');
  const secret=decodeTauriSecretKey(readHostKey());
  if(!secret.publicKey.equals(expected.publicKey)||!secret.keyId.equals(expected.keyId))throw new Error('La clave del host no corresponde a la clave pública del updater. No se firma.');
  const keys=ed25519Keys(secret.seed,secret.publicKey);
  secret.seed.fill(0);
  const signature=sign(null,body,keys.privateKey);
  if(!verify(null,body,publicKeyObject(expected.publicKey),signature))throw new Error('La firma no verifica con la clave pública del updater');
  const headJson=JSON.stringify({schemaVersion:1,sequence,sha256:sha256(body)});
  const work=join(tmpdir(),`coco2-media-${sequence}-${process.pid}`);
  await mkdir(work,{recursive:true});
  const files={body:join(work,mediaBodyName(sequence)),sig:join(work,`${mediaBodyName(sequence)}.sig`),head:join(work,MEDIA_HEAD)};
  await writeFile(files.body,body);await writeFile(files.sig,signature.toString('base64'));await writeFile(files.head,headJson);
  const summary={status:dryRun?'dry-run':'published',sequence,sha256:sha256(body),bytes:body.length,
    media:media.map(m=>`${m.entry.id} (${m.manifest.episodes.length})`)};
  try{
    if(dryRun){console.log(JSON.stringify(summary,null,2));return summary;}
    // Body and signature first, under names nobody reads yet; the head last switches clients over.
    gh(['release','upload',TAG,'-R',REPOSITORY,files.body,files.sig]);
    gh(['release','upload',TAG,'-R',REPOSITORY,files.head,'--clobber']);
    let ok=false;
    for(let attempt=0;attempt<30&&!ok;attempt++){
      const servedHead=await fetchBytes(CHANNEL_BASE+MEDIA_HEAD);
      ok=Boolean(servedHead&&servedHead.toString('utf8')===headJson);
      if(!ok)await new Promise(done=>setTimeout(done,10_000));
    }
    if(!ok)throw new Error('GitHub aún no sirve el head nuevo tras 5 minutos: vuelve a ejecutar el script; si responde unchanged, ya está publicado.');
    const servedBody=await fetchBytes(CHANNEL_BASE+mediaBodyName(sequence));
    const servedSig=await fetchBytes(`${CHANNEL_BASE}${mediaBodyName(sequence)}.sig`);
    if(!servedBody||sha256(servedBody)!==sha256(body))throw new Error('GitHub sirve otro canal de medios');
    if(!servedSig||!verify(null,servedBody,publicKeyObject(expected.publicKey),Buffer.from(servedSig.toString('utf8').trim(),'base64')))throw new Error('La firma servida no verifica');
    const latest=gh(['release','view','-R',REPOSITORY,'--json','tagName','-q','.tagName']).trim();
    if(latest===TAG)throw new Error(`ATENCIÓN: ${TAG} quedó como Latest; eso rompe a Coco 1.`);
    console.log(JSON.stringify(summary,null,2));
    return summary;
  }finally{
    await rm(work,{recursive:true,force:true});
  }
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  main().catch(error=>{console.error(error.message||error);process.exitCode=1;});
}
