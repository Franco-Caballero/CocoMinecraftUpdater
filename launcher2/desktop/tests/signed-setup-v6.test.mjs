import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const get=p=>readFile(resolve(root,p),'utf8');

test('release pipeline cryptographically validates exact signed bytes and trusted feed',async()=>{
  const [script,build]=await Promise.all([
    get('scripts/Verify-Coco2SignedSetup.mjs'),
    get('scripts/Build-CocoLauncher2.ps1'),
  ]);
  assert.match(script,/createPublicKey/);
  assert.match(script,/createHash\('blake2b512'\)/);
  assert.match(script,/verify\(null,prehash,key,payloadSignature\)/);
  assert.match(script,/verify\(null,commentSignedBytes,key,commentSignature\)/);
  assert.match(script,/tampered\[0\]\^=1/);
  assert.match(script,/feed\.version!==config\.version\|\|item\?\.signature!==encodedSignature/);
  assert.match(script,/sha\(candidateBytes\)!==digest\|\|candidateSignature!==encodedSignature/);
  assert.match(build,/Invoke-Checked 'node\.exe' @\(\(Join-Path \$PSScriptRoot 'Verify-Coco2SignedSetup\.mjs'\),\$candidateExe\)/);
  assert.match(build,/\[IO\.File\]::Replace\(\$stage,\$destination,\$backup,\$true\)/);
  assert.match(build,/\$promoted=\$true/);
  assert.doesNotMatch(script,/TAURI_SIGNING_PRIVATE_KEY|exec\(|spawn\(|Invoke-WebRequest/);
});

test('only SHA-identical intermediate installer copies are removed after signed promotion',async()=>{
  const build=await get('scripts/Build-CocoLauncher2.ps1');
  const verified=build.indexOf("Verify-Coco2SignedSetup.mjs");
  const cleanup=build.indexOf('$oldNsis=@(');
  assert.ok(verified>0&&cleanup>verified);
  assert.ok(build.indexOf('Copy-Item -LiteralPath $candidateExe -Destination $stage')>verified);
  assert.match(build,/\$intermediates=@\(\$source\.FullName,\$signatureSource\)/);
  assert.match(build,/\$candidatePair=@\(\$candidateExe,\$candidateSig\)/);
  assert.match(build,/\$promotedPair=@\(\$destination,\(\$destination\+'\.sig'\)\)/);
  assert.match(build,/\$sameLength=/);
  assert.match(build,/Get-FileHash -LiteralPath \$intermediate\.FullName -Algorithm SHA256/);
  assert.match(build,/Get-FileHash -LiteralPath \$retained\.FullName -Algorithm SHA256/);
  assert.doesNotMatch(build,/\$Matches\[1\] -ne \[string\]\$config\.version/);
  assert.match(build,/\.Attributes -band \[IO\.FileAttributes\]::ReparsePoint/);
  assert.match(build,/Remove-Item -LiteralPath \$old\.FullName -Force/);
  assert.doesNotMatch(build,/git clean|Remove-Item -LiteralPath \$distribution -Recurse/);
});
