import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, basename } from 'node:path';
import { toExperience, toInstallManifest, toManagedManifest, toMediaManifest, syncCatalog } from '../scripts/sync-catalog.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)), '..');
const project=resolve(root,'../../');

test('rejects unsafe image locations and invalid identities before generating assets',()=>{
  const standard={id:'safe-pack',name:'Safe pack',ui:{imagePath:'assets/experiences/safe.png'},launch:{workflow:'coco-managed'}};
  assert.equal(toExperience(standard).image,'/covers/safe.png.webp');
  assert.throws(()=>toExperience({...standard,ui:{imagePath:'../../secrets.json'}}),/Invalid experience cover/);
  assert.throws(()=>toExperience({...standard,ui:{imagePath:'assets/experiences/..%2fsecret.jpg'}}),/Invalid experience cover/);
  assert.throws(()=>toExperience({...standard,id:'../../escape'}),/Invalid experience metadata/);
});

test('the real catalog generates the same sanitized entries for browser and native app',async()=>{
  const entries=await syncCatalog();
  const original=JSON.parse(await readFile(resolve(project,'launcher/catalog.template.json'),'utf8'));
  const frontend=JSON.parse(await readFile(resolve(root,'public/catalog.json'),'utf8'));
  const backend=JSON.parse(await readFile(resolve(root,'src-tauri/resources/catalog.json'),'utf8'));
  assert.equal(entries.length,original.experiences.length);
  assert.deepEqual(entries,frontend);
  assert.deepEqual(frontend,backend);
  assert.equal(new Set(entries.map(x=>x.id)).size,entries.length);
  for(const entry of entries){
    assert.deepEqual(Object.keys(entry).sort(),['id','instanceId','name','image','description','workflow','minecraftVersion','loader','requiredFiles','executable','launchArguments','hostingMode'].sort());
    assert.ok(['external-launcher','coco-managed','coco-standalone','coco-media'].includes(entry.workflow));
    assert.ok((await stat(resolve(root,'public/covers',basename(entry.image)))).size>0);
  }
  assert.ok((await stat(resolve(root,'public/reyna.webp'))).size>0);
  assert.ok((await stat(resolve(root,'src-tauri/icons/icon.ico'))).size>0);
});

test('standalone archive metadata is private, ordered and SHA pinned',async()=>{
  const original=JSON.parse(await readFile(resolve(project,'launcher/catalog.template.json'),'utf8'));
  const manifests=JSON.parse(await readFile(resolve(root,'src-tauri/resources/install-manifests.json'),'utf8'));
  assert.equal(manifests.length,original.experiences.filter(x=>x.launch.workflow==='coco-standalone').length);
  for(const manifest of manifests){
    const source=original.experiences.find(x=>x.id===manifest.id);
    assert.ok(source);
    assert.deepEqual(manifest.archives.map(x=>x.sha256),source.pack.archives.map(x=>x.sha256));
    assert.equal(manifest.extraFiles.length,(source.files||[]).length);
  }
  const publicCatalog=await readFile(resolve(root,'public/catalog.json'),'utf8');
  assert.doesNotMatch(publicCatalog,/archiveUrl|sourceUrl|https:\/\/github\.com\/Franco-Caballero/);
  assert.throws(()=>toInstallManifest({...original.experiences.find(x=>x.id==='machine-party'),pack:{archives:[{archiveUrl:'http://example.com/bad.zip',sha256:'0'.repeat(64),size:100}],version:'1'}}),/Unsafe archive/);
});

test('Party Animals ships every independent part and verifies the prepared loader before launch',async()=>{
  const source=JSON.parse(await readFile(resolve(project,'launcher/catalog.template.json'),'utf8'));
  const game=source.experiences.find(entry=>entry.id==='party-animals');
  assert.ok(game);
  assert.equal(game.runtime.executable,'PartyAnimals.exe');
  assert.equal(game.pack.archives.length,7);
  assert.equal(game.pack.size,game.pack.archives.reduce((bytes,part)=>bytes+part.size,0));
  const hashes=new Set(game.pack.archives.map(part=>part.sha256));
  assert.equal(hashes.size,7);
  for(const part of game.pack.archives)assert.ok(part.size>0&&part.size<2*1024**3);
  for(const file of game.runtime.requiredFiles)assert.ok(hashes.has(file.archiveSha256));
  const loader=game.runtime.requiredFiles.find(file=>file.path==='version.dll');
  assert.equal(loader?.sha256,'2f2648b84507c813da18c1dac5965d84a8c96973f767c8dc12b54a8bb3eb1b0c');
  assert.equal(loader.size,3316736);
  const lock=JSON.parse(await readFile(resolve(project,game.pack.lockPath),'utf8'));
  assert.deepEqual(lock.archives,game.pack.archives.map(({archiveUrl:url,sha256,size})=>({url,sha256,size})));
});

test('Golf It uses the direct Unreal leaf and ten compressed parts without hashing the huge UCAS on every launch',async()=>{
  const source=JSON.parse(await readFile(resolve(project,'launcher/catalog.template.json'),'utf8'));
  const game=source.experiences.find(entry=>entry.id==='golf-it');
  assert.equal(game.runtime.executable,'GolfIt/Binaries/Win64/GolfIt-Win64-Shipping.exe');
  assert.equal(game.pack.archives.length,10);
  assert.equal(game.pack.size,5962596882);
  assert.equal(game.pack.archives.reduce((sum,part)=>sum+part.size,0),game.pack.size);
  assert.ok(game.pack.archives.every(part=>part.size<2*1024**3));
  assert.ok(game.runtime.requiredFiles.some(file=>file.path.endsWith('/OnlineFix64.dll')));
  assert.ok(game.runtime.requiredFiles.some(file=>file.path.endsWith('/OnlineFix.ini')));
  assert.ok(game.runtime.requiredFiles.every(file=>file.size<1024**3));
});

test('managed Minecraft lock assets are preserved in a private Rust resource',async()=>{
  const original=JSON.parse(await readFile(resolve(project,'launcher/catalog.template.json'),'utf8'));
  const manifests=JSON.parse(await readFile(resolve(root,'src-tauri/resources/managed-manifests.json'),'utf8'));
  assert.equal(manifests.length,original.experiences.filter(x=>x.launch.workflow==='coco-managed').length);
  for(const manifest of manifests){
    const originalEntry=original.experiences.find(x=>x.id===manifest.id);
    const lock=JSON.parse(await readFile(resolve(project,originalEntry.pack.lockPath),'utf8'));
    assert.equal(manifest.assets.length,lock.assets.length);
    assert.deepEqual(manifest.assets.map(x=>x.sha256),lock.assets.map(x=>x.sha256));
    assert.ok(manifest.assets.every(x=>x.role==='all'||x.role==='host'||x.role==='client'));
  }
  assert.equal(manifests.find(x=>x.id==='into-the-backrooms').extraFiles.length,0);
  const sample=manifests[0];
  assert.throws(()=>toManagedManifest(original.experiences.find(x=>x.id===sample.id),{schemaVersion:1,assets:[{path:'../saves/evil',role:'all',sha256:'a'.repeat(64),size:50}]}),/Invalid managed asset/);
  const source=original.experiences.find(x=>x.id==='into-the-backrooms');
  const sourceLock=JSON.parse(await readFile(resolve(project,source.pack.lockPath),'utf8'));
  assert.throws(()=>toManagedManifest({...source,files:[{...source.files[0],sha256:'0'.repeat(64)}]},sourceLock),/Conflicting managed extra/);
});

test('media is separate and private streams cannot leak into UI catalog',async()=>{
  const original=JSON.parse(await readFile(resolve(project,'launcher/catalog.template.json'),'utf8'));
  const manifests=JSON.parse(await readFile(resolve(root,'src-tauri/resources/media-manifests.json'),'utf8'));
  const media=original.experiences.filter(x=>x.launch.workflow==='coco-media');
  assert.equal(manifests.length,media.length);
  for(const item of media){
    const matched=manifests.find(x=>x.id===item.id);
    assert.equal(matched.episodes.length,item.content.episodes?.length||1);
    assert.ok(matched.episodes.every(e=>e.streamUrl.startsWith('https://github.com/')&&e.sha256.length===64));
  }
  const publicCatalog=await readFile(resolve(root,'public/catalog.json'),'utf8');
  assert.doesNotMatch(publicCatalog,/\.mp4\b|streamUrl|sourceUrl/);
  const bad={...media[0],content:{...media[0].content,episodes:[{...media[0].content.episodes[0],streamUrl:'http://evil.test/video.mp4'}]}};
  assert.throws(()=>toMediaManifest(bad),/Invalid media source/);
});
