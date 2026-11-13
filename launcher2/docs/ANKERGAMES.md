# AnkerGames → Coco 2: receta rápida

Receta para «agrega este juego: `https://ankergames.net/game/<slug>`». Sigue los pasos en orden sin investigar de nuevo lo que ya está resuelto aquí. Lo general (canal, Setup, Online-Fix, medios de Steam) está en [`AGENT_ADD_GAME.md`](AGENT_ADD_GAME.md); este documento solo cubre lo propio de AnkerGames y los atajos probados con 7 juegos.

Tiempo real esperado: 15–25 min para 1–3 GB; la mayor parte es descarga, reempaquetado y subida.

## Reglas que ahorran más tiempo

- **Nunca publiques un juego que no viste en su menú** (paso 7b). Revisa antes «Juegos que hay que evitar».
- **Mira en «Game Features & Info» si el Online-Fix viene dentro o aparte** (paso 1b) antes de pedir enlaces: si viene aparte hay dos descargas, y cada enlace es de un solo uso.
- **Todo lo pesado en `D:\CocoWork\<id>`**, con `TEMP`/`TMP` del proceso allí. Nunca dejes que el navegador guarde el ZIP (queda en C: con nombre UUID).
- **El navegador solo sirve para obtener el enlace**; el archivo se baja con `curl` directo a D:.
- **El enlace `download-file` es de un solo uso.** Ni `HEAD`, ni `curl -I`, ni una prueba previa: el primer acceso lo gasta y el siguiente devuelve la página «Ops matey no downloads here» (HTML de ~190 KB). Compruébalo **después** de bajar (tamaño y magic). Si lo gastaste, vuelve a pedir uno (paso 2).
- Las herramientas del navegador de T3 (`preview_open`, `preview_evaluate`, `preview_navigate`, `preview_wait_for`, `t3_preview_close`) son **herramientas**, no comandos de la terminal.
- En PowerShell `"\n"` es una barra y una n, no un salto de línea (usa `` `n ``), y no existen los heredoc `<<'EOF'`: para editar JSON escribe un `.py` en `D:\CocoWork\<id>\temp` y ejecútalo con `python -I`.
- `Publish-Coco2Catalog.mjs` tarda **2–3 minutos** (espera a que GitHub sirva el catálogo nuevo). Dale un timeout de 10 min o ejecútalo en segundo plano. Si se cortó, mira la secuencia en `coco2-catalog-head.json` antes de repetir; repetirlo es seguro (`unchanged`).
- Si tocas código Rust/TS para que un juego funcione, eso **no** viaja por el canal: hace falta un Setup nuevo (sección «Publicar una versión nueva» de la guía maestra). Nunca lo dejes sin commit.

## 1. Datos de la ficha (sin navegador)

```powershell
$d='D:\CocoWork\<id>'; New-Item -ItemType Directory -Force "$d\temp","$d\prepared","$d\assets" | Out-Null
curl.exe -sL -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "https://ankergames.net/game/<slug>" -o "$d\temp\page.html"
Select-String -Path "$d\temp\page.html" -Pattern 'generateDownloadUrl\((\d+)\)','softwareVersion[^,]*','steam/apps/(\d+)','Build \d+','(Goldberg|RUNE|OFME)[^.<]*','Online.?Fix[^.<]*separately[^.<]*' -AllMatches |
  ForEach-Object { $_.Matches.Value } | Select-Object -Unique
```

- `generateDownloadUrl(<n>)` → **downloadId** (no es el id de la ficha).
- `steam/apps/<n>` → **Steam AppId** (confírmalo con el `RealAppId` del `OnlineFix.ini`).
- **Versión** (debe ser numérica con puntos, el canal no acepta letras): `V 1.14.1k` → `1.14.1`; `Build 3911030` → `3911030`; sin versión → fecha del paquete `AAAA.MM.DD`. El `FileVersion` del `.exe` Unity/Unreal es el del motor: no sirve.

Mientras tanto, pide portada, clip y capturas de Steam (guía maestra, «Tarjeta completa»).

### 1b. ¿El Online-Fix viene dentro o aparte?

La sección **«Game Features & Info»** de la ficha lo dice (el `Select-String` de arriba ya la extrae):

| El texto dice | Qué trae el ZIP del juego | Qué hacer |
|---|---|---|
| «The **OFME** patch has been used» | El juego **con Online-Fix integrado** (Pummel Party, por ejemplo) | Solo el botón **Direct**. Sigue normal |
| «The **Goldberg** / **RUNE** emulator has been used» + «**Online Fix** (patch) has been added **separately**» | El juego con un emulador de Steam, **sin** Online-Fix | Baja **también** el fix (botón **Online Fix** del mismo diálogo) y aplícalo (paso 3b) |
| Emulador sin mención de Online Fix | Solo un emulador: no hay multijugador por internet | **Descártalo**: Coco necesita Online-Fix para jugar con amigos |

El diálogo de descarga lo confirma: con fix aparte muestra dos botones, **Direct** y **Online Fix**, y además un bloque **FILE INTEGRITY** con MD5 y SHA-256 del juego. Sin fix aparte solo hay **Direct**.

«Launch the game from Run Me!.bat» no se copia: Coco abre el `.exe` directamente. Lee el `.bat` (es texto) para saber **qué** `.exe` arranca y con qué argumentos, y no lo empaquetes.

## 2. Enlace de descarga (navegador, ~15 s)

El POST pasa por Cloudflare y **falla con `curl`**; hazlo dentro de la página. Abre `https://ankergames.net/game/<slug>` con `preview_open` y ejecuta con `preview_evaluate`:

```js
(async () => {
  const csrf = document.querySelector('meta[name="csrf-token"]').content;
  const r = await fetch('/generate-download-url/<downloadId>', {method: 'POST',
    headers: {'Content-Type': 'application/json', 'X-CSRF-TOKEN': csrf}, body: '{}'});
  return (await r.json()).download_url;   // https://ankergames.net/download/<payload>/<firma>
})()
```

Luego `preview_navigate` a ese `download_url`, `preview_wait_for` con el texto `Download Ready` (5–10 s, no hace falta Turnstile ni cuenta atrás), y lee el enlace final:

```js
[...document.querySelectorAll('a[href*="/download-file/"]')].map(a => a.href)[0]
```

(No uses `a.download-button` como selector: hay varios y el primero no siempre es el enlace.)

Si el juego trae fix aparte (1b), la página tiene **dos** enlaces `download-file`, y cada uno es de un solo uso. Lístalos con su texto y apunta los dos antes de bajar ninguno:

```js
[...document.querySelectorAll('a[href*="/download-file/"]')].map(a => [a.closest('div')?.innerText.trim().slice(0,40), a.href])
```

Si solo ves uno, haz clic en **Online Fix** con `preview_act` y lee el enlace nuevo (un clic en **Direct** gasta el del juego). Copia también el **SHA-256** de «FILE INTEGRITY» (`document.body.innerText.match(/[0-9a-f]{64}/)`) para comprobar la descarga. Cierra la pestaña con `t3_preview_close`.

## 3. Descargar e inspeccionar

```powershell
curl.exe -L --fail --retry 3 --retry-delay 5 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o "$d\game.zip" "<download-file>"
$b=[IO.File]::ReadAllBytes("$d\game.zip")[0..3]; '{0:X2} {1:X2} {2:X2} {3:X2}' -f $b[0],$b[1],$b[2],$b[3]   # 50 4B = ZIP, 52 61 = RAR
& 'C:\Program Files\7-Zip\7z.exe' x -y -o"$d\source" "$d\game.zip" | Out-Null
```

- Usa siempre 7-Zip: hay ZIP con entradas Zstandard (.NET falla) y RAR disfrazados (Grocery Store Simulator).
- Un HTML pequeño en vez del ZIP = enlace gastado: vuelve al paso 2.
- ~32 MB/s: 1 GB en 30–40 s.
- Si la página daba SHA-256: `(Get-FileHash "$d\game.zip").Hash` debe coincidir. Si no coincide, la descarga está corrupta: pide otro enlace.

### 3b. Aplicar un Online-Fix que viene aparte

```powershell
curl.exe -L --fail -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -o "$d\fix.zip" "<download-file del Online Fix>"
& 'C:\Program Files\7-Zip\7z.exe' l "$d\fix.zip"                  # mira la estructura ANTES de extraer
& 'C:\Program Files\7-Zip\7z.exe' x -y -o"$d\fix" "$d\fix.zip"    # si pide clave, prueba online-fix.me
```

- Copia el contenido del fix **sobre la carpeta del juego, reemplazando** (lo mismo que «replace when asked»). Si el fix trae una carpeta raíz propia (`Fix Repair`, el nombre del juego…), copia lo de **dentro**, de modo que `OnlineFix64.dll`/`OnlineFix.dll` y `OnlineFix.ini` queden junto al `.exe` que los carga. Se hace sobre la copia `source`, nunca sobre la descarga.
- El fix sustituye el `steam_api*.dll` del emulador (Goldberg/RUNE). Cuando termines, no deben quedar archivos del emulador sueltos: `steam_settings/`, `steam_emu.ini`, `ColdClientLoader.ini`, `rune.ini` o similares. Bórralos de la copia, o el emulador podría seguir activo en lugar del fix.
- Clasifica después con la tabla de abajo y sigue igual que con un fix integrado. En el paso 7b comprueba sobre todo que el juego llega al menú **con el fix**: una mezcla de emulador y fix es la causa más probable de un juego que no abre.

Busca en `source` (sin ejecutar nada): el `.exe` del juego, cada `OnlineFix.ini`, `OnlineFix64.dll`/`OnlineFix.dll`, y la basura del empaquetador. Clasifica el juego con esta tabla:

| Dónde está Online-Fix | Ejemplo | `--executable` | `--require` | Primer arranque invisible |
|---|---|---|---|---|
| `OnlineFix64.dll` junto al `.exe` (Unity 64 bits) | Pummel, Paint, Gang Beasts | `<Juego>/<Juego>.exe` | exe, `OnlineFix64.dll`, `winmm.dll`, `OnlineFix.ini`, `UnityPlayer.dll`, `steam_api64.dll` (+ `GameAssembly.dll` si es IL2CPP) | Sí |
| Unreal: `Binaries/Win64` junto a `-Shipping.exe` | Grocery Store Simulator | el `.exe` de la raíz | ese exe, el `-Shipping.exe` y los del fix | Sí (Coco arranca el `-Shipping.exe`) |
| Dentro de `steam_api.dll` en `<Juego>_Data/Plugins` (Unity 32 bits, sin `OnlineFix*.dll`) | Stick Fight (retirado) | — | — | **No soportado: descártalo** (ver «Juegos que hay que evitar») |
| Otro | — | — | — | Compruébalo en el paso 7 antes de publicar |

## 4. Limpiar la copia y empaquetar

En la **copia** `source` (nunca en la fuente del anfitrión):

- **Borra carpetas enteras** que no son el juego: `Fix Repair` (un fix de repuesto: Coco lo trataría como segunda carpeta del fix) y cualquier `Saves`/`saves` (el empaquetador rechaza rutas con `Saves` aunque las excluyas). `--exclude` solo acepta **archivos** exactos, no carpetas.
- INI sin el `1337` del empaquetador, sin BOM:

  ```powershell
  $ini="$d\source\<ruta>\OnlineFix.ini"; $t=[IO.File]::ReadAllText($ini)
  $t=[Text.RegularExpressions.Regex]::Replace($t,'(?m)^1337=.*\r?\n?','')
  [IO.File]::WriteAllText("$d\prepared\OnlineFix.ini",$t,(New-Object Text.UTF8Encoding($false)))
  [regex]::Match($t,'(?m)^0=([0-9a-f]{128})').Groups[1].Value   # hash0 para online-fix.json
  ```

- Excluye **cada** archivo promocional, también los de subcarpetas (en Grocery se coló un `Read Me.txt` dentro de la carpeta del juego). Lista rápida: `Get-ChildItem $d\source -Recurse -File -Include *.url,*.bat,'Read Me.txt',dlllist.txt,Log.txt,output_log.txt`.

```powershell
$env:TEMP="$d\temp"; $env:TMP=$env:TEMP
python -I launcher2/desktop/scripts/New-CocoMultipartArchives.py "$d\source" "$d\archives" `
  --prefix <id>-<version> --base-url 'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/<id>-<version>' `
  --override "<ruta del ini>=$d\prepared\OnlineFix.ini" `
  --exclude 'AnkerGames - Free Pre-installed PC Games.url' --exclude 'Read Me.txt' --exclude 'Run Me!.bat' `
  --compression deflate --level 1 --jobs 2      # + --split-large si un archivo pasa de 1,8 GB
python -I launcher2/desktop/scripts/Check-CocoGamePackage.py "$d\archives"   # debe terminar sin PROBLEM
```

`Check-CocoGamePackage.py` lee los ZIP finales e informa de `1337`, `.url`/`.bat`/`Read Me`/logs, `Saves`, `Fix Repair` y cuántas carpetas del fix verá Coco. No subas nada hasta que pase.

## 5. Release, borrador y catálogo

```powershell
$files=@(Get-ChildItem "$d\archives" -Filter *.zip | Sort-Object Name | ForEach-Object FullName)   # @() o gh recibe una letra
gh release create <id>-<version> -R Franco-Caballero/CocoMinecraftUpdater --prerelease --latest=false `
  --title '<Nombre> <version> - Coco 2' --notes '<Nombre> <version> para Coco Launcher 2.' @files
gh release view <id>-<version> -R Franco-Caballero/CocoMinecraftUpdater --json assets | ConvertFrom-Json | ForEach-Object assets | Select-Object name,size,state

python -I launcher2/desktop/scripts/New-CocoMultipartCandidate.py --inventory "$d\archives\inventory.json" `
  --id <id> --name '<Nombre>' --version <version> --executable '<exe>' --cover "$d\assets\cover.jpg" `
  --description '<resumen en español, con tildes>' --require '<cada archivo de la tabla del paso 3>'
& .\launcher2\desktop\scripts\Apply-CocoStandaloneDraft.ps1 -DraftId <id> -SourceZipDirectory "$d\archives"
# y con el SHA que imprime:  ... -Apply -ApproveReviewedLicenseRights -ExpectedCatalogSha256 <sha>
```

- `curl -sIL` a un asset de release da `Content-Length: 0` (redirige); la lista de `gh release view` ya muestra tamaño y `uploaded`.
- Descripción: español natural **con tildes** (el script escribe los escapes `\u00e1`), género, objetivo y jugadores; mira las de juegos vecinos en `launcher/catalog.template.json`. Ese archivo es CRLF: si lo editas a mano, consérvalo.

## 6. Online-Fix, clip, capturas y sync

- `launcher2/desktop/src-tauri/resources/online-fix.json`: añade `games.<id>` y `apps.<RealAppId>` con `realAppId`, `hash0` y `hash1337: ""`, **como texto** (copia el bloque del último juego y pégalo antes del cierre de cada objeto); `JSON.stringify` reordena `apps`.
- `launcher2/desktop/src/game-hover-previews.json`: igual, como texto (`url`, `steamAppId`, `trailerId`, `bytes`).
- Desde `launcher2/desktop`: `node scripts/sync-steam-screenshots.mjs; node scripts/sync-catalog.mjs`.

## 7. Instalar y primer arranque (obligatorio antes de publicar)

Este paso tiene dos partes y **las dos son obligatorias**: el primer arranque invisible (abajo) y **abrir el juego de verdad hasta su menú** (7b). Las verificaciones de ZIP, hashes, tamaños y el primer arranque invisible **no prueban que el juego funcione**. Stick Fight las pasó todas, se publicó sin que nadie lo abriera y no arrancaba.

```powershell
New-Item -ItemType Directory -Force "$d\cache" | Out-Null
(Get-Content "$d\archives\inventory.json" -Raw | ConvertFrom-Json).archives | ForEach-Object {
  New-Item -ItemType HardLink -Path "$d\cache\$($_.sha256).zip" -Target "$d\archives\$(Split-Path $_.archiveUrl -Leaf)" -Force | Out-Null }
cd launcher2\desktop\src-tauri
$env:COCO2_HOST_SMOKE_ID='<id>'; $env:COCO2_HOST_SMOKE_TARGET="$d\install-test"; $env:COCO2_HOST_SMOKE_CACHE="$d\cache"
cargo test --lib host_package_install_smoke -- --ignored --nocapture
$env:COCO_PRIME_ROOT="$d\install-test"; $env:COCO_PRIME_EXE='<exe relativo>'
cargo test --lib real_first_run -- --ignored --nocapture
```

Lee la primera línea: `fix folder <carpeta> -> Some(<exe>)`. Esperado al final: `conclusive true` y `credits box on screen afterwards: false` (`hashes changed: false` es normal cuando el `0=` del INI ya vale en este PC).

Si sale `-> None` («sin ejecutable junto al fix»), Coco no sabe qué programa carga el fix en esa distribución. Entonces:

- El juego **igual se abre**: el detector de avisos y el bloqueo de navegadores siguen activos. Pero cada partida intentará de nuevo el primer arranque.
- La solución es una regla nueva en `game_prepare.rs::first_run_exe`, con su prueba en `a_first_run_starts_the_program_that_loads_the_fix_in_every_layout`.
  - Hazla **específica** a la distribución. Nunca devuelvas «el exe del juego» en general: un lanzador que abre otro proceso fallaría dentro del arranque que solo admite uno.
  - Después: Rust en verde, prueba real con `-> Some(...)`, y un Setup nuevo.

### 7b. Abrir el juego de verdad (obligatorio)

Sobre `$d\install-test`, fuera de Coco, para separar un paquete roto de un fallo del launcher:

```powershell
$exe="$d\install-test\<exe relativo>"; $p=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
$t0=Get-Date; while(((Get-Date)-$t0).TotalSeconds -lt 90 -and !$p.HasExited){ Start-Sleep 5; $p.Refresh()
  "{0,3}s  ws={1} MB  ventana='{2}'" -f [int]((Get-Date)-$t0).TotalSeconds,[int]($p.WorkingSet64/1MB),$p.MainWindowTitle }
Get-ChildItem "$env:USERPROFILE\AppData\LocalLow" -Recurse -Filter Player.log -EA 0 | ? LastWriteTime -gt $t0 | % FullName
```

Aprobado solo si: aparece una **ventana con título**, la memoria sube a cientos de MB, en Unity se escribe un `Player.log` nuevo y **ves el menú principal** (pide al anfitrión que lo mire o haz una captura). Cierra el juego y repite una vez desde Coco (`npm run tauri dev` o el Coco instalado) para confirmar que Coco lo abre igual. Si el juego no llega al menú en 90 s, **no se publica**: mata el proceso (`Stop-Process -Id $p.Id -Force`) y descarta el juego o busca otra distribución. Un juego colgado bloquea además abrir cualquier otro juego en Coco.

## Juegos que hay que evitar

Descarta el paquete (no lo publiques ni lo «arregles» en Coco) si ves cualquiera de estas señales. Todas aparecieron en Stick Fight: The Game (AnkerGames, build 3911030), retirado en Coco 0.6.56:

- **Sin `OnlineFix64.dll`/`OnlineFix.dll`**, con el fix metido dentro de `steam_api.dll` en `<Juego>_Data/Plugins` (Unity antiguo de 32 bits). Ningún juego que funciona en Coco usa esa forma.
- **Ningún `UnityPlayer.dll`** junto a un juego Unity: el `.exe` de 18 MB lleva el motor dentro (Unity 5 o anterior). En ese caso, mira el `.exe` con más cuidado.
- **Secciones raras en el `.exe`** (`.trace`, `.data1`, `.rodata` en un juego de Windows): señal de un ejecutable modificado o empaquetado. Compruébalo con `[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe),0,1024)` y busca los nombres que empiezan por punto.
- Primer arranque invisible con **`hash_written: false, survived: true`**: el proceso no murió, pero el fix nunca escribió su hash. Eso **no** es un éxito; casi siempre significa que el juego no llegó a cargar nada.
- En 7b: proceso vivo con **menos de ~50 MB, sin ventana, sin `Player.log`** y gastando un núcleo entero. En Stick Fight solo tenía cargados `ntdll` y `wow64`: se colgaba antes de cargar ninguna DLL, también fuera de Coco y con Steam abierto. No se averiguó la causa exacta, y no vale la pena: busca otro juego.

## 8. Publicar, guardar y limpiar

```powershell
cd launcher2\desktop
node scripts/Publish-Coco2Catalog.mjs --dry-run      # lista TODOS los juegos posteriores al último Setup: es normal
node scripts/Publish-Coco2Catalog.mjs                # 2–3 min; timeout ≥ 10 min
```

Después:

- **Comprobar la publicación:** `coco2-catalog-head.json` sube de secuencia.
- **Guardar en git:** commit en `main` de tu alta y nada más. Los archivos van con `git add` explícito: catálogo, lock, portada, recursos, previews, capturas y docs.
- **Limpiar:** `Remove-Item -Recurse -Force D:\CocoWork\<id>`. Mata antes cualquier `UnityCrashHandler`/juego que siga abierto.

## Datos por juego

| Juego | Ficha | downloadId | Steam | Versión | Paquete | Release | Distribución del fix | Estado |
|---|---|---|---|---|---|---|---|---|
| Buckshot Roulette | `/game/buckshot-roulette` | 775 | 2835570 | 2.2.0.6 | 1.006.059.895 B | `buckshot-roulette-2026` | Godot, `OnlineFix64.dll` junto al exe | Setup 0.6.53 |
| Gang Beasts | `/game/gang-beasts` | 198 | 285900 | 1.28 | 1.077.893.081 B | `gang-beasts-1.28` | Unity 64 | Setup 0.6.54 |
| Pummel Party | `/game/pummel-party` | 166 | 880940 | 1.14.1 | 1.592.306.707 B (2 partes) | `pummel-party-1.14.1` | Unity 64 | Setup 0.6.55 |
| Grocery Store Simulator | `/game/grocery-store-simulator` | 92 | 2961880 | 1.2.4 | 6.623.041.166 B (5 partes, RAR de origen, `--split-large`) | `grocery-store-simulator-1.2.4` | Unreal, `Binaries/Win64` | Setup 0.6.55 (lleva un `Read Me.txt` inofensivo) |
| Paint the Town Red | `/game/paint-the-town-red` | 716 | 337320 | 1.3.4 | 2.527.207.121 B (2 partes) | `paint-the-town-red-1.3.4` | Unity 64 IL2CPP (conserva `1=`) | Setup 0.6.55 |

Gamble With Your Friends no vino de AnkerGames por enlace: era una carpeta ya descargada (receta de la guía maestra).

## Tiempos reales (anfitrión)

| Etapa | Tiempo |
|---|---|
| Datos de la ficha + enlace | ~1 min |
| Descarga | ~32 MB/s (1 GB ≈ 35 s) |
| Reempaquetado deflate nivel 1 | 1 GB ≈ 80 s; 6,6 GB ≈ 8 min |
| Subida a GitHub | similar a la descarga |
| Instalación nativa de prueba | 30–70 s |
| Primer arranque invisible | 5–20 s |
| Publicar el canal | 2–3 min |

## Errores que ya costaron tiempo

- `curl -sIL` al `download-file` antes de bajar: gasta el enlace.
- **Publicar sin ver el juego abierto.** Stick Fight pasó todas las verificaciones y se publicó, pero `StickFight.exe` quedaba colgado al 100 % de un núcleo, con 9 MB y sin ventana, también abierto a mano fuera de Coco; además bloqueaba abrir cualquier otro juego. `PrimeOutcome { hash_written: false, survived: true }` **no** es un éxito: solo dice que el proceso no murió. Antes de publicar, abre el `.exe` instalado a mano y espera a ver el menú (y en Unity, que aparezca `Player.log`). Si no llega al menú, descarta el juego.
- Publicación «cortada» a los 2 min por el timeout del agente cuando GitHub ya la tenía: revisa el head antes de repetir.
- Cambio de Rust sin Setup ni commit: los amigos no lo reciben.
- Una regla de primer arranque demasiado general: habría hecho fallar los juegos Unreal con lanzador.
- `Read Me.txt` en una subcarpeta (Grocery): usa `Check-CocoGamePackage.py`.
- `"\n"` en PowerShell insertó `\n` literales en `game-hover-previews.json`.
- `$files` sin `@()` hizo que `gh release create` recibiera `D`.
- Descripciones sin tildes («fisica», «creacion»): escríbelas bien desde el principio.
- `hash1337: ""` en `online-fix.json` no borra un `1337` que traiga el INI.
- `gh release upload archivo#label` cambia la etiqueta, no el nombre; un asset publicado no se reemplaza (los clientes con caché fallarían el hash): versión de paquete nueva.
