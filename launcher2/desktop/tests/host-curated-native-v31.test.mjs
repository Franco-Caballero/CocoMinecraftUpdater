/**
 * Coco Launcher 2 — host-curated catalog trust boundary (v31).
 * Source-contract RED tests until prime releases the 0.6.14 Rust builder.
 * No Rust edits, Cargo, network, user profiles, registry, games or signatures.
 * Native test is opt-in AFTER the builder is explicitly released by prime.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname,join,resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const catalogPath=join(desktop,'src-tauri','src','services','catalog.rs');
const channelPath=join(desktop,'src-tauri','src','services','catalog_channel.rs');
const [catalog,channel]=await Promise.all([
  readFile(catalogPath,'utf8'),readFile(channelPath,'utf8'),
]);

function section(text,from,to){
  const start=text.indexOf(from);
  const end=text.indexOf(to,start+from.length);
  assert.ok(start>=0&&end>start,`expected actual Rust route: ${from} → ${to}`);
  return text.slice(start,end);
}

test('Ed25519 must verify signed channel BEFORE any official snapshot is accepted',()=>{
  const signature=section(channel,'fn verify_signed_channel(', 'fn decode_channel(');
  const apply=section(channel,'fn apply_signed_at(', 'pub async fn sync_catalog_channel(');
  assert.ok(signature.includes('UnparsedPublicKey::new(&ED25519,key).verify(json,&sig)'),
    'official remote entries must be cryptographically verified');
  assert.ok(apply.indexOf('verify_signed_channel(body,sig,key)')>=0 &&
    apply.indexOf('verify_signed_channel(body,sig,key)')<apply.indexOf('commit(dir,snap,sha)'),
    'official signed payload must be authenticated before durable commit');
  assert.ok(channel.includes('pub mod test_api')||channel.includes('pub(super) mod test_api')||
    channel.includes('mod test_api'), 'existing synthetic host/client test fixture API remains present');
});

test('distributed public import must reject unsigned local packages even after confirmation',()=>{
  const publicReview=section(channel,'pub async fn review_local_publish_package(',
    'pub async fn import_local_publish_package(');
  const publicImport=section(channel,'pub async fn import_local_publish_package(',
    'fn minisign_key_from_config(');
  assert.ok(/host_curated_client_guard\(\)/.test(publicReview),
    'public review cannot authorize even the first step of friend-side unsigned publication');
  assert.ok(/host_curated_client_guard\(\)/.test(publicImport),
    'PUBLIC Tauri import must be disabled for distributed friends; user review token and consent do not convey host approval');
  assert.ok(catalog.includes('catalog_channel::import_local_publish_package(path,review_token,confirmed).await'),
    'do not silently break Tauri command handler or existing native API');
});

test('distributed catalog must exclude legacy unsigned local snapshot IDs, not just embedded collisions',()=>{
  const merged=section(channel,'pub(super) fn merged_catalog(', 'fn provenance_at(');
  assert.ok(merged.includes('client_catalog_view'),
    'public read_catalog must apply a client-only view that excludes ALL source=local, including legacy snapshot IDs');
  assert.ok(catalog.includes('catalog_channel::merged_catalog(baseline)'),
    'public get_catalog must keep using the native read path');
});

test('current AND historical installation manifests must reject unsigned legacy local entries',()=>{
  const manifest=section(channel,'pub(super) fn manifest_for(', 'fn merged_catalog_at(');
  assert.ok(manifest.includes('client_manifest_at'),
    'public read_install_manifest[_version] must enforce client authorization on current AND historical snapshots');
  assert.ok(catalog.includes('catalog_channel::manifest_for(id, Some(version))'),
    'existing history lookup must remain present for signed transactional upgrades');
});

test('public provenance must not advertise unsigned local IDs as host-approved',()=>{
  const provenance=section(channel,'pub(super) fn provenance()', 'fn status(');
  assert.ok(provenance.includes('client_provenance_view'),
    'distributed user-facing provenance cannot present local unsigned titles as available');
});

const native=process.platform==='win32' &&
  process.env.COCO2_HOST_CURATED_NATIVE_V31_E2E==='1';
test('native TEMP host/client legacy and signed-channel trust boundary',{
  skip:native?false:'set COCO2_HOST_CURATED_NATIVE_V31_E2E=1 ONLY after prime confirms builder complete',
  timeout:220_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','-j','1','--lib',
    'services::catalog::catalog_channel::tests', '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const collect=part=>{output=(output+part.toString()).slice(-250_000);};
  child.stdout.on('data',collect);child.stderr.on('data',collect);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},205_000);
  const finish=await new Promise((resolveFinish,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolveFinish({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Synthetic host/client Rust suite timed out:\n'+output);
  assert.equal(finish.code,0,'Synthetic host/client Rust suite failed:\n'+output);
  for(const name of [
    'v31_distributed_client_blocks_unsigned_local_snapshot_in_current_catalog_and_manifest',
    'v31_distributed_client_blocks_legacy_local_history_but_preserves_signed_and_embedded',
    'v31_client_signed_official_channel_supersedes_legacy_local_collision',
    'isolated_native_host_client_signed_e2e_retains_local_and_history_without_env_changes',
    'ed25519_channel_enforces_embedded_key_format_exact_signature_and_sequence',
  ]) assert.ok(output.includes(`${name} ... ok`),`missing native test: ${name}`);
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
