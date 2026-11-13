#!/usr/bin/env node
/** Agent-only CLI: inspect a LICENSED local ZIP, infer a single executable,
 * create an immutable draft with a neutral cover if needed, optionally apply
 * after documented source/rights review. NO publishing, games, HKCU or network.
 * This is developer automation, never a launcher runtime dependency. */
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {readFile,mkdtemp,stat,unlink,rmdir} from 'node:fs/promises';
import {basename,dirname,isAbsolute,join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import sharp from 'sharp';

const SCRIPT_ROOT=dirname(fileURLToPath(import.meta.url));
const REPO_ROOT=resolve(SCRIPT_ROOT,'../../..');
const INSPECT=resolve(SCRIPT_ROOT,'Inspect-Coco2AgentGame.ps1');
const NEW=resolve(SCRIPT_ROOT,'New-CocoStandaloneCandidate.ps1');
const APPLY=resolve(SCRIPT_ROOT,'Apply-CocoStandaloneDraft.ps1');

export function slugFromTitle(title){
  const normalized=title.normalize('NFKD').replace(/\p{M}/gu,'');
  const slug=normalized.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'').slice(0,48).replace(/-+$/,'');
  return /^[a-z][a-z0-9-]{0,46}[a-z0-9]$/.test(slug)?slug:null;
}

export function parseArgs(args){
  const valid=new Set(['zip','name','version','archive-url','id','executable','cover','rights-evidence']);
  const result={prepare:false,apply:false,help:false};
  for(let i=0;i<args.length;i++){
    const arg=args[i];
    if(arg==='--help'){if(result.help)throw Error('Argumento duplicado: --help');result.help=true;continue;}
    if(arg==='--prepare'){if(result.prepare)throw Error('Argumento duplicado: --prepare');result.prepare=true;continue;}
    if(arg==='--apply'){if(result.apply)throw Error('Argumento duplicado: --apply');result.apply=true;result.prepare=true;continue;}
    if(!arg.startsWith('--')||!valid.has(arg.slice(2))||i+1>=args.length)
      throw Error(`Argumento no reconocido o sin valor: ${arg}`);
    const name=arg.slice(2);
    if(Object.hasOwn(result,name))throw Error(`Argumento duplicado: --${name}`);
    result[name]=args[++i];
  }
  return result;
}

function powershell(script,args){
  const p=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,...args],
    {cwd:REPO_ROOT,encoding:'utf8',maxBuffer:1024*1024*4,windowsHide:true});
  if(p.error)throw p.error;
  if(p.status!==0)throw Error(`${basename(script)}: ${p.stderr||p.stdout||`exit ${p.status}`}`);
  return p.stdout.trim();
}

function escapeXml(value){
  return value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[ch]));
}
export async function neutralCover(title,path){
  const safe=escapeXml(title.slice(0,64));
  const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="960" height="540" viewBox="0 0 960 540">
  <defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="#20102f"/><stop offset="1" stop-color="#3c1a57"/></linearGradient></defs>
  <rect width="960" height="540" fill="url(#g)"/><circle cx="870" cy="90" r="245" fill="#9855d0" opacity="0.13"/>
  <rect x="56" y="64" width="92" height="8" rx="4" fill="#bd79ff"/>
  <text x="56" y="132" fill="#bd79ff" font-family="Arial,sans-serif" font-size="24" font-weight="bold">COCO // JUEGO DEL HOST</text>
  <text x="56" y="290" fill="white" font-family="Arial,sans-serif" font-size="48" font-weight="bold">${safe}</text>
  <text x="56" y="476" fill="#dbcee7" font-family="Arial,sans-serif" font-size="21">Portada neutral provisional · Sin arte oficial</text></svg>`;
  await sharp(Buffer.from(svg)).png().toFile(path);
}

export async function run(input){
  if(input.help){
    console.log('Uso: node scripts/QuickAdd-Coco2Agent.mjs --name "Juego" --zip "C:\\...\\Juego.zip" [--prepare --version 1.0.0 --archive-url https://sitio-autorizado/archivo.zip] [--executable Game.exe] [--cover portada.png] [--apply --rights-evidence "licencia verificada"]');
    console.log('Guía: launcher2/docs/AGENT_ADD_GAME.md. Default: SOLO inspección. --prepare: draft. --apply: cambia fuente aprobada, NO publica.');
    return {status:'help'};
  }
  if(typeof input.zip!=='string'||!isAbsolute(input.zip)||!input.zip.toLowerCase().endsWith('.zip'))
    throw Error('Se necesita --zip absoluto de una distribución autorizada.');
  if(typeof input.name!=='string'||!input.name.trim()||input.name.length>120)
    throw Error('Se necesita --name del juego autorizado.');
  const id=input.id||slugFromTitle(input.name);
  if(!id||!/^[a-z][a-z0-9-]{0,46}[a-z0-9]$/.test(id))
    throw Error('No se pudo derivar --id seguro. Especifica un ID ASCII de 2-48 caracteres.');
  const inspection=JSON.parse(powershell(INSPECT,['-ZipPath',input.zip,'-Name',input.name]));
  if(inspection.status!=='inspection-only-untrusted'||inspection.issues?.length)
    throw Error(`El ZIP necesita revisión: ${JSON.stringify(inspection.issues)}`);
  const executable=input.executable||inspection.uniqueExecutableSuggestion;
  const result={status:'inspected-only',id,name:input.name,zip:inspection.source,zipBytes:inspection.zipBytes,
    executableCandidates:inspection.executableCandidates,executable:executable||null,
    coverCandidates:inspection.coverCandidates,shaDeferred:true,inspectionMs:inspection.elapsedMs,
    published:false,approvedForClients:false};
  if(!input.prepare){console.log(JSON.stringify(result,null,2));return result;}
  if(!executable||!inspection.executableCandidates.includes(executable))
    throw Error(`ZIP no tiene un único ejecutable confirmado; el agente debe elegir --executable entre ${inspection.executableCandidates.join(', ')}`);
  if(!input.version||!input['archive-url'])throw Error('--prepare requiere --version y --archive-url HTTPS real, aunque sea futura y aun NO publicada.');
  if(input.apply&&(!input['rights-evidence']||input['rights-evidence'].trim().length<12))
    throw Error('--apply exige --rights-evidence verificable. No basta afirmar derechos.');
  const original=await stat(input.zip);if(!original.isFile())throw Error('ZIP no es un archivo regular');
  let neutralDir=null;
  try {
    let cover=input.cover;
    if(!cover){
      neutralDir=await mkdtemp(join(tmpdir(),'coco2-agent-cover-v1-'));
      cover=join(neutralDir,'cover.png');
      await neutralCover(input.name,cover);
    }
    const created=powershell(NEW,['-ZipPath',input.zip,'-Id',id,'-Name',input.name,
      '-Version',input.version,'-ArchiveUrl',input['archive-url'],'-CoverPath',cover,
      '-Executable',executable]);
    result.status='draft-only';result.draft=join(REPO_ROOT,'launcher2','drafts',id);
    result.note=created.split(/\r?\n/).slice(0,5).join(' | ');
    result.provisionalCover=!input.cover;
    // Dry-run validates staged metadata; no source mutation, publication or
    // user installations. The full source change still requires explicit
    // verified rights, a stable source catalog, and a second SHA check.
    const dry=powershell(APPLY,['-DraftId',id,'-SourceZipPath',input.zip]);
    result.dryRun=dry.includes('DRY-RUN:');
    if(!result.dryRun)throw Error('Catalog dry-run was not confirmed; leave draft for inspection');
    if(input.apply){
      const catalog=await readFile(join(REPO_ROOT,'launcher','catalog.template.json'));
      const expectedSha=createHash('sha256').update(catalog).digest('hex');
      const applied=powershell(APPLY,['-DraftId',id,'-SourceZipPath',input.zip,
        '-Apply','-ApproveReviewedLicenseRights','-ExpectedCatalogSha256',expectedSha]);
      if(!applied.includes('APLICADO:'))throw Error('Catalog source update not confirmed');
      result.status='host-source-integrated';result.catalogShaBefore=expectedSha;
      result.published=false;result.approvedForClients=false;
    }
    console.log(JSON.stringify(result,null,2));return result;
  } finally {
    if(neutralDir){
      // Only one known test/agent-generated image, never broad recursive rm.
      await unlink(join(neutralDir,'cover.png')).catch(error=>{if(error.code!=='ENOENT')throw error});
      await rmdir(neutralDir).catch(error=>{if(error.code!=='ENOENT')throw error});
    }
  }
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{await run(parseArgs(process.argv.slice(2)));}catch(error){console.error(String(error));process.exitCode=1;}
}
