import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const file=name=>readFile(resolve(root,name),'utf8');

test('game hover sources are curated, bounded, official Steam CDN media, never untrusted manifest URLs',async()=>{
  const [rawCatalog,rawPreviews]=await Promise.all([file('public/catalog.json'),file('src/game-hover-previews.json')]);
  const catalog=JSON.parse(rawCatalog);
  const videos=JSON.parse(rawPreviews);
  const standalone=new Set(catalog.filter(x=>x.workflow==='coco-standalone').map(x=>x.id));
  assert.ok(Object.keys(videos).length>=10,'use actual verified promotional footage, not placeholders');
  for(const [id,clip] of Object.entries(videos)){
    assert.ok(standalone.has(id),`not a standalone game: ${id}`);
    if(id==='yapyap'||id==='crack'){
      assert.equal(clip.url,`/previews/${id}-steam.mp4`);
      const video=await readFile(resolve(root,`public/previews/${id}-steam.mp4`));
      assert.equal(video.subarray(4,8).toString(),'ftyp');
      assert.equal(video.length,clip.bytes);
      assert.equal(clip.steamAppId,id==='yapyap'?3834090:4312190);
      continue;
    }
    const url=new URL(clip.url);
    assert.equal(url.protocol,'https:');
    assert.ok(['cdn.akamai.steamstatic.com','shared.akamai.steamstatic.com'].includes(url.hostname));
    assert.match(url.pathname,/\/(microtrailer\.webm|extras\/[0-9a-f]{32}\.mp4)$/);
    assert.ok(Number.isSafeInteger(clip.bytes)&&clip.bytes>10000&&clip.bytes<=6_000_000);
    assert.ok(Number.isSafeInteger(clip.steamAppId)&&clip.steamAppId>0);
  }
});

test('first paint preconnects the two curated Steam CDNs without embedding media assets',async()=>{
  const html=await file('index.html');
  assert.match(html,/<link rel="preconnect" href="https:\/\/cdn\.akamai\.steamstatic\.com" crossorigin\s*\/>/);
  assert.match(html,/<link rel="preconnect" href="https:\/\/shared\.akamai\.steamstatic\.com" crossorigin\s*\/>/);
  assert.doesNotMatch(html,/<video|<source/);
});

test('playing happens directly on mouse/pen hover and keyboard focus, muted, only one video per card',async()=>{
  const [ui,pool]=await Promise.all([file('src/main.tsx'),file('src/hover-video-pool.ts')]);
  assert.match(ui,/onPointerEnter=\{event=>\{cardActions\.current\.showStageArt\(entry\.image\);if\(motion&&event\.pointerType!=='touch'\)previewVideoInCard/);
  assert.match(ui,/onPointerLeave=\{event=>\{/);
  assert.match(ui,/matches\(':focus-visible'\)/);
  assert.match(ui,/if\(!article\.matches\(':hover'\)\)previewVideoInCard\(article,false\)/);
  assert.match(ui,/onFocus=\{event=>\{if\(motion\)previewVideoInCard/);
  assert.match(ui,/hoverVideoPool\.play\(id,card\.querySelector/);
  assert.match(ui,/hoverVideoPool\.pause\(id,card\.querySelector/);
  assert.match(ui,/<HoverPreview id=\{entry\.id\}\/>/);
  assert.match(pool,/void clip\.video\.play\(\)\.catch/);
  assert.match(pool,/clip\.video\.pause\(\)/);
  assert.match(pool,/clip\.video\.preload=tier==='metadata'\?'metadata':'auto'/);
  assert.match(pool,/video\.muted=true/);
  assert.match(pool,/video\.playsInline=true/);
  assert.match(pool,/video\.loop=true/);
  assert.doesNotMatch(ui,/autoPlay\s|autoPlay=/);
  assert.match(pool,/video\.addEventListener\('playing'/);
  assert.match(pool,/requestVideoFrameCallback/);
});

test('cover stays visible until playback actually starts and motion-off blocks preview',async()=>{
  const css=await file('src/experience-v2.css');
  assert.match(css,/\.card-hover-video\{[^}]*opacity:0/);
  assert.match(css,/\.card-image-button\.card-video-playing \.card-hover-video\{opacity:1\}/);
  assert.match(css,/body\[data-motion='off'\] \.coco2-desktop \.card-hover-video\{display:none\}/);
});

test('all curated clips queue automatically with bounded background requests and a shared player',async()=>{
  const [ui,pool,previews]=await Promise.all([file('src/main.tsx'),file('src/hover-video-pool.ts'),file('src/game-hover-previews.json')]);
  const items=JSON.parse(previews);
  assert.ok(Object.keys(items).length>=19);
  assert.match(ui,/hoverVideoPool\.start\(\)/);
  assert.match(ui,/hoverVideoPool\.prioritize\(items\.filter/);
  assert.match(ui,/hoverVideoPool\.setBackgroundBusy\(heavyWork\)/);
  assert.match(pool,/private readonly maxConcurrent=2/);
  assert.match(pool,/this\.sourceIds=Object\.keys\(sources\)/);
  assert.match(pool,/this\.sourceIds\[this\.scanCursor\]/);
  assert.match(ui,/hoverVideoPool\.registerSlot\(id,target\.current\)/);
  assert.match(pool,/document\.hidden/);
  assert.match(pool,/connection\?\.saveData/);
  assert.match(pool,/this\.stageElement\(\)\.appendChild\(video\)/);
  assert.match(pool,/this\.stageElement\(\)\.appendChild\(clip\.video\)/);
  assert.doesNotMatch(pool,/\bautoPlay\s*=/i);
});

test('hover displays a non-blocking loader until first decoded frame, then restores it on buffering',async()=>{
  const [pool,css]=await Promise.all([file('src/hover-video-pool.ts'),file('src/experience-v2.css')]);
  assert.match(pool,/clip\.host\.closest\('\.card-image-button'\)\?\.classList\.add\('card-video-loading'\)/);
  assert.match(pool,/video\.addEventListener\('waiting',buffering\)/);
  assert.match(pool,/video\.addEventListener\('stalled',buffering\)/);
  assert.match(pool,/callback\.call\(video,\(\)=>\{/);
  assert.match(pool,/video\.cancelVideoFrameCallback\?\.\(clip\.frameCallbackId\)/);
  assert.match(pool,/classList\.remove\('card-video-loading'\)/);
  assert.match(css,/\.card-video-loading:not\(\.card-video-playing\)::after\{[^}]*pointer-events:none/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});
