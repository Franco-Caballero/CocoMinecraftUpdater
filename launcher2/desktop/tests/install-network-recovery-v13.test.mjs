/**
 * Coco Launcher 2 v0.6.3 network/crash recovery. Native E2E uses only test-owned
 * Windows TEMP directories and ephemeral 127.0.0.1 HTTP, never real games,
 * app data, HKCU, internet or Release.
 * COCO2_INSTALL_NETWORK_RECOVERY_V13_E2E=1 enables Rust tests through Node.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=()=>readFile(join(desktop,'src-tauri','src','services','install.rs'),'utf8');

test('crash-orphan stages are identified before reuse, while SHA and create-new cache guarantees remain',async()=>{
  const code=await source();
  assert.match(code,/fn mark_download_stage\(stage:&Path,hash:&str,size:u64\)/);
  assert.match(code,/archive\.identity\.v13/);
  assert.match(code,/mark_download_stage\(&attempt\.0,&hash,spec\.size\)\?/);
  assert.match(code,/name\.starts_with\("\.coco2-stage-"\)/);
  assert.match(code,/if matches_digest\(&path,expected,hash,token\)\?/);
  assert.match(code,/publish_verified_archive\(&working,&archive,spec,token\)\?/);
  assert.match(code,/fn crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size/);
});

test('stale mirror Range rejection retries at zero once and Retry-After supports HTTP dates',async()=>{
  const code=await source();
  assert.match(code,/fn retry_after_delay_ms\(attempt:usize,retry_after:Option<&str>,now:time::OffsetDateTime\)/);
  assert.match(code,/time::format_description::well_known::Rfc2822/);
  assert.match(code,/let mut restarted_after_rejected_range=false/);
  assert.match(code,/previous_len>0 && start>0 && !restarted_after_rejected_range/);
  assert.match(code,/matches!\(status,200\|416\)/);
  assert.match(code,/resume_guard\.previous_len=0/);
  assert.match(code,/fn rejected_resume_range_416_and_200_restart_once_without_touching_partial/);
  assert.match(code,/fn retry_after_http_date_and_delta_seconds_are_parsed_and_bounded/);
  assert.match(code,/fn connection_reset_mid_chunk_resumes_at_actual_bytes_and_checks_final_sha/);
});

test('native Windows Rust download and recovery adversarial E2E',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_NETWORK_RECOVERY_V13_E2E==='1'
    ? false : 'opt in on Windows using COCO2_INSTALL_NETWORK_RECOVERY_V13_E2E=1',
  timeout:180_000,
},async()=>{
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const record=part=>{output=(output+part.toString()).slice(-150000);};
  cargo.stdout.on('data',record);cargo.stderr.on('data',record);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;cargo.kill();},165000);
  const result=await new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Native v13 tests timed out:\n'+output);
  assert.equal(result.code,0,'Native v13 Rust tests failed:\n'+output);
  for(const name of [
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
    'rejected_resume_range_416_and_200_restart_once_without_touching_partial',
    'retry_after_http_date_and_delta_seconds_are_parsed_and_bounded',
    'connection_reset_mid_chunk_resumes_at_actual_bytes_and_checks_final_sha',
    'transient_http_503_and_429_retry_with_bounded_ranges_and_verified_sha',
    'concurrent_verified_cache_winner_is_reused_but_foreign_corrupt_zip_is_preserved',
  ])assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
