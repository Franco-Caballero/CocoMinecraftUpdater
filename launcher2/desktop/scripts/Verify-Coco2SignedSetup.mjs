#!/usr/bin/env node
// Offline cryptographic verification of the exact Tauri updater package.
// Only the public key embedded in tauri.conf.json is read; no signing secrets
// or network calls are needed and no generated artifacts are modified.
import {readFile} from 'node:fs/promises';
import {createHash,createPublicKey,verify} from 'node:crypto';
import {dirname,resolve,join,basename} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const distribution=resolve(root,'../dist');
const setup=resolve(process.argv[2]||join(distribution,'CocoLauncher2-Setup.exe'));
const sha=bytes=>createHash('sha256').update(bytes).digest('hex').toUpperCase();
function decode64(text,label){
  const source=text.trim();
  if(!source||!/(?:^[A-Za-z0-9+/]+={0,2}$)/.test(source))throw Error(`Invalid ${label} base64`);
  const decoded=Buffer.from(source,'base64');
  if(decoded.toString('base64')!==source)throw Error(`Noncanonical ${label} base64`);
  return decoded;
}
function minisignSignature(encoded){
  const lines=decode64(encoded,'Tauri signature').toString('utf8').trim().split(/\r?\n/);
  if(lines.length!==4||!lines[0].startsWith('untrusted comment: ')||!lines[2].startsWith('trusted comment: ')){
    throw Error('Tauri signature must be the complete four-line Minisign envelope');
  }
  const binary=decode64(lines[1],'Minisign signed message');
  const commentSignature=decode64(lines[3],'Minisign trusted-comment signature');
  if(binary.length!==74||commentSignature.length!==64||binary.subarray(0,2).toString('ascii')!=='ED'){
    throw Error('Unsupported Minisign signature format (expected BLAKE2b-prehashed Ed25519)');
  }
  return {binary,commentSignature,trustedComment:lines[2].slice('trusted comment: '.length)};
}

try{
  const config=JSON.parse(await readFile(join(root,'src-tauri/tauri.conf.json'),'utf8'));
  const publicText=decode64(config.plugins.updater.pubkey,'Tauri updater public key').toString('utf8');
  const publicLines=publicText.trim().split(/\r?\n/);
  if(publicLines.length!==2||!publicLines[0].startsWith('untrusted comment: '))throw Error('Invalid embedded Minisign public key');
  const publicBytes=decode64(publicLines[1],'Minisign public key');
  if(publicBytes.length!==42||!['ED','Ed'].includes(publicBytes.subarray(0,2).toString('ascii'))){
    throw Error('Invalid embedded Ed25519 public key format');
  }
  // DER SubjectPublicKeyInfo prefix for an Ed25519 public key (RFC 8410).
  const key=createPublicKey({
    key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),publicBytes.subarray(10)]),
    format:'der',type:'spki',
  });
  const bytes=await readFile(setup);
  const digest=sha(bytes);
  const encodedSignature=(await readFile(`${setup}.sig`,'utf8')).trim();
  const {binary,commentSignature,trustedComment}=minisignSignature(encodedSignature);
  if(!publicBytes.subarray(2,10).equals(binary.subarray(2,10)))throw Error('Signature key ID mismatch');
  const payloadSignature=binary.subarray(10);
  const prehash=createHash('blake2b512').update(bytes).digest();
  if(!verify(null,prehash,key,payloadSignature))throw Error('Installer bytes fail Ed25519 signature');
  const commentSignedBytes=Buffer.concat([payloadSignature,Buffer.from(trustedComment,'utf8')]);
  if(!verify(null,commentSignedBytes,key,commentSignature))throw Error('Minisign trusted comment signature invalid');
  if(!trustedComment.includes(`version:${config.version}`))throw Error('Signed version does not match Tauri config');
  // Negative control: a one-byte changed installer must fail cryptographic
  // verification rather than being accepted based on filename/size metadata.
  const tampered=Buffer.from(bytes);tampered[0]^=1;
  if(verify(null,createHash('blake2b512').update(tampered).digest(),key,payloadSignature)){
    throw Error('Signature erroneously accepted a tampered installer');
  }
  const candidate=join(distribution,'publish-ready',`${config.version}-${digest.slice(0,12)}`);
  const feed=JSON.parse(await readFile(join(candidate,'latest.json'),'utf8'));
  const item=feed.platforms?.['windows-x86_64'];
  if(feed.version!==config.version||item?.signature!==encodedSignature)throw Error('Updater feed does not match exact signed installer');
  const url=new URL(item.url);
  const expectedName=`CocoLauncher2_${config.version}_x64-setup.exe`;
  if(url.protocol!=='https:'||url.hostname!=='github.com'||
     basename(decodeURIComponent(url.pathname))!==expectedName||
     url.pathname!==`/Franco-Caballero/CocoMinecraftUpdater/releases/download/coco2-channel/${expectedName}`){
    throw Error('Updater feed uses an unexpected release URL');
  }
  const candidateBytes=await readFile(join(candidate,expectedName));
  const candidateSignature=(await readFile(join(candidate,`${expectedName}.sig`),'utf8')).trim();
  if(sha(candidateBytes)!==digest||candidateSignature!==encodedSignature)throw Error('Immutable release candidate differs from shareable Setup');
  console.log(`Signed Coco 2 ${config.version}: verified ${bytes.length} bytes; SHA256 ${digest}; full Ed25519 Minisign + trusted comment + feed PASS`);
}catch(error){
  console.error(`Coco 2 signed Setup verification FAILED: ${error instanceof Error?error.message:String(error)}`);
  process.exitCode=1;
}
