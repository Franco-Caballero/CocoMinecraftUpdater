/**
 * Coco2 v0.6.2 crash/journal regressions. Native fixtures are owned per-test
 * TEMP paths; no HKCU, real games, external network, versions, or installer.
 * Use COCO2_REPAIR_JOURNAL_V12_E2E=1 on Windows to run Rust from this wrapper.
 */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=join(desktop,'src-tauri','src','services','repair_transaction.rs');

test('rollback can resume a verified temporary copy and rejects an unverified one before mutation',async()=>{
  const source=await readFile(rust,'utf8');
  assert.match(source,/let saved=fingerprint\(&temp,&AtomicBool::new\(false\)\)\?/);
  assert.match(source,/saved\.is_some\(\) && saved\.as_ref\(\)!=change\.old\.as_ref\(\)/);
  assert.match(source,/if !temp\.exists\(\) \{/);
  assert.match(source,/fingerprint\(&temp,&AtomicBool::new\(false\)\)\?\.as_ref\(\)!=Some\(previous\)/);
  assert.match(source,/fn crash_after_rollback_copy_resumes_verified_unicode_temp_and_preserves_saves/);
  assert.match(source,/fn foreign_recovery_temp_rejected_before_any_live_change_then_recovers/);
});

test('Windows commit/rollback uses atomic no-replace UTF-16 moves for foreign-file races',async()=>{
  const source=await readFile(rust,'utf8');
  assert.match(source,/fn move_no_replace\(from:&Path,to:&Path\)->Result<\(\),String>/);
  assert.match(source,/MoveFileExW\(source\.as_ptr\(\),destination\.as_ptr\(\),MOVEFILE_WRITE_THROUGH\)/);
  assert.match(source,/encode_wide\(\)\.chain\(Some\(0\)\)/);
  assert.match(source,/move_no_replace\(&payload\(root,i\),&path\)/);
  assert.match(source,/move_no_replace\(&temp,&live\)/);
  assert.match(source,/move_no_replace\(&live,&discard\)/);
  assert.match(source,/fn win32_no_replace_unicode_race_and_sharing_lock_preserve_foreign_destination/);
  assert.match(source,/fn locked_rollback_retries_after_av_sharing_violation_without_losing_journal/);
  // Never broaden the journal's pinned-file contract to mutable game data.
  assert.match(source,/"saves"\|"playerdata"\|"advancements"\|"stats"/);
  assert.match(source,/if protected_path\(&relative\)/);
});

test('native Windows Rust crash and recovery tests run offline in TEMP only',{
  skip: process.platform==='win32' && process.env.COCO2_REPAIR_JOURNAL_V12_E2E==='1'
    ? false : 'opt in on Windows with COCO2_REPAIR_JOURNAL_V12_E2E=1',
  timeout:150_000,
},async()=>{
  const command=spawn('cargo',[
    'test','--offline','--locked','--lib','services::install::repair_transaction::tests',
    '--','--test-threads=8',
  ],{cwd:join(desktop,'src-tauri'),shell:false,windowsHide:true,stdio:['ignore','pipe','pipe']});
  let output='';
  const record=chunk=>{output=(output+chunk.toString()).slice(-110000);};
  command.stdout.on('data',record);
  command.stderr.on('data',record);
  let timedOut=false;
  const watchdog=setTimeout(()=>{timedOut=true;command.kill();},130000);
  const outcome=await new Promise((resolve,reject)=>{
    command.once('error',reject);
    command.once('close',(code,signal)=>resolve({code,signal}));
  }).finally(()=>clearTimeout(watchdog));
  assert.equal(timedOut,false,'Rust journal tests timed out:\n'+output);
  assert.equal(outcome.code,0,'Rust journal tests failed:\n'+output);
  for (const name of [
    'crash_after_rollback_copy_resumes_verified_unicode_temp_and_preserves_saves',
    'foreign_recovery_temp_rejected_before_any_live_change_then_recovers',
    'win32_no_replace_unicode_race_and_sharing_lock_preserve_foreign_destination',
    'locked_rollback_retries_after_av_sharing_violation_without_losing_journal',
    'interrupted_multi_file_commit_rolls_back_while_restoring_missing_file',
    'rollback_refuses_to_overwrite_third_party_changes_and_keeps_backups',
    'committed_upgrade_recovery_finishes_cleanup_without_downgrading',
  ]) assert.match(output,new RegExp(name+' \\.\\.\\. ok'));
  assert.match(output,/test result: ok\. \d+ passed; 0 failed/);
});
