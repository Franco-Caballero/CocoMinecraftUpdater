// Fills src/game-screenshots.json with each game's official Steam screenshots, for the gallery
// in a game's detail view. Run when a game is added; the app itself never calls the Steam API.
//   node scripts/sync-steam-screenshots.mjs
import {readFile,writeFile} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const LIMIT=12;
const previews=JSON.parse(await readFile(resolve(root,'src/game-hover-previews.json'),'utf8'));
const out={};
for(const [id,{steamAppId}] of Object.entries(previews)){
  if(!steamAppId)continue;
  const response=await fetch(`https://store.steampowered.com/api/appdetails?appids=${steamAppId}&filters=screenshots`);
  const app=(await response.json())?.[steamAppId];
  const shots=(app?.success&&app.data?.screenshots)||[];
  // The 600x338 thumbnail looks soft at the drawer's width on HiDPI, and Steam has no size between.
  out[id]=shots.slice(0,LIMIT).map(shot=>shot.path_full.replace(/\?.*$/,''))
    .filter(url=>url.startsWith('https://'));
  console.log(`${id}: ${out[id].length}`);
}
await writeFile(resolve(root,'src/game-screenshots.json'),JSON.stringify(out,null,1)+'\n');
