import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {dirname,resolve} from 'node:path';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');

test('native commands are restricted to bundled games and no legacy launcher or network setup',async()=>{
  const lib=await readFile(resolve(root,'src-tauri/src/lib.rs'),'utf8');
  const status=await readFile(resolve(root,'src-tauri/src/services/status.rs'),'utf8');
  const capabilities=JSON.parse(await readFile(resolve(root,'src-tauri/capabilities/default.json'),'utf8'));
  assert.match(lib,/services::catalog::get_catalog/);
  assert.match(lib,/services::inventory::get_local_instances/);
  assert.match(lib,/services::standalone::launch_standalone/);
  assert.doesNotMatch(lib,/open_legacy_launcher|get_legacy_launcher_info/);
  assert.doesNotMatch(lib,/enable_ssh/);
  assert.match(lib,/services::status::get_engine_status/);
  assert.match(status,/installation_enabled: false/);
  assert.match(status,/launch_enabled: false/);
  assert.match(status,/network_enabled: false/);
  assert.deepEqual(capabilities.permissions, ['core:default','core:window:allow-minimize','core:window:allow-toggle-maximize','core:window:allow-close','core:window:allow-set-background-color','core:window:allow-start-dragging','core:window:allow-set-fullscreen','updater:default','dialog:allow-open','dialog:allow-save']);
});
