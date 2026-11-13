import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');

test('trusted catalog commands have native registrations and never grant browser code installer authority',async()=>{
  const [native,hub,catalog]=await Promise.all([read('src-tauri/src/lib.rs'),read('src/CatalogHub.tsx'),read('src-tauri/src/services/catalog.rs')]);
  for(const name of ['review_local_publish_package','import_local_publish_package','sync_catalog_channel','get_catalog_channel_status']){
    assert.match(native,new RegExp(`services::catalog::${name}\\b`));
    assert.match(catalog,new RegExp(`pub (async )?fn ${name}\\b`));
    assert.match(hub,new RegExp(`['"]${name}['"]`));
  }
  assert.match(hub,/reviewToken:review\.reviewToken,confirmed:true/);
  assert.match(hub,/!review\|\|!confirmed/);
  assert.match(hub,/se conserva el cat[aá]logo anterior/i);
  assert.doesNotMatch(hub,/execSync|powershell|fs\.writeFile|child_process/i);
});

test('new games do not require a new binary and the host can prepare an unsigned release review',async()=>{
  const [catalog,channel,studio,native]=await Promise.all([read('src-tauri/src/services/catalog.rs'),read('src-tauri/src/services/catalog_channel.rs'),read('src/HostStudio.tsx'),read('src-tauri/src/lib.rs')]);
  assert.match(catalog,/catalog_channel::merged_catalog/);
  assert.match(catalog,/read_install_manifest_version/);
  assert.match(channel,/ED25519/);
  assert.match(channel,/OFFICIAL_CATALOG/);
  assert.match(channel,/previous_sha256/);
  assert.match(channel,/standalone-packs/);
  assert.match(studio,/reviewForMyLibrary/);
  assert.match(studio,/addToMyLibrary/);
  assert.match(studio,/prepareChannel/);
  assert.match(studio,/reviewNote/);
  assert.match(native,/services::catalog::prepare_catalog_channel/);
  assert.match(channel,/staged-assets-upload-required/);
  assert.doesNotMatch(studio,/uploadToGitHub\(|release\.create\(/);
});

test('upgrades preserve native guard and expose recovery instead of pretending repaired',async()=>{
  const [native,app,install]=await Promise.all([read('src-tauri/src/lib.rs'),read('src/main.tsx'),read('src-tauri/src/services/install.rs')]);
  for(const name of ['plan_standalone_upgrade','upgrade_standalone','recover_standalone_upgrade']){
    assert.match(native,new RegExp(`services::install::${name}\\b`));
    assert.match(app,new RegExp(`['"]${name}['"]`));
    assert.match(install,new RegExp(`pub async fn ${name}\\b`));
  }
  assert.match(app,/upgradePlan\?\.status==='upgrade-ready'/);
  assert.doesNotMatch(app,/upgradePlan\.message\}/,'a plan that needs nothing from the player shows nothing');
  assert.match(app,/upgrading\|\|upgradeRecovering/);
  assert.match(install,/read_install_manifest_version/);
  assert.doesNotMatch(install,/git clean|git reset|PowerShell\.exe/);
});
