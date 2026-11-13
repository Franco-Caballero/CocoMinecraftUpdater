// Static contract only: no Windows Registry access, NSIS execution or installs.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');

test('Tauri 2 NSIS registers ONLY Coco 2 owned extension, never .zip',async()=>{
  const [configText,schemaText]=await Promise.all([
    read('src-tauri/tauri.conf.json'),
    read('node_modules/@tauri-apps/cli/config.schema.json'),
  ]);
  const config=JSON.parse(configText);
  const schema=JSON.parse(schemaText);
  assert.equal(config.bundle.active,true);
  assert.deepEqual(config.bundle.targets,['nsis']);
  assert.equal(config.bundle.windows.nsis.installMode,'currentUser',
    'Windows installer must never request a system-wide association');
  const associations=config.bundle.fileAssociations;
  assert.deepEqual(associations?.flatMap(x=>x.ext),['coco2pack'],
    'neither zip nor coco2pack.zip is safe to register with Windows');
  assert.equal(associations[0].name,'CocoLauncher2PortablePack');
  assert.equal(associations[0].mimeType,'application/x-coco2pack');
  assert.equal(associations[0].role,'Viewer');
  assert.ok(schema.definitions.BundleConfig.properties.fileAssociations,
    'bundled Tauri 2 CLI schema must support fileAssociations');
  for(const key of Object.keys(associations[0])){
    assert.ok(key in schema.definitions.FileAssociation.properties,
      `field ${key} must exist in installed Tauri 2 schema`);
  }
  assert.ok(!associations.some(x=>x.ext.some(e=>e.toLowerCase()==='zip')));
});

test('Host Studio exports real ZIP bytes with exclusive .coco2pack, optional Save As and no replace',async()=>{
  const [host,service]=await Promise.all([
    read('src-tauri/src/services/host_publish.rs'),
    read('src-tauri/src/services/import.rs'),
  ]);
  assert.match(host,/format!\("\{directory\}\.coco2pack"\)/);
  assert.match(host,/portable_destination\(&trusted_parent,directory,destination_path\)/);
  assert.match(host,/export_portable_to\(root:&Path,id:&str,artifact_path:&str,/);
  assert.match(host,/zip::ZipWriter::new\(output\)/);
  assert.match(host,/portable_file\(root,id,Path::new\(artifact_path\),None\)/);
  assert.match(host,/create_stage\(destination_parent,id\)/,
    'Save As stage must be on destination volume');
  assert.match(host,/rename_no_replace\(&temp,&dest\)/,
    'no replacement during final atomic publication');
  assert.match(host,/no_links\(destination_parent\)/);
  assert.match(host,/fs::symlink_metadata\(&dest\).is_ok\(\)/);
  assert.match(host,/selected\.starts_with\(r"\\\\"\)/,
    'reject UNC and device Windows paths');
  assert.match(service,/export_portable_standalone_package\(id:String,artifact_path:String,\s*destination_path:Option<String>\)/);
  assert.match(service,/destination_path\.as_deref\(\)/);
  assert.doesNotMatch(service,/reg\s+add|RegSetValue|HKEY_CLASSES_ROOT|Command::new\("powershell"\)/i);
});

test('legacy .coco2pack.zip stays readable through picker, but is not registered with Windows',async()=>{
  const [importer,host]=await Promise.all([
    read('src-tauri/src/services/catalog_portable.rs'),
    read('src-tauri/src/services/host_publish.rs'),
  ]);
  assert.match(importer,/name\.ends_with\("\.coco2pack"\)\s*\|\|\s*name\.ends_with\("\.coco2pack\.zip"\)/);
  assert.match(host,/Older `\.coco2pack\.zip`/);
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  assert.equal(config.bundle.fileAssociations.some(x=>x.ext.includes('zip')),false);
});

test('association values contain no registry-path or installer-command injection',async()=>{
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  assert.equal(config.bundle.windows.nsis.installMode,'currentUser');
  for(const association of config.bundle.fileAssociations){
    assert.match(association.name,/^[A-Za-z][A-Za-z0-9]+$/);
    assert.match(association.description,/^[^\\\r\n"$]+$/);
    for(const ext of association.ext) assert.match(ext,/^[a-z0-9]+$/);
  }
});
