# Golf It! 1.0.1.1953 — auditoría

Preparado el 2026-11-09 para Coco 2 0.6.47, ID `golf-it`. El original en Descargas y `D:\golfit.rar` se conservaron. Todo paquete, herramienta portátil, temporal, caché de prueba e instalación del juego se preparó en D:.

## Contenido y compresión

La carpeta y el RAR contienen las mismas 300 rutas y tamaños; no se afirmó comparación byte a byte del RAR. RAR: 6.243.878.270 bytes. Fuente: 16.495.402.835 bytes. Se excluyeron únicamente `Saved.lnk` y el acceso promocional `Engine/Binaries/ThirdParty/Steamworks/Steamv153/Win64/OnlineFix.url`. Instalación resultante: 16.495.400.506 bytes.

Diez ZIP independientes con Zstandard (método 93), generados por Python oficial portátil 3.14.0 (Authenticode Valid, Python Software Foundation), suman **5.962.596.882 bytes**, menos que el RAR original. Empaquetado: 205,01 s. El UCAS de 15.271.707.088 bytes se divide por streaming, sin copias temporales de piezas al comprimir, y el instalador lo reconstruye. SHA-256 fuente y reconstruido: `76cde6ef22f782cc46ab75c36d88977a546a13538e173b50c7774b4d45c16e36`.

El instalador nativo real instaló en `D:\CocoGames\golf-it` en 725,87 s; la reconstrucción añade una copia de las piezas al archivo final y es un coste de E/S considerable. Reservar descarga + staging descomprimido + mayor archivo reconstruido temporal. Verificación final del UCAS: 21,66 s. Caché de prueba en D: mediante hardlinks a los ZIP, sin duplicar físicamente sus bytes.

## Arranque y avisos

Ejecutable directo: `GolfIt/Binaries/Win64/GolfIt-Win64-Shipping.exe`; el pequeño `GolfIt.exe` raíz crea otro proceso y no se seleccionó. Fix separado en `Engine/Binaries/ThirdParty/Steamworks/Steamv153/Win64`, AppId 571740. OnlineFix64.dll SHA-256 `e9ff07d45aadfb25dc2a19514c4930b7d506a9de683be4febcba577b1b242dba`, x64 con secciones protegidas `.of0/.of1`; no se parchearon imports por tanteo.

El paquete conserva el INI original sin aceptación `1337` del anfitrión. La preparación por PC usa escritorio oculto y Job Object de un solo proceso. Prueba real: resultado concluyente en 4,014 s, hash local escrito, ningún Credits encontrado después. Confianza del equipo registrada por la función de producción. Se amplió la selección genérica del ejecutable para fix separado y Shipping declarado en catálogo.

El arranque visible pasó con guard de producción durante 75 s (proceso vivo al finalizar, escaneo de Credits negativo), ventana 1280×720 y registro externo en D:. Unreal registró `MainMenu_C`, `WB_Main` y foco `Button_Play`. No hay captura de escritorio: la herramienta devolvió `DESKTOP_IDENTITY_REQUIRED`; no se confunde el registro con observación visual del anfitrión. Multijugador y primer arranque en otro PC pendientes. No se promete ausencia de cualquier ventana de Windows/Steam/error.

## Validación

- Empaquetador Python: 7 pruebas aprobadas, incluido Zstandard, split, resume y colisiones.
- Rust global: 300 aprobadas, 0 fallos, 7 opt-in ignoradas; además instalación nativa y preparación real aprobadas.
- Fixture ZIP Zstandard/ZIP64 de Python 3.14 extraído por instalador nativo real.
- Pruebas PowerShell de catálogo, lanzamiento, instancia e integración aprobadas.
- Portada oficial 616×353, preview oficial y 12 capturas; descripción española revisada.
- No se añadió el UCAS a requiredFiles: se verifica por ZIP completo al instalar y una vez reconstruido; los ocho componentes de arranque esenciales sí se fijan.

## Assets

Release propio `golf-it-1.0.1.1953` (prerelease, nunca Latest). Diez tamaños/digests cotejados con GitHub tras subir.

| Archivo | Bytes | SHA-256 |
|---|---:|---|
| golf-it-1.0.1.1953-part01.zip | 304753084 | `d84deb775bcd86da4ec7d40372f1eccb89246f098dcb145b6f910aea15604723` |
| golf-it-1.0.1.1953-part02.zip | 532986181 | `fb33835d317c4efdc2ed886a4b220a0930083fba4f4c9f99554d1bf2a3c0d61f` |
| golf-it-1.0.1.1953-part03.zip | 497004622 | `4f261b6d3c850e320a719fa1c8dcf837a82b08b0023e3d5fca7d2aad337851b6` |
| golf-it-1.0.1.1953-part04.zip | 634147499 | `65627d5faee7059175e4323aae62dce5887d9795da97219bc1f0bb32d1af9dfc` |
| golf-it-1.0.1.1953-part05.zip | 681079718 | `df96380e60ca7aa61c58bb193975e2aff6a06fc2367404f2fc0dfddf60c0f770` |
| golf-it-1.0.1.1953-part06.zip | 293252710 | `426853ceabe277b3d144f9a102756cc11ab4a5c970deb33200e32bc619e5818b` |
| golf-it-1.0.1.1953-part07.zip | 589681382 | `23b9cd54e8d611493a30be5ca60fad7d4e9e3d1f9e038620dabd1956fbc6da56` |
| golf-it-1.0.1.1953-part08.zip | 781701163 | `d9b005cdf9668d115d8bf6c6ff62b3d5a67cc8ffbc43d7fffb673856be92f887` |
| golf-it-1.0.1.1953-part09.zip | 779722564 | `ea653dc1ded7d79dae91ab782077a67835e3a228cb04456b4e5cedcbb2b605e1` |
| golf-it-1.0.1.1953-part10.zip | 868267959 | `cfc4fe8a851281d66a2e12ac739d1262b55445e55fd541f8e1c75f4cbfad7c13` |

Verificación pública: 10/10 URLs devolvieron HTTP 206, Content-Range del tamaño exacto y firma ZIP PK0304; digests SHA-256 de GitHub coinciden con el inventario local.

Preflight del builder 0.6.47: Node 532 PASS, 0 FAIL, 31 opt-in SKIP (563 casos); TypeScript sin errores y Vite 3,54 s. Logs e inventario completos conservados en `D:\CocoWork\GolfIt-1.0.1.1953`.

## Setup 0.6.47

Candidato firmado `0.6.47-24452AD5EEDB`, 20.682.772 bytes, SHA-256 `24452ad5eedb78880a989b0ec513bc843ecaeb9a48c4539cddbab453a21f8731`. Firma Ed25519/Minisign y feed verificados; no equivale a Authenticode Windows. Extracción NSIS y pruebas de integridad del candidato aprobadas; comparación del PE permite exclusivamente el marcador Tauri de tres bytes.

Publicado en `coco2-channel`: feed 0.6.47, Setup versionado y enlace estable descargados y cotejados por SHA-256; Latest de Coco 1 conservado en `v0.5.186`. Instalación silenciosa del candidato exacto en el anfitrión terminó con exit 0 y registro de Windows 0.6.47. Ubicación del juego registrada en D:, sin reinstalar ni duplicar el juego.
