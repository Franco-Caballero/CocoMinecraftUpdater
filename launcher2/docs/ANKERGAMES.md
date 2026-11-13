# AnkerGames: notas del agente

Documento de trabajo para agregar juegos de `ankergames.net` a Coco Launcher 2. Complementa [`AGENT_ADD_GAME.md`](AGENT_ADD_GAME.md); no lo sustituye. Aquí se acumula lo que ya funcionó, los selectores/endpoints, los tropiezos y los datos de cada alta.

## Regla de oro

- **Todo lo pesado vive en `D:`** (`D:\CocoWork\<id>`): ZIP descargado, extracción, partes, caché de prueba e instalación nativa. Nunca dejes el ZIP grande en `%USERPROFILE%\.t3\userdata\server-browser\downloads` (C:).
- **Descarga desatendida**: el navegador solo se usa para *mintear* el enlace; el archivo grande se baja con `curl -L` directo a `D:`. Sin diálogo de guardar, sin esperar la cuenta atrás con la pestaña oculta.
- El ZIP de AnkerGames se **reempaqueta** (no se sube tal cual): hay que quitar el `1337` del `OnlineFix.ini`, los accesos `.url` y los archivos promocionales.
- `%TEMP%`/`%TMP%` del proceso apuntan a `D:\CocoWork\<id>\temp` antes de invocar scripts Python/PowerShell pesados.

## Flujo probado (Gang Beasts, Pummel, Grocery y Paint; 1,0–6,6 GB)

### 1. Abrir la ficha y obtener el `downloadId`

La ficha es `https://ankergames.net/game/<slug>`. En el HTML hay un modal Alpine con:

```html
<a class="download-button" @click.prevent="generateDownloadUrl(198)">Download</a>
```

Ese `198` es el **downloadId** (no el id de la ficha: Gang Beasts es `ankergames://game/210`). Búscalo con:

```js
[...document.querySelectorAll('[role="dialog"] a.download-button')]
  .map(a => a.getAttribute('@click.prevent'))
```

Si el modal aún no está en el DOM, el botón principal tiene `@click="$dispatch('open-download-modal')"`; el modal real se teleporta a `<body>`.

### 2. Mintear el enlace de descarga

El POST a `/generate-download-url/<downloadId>` requiere CSRF y pasa por Cloudflare. **Cloudflare bloquea el POST hecho con `curl`** (devuelve el HTML de "Just a moment..."). Hazlo desde la sesión del navegador:

```js
const meta = document.querySelector('meta[name="csrf-token"]');
const r = await fetch('/generate-download-url/198', {
  method: 'POST',
  headers: {'Content-Type': 'application/json', 'X-CSRF-TOKEN': meta.content},
  body: '{}'
});
const {download_url} = await r.json();
```

`download_url` es `https://ankergames.net/download/<payload>/<hash>`.

### 3. Leer el enlace final desde la página de descarga

Navega a `download_url` y espera a que exista `a.download-button` (la página muestra "Download Ready 100%"). Su `href` es:

```
https://ankergames.net/download-file/<token>
```

Ese `download-file` responde `302` a `https://tunnel5.dlproxy.uk/download/ag1...`. **No necesita cookies** y se puede bajar con `curl`:

```powershell
curl.exe -L --fail --retry 3 --retry-delay 5 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
  -o 'D:\CocoWork\gang-beasts\Gang-Beasts-AnkerGames.zip' `
  "https://ankergames.net/download-file/<token>"
```

Comprueba `Content-Length` con `curl -sIL` antes de bajar. Gang Beasts: `1,085,266,103` bytes en 32 s (~32 MB/s).

> No hace falta resolver el Turnstile a mano ni esperar la cuenta atrás: cuando la página ya muestra "Download Ready", el `href` está listo. El error clásico era dejar que el navegador guardara el archivo (queda en C: y con nombre UUID).

> **El token no sirve antes de "Download Ready".** Si haces `curl` (o incluso un `HEAD`) con el `download-file` recién minteado, recibes un HTML de **190.888 B** con "Ops matey no downloads here". Hay que navegar de verdad a `download_url`, esperar el texto "Download Ready" o `a.download-button`, y solo entonces leer el `href` y bajar. El mismo token funciona después. Haz una descarga a la vez; los tokens caducan en ~4 h.

### 3.1 Variantes de empaquetado

- **ZIP normal**: Pummel (1,6 GB), Paint (2,6 GB).
- **RAR**: Grocery Store Simulator. Magic `52 61 72 21` ("Rar!"), no `PK`. 7-Zip lo extrae igual; el reempaquetado posterior sí produce ZIP.
- **Zstandard**: algunas entradas de ZIP de AnkerGames; 7-Zip las maneja.
- **Unreal Engine** (Grocery): el `.exe` de la raíz (`Simulatorita.exe`) es el lanzador; el binario real es `<Juego>/<Juego>/Binaries/Win64/<Juego>-Win64-Shipping.exe`. Incluye ambos en `requiredFiles`.
- **Unity** (Pummel, Paint): `<Juego>.exe` + `UnityPlayer.dll` + `GameAssembly.dll` (Paint usa IL2CPP).

### 4. Inspeccionar y limpiar antes de hashear

El ZIP de AnkerGames puede usar **Zstandard** en algunas entradas: `System.IO.Compression` falla con "método de compresión no compatible". Usa 7-Zip (`C:\Program Files\7-Zip\7z.exe`) para extraer.

Comprueba el magic antes de elegir herramienta: `50 4B 03 04` = ZIP; `52 61 72 21` = RAR (Grocery Store Simulator). 7-Zip cubre ambos.

Extrae a `D:\CocoWork\<id>\source` y revisa:

- `OnlineFix.ini`: `RealAppId`, `hash0`, y una línea `1337=` del empaquetador. **Quita la línea `1337=`** y conserva `0`, `1` y el resto.
- `.url`, `Read Me.txt`, `Run Me!.bat`: material promocional, se excluyen.
- `Saves/`: el empaquetador rechaza cualquier ruta con un segmento `Saves` (datos persistentes). En Gang Beasts era `Gang Beasts/Saves/0/Input.txt` (mapeo de teclado por defecto): bórralo de la **copia temporal** `source` antes de empaquetar; el juego lo regenera. No toques partidas reales.
- El ejecutable real es `<Juego>/<Juego>.exe`; el `FileVersion` de un `.exe` Unity/Unreal no sirve como versión.

Prepara el INI sin BOM:

```powershell
$t=[IO.File]::ReadAllText($srcIni)
$t=[Text.RegularExpressions.Regex]::Replace($t,'(?m)^1337=.*\r?\n?','')
[IO.File]::WriteAllText($dstIni,$t,(New-Object Text.UTF8Encoding($false)))
```

### 5. Empaquetar (un ZIP o partes)

```powershell
$env:TEMP='D:\CocoWork\gang-beasts\temp'; $env:TMP=$env:TEMP
python -I launcher2/desktop/scripts/New-CocoMultipartArchives.py 'D:\CocoWork\gang-beasts\source' 'D:\CocoWork\gang-beasts\archives' `
  --prefix gang-beasts-1.28 `
  --base-url 'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/gang-beasts-1.28' `
  --override 'Gang Beasts/OnlineFix.ini=D:\CocoWork\gang-beasts\prepared\OnlineFix.ini' `
  --exclude 'AnkerGames - Free Pre-installed PC Games.url' `
  --exclude 'Read Me.txt' --exclude 'Run Me!.bat' `
  --compression deflate --level 1 --jobs 2
```

Gang Beasts: `1,077,893,081` bytes en 82,6 s (una parte). Si el juego supera 1,8 GB por archivo, añade `--split-large`.

`--split-large` parte un archivo individual (p. ej. `Simulatorita-Windows.ucas`, 6,18 GB) en `.part1..partN` y el instalador nativo lo reconstruye. Sin ese flag el empaquetador aborta con `ValueError: File exceeds part budget: <ruta>`. Verifica tras la instalación que el archivo reconstruido tiene el tamaño/SHA del inventario y que no quedan `.part*`.

### 6. Release, draft y catálogo

```powershell
gh release create <tag> -R Franco-Caballero/CocoMinecraftUpdater --prerelease --latest=false `
  --title '<Nombre> <version> - Coco 2' --notes '...' 'D:\CocoWork\<id>\archives\<parte>.zip'
# verificar Content-Length servido con curl -sIL

python -I launcher2/desktop/scripts/New-CocoMultipartCandidate.py --inventory 'D:\CocoWork\<id>\archives\inventory.json' `
  --id <id> --name '<Nombre>' --version <version> --executable '<Juego>/<Juego>.exe' `
  --description '<español>' --cover 'D:\CocoWork\<id>\cover.jpg' `
  --require '<Juego>/OnlineFix64.dll' --require '<Juego>/winmm.dll' --require '<Juego>/OnlineFix.ini' `
  --require '<Juego>/UnityPlayer.dll' --require '<Juego>/GameAssembly.dll' `
  --require '<Juego>/<Juego>_Data/Plugins/x86_64/steam_api64.dll'

& .\launcher2\desktop\scripts\Apply-CocoStandaloneDraft.ps1 -DraftId <id> -SourceZipDirectory 'D:\CocoWork\<id>\archives'
# revisar y aplicar con -Apply -ApproveReviewedLicenseRights -ExpectedCatalogSha256 <hash>
```

### 7. Online-Fix, medios y sync

- `online-fix.json`: añade `games.<id>` y `apps.<RealAppId>` con `realAppId`, `hash0` (el `0=` del INI) y `hash1337: ""`. **`hash1337: ""` no borra un 1337 existente**; el 1337 se elimina del INI en el paso 4. No agregues `hash1` al JSON: `game_prepare.rs::with_hashes` conserva la línea `1=` que ya trae el INI (Paint la necesita).
- Portada: cápsula oficial 616×353 (`.../store_item_assets/steam/apps/<appid>/capsule_616x353.jpg`) a `assets/experiences/<id>.jpg`.
- Preview: `game-hover-previews.json` con `url`, `steamAppId`, `trailerId`, `bytes`. Los juegos antiguos usan `https://cdn.akamai.steamstatic.com/steam/apps/<trailerId>/microtrailer.webm`.
- Capturas: `node scripts/sync-steam-screenshots.mjs` (12 por juego) y `node scripts/sync-catalog.mjs`.
- Edita los JSON **como texto**; `JSON.stringify` reordena `apps` y cambia todo el espaciado.

### 8. Instalación y primer arranque

```powershell
$sha='<sha-parte>'
New-Item -ItemType HardLink -Path "D:\CocoWork\<id>\cache\$sha.zip" -Target 'D:\CocoWork\<id>\archives\<parte>.zip'
$env:COCO2_HOST_SMOKE_ID='<id>'; $env:COCO2_HOST_SMOKE_TARGET='D:\CocoWork\<id>\install-test'; $env:COCO2_HOST_SMOKE_CACHE='D:\CocoWork\<id>\cache'
cargo test --lib host_package_install_smoke -- --ignored --nocapture

$env:COCO_PRIME_ROOT='D:\CocoWork\<id>\install-test'; $env:COCO_PRIME_EXE='<Juego>/<Juego>.exe'
cargo test --lib real_first_run -- --ignored --nocapture
```

Esperado: `conclusive true` y `credits box on screen afterwards: false`. `hashes changed: false` es lo normal cuando el `hash0` del INI ya es el de esta PC (Pummel, Grocery y Paint); `true` solo indica que el loader reescribió hashes. Cualquiera de los dos es aceptable si `conclusive` es `true`.

El dry-run del canal lista **todos** los juegos posteriores al último Setup, no solo el nuevo (el canal es un snapshot completo). Es esperado que vuelvan a aparecer Pummel/Grocery en la secuencia siguiente.

### 9. Publicar el canal

```powershell
cd launcher2\desktop
node scripts/Publish-Coco2Catalog.mjs --dry-run
node scripts/Publish-Coco2Catalog.mjs
```

No requiere Git limpio ni Setup. El juego aparece en los Coco abiertos en minutos. Si el dry-run dice que el juego "necesita un Setup", revisa argumentos de lanzamiento, `files` extra, versión no numérica, ZIP fuera del repo o hosting distinto de `p2p`.

## Datos por juego

| Juego | Ficha | downloadId | Steam | Versión | ZIP final | SHA-256 | Release | Estado |
|---|---|---|---|---|---|---|---|---|
| Buckshot Roulette | `/game/buckshot-roulette` | 775 | 2835570 | 2.2.0.6 | 1,006,059,895 B | `27a62a3677fd52651bc00992980f7125b5a457dcfc01aa1ff4a64760fb53738d` | `buckshot-roulette-2026` | En Setup 0.6.53 (baseline) |
| Gang Beasts | `/game/gang-beasts` | 198 | 285900 | 1.28 | 1,077,893,081 B | `50482c9ac3ebfc757c5f7bfc01fff1cc039e61a4a29a03d36629428ba6ac7b45` | `gang-beasts-1.28` | Canal firmado secuencia 2 |
| Pummel Party | `/game/pummel-party` | 166 | 880940 | 1.14.1 | 1,592,306,707 B (2 partes) | `e39ac7468651b013a6d8bf418d43b107b70f661f5c537897b3e9e8779adb533b` (part01) | `pummel-party-1.14.1` | Canal firmado secuencia 5 |
| Grocery Store Simulator | `/game/grocery-store-simulator` | 92 | 2961880 | 1.2.4 | 6,623,041,166 B (5 partes) | `b95f6408f0b250922e651fee518be82036ccef4ea02987c110abc93a9ac0aa51` (part01) | `grocery-store-simulator-1.2.4` | Canal firmado secuencia 5 |
| Paint the Town Red | `/game/paint-the-town-red` | 716 | 337320 | 1.3.4 | 2,527,207,121 B (2 partes) | `89522e27e85cc41d29757a587b29b97918ecacb67893679bcab5789d47f53be6` (part01) | `paint-the-town-red-1.3.4` | Canal firmado secuencia 5 |

Gang Beasts: ZIP original `1,085,266,103` B SHA-256 `da78bdf52537a921657cb47521cc531bc13f1563eb383f5d10adcd27b3b4d035`; INI preparado `e07c10f2d451a2da42b522c1ee9ed0d4c0c27f5366d61399d6e681e15ee4411c` (623 B); `hash0` `28e860b2...`; preview `257075225` (2,199,673 B); 12 capturas; excluidos `.url`, `Read Me.txt`, `Run Me!.bat`, `Saves/0/Input.txt`.

## Tiempos reales (host, 2026-11-12)

| Etapa | Tiempo |
|---|---|
| Descarga curl 1,0 GB | 32 s |
| Reempaquetado deflate nivel 1 | 82,6 s |
| Instalación nativa (smoke) | 31,3 s |
| Primer arranque invisible (prime) | 5,3 s |
| Total alta (sin contar espera de propagación) | ~25 min |

## Errores que costaron tiempo

- **Cloudflare** bloquea `curl` en `/generate-download-url/<id>`: usa el navegador para el POST y solo baja con `curl` el `download-file`.
- **ZIP con Zstandard**: .NET falla al extraer; usa 7-Zip.
- **`Saves/`**: el empaquetador lo rechaza aunque lo pongas en `--exclude`; bórralo de la copia temporal.
- **`hash1337: ""` no borra**: el INI debe salir sin `1337=` antes de hashear.
- **No guardes el ZIP con el navegador**: queda en C: con nombre UUID; usa `curl -o D:\...`.
- **`gh release upload archivo#label`** cambia la etiqueta, no el nombre del asset.
- **Reemplazar un asset** cambia los bytes/hash y rompe clientes con caché: sube versión de paquete nueva.
- **PowerShell 5.1** `Set-Content -Encoding UTF8` añade BOM; usa `UTF8Encoding($false)`.
- **`powershell -File script.ps1 -RequiredPaths a,b`** llega como un solo string; invoca con `&` y `@('a','b')`.

## Checklist rápido

- [ ] `git status --short` revisado; cambios ajenos intactos.
- [ ] `D:\CocoWork\<id>` y `TEMP`/`TMP` en D:.
- [ ] Enlace final obtenido y `Content-Length` verificado.
- [ ] `1337=` y `.url`/`Read Me`/`Run Me`/`Saves` fuera del paquete.
- [ ] ZIP final con SHA-256 y tamaño; release prerelease (nunca Latest).
- [ ] Draft aplicado; `online-fix.json`, portada, preview y capturas.
- [ ] `sync-steam-screenshots.mjs` y `sync-catalog.mjs`.
- [ ] Tests: catálogo, launch, Node, `tsc`, Rust Online-Fix.
- [ ] Instalación nativa + prime (`conclusive true`, `credits box false`).
- [ ] `Publish-Coco2Catalog.mjs --dry-run` y publicación; head/body/firma servidos.
- [ ] Limpieza de `D:\CocoWork\<id>` y descargas temporales.
