// Read-only verification of the real versioned NSIS package.
//
// DO NOT EXECUTE setup.exe or uninstall.exe from this file. Setting /D to a
// temporary location does not isolate HKCU, Start Menu, WebView2 or prior
// installed applications. A live install/uninstall needs an independently
// authenticated disposable Windows user/VM with its own registry hive.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, stat, mkdtemp, rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join, resolve, dirname, basename} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=path=>resolve(root,path);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex').toUpperCase();
const file=path=>readFile(source(path));
const config=JSON.parse(await readFile(source('src-tauri/tauri.conf.json'),'utf8'));
const version=config.version;
const exists=async path=>stat(path).then(s=>s.isFile()).catch(()=>false);
const releaseName=`Coco Launcher 2_${version}_x64-setup.exe`;
const bundledSetup=source(`src-tauri/target/release/bundle/nsis/${releaseName}`);
const sharedSetup=source('../dist/CocoLauncher2-Setup.exe');
// A completed build may legitimately prune intermediate target artifacts.
// Fallback is read-only; these tests never create, sign or overwrite a Setup.
const setup=await exists(bundledSetup)?bundledSetup:sharedSetup;
const template=source('src-tauri/windows/nsis/installer-safe.nsi');
const verifyScript=source('scripts/Verify-Coco2SignedSetup.mjs');

// Any 7-Zip works; only some builds can also print the NSIS script, and those checks are skipped otherwise.
const hasSevenZip=()=>spawnSync('7z.exe',['i'],{windowsHide:true}).error===undefined;

function run(program,args,opts={}){
  const result=spawnSync(program,args,{cwd:root,encoding:'utf8',maxBuffer:2*1024*1024,
    timeout:30000,windowsHide:true,...opts});
  assert.equal(result.status,0,
    `${program} ${args.map(x=>basename(x)).join(' ')} failed: ${result.error?.message??''}\n${result.stdout??''}\n${result.stderr??''}`);
  return result.stdout;
}

test(`real Setup ${version} has exact Tauri signed bytes, trusted comment and local update feed`,async(t)=>{
  if(!await exists(setup))return t.skip('Real compiled Setup not present; install test never builds/releases it');
  assert.match(version,/^\d+\.\d+\.\d+$/,'Tauri version must be SemVer for the real Windows package');
  assert.ok(await exists(`${setup}.sig`),'Updater signature sidecar is required');
  const result=run(process.execPath,[verifyScript,setup]);
  assert.match(result,/full Ed25519 Minisign \+ trusted comment \+ feed PASS/);
  const digest=sha(await readFile(setup));
  const candidate=source(`../dist/publish-ready/${version}-${digest.slice(0,12)}`);
  const feed=JSON.parse(await readFile(join(candidate,'latest.json'),'utf8'));
  assert.equal(feed.version,version);
  assert.equal(feed.platforms['windows-x86_64'].signature,
    (await readFile(`${setup}.sig`,'utf8')).trim());
  assert.equal(sha(await readFile(join(candidate,`CocoLauncher2_${version}_x64-setup.exe`))),digest);
  assert.equal(sha(await file('../dist/CocoLauncher2-Setup.exe')),digest);
  t.diagnostic(`Minisign and release candidate valid; SHA256 ${digest}`);
});

test('the shipped NSIS binary embeds guarded HKCU registration and emits an uninstaller',async(t)=>{
  if(!await exists(setup))return t.skip('Real compiled Setup not present');
  if(process.platform!=='win32')return t.skip('7z.exe NSIS disassembler requires Windows here');
  if(!hasSevenZip())return t.skip('7-Zip not installed');
  const listing=run('7z.exe',['l','-slt',setup]);
  assert.match(listing,/Type = Nsis/);
  for(const entry of ['coco-launcher-2.exe','resources\\ZeroTierOne.msi','MicrosoftEdgeWebview2Setup.exe']){
    assert.ok(listing.includes(entry),`real installer must contain ${entry}`);
  }
  if(!listing.includes('[NSIS].nsi'))return t.skip('this 7-Zip cannot print the NSIS script');
  const script=run('7z.exe',['x','-so',setup,'[NSIS].nsi']);
  assert.match(script,/Name "Coco Launcher 2"/);
  assert.match(script,/WriteUninstaller \$INSTDIR\\uninstall\.exe/,'the installer must write its uninstaller');
  assert.ok(script.includes(`WriteRegStr SHCTX "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Coco Launcher 2" DisplayVersion ${version}`),
    `NSIS uninstall metadata must match signed version ${version}`);
  assert.match(script,/ReadRegStr \$R0 HKCR CocoLauncher2PortablePack\\shell\\open\\command/);
  assert.match(script,/ReadRegStr \$R4 HKCU Software\\Classes\\CocoLauncher2PortablePack\\shell\\open\\command/);
  assert.match(script,/EnumRegValue \$R1 HKCR CocoLauncher2PortablePack 0/);
  assert.match(script,/ReadRegStr \$R2 HKCU Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\\.coco2pack\\UserChoice ProgId/);
  assert.match(script,/ReadRegStr \$R3 HKCU Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\\.coco2pack\\UserChoice Hash/);
  assert.match(script,/WriteRegStr HKCU Software\\Classes\\\.coco2pack\\OpenWithProgids CocoLauncher2PortablePack/);
  assert.match(script,/WriteRegStr HKCU Software\\Classes\\\.coco2pack "" CocoLauncher2PortablePack/);
  assert.match(script,/WriteUninstaller \$INSTDIR\\uninstall\.exe/);
  assert.doesNotMatch(script,/NSIS_HOOK_(?:PRE|POST)(?:INSTALL|UNINSTALL)/);
  assert.doesNotMatch(script,/Software\\Classes\\\.zip\\/);
  if(!script.includes('Coco2PackAssociation')){
    t.diagnostic('REBUILD REQUIRED: signed Setup predates the new ownership checks; compile/sign a new Setup after installer-safe.nsi changes.');
  }else{
    assert.match(script,/EnumRegKey \$R1 HKCR \.coco2pack 0/);
    assert.match(script,/EnumRegValue \$R7 HKCU Software\\Classes\\\.coco2pack\\OpenWithProgids/);
    assert.match(script,/WriteRegStr HKCU Software\\cl\.coco\.launcher2\.preview\\Coco2PackAssociation OpenWithOwner/);
  }
  t.diagnostic('Compiled NSIS installer writes HKCU; /S /D TEMP is NOT an isolated installation.');
});

test('archive contents can be extracted to a fresh TEMP directory without installing',async(t)=>{
  if(!await exists(setup))return t.skip('Real compiled Setup not present');
  if(process.platform!=='win32')return t.skip('7z.exe NSIS extraction requires Windows here');
  if(!hasSevenZip())return t.skip('7-Zip not installed');
  const temp=await mkdtemp(join(tmpdir(),'coco2-v6-nsis-inspect-'));
  try{
    run('7z.exe',['x','-y',`-o${temp}`,setup,'coco-launcher-2.exe',
      'resources\\ZeroTierOne.msi','player\\*','resources\\THIRD_PARTY_VLC.md','resources\\VLC-COPYING.LIB.txt']);
    const payload=await readFile(join(temp,'coco-launcher-2.exe'));
    const compiled=await file('src-tauri/target/release/coco-launcher-2.exe');
    // Tauri patches exactly this 3-byte runtime build-type marker when
    // bundling NSIS; its unbundled executable intentionally says UNK.
    const bundleMarker=Buffer.from('__TAURI_BUNDLE_TYPE_VAR_NSS','ascii');
    const looseMarker=Buffer.from('__TAURI_BUNDLE_TYPE_VAR_UNK','ascii');
    const markerOffset=payload.indexOf(bundleMarker);
    assert.ok(markerOffset>=0,'packaged EXE must identify itself as Tauri NSIS');
    assert.ok(compiled.includes(looseMarker),'loose EXE must carry the expected unbundled Tauri marker');
    assert.equal(payload.indexOf(bundleMarker,markerOffset+1),-1,'unexpected duplicate NSIS marker');
    const normalized=Buffer.from(payload);
    normalized.set(Buffer.from('UNK','ascii'),markerOffset+bundleMarker.length-3);
    assert.equal(sha(normalized),sha(compiled),
      'packed executable differs beyond the 3-byte documented Tauri NSIS marker');
    const bundledMsi=await readFile(join(temp,'resources','ZeroTierOne.msi'));
    const sourceMsi=await file('src-tauri/resources/ZeroTierOne.msi');
    assert.equal(sha(bundledMsi),sha(sourceMsi),'bundled MSI differs from declared source');
    const decoder=JSON.parse(await readFile(source('src-tauri/resources/vlc-runtime-manifest.json'),'utf8'));
    for(const entry of decoder.files){
      const bytes=await readFile(join(temp,'player',...entry.path.split('/')));
      assert.equal(bytes.length,entry.size);assert.equal(sha(bytes),entry.sha256.toUpperCase(),entry.path);
    }
    assert.ok((await readFile(join(temp,'resources','THIRD_PARTY_VLC.md'),'utf8')).includes('videolan.org'));
    t.diagnostic(`Extracted application (${payload.length} B): identical except Tauri NSS/UNK marker (3 B); ZeroTier MSI (${bundledMsi.length} B): SHA256 identical; neither executed`);
  }finally{
    // Only a path created by mkdtemp() in this test is recursively removed.
    await rm(temp,{recursive:true,force:true});
  }
});

test('live silent install/uninstall is blocked until Windows registry is actually isolated',async(t)=>{
  const configNsis=config.bundle.windows.nsis;
  const nsis=await readFile(template,'utf8');
  assert.equal(configNsis.installMode,'currentUser');
  assert.equal(configNsis.installerHooks,undefined,'no additional install hooks permitted');
  assert.equal(configNsis.template,'windows/nsis/installer-safe.nsi');
  assert.deepEqual(config.bundle.fileAssociations.flatMap(x=>x.ext),['coco2pack']);
  assert.match(nsis,/WriteRegStr HKCU "\$\{COCO2PACK_EXTKEY\}\\OpenWithProgids"/);
  assert.match(nsis,/!define COCO2PACK_OWNERSHIP "Software\\\$\{BUNDLEID\}\\Coco2PackAssociation"/);
  assert.match(nsis,/EnumRegKey \$R1 HKCR "\$\{COCO2PACK_EXT\}" 0/);
  assert.match(nsis,/EnumRegValue \$R1 HKCR "\$\{COCO2PACK_EXT\}" 0/);
  assert.match(nsis,/EnumRegValue \$R7 HKCU "\$\{COCO2PACK_EXTKEY\}\\OpenWithProgids" \$R6/);
  assert.match(nsis,/ReadRegStr \$R5 HKCU "\$\{COCO2PACK_OWNERSHIP\}" "OpenWithOwner"/);
  assert.match(nsis,/ReadRegStr \$R5 HKCU "\$\{COCO2PACK_OWNERSHIP\}" "DefaultOwner"/);
  assert.match(nsis,/DeleteRegKey \/ifempty HKCU "Software\\\$\{BUNDLEID\}"/);
  assert.match(nsis,/WriteRegStr SHCTX "\$\{UNINSTKEY\}" "DisplayName"/);
  assert.match(nsis,/!if "\$\{INSTALLMODE\}" != "currentUser"\s+!error/);

  // The uninstaller may only delete its own association when it still owns the
  // exact command; empty-only deletion respects other applications' keys.
  assert.match(nsis,/Function un\.Coco2PackUnregister[\s\S]*?ReadRegStr \$R0 HKCU "\$\{COCO2PACK_CLASS\}\\shell\\open\\command" ""[\s\S]*?\$R0 != [^\n]+\n\s+Return/);
  assert.match(nsis,/Function un\.Coco2PackUnregister[\s\S]*?\$R1 == "\$\{COCO2PACK_PROGID\}"\s+DeleteRegValue HKCU "\$\{COCO2PACK_EXTKEY\}" ""/);
  assert.match(nsis,/DeleteRegKey \/ifempty HKCU "\$\{COCO2PACK_EXTKEY\}"/);
  assert.match(nsis,/\$DeleteAppDataCheckboxState = 1\s+\$\{AndIf\} \$UpdateMode <> 1/);
  assert.match(nsis,/Section Uninstall[\s\S]*?Call un\.Coco2PackUnregister/);
  assert.match(nsis,/Delete "\$INSTDIR\\uninstall\.exe"/);

  t.diagnostic('LIVE INSTALL/UNINSTALL NOT RUN: NSIS changes HKCU, uninstall metadata and shortcuts; TEMP /D does not isolate the user hive or the WebView2 installer.');
});
