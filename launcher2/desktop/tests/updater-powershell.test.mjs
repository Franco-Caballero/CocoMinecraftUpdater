import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';

const scriptRoot = resolve(import.meta.dirname, '../scripts');
const feedScript = join(scriptRoot, 'New-Coco2UpdateFeed.ps1');
const keyScript = join(scriptRoot, 'Configure-Coco2Updater.ps1');
const ps = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';

function invoke(script, args = [], env = process.env) {
  return spawnSync(ps, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, ...args], {
    encoding: 'utf8', timeout: 60_000, env,
  });
}

function temporary(testContext) {
  const dir = mkdtempSync(join(tmpdir(), 'coco2-updater-test-'));
  testContext.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function fixture(root, version = '0.2.0') {
  const exeName = `Coco Launcher 2_${version}_x64-setup.exe`;
  const exe = join(root, exeName);
  writeFileSync(exe, Buffer.concat([Buffer.from('MZ'), Buffer.alloc(500)]));
  const signature = Buffer.from(`untrusted comment: fake offline fixture\n${'A'.repeat(180)}`).toString('base64');
  writeFileSync(exe + '.sig', signature + '\n');
  const config = join(root, 'tauri.conf.json');
  writeFileSync(config, JSON.stringify({ version, bundle: { createUpdaterArtifacts: true } }));
  const url = `https://github.com/Owner/Repo/releases/download/v${version}/${encodeURIComponent(exeName)}`;
  return { exe, config, url, signature };
}

test('feed: offline exact NSIS sidecar + HTTPS GitHub URL, reproducible JSON', (t) => {
  const root = temporary(t);
  const { exe, config, url, signature } = fixture(root);
  const dest = join(root, 'latest.json');
  const args = ['-InstallerPath', exe, '-TauriConfigPath', config, '-Version', '0.2.0', '-DownloadUrl', url, '-OutputPath', dest];
  const result = invoke(feedScript, args);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const doc = JSON.parse(readFileSync(dest, 'utf8'));
  assert.deepEqual(doc.platforms['windows-x86_64'], { signature, url });
  assert.equal(doc.version, '0.2.0');
  assert.ok(!readFileSync(dest, 'utf8').startsWith('\ufeff'), 'no UTF-8 BOM');
  assert.ok(!result.stdout.includes(signature), 'do not log entire signature');
  assert.equal(invoke(feedScript, args).status, 1, 'existing feed is not silently overwritten');
});

test('feed: rejects mismatch, signature alias, unsigned bundle and insecure URLs', (t) => {
  const root = temporary(t);
  const { exe, config, url } = fixture(root);
  const prefix = ['-InstallerPath', exe, '-TauriConfigPath', config, '-Version', '0.2.0', '-OutputPath', join(root, 'latest.json')];
  const bad = [
    ['-DownloadUrl', url.replace('/v0.2.0/', '/v0.3.0/')],
    ['-DownloadUrl', url.replace('https:', 'http:')],
    ['-DownloadUrl', url.replace('github.com', 'evil.example')],
    ['-DownloadUrl', url.replace('setup.exe', 'other-setup.exe')],
    ['-DownloadUrl', url + '?redirect=https://evil.example'],
    ['-DownloadUrl', url, '-SignaturePath', join(root, 'wrong.sig')],
    ['-DownloadUrl', url, '-Version', '0.2.1'],
  ];
  for (const args of bad) {
    const result = invoke(feedScript, [...prefix, ...args]);
    assert.notEqual(result.status, 0, `${args.join(' ')} should fail`);
  }
  assert.ok(!existsSync(join(root, 'latest.json')));
  const configObj = JSON.parse(readFileSync(config));
  delete configObj.bundle.createUpdaterArtifacts;
  writeFileSync(config, JSON.stringify(configObj));
  assert.notEqual(invoke(feedScript, [...prefix, '-DownloadUrl', url]).status, 0);
});

test('signing: mock Tauri CLI, private key DPAPI vault, idempotent and no secret output', { skip: process.platform !== 'win32' }, (t) => {
  const root = temporary(t);
  const local = join(root, 'local');
  mkdirSync(local);
  const signer = join(root, 'fake-tauri.cmd');
  const mockSecret = 'TEST_PRIVATE_KEY_' + 'not-a-real-secret-but-should-never-appear'.repeat(4);
  const publicKey = 'PUBLIC_TEST_KEY_' + 'A'.repeat(75);
  writeFileSync(signer,
    `@echo off\r\nif not "%1"=="signer" exit /b 10\r\nif not "%2"=="generate" exit /b 11\r\n>"%5" echo ${mockSecret}\r\n>"%5.pub" echo ${publicKey}\r\nexit /b 0\r\n`);
  const env = { ...process.env, LOCALAPPDATA: local };
  const args = ['-TauriCliPath', signer];
  const first = invoke(keyScript, args, env);
  assert.equal(first.status, 0, first.stderr + first.stdout);
  assert.ok(first.stdout.includes('Clave publica'));
  assert.ok(!first.stdout.includes(mockSecret));
  const signing = join(local, 'CocoLauncher2', 'signing');
  const vault = join(signing, 'private-key.dpapi');
  assert.ok(existsSync(vault));
  assert.ok(!readFileSync(vault).includes(Buffer.from(mockSecret)));
  assert.ok(!readFileSync(vault).toString('latin1').includes(mockSecret));
  assert.equal(readFileSync(join(signing, 'public-key.pub'), 'utf8').trim(), publicKey);
  assert.equal(statSync(vault).size > 80, true);
  assert.deepEqual(readFileSync(vault), readFileSync(vault));
  const before = readFileSync(vault);
  const second = invoke(keyScript, ['-TauriCliPath', join(root, 'nonexistent.cmd')], env);
  assert.equal(second.status, 0, second.stderr + second.stdout);
  assert.deepEqual(readFileSync(vault), before, 'reuse key, do not rotate');
  const build = join(root, 'mock-build.ps1');
  const buildOutput = join(root, 'build-status.txt');
  writeFileSync(build, `if ([string]::IsNullOrEmpty($env:TAURI_SIGNING_PRIVATE_KEY)) { throw 'missing private key' }\n[IO.File]::WriteAllText('${buildOutput.replaceAll('\\', '\\\\')}', 'signing-env-present')\n`);
  const signed = invoke(keyScript, [...args, '-RunBuild', '-BuildScript', build], env);
  assert.equal(signed.status, 0, signed.stderr + signed.stdout);
  assert.equal(readFileSync(buildOutput, 'utf8'), 'signing-env-present');
  assert.ok(!signed.stdout.includes(mockSecret));
});
