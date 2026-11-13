import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const code=await readFile(resolve(root,'src/HostStudio.tsx'),'utf8');
const css=await readFile(resolve(root,'src/host-studio-v9.css'),'utf8');
const ast=ts.createSourceFile('HostStudio.tsx',code,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TSX);
const names=['studioExecutableReviewKey','isStudioExecutableReviewed','studioExecutableWarning','suggestStudioExecutable'];
const funcs=ast.statements.filter(n=>ts.isFunctionDeclaration(n)&&names.includes(n.name?.text));
assert.equal(funcs.length,names.length);
const js=ts.transpileModule(funcs.map(f=>f.getText(ast).replace(/^export\s+/,'')).join('\n')+
  '\n({studioExecutableReviewKey,isStudioExecutableReviewed,studioExecutableWarning,suggestStudioExecutable});',{
    compilerOptions:{module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022},
  }).outputText;
const helpers=vm.runInNewContext(js,{});

const archive1='a'.repeat(64), archive2='b'.repeat(64);
const inspected={sha256:archive1,executables:['game\\Coco.exe','helpers\\setup.exe','game\\Repair.exe']};

test('detected EXE is a proposal; explicit human confirmation binds SHA and full executable path',()=>{
  const suggest=helpers.suggestStudioExecutable(inspected.executables,'Coco.zip');
  assert.equal(suggest,'game\\Coco.exe');
  assert.equal(helpers.isStudioExecutableReviewed(inspected,suggest,''),false,'auto proposal is not consent');
  const consent=helpers.studioExecutableReviewKey(inspected.sha256,suggest);
  assert.equal(helpers.isStudioExecutableReviewed(inspected,suggest,consent),true);
  assert.equal(helpers.isStudioExecutableReviewed({...inspected,sha256:archive2},suggest,consent),false,
    'new archive bytes revoke prior consent');
  assert.equal(helpers.isStudioExecutableReviewed(inspected,'helpers\\setup.exe',consent),false,
    'new selected executable revokes prior consent');
  assert.equal(helpers.isStudioExecutableReviewed({...inspected,executables:[]},suggest,consent),false,
    'cannot confirm a path absent from current native inspection');
  assert.equal(helpers.isStudioExecutableReviewed(null,suggest,consent),false);
  assert.match(helpers.studioExecutableWarning('C:\\Runtime\\setup.exe'),/instalador/);
  assert.match(helpers.studioExecutableWarning('C:\\Game\\Coco.exe'),/Comprueba/);
});

test('native create is refused even if UI is clicked before React disabled button is committed',async()=>{
  let handlerSource='';
  const visit=node=>{
    if(ts.isVariableDeclaration(node)&&node.name.getText(ast)==='create')
      handlerSource=node.initializer.getText(ast);
    ts.forEachChild(node,visit);
  };
  visit(ast);
  assert.ok(handlerSource.includes('!executableReviewed'));
  const jsCreate=ts.transpileModule('const create='+handlerSource+'; create;',{
    compilerOptions:{module:ts.ModuleKind.None,target:ts.ScriptTarget.ES2022}
  }).outputText;
  for(const reviewed of [false,true]){
    const native=[];
    const ctx={
      inspection:{sha256:archive1},busy:false,executableReviewed:reviewed,
      beginOperation:()=>1,completeOperation:()=>{},
      mode:'new',zip:'C:\\Temp\\Coco.zip',id:'coco',name:'Coco',
      version:'1.0.0',url:'https://example.test/review.zip',cover:'',executable:'game\\Coco.exe',
      setResult:()=>{},setPublishPreview:()=>{},setRightsReviewed:()=>{},
      setBusyLabel:()=>{},setPublishArtifact:()=>{},setError:()=>{},
      flowGate:{current:{owns:()=>true}},
      createDraftWithPreview:async make=>{await make();},
      invoke:async(name,args)=>{native.push({name,args});return {id:'coco'};},
      showOperationError:()=>{},
    };
    const create=vm.runInNewContext(jsCreate,ctx);
    await create();
    assert.equal(native.length,reviewed?1:0,'unreviewed EXE must not cross Tauri boundary');
    if(reviewed){
      assert.equal(native[0].name,'create_standalone_draft');
      assert.equal(native[0].args.expectedSha256,archive1);
      assert.equal(native[0].args.executable,'game\\Coco.exe');
    }
  }
});

test('Host Studio UI resets confirmation on executable/archive changes and honors keyboard and small screens',()=>{
  assert.match(code,/setExecutableReviewKey\(''\);setExecutable\(event\.target\.value\)/);
  assert.match(code,/const inspected=await invoke<Inspection>\('inspect_standalone_archive',\{zipPath:chosen\.zip\}\)/);
  assert.match(code,/if\(flowGate\.current\.owns\(ticket\)\)\{\s*setZip\(chosen\.zip\);setCover\(chosen\.cover\);setExecutableReviewKey\(''\)/,
    'do not clear an accepted ZIP before its replacement has passed native inspection');
  assert.match(code,/checked=\{executableReviewed\}/);
  assert.match(code,/confirmar archivo que inicia el juego/);
  assert.match(code,/disabled=\{busy\|\|!urlValid\|\|missingItems\.length>0\}/);
  assert.match(css,/\.studio-executable-confirm:focus-within/);
  assert.doesNotMatch(code,/exec\(|spawn\(|Start-Process|powershell\.exe/);
});
