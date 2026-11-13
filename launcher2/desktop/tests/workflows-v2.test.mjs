import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const source=path=>readFile(resolve(root,path),'utf8');

test('an interrupted repair stays recoverable through the native journal',async()=>{
  const [app,lib,labels]=await Promise.all([source('src/main.tsx'),source('src-tauri/src/lib.rs'),source('src/native-progress-sampler.ts')]);
  for(const command of ['recover_standalone_repair','get_standalone_repair_recovery_status']) {
    assert.match(lib,new RegExp(`services::install::${command}\\b`));
    assert.match(app,new RegExp(`['"]${command}['"]`));
  }
  assert.match(app,/recover_standalone_repair'\s*,\s*\{id:entry\.id\}/);
  assert.match(labels,/case 'repair-committing':return 'Aplicando reparación protegida'/);
  assert.match(app,/nativeProgressDescription\(installProgress\?\.phase\|\|''\)/);
  assert.match(app,/onClick=\{\(\)=>void recoverRepair\(selected\)\}/);
  assert.doesNotMatch(app,/execSync|PowerShell\.exe|CocoLauncher\.ps1/i);
});

test('Host Studio prepares a reviewed offline pack and never publishes silently',async()=>{
  const [studio,lib]=await Promise.all([source('src/HostStudio.tsx'),source('src-tauri/src/lib.rs')]);
  for(const command of ['create_standalone_update_draft','preview_standalone_publish','prepare_standalone_publish']) {
    assert.match(lib,new RegExp(`services::r#import::${command}\\b`));
    assert.match(studio,new RegExp(`['"]${command}['"]`));
  }
  assert.match(studio,/expectedPreviewSha256:publishPreview\.previewSha256/);
  assert.match(studio,/!rightsReviewed\|\|busy/);
  assert.match(studio,/nada se publicó ni se importó|no está publicado ni se ha importado/i);
  assert.doesNotMatch(studio,/gh\s+release|fetch\(.*github|upload_release|publish_to_github/i);
});

test('watching resumes where the viewer stopped, and no download is offered',async()=>{
  const app=await source('src/main.tsx');
  assert.match(app,/startAt:fromStart\?null:resumePoint\(progressFor\(entry\.id,episode\.id\)\)/);
  assert.match(app,/progress=\{\{id:mediaPlaying\.stream\.id,episodeId:mediaPlaying\.stream\.episodeId\}\}/);
  assert.doesNotMatch(app,/media-episode-download|'download_media_episode'/);
  assert.doesNotMatch(app,/localStorage\.setItem\(['"]media/,'progress lives in its own module');
});
