import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(root,name),'utf8');

test('Host Studio constructs official future ZIP URL from tag and filename, not a fake publication status',async()=>{
  const studio=await read('src/HostStudio.tsx');
  assert.match(studio,/setReleaseTag/);
  assert.match(studio,/setAssetName/);
  assert.match(studio,/https:\/\/github\.com\/Franco-Caballero\/CocoMinecraftUpdater\/releases\/download\/\$\{releaseTag\}/);
  assert.match(studio,/disabled=\{busy\|\|!urlValid\|\|missingItems\.length>0\}/);
  assert.match(studio,/Portada \(opcional\)/);
  assert.match(studio,/no crea releases ni sube archivos/i);
});

test('portable export has isolated native verified and non-overwriting path and honest import limitation',async()=>{
  const [studio,host,native,app]=await Promise.all([
    read('src/HostStudio.tsx'),read('src-tauri/src/services/host_publish.rs'),
    read('src-tauri/src/lib.rs'),read('src-tauri/src/services/import.rs')]);
  assert.match(native,/services::r#import::export_portable_standalone_package/);
  assert.match(app,/pub async fn export_portable_standalone_package/);
  assert.match(host,/pub\(super\) fn export_portable/);
  assert.match(host,/rename_no_replace\(&temp,&dest\)/);
  assert.match(host,/portable_export_contains_only_verified_review_package/);
  assert.match(studio,/export_portable_standalone_package/);
  assert.match(studio,/No necesita extraer nada/);
  assert.match(studio,/extensions:\['coco2pack'\]/);
  assert.match(studio,/destinationPath:destination/);
  assert.doesNotMatch(studio,/signedAndPublished|publishedSuccessfully|releaseUploaded/);
});

test('signed delivery readiness requires actual native verification; remote check is explicitly user triggered',async()=>{
  const [native,studio,catalog]=await Promise.all([
    read('src-tauri/src/lib.rs'),read('src/HostStudio.tsx'),
    read('src-tauri/src/services/catalog_channel.rs')]);
  for(const command of ['review_channel_delivery','verify_channel_delivery_online']){
    assert.match(native,new RegExp(`services::catalog::${command}\\b`));
    assert.match(studio,new RegExp(`['"]${command}['"]`));
  }
  assert.match(studio,/deliveryReview\?\.signatureTrusted/);
  assert.match(studio,/deliveryReview\.assets\.map/);
  assert.match(catalog,/verify_signed_channel\(bytes,signature_bytes,key\)/);
  assert.match(catalog,/report\.ready_for_upload=correct&&report\.signature_trusted/);
  assert.match(catalog,/report\.all_remote_verified/);
});

test('pending native operations are shown without silent rollback',async()=>{
  const [app,native]=await Promise.all([read('src/main.tsx'),read('src-tauri/src/lib.rs')]);
  assert.match(native,/services::install::recover_pending_standalone_operations/);
  assert.match(app,/invoke<PendingStandaloneOperation\[]>\('recover_pending_standalone_operations'\)/);
  assert.match(app,/role="alert" aria-label="Operaciones pendientes de recuperar"/);
  assert.match(app,/Coco no modificará nada sin que revises la recuperación/);
  assert.doesNotMatch(app,/useEffect\([^]*?recover_standalone_upgrade\([^]*?\},\[bootstrapLoaded/);
});

test('trusted cached catalog renders immediately and background identical/offline channel causes no re-enumeration',async()=>{
  const app=await read('src/main.tsx');
  assert.match(app,/const CATALOG_SYNC_INTERVAL_MS=3\*60_000/,'only a tiny head is read each time');
  assert.match(app,/result\.status==='updated'\)\{await loadCatalogExtras\(\);await refreshNativeCatalog\(\);\}/,'extras land before the new cards');
  assert.match(app,/publishVerifiedCatalog\(/);
  assert.match(app,/if\(sources\.status==='fulfilled'\)setCatalogSources\(new Map\(sources\.value\.map/);
  assert.match(app,/if\(!isCurrent\(\)\)return/);
});
