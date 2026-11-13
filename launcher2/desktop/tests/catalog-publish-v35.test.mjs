// The host's fast path: games added after the last Setup travel through the signed catalog
// channel. These checks cover the publisher's pure parts; the signing key is never needed.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync,sign,verify} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {channelCandidates,channelProblems,decodeTauriSecretKey,ed25519Keys,extrasFor,newerVersion,publicKeyObject,scryptParams,updaterPublicKey}
  from '../scripts/Publish-Coco2Catalog.mjs';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');

test('scrypt parameters match libsodium for minisign keys',()=>{
  // The Tauri CLI writes opslimit 2^20 and memlimit 2^25: N=2^15, r=8, p=1.
  assert.deepEqual(scryptParams(1048576,33554432),{N:32768,r:8,p:1});
  // minisign's own defaults pick N=2^20 with p=1.
  assert.deepEqual(scryptParams(33554432,1073741824),{N:1048576,r:8,p:1});
});

test('versions order numerically and refuse labels the client cannot order',()=>{
  assert.equal(newerVersion('1.10.0','1.9.9'),true);
  assert.equal(newerVersion('2026','2025.12'),true);
  assert.equal(newerVersion('1.0','1.0.0'),false);
  assert.throws(()=>newerVersion('2.1.a','2.1'),/numérica/);
});

test('only standalone games newer than the last Setup go through the channel',()=>{
  const game=(id,version,workflow='coco-standalone')=>({id,launch:{workflow},pack:{version}});
  const baseline={games:{old:'1.0.0',same:'2.1.a',bumped:'1.0.0'}};
  const picked=channelCandidates([game('old','1.0.0'),game('same','2.1.a'),game('bumped','1.1.0'),game('fresh','0.1'),game('film','1','coco-media')],baseline)
    .map(entry=>entry.id);
  assert.deepEqual(picked,['bumped','fresh']);
});

test('a game the client would reject is reported instead of published',()=>{
  const experience={id:'nice-game',instanceId:'nice-game',name:'Nice',description:'',launchArguments:[],hostingMode:'p2p',
    executable:'Game/Game.exe',requiredFiles:[{path:'Game/Game.exe',sha256:'a'.repeat(64),size:1}]};
  const manifest={extraFiles:[],archives:[{url:'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/nice-1/nice.zip'}]};
  assert.deepEqual(channelProblems(experience,manifest),[]);
  assert.ok(channelProblems({...experience,launchArguments:['-x']},manifest).some(p=>/argumentos/.test(p)));
  assert.ok(channelProblems(experience,{...manifest,archives:[{url:'https://example.com/a.zip'}]}).some(p=>/releases/.test(p)));
  assert.ok(channelProblems(experience,{...manifest,extraFiles:[{}]}).some(p=>/files/.test(p)));
});

test('extras carry only the Steam media the client accepts',()=>{
  const fix={games:{g:{realAppId:'123',hash0:'a'.repeat(128),hash1337:''}}};
  const extra=extrasFor('g',{g:{url:'https://cdn.akamai.steamstatic.com/steam/apps/1/microtrailer.webm',steamAppId:1,bytes:9}},
    {g:['https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1/ss_a.1920x1080.jpg','https://evil.example/x.jpg']},fix);
  assert.equal(extra.preview.url.endsWith('microtrailer.webm'),true);
  assert.equal(extra.screenshots.length,1);
  assert.equal(extra.onlineFix.realAppId,'123');
  assert.deepEqual(extrasFor('g',{g:{url:'/previews/local.mp4'}},{},{games:{}}),{},'a bundled local clip cannot travel');
  const newer=extrasFor('g',{g:{url:'https://video.akamai.steamstatic.com/store_trailers/1/2/abc/3/microtrailer.webm'}},{},{games:{}});
  assert.ok(newer.preview,'newer Steam trailers live on video.akamai');
});

test('a minisign secret key decodes to the same Ed25519 pair the updater trusts',()=>{
  const {privateKey,publicKey}=generateKeyPairSync('ed25519');
  const jwk=privateKey.export({format:'jwk'});
  const seed=Buffer.from(jwk.d,'base64url'),pub=Buffer.from(jwk.x,'base64url');
  const keyId=Buffer.from('0123456789abcdef','hex');
  // Unencrypted layout: Ed, \0\0 kdf, B2 checksum, salt, limits, then key id + secret + checksum.
  const raw=Buffer.concat([Buffer.from('Ed'),Buffer.from([0,0]),Buffer.from('B2'),Buffer.alloc(32),Buffer.alloc(16),keyId,seed,pub,Buffer.alloc(32)]);
  const tauriKey=Buffer.from(`untrusted comment: rsign encrypted secret key\n${raw.toString('base64')}\n`).toString('base64');
  const decoded=decodeTauriSecretKey(tauriKey);
  assert.ok(decoded.keyId.equals(keyId));
  assert.ok(decoded.publicKey.equals(pub));
  const keys=ed25519Keys(decoded.seed,decoded.publicKey);
  const signature=sign(null,Buffer.from('catalog'),keys.privateKey);
  assert.ok(verify(null,Buffer.from('catalog'),publicKey,signature));
  assert.ok(verify(null,Buffer.from('catalog'),publicKeyObject(pub),signature));
});

test('the publisher signs with the key the shipped launcher embeds',async()=>{
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  assert.equal(updaterPublicKey(config).publicKey.length,32);
  const rust=await read('src-tauri/src/services/catalog_channel.rs');
  assert.match(rust,/const CHANNEL_HEAD: &str = "coco2-catalog-head\.json"/);
  assert.match(rust,/format!\("coco2-catalog-s\{\}\.json",head\.sequence\)/);
  const script=await read('scripts/Publish-Coco2Catalog.mjs');
  assert.match(script,/export const HEAD_NAME='coco2-catalog-head\.json'/);
  assert.match(script,/Body and signature first, under names nobody reads yet; the head last/);
  const baseline=JSON.parse(await read('channel-baseline.json'));
  assert.ok(Object.keys(baseline.games).length>0);
  const release=await read('scripts/Publish-Coco2Release.ps1');
  assert.match(release,/channel-baseline\.json/,'publishing a Setup moves the channel baseline');
});
