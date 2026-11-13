// Coco2 v0.6.0: compile the ACTUAL std-only Rust cover generator in an
// exclusively owned TEMP directory, then decode the output with sharp/zlib.
// Never touches a game, profile, registry, release, installer or repository
// artifact. Full native draft→publish→portable E2E lives in Rust inline tests.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,rmSync,existsSync} from 'node:fs';
import {join,resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {inflateSync} from 'node:zlib';
import sharp from 'sharp';

const base=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const rust=readFileSync(resolve(base,'src-tauri/src/services/import.rs'),'utf8');
const publisher=readFileSync(resolve(base,'src-tauri/src/services/host_publish.rs'),'utf8');
const first=rust.indexOf('fn neutral_cover_png() -> Vec<u8> {');
const last=rust.indexOf('\nfn validate_archive_url(',first);
assert.ok(first>0&&last>first,'the production generator must be present');
const functionSource=rust.slice(first,last).trim();
const ownTemp=mkdtempSync(join(tmpdir(),'coco2-neutral-cover-v10-'));
let bytes;
try {
  const source=join(ownTemp,'cover.rs');
  const exe=join(ownTemp,process.platform==='win32'?'cover.exe':'cover');
  writeFileSync(source,
    'use std::io::Write;\nconst MAX_COVER_BYTES:u64=20*1024*1024;\n'+functionSource+
    '\nfn main(){std::io::stdout().write_all(&neutral_cover_png()).unwrap();}\n');
  const compiled=spawnSync('rustc',['--edition=2021',source,'-o',exe],{
    cwd:ownTemp,encoding:'utf8',timeout:40000,windowsHide:true
  });
  assert.equal(compiled.error,undefined,compiled.error?.message);
  assert.equal(compiled.status,0,'Rust generator must compile alone: '+compiled.stderr);
  assert.equal(existsSync(exe),true);
  const output=spawnSync(exe,[],{cwd:ownTemp,timeout:10000,
    windowsHide:true,maxBuffer:4*1024*1024});
  assert.equal(output.error,undefined,output.error?.message);
  assert.equal(output.status,0,output.stderr?.toString('utf8'));
  bytes=output.stdout;
}finally{
  rmSync(ownTemp,{recursive:true,force:true,maxRetries:2});
}
assert.ok(bytes.length>100&&bytes.length<20*1024*1024);

test('generated PNG decodes as real neutral RGB artwork (not a forged signature)',async()=>{
  const image=sharp(bytes,{failOn:'error'});
  const metadata=await image.metadata();
  assert.equal(metadata.format,'png');
  assert.equal(metadata.width,320);
  assert.equal(metadata.height,180);
  assert.equal(metadata.channels,3);
  assert.equal(metadata.hasAlpha,false);
  const pixels=await image.raw().toBuffer();
  assert.equal(pixels.length,320*180*3);
  assert.notDeepEqual(pixels.subarray(0,3),pixels.subarray((90*320+160)*3,(90*320+160)*3+3));
});

test('PNG has valid stream checksum and stable content hash, no external images',()=>{
  assert.equal(bytes.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  let at=8;
  let header=0,images=0,ended=0;
  const compressed=[];
  while(at<bytes.length){
    const size=bytes.readUInt32BE(at);
    const kind=bytes.subarray(at+4,at+8).toString('ascii');
    const start=at+8,end=start+size;
    assert.ok(end+4<=bytes.length);
    if(kind==='IHDR'){header++;assert.equal(size,13);}
    else if(kind==='IDAT'){images++;compressed.push(bytes.subarray(start,end));}
    else if(kind==='IEND'){ended++;assert.equal(size,0);}
    else assert.fail('unrecognized PNG chunk: '+kind);
    at=end+4;
  }
  assert.equal(at,bytes.length);
  assert.equal(header,1);assert.equal(images,1);assert.equal(ended,1);
  const decoded=inflateSync(Buffer.concat(compressed));
  assert.equal(decoded.length,180*(320*3+1));
  for(let row=0;row<180;row++)assert.equal(decoded[row*(320*3+1)],0,
    'PNG filter None is deterministic');
  assert.match(createHash('sha256').update(bytes).digest('hex'),/^[a-f0-9]{64}$/);
  assert.doesNotMatch(functionSource,/https?:|include_bytes!|File::open|fs::read|\breqwest\b|\brand\b|assets\//i);
});

test('exact empty cover means generated PNG; nonempty invalid path never falls back',()=>{
  assert.match(rust,/if cover_path\.is_empty\(\)\s*\{\s*None\s*\}\s*else\s*\{\s*Some\(canonical_file\(cover_path, "cover"\)\?\)/);
  assert.match(rust,/Some\(cover\) => cover_kind\(cover\)\?/);
  assert.match(rust,/None => "png"/);
  assert.match(rust,/if let Some\(cover\) = explicit_cover \{/);
  assert.match(rust,/let image = neutral_cover_png\(\)/);
  assert.match(rust,/write_new\(&target_cover, &image\)\?/);
  assert.match(rust,/cover_kind\(&target_cover\)\? != "png"/);
  assert.match(rust,/fs::rename\(&stage\.0, &output\)/);
  assert.match(rust,/no_links\(&drafts\)\?/);
  assert.match(rust,/pin_source_parent\(&output\)\?/);
});

test('draft API, catalog schema, native signature and portable structure remain unchanged',()=>{
  assert.match(rust,/pub async fn create_standalone_draft\(/);
  assert.match(rust,/pub async fn create_standalone_update_draft\(/);
  assert.match(rust,/archive_url: String, cover_path: String, executable: String, expected_sha256: String/);
  assert.match(rust,/let cover_name = format!\("cover\.\{ext\}"\)/);
  assert.match(rust,/let cover_catalog = format!\("assets\/experiences\/\{id\}\.\{ext\}"\)/);
  assert.match(rust,/candidate\["runtime"\]\["requiredFiles"\]/);
  assert.match(rust,/write_json\(&stage\.0\.join\("catalog-candidate\.json"\), &candidate\)\?/);
  assert.match(rust,/write_json\(&stage\.0\.join\("source-lock\.json"\), &lock\)\?/);
  assert.match(publisher,/format!\("cover\.\{\}", prepared\.cover_extension\)/);
  assert.match(publisher,/"coverSha256":sha_bytes\(&prepared\.promotion\.cover\)/);
  assert.match(publisher,/"coverFile":cover_name/);
  assert.match(publisher,/fn export_portable_to\(/);
  assert.doesNotMatch(functionSource,/ed25519|sign|certificate|publish|import/i);
});
