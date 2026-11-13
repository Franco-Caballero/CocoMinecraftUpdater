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
  assert.match(defender,/fn prepare_windows[\s\S]*?zerotier_script\(msi[\s\S]*?request_with\(Some\(&app\),&\[\],false,script\)/,'one elevation for Defender and ZeroTier');
  assert.match(defender,/service_installed==Some\(false\)/,'only installs ZeroTier when it is missing');
  assert.match(defender,/pinned_installer/,'only the SHA-pinned bundled MSI');
});

test('the host accepts friends automatically while Coco is open, and only for Coco\'s network',async()=>{
  const authorizer=await read('src-tauri/src/services/zerotier_host.rs');
  assert.match(authorizer,/58997fc5f3c0c001/);
  assert.match(authorizer,/127\.0\.0\.1:9993\/controller\/network/);
  assert.match(authorizer,/"authorized":true/);
});
