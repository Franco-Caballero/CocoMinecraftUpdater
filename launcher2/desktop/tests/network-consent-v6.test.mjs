import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(root,name),'utf8');

// ZeroTier configures itself like Coco 1 did: on first open, inside the same single Windows
// prompt as Defender. The launcher never waits on it, and the host being offline only means
// the friend's membership is accepted the next time the host opens Coco.
test('ZeroTier is set up on first open inside the one Windows prompt, never from the settings',async()=>{
  const [main,defender,lib]=await Promise.all([read('src/main.tsx'),read('src-tauri/src/services/defender.rs'),read('src-tauri/src/lib.rs')]);
  assert.match(main,/invoke<string>\('prepare_windows'\)/);
  assert.doesNotMatch(main,/join_coco_network|install_zerotier_msi|<h2>Multijugador<\/h2>/,'no network buttons left for the friend');
  assert.match(lib,/services::defender::prepare_windows/);
  assert.match(defender,/fn prepare_windows[\s\S]*?zerotier_script\(msi[\s\S]*?request_with\(Some\(&app\),&\[\],&host_program,false,script\)/,'one elevation for Defender and ZeroTier');
  assert.match(defender,/let host_program[^;]*is_host\(\)\{std::env::current_exe\(\)/,'only the host lets Coco itself through the firewall');
  assert.doesNotMatch(defender.slice(defender.indexOf('pub async fn prepare_windows')).split('\n}')[0],/setup_supported/,'the never-true status flag must not gate the setup');
  assert.match(defender,/service_installed==Some\(false\)/,'only installs ZeroTier when it is missing');
  assert.match(defender,/pinned_installer/,'only the SHA-pinned bundled MSI');
});

test('Windows consent guidance ends when the elevated helper starts or the request fails',async()=>{
  const [main,defender]=await Promise.all([read('src/main.tsx'),read('src-tauri/src/services/defender.rs')]);
  assert.match(defender,/set_phase\(WindowsPreparation::Requesting\);\s*if unsafe\{ShellExecuteExW/);
  assert.match(defender,/set_phase\(WindowsPreparation::Configuring\);[\s\S]*?let waited=unsafe\{WaitForSingleObject/);
  assert.match(defender,/let elevation=run_elevated[^;]*;\s*set_phase\(WindowsPreparation::Idle\);/);
  assert.match(main,/window\.clearTimeout\(consentHintTimer\);\s*if\(payload==='requesting'\)\{\s*setWindowsPreparation\('checking'\);[\s\S]*?window\.setTimeout\(\(\)=>setWindowsPreparation\('requesting'\),900\);\s*\}else setWindowsPreparation\(payload\)/);
});

test('the host accepts friends automatically while Coco is open, and only for Coco\'s network',async()=>{
  const authorizer=await read('src-tauri/src/services/zerotier_host.rs');
  assert.match(authorizer,/58997fc5f3c0c001/);
  assert.match(authorizer,/127\.0\.0\.1:9993\/controller\/network/);
  assert.match(authorizer,/"authorized":true/);
});

test('profile names reach the host only over the Coco network',async()=>{
  const names=await read('src-tauri/src/services/zerotier_host.rs');
  assert.match(names,/TcpListener::bind\(\(HOST_IP,NAME_PORT\)\)/,'listens on 10.77.37.1 only, never on every interface');
  assert.match(names,/if !is_coco_client_address\(peer\.ip\(\)\)\{continue;\}/);
  assert.match(names,/valid_minecraft_username\(name\)/);
});
