import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const code=ts.transpileModule(await readFile(resolve(root,'src/native-affected-path.ts'),'utf8'),{
  compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
}).outputText;
const module={exports:{}};
vm.runInNewContext(code,{module,exports:module.exports});
const {affectedRegisteredGamePath:affected}=module.exports;

test('exact Unicode Windows path appears only when the native error quotes it within the catalog root',()=>{
  const registered='C:\\Users\\Jugadora\\Coco Games\\Juego Español';
  const actual='C:\\Users\\Jugadora\\Coco Games\\Juego Español\\bin\\café 漢字.exe';
  assert.equal(affected(`No se pudo escribir '${actual}': os error 32`,registered),actual);
  assert.equal(affected(`No se pudo escribir "${actual}": os error 5`,registered),actual);
  assert.equal(affected(`No se pudo escribir ${actual}: os error 5`,registered),null,'unbounded plain text has no safe path terminator');
  assert.equal(affected(`Fallo: '${actual}'`,registered.toUpperCase()),actual);
});

test('does not reveal neighboring games, user profile paths, UNC or malicious traversal',()=>{
  const root='C:\\Games\\Coco';
  for(const path of [
    'C:\\Games\\CocoOtro\\secrets.exe',
    'C:\\Games\\Coco\\..\\otro\\secrets.exe',
    'C:\\Games\\Coco\\.\\bad.exe',
    'C:\\Users\\Persona\\passwords.txt',
    'C:\\Games\\Coco\\bad\\\\file.exe',
    '\\\\server\\share\\game.exe',
    '\\\\?\\C:\\Games\\Coco\\hidden.exe',
  ])assert.equal(affected(`Error: '${path}'`,root),null,path);
  assert.equal(affected(`Error: 'C:\\Games\\Coco\\good.exe'`,'\\\\server\\share'),null);
  assert.equal(affected(`Error: 'C:\\Games\\Coco\\good.exe'`,'C:\\Games\\Coco\\..\\Elsewhere'),null);
  assert.equal(affected(`No se pudo abrir https://example.invalid?token=abc`,root),null);
});

test('UI treats the extracted path as quoted error evidence, never proof of Defender quarantine',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  assert.match(ui,/affectedRegisteredGamePath\(nativeFailure\.detail,securityGuide\.folder\)/);
  assert.match(ui,/Ruta mencionada por el error, no confirma cuarentena/);
  assert.match(ui,/Carpeta registrada y verificada/);
  assert.doesNotMatch(ui,/invoke\('add_defender_exclusion'\)/);
});
