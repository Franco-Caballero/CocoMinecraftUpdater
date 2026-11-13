import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,unlink,rmdir,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';

const script=resolve(dirname(fileURLToPath(import.meta.url)),'../scripts/Inspect-Coco2AgentGame.ps1');
function ps(args){
  const r=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',...args],
    {encoding:'utf8',timeout:18000,windowsHide:true});
  if(r.error)throw r.error;
  assert.equal(r.status,0,`scanner process exited ${r.status}: ${r.stderr}`);
  return r.stdout.trim();
}

test('fast read-only source preflight detects one synthetic executable, support DLL and defers redundant SHA',async()=>{
  const root=await mkdtemp(join(tmpdir(),'coco2-agent-preflight-v31-'));
  const assets=join(root,'assets'),zip=join(root,'sandbox.zip');
  const exe=join(assets,'TestGame.exe'),dll=join(assets,'UnityPlayer.dll');
  try{
    await mkdir(assets);await writeFile(exe,Buffer.from('synthetic-test-exe-not-executable'));
    await writeFile(dll,Buffer.from('synthetic-test-dll'));
    const escaped=assets.replaceAll("'","''"),zipped=zip.replaceAll("'","''");
    ps(['-Command',`Compress-Archive -Path '${escaped}\\*' -DestinationPath '${zipped}'`]);
    const initial=JSON.parse(ps(['-File',script,'-ZipPath',zip,'-Name','Synthetic Authorized Test']));
    assert.equal(initial.schemaVersion,1);
    assert.equal(initial.status,'inspection-only-untrusted');
    assert.deepEqual(initial.issues,[]);
    assert.equal(initial.uniqueExecutableSuggestion,'TestGame.exe');
    assert.deepEqual(initial.supportFiles,['UnityPlayer.dll']);
    assert.equal(initial.shaDeferred,true);
    assert.equal(initial.zipSha256,null);
    assert.ok(initial.elapsedMs>=0&&initial.entries===2);
    const verified=JSON.parse(ps(['-File',script,'-ZipPath',zip,'-HashArchive']));
    assert.equal(verified.shaDeferred,false);
    assert.equal(verified.zipSha256,createHash('sha256').update(await readFile(zip)).digest('hex'));
    assert.equal(verified.zipBytes,(await stat(zip)).size);
  }finally{
    for(const path of [zip,exe,dll])await unlink(path).catch(error=>{if(error.code!=='ENOENT')throw error});
    await rmdir(assets).catch(error=>{if(error.code!=='ENOENT')throw error});
    await rmdir(root).catch(error=>{if(error.code!=='ENOENT')throw error});
  }
});
