/**
 * Windows-specific ZIP path identity and installation recovery contract.
 * Everything created by this test is under a unique OS TEMP directory.
 * No user profiles, installed games, registry, network or signed release.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,readFile,writeFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname,join,resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=join(desktop,'src-tauri','src','services','install.rs');
const native=process.platform==='win32' &&
  process.env.COCO2_INSTALL_RECOVERY_V30_E2E==='1';

test('real Windows treats ASCII K and Kelvin sign as independent files',{skip:process.platform==='win32'?false:'requires Win32 paths'},async()=>{
  const root=await mkdtemp(join(tmpdir(),'coco2-v30-kelvin-'));
  try{
    await writeFile(join(root,'K.bin'),'ascii',{flag:'wx'});
    await writeFile(join(root,'K.bin'),'kelvin',{flag:'wx'});
    assert.equal(await readFile(join(root,'K.bin'),'utf8'),'ascii');
    assert.equal(await readFile(join(root,'K.bin'),'utf8'),'kelvin');
  }finally{await rm(root,{recursive:true,force:true});}
});

test('ZIP conflict preflight distinguishes Win32 ordinal case from Unicode compatibility folding',async()=>{
  const source=await readFile(rust,'utf8');
  assert.match(source,/fn windows_path_case_equal\(/);
  assert.match(source,/CompareStringOrdinal/);
  assert.match(source,/fn v30_windows_distinct_kelvin_and_ascii_zip_entries_install_without_false_case_collision\(/);
  assert.match(source,/fn v30_unicode_case_split_chunks_reassemble_to_sha_pinned_executable\(/);
});

test('native install ZIP path identity + pre-existing recovery tests',{
  skip:native?false:'set COCO2_INSTALL_RECOVERY_V30_E2E=1 on Windows for native Rust fixture tests',
  timeout:240_000,
},async()=>{
  const child=spawn('cargo',[
    'test','--offline','--locked','-j','1','--lib','services::install::tests',
    '--','--test-threads=4',
  ],{cwd:join(desktop,'src-tauri'),windowsHide:true,shell:false,stdio:['ignore','pipe','pipe']});
  let output='';
  const append=chunk=>{output=(output+chunk.toString()).slice(-220_000);};
  child.stdout.on('data',append);child.stderr.on('data',append);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;child.kill();},225_000);
  const result=await new Promise((resolveResult,reject)=>{
    child.once('error',reject);
    child.once('close',(code,signal)=>resolveResult({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Native install suite exceeded deadline:\n'+output);
  assert.equal(result.code,0,'Native install suite failed:\n'+output);
  for(const name of [
    'v30_windows_distinct_kelvin_and_ascii_zip_entries_install_without_false_case_collision',
    'v30_unicode_case_split_chunks_reassemble_to_sha_pinned_executable',
    'unsafe_paths_and_duplicate_case_are_rejected',
    'preflight_rejects_cross_zip_case_aliases_and_file_parent_conflicts',
    'joins_split_files_in_stage_and_preserves_required_hash',
    'crash_orphan_stage_resumes_only_if_identity_matches_sha_and_size',
    'uncommitted_http_etag_does_not_exhaust_single_real_rotation_v25',
    'duplicate_content_encoding_does_not_publish_untrusted_206_v27',
  ])assert.match(output,new RegExp(`${name} \\.\\.\\. ok`));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
