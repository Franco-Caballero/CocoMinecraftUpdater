import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {mediaRecords,mediaPayload,MEDIA_HEAD,mediaBodyName} from '../scripts/Publish-Coco2Media.mjs';
import {channelCandidates} from '../scripts/Publish-Coco2Catalog.mjs';

const read=path=>readFile(fileURLToPath(new URL(`../${path}`,import.meta.url)),'utf8');

test('every movie and series goes on its own signed channel, never the games one',async()=>{
  const template=JSON.parse(await read('../../launcher/catalog.template.json'));
  const media=await mediaRecords(template.experiences,async()=> 'data:image/webp;base64,UklGRg==');
  const ids=template.experiences.filter(e=>e.launch?.workflow==='coco-media').map(e=>e.id);
  assert.deepEqual(media.map(m=>m.entry.id),ids);
  for(const {entry,manifest} of media){
    assert.equal(entry.workflow,'coco-media');assert.equal(manifest.id,entry.id);
    assert.ok(manifest.episodes.length>0);
    assert.ok(entry.image.startsWith('data:image/'),'the cover travels inside the signed body');
  }
  const yumeiro=media.find(m=>m.entry.id==='yumeiro-patissiere');
  assert.ok(yumeiro.manifest.episodes.every(e=>e.subtitles?.length===1),'its subtitle tracks ride along');
  assert.deepEqual(Object.keys(mediaPayload(4,media)),['schemaVersion','sequence','media']);
  assert.equal(MEDIA_HEAD,'coco2-media-head.json');assert.equal(mediaBodyName(4),'coco2-media-s4.json');
  // Older clients reject a games channel holding anything else.
  assert.ok(channelCandidates(template.experiences,{games:{}}).every(e=>e.launch.workflow==='coco-standalone'));
});

test('the client reads the media channel next to the games one and lets it extend the library',async()=>{
  const channel=await read('src-tauri/src/services/catalog/../catalog_channel.rs');
  assert.match(channel,/crate::services::media_channel::sync\(&key\)/);
  const catalog=await read('src-tauri/src/services/catalog.rs');
  assert.match(catalog,/media_channel::accepted\(\)/);
  const media=await read('src-tauri/src/services/media.rs');
  assert.match(media,/fn private_catalog\(\)[\s\S]*media_channel::accepted\(\)/);
  const main=await read('src/main.tsx');
  assert.match(main,/mediaCatalogEpoch\.current===catalogEpoch/,'a new episode shows without restarting Coco');
});
