# Auditoría integral de Coco Launcher — 2026-08-12

## Objetivo

Revisar el flujo completo del launcher y corregir fallas que pudieran afectar una primera instalación, una instalación ya existente, la actualización de contenido, el aislamiento por experiencia, el lanzamiento, la red o la publicación. La revisión incluyó las siete experiencias administradas del catálogo y la instalación viva disponible en el host.

## Hallazgos corregidos

1. **Mods de Big Walk en instalaciones existentes.** El estado standalone antiguo sólo comparaba el hash del ZIP adicional. Si el juego base ya estaba marcado como instalado, no comprobaba que cada archivo BepInEx realmente existiera. El estado vigente usa `schemaVersion: 2`, registra ruta, tamaño y SHA-256 de cada archivo inmutable y repara cualquier archivo ausente o alterado al abrir Coco Launcher.
2. **Actualización transaccional de extras.** Los ZIP adicionales se preparan y verifican antes de modificar la instancia. Un fallo restaura los archivos anteriores; un plugin retirado del paquete también se retira de la instalación.
3. **Configuraciones del jugador.** Los archivos bajo `BepInEx/config` se inicializan sólo cuando faltan. Una reparación, migración o actualización no reemplaza volumen, controles ni otras preferencias existentes.
4. **Roles standalone.** Los archivos `all`, `host` y `client` se resuelven según el rol activo. Cambiar de rol retira de forma transaccional los archivos exclusivos que ya no corresponden.
5. **Archivos base reparables.** Big Walk declara el EXE, `OnlineFix64.dll`, `winmm.dll` y `EOSSDK-Win64-Shipping.dll` con ruta, tamaño, SHA-256 y SHA-256 de la parte exacta que los contiene. Si falta uno, el launcher recupera únicamente el archivo fijado desde su archivo oficial; ya no examina ZIP de otras experiencias ni depende de que el caché siga presente.
6. **Extracción segura.** Los paquetes standalone rechazan rutas absolutas, traversal y entradas duplicadas antes de usar cualquiera de los mecanismos de extracción.
7. **Staging en ubicaciones personalizadas.** La limpieza ahora reconoce de manera estricta los staging hermanos de una instancia personalizada. Se eliminaron dos staging temporales abandonados (Cobbleverse vacío y VALORANTCraft de aproximadamente 63 MiB) sin tocar mundos ni instalaciones vivas.
8. **Protección al eliminar una experiencia.** Se corrigió la prueba que, por un error de scope, no ejercitaba realmente el bloqueo cuando el juego estaba abierto. La protección del engine quedó confirmada.
9. **Defender y OnlineFix declarativos.** La política dejó de estar codificada por nombre de juego. La exclusión se consulta primero y sólo se solicita elevación cuando falta; el identificador de OnlineFix vive en el catálogo.
10. **Publicación directa segura.** `Publish-CocoRelease.ps1` aplica su propio preflight para Minecraft, experiencias standalone, Coco Launcher/Updater, Publisher y puertos LAN. Durante la validación del host impide que el updater intente descargar desde un release que aún está oculto como borrador.

## Evidencia viva

- La instalación existente de Big Walk migró a esquema 2 mediante una preparación real, sin abrir el juego.
- Quedaron 42 archivos BepInEx inmutables registrados y verificados; `BigVoice.dll`, `EnhancedControls.dll` y `FlipOff.dll` están presentes.
- Los hashes de `BepInEx.cfg`, `BigVoice.cfg`, `deck.bigwalk.flipoff.cfg` y `mhz.bigwalk.enhancedcontrols.cfg` fueron idénticos antes y después de la migración.
- El EXE y las tres DLL críticas coinciden en tamaño y SHA-256 con el contrato del catálogo.
- El log vivo anterior de BepInEx confirma la carga real de Big Voice 1.0.0, Big Disrespect 1.0.1 y Enhanced Controls 1.0.1.
- La instancia viva de VALORANTCraft conserva TACZ, CSmain, Origins, Valorant Origins, MCWiFiPnP, Coco VALORANT Tools, gunpack, ambos mundos y configuración LAN válida.

## Validación automatizada

Se analizaron todos los PowerShell y JSON versionados. Pasaron las suites de:

- catálogo, locks, rutas y ensamblado de assets;
- instalación, reparación, reanudación, migración, ubicaciones y almacenamiento;
- extras standalone, caché vacío, corrupción, cambio de rol, retiro de plugins, preservación de config y ZIP traversal;
- launch, backend, identidad, logs, observabilidad y reintentos;
- integración, skins, voz, UI y layout;
- lifecycles host/cliente, sesión, serialización, LAN, ZeroTier y adaptadores;
- updater, bootstrap, detección, recuperación, políticas de ejecución y diagnósticos;
- VALORANTCraft (herramientas, mapas, Orb y preflight vivo);
- release y políticas del Publisher.

## Límite de la auditoría

El código y el host quedaron cubiertos por pruebas sintéticas y evidencia viva. Ninguna auditoría local puede garantizar las condiciones externas de cada PC —antivirus de terceros, permisos/UAC, Steam, caída de GitHub o red doméstica— ni sustituir una sesión física con varios computadores. Ante esos casos, el launcher ahora falla de forma verificable y reparable en vez de dejar una instalación parcialmente actualizada.
