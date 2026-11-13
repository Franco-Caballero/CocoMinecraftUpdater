import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve,dirname} from 'node:path';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=(path)=>readFile(resolve(root,path),'utf8');

test('private signing key never enters dependency install, tests or compilation',async()=>{
  const build=await read('scripts/Build-CocoLauncher2.ps1');
  const signing=await read('scripts/Sign-Coco2Bundle.ps1');
  const configure=await read('scripts/Configure-Coco2Updater.ps1');
  assert.match(build,/TAURI_SIGNING_PRIVATE_KEY.*Process/);
  assert.match(build,/No compilar con la clave de firma/);
  const compilation=build.indexOf("'tauri','build'");
  const signingCall=build.indexOf("'Configure-Coco2Updater.ps1'");
  assert.ok(compilation>0&&signingCall>compilation,'compilation must finish before private key is loaded');
  assert.match(build,/--no-sign/);
  assert.doesNotMatch(build,/Resolve-Path\s+\(Join-Path\s+\$root\s+['"]\.\.\\dist['"]\)/,'a clean clone does not contain a gitignored dist directory');
  assert.match(build,/New-Item\s+-ItemType\s+Directory\s+-Path\s+\$distribution/);
  assert.ok(build.indexOf("Get-Coco2ZeroTierMsi.ps1")<compilation,'bundled driver must be verified before compilation and signing');
  assert.match(signing,/signer sign --app-version/);
  assert.doesNotMatch(signing,/&\s*(?:npm\.cmd|cargo\.exe)|Invoke-Checked\s+['"](?:npm|cargo)/i);
  assert.match(configure,/TAURI_SIGNING_PRIVATE_KEY/);
  assert.match(configure,/finally\s*\{/);
});

test('updater signs exact version and checks before installation',async()=>{
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  assert.equal(config.bundle.createUpdaterArtifacts,true);
  assert.equal(config.plugins.updater.requireSignedVersion,true);
  assert.match(config.plugins.updater.endpoints[0],/^https:\/\/github\.com\/Franco-Caballero\/CocoMinecraftUpdater\/releases\/download\/coco2-channel\/latest\.json$/,
    'the Latest release belongs to Coco 1 and carries its own latest.json');
  const app=await read('src/main.tsx');
  const check=app.slice(app.indexOf('const checkAppUpdate='),app.indexOf('const applyAppUpdate='));
  assert.doesNotMatch(check,/downloadAndInstall/,'automatic discovery must not install in the middle of playback');
  const apply=app.slice(app.indexOf('const applyAppUpdate='),app.indexOf('const playMedia='));
  assert.match(apply,/mediaPlaying/);
  assert.match(apply,/list_running_games/);
  assert.match(apply,/get_active_game_processes/);
  assert.match(apply,/processReport\.status!=='none'/,'fail closed unless Windows scan explicitly reports no games');
  assert.match(apply,/processReportAfter\.status!=='none'/,'the second check must also fail closed');
  assert.match(apply,/processReportAfter\.safeToUpdate/);
  assert.doesNotMatch(apply,/downloadAndInstall/,'do not install in the same operation as downloading');
  assert.match(apply,/await update\.download\(/);
  assert.match(apply,/runningAfter/);
  assert.match(apply,/await update\.install\(/);
  assert.ok(apply.indexOf('runningAfter')<apply.indexOf('await update.install('),'recheck game state after downloading');
});

test('a film downloaded before still plays from disk, though new downloads are not offered',async()=>{
  const app=await read('src/main.tsx');
  assert.doesNotMatch(app,/'download_media_episode'/,'the UI no longer starts downloads');
  assert.match(app,/invoke<PreparedMediaStream>\('prepare_media_stream'/,'playback should use native local-first streaming');
  const lib=await read('src-tauri/src/lib.rs');
  assert.match(lib,/services::media_download::get_media_download_status/);
  assert.match(lib,/services::media_download::download_media_episode/);
  assert.match(lib,/services::media_download::cancel_media_download/);
  assert.match(lib,/services::media::prepare_local_media_stream/);
});

test('network and repair are explicit native commands with honest state gates',async()=>{
  const lib=await read('src-tauri/src/lib.rs');
  const network=await read('src-tauri/src/services/network.rs');
  const install=await read('src-tauri/src/services/install.rs');
  const app=await read('src/main.tsx');
  for(const command of ['prepare_network_setup','join_coco_network'])
    assert.match(lib,new RegExp('services::network::'+command));
  assert.match(app,/invoke<string>\('prepare_windows'\)/,'ZeroTier joins inside the first-open Windows prompt');
  for(const command of ['plan_standalone_repair','prepare_standalone_repair'])
    assert.match(lib,new RegExp('services::install::'+command));
  assert.match(network,/automatic_install_supported:\s*false/);
  assert.match(network,/JoinCoco/);
  assert.match(install,/repair-prepared-no-commit/);
  assert.match(install,/no se reemplazó ningún archivo del juego/);
  const driver=await read('src-tauri/src/services/network_installer.rs');
  assert.match(lib,/services::network_installer::install_zerotier_msi/);
  assert.match(await read('src-tauri/src/services/defender.rs'),/pinned_installer/,'the MSI installs inside the first-open Windows prompt');
  assert.match(driver,/SHELLEXECUTEINFOW/);
  assert.match(driver,/PINNED_SHA256/);
});
