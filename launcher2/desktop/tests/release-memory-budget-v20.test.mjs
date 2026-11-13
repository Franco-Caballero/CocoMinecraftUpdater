import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const dir=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const builder=await readFile(resolve(dir,'scripts/Build-CocoLauncher2.ps1'),'utf8');

test('single Release build automatically caps Rust jobs when memory is limited, preserving explicit overrides',()=>{
  assert.match(builder,/function Get-SafeCargoJobs\(/);
  assert.match(builder,/if\s*\(-not\s+\$env:CARGO_BUILD_JOBS\)/);
  assert.match(builder,/Get-SafeCargoJobs\s+\$memoryBytes\s+\$logicalCores/);
  assert.match(builder,/CARGO_BUILD_JOBS.*(?:invalid|inválid|positiv)/i);
  assert.ok(builder.indexOf('Get-SafeCargoJobs $memoryBytes $logicalCores')<
    builder.indexOf("Invoke-Checked 'npm.cmd' @('run','tauri','build'"),
  'job cap must take effect before Tauri launches Cargo');
});

test('PowerShell 5.1 build budget scales from 2 jobs on 16 GiB/16 cores to at most 4 on high-memory builders',()=>{
  const helper=builder.match(/^function Get-SafeCargoJobs\([^\n]+\)\s*\{[\s\S]*?^\}/m)?.[0];
  assert.ok(helper,'standalone deterministic helper required for a read-only test');
  if(process.platform!=='win32')return;
  const code=`${helper}\n@((Get-SafeCargoJobs 16GB 16),(Get-SafeCargoJobs 32GB 16),(Get-SafeCargoJobs 64GB 16),(Get-SafeCargoJobs 64GB 2),(Get-SafeCargoJobs 0 0))|ConvertTo-Json -Compress`;
  const run=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',code],{
    cwd:dir,windowsHide:true,encoding:'utf8',timeout:15000,
  });
  assert.equal(run.status,0,run.stderr||run.error?.message);
  assert.deepEqual(JSON.parse(run.stdout.trim()),[2,2,4,2,1]);
});
