import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
test('picker rejects generic ZIP before SHA-heavy native inspection and retains Unicode/legacy Coco files',async()=>{
  const [source,hub]=await Promise.all([
    readFile(resolve(root,'src/portable-format.ts'),'utf8'),
    readFile(resolve(root,'src/CatalogHub.tsx'),'utf8'),
  ]);
  const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports});
  const isSupported=module.exports.isPortablePackageFile;
  for(const value of [
    'C:\\Juegos\\Amigo Áé😀\\Juego final.coco2pack',
    'C:\\Mis juegos\\backup.coco2pack.zip',
    'C:\\Games\\GAME.COCO2PACK',
  ])assert.equal(isSupported(value),true,value);
  for(const value of ['C:\\Games\\juego.zip','C:\\Games\\juego.coco2pack.exe',
    'C:\\Games\\juego.coco2pack.zip.exe','C:\\Games\\juego.coco2pack\n',
    '','C:\\Games\\juego.coco2pack\0junk'])assert.equal(isSupported(value),false,value);
  assert.match(hub,/if\(!legacyFolder&&!isPortablePackageFile\(selected\)\)/);
  assert.match(hub,/ZIP genéricos/);
  assert.match(hub,/invoke<LocalPackageReview>\('review_local_publish_package'/);
  assert.match(hub,/path:sourcePath,reviewToken:review.reviewToken,confirmed:true/);
});
