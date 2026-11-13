import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
test('verified catalog renders before independent diagnostics complete',async()=>{
  const ui=await readFile(resolve(root,'src/main.tsx'),'utf8');
  const start=ui.indexOf('const result:Experience[]=isTauri()');
  const end=ui.indexOf('  },[]);',start);
  assert.ok(start>=0&&end>start);
  const bootstrap=ui.slice(start,end);
  assert.match(bootstrap,/if\(trustedCatalogSnapshot\.current\.size===0\)\{/);
  assert.match(bootstrap,/trustedCatalogSnapshot\.current=new Map\(result\.map/);
  assert.match(bootstrap,/setItems\(result\)/);
  assert.match(bootstrap,/void Promise\.allSettled\(\[/);
  for(const command of ['get_local_instances','get_catalog_provenance','get_local_identity','host_studio_available']){
    assert.match(bootstrap,new RegExp(`invoke<[^>]*>\\('${command}'\\)`));
  }
  assert.doesNotMatch(bootstrap,/await invoke<EngineStatus>|await invoke<LocalInstance\[\]>|await invoke<CatalogProvenance\[\]>/);
  assert.match(bootstrap,/if\(active\)/);
  assert.match(bootstrap,/finally\(\(\)=>\{if\(active\)setBootstrapLoaded\(true\);\}\)/);
});
