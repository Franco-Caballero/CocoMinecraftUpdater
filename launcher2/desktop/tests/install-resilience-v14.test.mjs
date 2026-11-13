/**
 * Coco Launcher 2 v0.6.4 candidate: crash-safe native ZIP installation.
 * Windows synthetic TEMP + 127.0.0.1 HTTP only. No real games, internet,
 * signed Release, HKCU, launcher UI, or user saves are exercised.
 * Native cargo tests are opt-in with COCO2_INSTALL_RESILIENCE_V14_E2E=1.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=()=>readFile(join(desktop,'src-tauri','src','services','install.rs'),'utf8');

test('split-part ZIP preflight includes transient assembly scratch, not only expanded ZIP bytes',async()=>{
  const text=await source();
  assert.match(text,/fn split_reassembly_scratch_bytes\(/);
  assert.match(text,/fn required_extraction_space\(/);
  assert.match(text,/required_extraction_space\(&all_archives,expected_uncompressed,token\)\?/);
  assert.match(text,/required_extraction_space\(&sources,bytes,token\)\?/);
  assert.match(text,/required_extraction_space\(&sources,expanded,token\)\?/);
  assert.match(text,/fn split_part_assembly_disk_preflight_counts_transient_second_copy/);
});

test('ZIP archive redirects are rejected before any insecure HTTP follow-up request',async()=>{
  const text=await source();
  assert.match(text,/fn safe_archive_redirect\(\)->reqwest::redirect::Policy/);
  assert.match(text,/attempt\.url\(\)\.scheme\(\)=="https"/);
  assert.match(text,/attempt\.previous\(\)\.iter\(\)\.all\(/);
  assert.match(text,/\.redirect\(safe_archive_redirect\(\)\)/);
  assert.doesNotMatch(text,/redirect\(reqwest::redirect::Policy::limited\(8\)\)/);
  assert.match(text,/fn redirect_policy_blocks_untrusted_http_before_following_location/);
});

test('assembled split part publication never overwrites an existing user or foreign file',async()=>{
  const text=await source();
  assert.match(text,/fn publish_reassembled_file\(/);
  assert.match(text,/fs::hard_link\(temporary,target\)/);
  assert.match(text,/publish_reassembled_file\(&temporary,&target\)\?/);
  assert.match(text,/fn split_publish_foreign_collision_preserves_destination/);
});

test('Windows native synthetic ZIP and loopback redirects E2E',{
  skip:process.platform==='win32'&&process.env.COCO2_INSTALL_RESILIENCE_V14_E2E==='1'
    ? false : 'opt in on Windows using COCO2_INSTALL_RESILIENCE_V14_E2E=1',
  timeout:180_000,
},async()=>{
  const cargo=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),shell:false,windowsHide:true,stdio:['ignore','pipe','pipe']});
  let output='';
  const record=chunk=>{output=(output+chunk.toString()).slice(-180000);};
  cargo.stdout.on('data',record);cargo.stderr.on('data',record);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;cargo.kill();},165000);
  const completed=await new Promise((resolve,reject)=>{
    cargo.once('error',reject);
    cargo.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'cargo focal exceeded safe limit:\n'+output);
  assert.equal(completed.code,0,'cargo focal failed:\n'+output);
  for(const name of [
    'split_part_assembly_disk_preflight_counts_transient_second_copy',
    'redirect_policy_blocks_untrusted_http_before_following_location',
    'split_publish_foreign_collision_preserves_destination',
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
    'transient_http_503_and_429_retry_with_bounded_ranges_and_verified_sha',
  ]) assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
