import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import ts from 'typescript';

async function subtitles(storage=new Map()){
  const code=await readFile(new URL('../src/subtitles.ts',import.meta.url),'utf8'),exports={};
  const localStorage={getItem:key=>storage.get(key)??null,setItem:(key,value)=>storage.set(key,String(value))};
  vm.runInNewContext(ts.transpileModule(code,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports,localStorage,Intl});
  return exports;
}
const plain=value=>JSON.parse(JSON.stringify(value));
const track=(id,language,label,extra={})=>({id,language,label,format:'ass',...extra});

test('Spanish is recognised by tag or by name, in its many spellings',async()=>{
  const {spanishScore,languageFamily}=await subtitles();
  for(const [language,label] of [['spa',''],['es',''],['es-419',''],['es-MX',''],['es_ES',''],['esp',''],['spa-LA',''],
    ['','Español latino'],['','Espanol'],['','Spanish (Latin America)'],['','Castellano'],['und','Latino'],['','[ES] Completos'],['','LATAM']]){
    assert.ok(spanishScore(track('x',language,label))>0,`${language}/${label}`);
    assert.equal(languageFamily(track('x',language,label)),'es');
  }
  for(const [language,label] of [['eng','English'],['jpn','日本語'],['por','Português'],['lat','Latin'],['','Esperanto'],['est','Eesti']])
    assert.equal(spanishScore(track('x',language,label)),0,`${language}/${label}`);
  assert.equal(languageFamily(track('x','eng','English')),'en');
});

test('the Spanish track is chosen by default, a full one over signs only, Latin American first; off stays off',async()=>{
  const {chooseTrack,DEFAULT_PREFS}=await subtitles();
  const tracks=[track('en','eng','English',{default:true}),track('signs','spa','Español (carteles)',{forced:true}),
    track('es','spa','Español (España)'),track('la','spa','Español latino')];
  assert.equal(chooseTrack(tracks,DEFAULT_PREFS).id,'la');
  assert.equal(chooseTrack(tracks,{...DEFAULT_PREFS,family:'en'}).id,'en','the viewer picked English before');
  assert.equal(chooseTrack(tracks,{...DEFAULT_PREFS,enabled:false}),null);
  assert.equal(chooseTrack([track('en','eng','English')],DEFAULT_PREFS),null,'no Spanish: nothing imposed');
  assert.equal(chooseTrack([track('only','und','Pista 1'),track('es','','Subtítulos en español')],DEFAULT_PREFS).id,'es');
});

test('preferences survive bad stored values',async()=>{
  const storage=new Map([['coco2.subtitles.v1','{"enabled":false,"family":"<x>","preset":"neon","size":"xl"}']]);
  const {readSubtitlePrefs,saveSubtitlePrefs}=await subtitles(storage);
  assert.deepEqual({...readSubtitlePrefs()},{enabled:false,family:'es',preset:'clasico',scale:1});
  storage.set('coco2.subtitles.v1','{"size":"l"}');
  assert.equal(readSubtitlePrefs().scale,1.24,'the first menu\'s three sizes carry over');
  saveSubtitlePrefs({enabled:true,family:'en',preset:'caja',scale:9});
  assert.equal(readSubtitlePrefs().scale,1.8,'clamped to the slider');
  saveSubtitlePrefs({enabled:true,family:'en',preset:'caja',scale:1.35});
  assert.deepEqual({...readSubtitlePrefs()},{enabled:true,family:'en',preset:'caja',scale:1.35});
});

test('a track\'s second line only says what its name does not',async()=>{
  const {trackDetail}=await subtitles();
  assert.equal(trackDetail(track('spa','spa','Español latino')),'');
  assert.equal(trackDetail(track('spa','spa','Espanol Latino [Fansub]')),'');
  assert.equal(trackDetail(track('spa','spa','Completos')),'Español');
  assert.equal(trackDetail(track('spa','es-419','Completos')),'Español latino');
  assert.equal(trackDetail(track('eng','eng','English')),'Inglés');
  assert.equal(trackDetail(track('s','spa','Español',{forced:true})),'Solo carteles');
});

test('ASS: styles, line breaks, italics, top lines, signs and drawings',async()=>{
  const {parseAss,activeCues,assColor}=await subtitles();
  const cues=parseAss(`[Script Info]
PlayResX: 848
PlayResY: 480

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Trebuchet MS,25,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,1.45,0.65,2,31,31,24,1
Style: Top,Trebuchet MS,23,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,1.4,0.65,8,31,31,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:03.26,0:00:07.23,Default,,0,0,0,,{\\be1}Desde que volví a París,\\Nme he esforzado, mucho.
Dialogue: 0,0:00:01.08,0:00:10.84,Top,,0,0,0,,Petición de {\\i1}Ichigo{\\i0}
Dialogue: 0,0:01:00.00,0:01:02.00,Default,,0,0,0,,{\\an8\\bord0\\c&H2117A3&\\fs25\\pos(680,109)}Pastelería
Dialogue: 0,0:01:00.00,0:01:02.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
Comment: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,nota
`);
  assert.equal(cues.length,3);
  const [top,dialogue,sign]=cues;
  assert.equal(top.align,8);assert.deepEqual(plain(top.lines[0].map(s=>[s.text,!!s.italic])),[['Petición de ',false],['Ichigo',true]]);
  assert.deepEqual(plain(dialogue.lines.map(line=>line.map(s=>s.text).join(''))),['Desde que volví a París,','me he esforzado, mucho.']);
  assert.equal(dialogue.look.font,'Trebuchet MS');assert.ok(Math.abs(dialogue.look.size-25/480)<1e-9);
  assert.ok(sign.sign);assert.equal(sign.align,8);assert.ok(Math.abs(sign.pos.x-680/848)<1e-9&&Math.abs(sign.pos.y-109/480)<1e-9);
  assert.equal(sign.look.color,'rgb(163,23,33)');
  assert.equal(assColor('&H80000000'),'rgba(0,0,0,0.498)');
  assert.deepEqual([...activeCues(cues,5)],[0,1]);assert.deepEqual([...activeCues(cues,9)],[0]);assert.deepEqual([...activeCues(cues,61)],[2]);
  assert.deepEqual([...activeCues(cues,20)],[]);
});

test('SRT and WebVTT',async()=>{
  const {parseSubtitles}=await subtitles();
  const cues=parseSubtitles(`1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>Hola</i> mundo\r\n&amp; adiós\r\n\r\n2\r\n00:00:04.000 --> 00:00:05.000 position:10%\r\n{\\an8}Arriba\r\n`,'srt');
  assert.equal(cues.length,2);
  assert.deepEqual(plain(cues[0].lines.map(line=>line.map(s=>s.text+(s.italic?'/i':'')).join('|'))),['Hola/i| mundo','& adiós']);
  assert.equal(cues[0].start,1.5);assert.equal(cues[1].align,8);
});

test('the real Yumeiro Patissiere 41 track reads completely',async(t)=>{
  const path='D:/CocoWork/yumeiro-publish/Yumeiro.Patissiere.41.1080p.1.spa.ass';
  const text=await readFile(path,'utf8').catch(()=>null);
  if(!text){t.skip('track not on this PC');return;}
  const {parseAss}=await subtitles();
  const cues=parseAss(text);
  assert.ok(cues.length>=340,`${cues.length}`);
  assert.ok(cues.every(cue=>cue.lines.every(line=>line.every(span=>!/[{}\\]/.test(span.text)))),'no override tags leak into the text');
  assert.ok(cues.some(cue=>cue.align===8),'the opening notice sits at the top');
  assert.ok(cues.filter(cue=>cue.sign).length>=1);
});
