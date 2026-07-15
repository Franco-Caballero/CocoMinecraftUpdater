
# AGENTS.md — contexto canónico del servidor Coco y CocoMinecraftUpdater

Última revisión: 2026-07-14 (America/Santiago).

Este es el punto de entrada canónico para cualquier agente o thread que trabaje desde `C:\Users\smol\Desktop\random\CocoMinecraftUpdater`. Cubre tanto el proyecto Coco Updater como la instalación de Minecraft, el mundo cooperativo, la red, Distant Horizons, los mods y las investigaciones de rendimiento. No debe tratar hipótesis antiguas como hechos. Antes de intervenir, verificar el estado vivo mediante archivos, logs y procesos. Si cambia el flujo del updater, la red, la versión del pack o una decisión importante, actualizar este archivo y la documentación del repositorio.

No mantener otra copia de este documento bajo `.minecraft`; el directorio `mods problematicos` es únicamente una cuarentena de JARs y no la fuente de documentación.

## Prioridades del usuario

1. Mantener jugable el mundo cooperativo `coco`, alojado desde el cliente del host mediante **Abrir en LAN**.
2. Permitir clientes premium y no-premium/offline sin abrir puertos manualmente.
3. Mantener latencia baja para jugadores principalmente en Chile.
4. Usar Distant Horizons (DH) para horizontes grandes sin elevar innecesariamente la distancia vanilla ni alterar mecánicas.
5. Sincronizar automáticamente los mods de amigos con el menor roce posible.
6. Ante problemas de rendimiento, preservar la jugabilidad: primero medir; después aplicar límites de red, memoria o diagnóstico que no cambien mecánicas.

## Instalación y mundo

- Raíz del host: `C:\Users\smol\AppData\Roaming\.minecraft`
- Mundo: `C:\Users\smol\AppData\Roaming\.minecraft\saves\coco`
- Minecraft: **26.1.2**
- Loader activo: **Fabric Loader 0.19.3**
- Java del juego: Java 25 (`java-runtime-epsilon`)
- Perfil activo observado: `fabric-loader-0.19.3-26.1.2`
- Host/jugador operador: `smolbird`, nivel OP 4.
- Spawn configurado por el usuario con `/setworldspawn -1907 64 6675`. Tratarlo como intención registrada; si una tarea depende de la coordenada exacta, verificar `level.dat` o ejecutar `/worldborder get`/comando equivalente según corresponda.
- Ajustes vanilla observados el 2026-07-14: render distance 4, simulation distance 5. Estos valores pueden cambiar en tiempo real; leer `options.txt` antes de afirmar el valor actual.

## Red LAN y autenticación

### Componentes

- `e4mc-fabric-6.2.0-modern.jar`: crea un túnel público QUIC y asigna un dominio temporal `*.cl.e4mc.link`. No modifica autenticación.
- `mcwifipnp-2.0.0-26.1.2-fabric.jar`: controla Abrir en LAN, online mode, UUID Fixer y opciones del servidor integrado.
- No se depende de UPnP ni port forwarding para e4mc. Un error de UPnP no implica que e4mc haya fallado.

### Configuración LAN verificada

Fuente: `saves\coco\mcwifipnp.json`.

- Puerto de la sesión observada: `49261` (cambia entre aperturas).
- Máximo de jugadores: 8.
- Survival, PvP activo.
- `online-mode=false` para permitir cuentas offline/no-premium.
- UUID Fixer activo.
- Whitelist de MCWiFiPnP actualmente desactivada (`enforce-whitelist=false`). Esto es un riesgo porque una identidad offline se basa en el nombre y puede ser suplantada. No afirmar que existe whitelist sin verificar.
- Dominio e4mc más reciente observado: `unrobed-nearly.cl.e4mc.link`. Es efímero; obtener siempre el actual desde el chat o `logs\latest.log`.

### Identidades y UUID Fixer

- Política predeterminada observada: `online`.
- La jugadora cambió su nombre de `sketcheando` a `nadicon` y perdió inventario por el cambio de UUID.
- Se creó una regla manual para que `nadicon` use `8aa9a0d5-6c18-3d17-8655-9ed500e98bc6`, conservando los datos asociados a la identidad anterior.
- `usercache.json` puede contener más de una entrada histórica para `nadicon`; no borrar ni migrar archivos de jugador sin verificar la regla activa de UUID Fixer y hacer un respaldo específico de `playerdata`, avances y estadísticas.

## Distant Horizons: modelo correcto y ajustes actuales

DH distingue al menos estas operaciones:

1. Generación/carga de chunks vanilla o datos de mundo.
2. Construcción y almacenamiento de datos LOD.
3. Sincronización de LOD entre servidor y clientes.
4. Renderizado local de esos LOD por cada cliente.

El radio visual de un cliente no convierte mágicamente todos los chunks en chunks vanilla activos. El servidor puede generar o servir datos LOD según su configuración; cada cliente renderiza y guarda su propia caché. Datos ya presentes en la base DH del host pueden reutilizarse y enviarse sin repetir toda la generación vanilla, pero una ausencia real puede producir solicitudes de generación en el host.

### Ajustes verificados en `config\DistantHorizons.toml`

- `lodChunkRenderDistanceRadius = 128`
- `maxGenerationRequestDistance = 128`
- `maxSyncOnLoadRequestDistance = 128`
- `realTimeUpdateDistanceRadiusInChunks = 64`
- `enableServerGeneration = true`
- `enableDistantGeneration = true`
- `distantGeneratorMode = "FEATURES"`
- `generationMaxChunkRadius = 0`: no existe un límite global fijo alrededor del centro; rigen los radios configurados alrededor de las solicitudes/jugadores.
- `generationRequestRateLimit = 32`
- `syncOnLoadRateLimit = 16`
- `numberOfThreads = 4`
- `threadRunTimeRatio = "1.0"`
- `playerBandwidthLimit = 1000` KB/s
- `globalBandwidthLimit = 0` (sin límite global explícito)
- `enableAdaptiveTransferSpeed = true`, activado el 2026-07-14 como mitigación de congestión. No cambia mecánicas: adapta el tráfico LOD.
- `serverFolderNameMode = "NAME_ONLY"`: ayuda a reutilizar la caché de un mismo servidor aunque e4mc entregue otro dominio. Si dos mundos distintos usan exactamente el mismo nombre, existe riesgo de colisión; verificar antes de reutilizar/copiar bases.

No reducir radios, desactivar generación o cambiar el modo sin explicar el impacto al usuario. Los valores pueden ser modificados por el juego; releer el archivo después de cerrar Minecraft.

## Mods: fuente canónica y cuarentena

La lista exacta activa es siempre el contenido de:

`C:\Users\smol\AppData\Roaming\.minecraft\mods`

No copiar aquí una lista completa estática: se vuelve obsoleta. El manifiesto publicado es `C:\Users\smol\Desktop\random\CocoMinecraftUpdater\release\latest.json`.

Stack relevante actual: DH 3.2.0-b, e4mc 6.2.0, MCWiFiPnP 2.0.0, C2ME 0.4.0 alpha, Sodium, Iris, Lithium, FerriteCore, ImmediatelyFast, EntityCulling, ScalableLux, PacketFixer, JourneyMap, JEI, Biomes O' Plenty, Terralith y mods de contenido/animales.

### Esta carpeta es cuarentena, no carpeta de mods

`C:\Users\smol\AppData\Roaming\.minecraft\mods problematicos`

Estado al 2026-07-14:

- `SubtleEffects-fabric-26.1-1.14.3.jar`: retirado y en cuarentena durante pruebas de lag.
- `pingview-fabric-1.6.jar`: activo nuevamente por decisión explícita del usuario y publicado en 0.5.22.
- Los diez mods YUNG's y `YungsCaveBiomes` añadidos antes de 0.5.22 son intencionales y forman parte del pack; no retirarlos como si fueran residuos de publicación.


El Publisher toma como verdad la carpeta `mods`; por tanto, un JAR puesto aquí queda excluido de futuras publicaciones mientras no vuelva a `mods`.

## Investigación de lag persistente

### Síntoma

En ocasiones, después de ráfagas grandes de cambios de bloques (TNT o dos jugadores usando martillos en el Nether), los invitados sufren lag severo y permanente. El host puede seguir renderizando con normalidad. Alejarse, dejar de minar o cambiar de dimensión no siempre recupera la sesión; cerrar y volver a abrir el servidor LAN sí limpia el problema. No se reprodujo de manera determinista: varios ensayos posteriores con uno o dos martillos funcionaron bien.

### Evidencia observada el 2026-07-14

- No apareció `Can't keep up` ni watchdog del servidor en la ventana analizada.
- En dos cierres se observaron grandes colas de descarga: hasta 991 chunks del Overworld y 1641 del Nether esperando descargarse.
- Hubo muchos `Received passengers for unknown entity`, compatibles con referencias de entidades fuera de orden o ya descargadas, aunque no prueban por sí solos la causa.
- DH produjo al cerrar el mundo un `Failed to decode message` porque llegó una `FullDataSourceRequestMessage` cuando ya no había mundo cargado. Probablemente es consecuencia de una solicitud en tránsito durante el cierre, no prueba de que haya iniciado el lag.
- e4mc transportaba las conexiones por QUIC/Netty.
- DH permitía 1000 KB/s por jugador, sin límite global y con adaptación desactivada. Se activó `enableAdaptiveTransferSpeed=true`.
- El heap efectivo era 4 GB y estaba en 3356 MB usados de 4096 MB. TLauncher añadía `-Xmx10680M`, pero los JSON de versión agregaban después `-Xmx4G`; el último argumento ganaba.
- Se eliminó `-Xmx4G` de ambos JSON de perfil para que, en el próximo arranque completo, prevalezca la memoria elegida en TLauncher. Archivos modificados:
  - `versions\fabric-loader-0.19.3-26.1.2\fabric-loader-0.19.3-26.1.2.json`
  - `versions\Fabric 26.1.2\Fabric 26.1.2.json`
- TLauncher puede regenerar esos JSON. En el próximo arranque verificar el comando real y `jcmd <PID> GC.heap_info`; no asumir que el arreglo persistió.

### Captura concluyente de ZoeSokolov88 (2026-07-14, 01:24-01:31)

- Se volcó correctamente la grabación circular mientras Zoe reportaba lag. Archivos principales en `C:\Users\smol\Desktop\random\power-logs`:
  - `minecraft-lag-capture-20260714-0110.jfr` (80,6 MB; en realidad volcado cerca de las 01:24).
  - `minecraft-lag-capture-after-zoe-rejoin.jfr`.
  - `minecraft-packets-20s.jfr` (captura enfocada por tipo de paquete).
- En los 30 minutos capturados, el servidor promedió **6,81 ms/tick**, P95 **10,4 ms**, máximo **16,3 ms** y jamás superó 50 ms. No fue lag de ticks.
- ZGC acumuló solo **6,5 ms** de pausas en 379 pausas; máximo 0,134 ms. No fue una pausa de GC.
- El heap vivo estaba en 3090 MB/4096 MB. La sesión seguía usando `-Xmx4G` porque había empezado antes del próximo reinicio/verificación del perfil.
- El event loop compartido por e4mc, `Netty NIO IO #7`, consumió 95,9 % de un núcleo en una medición viva de 5 segundos. Es el cuello inmediato.
- Tras detener por completo JFR, el mismo hilo todavía consumía 95 % de un núcleo; la instrumentación no creó el cuello. La grabación `CocoLag` quedó detenida y `minecraft-lag-rolling.jfr` contiene el volcado final (86,5 MB). No asumir que sigue grabando.
- En 20 segundos se enviaron 30.676 paquetes y se recibieron 7.698. Los tipos salientes dominantes fueron 9.322 `set_entity_motion`, 6.598 `rotate_head`, 5.842 `move_entity_pos` y 4.709 `move_entity_pos_rot`; hubo solo 837 `custom_payload`. El tráfico dominante era actualización de entidades, no DH.
- Zoe estaba en `QuicStreamAddress{streamId=17}`. Aunque intentaba volver a entrar, la sesión vieja no se declaró desconectada hasta las 01:26:11. Entró correctamente tres segundos después por `streamId=41`; otro intento viejo (`streamId=37`) expiró después. Esto confirma una conexión/cola individual obsoleta durante el episodio.
- Tras reconectar, Zoe recibió normalmente entre 0,5 y 1,1 Mbps, alrededor de 500 paquetes/s. Los otros clientes podían seguir bien porque cada jugador tiene su stream, aunque todos comparten el mismo event loop QUIC.
- `packetfixer` no parece duplicar actualizaciones: su bytecode modifica límites de compresión, NBT y timeouts. No retirarlo basándose en esta captura.
- Se comprobó que `packetfixer.properties` tenía `readTimeout=120`, `loginTimeout=120` y `keepAliveTimeout=120`, frente a los 30 segundos vanilla. Esto explica que una sesión obsoleta pueda persistir unos dos minutos. Se cambiaron los tres a **30**; el cambio se aplica únicamente tras reiniciar Minecraft y no modifica mecánicas del mundo.
- Existe `toms_mobs-3.0.3+26.1.2.jar`, pero la captura no identifica qué tipos concretos de entidad originaron los movimientos. No culparlo sin una medición de entidades/tipos.

### Interpretación actual

Está confirmado que el problema observado con Zoe fue saturación del único event loop QUIC/Netty y una sesión individual que tardó en cerrarse, no lag de ticks ni GC. En esa ventana, la mayor presión provenía de actualizaciones de entidades; DH no dominó el conteo de paquetes. Sigue sin estar confirmado qué entidades o mod originan tantas actualizaciones ni por qué ciertos episodios comienzan después de minería/TNT. El martillo puede actuar como disparador indirecto (entidades, drops y movimientos), pero no hay evidencia de un bug propio del mod.

### Diagnóstico preparado

Se inició una grabación JFR circular `CocoLag` con máximo 30 minutos/256 MB en el proceso que estaba activo. Ruta prevista:

`C:\Users\smol\Desktop\random\power-logs\minecraft-lag-rolling.jfr`

El archivo puede permanecer en 0 bytes hasta hacer `JFR.dump` o cerrar el proceso con `dumponexit=true`. La grabación no sobrevive a un reinicio de Minecraft.

Si vuelve el lag:

1. No reiniciar inmediatamente.
2. Registrar hora exacta y quién está en cada dimensión.
3. Volcar JFR: `jcmd <PID> JFR.dump name=CocoLag filename="C:\Users\smol\Desktop\random\power-logs\minecraft-lag-capture.jfr"`.
4. Capturar `jcmd <PID> GC.heap_info`, `jcmd <PID> Thread.print` y los últimos minutos de `logs\latest.log`.
5. Si se desea perfil de ticks vanilla, ejecutar `/debug start`, esperar durante el problema y luego `/debug stop`. JFR ya cubre más áreas; `/debug` complementa con ticks.
6. Solo después reiniciar la LAN.

No introducir todavía límites más agresivos de DH ni retirar Just Hammers basándose solo en la hipótesis.

## JourneyMap, exploración y teletransporte

- El mapa instalado es **JourneyMap 6.0.0**, no Xaero.
- La exploración visible se guarda localmente por cliente bajo `journeymap\data`; las zonas recorridas por un amigo no aparecen automáticamente en el mapa del host. No hay sincronización colectiva configurada.
- Los waypoints y mapas tampoco deben asumirse compartidos solo porque todos tengan el mismo JAR.
- El teletransporte desde el mapa termina ejecutando una acción/comando que normalmente requiere permisos. Actualmente solo `smolbird` es OP.
- No existe todavía una solución de permisos instalada para permitir teletransporte de JourneyMap a todos sin OP. Implementarlo requeriría un mod/servicio de comandos y reglas limitadas; no dar OP general como workaround silencioso.
- No copiar carpetas completas de JourneyMap entre usuarios sin revisar IDs de mundo/servidor, porque puede mezclar mapas distintos.

## Coco Minecraft Updater

### Ubicaciones y documentación

- Repositorio local: `C:\Users\smol\Desktop\random\CocoMinecraftUpdater`
- GitHub: `Franco-Caballero/CocoMinecraftUpdater`
- Documentación que debe mantenerse al día:
  - `README.md`: explicación general y primera instalación.
  - `docs\OPERACION.md`: publicación, recuperación y soporte.
  - `docs\GITHUB_SETUP.md`: canal estable y arquitectura de assets.
  - Este `AGENTS.md`: contexto combinado del juego y decisiones operativas.

Cuando se cambie comportamiento, actualizar código, pruebas y documentación en el mismo cambio. No documentar como publicado algo que solo esté modificado localmente.

### Estado verificado

- Release público estable: **0.5.28**.
- Host instalado: pack 0.5.28, rol `host`.
- Bridge activo: `coco-session-bridge-0.5.28.jar`.
- EXE canónico: `%LOCALAPPDATA%\CocoMinecraftUpdater\CocoUpdater.exe`, versión 0.5.28.0.
- Manifiesto 0.5.28: 69 mods de cliente y 71 de host. Incluye `pingview`, los mods YUNG's y `geckolib-fabric-26.1.2-5.5.2.jar`, todos confirmados por el usuario.
- El host se identifica exclusivamente mediante `config\coco-host.json`, que no se distribuye.
- Cliente excluye e4mc y MCWiFiPnP; host los incluye. Ambos roles reciben Bridge/Gate.
- Los clientes reemplazan exactamente la carpeta `mods`. Desde 0.5.25 el host conserva JAR adicionales con un Fabric ID nuevo porque su carpeta es la fuente del Publisher; una versión vieja cuyo ID ya está en el manifiesto no se duplica. El Publisher bloquea la desaparición de IDs publicados salvo `-AllowModRemoval` y autorización explícita. No conserva respaldos permanentes de archivos retirados deliberadamente.
- Los JAR se publican como assets inmutables por SHA-256; cada actualización descarga solo faltantes/diferentes.

### Flujo actual esperado

Primera instalación:

1. El amigo abre la instancia Fabric 26.1.2 correcta hasta el menú principal.
2. Ejecuta una vez el `CocoUpdater.exe` compartido.
3. El updater usa `--gameDir` para identificar la instalación, cierra Minecraft, sincroniza mods e instala Session Bridge.

Actualizaciones posteriores:

1. Bridge **no** debe abrir el updater al arrancar Minecraft.
2. Bridge ejecuta un chequeo `-NetworkOnly` al arrancar Minecraft tanto en host como clientes; no cambia mods ni cierra el juego. Al iniciar el login (`ClientLoginConnectionEvents.INIT`) ejecuta el chequeo completo antes de la sincronización de registros. En el host el chequeo de red mantiene activo el autorizador durante esa sesión.
3. Si está actualizado, el chequeo termina inmediatamente.
4. Si está atrasado, Gate rechaza la versión antigua, el updater cierra Minecraft, instala y muestra cuándo se puede reabrir.
5. No existe un monitor permanente cada 60 segundos en la versión nueva.

Un cliente todavía en Bridge 0.5.17 puede abrir el updater al iniciar; debe completar una última actualización con el comportamiento antiguo.

### Cambios publicados en 0.5.22 a 0.5.28

`engine\CocoUpdater.ps1` y Session Bridge publicaron estos cambios en 0.5.22:

- Solicitar cierre normal directamente al PID de Minecraft.
- Reintentar el cierre automáticamente.
- Si un cliente no responde en 20 segundos, terminar solo ese proceso de Minecraft.
- No forzar el cierre del host.
- Hacer que las pruebas `-Silent` no abran la ventana visual.
- Instalar/reparar ZeroTier antes de la comprobación de versión del pack, con una única elevación cuando haga falta.
- Autorizar automáticamente nodos en el controlador local del host, sin secretos de Central.
- Crear/reparar la entrada `Coco Minecraft` en la lista de servidores.
- Incluir pruebas de red estáticas, de estado vivo y end-to-end mediante el propio engine.
- 0.5.23 añade heartbeat del autorizador, reintento de MSI/NLA, limpieza de reglas host en clientes, diagnóstico DIRECT/RELAY y reparación `-NetworkOnly` al arrancar.
- 0.5.23 republica la configuración del controlador inmediatamente después de aceptar nodos nuevos, evitando la carrera inicial en la que un cliente podía conservar `ACCESS_DENIED` aun después de ser autorizado.
- La secuencia del host instala o repara servicio/adaptador antes de usar el controlador, fija primero su IP `10.77.37.1` y luego inicia el autorizador.
- 0.5.24 añade un disparador por ticks para `-NetworkOnly`: en este entorno `ClientLifecycleEvents.CLIENT_STARTED` no se entregó aunque el Bridge cargó. El fallback evita depender de ese único evento.
- 0.5.25 publica GeckoLib 5.5.2, preserva mods adicionales únicos del host y bloquea eliminaciones silenciosas en publicaciones futuras.
- 0.5.26 mueve el chequeo temprano `-NetworkOnly` al entrypoint principal de Fabric, conserva callbacks cliente como verificación/reintento cada diez segundos, escribe `bridge-<PID>.log` y deja oculta la consola PowerShell posterior al consentimiento UAC.
- 0.5.27 carga `CocoNetwork.ps1` como texto y `ScriptBlock` dentro del engine en memoria. Corrige el primer ensayo real, donde Windows del amigo mantenía la política predeterminada `Restricted` y bloqueó el dot-source del archivo secundario. No cambia ni debilita la ExecutionPolicy del computador. El Publisher ejecuta una regresión en un proceso real con `-ExecutionPolicy Restricted`.
- 0.5.28 elimina la necesidad de “Ejecutar como administrador” manualmente: el helper del UAC espera `OK` e IP, mientras los chequeos posteriores reconocen una instalación sana por servicio/registro y por el adaptador/IP administrada sin leer la CLI protegida. También hace que `-NetworkOnly` reutilice manifiesto/engine verificados en caché, evitando bloqueos de descarga cuando el EXE nace desde Java. Una regresión simula un cliente estándar con `10.77.37.133/24` y ejecuta dinámicamente el bootstrapper contra caché y una URL deliberadamente inválida.

Pasaron las pruebas de sintaxis, recuperación transaccional, autorización sintética y ejecución end-to-end de red. El host quedó actualizado antes de exponer el release.

### Publicación

Con Minecraft completamente cerrado:

1. Dejar en `mods` exactamente los JAR deseados; mover cuarentenas fuera de esa carpeta.
2. Ejecutar `C:\Users\smol\Desktop\random\CocoMinecraftUpdater\dist\CocoPublisher.exe`.
3. El Publisher incrementa el último número, compila Bridge/Gate/engine/bootstrapper/Publisher, valida manifiesto y hashes, prueba recuperación, crea un release borrador, actualiza el host y solo entonces publica.
4. No publicar durante una LAN: Gate del servidor vivo y clientes podrían quedar temporalmente en versiones distintas. El Publisher contiene un bloqueo para Minecraft abierto.
5. Verificar Git limpio, commit sincronizado y release público después del éxito.

Los amigos que ya instalaron correctamente no necesitan recibir otro EXE: bootstrapper y engine se autoactualizan. Solo reenviar el EXE a quienes nunca completaron la instalación o conservan una copia demasiado antigua/rota.

### Logs y soporte

- Updater: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`
- Session Bridge: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs\bridge-<PID>.log`
- Minecraft: `%APPDATA%\.minecraft\logs\latest.log`
- Crash reports: `%APPDATA%\.minecraft\crash-reports`
- DH SQLite por dimensión: `saves\coco\dimensions\minecraft\<dimension>\data\DistantHorizons.sqlite`
- Estado instalado: `config\coco-updater-state.json`
- Destino persistido: `%LOCALAPPDATA%\CocoMinecraftUpdater\target.json`

## Incidencias anteriores útiles, ya resueltas o acotadas

- SmartScreen mostró “Windows protegió su PC” porque el EXE no está firmado. Workaround actual: “Más información” y “Ejecutar de todas formas”. Solución definitiva: firma de código con reputación.
- Algunos Windows no podían cargar `Expand-Archive`. El bootstrapper agregó extracción primaria con `.NET ZipFile`, luego `tar.exe`, PowerShell y finalmente Shell COM.
- Un error de bootstrap indicaba que no podía cargar el engine. Se añadieron diagnósticos en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs` y recuperación de extracción.
- El updater mostraba ventanas separadas y errores de fuente/recorte. Se unificó la interfaz morada; el trabajo visual mínimo total es 7 segundos, no 7 segundos adicionales después del trabajo real.
- Publisher mostró “No se pudo publicar” incluso junto a una URL publicada por advertencias/salida de Git. Se corrigió la detección de éxito.
- El Publisher ejecutó antiguamente una prueba visual en el host. Desde 0.5.22 `-Silent` es realmente silencioso.
- Cambiar nombre offline causó pérdida aparente de inventario; se resolvió con una regla UUID Fixer para `nadicon`.
- El error DH `Message can't be created if no world is loaded` apareció durante cierre; no tratarlo automáticamente como causa del lag en juego.

## Comandos operativos frecuentes

- Limpiar ítems del suelo en todas partes: `/kill @e[type=item]` (destructivo; elimina todos los objetos tirados cargados).
- Activar whitelist vanilla: `/whitelist on`, luego `/whitelist add <nombre>`. Verificar interacción con MCWiFiPnP; actualmente `enforce-whitelist=false`.
- Porcentaje para dormir en versiones modernas: `/gamerule playersSleepingPercentage <0-100>`. La forma `playersSleepingPercentage 0%` es inválida; no usar `%`.
- Guardado previo a cerrar: `/save-all`; pedir que los invitados salgan primero y dejar que DH termine escrituras antes de salir.
- Perfil ticks: `/debug start` y `/debug stop`.

## Reglas de trabajo para agentes futuros

- No borrar mundos, `playerdata`, bases DH ni configuraciones sin autorización y respaldo específico.
- No mover o eliminar mods fuera de la solicitud. La carpeta `mods problematicos` es la cuarentena elegida por el usuario.
- No publicar mientras Minecraft/LAN esté abierto.
- Antes de afirmar RAM, revisar la línea de comandos y `VM.flags`; la interfaz del launcher no es suficiente.
- Distinguir FPS del host, TPS del servidor integrado y latencia/cola de red de invitados.
- Ante lag, recolectar evidencia antes de reiniciar si el usuario puede esperar unos segundos.
- No atribuir un problema a Just Hammers, DH, e4mc o C2ME sin una reproducción o perfil que lo respalde.
- Al tocar Coco Updater: ejecutar al menos sintaxis PowerShell, `tests\Test-CocoRelease.ps1` cuando exista release nuevo y `tests\Test-CocoEngineRecovery.ps1`; confirmar que una prueba silenciosa no abra UI.
- Mantener `README.md`, `docs\OPERACION.md`, `docs\GITHUB_SETUP.md` y este archivo coherentes.

## Diagnostico de red del 14-07-2026 (18:03-18:16)

- La sesion estaba en e4mc 6.2.0 modern, relay `cl`, Ethernet 1 Gbps y Minecraft con `-Xmx6714M`.
- No hubo `Can't keep up`, pausas GC relevantes ni errores/descartes en el adaptador Ethernet. El host siguio fluido.
- Varios clientes remotos perdieron conexion y luego fallaron nuevos intentos de login en streams QUIC distintos (`streamId=57,69,73,81`). El log contiene `ClosedChannelException`, `connection lost`, timeouts y `handleDisconnection() called twice`.
- Reiniciar la LAN creo una sesion e4mc nueva y los clientes volvieron a entrar. La evidencia apunta a degradacion de la sesion/ruta e4mc QUIC compartida, no a TPS del servidor ni a un mundo/chunk corrupto.
- El error de cliente `DecoderException: DataFormatException: incorrect header check` coincide con un problema abierto de descompresion en e4mc (#283). Tambien existen reportes abiertos contemporaneos de timeout/ping remoto (#281 y #286).
- Los timeouts de Packet Fixer ya estaban en 30 segundos durante el incidente: ayudan a retirar conexiones muertas antes, pero no previenen la degradacion.
- DH tenia `playerBandwidthLimit=1000`, `globalBandwidthLimit=0`, `generationRequestRateLimit=32`, `syncOnLoadRateLimit=16` y `realTimeUpdateDistanceRadiusInChunks=64`. Son candidatos para limitar rafagas de red sin cambiar mecanicas, pero no se ha demostrado que DH originara este incidente.
- Mitigacion mas fuerte sin cambiar jugabilidad: usar una VPN mesh/LAN virtual y conectar a la IP virtual del host con puerto LAN fijo, dejando e4mc como respaldo. Esto elimina el relay y la sesion QUIC de e4mc del camino.

## Automatizacion ZeroTier preparada el 14-07-2026

- La implementacion y sus correcciones estan publicadas en 0.5.28. El primer ensayo real terminó correctamente: CocoUpdater instaló ZeroTier, el host autorizó el nodo `bc70a91be7`, recibió `10.77.37.133/24`, la ruta fue `DIRECT`, el ping estabilizado quedó en 32–40 ms con 0 % de pérdida y el amigo entró/jugó mediante `Coco Minecraft`. Durante el ensayo 0.5.27 fue necesario ejecutar el EXE elevado una vez porque el proceso normal no podía leer la CLI protegida; Bridge abrió después una reparación innecesaria por la misma causa. 0.5.28 corrige ambos comportamientos.
- ZeroTier One 1.16.2 esta instalado en el host; servicio automatico, nodo `58997fc5f3`.
- Se abandono la red de Central `154a350c866b8062` en el host. La red activa es autocontrolada y privada: `Coco Minecraft`, Network ID `58997fc5f3c0c001`, subred `10.77.37.0/24`, host `10.77.37.1/24`.
- El controlador local evita limites de dispositivos y elimina la necesidad de un token de Central. El autorizador acepta automaticamente los Node ID pendientes mientras Minecraft del host esta abierto.
- CocoUpdater instala/repara ZeroTier con un UAC, valida URL oficial versionada, SHA-256 y firma Authenticode, une la red, ajusta el perfil y espera `OK PRIVATE`. Una instalacion sana no vuelve a elevarse.
- Host: perfil `Private` y regla `Coco Minecraft - ZeroTier TCP 25565`, limitada a TCP 25565, interfaz ZeroTier y origen `10.77.37.0/24`. Clientes: perfil `Public`.
- `saves\coco\mcwifipnp.json` usa puerto fijo `25565` y `enable-upnp=false`. Session Bridge crea `Coco Minecraft` en `servers.dat` con `10.77.37.1:25565`.
- Seguridad deliberada: conocer el Network ID basta para ser autorizado durante la ventana activa. La exposicion queda limitada por Firewall a Minecraft; sigue siendo necesario activar/verificar whitelist por la suplantacion de nombres offline.
- e4mc no fue retirado. Durante la prueba A/B detener su tunel para no mezclar rutas y conservarlo como respaldo.
- Falta ampliar la prueba a sesiones largas, reconexiones y más amigos. Con el primer amigo se midió `DIRECT`, 32–40 ms estabilizados y 0 % de pérdida; no generalizar ese resultado a otros ISP/equipos antes de medirlos.
- Prueba aislada previa a 0.5.23: un segundo nodo ZeroTier 1.16.2 con identidad nueva se unio desde WSL, fue autorizado sin intervencion y recibio automaticamente `10.77.37.11/24` en 10,9 s. Hubo 0 % de perdida, TCP 25565 respondio y el peer fue `DIRECT`. Esta prueba valida controlador, autorizador, asignacion IP, Firewall y transporte; su latencia local no representa la de Chile/Argentina ni sustituye la prueba del MSI/UAC en otro Windows.

### Incidente Ethernet durante la preparacion del primer test

- A las 22:23 el Realtek fisico perdio su concesion DHCP y quedo con una direccion APIPA aunque conservaba enlace de 1 Gbps. Reiniciar Windows restauro DHCP `192.168.1.86`, acceso al router en menos de 1 ms e Internet con 0 % de perdida.
- ZeroTier se habia instalado correctamente a las 20:23 y creo su adaptador a las 20:38; CocoUpdater termino su ultimo chequeo a las 22:18:56. No hubo instalacion ni reparacion de ZeroTier en el momento de la perdida.
- Windows registro dos cambios de fuente de energia a las 22:23:10-14 y Ethernet paso a red no identificada a las 22:23:42. El controlador Realtek es `1168.11.1206.2022`; `Power Saving Mode`, Green Ethernet, EEE y Advanced EEE ya estaban desactivados. Esto hace plausible un estado transitorio del controlador/pila de red, pero no demuestra la causa exacta.
- CocoUpdater selecciona el adaptador exclusivamente por descripcion ZeroTier y MAC/Network ID; no ejecuta cambios sobre Realtek. ZeroTier tampoco instala un filtro sobre el adaptador fisico. No atribuir el incidente a ZeroTier ni descartarlo definitivamente sin una reproduccion.
- Durante el diagnostico un reinicio administrativo incompleto dejo Ethernet deshabilitado temporalmente; se rehabilito y se devolvio a DHCP antes del reinicio. No confundir ese efecto posterior con la perdida original.
- Wi-Fi quedo administrativamente deshabilitado por peticion del usuario. La ruta activa es solo Ethernet; ZeroTier esta `ONLINE`, red `OK PRIVATE`, IP `10.77.37.1/24`.
