/**
 * Read-only offline E2E of the *built* Coco2 NSIS release. The Setup is never
 * executed: 7-Zip only lists, disassembles and extracts two named payloads.
 * Windows Explorer, HKCU, games, ZeroTier and installed Coco are untouched.
 * Every write is confined to a unique mkdtemp-owned test directory.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {copyFile, lstat, mkdir, mkdtemp, open, readFile, rm, stat, unlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {basename, dirname, join, resolve, sep} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const fromDesktop=path=>resolve(desktop,path);
// The release builder can check its immutable, signed candidate BEFORE
// replacing the previously verified public installer. This opt-in applies
// only to this read-only test and must stay inside our publish-ready tree.
const candidateOverride=process.env.COCO2_QA_SETUP_CANDIDATE;
const candidateRoot=fromDesktop('../dist/publish-ready');
const setup=candidateOverride?resolve(candidateOverride):fromDesktop('../dist/CocoLauncher2-Setup.exe');
if(candidateOverride){
  assert.ok(setup.toLowerCase().startsWith((candidateRoot+sep).toLowerCase()),
    'candidate test override must stay inside Coco2 publish-ready');
  assert.match(basename(setup),/^CocoLauncher2_\d+\.\d+\.\d+_x64-setup\.exe$/);
}
const compiledExe=fromDesktop('src-tauri/target/release/coco-launcher-2.exe');
const trustedMsi=fromDesktop('src-tauri/resources/ZeroTierOne.msi');
const mainName='coco-launcher-2.exe';
const msiName='resources\\ZeroTierOne.msi';
const markerNss=Buffer.from('__TAURI_BUNDLE_TYPE_VAR_NSS','ascii');
const markerUnk=Buffer.from('__TAURI_BUNDLE_TYPE_VAR_UNK','ascii');
const digest=bytes=>createHash('sha256').update(bytes).digest('hex').toUpperCase();
const exists=async path=>stat(path).then(s=>s.isFile()).catch(()=>false);

// Any 7-Zip works; only some builds can also print the NSIS script, and those checks are skipped otherwise.
const hasSevenZip=()=>spawnSync('7z.exe',['i'],{windowsHide:true}).error===undefined;

function run(command,args,{env=process.env,maxBuffer=2*1024*1024}={}){
  // No shell or untrusted command interpolation; executable names are fixed.
  assert.ok(['7z.exe','powershell.exe'].includes(command));
  const result=spawnSync(command,args,{
    cwd:desktop,env,encoding:'utf8',maxBuffer,timeout:60_000,
    windowsHide:true,shell:false,
  });
  assert.equal(result.error,undefined,`${command}: ${result.error?.message}`);
  assert.equal(result.status,0,`${command} failed (exit ${result.status}):\n${result.stderr}\n${result.stdout?.slice(-3000)}`);
  return result.stdout;
}

function checkArchiveListing(listing){
  assert.match(listing,/^Type = Nsis\s*$/m,'the input must be an NSIS archive');
  const paths=[...listing.matchAll(/^Path = (.+)\r?$/gm)].map(match=>match[1]);
  // Only two constant, relative paths will be handed to the extractor. Do
  // not extract * or let archive-supplied names decide filesystem targets.
  for(const path of [mainName,msiName]){
    assert.equal(paths.filter(name=>name===path).length,1,`required unique NSIS entry: ${path}`);
  }
}

async function checkedRegularFile(file,root){
  const absolute=resolve(file);
  assert.ok(absolute.startsWith(resolve(root)+'\\'),`file escapes test temp: ${absolute}`);
  const info=await lstat(absolute);
  assert.ok(info.isFile()&&!info.isSymbolicLink(),`${basename(file)} is not a regular file`);
  return readFile(absolute);
}

async function verifyPayload(directory,expected){
  const exe=await checkedRegularFile(join(directory,mainName),directory);
  const msi=await checkedRegularFile(join(directory,'resources','ZeroTierOne.msi'),directory);
  assert.equal(exe.length,expected.compiled.length,'bundled app has unexpected byte length');
  assert.equal(msi.length,expected.msi.length,'bundled ZeroTier has unexpected byte length');
  assert.equal(digest(msi),expected.msiHash,'bundled ZeroTier MSI is not the trusted source bytes');

  // Tauri NSIS bundling changes only the three-character UNK -> NSS marker.
  // Exact SHA256 of the normalized binary proves no other release-time edits.
  const offset=exe.indexOf(markerNss);
  assert.ok(offset>=0,'bundled EXE has no Tauri NSS marker');
  assert.equal(exe.indexOf(markerNss,offset+1),-1,'duplicate NSS marker');
  assert.equal(expected.compiled.indexOf(markerUnk,0),offset,'unbundled Tauri marker differs');
  assert.equal(expected.compiled.indexOf(markerUnk,offset+1),-1,'duplicate UNK marker');
  const normalized=Buffer.from(exe);
  markerUnk.copy(normalized,offset);
  assert.equal(digest(normalized),expected.exeHash,
    'bundled EXE differs from built Rust binary beyond the three-byte Tauri marker');
  // These are native runtime strings in the compiled payload (not only source).
  assert.ok(exe.includes(Buffer.from('coco2://package-open-request')),
    'bundled EXE lacks native activation event');
  assert.ok(exe.includes(Buffer.from('.coco2pack')),
    'bundled EXE lacks canonical portable extension');
  return {exeBytes:exe.length,exeHash:digest(exe),msiBytes:msi.length,msiHash:digest(msi)};
}

function verifyCompiledNsi(script,config){
  assert.match(config.version,/^\d+\.\d+\.\d+$/);
  assert.equal(config.productName,'Coco Launcher 2');
  assert.equal(config.bundle.windows.nsis.installMode,'currentUser');
  assert.deepEqual(config.bundle.fileAssociations.flatMap(item=>item.ext),['coco2pack']);
  assert.deepEqual(config.bundle.resources,['resources/ZeroTierOne.msi','resources/THIRD_PARTY_VLC.md','resources/VLC-COPYING.LIB.txt']);
  // 7-Zip disassembles native NSIS opcodes, not the preprocessor source:
  // VIProductVersion and named functions are absent in its output. Check
  // observed machine operations here; VERSIONINFO is checked via Win32 below.
  assert.ok(script.includes('Name "Coco Launcher 2"'));
  assert.ok(script.includes('WriteUninstaller $INSTDIR\\uninstall.exe'));
  assert.ok(script.includes(`DisplayVersion ${config.version}`));
  assert.ok(script.includes(String.raw`ReadRegStr $R0 HKCR CocoLauncher2PortablePack\shell\open\command ""`));
  assert.ok(script.includes(String.raw`WriteRegStr HKCU Software\Classes\.coco2pack\OpenWithProgids CocoLauncher2PortablePack ""`),
    'registration for the dedicated Open With ProgID is absent');
  assert.ok(script.includes(String.raw`WriteRegStr HKCU Software\Classes\CocoLauncher2PortablePack\shell\open\command "" "$\"$INSTDIR\coco-launcher-2.exe$\" $\"%1$\""`),
    'Explorer must pass the quoted package path as the only startup argument');
  assert.ok(script.includes(String.raw`ReadRegStr $R2 HKCU Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.coco2pack\UserChoice ProgId`),
    'installer must inspect an existing UserChoice');
  assert.doesNotMatch(script,/WriteReg(?:Str|DWORD)\s+\w+\s+[^\r\n]*\\\.zip(?:\\|\s|$)/i,
    'a generic ZIP association would hijack other user files');
  assert.doesNotMatch(script,/Software\\Classes\\\.zip(?:\\|\s|$)/i);
}

async function verifyNativeWiring(){
  const [main,activation]=await Promise.all([
    readFile(fromDesktop('src-tauri/src/lib.rs'),'utf8'),
    readFile(fromDesktop('src-tauri/src/services/activation.rs'),'utf8'),
  ]);
  const entry=main.indexOf('services::activation::start_or_handoff()');
  const window=main.indexOf('tauri::Builder::default()');
  assert.ok(entry>=0&&window>entry,'native path handling must precede window creation');
  assert.match(main,/services::activation::attach_app\(app\.handle\(\)\)/);
  assert.match(main,/services::activation::take_pending_package_open_requests/);
  assert.match(activation,/start_with\(parse\(std::env::args_os\(\)\.skip\(1\),"cold"\)\?,None\)/);
  assert.match(activation,/lower\.ends_with\("\.coco2pack"\)\s*\|\|\s*lower\.ends_with\("\.coco2pack\.zip"\)/);
  assert.match(activation,/if !path\.is_absolute\(\)\|\|!has_extension\(&path\)/);
  assert.match(activation,/pub const PACKAGE_OPEN_EVENT:&str="coco2:\/\/package-open-request"/);
}

function getWindowsVersionInfo(exe){
  // PowerShell only reads Win32 VERSIONINFO on a verified EXE; it does not
  // execute the EXE. Path arrives in an environment variable, never script.
  const code=`$p=[Environment]::GetEnvironmentVariable('COCO2_QA_EXTRACTED_EXE'); $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($p); [ordered]@{ProductName=$v.ProductName;FileDescription=$v.FileDescription;ProductVersion=$v.ProductVersion;FileVersion=$v.FileVersion} | ConvertTo-Json -Compress`;
  return JSON.parse(run('powershell.exe',['-NoProfile','-NonInteractive','-Command',code],{
    env:{...process.env,COCO2_QA_EXTRACTED_EXE:exe},
  }));
}

async function flipByte(file,offset){
  const handle=await open(file,'r+');
  try{
    const one=Buffer.alloc(1);
    assert.equal((await handle.read(one,0,1,offset)).bytesRead,1);
    one[0]^=0x01;
    assert.equal((await handle.write(one,0,1,offset)).bytesWritten,1);
  }finally{await handle.close();}
}

test('NSIS configured version: extracted payload identity, native file-open wiring and adversarial tampering',
  {timeout:120_000},async t=>{
    if(process.platform!=='win32')return t.skip('Windows NSIS extraction and VERSIONINFO only');
    if(!hasSevenZip())return t.skip('7-Zip not installed');
    if(!await exists(setup)||!await exists(compiledExe)||!await exists(trustedMsi)){
      return t.skip('compiled Setup, corresponding unbundled EXE and original MSI are all required');
    }
    const temp=await mkdtemp(join(tmpdir(),'coco2-v6-extracted-qa-'));
    // Assert cleanup ownership before any recursive remove, even on failure.
    assert.equal(dirname(temp).toLowerCase(),resolve(tmpdir()).toLowerCase());
    assert.match(basename(temp),/^coco2-v6-extracted-qa-[A-Za-z0-9]+$/);
    try{
      const [compiled,msi,config,networkSource]=await Promise.all([
        readFile(compiledExe),readFile(trustedMsi),
        readFile(fromDesktop('src-tauri/tauri.conf.json'),'utf8').then(JSON.parse),
        readFile(fromDesktop('src-tauri/src/services/network.rs'),'utf8'),
      ]);
      const expected={compiled,exeHash:digest(compiled),msi,msiHash:digest(msi)};
      const pinned=networkSource.match(/const INSTALLER_SHA256:\s*&str\s*=\s*"([0-9a-f]{64})"/);
      assert.ok(pinned,'network installer lacks a pinned SHA256');
      assert.equal(expected.msiHash,pinned[1].toUpperCase(),'ZeroTier source does not match network.rs pin');

      const listing=run('7z.exe',['l','-slt',setup]);
      checkArchiveListing(listing);
      if(listing.includes('[NSIS].nsi')){
        const script=run('7z.exe',['x','-so',setup,'[NSIS].nsi']);
        const normalizedScript=script.replace(/\r/g,'').trim();
        await t.test('compiled NSIS registers only .coco2pack with quoted %1 and preserves existing defaults',()=>{
          verifyCompiledNsi(normalizedScript,config);
        });
      }else t.diagnostic('this 7-Zip cannot print the NSIS script; script checks skipped');
      await t.test('native CLI parsing and primary UI handoff are wired',verifyNativeWiring);

      const extracted=join(temp,'payload');
      await mkdir(extracted);
      run('7z.exe',['x','-y',`-o${extracted}`,setup,mainName,msiName]);
      const verified=await verifyPayload(extracted,expected);
      const vi=getWindowsVersionInfo(join(extracted,mainName));
      for(const field of ['ProductName','FileDescription'])assert.equal(vi[field],config.productName);
      for(const field of ['ProductVersion','FileVersion'])assert.equal(vi[field],config.version);
      t.diagnostic(`REAL extraction: Setup ${(await stat(setup)).size} B, app ${verified.exeBytes} B SHA256 ${verified.exeHash}, ZeroTier ${verified.msiBytes} B SHA256 ${verified.msiHash}; VERSIONINFO ${vi.ProductName} ${vi.ProductVersion}; NO INSTALL/EXEC`);

      // Mutations happen only to disposable copies inside this test's temp.
      const attack=join(temp,'tampered');
      await mkdir(join(attack,'resources'),{recursive:true});
      const badExe=join(attack,mainName);
      const badMsi=join(attack,'resources','ZeroTierOne.msi');
      const restore=()=>Promise.all([
        copyFile(join(extracted,mainName),badExe),
        copyFile(join(extracted,'resources','ZeroTierOne.msi'),badMsi),
      ]);
      await t.test('rejects one-bit patch in the packaged PE beyond the bundle marker',async()=>{
        await restore();
        await flipByte(badExe,1024);
        await assert.rejects(verifyPayload(attack,expected),/bundled EXE differs/);
      });
      await t.test('rejects tampered ZeroTier MSI even when size is unchanged',async()=>{
        await restore();
        await flipByte(badMsi,4096);
        await assert.rejects(verifyPayload(attack,expected),/bundled ZeroTier MSI is not/);
      });
      await t.test('rejects corruption of the required NSIS marker',async()=>{
        await restore();
        const payload=await readFile(badExe);
        await flipByte(badExe,payload.indexOf(markerNss)+markerNss.length-1);
        await assert.rejects(verifyPayload(attack,expected),/bundled EXE has no Tauri NSS marker/);
      });
      await t.test('rejects missing or substituted resource without touching trusted MSI',async()=>{
        await restore();
        await unlink(badMsi);
        await assert.rejects(verifyPayload(attack,expected),/ENOENT/);
        await copyFile(badExe,badMsi);
        await assert.rejects(verifyPayload(attack,expected),/bundled ZeroTier has unexpected byte length/);
      });
    }finally{
      assert.equal(dirname(temp).toLowerCase(),resolve(tmpdir()).toLowerCase());
      await rm(temp,{recursive:true,force:true});
    }
  });
