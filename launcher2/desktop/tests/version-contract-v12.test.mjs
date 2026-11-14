import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(root,name),'utf8');

test('the release carries one new version everywhere, without reusing SemVer',async()=>{
  const [packageJson,packageLock,tauri,cargo,cargoLock]=await Promise.all([
    read('package.json').then(JSON.parse),
    read('package-lock.json').then(JSON.parse),
    read('src-tauri/tauri.conf.json').then(JSON.parse),
    read('src-tauri/Cargo.toml'),read('src-tauri/Cargo.lock'),
  ]);
  assert.equal(packageJson.version,'0.6.57');
  assert.equal(packageLock.version,packageJson.version);
  assert.equal(packageLock.packages[''].version,packageJson.version);
  assert.equal(tauri.version,packageJson.version);
  assert.match(cargo,/\[package\]\s*name = "coco-launcher-2"\s*version = "0.6.57"/);
  assert.match(cargoLock,/\[\[package\]\]\s*name = "coco-launcher-2"\s*version = "0.6.57"/);
  assert.equal(tauri.plugins.updater.requireSignedVersion,true);
  assert.equal(tauri.bundle.windows.nsis.installMode,'currentUser');
  assert.deepEqual(tauri.bundle.fileAssociations.flatMap(a=>a.ext),['coco2pack']);
});

test('release promotion validates exact candidate signed bytes and extracted NSIS before touching public installer',async()=>{
  const [builder,verifier,nsis]=await Promise.all([
    read('scripts/Build-CocoLauncher2.ps1'),
    read('scripts/Verify-Coco2SignedSetup.mjs'),
    read('src-tauri/windows/nsis/installer-safe.nsi'),
  ]);
  const sourceTest=builder.indexOf("$artifactTests=@('installed-nsis-v6.test.mjs'");
  const build=builder.indexOf("Invoke-Checked 'npm.cmd' @('run','tauri','build'");
  const verify=builder.indexOf("'Verify-Coco2SignedSetup.mjs'),$candidateExe");
  const qa=builder.indexOf('$env:COCO2_QA_SETUP_CANDIDATE=$candidateExe');
  const replace=builder.indexOf('[IO.File]::Replace($stage,$destination,$backup,$true)');
  const after=builder.indexOf("'Verify-Coco2SignedSetup.mjs'))",replace);
  assert.ok(sourceTest>=0&&build>sourceTest&&verify>build&&qa>verify&&replace>qa&&after>replace);
  assert.match(builder,/\[IO\.File\]::Replace\(\$backup,\$destination,\$rejected,\$true\)/);
  assert.doesNotMatch(builder,/\[IO\.File\]::Replace\([^\r\n]+,\$null,\$true\)/);
  assert.match(verifier,/verify\(null,prehash,key,payloadSignature\)/);
  assert.match(verifier,/verify\(null,commentSignedBytes,key,commentSignature\)/);
  assert.match(nsis,/!if "\$\{INSTALLMODE\}" != "currentUser"/);
  assert.match(nsis,/!if "\{\{ext\}\}" != "coco2pack"/);
  assert.doesNotMatch(nsis,/!insertmacro APP_ASSOCIATE\s/);
});
