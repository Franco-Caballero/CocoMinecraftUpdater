// Offline, non-invasive NSIS checks. The optional makensis probe COMPiles code
// into a disposable EXE; it never executes an installer or modifies the registry.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, mkdtemp, writeFile, rm, access} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join, resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const base=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const scriptPath=resolve(base,'src-tauri/windows/nsis/installer-safe.nsi');
const load=()=>readFile(scriptPath,'utf8');
const block=(source,name)=>{
  const match=source.match(new RegExp(`Function ${name}\\r?\\n([\\s\\S]*?)\\r?\\nFunctionEnd`));
  assert.ok(match,`NSIS function ${name} should exist`);
  return `Function ${name}\n${match[1]}\nFunctionEnd`;
};

test('custom template is an actual Tauri Handlebars installer with the expected NSIS integration',async()=>{
  const [source,configText,schemaText]=await Promise.all([
    load(),
    readFile(resolve(base,'src-tauri/tauri.conf.json'),'utf8'),
    readFile(resolve(base,'node_modules/@tauri-apps/cli/config.schema.json'),'utf8'),
  ]);
  const cfg=JSON.parse(configText);
  const schema=JSON.parse(schemaText);
  assert.ok(schema.definitions.NsisConfig.properties.template,
    'installed Tauri 2 schema must support windows.nsis.template');
  assert.equal(cfg.bundle.windows.nsis.installMode,'currentUser');
  assert.deepEqual(cfg.bundle.fileAssociations.flatMap(x=>x.ext),['coco2pack']);
  for(const token of [
    '{{main_binary_name}}','{{#each resources}}','{{#each binaries}}',
    '{{#each file_associations as |association| ~}}',
    '{{#if installer_hooks}}','Section Install','Section Uninstall',
    'WriteUninstaller', 'NSIS_HOOK_PREINSTALL','NSIS_HOOK_POSTINSTALL',
    'NSIS_HOOK_PREUNINSTALL','NSIS_HOOK_POSTUNINSTALL',
  ]) assert.ok(source.includes(token),`upstream Tauri template contract: ${token}`);
  assert.match(source,/!if "\$\{INSTALLMODE\}" != "currentUser"\s+!error/);
  assert.match(source,/!if "\{\{ext\}\}" != "coco2pack"\s+!error/);
  assert.match(source,/!if "\{\{or association.name ext\}\}" != "\$\{COCO2PACK_PROGID\}"\s+!error/);
});

test('install leaves prior defaults and UserChoice alone, and uses dedicated Open With registration',async()=>{
  const source=await load();
  const installer=block(source,'Coco2PackRegister');
  assert.match(installer,/ReadRegStr \$R0 HKCR "\$\{COCO2PACK_PROGID\}\\shell\\open\\command"/);
  assert.match(installer,/EnumRegValue \$R1 HKCR "\$\{COCO2PACK_PROGID\}" 0/);
  assert.match(installer,/EnumRegKey \$R1 HKCR "\$\{COCO2PACK_PROGID\}" 0/);
  assert.match(installer,/ReadRegStr \$R0 HKCR "\$\{COCO2PACK_EXT\}"/);
  assert.match(installer,/UserChoice" "ProgId"/);
  assert.match(installer,/UserChoice" "Hash"/);
  assert.match(installer,/EnumRegValue \$R1 HKCR "\$\{COCO2PACK_EXT\}" 0/);
  assert.match(installer,/EnumRegKey \$R1 HKCR "\$\{COCO2PACK_EXT\}" 0/);
  assert.match(installer,/EnumRegValue \$R1 HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\\$\{COCO2PACK_EXT\}\\UserChoice" 0/);
  assert.match(installer,/StrCpy \$R8 0/g);
  const priorCheck=installer.indexOf('EnumRegKey $R1 HKCR "${COCO2PACK_EXT}" 0');
  const openWithWrite=installer.indexOf('WriteRegStr HKCU "${COCO2PACK_EXTKEY}\\OpenWithProgids"');
  const conditional=installer.indexOf('${If} $R8 == 1');
  const claim=installer.indexOf('WriteRegStr HKCU "${COCO2PACK_EXTKEY}" "" "${COCO2PACK_PROGID}"');
  assert.ok(priorCheck>0 && priorCheck<openWithWrite && conditional>openWithWrite && claim>conditional,
    'existing keys and UserChoice must be inspected before OpenWith changes; default claim must depend on original state');
  assert.match(installer,/WriteRegStr HKCU "\$\{COCO2PACK_EXTKEY\}\\OpenWithProgids"/);
  assert.match(installer,/coco2_openwith_scan:[\s\S]*?EnumRegValue \$R7 HKCU "\$\{COCO2PACK_EXTKEY\}\\OpenWithProgids" \$R6[\s\S]*?\$R7 == "\$\{COCO2PACK_PROGID\}"[\s\S]*?Goto coco2_openwith_done/);
  assert.match(installer,/WriteRegStr HKCU "\$\{COCO2PACK_OWNERSHIP\}" "OpenWithOwner" "\$INSTDIR\\\$\{MAINBINARYNAME\}\.exe"/);
  assert.match(installer,/WriteRegStr HKCU "\$\{COCO2PACK_OWNERSHIP\}" "DefaultOwner" "\$INSTDIR\\\$\{MAINBINARYNAME\}\.exe"/);
  assert.match(installer,/WriteRegStr HKCU "\$\{COCO2PACK_CLASS\}\\shell\\open\\command" "" "\$\\"\$INSTDIR/);
  assert.doesNotMatch(installer,/WriteReg(?:Str|DWORD) HKCU "[^"]*UserChoice"/);
  assert.doesNotMatch(source,/!insertmacro APP_ASSOCIATE\s/);
  assert.doesNotMatch(source,/!insertmacro APP_UNASSOCIATE\s/);
  assert.doesNotMatch(installer,/WriteReg(?:Str|DWORD) (?:HKLM|HKCR|SHCTX)/);
});

test('uninstall only changes own class when command and ProgID still match',async()=>{
  const source=await load();
  const uninstall=block(source,'un.Coco2PackUnregister');
  const guard=uninstall.indexOf('ReadRegStr $R0 HKCU "${COCO2PACK_CLASS}\\shell\\open\\command" ""');
  const ret=uninstall.indexOf('Return');
  const firstDelete=uninstall.indexOf('DeleteReg');
  assert.ok(guard>=0 && ret>guard && firstDelete>ret,'uninstall must reject changed executable command before any cleanup');
  assert.match(uninstall,/\$R1 == "\$\{COCO2PACK_PROGID\}"/);
  for(const marker of ['DefaultOwner','OpenWithOwner']){
    assert.ok(uninstall.includes('ReadRegStr $R5 HKCU "${COCO2PACK_OWNERSHIP}" "'+marker+'"'),
      `uninstall must verify ${marker} before touching the extension`);
    assert.ok(uninstall.includes('DeleteRegValue HKCU "${COCO2PACK_OWNERSHIP}" "'+marker+'"'),
      `uninstall must release ${marker}`);
  }
  const defaultOwner=uninstall.indexOf('ReadRegStr $R5 HKCU "${COCO2PACK_OWNERSHIP}" "DefaultOwner"');
  const defaultDelete=uninstall.indexOf('DeleteRegValue HKCU "${COCO2PACK_EXTKEY}" ""');
  const openWithOwner=uninstall.indexOf('ReadRegStr $R5 HKCU "${COCO2PACK_OWNERSHIP}" "OpenWithOwner"');
  const openWithDelete=uninstall.indexOf('DeleteRegValue HKCU "${COCO2PACK_EXTKEY}\\OpenWithProgids" "${COCO2PACK_PROGID}"');
  assert.ok(defaultOwner>ret && defaultOwner<defaultDelete && openWithOwner<openWithDelete);
  assert.match(uninstall,/\$R5 == "\$INSTDIR\\\$\{MAINBINARYNAME\}\.exe"/);
  assert.match(uninstall,/ReadRegStr \$R1 HKCU "\$\{COCO2PACK_EXTKEY\}\\OpenWithProgids" "\$\{COCO2PACK_PROGID\}"/);
  assert.match(uninstall,/DeleteRegKey \/ifempty HKCU "\$\{COCO2PACK_OWNERSHIP\}"/);
  assert.match(uninstall,/DeleteRegKey \/ifempty HKCU/);
  assert.doesNotMatch(uninstall,/DeleteRegKey\s+(?!\/ifempty)/);
  assert.doesNotMatch(uninstall,/DeleteReg(?:Key|Value) (?:HKCR|HKLM|SHCTX)/);
  assert.doesNotMatch(source,/Software\\Classes\\\.zip|\\"zip\\"/i);
});

test('NSIS compiles and disassembles current guarded functions offline, without execution',async(t)=>{
  if(process.platform!=='win32') return t.skip('NSIS is only available on Windows');
  const makensis=join(process.env.LOCALAPPDATA??'','tauri','NSIS','makensis.exe');
  try{await access(makensis);}catch{return t.skip('Tauri-bundled NSIS compiler is unavailable');}
  const source=await load();
  const dir=await mkdtemp(join(tmpdir(),'coco2-nsis-check-'));
  try{
    const fixture=[
      'Unicode true',
      '!include "LogicLib.nsh"',
      '!macro UPDATEFILEASSOC',
      '  Nop',
      '!macroend',
      '!define MAINBINARYNAME "CocoLauncher2"',
      '!define PRODUCTNAME "Coco Launcher 2"',
      '!define COCO2PACK_PROGID "CocoLauncher2PortablePack"',
      '!define COCO2PACK_EXT ".coco2pack"',
      '!define COCO2PACK_CLASS "Software\\Classes\\${COCO2PACK_PROGID}"',
      '!define COCO2PACK_EXTKEY "Software\\Classes\\${COCO2PACK_EXT}"',
      '!define COCO2PACK_DESCRIPTION "Coco Launcher 2 portable package"',
      '!define BUNDLEID "cl.coco.launcher2.preview"',
      '!define COCO2PACK_OWNERSHIP "Software\\${BUNDLEID}\\Coco2PackAssociation"',
      'Name "Offline validation"',
      'OutFile "offline-validation.exe"',
      'RequestExecutionLevel user',
      block(source,'Coco2PackRegister'),
      block(source,'un.Coco2PackUnregister'),
      'Section "Install"',
      '  Call Coco2PackRegister',
      '  WriteUninstaller "$INSTDIR\\uninstall.exe"',
      'SectionEnd',
      'Section "Uninstall"',
      '  Call un.Coco2PackUnregister',
      'SectionEnd',
    ].join('\n');
    const file=join(dir,'offline-validation.nsi');
    await writeFile(file,fixture,'utf8');
    const run=spawnSync(makensis,['-V2','-INPUTCHARSET','UTF8',file],
      {cwd:dir,timeout:20000,encoding:'utf8'});
    assert.equal(run.status,0,
      `NSIS compile failed:\n${run.stdout??''}\n${run.stderr??''}\n${run.error?.message??''}`);
    const disassembled=spawnSync('7z.exe',['x','-so',join(dir,'offline-validation.exe'),'[NSIS].nsi'],
      {cwd:dir,timeout:20000,encoding:'utf8',maxBuffer:2*1024*1024,windowsHide:true});
    if(disassembled.error||disassembled.status!==0||!disassembled.stdout?.trim()){
      t.diagnostic('NSIS fixture compiled; this machine cannot print the NSIS script, checks skipped');
    }else{
      assert.equal(disassembled.status,0,`7z NSIS disassembly failed: ${disassembled.stderr??''}`);
      const code=disassembled.stdout;
      for(const pattern of [
        /EnumRegKey \$R1 HKCR \.coco2pack 0/,
        /EnumRegValue \$R1 HKCR \.coco2pack 0/,
        /EnumRegValue \$R7 HKCU Software\\Classes\\\.coco2pack\\OpenWithProgids \$R6/,
        /WriteRegStr HKCU Software\\cl\.coco\.launcher2\.preview\\Coco2PackAssociation DefaultOwner/,
        /WriteRegStr HKCU Software\\cl\.coco\.launcher2\.preview\\Coco2PackAssociation OpenWithOwner/,
        /WriteRegStr HKCU Software\\Classes\\\.coco2pack "" CocoLauncher2PortablePack/,
        /WriteUninstaller \$INSTDIR\\uninstall\.exe/,
      ])assert.match(code,pattern,`compiled NSIS bytecode must preserve ${pattern}`);
      assert.doesNotMatch(code,/WriteRegStr (?:HKCU|HKLM) [^\n]*UserChoice/);
      assert.doesNotMatch(code,/Software\\Classes\\\.zip\\/);
      const extracted=spawnSync('7z.exe',['x','-y',`-o${dir}`,join(dir,'offline-validation.exe'),'uninstall.exe'],
        {cwd:dir,timeout:20000,encoding:'utf8',maxBuffer:2*1024*1024,windowsHide:true});
      assert.equal(extracted.status,0,`7z extract uninstaller failed: ${extracted.stdout??''} ${extracted.stderr??''}`);
      const unScript=spawnSync('7z.exe',['x','-so',join(dir,'uninstall.exe'),'[NSIS].nsi'],
        {cwd:dir,timeout:20000,encoding:'utf8',maxBuffer:2*1024*1024,windowsHide:true});
      assert.equal(unScript.status,0,`7z disassemble uninstaller failed: ${unScript.stdout??''} ${unScript.stderr??''}`);
      for(const pattern of [
        /ReadRegStr \$R5 HKCU Software\\cl\.coco\.launcher2\.preview\\Coco2PackAssociation DefaultOwner/,
        /ReadRegStr \$R5 HKCU Software\\cl\.coco\.launcher2\.preview\\Coco2PackAssociation OpenWithOwner/,
        /DeleteRegValue HKCU Software\\Classes\\\.coco2pack\\OpenWithProgids CocoLauncher2PortablePack/,
        /DeleteRegKey \/ifempty HKCU Software\\Classes\\\.coco2pack/,
      ])assert.match(unScript.stdout,pattern,`uninstaller NSIS bytecode must preserve ${pattern}`);
    }
  }finally{
    await rm(dir,{recursive:true,force:true});
  }
});
