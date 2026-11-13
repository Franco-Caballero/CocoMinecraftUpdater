import { readFile, mkdir, writeFile, copyFile, stat, unlink } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, relative, sep } from 'node:path';
import sharp from 'sharp';

const scriptRoot = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptRoot, '../../..');
const desktopRoot = resolve(scriptRoot, '..');
const experiencesRoot = resolve(repoRoot, 'assets/experiences');
const coverRoot = resolve(desktopRoot, 'public/covers');
const catalogPath = resolve(repoRoot, 'launcher/catalog.template.json');

export function toExperience(entry) {
  const image = String(entry?.ui?.imagePath || '');
  if (!/^assets\/experiences\/[a-zA-Z0-9._-]+\.(png|jpe?g|webp)$/.test(image)) {
    throw new Error(`Invalid experience cover for ${entry?.id || '(missing id)'}: ${image}`);
  }
  if (!/^[a-z0-9][a-z0-9-]*$/.test(entry?.id || '') || !entry?.name || !entry?.launch?.workflow) {
    throw new Error(`Invalid experience metadata: ${entry?.id || '(missing id)'}`);
  }
  const requiredFiles = (entry.runtime?.requiredFiles || []).map(file => {
    const path = String(file.path || '');
    if (!path || path.includes('\\') || path.split('/').some(segment => !segment || segment === '.' || segment === '..' || segment.includes(':')) || path.startsWith('/')) {
      throw new Error(`Invalid required file path: ${entry.id}`);
    }
    const sha256 = String(file.sha256 || '').toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(sha256) || !Number.isSafeInteger(file.size) || file.size < 0) {
      throw new Error(`Invalid required file digest/size: ${entry.id}/${path}`);
    }
    return {path, sha256, size: file.size};
  });
  const executable = String(entry.runtime?.executable || '');
  if (executable && (executable.includes('\\') || executable.split('/').some(part=>!part || part==='.' || part==='..'||part.includes(':')) || executable.startsWith('/'))) {
    throw new Error(`Invalid runtime executable: ${entry.id}`);
  }
  const launchArguments = entry.launch?.arguments ?? entry.runtime?.arguments ?? [];
  if (!Array.isArray(launchArguments) || launchArguments.some(arg=>typeof arg !== 'string' || arg.length>512)) {
    throw new Error(`Invalid runtime arguments: ${entry.id}`);
  }
  return {
    id: entry.id,
    instanceId: entry.instanceId || entry.id,
    name: entry.name,
    image: `/covers/${image.split('/').at(-1)}.webp`,
    description: entry.description || '',
    workflow: entry.launch.workflow,
    minecraftVersion: entry.runtime?.minecraftVersion || '',
    loader: entry.runtime?.loader || '',
    requiredFiles,
    executable,
    launchArguments,
    hostingMode: entry.hosting?.mode || '',
  };
}

export function toInstallManifest(entry) {
  if (entry?.launch?.workflow !== 'coco-standalone') return null;
  const basic = toExperience(entry);
  const archives = (entry.pack?.archives || []).map((item, index) => {
    const url=String(item.archiveUrl||'');
    const sha256=String(item.sha256||'').toLowerCase();
    if (!url.startsWith('https://') || !/^https:\/\/[^\s@/#?]+(?:\/[^\s]*)?$/.test(url) || !/^[a-f0-9]{64}$/.test(sha256) || !Number.isSafeInteger(item.size) || item.size<=0) {
      throw new Error(`Unsafe archive metadata: ${entry.id}/${index}`);
    }
    return {url,sha256,size:item.size};
  });
  if (!archives.length || !basic.requiredFiles.length || basic.hostingMode!=='p2p') throw new Error(`Standalone incomplete manifest: ${entry.id}`);
  const version=String(entry.pack?.version||'');
  if (!version || version.length>100) throw new Error(`Standalone missing version: ${entry.id}`);
  return {
    id:basic.id,
    instanceId:basic.instanceId,
    workflow:basic.workflow,
    version,
    archives,
    requiredFiles:basic.requiredFiles,
    extraFiles:(entry.files||[]).map(item=>({path:item.path||'',sourceUrl:item.sourceUrl||'',size:item.size??null,sha256:item.sha256||'',role:item.role||'all',policy:item.policy||'replace'})),
  };
}

export function toSessionConfig(source) {
  const discovery=source.sessionDiscovery||{};
  const host=String(discovery.host||'');
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) throw new Error('Invalid session host');
  const bounded=(value,min,max,label)=>{
    if (!Number.isSafeInteger(value)||value<min||value>max)throw new Error(`Invalid ${label}`);
    return value;
  };
  return {
    discovery: {
      host,port:bounded(discovery.port,1,65535,'port'),
      timeoutMs:bounded(discovery.connectTimeoutMs,100,10000,'timeout'),
      maxResponseBytes:bounded(discovery.maximumResponseBytes,128,65536,'response bounds'),
      maxTtlSeconds:bounded(discovery.maximumTtlSeconds,5,600,'TTL'),
    },
    experiences:(source.experiences||[]).filter(e=>e.managementMode==='managed'&&(e.launch.workflow==='coco-managed'||e.launch.workflow==='coco-standalone')).map(e=>({
      id:e.id,
      packVersion:String(e.pack?.version||''),
      host:String(e.hosting?.host||''),
      port:e.hosting?.port??0,
    })),
  };
}

function safeManagedAsset(asset, packId) {
  const path=String(asset?.path||'');
  const sha256=String(asset?.sha256||'').toLowerCase();
  const size=asset?.size;
  const role=String(asset?.role||'all');
  if(!path||path.startsWith('/')||path.includes('\\')||path.split('/').some(p=>!p||p==='.'||p==='..'||p.includes(':'))||!['all','host','client'].includes(role)||!Number.isSafeInteger(size)||size<0||!/^[a-f0-9]{64}$/.test(sha256)){
    throw new Error(`Invalid managed asset: ${packId}/${path}`);
  }
  return {path,sha256,size,role,sourceUrl:String(asset?.sourceUrl||'')};
}

export function toManagedManifest(entry, lock){
  if(entry.launch.workflow!=='coco-managed')return null;
  if(lock.schemaVersion!==1||!Array.isArray(lock.assets)||!lock.assets.length)throw Error(`Managed lock incomplete: ${entry.id}`);
  const assets=lock.assets.map(asset=>safeManagedAsset(asset,entry.id));
  const pathSet=new Set();
  for(const asset of assets){const key=asset.path.toLowerCase();if(pathSet.has(key))throw Error(`Duplicate managed asset: ${entry.id}/${key}`);pathSet.add(key);}
  const basic=toExperience(entry);
  const extras=[];
  for(const item of (entry.files||[])){
    const file=safeManagedAsset(item,entry.id);
    const original=assets.find(asset=>asset.path.toLowerCase()===file.path.toLowerCase());
    if(original){
      if(original.sha256!==file.sha256||original.size!==file.size||original.role!==file.role){throw Error(`Conflicting managed extra: ${entry.id}/${file.path}`);}
      continue;
    }
    extras.push(file);
  }
  return {
    id:entry.id,instanceId:basic.instanceId,workflow:'coco-managed',
    minecraftVersion:basic.minecraftVersion,loader:basic.loader,loaderVersion:String(entry.runtime?.loaderVersion||''),
    packVersion:String(entry.pack?.version||''),
    assets,
    extraFiles:extras,
    sourceArchive:lock.pack?.archive ? {path:lock.pack.archive.path,sha256:lock.pack.archive.sha256,size:lock.pack.archive.size,sourceUrl:lock.pack.archive.sourceUrl} : null,
  };
}

export function toMediaManifest(entry){
  if(entry?.launch?.workflow!=='coco-media')return null;
  const content=entry.content||{};
  if(!['movie','episodic-video'].includes(content.type))throw Error(`Unknown media type ${entry.id}`);
  const episodes=Array.isArray(content.episodes)&&content.episodes.length?content.episodes:(content.movie?[content.movie]:[]);
  if(!episodes.length)throw Error(`Missing media episodes ${entry.id}`);
  const ids=new Set();
  return {id:entry.id,name:String(entry.name),type:content.type,episodes:episodes.map(e=>{
    if(!/^[a-zA-Z0-9][a-zA-Z0-9-]{0,100}$/.test(e.id)||ids.has(e.id))throw Error(`Duplicate or invalid episode ${entry.id}`);
    ids.add(e.id);
    const streamUrl=String(e.streamUrl||e.sourceUrl||'');
    const sourceUrl=String(e.sourceUrl||'');
    if(!streamUrl.startsWith('https://github.com/')||!sourceUrl.startsWith('https://github.com/')||!Number.isSafeInteger(e.size)||e.size<=0||!/^[a-fA-F0-9]{64}$/.test(String(e.sha256||'')))throw Error(`Invalid media source ${entry.id}/${e.id}`);
    return {id:e.id,title:String(e.title),fileName:String(e.fileName),streamUrl,sourceUrl,size:e.size,sha256:String(e.sha256).toLowerCase()};
  })};
}

export async function syncCatalog() {
  const source = JSON.parse(await readFile(catalogPath, 'utf8'));
  const entries = (source.experiences || []).map(toExperience);
  const installManifests = (source.experiences || []).map(toInstallManifest).filter(Boolean);
  const mediaManifests=(source.experiences||[]).map(toMediaManifest).filter(Boolean);
  const managedManifests=[];
  for(const experience of (source.experiences||[]).filter(x=>x.launch.workflow==='coco-managed')){
    const relative=String(experience.pack?.lockPath||'');
    if(!/^launcher\/experiences\/[a-z0-9-]+\.lock\.json$/.test(relative))throw Error(`Invalid lock path: ${experience.id}`);
    const lock=JSON.parse(await readFile(resolve(repoRoot,relative),'utf8'));
    managedManifests.push(toManagedManifest(experience,lock));
  }
  if (!entries.length || !entries.some(e => e.id === 'coco-original')) throw new Error('Catalog missing Coco original');
  if (new Set(entries.map(e => e.id)).size !== entries.length) throw new Error('Duplicate experience IDs');
  await mkdir(coverRoot, { recursive: true });
  await mkdir(resolve(desktopRoot, 'src-tauri/resources'), { recursive: true });
  // The app icon (src-tauri/icons/icon.ico) and favicon belong to Coco 2 now, not Coco 1's reynaico.
  for (const entry of entries) {
    const name = entry.image.split('/').at(-1).replace(/\.webp$/, '');
    const src = resolve(experiencesRoot, name);
    const scope = relative(experiencesRoot, src);
    if (scope.startsWith('..') || scope.includes(sep)) throw new Error(`Out-of-scope cover: ${name}`);
    const dst=resolve(coverRoot,`${name}.webp`);
    const original=await stat(src);
    const output=await stat(dst).catch(()=>null);
    if(!output||output.size===0||output.mtimeMs<original.mtimeMs){
      await sharp(src).rotate().resize({width:1200,height:800,fit:'inside',withoutEnlargement:true})
        .webp({quality:78,effort:4}).toFile(dst);
    }
    // Remove only byte-identical copies created by the old packager. Never
    // delete a file that someone has modified in the shared dirty worktree.
    const legacy=resolve(coverRoot,name);
    const prev=await stat(legacy).catch(()=>null);
    if(prev?.size===original.size){
      const [a,b]=await Promise.all([readFile(src),readFile(legacy)]);
      if(a.equals(b))await unlink(legacy);
    }
  }
  await copyFile(resolve(repoRoot, 'reynaico.webp'), resolve(desktopRoot, 'public/reyna.webp'));
  const json = JSON.stringify(entries, null, 2) + '\n';
  await writeFile(resolve(desktopRoot, 'public/catalog.json'), json, 'utf8');
  await writeFile(resolve(desktopRoot, 'src-tauri/resources/catalog.json'), json, 'utf8');
  await writeFile(resolve(desktopRoot, 'src-tauri/resources/install-manifests.json'), JSON.stringify(installManifests, null, 2)+'\n', 'utf8');
  await writeFile(resolve(desktopRoot, 'src-tauri/resources/session-config.json'), JSON.stringify(toSessionConfig(source),null,2)+'\n','utf8');
  await writeFile(resolve(desktopRoot, 'src-tauri/resources/managed-manifests.json'),JSON.stringify(managedManifests,null,2)+'\n','utf8');
  await writeFile(resolve(desktopRoot, 'src-tauri/resources/media-manifests.json'),JSON.stringify(mediaManifests,null,2)+'\n','utf8');
  console.log(`Coco Launcher 2: synced ${entries.length} experiences and Reyna.`);
  return entries;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  syncCatalog().catch(error => { console.error(error); process.exitCode = 1; });
}
