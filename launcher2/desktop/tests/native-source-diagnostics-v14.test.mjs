import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const load=async path=>{
  const js=ts.transpileModule(await readFile(resolve(root,path),'utf8'),{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022},
  }).outputText;
  const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports});return module.exports;
};

test('incompatible HTTP ranges/ETag/redirects are source-integrity failures, not Defender events',async()=>{
  const {nativeFailureGuidance:guide}=await load('src/native-failure-guidance.ts');
  for(const cause of [
    'El servidor devolvió un Content-Range distinto del solicitado',
    'ETag cambió entre partes del ZIP',
    'HTTP 416 durante descarga parcial',
    'El servidor no soporta las descargas parciales requeridas',
    'El servidor redirigió el paquete a una conexión no cifrada',
  ]){
    const advice=guide(cause,'install');
    assert.equal(advice.kind,'source',cause);
    assert.match(advice.summary,/sin confiar|no fuerces|Coco detuvo/i);
    assert.doesNotMatch(advice.summary,/Defender|exclusi[oó]n|desactivar|SmartScreen/i);
  }
  assert.equal(guide('os error 5: access denied','install').kind,'permissions');
  assert.equal(guide('os error 32: sharing violation','repair').kind,'locked');
  assert.equal(guide('sha256 mismatch','upgrade').kind,'integrity');
});

test('remote errors redact URL bearer parameters before becoming visible diagnostics',async()=>{
  const {nativeFailureGuidance:guide}=await load('src/native-failure-guidance.ts');
  const advice=guide('HTTP 416; source https://cdn.example.invalid/archive.zip?token=secret-123&signature=abc','install');
  assert.equal(advice.kind,'source');
  assert.doesNotMatch(advice.detail,/secret-123|cdn\.example|signature=abc/i);
  assert.match(advice.detail,/\[dirección remota omitida\]/);
});
