import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseArgs,slugFromTitle,neutralCover,run} from '../scripts/QuickAdd-Coco2Agent.mjs';
import {spawnSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,unlink,rmdir} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import sharp from 'sharp';

test('agent CLI derives stable IDs, refuses missing inputs and never infers publication',()=>{
  assert.equal(slugFromTitle('Pokémon Édition 🐉'),'pokemon-edition');
  assert.equal(slugFromTitle('☃️'),null);
  assert.deepEqual(parseArgs(['--name','Mi Juego','--zip','C:\\Game.zip']),
    {prepare:false,apply:false,help:false,name:'Mi Juego',zip:'C:\\Game.zip'});
  assert.throws(()=>parseArgs(['--apply','--apply']),/unrecognized|duplicado/i);
  assert.throws(()=>parseArgs(['--sign']),/no reconocido/i);
});

test('provisional host cover can be generated locally without artwork or network',async()=>{
  const root=await mkdtemp(join(tmpdir(),'coco2-agent-neutral-v31-'));
  const cover=join(root,'cover.png');
  try{
    await neutralCover('Synthetic & <Game> / 漢字',cover);
    const meta=await sharp(cover).metadata();
    assert.equal(meta.format,'png');
    assert.equal(meta.width,960);
    assert.equal(meta.height,540);
    const bytes=await readFile(cover);
    assert.ok(bytes.length>200&&bytes.length<20*1024*1024);
    assert.ok(bytes.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex')));
  }finally{
    await unlink(cover).catch(error=>{if(error.code!=='ENOENT')throw error});
    await rmdir(root).catch(error=>{if(error.code!=='ENOENT')throw error});
  }
});

test('one-command agent inspect runs on synthetic Windows ZIP without creating drafts or mutating host catalog',async()=>{
  const path=await mkdtemp(join(tmpdir(),'coco2-agent-quick-v31-'));
  const contents=join(path,'source'),zip=join(path,'game.zip');
  const exe=join(contents,'MiJuego.exe');
  const catalog=resolve('../..','launcher/catalog.template.json');
  const before=createHash('sha256').update(await readFile(catalog)).digest('hex');
  try{
    await mkdir(contents);
    await writeFile(exe,'not-a-real-executable; synthetic and inert');
    const command=`Compress-Archive -Path '${contents.replaceAll("'","''")}\\*' -DestinationPath '${zip.replaceAll("'","''")}'`;
    const child=spawnSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],
      {encoding:'utf8',timeout:15000,windowsHide:true});
    assert.equal(child.status,0,child.stderr);
    const received=[];const previous=console.log;
    console.log=v=>received.push(v);
    let result;
    try{result=await run({zip,name:'Mi Juego'});}finally{console.log=previous;}
    assert.equal(result.status,'inspected-only');
    assert.equal(result.id,'mi-juego');
    assert.equal(result.executable,'MiJuego.exe');
    assert.equal(result.published,false);
    assert.equal(result.approvedForClients,false);
    assert.equal(received.length,1);
    assert.deepEqual(JSON.parse(received[0]).executableCandidates,['MiJuego.exe']);
    const after=createHash('sha256').update(await readFile(catalog)).digest('hex');
    assert.equal(after,before,'agent inspection cannot modify host source');
  }finally{
    await unlink(zip).catch(error=>{if(error.code!=='ENOENT')throw error});
    await unlink(exe).catch(error=>{if(error.code!=='ENOENT')throw error});
    await rmdir(contents).catch(error=>{if(error.code!=='ENOENT')throw error});
    await rmdir(path).catch(error=>{if(error.code!=='ENOENT')throw error});
  }
});
