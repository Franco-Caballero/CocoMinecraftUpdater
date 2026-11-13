/**
 * Coco2 v0.6.3 offline media transfer recovery. Native tests use synthetic
 * data, isolated OS TEMP folders and only ephemeral 127.0.0.1 HTTP sockets.
 * No real media, user game saves, HKCU, browser, internet, or Release.
 *
 * COCO2_MEDIA_DOWNLOAD_RECOVERY_V13_E2E=1 runs the Rust suite on Windows.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const media=join(desktop,'src-tauri','src','services','media_download.rs');

test('fsynced state.new crash window can be resumed only with SHA-verified pinned prefix',async()=>{
  const code=await readFile(media,'utf8');
  assert.match(code,/fn recover_staged_state\(target:&Target\)->Result<\(\),String>/);
  assert.match(code,/fn read_state_at\(target:&Target,path:&Path\)/);
  assert.match(code,/staged\.verified_bytes<old\.verified_bytes/);
  assert.match(code,/format!\("\{:x\}",digest\.finalize\(\)\)!=staged\.prefix_sha256/);
  assert.match(code,/recover_staged_state\(target\)\?/);
  assert.match(code,/fs::rename\(&staged,&target\.state\)/);
  assert.match(code,/fn crash_between_state_sync_and_rename_recovers_verified_unicode_checkpoint/);
  assert.match(code,/fn foreign_or_tampered_state_stage_never_overwrites_committed_state_or_media/);
});

test('full SHA mismatch on completed partial restarts only manifest-owned partial, not user video',async()=>{
  const code=await readFile(media,'utf8');
  assert.match(code,/state\.verified_bytes==target\.expected/);
  assert.match(code,/format!\("\{:x\}",digest\.clone\(\)\.finalize\(\)\)!=target\.sha256/);
  assert.match(code,/save_state\(&target\.state,&initial\)\?/);
  assert.match(code,/partial\.set_len\(0\)/);
  assert.match(code,/fs::hard_link\(&target\.partial,&target\.path\)/);
  assert.match(code,/fn fully_checkpointed_wrong_sha_recovers_next_invocation_without_user_overwrite/);
  assert.match(code,/media::upstream_allowed\(&url, local_fixture\)/);
});

test('retry-after date, cancellation, exact Range, ETag and no downgrade remain required',async()=>{
  const code=await readFile(media,'utf8');
  assert.match(code,/fn retry_wait_ms\(attempt:u8,retry_after:Option<&str>,now:time::OffsetDateTime\)/);
  assert.match(code,/time::format_description::well_known::Rfc2822/);
  assert.match(code,/retry_wait\(attempt\+1,after\.as_deref\(\),cancel\)/);
  assert.match(code,/reqwest::header::IF_RANGE/);
  assert.match(code,/Media ETag changed or disappeared between chunks/);
  assert.match(code,/body\.headers\(\)\.get\(reqwest::header::CONTENT_RANGE\)/);
  assert.match(code,/body\.headers\(\)\.get\(reqwest::header::CONTENT_ENCODING\)/);
  assert.match(code,/media::upstream_allowed\(body\.url\(\),local_fixture\)/);
  assert.match(code,/fn rate_limits_retries_then_etag_switch_and_connection_reset_fail_safe/);
});

test('native Rust TEMP and HTTP-loopback media recovery E2E',{
  skip:process.platform==='win32'&&process.env.COCO2_MEDIA_DOWNLOAD_RECOVERY_V13_E2E==='1'
    ? false : 'opt in on Windows with COCO2_MEDIA_DOWNLOAD_RECOVERY_V13_E2E=1',
  timeout:180_000,
},async()=>{
  const process=spawn('cargo',[
    'test','--offline','--locked','--lib','services::media_download::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const record=chunk=>{output=(output+chunk.toString()).slice(-140_000);};
  process.stdout.on('data',record);
  process.stderr.on('data',record);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;process.kill();},165_000);
  const status=await new Promise((resolve,reject)=>{
    process.once('error',reject);
    process.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Native media recovery suite exceeded deadline:\n'+output);
  assert.equal(status.code,0,'Native media recovery suite failed:\n'+output);
  for(const name of [
    'crash_between_state_sync_and_rename_recovers_verified_unicode_checkpoint',
    'foreign_or_tampered_state_stage_never_overwrites_committed_state_or_media',
    'fully_checkpointed_wrong_sha_recovers_next_invocation_without_user_overwrite',
    'rate_limits_retries_then_etag_switch_and_connection_reset_fail_safe',
    'verified_partial_resumes_exact_suffix_and_preserves_corrupt_user_file',
    'redirect_to_untrusted_origin_never_follows_or_commits',
  ]) assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
