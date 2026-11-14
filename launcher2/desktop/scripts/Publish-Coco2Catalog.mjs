#!/usr/bin/env node
// Publishes the games added since the last Coco 2 Setup through the signed catalog channel,
// so every open launcher shows them within minutes, without a new Setup or a restart.
//
//   node scripts/Publish-Coco2Catalog.mjs --dry-run   builds, signs and checks; uploads nothing
//   node scripts/Publish-Coco2Catalog.mjs             also uploads and verifies what GitHub serves
//
// Source of truth: launcher/catalog.template.json (+ covers, previews, screenshots, online-fix).
// "New" means: a standalone game that channel-baseline.json (what the last Setup ships) does
// not contain, or contains at an older version. The signing key never touches the disk: it is
// unwrapped from the host's DPAPI vault in memory, used once and dropped.
import {readFile,writeFile,mkdir,rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {createHash,createPrivateKey,createPublicKey,scryptSync,sign,verify} from 'node:crypto';
import {tmpdir} from 'node:os';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import sharp from 'sharp';
import {toExperience,toInstallManifest} from './sync-catalog.mjs';

const scriptRoot=dirname(fileURLToPath(import.meta.url));
const desktopRoot=resolve(scriptRoot,'..');
const repoRoot=resolve(desktopRoot,'../..');
export const REPOSITORY='Franco-Caballero/CocoMinecraftUpdater';
export const TAG='coco2-channel';
export const CHANNEL_BASE=`https://github.com/${REPOSITORY}/releases/download/${TAG}/`;
export const HEAD_NAME='coco2-catalog-head.json';
export const bodyName=sequence=>`coco2-catalog-s${sequence}.json`;
const OWNED_ARCHIVE=new RegExp(`^https://github\\.com/${REPOSITORY.replace('/','\\/')}/releases/download/[^/?#]+/[^/?#]+\\.zip$`,'i');
const PREVIEW_HOSTS=['cdn.akamai.steamstatic.com','shared.akamai.steamstatic.com','video.akamai.steamstatic.com'];
const SHOT_HOSTS=['shared.akamai.steamstatic.com'];

const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
const sha512=bytes=>createHash('sha512').update(bytes).digest();

/** Dotted numeric versions only, as the client orders them. */
export function newerVersion(next,prior){
  const parse=value=>{
    if(!/^\d{1,18}(\.\d{1,18}){0,7}$/.test(String(value)))throw new Error(`La versión "${value}" no es numérica con puntos (p. ej. 1.2.0): el canal no puede ordenarla.`);
    return String(value).split('.').map(BigInt);
  };
  const a=parse(next),b=parse(prior);
  for(let i=0;i<Math.max(a.length,b.length);i++){
    const x=a[i]??0n,y=b[i]??0n;
    if(x!==y)return x>y;
  }
  return false;
}

/** Standalone games the last Setup does not ship (or ships older). */
export function channelCandidates(experiences,baseline){
  return experiences.filter(entry=>entry?.launch?.workflow==='coco-standalone').filter(entry=>{
    const shipped=baseline.games?.[entry.id];
    const version=String(entry.pack?.version||'');
    return shipped===undefined||(version!==shipped&&newerVersion(version,shipped));
  });
}

/** The same rules the client applies to a signed entry; a game that breaks one needs a Setup. */
export function channelProblems(experience,manifest){
  const problems=[];
  if(experience.launchArguments.length)problems.push('usa argumentos de lanzamiento');
  if(experience.hostingMode!=='p2p')problems.push('su hosting no es p2p');
  if(experience.instanceId!==experience.id)problems.push('instanceId distinto del id');
  if(!/^[a-z][a-z0-9-]{1,47}$/.test(experience.id)||experience.id.endsWith('-'))problems.push('id no válido para el canal');
  if(!experience.executable.toLowerCase().endsWith('.exe'))problems.push('el ejecutable no es .exe');
  if(!experience.requiredFiles.some(file=>file.path.toLowerCase()===experience.executable.toLowerCase()))problems.push('el ejecutable no está en requiredFiles');
  if(manifest.extraFiles.length)problems.push('declara files extra (experiences[].files)');
  if(manifest.archives.some(archive=>!OWNED_ARCHIVE.test(archive.url)))problems.push(`sus ZIP no están en releases de ${REPOSITORY}`);
  if(experience.description.length>10000)problems.push('descripción demasiado larga');
  return problems;
}

const steamUrl=(value,hosts,extensions)=>{
  try{
    const url=new URL(value);
    return value.length<=512&&url.protocol==='https:'&&!url.port&&!url.search&&!url.hash&&hosts.includes(url.hostname)
      &&extensions.some(ext=>url.pathname.toLowerCase().endsWith(ext));
  }catch{return false;}
};

/** Hover clip, gallery and Online-Fix data for a game, from the same files the Setup embeds. */
export function extrasFor(id,previews,screenshots,onlineFix){
  const extra={};
  const preview=previews[id];
  if(preview&&steamUrl(preview.url,PREVIEW_HOSTS,['.webm','.mp4'])){
    extra.preview={url:preview.url};
    for(const key of ['steamAppId','trailerId','bytes'])if(Number.isSafeInteger(preview[key])&&preview[key]>0)extra.preview[key]=preview[key];
  }
  // Steam appends a cache-buster (?t=…) that the client refuses; the image is the same without it.
  const listed=(screenshots[id]||[]).map(shot=>typeof shot==='string'?shot.replace(/\?t=\d+$/,''):shot);
  const shots=listed.filter(shot=>steamUrl(shot,SHOT_HOSTS,['.jpg','.jpeg','.png','.webp'])).slice(0,16);
  if(listed.length&&!shots.length)throw new Error(`game-screenshots.json: none of the screenshots of ${id} is a plain https://${SHOT_HOSTS[0]} image URL`);
  if(shots.length)extra.screenshots=shots;
  const fix=onlineFix.games?.[id];
  // The client parses realAppId as a JSON string; a number there makes it reject the whole channel.
  if(fix&&typeof fix.realAppId!=='string')throw new Error(`online-fix.json: realAppId of ${id} must be a string ("${fix.realAppId}")`);
  if(fix&&/^\d{1,12}$/.test(fix.realAppId)&&/^[0-9a-f]{128}$/i.test(fix.hash0)&&(!fix.hash1337||/^[0-9a-f]{128}$/i.test(fix.hash1337)))
    extra.onlineFix={realAppId:fix.realAppId,hash0:fix.hash0,hash1337:fix.hash1337||''};
  return extra;
}

export function channelPayload(sequence,entries,extras){
  return {schemaVersion:1,sequence,entries,extras};
}

// ── Signing ──────────────────────────────────────────────────────────────────────────────

/** libsodium's crypto_pwhash_scryptsalsa208sha256 parameter choice, as minisign uses it. */
export function scryptParams(opslimit,memlimit){
  let ops=BigInt(opslimit);const mem=BigInt(memlimit);
  if(ops<32768n)ops=32768n;
  const r=8n;let p,logN,maxN;
  const pick=()=>{for(logN=1n;logN<63n;logN++)if((1n<<logN)>maxN/2n)break;};
  if(ops<mem/32n){p=1n;maxN=ops/(r*4n);pick();}
  else{
    maxN=mem/(r*128n);pick();
    let maxrp=(ops/4n)/(1n<<logN);
    if(maxrp>0x3fffffffn)maxrp=0x3fffffffn;
    p=maxrp/r;
  }
  return {N:Number(1n<<logN),r:Number(r),p:Number(p)};
}

/** Tauri's private key: base64 of a minisign secret key ("rsign encrypted secret key"). */
export function decodeTauriSecretKey(tauriKey,password=''){
  const text=Buffer.from(String(tauriKey).trim(),'base64').toString('utf8');
  const line=text.split(/\r?\n/).find(value=>value&&!value.startsWith('untrusted comment:'));
  if(!line)throw new Error('Clave privada sin contenido minisign');
  const raw=Buffer.from(line.trim(),'base64');
  if(raw.length!==158||raw.subarray(0,2).toString()!=='Ed')throw new Error('Formato de clave minisign no soportado');
  const kdf=raw.subarray(2,4).toString();
  const salt=raw.subarray(6,38);
  const ops=raw.readBigUInt64LE(38),mem=raw.readBigUInt64LE(46);
  const keynum=Buffer.from(raw.subarray(54,158));
  if(kdf==='Sc'){
    const {N,r,p}=scryptParams(ops,mem);
    const stream=scryptSync(Buffer.from(password,'utf8'),salt,104,{N,r,p,maxmem:256*N*r+(32<<20)});
    for(let i=0;i<104;i++)keynum[i]^=stream[i];
    stream.fill(0);
  }else if(kdf!=='\0\0')throw new Error('KDF de clave desconocido');
  const keyId=Buffer.from(keynum.subarray(0,8));
  const secret=Buffer.from(keynum.subarray(8,72));
  keynum.fill(0);
  return {keyId,seed:secret.subarray(0,32),publicKey:secret.subarray(32,64)};
}

/** The raw Ed25519 key inside the updater's minisign public key in tauri.conf.json. */
export function updaterPublicKey(config){
  const text=Buffer.from(config.plugins.updater.pubkey,'base64').toString('utf8');
  const line=text.split(/\r?\n/).find(value=>value.startsWith('RW'));
  const raw=Buffer.from(line.trim(),'base64');
  if(raw.length!==42||raw.subarray(0,2).toString()!=='Ed')throw new Error('Clave pública del updater inválida');
  return {keyId:raw.subarray(2,10),publicKey:raw.subarray(10,42)};
}

const b64url=bytes=>Buffer.from(bytes).toString('base64url');
export const publicKeyObject=publicKey=>createPublicKey({key:{kty:'OKP',crv:'Ed25519',x:b64url(publicKey)},format:'jwk'});
export function ed25519Keys(seed,publicKey){
  return {
    privateKey:createPrivateKey({key:{kty:'OKP',crv:'Ed25519',d:b64url(seed),x:b64url(publicKey)},format:'jwk'}),
    publicKey:publicKeyObject(publicKey),
  };
}

function readHostKey(){
  // DPAPI (CurrentUser) with the same entropy Configure-Coco2Updater.ps1 used to store it.
  const script=[
    "$ErrorActionPreference='Stop'",
    'Add-Type -AssemblyName System.Security',
    "$path=Join-Path $env:LOCALAPPDATA 'CocoLauncher2\\signing\\private-key.dpapi'",
    "$entropy=[Text.Encoding]::UTF8.GetBytes('CocoLauncher2/Tauri2/signing/v1')",
    "$plain=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path),$entropy,'CurrentUser')",
    '[Console]::Out.Write([Text.Encoding]::UTF8.GetString($plain))',
    '[Array]::Clear($plain,0,$plain.Length)',
  ].join(';');
  const result=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],{encoding:'utf8',windowsHide:true,maxBuffer:65536});
  if(result.status!==0||!result.stdout.trim())throw new Error('No se pudo abrir la clave de firma del host (DPAPI). Solo funciona en el PC del anfitrión.');
  return result.stdout;
}

// ── GitHub ───────────────────────────────────────────────────────────────────────────────

async function fetchBytes(url){
  const response=await fetch(url,{redirect:'follow',cache:'no-store'});
  if(response.status===404)return null;
  if(!response.ok)throw new Error(`${url}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}
async function archiveServed(archive){
  const response=await fetch(archive.url,{method:'HEAD',redirect:'follow'});
  const length=Number(response.headers.get('content-length'));
  if(!response.ok||length!==archive.size)throw new Error(`El ZIP ${archive.url} no está publicado con ${archive.size} bytes (HTTP ${response.status}, ${length||'?'} bytes).`);
}
function gh(args){
  const result=spawnSync('gh',args,{encoding:'utf8',windowsHide:true});
  if(result.status!==0)throw new Error(`gh ${args.join(' ')}: ${(result.stderr||result.stdout).trim()}`);
  return result.stdout;
}

async function coverDataUrl(imagePath){
  const source=resolve(repoRoot,imagePath);
  const webp=await sharp(source).rotate().resize({width:1200,height:800,fit:'inside',withoutEnlargement:true}).webp({quality:78,effort:4}).toBuffer();
  if(webp.length>3_500_000)throw new Error(`Portada demasiado grande: ${imagePath}`);
  return `data:image/webp;base64,${webp.toString('base64')}`;
}

export async function main(argv=process.argv.slice(2)){
  const dryRun=argv.includes('--dry-run')||argv.includes('--baseline')||argv.includes('--sequence');
  const outIndex=argv.indexOf('--out');
  const template=JSON.parse(await readFile(resolve(repoRoot,'launcher/catalog.template.json'),'utf8'));
  const baselineIndex=argv.indexOf('--baseline');
  const baseline=JSON.parse(await readFile(baselineIndex>=0?resolve(argv[baselineIndex+1]):resolve(desktopRoot,'channel-baseline.json'),'utf8'));
  const sequenceIndex=argv.indexOf('--sequence');
  const previews=JSON.parse(await readFile(resolve(desktopRoot,'src/game-hover-previews.json'),'utf8'));
  const screenshots=JSON.parse(await readFile(resolve(desktopRoot,'src/game-screenshots.json'),'utf8'));
  const onlineFix=JSON.parse(await readFile(resolve(desktopRoot,'src-tauri/resources/online-fix.json'),'utf8'));
  const config=JSON.parse(await readFile(resolve(desktopRoot,'src-tauri/tauri.conf.json'),'utf8'));

  const candidates=channelCandidates(template.experiences||[],baseline);
  const entries=[],extras={},blocked=[],noMedia=[];
  for(const source of candidates){
    const experience=toExperience(source);
    const manifest=toInstallManifest(source);
    const problems=channelProblems(experience,manifest);
    if(problems.length){blocked.push(`${source.id}: ${problems.join(', ')}`);continue;}
    entries.push({source:'remote',version:manifest.version,
      entry:{...experience,image:await coverDataUrl(source.ui.imagePath)},manifest});
    const extra=extrasFor(source.id,previews,screenshots,onlineFix);
    if(Object.keys(extra).length)extras[source.id]=extra;
    const missing=[!extra.preview&&'clip (src/game-hover-previews.json)',!extra.screenshots&&'capturas (src/game-screenshots.json)'].filter(Boolean);
    if(missing.length)noMedia.push(`${source.id}: falta ${missing.join(' y ')}`);
  }
  if(noMedia.length)console.warn(`AVISO: falta la tarjeta completa (paso «Tarjeta completa» de AGENT_ADD_GAME.md):\n  ${noMedia.join('\n  ')}`);
  if(blocked.length)throw new Error(`Estos juegos no pueden ir por el canal y necesitan un Setup nuevo:\n  ${blocked.join('\n  ')}`);
  if(entries.length>100)throw new Error('El canal admite hasta 100 juegos: publica un Setup nuevo para incorporarlos de fábrica.');
  for(const entry of entries)for(const archive of entry.manifest.archives)await archiveServed(archive);

  const headBytes=await fetchBytes(CHANNEL_BASE+HEAD_NAME);
  const head=headBytes?JSON.parse(headBytes.toString('utf8')):null;
  if(head){
    const published=await fetchBytes(CHANNEL_BASE+bodyName(head.sequence));
    if(published&&sha256(published)===head.sha256){
      const current=JSON.parse(published.toString('utf8'));
      const servedSig=await fetchBytes(`${CHANNEL_BASE}${bodyName(head.sequence)}.sig`);
      const trusted=servedSig&&verify(null,published,publicKeyObject(updaterPublicKey(config).publicKey),Buffer.from(servedSig.toString('utf8').trim(),'base64'));
      if(trusted&&JSON.stringify({entries:current.entries,extras:current.extras})===JSON.stringify({entries,extras})){
        console.log(JSON.stringify({status:'unchanged',sequence:head.sequence,games:entries.map(e=>e.entry.id)},null,2));
        return;
      }
    }
  }
  const sequence=sequenceIndex>=0?Number(argv[sequenceIndex+1]):(head?.sequence||0)+1;
  if(!Number.isSafeInteger(sequence)||sequence<1)throw new Error('Secuencia inválida');
  const body=Buffer.from(JSON.stringify(channelPayload(sequence,entries,extras)),'utf8');
  if(body.length>32*1024*1024)throw new Error('El catálogo firmado supera 32 MiB');

  const expected=updaterPublicKey(config);
  const secret=decodeTauriSecretKey(readHostKey());
  if(!secret.publicKey.equals(expected.publicKey)||!secret.keyId.equals(expected.keyId))throw new Error('La clave del host no corresponde a la clave pública del updater. No se firma.');
  const keys=ed25519Keys(secret.seed,secret.publicKey);
  secret.seed.fill(0);
  const signature=sign(null,body,keys.privateKey);
  if(!verify(null,body,publicKeyObject(expected.publicKey),signature))throw new Error('La firma no verifica con la clave pública del updater');
  const sigText=signature.toString('base64');
  const headJson=JSON.stringify({schemaVersion:1,sequence,sha256:sha256(body)});

  const work=outIndex>=0?resolve(argv[outIndex+1]):join(tmpdir(),`coco2-catalog-${sequence}-${process.pid}`);
  await mkdir(work,{recursive:true});
  const files={body:join(work,bodyName(sequence)),sig:join(work,`${bodyName(sequence)}.sig`),head:join(work,HEAD_NAME)};
  await writeFile(files.body,body);await writeFile(files.sig,sigText);await writeFile(files.head,headJson);
  const summary={status:dryRun?'dry-run':'published',sequence,sha256:sha256(body),bytes:body.length,games:entries.map(e=>`${e.entry.id} ${e.version}`),extras:Object.keys(extras),files:outIndex>=0?files:undefined};
  try{
    if(dryRun){console.log(JSON.stringify(summary,null,2));return summary;}
    // Body and signature first, under names nobody reads yet; the head last switches clients over.
    gh(['release','upload',TAG,'-R',REPOSITORY,files.body,files.sig]);
    gh(['release','upload',TAG,'-R',REPOSITORY,files.head,'--clobber']);
    let served=null;
    // A replaced asset can answer 404 on its plain URL for a few minutes (seen: ~3 min) while
    // GitHub settles; clients simply stay on the previous catalog meanwhile.
    for(let attempt=0;attempt<30;attempt++){
      const servedHead=await fetchBytes(CHANNEL_BASE+HEAD_NAME);
      if(servedHead&&servedHead.toString('utf8')===headJson){served=servedHead;break;}
      await new Promise(done=>setTimeout(done,10_000));
    }
    if(!served)throw new Error('GitHub aún no sirve el head nuevo tras 5 minutos: vuelve a ejecutar el script; si responde unchanged, ya está publicado.');
    const servedBody=await fetchBytes(CHANNEL_BASE+bodyName(sequence));
    const servedSig=await fetchBytes(`${CHANNEL_BASE}${bodyName(sequence)}.sig`);
    if(!servedBody||sha256(servedBody)!==sha256(body))throw new Error('GitHub sirve otro catálogo');
    if(!servedSig||!verify(null,servedBody,publicKeyObject(expected.publicKey),Buffer.from(servedSig.toString('utf8').trim(),'base64')))throw new Error('La firma servida no verifica');
    const latest=gh(['release','view','-R',REPOSITORY,'--json','tagName','-q','.tagName']).trim();
    if(latest===TAG)throw new Error(`ATENCIÓN: ${TAG} quedó como Latest; eso rompe a Coco 1.`);
    console.log(JSON.stringify(summary,null,2));
    return summary;
  }finally{
    if(outIndex<0)await rm(work,{recursive:true,force:true});
  }
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  main().catch(error=>{console.error(error.message||error);process.exitCode=1;});
}
