# AGENTS.md — contexto canónico de CocoMinecraftUpdater

Última revisión: 2026-07-16 (America/Santiago).

Este archivo contiene el estado operativo necesario para trabajar en `C:\Users\smol\Desktop\random\CocoMinecraftUpdater`. Antes de intervenir, verificar archivos, procesos y logs: los valores observados pueden cambiar durante una sesión. Si cambia la red, el updater, la versión publicada o una decisión operativa, actualizar también `README.md`, `docs\OPERACION.md` y `docs\GITHUB_SETUP.md` cuando corresponda.

## Objetivos y reglas

1. Mantener jugable el mundo cooperativo `coco`, alojado desde el cliente mediante **Abrir en LAN**.
2. Admitir perfiles premium y offline/no-premium sin port forwarding.
3. Mantener baja latencia y automatizar red y mods con la mínima interacción.
4. Preservar mecánicas, mundo, identidades y configuración de Distant Horizons (DH).
5. Medir antes de atribuir lag o modificar límites.

Reglas obligatorias:

- No borrar mundos, `playerdata`, bases DH, mods ni configuraciones sin autorización explícita y respaldo específico.
- No publicar mientras Minecraft o la LAN estén abiertos.
- No tratar hipótesis históricas como causas actuales.
- No retirar un mod por sospecha sin reproducción o evidencia.
- La fuente viva de mods es `%APPDATA%\.minecraft\mods`; el manifiesto publicado es `release\latest.json`.

## Entorno

- Repositorio: `C:\Users\smol\Desktop\random\CocoMinecraftUpdater`
- Instalación host: `C:\Users\smol\AppData\Roaming\.minecraft`
- Mundo: `%APPDATA%\.minecraft\saves\coco`
- Minecraft Java: **26.1.2**
- Fabric Loader: **0.19.3**
- Java: **25** (`java-runtime-epsilon`)
- Perfil: `fabric-loader-0.19.3-26.1.2`
- Host/OP: `smolbird`, nivel 4
- Spawn registrado: `-1907 64 6675`; verificar `level.dat` si una tarea depende del valor exacto.

## Red principal: ZeroTier

ZeroTier es la ruta de producción. Minecraft usa TCP normal hacia una IP virtual; e4mc no participa en el tráfico de las sesiones ZeroTier.

- ZeroTier One: **1.16.2**
- Red privada autocontrolada: `Coco Minecraft`
- Network ID: `58997fc5f3c0c001`
- Subred: `10.77.37.0/24`
- Host: `10.77.37.1:25565`
- Nodo controlador/host: `58997fc5f3`
- Servicio y adaptador se instalan y reparan mediante CocoUpdater.
- El controlador local autoriza nodos pendientes mientras Minecraft del host está abierto; no se usa ZeroTier Central ni se distribuyen tokens administrativos.
- Firewall host: entrada TCP 25565, perfil Private, interfaz ZeroTier, origen `10.77.37.0/24`.
- Clientes: perfil ZeroTier Public, sin regla de entrada Coco.
- `servers.dat` recibe la entrada `Coco Minecraft` automáticamente.

Validación real del 2026-07-15:

- Hasta seis clientes simultáneos más el host.
- Seis rutas `DIRECT`, 0 % de pérdida en las ventanas medidas.
- Ping observado por cliente entre aproximadamente 6 y 46 ms.
- Sesión cercana a dos horas sin degradación colectiva, errores de compresión ni canales e4mc.
- Hubo dos atrasos aislados del servidor integrado (3,1 s y 2,7 s) y un timeout individual con reconexión; no coincidieron con pérdida colectiva ni fallo de ZeroTier.

Flujo normal del host:

1. Abrir Minecraft; Bridge inicia silenciosamente el autorizador.
2. Entrar al mundo y usar **Start LAN**; MCWiFiPnP fija TCP 25565.
3. Ejecutar `/e4mc stop` para dejar solo la ruta ZeroTier.
4. Mantener Minecraft abierto durante la sesión.
5. Cerrar normalmente al terminar; el autorizador se detiene con el proceso.

### e4mc: respaldo

`e4mc-fabric-6.2.0-modern.jar` permanece únicamente en el paquete host como contingencia. Si ZeroTier no está disponible, no detener e4mc y distribuir el dominio temporal mostrado por el juego. En operación normal, detenerlo después de abrir la LAN para evitar una segunda ruta pública.

Motivo de la migración: e4mc presentó degradación compartida de QUIC/Netty con `ClosedChannelException`, `connection lost`, timeouts y `DataFormatException: incorrect header check`. Reiniciar la LAN recuperaba la sesión. JFR descartó TPS y GC como causa de ese incidente y mostró saturación del event loop e4mc. No reabrir esa investigación salvo que la ruta e4mc vuelva a usarse.

## LAN, autenticación e identidades

Fuente: `saves\coco\mcwifipnp.json`.

- Puerto fijo: **25565**
- UPnP: desactivado
- Máximo: 8 jugadores
- Survival y PvP activos
- `online-mode=false`
- UUID Fixer activo
- Whitelist actualmente desactivada; los nombres offline pueden suplantarse. Verificar antes de afirmar que existe protección por whitelist.

La identidad `nadicon` está fijada manualmente al UUID `8aa9a0d5-6c18-3d17-8655-9ed500e98bc6` para conservar datos históricos. No migrar ni limpiar sus archivos sin revisar primero la regla de UUID Fixer y respaldar `playerdata`, avances y estadísticas.

## CocoMinecraftUpdater

Estado publicado:

- Release estable: **0.5.37**
- Host: 0.5.37, rol `host`
- Bridge: `coco-session-bridge-0.5.37.jar`
- EXE canónico: `%LOCALAPPDATA%\CocoMinecraftUpdater\CocoUpdater.exe`, 0.5.37.0; hash verificado contra el manifiesto público.
- Manifiesto: 148 mods de cliente y 152 de host
- Marcador de rol host: `config\coco-host.json`; nunca se distribuye.

Incidente resuelto el 2026-07-16: 0.5.35 corrigió el falso error inicial y la detección de una JVM antigua, pero su helper usó un backup nulo con `File.Replace`, inválido en Windows PowerShell 5.1. 0.5.36 publicó el helper correcto y convirtió la carpeta `mods` en autoritativa, retirando `inventorysorter`; la verificación posterior descubrió que el Publisher intentaba descargar el bootstrap desde el release aún borrador y recibía 404. 0.5.37 instala el EXE compilado localmente antes de actualizar el host. Se verificaron release público, host, Bridge, Publisher, EXE canónico/hash, manifiesto, Git y ausencia de Minecraft abierto.

Comportamiento desde 0.5.37:

- Primera instalación: abrir la instancia Fabric correcta hasta el menú y ejecutar el EXE una vez.
- El bootstrapper se autoactualiza, detecta `--gameDir`, prepara ZeroTier, sincroniza mods e instala Bridge/Gate.
- La elevación se solicita solo cuando Windows necesita instalar o reparar red. Desde 0.5.28 no se requiere ejecutar manualmente como administrador.
- Bridge ejecuta `-NetworkOnly` silencioso al arrancar y un chequeo completo al iniciar login. Red y actualización usan estados de sesión separados; el chequeo completo se reintenta hasta tres veces. Una red y pack sanos no muestran UI ni cierran el juego.
- El chequeo de login pasa al engine la versión cargada en la JVM; la ejecución manual compara además el inicio de Minecraft con `installedAt`. Si el release nuevo ya está en disco pero la JVM es anterior, el updater cierra únicamente ese cliente y solicita reabrir sin reinstalar; si faltan archivos, instala antes de solicitarlo.
- El reemplazo del EXE canónico nunca es requisito para continuar el engine: si Windows lo mantiene mapeado, queda una copia verificada pendiente hasta 12 horas y no se informa un falso error de conexión/mods.
- Toda operación visible que termina correctamente conserva la ventana de la reina con `TODO LISTO`, indicador verde, texto ampliado y botón `ACEPTAR`; también responde a Enter y no se cierra por temporizador. Los chequeos automáticos sanos siguen sin mostrar UI.
- No existe un monitor periódico permanente.

Política de mods:

- Los clientes reciben exactamente el conjunto publicado.
- `managed-config\Stackable.json` se distribuye como `config\Stackable.json` en ambos roles y fija `maxStack = 256`; cambiarlo es una decisión global de mecánica.
- El host es la fuente del Publisher y conserva JAR adicionales con un Fabric ID nuevo.
- Una versión anterior cuyo Fabric ID ya está publicado no se duplica.
- La carpeta viva `%APPDATA%\.minecraft\mods` es autoritativa: agregar o quitar JAR se refleja directamente en la publicación siguiente, sin `-AllowModRemoval`.
- `tsa-decorations` está retirado permanentemente y `policy\blocked-mod-ids.txt` impide reintroducirlo en la fuente viva o en cualquier rol publicado.
- El Publisher exige exactamente la siguiente versión pública, `HEAD == origin/main` al comenzar y que `origin/main` no cambie durante la compilación.
- No mantener listas estáticas completas de JAR en documentación; consultar `mods` y `release\latest.json`.

Publicación, con Minecraft cerrado:

1. Dejar en `%APPDATA%\.minecraft\mods` el conjunto deseado.
2. Ejecutar `dist\CocoPublisher.exe`.
3. El Publisher incrementa versión, compila, valida hashes/roles, ejecuta pruebas, crea un release borrador, actualiza el host y solo entonces publica.
4. Verificar release público, manifiesto estable, Git limpio y `origin/main` sincronizado.

Pruebas mínimas al modificar el updater:

- Parseo de sintaxis PowerShell.
- `tests\Test-CocoRelease.ps1` para un release nuevo.
- `tests\Test-CocoEngineRecovery.ps1`.
- Pruebas específicas de Bridge/ZeroTier afectadas por el cambio.
- Confirmar que `-Silent` no abre UI.

## DH y rendimiento

Configuración relevante en `config\DistantHorizons.toml`:

- Radio LOD, generación y sync máxima: 128 chunks.
- `realTimeUpdateDistanceRadiusInChunks = 64`
- Generación servidor/distante activa, modo `FEATURES`.
- `generationRequestRateLimit = 32`, `syncOnLoadRateLimit = 16`.
- 4 threads, ratio 1.0.
- `playerBandwidthLimit = 1000` KB/s, sin límite global explícito.
- `enableAdaptiveTransferSpeed = true`.
- `serverFolderNameMode = "NAME_ONLY"`.

No reducir radios ni desactivar generación sin explicar el impacto. Cada cliente renderiza y almacena su propia caché LOD; el servidor puede generar o transferir datos faltantes.

Hallazgos de rendimiento:

- Captura histórica JFR: 6,81 ms/tick promedio, P95 10,4 ms, máximo 16,3 ms; pausas ZGC insignificantes.
- El tráfico e4mc histórico estuvo dominado por actualizaciones de entidades, no por custom payloads DH.
- PacketFixer usa timeouts de 30 s; no existe evidencia de duplicación de paquetes.
- En la prueba ZeroTier extensa, los picos de ticks coincidieron con teletransporte/generación y no con pérdida de red.
- La línea de comandos viva observada usa `-Xmx6714M`; verificar siempre `VM.flags`/`GC.heap_info`, porque el launcher puede regenerar argumentos.

Si reaparece lag grave:

1. No reiniciar inmediatamente.
2. Registrar hora, participantes y dimensiones.
3. Revisar `latest.log` y separar FPS, TPS, heap y red.
4. Capturar `jcmd <PID> GC.heap_info` y `Thread.print`.
5. Si existe una grabación JFR activa, volcarla; no asumir que sobrevive a reinicios.
6. Opcionalmente usar `/debug start` y `/debug stop` para ticks vanilla.

No culpar Just Hammers, DH, C2ME, PacketFixer o un mod de entidades sin una captura que lo sostenga.

## JourneyMap y permisos

- JourneyMap 6.0.0 guarda mapa y waypoints localmente por cliente; no existe sincronización colectiva configurada.
- El teletransporte requiere permisos; actualmente solo `smolbird` es OP.
- No conceder OP general ni copiar árboles completos de JourneyMap entre instalaciones como solución improvisada.

## Rutas de soporte

- Updater: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`
- Bridge: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs\bridge-<PID>.log`
- Minecraft: `%APPDATA%\.minecraft\logs\latest.log`
- Crash reports: `%APPDATA%\.minecraft\crash-reports`
- Estado instalado: `%APPDATA%\.minecraft\config\coco-updater-state.json`
- Destino persistido: `%LOCALAPPDATA%\CocoMinecraftUpdater\target.json`
- DH: `saves\coco\dimensions\minecraft\<dimension>\data\DistantHorizons.sqlite`

## Seguridad operativa

- `CocoUpdater.exe` aún no tiene una firma de código con reputación; SmartScreen puede advertir en la primera ejecución.
- Nunca incluir tokens ZeroTier, credenciales GitHub o secretos del controlador en EXE, JAR, manifiesto o release.
- Conocer el Network ID permite solicitar ingreso mientras el autorizador está activo. La contención depende del firewall y de la whitelist; la autorización del dispositivo no autentica un nombre offline.
- Comandos destructivos como `/kill @e[type=item]` requieren confirmación explícita.
