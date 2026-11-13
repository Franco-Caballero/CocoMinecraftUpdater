// Offline tests only. Never downloads or installs ZeroTier or changes services.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';

const root = resolve(import.meta.dirname, '../src-tauri');
const script = resolve(import.meta.dirname, '../scripts/Get-Coco2ZeroTierMsi.ps1');
const configPath = join(root, 'tauri.conf.json');
const networkPath = join(root, 'src/services/network.rs');
const nativeInstallerPath = join(root, 'src/services/network_installer.rs');
const url = 'https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi';
const sha = '42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670';
const ps = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';

function temporary(t) {
  const dir = mkdtempSync(join(tmpdir(), 'coco2-zt-msi-offline-'));
  t.after(() => rmSync(dir, { force: true, recursive: true }));
  return dir;
}

function runPs(args) {
  return spawnSync(ps, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', script, ...args], { encoding: 'utf8', timeout: 20_000 });
}

test('bundle: verified ZeroTier MSI is only a resource; NSIS must never elevate it', () => {
  const cfg = JSON.parse(readFileSync(configPath, 'utf8'));
  assert.ok(cfg.bundle.targets.includes('nsis'));
  assert.equal(cfg.bundle.windows.nsis.installMode, 'currentUser');
  assert.equal(cfg.bundle.windows.nsis.installerHooks, undefined);
  assert.deepEqual(cfg.bundle.resources, ['resources/ZeroTierOne.msi','resources/THIRD_PARTY_VLC.md','resources/VLC-COPYING.LIB.txt']);
  assert.equal(existsSync(join(root,'windows/zerotier-installer-hooks.nsh')),false);
  assert.equal(cfg.bundle.createUpdaterArtifacts, true, 'bundled MSI must not disable signed updates');
  assert.ok(!readFileSync(configPath, 'utf8').includes('perMachine'), 'no forced all-machine privilege');
});

test('builder: fixed official MSI, checksum, size, Authenticode publisher and no install commands', () => {
  const body = readFileSync(script, 'utf8');
  const net = readFileSync(networkPath, 'utf8');
  assert.ok(body.includes(url));
  assert.ok(body.includes(sha));
  assert.ok(net.includes(url) && net.includes(sha), 'source pin differs from native preflight');
  assert.match(body, /\$expectedBytes\s*=\s*12003840/);
  assert.match(body, /Get-FileHash\s+-LiteralPath.*-Algorithm SHA256/);
  assert.match(body, /Get-AuthenticodeSignature\s+-LiteralPath/);
  assert.match(body, /\[string\]\$signature.Status\s+-cne\s+'Valid'/);
  assert.match(body, /\$expectedSigner\s*=\s*'ZeroTier, Inc\.'/);
  assert.match(body, /1\.3\.6\.1\.5\.5\.7\.3\.3/);
  assert.doesNotMatch(body, /\bStart-Process\b|\bInvoke-Expression\b|\biex\b|\bSet-Service\b|\bStart-Service\b|\bmsiexec(?:\.exe)?\s+\//i,
    'build-time downloader must not activate or install anything');
  assert.match(body, /\[IO\.File\]::Move\(\$temporary,\$destination\)/);
});

test('runtime native installer verifies pinned bytes and locks the MSI through UAC', () => {
  const installer=readFileSync(nativeInstallerPath,'utf8');
  assert.match(installer,/PINNED_SHA256/);
  assert.match(installer,/share_mode\(0x00000001\)/);
  assert.match(installer,/ShellExecuteExW/);
  assert.match(installer,/PINNED_BYTES: u64 = 12_003_840/);
  assert.match(installer,/status\.service_installed!=Some\(false\)/);
  assert.match(installer,/hold_read_lock: File/);
});

test('builder: corrupt original-sized unsigned MSI is refused without writes to real checkout', {
  skip: process.platform !== 'win32',
}, (t) => {
  const dir = temporary(t);
  const fixture = join(dir, 'src-tauri');
  const resources = join(fixture, 'resources');
  mkdirSync(resources, { recursive: true });
  const source = join(dir, 'pretend.msi');
  writeFileSync(source, Buffer.alloc(12_003_840, 0x4d));
  const bad = runPs(['-TauriRoot', fixture, '-SourceMsiPath', source]);
  assert.notEqual(bad.status, 0, 'bad hash must abort the build preparation');
  assert.match(bad.stderr, /SHA-256|hash|no coincide|rechazado/i);
  assert.equal(existsSync(join(resources, 'ZeroTierOne.msi')), false,
    'never leave unverified MSI in the future Tauri bundle');
  assert.deepEqual(readdirSync(resources), [], 'temporary failed-download artifacts must be deleted');
  const malicious = join(resources, 'ZeroTierOne.msi');
  writeFileSync(malicious, 'existing-untrusted');
  const before = readFileSync(malicious);
  const repeat = runPs(['-TauriRoot', fixture, '-SourceMsiPath', source]);
  assert.notEqual(repeat.status, 0, 'existing malicious artifact must never be silently replaced');
  assert.deepEqual(readFileSync(malicious), before, 'existing destination must be left unchanged');
});

