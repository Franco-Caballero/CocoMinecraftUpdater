/**
 * Coco Launcher 2 media streaming v19 — native loopback resilience.
 * Opt into Rust HTTP/TEMP E2E using COCO2_MEDIA_STREAM_RESILIENCE_V19_E2E=1.
 * No external requests, commercial media, registry, user processes or Release.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = () => readFile(join(desktop, 'src-tauri', 'src', 'services', 'media.rs'), 'utf8');

test('pinned remote HEAD ignores Range while GET still validates Content-Range and bytes', async () => {
  const code = await source();
  assert.match(code, /if request\.method == "HEAD" && spec\.expected_bytes != 0 \{/);
  assert.match(code, /send_headers\(&mut stream, 200, spec\.mime, spec\.expected_bytes, None, false\)/);
  assert.match(code, /if code == 206 && !request\.range\.as_deref\(\)/);
  assert.match(code, /valid_partial_response\(range, content_range, length\)/);
  assert.match(code, /valid_unsatisfiable_response\(request\.range\.as_deref\(\), content_range, spec\.expected_bytes\)/);
  assert.match(code, /fn ranged_head_ignores_range_per_http_semantics_without_origin_502_v19/);
});

test('closing streaming URL releases global quota atomically without counter underflow', async () => {
  const code = await source();
  assert.match(code, /if !token\.swap\(true,Ordering::AcqRel\) \{/);
  assert.match(code, /struct ProxyGuard\(Arc<AtomicBool>\)/);
  assert.match(code, /if !self\.0\.swap\(true,Ordering::AcqRel\) \{/);
  assert.match(code, /let guard = ProxyGuard\(Arc::clone\(&cancelled\)\)/);
  assert.match(code, /Arc::ptr_eq\(flag,&cancel_flag\)/);
  assert.match(code, /fn released_stream_slots_are_reusable_immediately_on_media_reload_v19/);
});

test('URL allowlist, path token, cancellation, localhost binding and CORS remain enforced', async () => {
  const code = await source();
  assert.match(code, /fn upstream_allowed\(url: &reqwest::Url, local_fixture: bool\)/);
  assert.match(code, /url\.scheme\(\) != "https"/);
  assert.match(code, /fn secure_token\(\) -> Result<String, String>/);
  assert.match(code, /if request\.target != spec\.path/);
  assert.match(code, /Ipv4Addr::LOCALHOST/);
  assert.match(code, /Access-Control-Allow-Origin: \*/);
  assert.match(code, /spec\.cancelled\.load\(Ordering::Acquire\)/);
});

test('native Windows synthetic HTTP streaming v19 and legacy regression E2E', {
  skip: process.platform === 'win32' && process.env.COCO2_MEDIA_STREAM_RESILIENCE_V19_E2E === '1'
    ? false : 'opt in on Windows with COCO2_MEDIA_STREAM_RESILIENCE_V19_E2E=1',
  timeout: 180_000,
}, async () => {
  const child = spawn('cargo', [
    'test', '--offline', '--locked', '--lib', 'services::media::tests', '--', '--test-threads=8',
  ], { cwd: join(desktop, 'src-tauri'), windowsHide: true, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  const collect = part => { output = (output + part.toString()).slice(-180000); };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  let timedOut = false;
  const watchdog = setTimeout(() => { timedOut = true; child.kill(); }, 165000);
  const finished = await new Promise((done, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => done({ code, signal }));
  }).finally(() => clearTimeout(watchdog));
  assert.equal(timedOut, false, 'native Rust v19 timed out:\n' + output);
  assert.equal(finished.code, 0, 'native Rust v19 failed:\n' + output);
  for (const name of [
    'ranged_head_ignores_range_per_http_semantics_without_origin_502_v19',
    'released_stream_slots_are_reusable_immediately_on_media_reload_v19',
    'local_range_proxy_supports_seek_head_cors_and_token_guard_without_real_network',
    'rejects_forged_or_misaligned_content_range',
    'synthetic_upstream_416_requires_genuine_unsatisfiable_range_and_correct_total',
    'aborted_first_upstream_connection_retries_identical_range_once',
  ]) assert.match(output, new RegExp(name + ' \\.\\.\\. ok'));
  assert.match(output, /test result: ok\. \d+ passed; 0 failed/);
});
