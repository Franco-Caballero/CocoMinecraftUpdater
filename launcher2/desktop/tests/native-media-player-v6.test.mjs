import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
async function helper(){
  const file=await readFile(resolve(root,'src/media-playback-controls.ts'),'utf8');
  const js=ts.transpileModule(file,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{module,exports:module.exports});
  return module.exports;
}

test('seek clamps to finite duration and ignores malformed or unseekable sources',async()=>{
  const {seekRelative,resumeMediaPosition}=await helper();
  assert.equal(seekRelative(45,100,10),55);
  assert.equal(seekRelative(96,100,10),99.95);
  assert.equal(seekRelative(4,100,-10),0);
  for(const value of [0,NaN,Infinity,-Infinity,-3])assert.equal(seekRelative(8,value,10),null);
  assert.equal(seekRelative(Infinity,100,10),null);
  assert.equal(seekRelative(3,100,NaN),null);
  assert.equal(resumeMediaPosition(275,300),275);
  assert.equal(resumeMediaPosition(301,300),299.85);
  assert.equal(resumeMediaPosition(0.5,300),null);
  assert.equal(resumeMediaPosition(Infinity,300),null);
  assert.equal(resumeMediaPosition(20,Infinity),null);
});

test('keyboard shortcuts never steal focus/input/button or native video controls',async()=>{
  const {shouldHandlePlaybackKey}=await helper();
  for(const key of [' ','ArrowRight','ArrowLeft','ArrowUp','k','K','m','M','f','j','l','5']){
    assert.equal(shouldHandlePlaybackKey(key,{tagName:'DIV',hasAttribute:()=>false}),true,key);
    for(const tagName of ['INPUT','TEXTAREA','SELECT','VIDEO'])
      assert.equal(shouldHandlePlaybackKey(key,{tagName,hasAttribute:()=>false}),false,`${key}/${tagName}`);
    // The player's own buttons keep focus after a click: only Space is theirs, the rest still drives playback.
    assert.equal(shouldHandlePlaybackKey(key,{tagName:'BUTTON',hasAttribute:()=>false}),key!==' ',`${key}/BUTTON`);
    assert.equal(shouldHandlePlaybackKey(key,{tagName:'DIV',hasAttribute:()=>true}),false);
    assert.equal(shouldHandlePlaybackKey(key,null,true),false);
  }
  assert.equal(shouldHandlePlaybackKey('Escape',null,false),false);
});

test('media player keeps Coco controls and browser fallback while Windows uses its own decoder',async()=>{
  const [player,app,css]=await Promise.all([
    readFile(resolve(root,'src/MediaPlayer.tsx'),'utf8'),
    readFile(resolve(root,'src/main.tsx'),'utf8'),
    readFile(resolve(root,'src/cinema.css'),'utf8'),
  ]);
  assert.match(player,/<video ref=\{videoRef\} key=\{url\} src=\{native\?undefined:url\}/);
  assert.match(player,/useNativePlayback\(native,url/);
  assert.match(player,/playsInline preload="metadata" crossOrigin="anonymous"/);
  assert.doesNotMatch(player,/<video[^>]*\scontrols[\s>]/,'Coco draws its own controls over the native element');
  assert.match(player,/className="coco-player-scrub"|className=\{`coco-player-scrub/);
  assert.match(player,/onWaiting=\{event=>videoEvent\(event,'buffering'\)\}/);
  assert.match(player,/onLoadedMetadata=\{event=>\{/);
  assert.match(player,/onTimeUpdate=\{event=>\{/);
  assert.match(player,/resumeAfterRefresh\.current/);
  assert.match(player,/onError=\{event=>videoEvent\(event,'error'\)\}/);
  assert.match(player,/video\.pause\(\);[\s\S]*?queueMicrotask\(\(\)=>\{/);
  assert.match(player,/if\(video\.isConnected\)return;\s*video\.removeAttribute\('src'\);\s*video\.load\(\);/);
  assert.match(player,/onClick=\{\(\)=>void retry\(\)\}/);
  assert.match(player,/const epoch=\+\+playEpoch\.current/);
  assert.match(player,/if\(playEpoch\.current===epoch\)setState/);
  assert.doesNotMatch(player,/videojs|VideoSkin|VideoPlayer|hls\.js/i);
  assert.match(app,/LazyMediaPlayer=React\.lazy\(\(\)=>import\('\.\/MediaPlayer'\)\)/);
  assert.match(css,/\.coco-player-frame video\{/);
});
