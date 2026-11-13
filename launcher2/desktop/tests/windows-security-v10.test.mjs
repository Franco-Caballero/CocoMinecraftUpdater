import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const text=name=>readFile(resolve(root,name),'utf8');

test('Windows Security can only open its fixed system-owned page, never add exclusions or elevate silently',async()=>{
  const [native,lib,modules]=await Promise.all([
    text('src-tauri/src/services/windows_security.rs'),
    text('src-tauri/src/lib.rs'),
    text('src-tauri/src/services/mod.rs'),
  ]);
  const implementation=native.slice(0,native.indexOf('#[cfg(test)]'));
  assert.match(implementation,/"windowsdefender:\/\/threatsettings"/);
  assert.match(implementation,/ShellExecuteExW/);
  assert.doesNotMatch(implementation,/Add-MpPreference|Set-MpPreference|Remove-MpPreference|runas|powershell|cmd\.exe|reg\.exe|ExclusionPath/);
  assert.match(modules,/pub mod windows_security;/);
  assert.match(lib,/services::windows_security::get_game_security_guide/);
  assert.match(lib,/services::windows_security::open_windows_security/);
});

test('security folder is obtained from native catalog registration, rejects UNC/reparse and does not trust a package-preview path',async()=>{
  const native=await text('src-tauri/src/services/windows_security.rs');
  assert.match(native,/catalog::read_catalog\(\)/);
  assert.match(native,/entry\.id==id&&entry\.workflow=="coco-standalone"/);
  assert.match(native,/inventory::resolve_instance_root/);
  assert.match(native,/inventory::custom_locations/);
  assert.match(native,/fs::canonicalize\(root\)/);
  assert.match(native,/file_type\(\)\.is_symlink\(\)/);
  assert.match(native,/metadata\.file_attributes\(\) & 0x400 != 0/);
  assert.match(native,/starts_with\(r"\\\\"\)/);
});

test('the user must explicitly request a guide, open Windows Security and manually decide about one verified file',async()=>{
  const app=await text('src/main.tsx');
  assert.match(app,/get_game_security_guide',\{id:entry\.id\}/);
  assert.match(app,/open_windows_security/);
  assert.match(app,/securityRequestEpoch\.current===epoch/);
  assert.match(app,/securityGuide\?\.id===selected\.id/);
  assert.match(app,/onClick=\{\(\)=>void requestGameSecurityGuide\(selected\)\}/);
  assert.match(app,/onClick=\{\(\)=>void openSecuritySettings\(\)\}/);
  assert.match(app,/Coco solo agrega a Defender las carpetas de juegos, con tu autorización de Windows\. No lo desactiva\./);
  const effect=app.slice(app.indexOf('useEffect(()=>{\n    securityRequestEpoch.current++'));
  assert.match(effect,/setSecurityGuide\(null\)/);
  assert.doesNotMatch(app,/invoke\('add_defender_exclusion'/);
});
