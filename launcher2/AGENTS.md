# AGENTS.md — Coco Launcher 2 (prioridad sobre el launcher original)

**Para agentes:** antes de agregar, actualizar o publicar un juego abre **[`docs/AGENT_ADD_GAME.md`](docs/AGENT_ADD_GAME.md)**. Es el procedimiento maestro con comandos, fuentes de verdad, rutas de verificación, fallos frecuentes y el recorrido desde el ZIP del host hasta el catálogo de los amigos. No recorras todo el repositorio antes de leerlo.

## Contrato innegociable

- **HOST-CURATED, AGENT-OPERATED.** Solo se muestran y se instalan juegos explícitamente aprobados por el host mediante el catálogo embebido o un canal remoto **Ed25519 verificado**. El agente realiza el alta; el usuario no necesita crear ZIP, JSON, comandos ni usar Host Studio a mano.
- El explorador, el selector, un `.coco2pack` y el consentimiento de un amigo **no autorizan alta de un juego nuevo**. SHA-256 asegura integridad de bytes, **NO demuestra que el host aprobó el contenido**. Los `.coco2pack` antiguos de Host Studio son paquetes **locales sin firma del host** y no son una fuente de catálogo autoritativa para clientes.
- El instalador solo puede trabajar con manifests de origen permitido, comprobando hashes, versión, ZIP/rutas seguras, rollback, journal, saves y procesos activos. No se instala ni ejecuta nada con el mero clic en una tarjeta o fichero.
- **Defender (autorizado por el anfitrión):** Coco 2 agrega exclusiones solo para carpetas de juegos, sus carpetas de trabajo y su caché, con UAC, nunca una unidad o carpeta personal completa, y jamás desactiva la protección (`services/defender.rs`).

- Trabajo compartido y Git sucio: **prohibido** `git reset`, `git clean`, reemplazar cambios de terceros, borrar caches Rust o reutilizar SemVer/bytes firmados; comprobar `git status --short` y OWN antes de modificar.
- Juegos nuevos: `%APPDATA%\CocoLauncher2\games\<instanceId>`. Los ya instalados en `%APPDATA%\CocoMinecraft\experiences` siguen ahí hasta que el jugador los mueva; los packs Minecraft no cambian de carpeta.
- Minecraft pospuesto; no convertir las instrucciones heredadas de `../AGENTS.md` en cambios automáticos de Minecraft o de Coco 1.

## Enlaces inmediatos por tarea

| Tarea | Abrir solo esto primero |
|---|---|
| **Agregar o actualizar juego autorizado por host** | [`docs/AGENT_ADD_GAME.md`](docs/AGENT_ADD_GAME.md) |
| Agregar películas/series, reseñas o investigar reproducción | [`docs/AGENT_ADD_GAME.md`](docs/AGENT_ADD_GAME.md), sección «Agregar películas y series»; `services/{media.rs,native_player.rs}`, `src/{MediaPlayer.tsx,native-playback.ts}` |
| Código del launcher, catálogo firmado e instalación | `desktop/src-tauri/src/services/{catalog.rs,catalog_channel.rs,install.rs}` |
| Preparar borrador sin modificar catálogo | `desktop/scripts/New-CocoStandaloneCandidate.ps1` |
| Inspeccionar ZIP, proponer ejecutable/cover en una llamada | `desktop/scripts/Inspect-Coco2AgentGame.ps1` |
| Un solo comando para inspección, borrador, portada neutral y dry-run | `desktop/scripts/QuickAdd-Coco2Agent.mjs` |
| Validar y promocionar al catálogo fuente (solo con derechos verificados) | `desktop/scripts/Apply-CocoStandaloneDraft.ps1` |
| Regenerar archivos compilables del catálogo fuente | `desktop/scripts/sync-catalog.mjs` |
| Host Studio para borradores/exportación | `desktop/src-tauri/src/services/{import.rs,host_publish.rs}`, `desktop/src/HostStudio.tsx` |
| Recepción y confianza en el cliente | `desktop/src-tauri/src/services/catalog_channel.rs`, `desktop/src/CatalogHub.tsx` |
| Biblioteca, panel de estado y previews | `desktop/src/{main.tsx,coco-ui.css,library-view.ts,launcher-status.ts,flip-grid.ts,stage-motion.ts,hover-video-pool.ts}`, `desktop/src-tauri/src/services/preview_cache.rs` |
| Perfil, carpeta del juego y desinstalación | `desktop/src-tauri/src/services/{identity.rs,location.rs,uninstall.rs}` |
| Preparación al abrir un juego (Online-Fix, Steam, popups) y Defender | `desktop/src-tauri/src/services/{game_prepare.rs,defender.rs}`, `desktop/src-tauri/resources/online-fix.json` |
| Partidas LAN, prioridad del adaptador Coco y migración de red desde Coco 1 | [`docs/LAN.md`](docs/LAN.md) |
| Última versión distribuible y QA | `README.md` y `desktop/scripts/{Build-CocoLauncher2.ps1,Verify-Coco2SignedSetup.mjs}` |
| **Hacer aparecer un juego nuevo a los amigos** (sin Setup ni reinicio) | `desktop/scripts/Publish-Coco2Catalog.mjs` y la sección «Publicar el catálogo» de `docs/AGENT_ADD_GAME.md` |
| Publicar una versión (solo con autorización del host) | `desktop/scripts/Publish-Coco2Release.ps1` y la sección «Publicar una versión nueva» de `docs/AGENT_ADD_GAME.md` |
| Traspaso de amigos desde Coco 1 | `../engine/CocoUpdater.ps1` (`Invoke-CocoLauncher2Handoff`) y `../tests/Test-CocoLauncher2Handoff.ps1` |

Mantén este archivo corto: decisiones y recetas detalladas viven **solo** en el documento maestro. Las versiones, hashes y métricas de Release se registran en `README.md`, nunca se copian aquí.
