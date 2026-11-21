/** Subtitle tracks Coco draws over the picture itself: reading ASS/SSA and SRT/VTT, choosing the
 * Spanish track on its own, and the viewer's style. The engine draws none of these, so the film
 * keeps decoding on the graphics card and the text can take any style. */

export type SubtitleTrack={id:string;label:string;language:string;format:string;default?:boolean;forced?:boolean};
export type Span={text:string;italic?:boolean;bold?:boolean};
/** The look a cue has in the file; used by the «Original» style and by signs. */
export type CueLook={color?:string;outline?:string;font?:string;size?:number;bold?:boolean;italic?:boolean};
/** `align` is the numpad position (1 bottom-left … 9 top-right). `pos` is a point on the picture
 * (0–1) for on-screen signs; their `look.size` is relative to the picture height. */
export type Cue={start:number;end:number;lines:Span[][];align:number;pos?:{x:number;y:number};look:CueLook;sign:boolean};

// ---------------------------------------------------------------------------
// Choosing a track
// ---------------------------------------------------------------------------

/** es, spa, esp, spn and their regional forms (es-419, es-MX, es_ES, spa-LA…). */
const SPANISH_CODE=/^(es|spa|esp|spn|sp)([-_][a-z0-9]{2,8})*$/i;
/** Names a track can carry instead of (or besides) a language tag. */
const SPANISH_NAME=/(espa[nñ]ol|espanol|spanish|castellano|castilian|latino|latina|latam|latinoam[eé]rica|hispano|hispanic|mexicano|neutro|\bes[-_](419|la|lat|mx|ar|cl|co|pe|us|es)\b|\[es\]|\(es\)|\bspa\b|\besp\b|\bes\b)/i;
const LATIN_AMERICAN=/(latino|latina|latam|latinoam[eé]rica|419|\bla\b|\blat\b|mexicano|\bmx\b|neutro|\bar\b|\bcl\b|\bco\b|\bpe\b)/i;
const SIGNS_ONLY=/(forzad|forced|signs?\b|carteles|letreros|songs?\b|canciones)/i;

/** How Spanish a track looks: 0 when it does not. */
export function spanishScore(track:SubtitleTrack){
  const code=SPANISH_CODE.test(track.language.trim());
  const name=SPANISH_NAME.test(track.label);
  if(!code&&!name)return 0;
  let score=(code?3:0)+(name?2:0);
  // Friends watch in Latin American Spanish; a full track beats signs only.
  if(LATIN_AMERICAN.test(`${track.language} ${track.label}`))score+=.5;
  if(track.forced||SIGNS_ONLY.test(track.label))score-=2.5;
  if(track.default)score+=.25;
  return Math.max(.1,score);
}

const CODES:Record<string,string>={spa:'es',esp:'es',spn:'es',eng:'en',jpn:'ja',jap:'ja',por:'pt',fre:'fr',fra:'fr',ger:'de',deu:'de',ita:'it',
  kor:'ko',chi:'zh',zho:'zh',rus:'ru',ara:'ar',hin:'hi',tur:'tr',pol:'pl',dut:'nl',nld:'nl',swe:'sv',cat:'ca',tha:'th',vie:'vi',ind:'id'};

/** The two-letter family of a track ('es', 'en'…), or '' when unknown. */
export function languageFamily(track:SubtitleTrack){
  if(spanishScore(track)>0)return 'es';
  const code=track.language.trim().toLowerCase().split(/[-_]/)[0]||'';
  return CODES[code]??(code.length===2?code:'');
}

/** «Español», «Inglés»… for the small tag next to a track. */
export function languageName(track:SubtitleTrack){
  const family=languageFamily(track);
  if(family==='es')return LATIN_AMERICAN.test(`${track.language} ${track.label}`)?'Español latino':'Español';
  if(!family)return '';
  try{const name=new Intl.DisplayNames(['es'],{type:'language'}).of(family);return name?name.charAt(0).toUpperCase()+name.slice(1):family.toUpperCase();}
  catch{return family.toUpperCase();}
}

export type SubtitlePreset='clasico'|'caja'|'amarillo'|'original';
/** `scale` multiplies the text size: 1 is the usual size, set with a slider. */
export type SubtitlePrefs={enabled:boolean;family:string;preset:SubtitlePreset;scale:number};
export const SUBTITLE_PRESETS:{id:SubtitlePreset;label:string;hint:string}[]=[
  {id:'clasico',label:'Clásico',hint:'Blanco con borde'},
  {id:'caja',label:'Caja',hint:'Sobre fondo oscuro'},
  {id:'amarillo',label:'Amarillo',hint:'Como en el cine'},
  {id:'original',label:'Original',hint:'Colores del archivo'},
];
export const SUBTITLE_SCALE={min:.6,max:1.8,step:.05};
export const clampScale=(value:number)=>Number.isFinite(value)?Math.round(Math.min(SUBTITLE_SCALE.max,Math.max(SUBTITLE_SCALE.min,value))*100)/100:1;
/** Sizes saved by the first version of the menu (three buttons). */
const LEGACY_SIZES:Record<string,number>={s:.82,m:1,l:1.24};
const PREFS_KEY='coco2.subtitles.v1';
export const DEFAULT_PREFS:SubtitlePrefs={enabled:true,family:'es',preset:'clasico',scale:1};

export function readSubtitlePrefs():SubtitlePrefs{
  try{
    const saved=JSON.parse(localStorage.getItem(PREFS_KEY)||'null');
    if(!saved||typeof saved!=='object')return DEFAULT_PREFS;
    return {
      enabled:saved.enabled!==false,
      family:typeof saved.family==='string'&&/^[a-z]{0,3}$/.test(saved.family)?saved.family:'es',
      preset:SUBTITLE_PRESETS.some(p=>p.id===saved.preset)?saved.preset:DEFAULT_PREFS.preset,
      scale:typeof saved.scale==='number'?clampScale(saved.scale):LEGACY_SIZES[saved.size]??DEFAULT_PREFS.scale,
    };
  }catch{return DEFAULT_PREFS;}
}
export function saveSubtitlePrefs(prefs:SubtitlePrefs){
  try{localStorage.setItem(PREFS_KEY,JSON.stringify(prefs));}catch{/* chosen again next time */}
}

/** The track to show: the viewer's language when the film has it, otherwise Spanish; none when off
 * or when the film has neither (a track in another language is offered in the menu, not imposed). */
const plainText=(text:string)=>text.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();
/** The small line under a track's name: its language and «Solo carteles», minus what the name
 * already says («Español latino» named «Español latino» gets no second line). */
export function trackDetail(track:SubtitleTrack){
  const language=languageName(track),name=plainText(track.label);
  const parts=[language&&!name.includes(plainText(language))?language:'',track.forced?'Solo carteles':''];
  return parts.filter(Boolean).join(' · ');
}

export function chooseTrack(tracks:readonly SubtitleTrack[],prefs:SubtitlePrefs):SubtitleTrack|null{
  if(!prefs.enabled||!tracks.length)return null;
  const best=(family:string)=>{
    let chosen:SubtitleTrack|null=null,top=-Infinity;
    for(const track of tracks){
      if(languageFamily(track)!==family)continue;
      const score=(family==='es'?spanishScore(track):1)-(track.forced?2.5:0)+(track.default?.25:0);
      if(score>top){top=score;chosen=track;}
    }
    return chosen;
  };
  return (prefs.family&&best(prefs.family))||best('es');
}

// ---------------------------------------------------------------------------
// Reading files
// ---------------------------------------------------------------------------

const time=(text:string)=>{
  const match=/^\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?\s*$/.exec(text);
  if(!match)return NaN;
  const fraction=match[4]?Number(match[4])/10**match[4].length:0;
  return Number(match[1]||0)*3600+Number(match[2])*60+Number(match[3])+fraction;
};

/** &HAABBGGRR (or &HBBGGRR) to a CSS color; ASS alpha 00 is opaque. */
export function assColor(value:string|undefined){
  if(!value)return undefined;
  const hex=/&?H?([0-9a-f]{1,8})&?/i.exec(value.trim())?.[1];
  if(!hex)return undefined;
  const n=parseInt(hex.padStart(8,'0'),16);
  const a=1-((n>>>24)&255)/255,b=(n>>>16)&255,g=(n>>>8)&255,r=n&255;
  return a>=.999?`rgb(${r},${g},${b})`:`rgba(${r},${g},${b},${a.toFixed(3)})`;
}

type Style={look:CueLook;align:number};
const legacyAlign=(value:number)=>value>=9?value-5:value>=5?value+2:value; // SSA: 5-7 top, 9-11 middle

function splitFields(line:string,count:number){
  const fields:string[]=[];let rest=line;
  for(let index=0;index<count-1;index++){
    const at=rest.indexOf(',');if(at<0)break;
    fields.push(rest.slice(0,at));rest=rest.slice(at+1);
  }
  fields.push(rest);return fields;
}

/** Dialogue text to lines of spans, with the alignment, point and look its override tags ask for. */
function assText(raw:string,base:Style,playX:number,playY:number){
  let italic=base.look.italic===true,bold=base.look.bold===true,drawing=false;
  let align=base.align;let pos:{x:number;y:number}|undefined;
  const look:CueLook={...base.look};
  const lines:Span[][]=[[]];
  const push=(text:string)=>{
    if(drawing||!text)return;
    const parts=text.replace(/\\h/g,' ').replace(/\\n/g,' ').split('\\N');
    parts.forEach((part,index)=>{
      if(index>0)lines.push([]);
      if(part)lines[lines.length-1].push({text:part,...(italic?{italic:true}:{}),...(bold?{bold:true}:{})});
    });
  };
  const pattern=/\{([^}]*)\}/g;let last=0,match:RegExpExecArray|null;
  while((match=pattern.exec(raw))){
    push(raw.slice(last,match.index));last=match.index+match[0].length;
    for(const tag of match[1].split('\\').slice(1)){
      let m:RegExpExecArray|null;
      if((m=/^i(\d?)$/.exec(tag)))italic=m[1]!=='0';
      else if((m=/^b(\d*)$/.exec(tag)))bold=m[1]!=='0'&&m[1]!=='';
      else if((m=/^an([1-9])$/.exec(tag)))align=Number(m[1]);
      else if((m=/^a(\d{1,2})$/.exec(tag)))align=legacyAlign(Number(m[1]));
      else if((m=/^(?:pos|move)\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)/.exec(tag)))pos={x:Number(m[1])/playX,y:Number(m[2])/playY};
      else if((m=/^p(\d+)$/.exec(tag)))drawing=Number(m[1])>0;
      else if((m=/^fs([\d.]+)$/.exec(tag)))look.size=Number(m[1])/playY;
      else if((m=/^1?c(&H[0-9a-f]+&?)$/i.exec(tag)))look.color=assColor(m[1]);
      else if((m=/^3c(&H[0-9a-f]+&?)$/i.exec(tag)))look.outline=assColor(m[1]);
      else if(tag==='r'){italic=base.look.italic===true;bold=base.look.bold===true;}
    }
  }
  push(raw.slice(last));
  const cleaned=lines.map(line=>line.filter(span=>span.text.trim()!==''||line.length>1)).filter(line=>line.some(span=>span.text.trim()!==''));
  return {lines:cleaned,align,pos,look:{...look,italic:undefined,bold:undefined}};
}

export function parseAss(text:string):Cue[]{
  let section='',playX=0,playY=0;
  let styleFormat:string[]=[],eventFormat:string[]=[];
  const styles=new Map<string,Style>();
  const events:string[]=[];
  for(const rawLine of text.split(/\r?\n/)){
    const line=rawLine.trim();
    if(!line||line.startsWith(';'))continue;
    const header=/^\[(.+)\]$/.exec(line);
    if(header){section=header[1].toLowerCase();continue;}
    const colon=line.indexOf(':');if(colon<0)continue;
    const key=line.slice(0,colon).trim().toLowerCase(),value=line.slice(colon+1).trim();
    if(section==='script info'){
      if(key==='playresx')playX=Number(value)||0;
      if(key==='playresy')playY=Number(value)||0;
    }else if(section.includes('styles')){
      if(key==='format')styleFormat=value.split(',').map(f=>f.trim().toLowerCase());
      else if(key==='style'&&styleFormat.length){
        const fields=splitFields(value,styleFormat.length);
        const field=(name:string)=>fields[styleFormat.indexOf(name)]?.trim();
        const alignment=Number(field('alignment')||2);
        styles.set((field('name')||'Default').toLowerCase(),{
          align:section.includes('v4+')?alignment:legacyAlign(alignment),
          look:{color:assColor(field('primarycolour')),outline:assColor(field('outlinecolour')),font:field('fontname'),
            size:Number(field('fontsize'))||undefined,bold:field('bold')!==undefined&&field('bold')!=='0',italic:field('italic')!==undefined&&field('italic')!=='0'},
        });
      }
    }else if(section==='events'){
      if(key==='format')eventFormat=value.split(',').map(f=>f.trim().toLowerCase());
      else if(key==='dialogue')events.push(value);
    }
  }
  // Libass defaults: 384×288 when neither is given, and a missing one follows the other's 4:3.
  if(!playX&&!playY){playX=384;playY=288;}
  else if(!playY)playY=playX===1280?1024:playX*3/4;
  else if(!playX)playX=playY===1024?1280:playY*4/3;
  if(!eventFormat.length)eventFormat=['layer','start','end','style','name','marginl','marginr','marginv','effect','text'];
  const fallback:Style={align:2,look:{}};
  const cues:Cue[]=[];
  for(const value of events){
    const fields=splitFields(value,eventFormat.length);
    const field=(name:string)=>fields[eventFormat.indexOf(name)]??'';
    const start=time(field('start')),end=time(field('end'));
    if(!(end>start))continue;
    const style=styles.get(field('style').trim().toLowerCase())??styles.get('default')??fallback;
    const base:Style={align:style.align,look:{...style.look,size:style.look.size?style.look.size/playY:undefined}};
    const parsed=assText(field('text'),base,playX,playY);
    if(!parsed.lines.length)continue;
    cues.push({start,end,lines:parsed.lines,align:parsed.align,pos:parsed.pos,look:parsed.look,sign:parsed.pos!==undefined});
  }
  return cues.sort((a,b)=>a.start-b.start||a.end-b.end);
}

/** SRT and WebVTT: numbered or not, `,` or `.` for milliseconds, <i>/<b> and {\an8}. */
export function parseSrt(text:string):Cue[]{
  const cues:Cue[]=[];
  for(const block of text.replace(/\r/g,'').split(/\n{2,}/)){
    const rows=block.split('\n').filter(Boolean);
    const at=rows.findIndex(row=>row.includes('-->'));if(at<0)continue;
    const [from,to]=rows[at].split('-->');
    const start=time(from),end=time((to||'').trim().split(/\s+/)[0]);
    if(!(end>start))continue;
    let align=2;
    const lines:Span[][]=[];
    for(const row of rows.slice(at+1)){
      let italic=false,bold=false;const spans:Span[]=[];
      const anchor=/\{\\an([1-9])\}/.exec(row);if(anchor)align=Number(anchor[1]);
      const clean=row.replace(/\{\\[^}]*\}/g,'');
      for(const piece of clean.split(/(<\/?[ib]>|<[^>]+>)/i)){
        const tag=/^<(\/?)([ib])>$/i.exec(piece);
        if(tag){if(tag[2].toLowerCase()==='i')italic=!tag[1];else bold=!tag[1];continue;}
        if(/^<[^>]+>$/.test(piece)||!piece)continue;
        const decoded=piece.replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&nbsp;/g,' ');
        spans.push({text:decoded,...(italic?{italic:true}:{}),...(bold?{bold:true}:{})});
      }
      if(spans.some(span=>span.text.trim()))lines.push(spans);
    }
    if(lines.length)cues.push({start,end,lines,align,look:{},sign:false});
  }
  return cues.sort((a,b)=>a.start-b.start||a.end-b.end);
}

export function parseSubtitles(text:string,format:string):Cue[]{
  return format==='ass'||format==='ssa'||/^\s*\[Script Info\]/i.test(text)?parseAss(text):parseSrt(text);
}

/** Indexes of the cues on screen at `seconds`; cues are sorted by start. */
export function activeCues(cues:readonly Cue[],seconds:number){
  const shown:number[]=[];
  // Cues start in order: skip straight past the ones that start later.
  let low=0,high=cues.length;
  while(low<high){const mid=(low+high)>>1;if(cues[mid].start<=seconds)low=mid+1;else high=mid;}
  for(let index=0;index<low;index++)if(cues[index].end>seconds)shown.push(index);
  return shown;
}
