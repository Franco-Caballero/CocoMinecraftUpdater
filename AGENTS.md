# AGENTS.md — guía operativa de Coco Launcher

Última revisión: 2026-07-26 (America/Santiago).

Este repositorio mantiene **Coco Launcher**, un launcher de experiencias Minecraft aisladas, y conserva **Coco original** como una experiencia heredada. No asumas que la versión, loader, mods o configuración de Coco original aplican a las demás experiencias.

## Empieza aquí

Antes de modificar:

1. Ejecuta `git status --short` y preserva cambios ajenos.
2. Comprueba procesos Minecraft/Java y Publisher.
3. Identifica el alcance: experiencia administrada, Coco original, red, launcher/updater o publicación.
4. Lee únicamente la referencia de esa tarea:

| Tarea | Fuente principal |
|---|---|
| Agregar o modificar una experiencia | Esta guía y `docs\ModpackCompatibilityChecklist.md` |
| Estado, arquitectura y flujo del launcher | `docs\CocoLauncherImplementation.md` |
| Operar sesiones, red o recuperar una instalación | `docs\OPERACION.md` |
| Publicar releases/GitHub | `docs\GITHUB_SETUP.md` |
| Mundo heredado Coco original, DH o rendimiento | `docs\LegacyCocoReference.md` |
| Investigar una regresión histórica del updater | `docs\UpdaterIncidentHistory.md` |
| Evidencia de una experiencia | Su auditoría bajo `docs\` |

No leas todas las referencias por defecto. Abre las necesarias según el cambio.

## Reglas que no se negocian

- No borres ni reemplaces mundos, `saves`, `playerdata`, avances, estadísticas, bases DH, mods o configuraciones del usuario sin autorización explícita y respaldo específico.
- No publiques con Minecraft, una LAN o CocoPublisher abiertos.
- No retires un mod por sospecha: reproduce o reúne evidencia.
- No conviertas una observación histórica en causa actual; verifica procesos, archivos y logs vivos.
- Mantén cada experiencia aislada bajo `%APPDATA%\CocoMinecraft\experiences\<instanceId>`. Nunca mezcles sus `mods`, `config`, `resourcepacks`, `shaderpacks`, mundos o DH con otra experiencia.
- `%APPDATA%\.minecraft` y su carpeta `mods` pertenecen a **Coco original**, no son la fuente de experiencias administradas.
- Essential es la única exclusión global. Todas las demás dependencias declaradas, requeridas u opcionales, se incluyen por defecto.
- Todos los jugadores usan identidad local/offline. CustomSkinLoader debe resolver exactamente una variante compatible por versión de Minecraft. La skin propia es opcional y nunca debe bloquear instalación, red o lanzamiento.
- Nunca publiques secretos, tokens ZeroTier, credenciales o datos personales en código, manifiestos, locks, logs o releases.

## Cambio rápido de una experiencia

Fuentes:

- definición: `launcher\catalog.template.json`;
- lock upstream: `launcher\experiences\<id>.lock.json`;
- instalador y preferencias: `engine\CocoLauncher.ps1`;
- importador CurseForge: `tools\Import-CocoCurseForgePack.ps1`;
- instalación viva: `%APPDATA%\CocoMinecraft\experiences\<instanceId>`.

### Pack nuevo o nueva versión

1. Obtén project/file ID y licencia desde la fuente oficial.
2. Importa con:

   ```powershell
   .\tools\Import-CocoCurseForgePack.ps1 -ProjectId <id> -FileId <id> -SourcePage <url> -SourceLicense <licencia> -OutputPath launcher\experiences\<id>.lock.json
   ```

   El importador conserva dependencias requeridas y opcionales, URLs oficiales, tamaños y hashes.
3. Añade o actualiza la entrada del catálogo con runtime, memoria, hosting, estado y lock.
4. Declara una variante CustomSkinLoader para esa versión si todavía no existe.
5. Decide el mundo explícitamente: plantilla fijada o mundo nuevo aleatorio. Nunca inventes un mapa o seed.

Prepara el candidato con un solo comando:

```powershell
.\tools\Invoke-CocoExperienceDev.ps1 -ExperienceId <id> -Action Prepare -Role host
```

Usa `-Action Launch` para abrir la instancia temporal. Agrega `-Live` únicamente cuando la tarea autorice instalar/probar la instancia viva. El autoingreso permanece desactivado salvo `-EnableAutoJoin`.

### Mods adicionales o retirados

- Mod adicional fuera del manifiesto: `experiences[].files` con URL oficial permitida, tamaño, SHA-256, licencia, `policy: "replace"` y rol.
- Usa `all` para contenido/protocolo; `host` para adaptadores exclusivos del anfitrión; `client` sólo con evidencia de que es puramente cliente.
- Retiro solicitado para una experiencia: ruta exacta en `pack.excludedPaths`, después de revisar dependencias.
- No edites el lock para ocultar archivos y no copies JAR manualmente a la instancia como solución final.
- No hardcodees IDs de experiencia en el engine.

### Configuración y shaders

- Archivo de texto completo para todos los jugadores de una experiencia: `preferences.managedFiles` con ruta bajo `config/` o `shaderpacks/` y contenido exacto (máximo 1 MiB).
- Preferencias soportadas: `standardControls`, `fov`, `resourcePack`, `optifineEmissive`, `voiceChatDefaults` y `shader`.
- `preferences.shader.provider` admite `iris`, `oculus` y `optifine`; `pack` debe coincidir exactamente con un archivo instalado.
- Settings auxiliares del shader: `preferences.shader.companionFiles` o `preferences.managedFiles`.
- Si necesitas modificar claves sin reemplazar el archivo entero, crea un adaptador **genérico y declarativo** en `Set-CocoManagedInstancePreferences` con su prueba. No agregues ramas por nombre de pack.
- Si el catálogo no declara intervención visual, conserva lo que entrega el modpack.

### LAN y mundo

- Ruta normal: ZeroTier `10.77.37.1:25565`, red `58997fc5f3c0c001`.
- MCWiFiPnP moderno debe producir exactamente `OnlineMode=false`, `EnableUUIDFixer=true`, `UseUPnP=false` y puerto 25565. Los nombres kebab-case son inválidos.
- Un adaptador alternativo necesita rol host, hash, versión compatible y prueba real; no inventes configuraciones.
- No anuncies `ready` hasta validar configuración LAN y listener TCP 25565.
- El instalador puede administrar pack/config, pero nunca debe administrar una partida viva bajo `saves`.

## Validación proporcional

Siempre:

- parseo de JSON y PowerShell;
- `tests\Test-CocoLauncherCatalog.ps1`;
- `tests\Test-CocoLauncherLaunch.ps1`;
- prueba específica del cambio;
- `git diff --check`.

Si cambian instalación, archivos, settings o aislamiento:

- `tests\Test-CocoLauncherInstance.ps1`;
- `tests\Test-CocoLauncherIntegration.ps1`;
- comprobar roles, hashes, ausencia de Essential y preservación de `saves`;
- preparar host y cliente cuando cambie el conjunto por rol.

Si cambia una experiencia:

- instalación reanudable;
- arranque real hasta menú;
- mundo real, cierre y reapertura cuando el cambio afecta juego/worldgen;
- host + cliente, LAN y reconexión cuando afecta contenido, protocolo o red.

Si cambia updater/red/publicación, usa las pruebas indicadas en `docs\OPERACION.md` y `docs\GITHUB_SETUP.md`. Un release nuevo debe pasar `tests\Test-CocoRelease.ps1`.

Toda experiencia administrada presente en el catálogo publicado se muestra y puede lanzarse. No existen estados `blocked`, `experimental`, `normal` o `validated` que alteren visibilidad. La evidencia y las pruebas pendientes viven en documentación/auditorías; llegar al menú no equivale a validar juego o multijugador.

## Publicación

La fuente de verdad es el árbol del repositorio y, sólo para Coco original, `%APPDATA%\.minecraft\mods`. No mantengas listas manuales completas de JAR.

Antes de ejecutar `dist\CocoPublisher.exe`:

- Minecraft/LAN cerrados;
- versión pública y estado local verificados;
- `HEAD == origin/main`;
- worktree preparado de forma deliberada;
- pruebas requeridas aprobadas.

El Publisher exige la siguiente versión pública exacta, compila, valida hashes/roles, crea un borrador, actualiza el host y publica únicamente al completar el flujo. Después verifica release, manifiesto, caché/engine del host, Git limpio y `origin/main` sincronizado.

## Rutas de diagnóstico

- Updater: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`
- Sesión/skins: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs\launcher-session-service.log`
- Coco original: `%APPDATA%\.minecraft\logs\latest.log`
- Experiencia: `%APPDATA%\CocoMinecraft\experiences\<instanceId>\logs\latest.log`
- Crash: `<gameDir>\crash-reports`
- Estado Coco original: `%APPDATA%\.minecraft\config\coco-updater-state.json`
- Destino persistido: `%LOCALAPPDATA%\CocoMinecraftUpdater\target.json`

## Mantener la documentación útil

- `AGENTS.md` contiene reglas estables, routing y recetas; no cronologías, conteos de mods, versiones publicadas ni resultados pasajeros.
- Estado vigente por experiencia: `docs\CocoLauncherImplementation.md`.
- Evidencia extensa: auditoría separada.
- Operación y recuperación: `docs\OPERACION.md`.
- Al cambiar un contrato, actualiza la fuente principal y las referencias afectadas; no copies el mismo párrafo en todos los documentos.
