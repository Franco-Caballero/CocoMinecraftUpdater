# Coco original — referencia heredada

Última revisión: 2026-07-26 (America/Santiago).

Esta referencia contiene datos específicos del mundo heredado **Coco original**. No aplican automáticamente a experiencias administradas por Coco Launcher. Verificar el estado vivo antes de actuar.

## Instalación y mundo

- GameDir: `%APPDATA%\.minecraft`
- Mundo: `%APPDATA%\.minecraft\saves\coco`
- Runtime observado: Minecraft 26.1.2, Fabric Loader 0.19.3, Java 25.
- Perfil observado: `fabric-loader-0.19.3-26.1.2`.
- Host/OP: `smolbird`, nivel 4.
- Spawn registrado: `-1907 64 6675`; comprobar `level.dat` si importa.
- La carpeta `%APPDATA%\.minecraft\mods` es autoritativa para publicar **Coco original**.

No mover la instalación ni el mundo. No usar VM por decisión del host.

## LAN, red e identidad

- ZeroTier One 1.16.2.
- Network ID `58997fc5f3c0c001`, subred `10.77.37.0/24`.
- Host `10.77.37.1:25565`.
- Controlador/host `58997fc5f3`.
- TCP 25565 y UDP de voz se limitan a perfil Private, interfaz ZeroTier y origen `10.77.37.0/24`.
- Máximo LAN: 8 jugadores; Survival/PvP activos.
- `online-mode=false`, UUID Fixer activo, UPnP desactivado.
- La whitelist está desactivada: ZeroTier autoriza dispositivos, no autentica nombres offline.

MCWiFiPnP lee `OnlineMode`, `EnableUUIDFixer` y `UseUPnP`; no acepta equivalentes kebab-case.

La identidad `nadicon` está fijada al UUID `8aa9a0d5-6c18-3d17-8655-9ed500e98bc6`. Antes de migrarla o limpiar datos, respaldar `playerdata`, avances y estadísticas y revisar UUID Fixer.

La prueba del 2026-07-15 sostuvo host + seis clientes, rutas DIRECT, 0 % de pérdida en las ventanas medidas y aproximadamente 6–46 ms de ping. Dos atrasos aislados del servidor y un timeout individual no coincidieron con pérdida colectiva.

## Flujo normal

1. Abrir Minecraft; Bridge inicia el autorizador.
2. Entrar a `coco` y abrir LAN; MCWiFiPnP fija TCP 25565.
3. Ejecutar `/e4mc stop` para dejar sólo ZeroTier.
4. Mantener Minecraft abierto durante la sesión.
5. Cerrar normalmente al terminar.

e4mc queda únicamente como contingencia. Si ZeroTier falla, mantenerlo activo y distribuir el dominio temporal. La migración ocurrió por degradación histórica QUIC/Netty; no reabrir esa hipótesis si e4mc no está transportando la sesión actual.

## Distant Horizons y rendimiento

Configuración observada:

- radios LOD/generación/sync: 128 chunks;
- actualización en tiempo real: 64 chunks;
- generación distante: `FEATURES`;
- request/sync rate: 32/16;
- 4 threads, ratio 1.0;
- límite por jugador: 1000 KB/s;
- transferencia adaptativa activa;
- `serverFolderNameMode = "NAME_ONLY"`.

No reducir radios ni desactivar generación sin explicar el impacto. Cada cliente mantiene su propia caché; base del overworld:

`saves\coco\dimensions\minecraft\overworld\data\DistantHorizons.sqlite`

Una captura JFR histórica mostró 6,81 ms/tick promedio, P95 10,4 ms, máximo 16,3 ms y pausas ZGC insignificantes. Es referencia, no diagnóstico actual.

Si reaparece lag:

1. registrar hora, jugadores y dimensiones antes de reiniciar;
2. separar FPS, TPS, heap y red en `latest.log`;
3. capturar `jcmd <PID> GC.heap_info` y `Thread.print`;
4. volcar JFR si existe;
5. usar `/debug start` y `/debug stop` si hace falta.

No culpar DH, C2ME, PacketFixer, Just Hammers o entidades sin evidencia.

## Datos y permisos

- JourneyMap conserva mapas/waypoints localmente; no existe sincronización colectiva.
- El teletransporte requiere permisos; no conceder OP general.
- `inventoryextended` está bloqueado por duplicar el inventario. El respaldo está en `%LOCALAPPDATA%\CocoMinecraftUpdater\backups\20260719-inventoryextended-removal`.
- `tsa-decorations` también está bloqueado mediante `policy\blocked-mod-ids.txt`.

