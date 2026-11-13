// The sheet shows what a game occupies and removes it deliberately; the profile is a
// name and one small picture; and what the player does not need stays out of sight.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const read=path=>readFile(resolve(root,path),'utf8');
async function load(path){
  const js=ts.transpileModule(await read(path),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{exports:module.exports,module,require:()=>({})});
  return module.exports;
}

test('what the player asked to remove is gone from the interface',async()=>{
  const ui=await read('src/main.tsx');
  for(const text of ['Seguridad y distribución','Rendimiento de las vistas previas','Usando la biblioteca','Mantenimiento y ayuda','Integridad','Recuperar juego','Partidas protegidas','¿Windows bloqueó un archivo?','Sin borrar partidas','Preparando vistas previas'])
    assert.ok(!ui.includes(text),text);
  assert.ok(!(await read('src/launcher-status.ts')).includes('vistas previas'));
});

test('a Minecraft pack only says it is disabled',async()=>{
  const ui=await read('src/main.tsx');
  for(const text of ['Coco 2 todavía no abre Minecraft','Pack Minecraft','Verificar pack','plan_managed'])assert.ok(!ui.includes(text),text);
  assert.match(ui,/isComingSoon\(selected\)&&<button className="primary-button" disabled>Desactivado<\/button>/);
  assert.match(ui,/soon\?'Desactivado':''/);
});

test('a plan that needs nothing from the player shows nothing, and raw messages stay out',async()=>{
  const ui=await read('src/main.tsx');
  assert.match(ui,/\['upgrade-ready','recovery-required','recovery-blocked'\]\.includes\(upgradePlan\.status\)/);
  assert.doesNotMatch(ui,/<p>\{upgradePlan\.message\}<\/p>/,'Recibo Coco2 ausente must never be rendered');
});

test('uninstall needs two clicks, runs through the single-flight gate and stays honest about saves',async()=>{
  const ui=await read('src/main.tsx');
  const body=ui.slice(ui.indexOf('const uninstallNative=async'),ui.indexOf('const chooseAvatar=async'));
  assert.match(body,/nativeOperationGate\.current\.begin\(entry\.id,'uninstall'\)/);
  assert.match(body,/invoke<UninstallOutcome>\('uninstall_standalone',\{id:entry\.id\}\)/);
  assert.match(ui,/onClick=\{\(\)=>\{setMoveDraft\(null\);setUninstallConfirm\(selected\.id\);\}\}/,'the first click only asks');
  assert.match(ui,/<button autoFocus className="filter-button" onClick=\{\(\)=>setUninstallConfirm\(null\)\}>Conservar/,'keeping the game is the default');
  assert.match(ui,/Coco guarda las carpetas de partidas que encuentre/);
});

test('native uninstall refuses active games, pending journals and foreign folders',async()=>{
  const rust=await read('src-tauri/src/services/uninstall.rs');
  assert.match(rust,/standalone::is_game_active\(&id,&runtime\)\.await/);
  assert.match(rust,/install::reserve_exclusive\(&id,&install_state\)/);
  assert.match(rust,/owns_folder\(&root,custom,&entry\.instance_id,&entry\.executable\)/);
  assert.match(rust,/install::assert_can_remove\(/);
  assert.match(await read('src-tauri/src/services/install.rs'),/restore_kept_saves\(&target, &m\.instance_id\)/);
});

test('a game can be placed before installing and moved afterwards, always through the gate',async()=>{
  const ui=await read('src/main.tsx');
  assert.match(ui,/open\(\{directory:true,multiple:false/,'the native folder picker');
  assert.match(ui,/invoke<InstallLocation>\('set_install_location',\{id:entry\.id,parent\}\)/);
  const move=ui.slice(ui.indexOf('const moveInstallation=async'),ui.indexOf('const uninstallNative=async'));
  assert.match(move,/nativeOperationGate\.current\.begin\(entry\.id,'move'\)/);
  assert.match(move,/nativeOperationGate\.current\.finish\(ticket\)/);
  assert.match(ui,/<button autoFocus className="filter-button" onClick=\{\(\)=>setMoveDraft\(null\)\}>Dejarlo aquí/,'staying put is the default');
  const rust=await read('src-tauri/src/services/location.rs');
  assert.match(rust,/standalone::is_game_active\(&id,&runtime\)\.await/);
  assert.match(rust,/install::assert_can_remove\(/);
  assert.match(rust,/uninstall::owns_folder\(/);
  assert.ok(rust.indexOf('save(target.as_deref())?;\n    let trash=')>0,'the record changes before the original goes');
  const lib=await read('src-tauri/src/lib.rs');
  for(const command of ['get_install_location','check_install_location','set_install_location','move_installation','open_game_folder'])assert.match(lib,new RegExp(`services::location::${command}`));
});

test('long folders keep what tells them apart',async()=>{
  const {shortPath}=await load('src/library-view.ts');
  assert.equal(shortPath('D:\\Juegos\\pilgrim'),'D:\\Juegos\\pilgrim');
  const short=shortPath('C:\\Users\\smol\\AppData\\Roaming\\CocoMinecraft\\experiences\\pilgrim');
  assert.ok(short.startsWith('C:\\…\\')&&short.endsWith('experiences\\pilgrim'),short);
  assert.ok(short.length<=44);
});

test('the presentation starts in its color, covers the window in the chip\'s shape and lands on it exactly',async()=>{
  const source=await read('src/LauncherIntro.tsx');
  const body=source.slice(source.indexOf('const CHIP_SLANT_PX'),source.indexOf('export default'));
  const js=ts.transpileModule(body,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(js,{exports:module.exports,module,Math,Array});
  const {coverScale,foldProgress,twoPose}=module.exports;
  const chip={left:230,top:133,width:27,height:25};
  const view={width:1280,height:820};
  const scale=coverScale(chip,view);
  const cx=chip.left+chip.width/2,cy=chip.top+chip.height/2;
  // Top edge leans right: x bounds at a height shift by the slant.
  for(const [x,y] of [[0,0],[view.width,0],[0,view.height],[view.width,view.height]]){
    const rx=(x-cx)/scale,ry=(y-cy)/scale;
    assert.ok(Math.abs(ry)<=chip.height/2,'corner within the height');
    const shift=-ry/chip.height*6;
    assert.ok(Math.abs(rx-shift)<=chip.width/2-3,`corner ${x},${y} is covered`);
  }
  assert.equal(foldProgress(1,scale),1,'ends exactly on the real chip');
  assert.equal(foldProgress(0,scale),scale);
  let last=scale;
  for(let p=.02;p<.88;p+=.02){const now=foldProgress(p,scale);assert.ok(now<=last);last=now;}
  assert.ok(foldProgress(.9,scale)<1,'dips under its size so the landing has weight');
  // The 2 never leaves the shape carrying it: the case that showed it alone on the dark library.
  const giant=28,dx=510,dy=265,reachX=chip.width/2/dx,reachY=chip.height/2/dy;
  assert.deepEqual({...twoPose(1,giant,reachX,reachY)},{scale:1,away:0},'lands centered on the chip');
  assert.equal(twoPose(scale,giant,reachX,reachY).away,1,'waits at the center while the color still covers everything');
  for(let p=0;p<=1.0001;p+=.01){
    const shape=foldProgress(Math.min(p,1),scale);
    const {scale:two,away}=twoPose(shape,giant,reachX,reachY);
    assert.ok(two<=shape,'never bigger than its shape');
    {
      assert.ok(dx*away<=shape*chip.width/2,`inside horizontally at ${p}`);
      assert.ok(dy*away<=shape*chip.height/2,`inside vertically at ${p}`);
    }
  }
  assert.ok(source.includes("const RISE_MS=300")&&source.includes("const FOLD_MS=780"),'about a second and a half in total');
  assert.match(source,/onPointerDown=/);
  assert.match(source,/addEventListener\('keydown',finish\)/);
  const html=await read('index.html');
  assert.match(html,/html\.coco-booting,html\.coco-booting body\{background:#e23df5!important\}/,'the first frame already has the color');
  assert.match(html,/prefers-reduced-motion:reduce/);
  const config=JSON.parse(await read('src-tauri/tauri.conf.json'));
  assert.equal(config.app.windows[0].backgroundColor,'#e23df5');
  const ui=await read('src/main.tsx');
  assert.match(ui,/useState<'hold'\|'reveal'\|'done'\|'none'>\(motion\?'hold':'none'\)/,'reduced motion skips it');
  assert.match(ui,/setBackgroundColor\('#0b0a0f'\)/);
  assert.doesNotMatch(await read('src/coco-ui.css'),/coco-chip-land/,'no pulse restarts the chip after landing');
});

test('sizes read naturally',async()=>{
  const {formatBytes}=await load('src/library-view.ts');
  assert.equal(formatBytes(5*1024**2),'5 MB');
  assert.equal(formatBytes(0),'1 MB');
  assert.match(formatBytes(2.5*1024**3),/^2,5 GB$/);
});

test('the profile picture is shrunk by the page and only a small WebP reaches disk',async()=>{
  const ui=await read('src/main.tsx');
  assert.match(ui,/createImageBitmap\(file\)/);
  assert.match(ui,/canvas\.toDataURL\('image\/webp',\.86\)/);
  assert.match(ui,/accept="image\/png,image\/jpeg,image\/webp,image\/gif"/,'no SVG: it could carry script');
  const lib=await read('src-tauri/src/lib.rs');
  for(const command of ['get_profile_avatar','set_profile_avatar','remove_profile_avatar'])assert.match(lib,new RegExp(`services::identity::${command}`));
});

test('card tilt stays inside its limit, even with the pointer outside the card',async()=>{
  const {tiltFor}=await load('src/stage-motion.ts');
  const corner=tiltFor(0,0,200,100);
  assert.equal(corner.rotateX,12.65);assert.equal(corner.rotateY,-12.65);
  const outside=tiltFor(9999,-50,200,100);
  assert.equal(outside.rotateY,12.65);assert.equal(outside.glareX,100);assert.equal(outside.glareY,0);
  assert.equal(tiltFor(100,50,200,100).rotateY,0);
});

test('ambient motion respects the player: reduced motion, and silence while a game is open',async()=>{
  const css=await read('src/coco-ui.css');
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)\{\.coco2-desktop \*/);
  assert.match(css,/\[data-tone='playing'\] \.coco-ambience \*[^{]*\{animation-play-state:paused\}/);
  assert.match(css,/animation:coco-card-in [^;]*backwards/,'filling forwards would cancel every hover transform');
});
