import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname,resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=name=>readFile(resolve(desktop,name),'utf8');

test('current release metadata is coherent without changing dependency locks or update signing policy',async()=>{
  const [p,l,config,toml,lock]=await Promise.all([
    read('package.json').then(JSON.parse),read('package-lock.json').then(JSON.parse),
    read('src-tauri/tauri.conf.json').then(JSON.parse),
    read('src-tauri/Cargo.toml'),read('src-tauri/Cargo.lock'),
  ]);
  for(const v of [l.version,l.packages[''].version,config.version])assert.equal(v,p.version);
  assert.match(p.version,/^\d+\.\d+\.\d+$/);
  assert.ok(toml.includes(`version = "${p.version}"`));
  assert.match(lock,new RegExp(`\\[\\[package\\]\\]\\s*name = "coco-launcher-2"\\s*version = "${p.version.replaceAll('.','\\.') }"`));
  assert.equal(config.plugins.updater.requireSignedVersion,true);
  assert.deepEqual(config.bundle.fileAssociations.flatMap(x=>x.ext),['coco2pack']);
  assert.equal(config.bundle.windows.nsis.installMode,'currentUser');
});

test('release builder validates signed candidate NSIS before replacing prior verified Setup',async()=>{
  const [build,qa]=await Promise.all([
    read('scripts/Build-CocoLauncher2.ps1'),
    read('tests/installed-release-synthetic-v6.test.mjs'),
  ]);
  assert.match(build,/\$artifactTests=@\('installed-nsis-v6\.test\.mjs','installed-release-synthetic-v6\.test\.mjs'\)/);
  assert.match(build,/\$sourceTests=@\(Get-ChildItem/);
  assert.match(build,/Invoke-Checked 'node\.exe' \$testArgs/);
  assert.match(build,/\$env:COCO2_QA_SETUP_CANDIDATE=\$candidateExe/);
  assert.match(build,/Remove-Item Env:COCO2_QA_SETUP_CANDIDATE/);
  const verify=build.indexOf("Verify-Coco2SignedSetup.mjs'),$candidateExe");
  const candidateE2e=build.indexOf('$env:COCO2_QA_SETUP_CANDIDATE=$candidateExe');
  const promote=build.indexOf('[IO.File]::Replace($stage,$destination,$backup,$true)');
  const postPromote=build.indexOf("tests\\installed-nsis-v6.test.mjs");
  const markedSuccessful=build.indexOf('$promoted=$true');
  assert.ok(verify>0&&candidateE2e>verify&&promote>candidateE2e);
  assert.ok(postPromote>promote&&markedSuccessful>postPromote,'post-promotion QA must trigger rollback on failure');
  assert.match(qa,/candidateOverride\?resolve\(candidateOverride\):fromDesktop/);
  assert.match(qa,/startsWith\(\(candidateRoot\+sep\)\.toLowerCase\(\)\)/);
  assert.match(build,/\$hadSetup=Test-Path/);
  assert.match(build,/\$hadSig=Test-Path/);
  assert.match(build,/if\(\$promoted -or \$rolledBack\)/);
  assert.match(build,/\[IO\.File\]::Replace\(\$backup,\$destination,\$rejected,\$true\)/);
  assert.match(build,/\[IO\.File\]::Replace\(\$backupSig,\(\$destination\+'\.sig'\),\$rejectedSig,\$true\)/);
  assert.doesNotMatch(build,/\[IO\.File\]::Replace\([^\r\n]+,\$null,\$true\)/);
  assert.doesNotMatch(build,/git clean|git reset|Remove-Item.*(?:CocoMinecraft|SouthWind).*Recurse/i);
});

test('Windows rollback restores previous bytes using an owned backup path, not a null argument',async t=>{
  if(process.platform!=='win32')return t.skip('Windows File.Replace needs an isolated TEMP fixture');
  const path=await mkdtemp(join(tmpdir(),'coco2-release-rollback-v11-'));
  try{
    assert.equal(dirname(path).toLowerCase(),resolve(tmpdir()).toLowerCase());
    const destination=join(path,'Coco simulated Setup.exe');
    const stage=join(path,'firma nueva.exe');
    const backup=join(path,'guardado anterior.exe');
    const rejected=join(path,'candidato rechazado.exe');
    await writeFile(destination,'signed-previous-installer');
    await writeFile(stage,'signed-new-installer');
    const q=p=>`'${p.replaceAll("'","''")}'`;
    const command=`[IO.File]::Replace(${q(stage)},${q(destination)},${q(backup)},$true); [IO.File]::Replace(${q(backup)},${q(destination)},${q(rejected)},$true)`;
    const executed=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],
      {encoding:'utf8',windowsHide:true,timeout:15_000});
    assert.equal(executed.status,0,executed.stderr||executed.stdout);
    assert.equal(await readFile(destination,'utf8'),'signed-previous-installer');
    assert.equal(await readFile(rejected,'utf8'),'signed-new-installer');
  }finally{await rm(path,{recursive:true,force:true});}
});
