# Operación

> Estado observado el 2026-07-26: release público, host, caché, EXE y manifiesto 0.5.62. Todas las experiencias administradas presentes en el catálogo son visibles: DREAD, Backrooms, Zombie 1.12.2 y COBBLEVERSE 1.7.42-CF. Ya no existen estados de bloqueo/experimento que filtren el selector. Cobbleverse completó instalación y arranque físico hasta el menú con DH+Iris; aún faltan mundo, LAN y clientes. Evidencia: [`CocoLauncherImplementation.md`](CocoLauncherImplementation.md) y auditorías bajo `docs`.

En Zombie, abrir el mundo, elegir **Abrir en LAN**, conservar el puerto `25565` y cambiar **Online Mode** a **OFF** antes de iniciar. El JAR `lanserverproperties-1.0.jar` se instala únicamente en el rol host y Coco no mezcla con esta experiencia la configuración de MCWiFiPnP de versiones modernas.

Para DREAD, los amigos conectan por **Conexión directa** a `10.77.37.1:25565`; no se usa la IP pública. La IP ZeroTier por sí sola no significa que exista una partida: el host debe entrar al mundo, pulsar **Abrir en LAN**, esperar `PARTIDA ONLINE` y comprobar que TCP 25565 esté escuchando. El 2026-07-26 se observó ZeroTier sano en `10.77.37.1`, pero sin Java/Minecraft ni listener 25565 durante la consulta; no se registró ese instante como fallo del pack.

## Roles y ubicaciones

- Host: instalación que contiene `config\coco-host.json`; recibe los componentes exclusivos de servidor LAN.
- Cliente: instalación sin ese marcador; recibe el conjunto exacto de mods publicado para conexión.
- EXE canónico: `%LOCALAPPDATA%\CocoMinecraftUpdater\CocoUpdater.exe`.
- Estado: `%APPDATA%\.minecraft\config\coco-updater-state.json`.
- Destino detectado: `%LOCALAPPDATA%\CocoMinecraftUpdater\target.json`.
- Instancias administradas: `%APPDATA%\CocoMinecraft\experiences\<instanceId>`.

Into The Backrooms usa la instancia persistente `%APPDATA%\CocoMinecraft\experiences\into-the-backrooms`, que contiene el mundo del primer test. No crear una copia paralela bajo `%TEMP%`.

COBBLEVERSE usa `%APPDATA%\CocoMinecraft\experiences\cobbleverse`. No trae mapa ni `save`: crear un mundo nuevo con las opciones normales y semilla vacía produce una semilla aleatoria; Terralith, incluido por el manifiesto upstream aunque figure como opcional, modifica la generación. DH se instala en ambos roles y MCWiFiPnP 1.9.0 sólo en el host.

`config\coco-host.json` nunca se distribuye.

## Primera instalación

1. Mantener Minecraft del host abierto para que el autorizador ZeroTier esté disponible.
2. En el equipo cliente, abrir la instancia Fabric 26.1.2 correcta hasta el menú.
3. Ejecutar el `CocoUpdater.exe` del release estable.
4. Aceptar SmartScreen/UAC si Windows lo solicita.
5. El updater valida que el proceso sea Fabric 26.1.2, detecta `--gameDir`, corrige la integración incompatible de TLSkinCape en TLauncher, instala o repara ZeroTier, espera autorización, sincroniza mods e instala Bridge/Gate.
6. Reabrir Minecraft y usar la entrada `Coco Minecraft`.

No instalar ZeroTier manualmente ni usar “Ejecutar como administrador” como procedimiento normal. Una instalación sana se reconoce por servicio, registro, adaptador e IP administrada y no vuelve a elevarse.

## Sesión normal

Host:

1. Abrir Minecraft.
2. Entrar al mundo y seleccionar **Start LAN**.
3. Confirmar el puerto 25565.
4. Ejecutar `/e4mc stop` para mantener únicamente la ruta ZeroTier.
5. Cerrar Minecraft normalmente al terminar.

Cliente:

1. Abrir Minecraft.
2. Seleccionar `Coco Minecraft` en Multijugador.
3. Si Gate detecta una versión anterior, dejar que el updater cierre el cliente, actualice y solicite reabrir.

Bridge ejecuta `-NetworkOnly` al arrancar y consulta dentro de Minecraft únicamente el número de versión pública al iniciar login. El proceso Java conserva la entrada del EXE como pipe y cierra inmediatamente el extremo de escritura del padre: `ps2exe` recibe EOF y comienza el script sin esperar que Minecraft termine. No se debe usar `ProcessBuilder.Redirect.DISCARD` como entrada, porque es un destino de escritura y Java 25 lo rechaza. Si la versión coincide, no lanza el updater completo; si difiere o la consulta falla, inicia el flujo visual y reintentable. Red y actualización usan archivos de sesión y mutex distintos: una comprobación silenciosa de red ya iniciada no puede bloquear la reina ni el cierre del cliente. El flujo completo comprueba primero los archivos locales; ante cualquier pack cliente atrasado muestra la reina, pide el cierre normal y fuerza únicamente ese PID tras ocho segundos si no responde. Después espera de forma visible cualquier operación de red anterior —incluidos engines hasta 0.5.39 que usaban el mutex único— y continúa con ZeroTier, descargas e instalación. Un autorizador persistente sano y ligado al mismo PID se reutiliza en vez de borrar su heartbeat o competir por el mutex. El chequeo completo informa además la versión cargada en la JVM; al abrir el EXE manualmente, el engine compara el inicio del proceso con `installedAt`. Si el disco ya contiene el release nuevo pero Minecraft sigue ejecutando el Bridge anterior, cierra solo ese cliente y pide reabrir sin reinstalar. El engine considera visible cualquier chequeo completo asociado a un PID de Minecraft, aunque el Bridge antiguo no envíe `ShowOnUpdate`. El chequeo se reintenta hasta tres veces si el proceso no llega a producir estado. Una instalación realmente actualizada no abre el updater de mods ni mantiene un monitor periódico. Cuando hubo trabajo visible, el final correcto se reconoce por `TODO LISTO`, color verde y el botón `ACEPTAR`; la ventana no se cierra por tiempo, Enter equivale a pulsar el botón y no aparece texto superpuesto ni un cuadro booleano posterior.

En ejecución manual sin `-GameDir`, solo un proceso Minecraft que anuncie Fabric y la versión publicada recibe prioridad. Ese proceso compatible vence al destino persistido aunque una instalación anterior ya tenga marcador Coco. Si está abierta una versión distinta, el updater se detiene con instrucciones para abrir Fabric 26.1.2; si hay dos instancias compatibles, solicita dejar solo una abierta. En carpetas TLauncher Fabric 26.1.2, pone en `false` los campos `skinVersion` y `activateSkinCapeForUserVersion` presentes en `TLauncherAdditional.json` o en el JSON de versión, porque TLSkinCape es incompatible con EntityCulling/TRenderer/Transition. No retirar EntityCulling como solución.

`NetworkOnly` también sincroniza el registro de skins sin alterar mods ni bloquear la red si el servicio no está disponible. En el host de Coco original inicia `CocoSessionService.ps1` ligado al PID de Minecraft; en clientes sube la selección pendiente y descarga hashes nuevos. El registro vive en `%LOCALAPPDATA%\CocoMinecraftUpdater\launcher\skins\profiles` y se copia a `<gameDir>\CustomSkinLoader\LocalSkin\skins`. Revisar `logs\launcher-session-service.log` y el log `updater-*` para diagnosticar rechazos `OWNER`, PNG o conexión.

En toda experiencia administrada, Coco inspecciona la metadata interna de los JAR. Si encuentra `voicechat`, repara antes del arranque `config\voicechat\voicechat-client.properties`: onboarding terminado, entrada/salida default, VOICE, AGC, denoiser, nativos activos y micrófono sin mute. En el servidor integrado Simple Voice Chat cambia dinámicamente su UDP al puerto publicado por Abrir en LAN; con el puerto Coco fijo esto es 25565. El host debe tener `Coco Voice LAN - ZeroTier UDP 25565`, restringida a Private y `10.77.37.0/24`; `Ensure-CocoNetwork` eleva y la repara junto con las reglas TCP. Verificar `Get-NetFirewallRule`/`Get-NetFirewallPortFilter` y probar voz real desde dos equipos.

Las migraciones de preferencias declaradas por un release se ejecutan solo durante esa actualización, con Minecraft cerrado, y sus IDs quedan registrados en `coco-updater-state.json`. `pingwheel-location-z-v1` reemplaza Mouse 5 por Z solo si sigue en el valor predeterminado, o agrega Z si la entrada aún no existe. Si el jugador ya eligió otra tecla, se conserva; una vez registrada, publicaciones posteriores tampoco vuelven a tocarla.

`managed-config\Stackable.json` y `managed-config\jei\jei-client.ini` son las fuentes publicadas de `config\Stackable.json` y `config\jei\jei-client.ini`. El Publisher las incorpora al manifiesto con tamaño, SHA-256 y contenido; el updater las verifica y aplica a ambos roles durante cada actualización. Stackable fija `maxStack` en 256 y JEI fija `showHiddenIngredients = true` para mostrar objetos que no llegan a su lista desde pestañas creativas defectuosas. Cambiar cualquiera de estos valores es una decisión global del pack.

## Publicar una actualización

1. Cerrar Minecraft y confirmar que la LAN terminó.
2. Dejar en `%APPDATA%\.minecraft\mods` el conjunto deseado.
3. Ejecutar `dist\CocoPublisher.exe`.
4. No abrir Minecraft hasta recibir confirmación de éxito.
5. Verificar release público, `release\latest.json`, estado host y Git sincronizado.

El Publisher:

- incrementa el componente final de versión;
- separa roles host/cliente;
- deduplica contenido e IDs Fabric;
- conserva en el host JAR adicionales con IDs nuevos;
- toma `%APPDATA%\.minecraft\mods` como fuente autoritativa: los JAR agregados o retirados se reflejan directamente en el release;
- rechaza versiones que no sean exactamente la siguiente al canal estable o si `HEAD` no coincide con `origin/main`;
- rechaza en la fuente viva y en el manifiesto cualquier ID de `policy\blocked-mod-ids.txt`; `tsa-decorations` e `inventoryextended` están retirados;
- verifica tamaños, SHA-256 y assets;
- prueba recuperación transaccional;
- para releases launcher valida catálogo y locks, backend fijado, reintentos, drenaje de pipes, serialización ZeroTier y lifecycles host/cliente;
- el importador de experiencias conserva dependencias requeridas y opcionales; Essential es la única exclusión global;
- instala el bootstrap compilado directamente en el host antes de ejecutar el engine, porque los assets de un release borrador todavía no son descargables de forma anónima;
- hidrata en `%LOCALAPPDATA%\CocoMinecraftUpdater` el manifiesto, ZIP y engine extraído verificados del mismo release para que el siguiente `NetworkOnly` no use una versión anterior;
- archiva helpers y respaldos bootstrap obsoletos bajo `backups\publisher-stale-artifacts-<versión>` después de verificar el EXE canónico;
- mantiene el release como borrador hasta actualizar correctamente el host.

`inventoryextended` está prohibido desde 0.5.42: duplicaba el inventario principal y fue retirado por decisión operativa. El respaldo previo del JAR y los datos `saves\coco\players\data` está en `%LOCALAPPDATA%\CocoMinecraftUpdater\backups\20260719-inventoryextended-removal`; usarlo si un objeto de las filas extra queda inaccesible.

## ZeroTier

- Ruta normal: ZeroTier `10.77.37.1:25565`, red `58997fc5f3c0c001`.
- **Autoaceptación permanente**: el host instala la tarea `Coco ZeroTier AutoAccept` (SYSTEM, cada minuto) que ejecuta `C:\ProgramData\CocoMinecraftUpdater\network\CocoNetworkAuthorizer.ps1 -Once`. Cualquier amigo que se una a la red queda admitido solo, sin abrir el launcher ni Minecraft; el autorizador en vivo (mientras el host juega) acepta al instante y repite la configuración de red para entregar IP de inmediato. El Network ID viaja en `latest.json`, así que con esta política tener el launcher equivale a pertenecer; firewall sigue limitando la exposición a TCP/UDP 25565 y TCP 25564 desde `10.77.37.0/24`.
- MCWiFiPnP moderno debe producir exactamente `OnlineMode=false`, `EnableUUIDFixer=true`, `UseUPnP=false` y puerto 25565. Los nombres kebab-case son inválidos.
- Un adaptador alternativo necesita rol host, hash, versión compatible y prueba real; no inventes configuraciones.
- No anuncies `ready` hasta validar configuración LAN y listener TCP 25565.
- El instalador puede administrar pack/config, pero nunca debe administrar una partida viva bajo `saves`.
- Diagnóstico de autoaceptación: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs\zerotier-authorizer.log` (sesión de usuario) y el historial de la tarea `Coco ZeroTier AutoAccept`; quitar la tarea elimina la admisión automática.
- Red: `Coco Minecraft` (`58997fc5f3c0c001`).
- Subred: `10.77.37.0/24`.
- Endpoint: `10.77.37.1:25565`.
- Controlador local asociado al nodo `58997fc5f3`.
- El host acepta nodos pendientes en todo momento: tarea SYSTEM cada minuto más el autorizador vivo durante la partida.
- El firewall permite únicamente TCP 25565 desde la subred ZeroTier por la interfaz virtual.
- Los clientes usan perfil Public; el host usa Private.

El helper elevado valida el MSI oficial y espera estado `OK` e IP. Permanece oculto, pero escribe un estado lateral que la reina consume mientras el proceso sigue activo; instalación, servicio, adaptador, perfil y la cuenta regresiva de autorización permanecen visibles. Las comprobaciones posteriores no necesitan leer la CLI administrativa. `-NetworkOnly` reutiliza engine/manifiesto verificados en caché para iniciar rápidamente desde Bridge.

No borrar `C:\ProgramData\ZeroTier\One\identity.secret`: la identidad del controlador determina el Network ID.

### Respaldo e4mc

e4mc permanece instalado solo en el host. En operación ZeroTier se detiene con `/e4mc stop` después de abrir la LAN. Como contingencia, mantenerlo activo y usar el dominio temporal mostrado por Minecraft.

## Seguridad

- No publicar tokens ZeroTier, credenciales GitHub ni secretos del controlador.
- La autoaceptación es permanente (tarea `Coco ZeroTier AutoAccept`): pertenecer a la red no requiere aprobación manual; revocar a alguien exige expulsarlo y desactivar la tarea.
- Conocer el Network ID permite solicitar incorporación; firewall y whitelist siguen siendo controles independientes.
- `online-mode=false` permite perfiles offline y, por tanto, suplantación de nombres si no existe whitelist.
- SmartScreen puede advertir porque el EXE aún no posee una firma de código con reputación.

## Defender Control (ventana online-fix)

Los juegos standalone con parche online-fix son eliminados por Windows Defender al momento, así que Coco alterna la protección en tiempo real durante cada sesión con [Defender Control v2.0](https://github.com/pgkt04/defender-control) (MIT), binarios fijados por SHA-256 en `engine\CocoDefenderControl.ps1`.

Automático en todas las sesiones:

- Al abrir Coco Launcher: crea `%LOCALAPPDATA%\CocoMinecraftUpdater\tools\defender-control`, agrega esa carpeta como exclusión de Defender (antes de descargar, para que las herramientas no sean eliminadas), descarga y verifica los binarios y desactiva la protección.
- Al cerrar Coco Launcher: restaura la protección, incluso si la sesión terminó con error.
- La alternancia es silenciosa gracias a dos tareas manuales (`CocoDefenderDisable` y `CocoDefenderEnable`) creadas una sola vez; en sesiones ya elevadas se ejecuta directo.

Los únicos pasos que Windows exige una vez por equipo —ningún programa puede evitarlos—:

1. **Un clic en el aviso de permisos (UAC) la primera vez**: tocar Defender requiere administrador. No hace falta click derecho ni «ejecutar como administrador»; Coco pide el permiso él solo cuando lo necesita.
2. **«Protección contra alteraciones»: No**: Windows bloquea por diseño ese interruptor frente a cualquier software. Si está activo, la desactivación no surte efecto; Coco lo detecta y muestra una ventana única con el paso exacto y un botón que abre Seguridad de Windows. Tras hacerlo una vez, todo queda automático para siempre.

Recuperación manual (por ejemplo, un corte de luz mató a Coco sin restaurar): `schtasks /Run /TN CocoDefenderEnable` o ejecutar `enable-defender.exe` del directorio como administrador. Diagnóstico: entradas `DEFENDER` en los logs del updater.

La ventana de créditos de online-fix se cierra sola en cada máquina gracias al vigilante `POPUPGATE` (árbol completo de procesos del juego, pulsación del botón real, activa durante toda la partida). Si algún juego mostrara una variante no reconocida, los logs registran sus candidatos (`cls`, `titulo`, `botones`) con prefijo `POPUPGATE candidatos no atendidos`; con esa evidencia se amplían las etiquetas en `CocoPopupGateDefaults` o en `preferences.popupGate` de esa experiencia.

## Recuperación y diagnóstico

Si Windows se interrumpe durante el reemplazo de `mods`, el siguiente inicio restaura la transacción pendiente antes de continuar. Las descargas se verifican por SHA-256 y se reintentan. La autoactualización del EXE canónico es secundaria: si otra instancia lo mantiene bloqueado, se deja un reemplazo verificado pendiente durante hasta 12 horas y el engine continúa; esa condición no debe presentarse como fallo de mods o de conexión.

Logs:

- Updater: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`.
- Bridge: `bridge-<PID>.log` dentro de la misma carpeta.
- Auto-reemplazo del EXE: `bootstrap-update.log` dentro de la misma carpeta.
- Fallos visibles: `CocoUpdater-error-<fecha>.txt` en el Escritorio, tanto para bootstrap como para engine.
- Minecraft: `%APPDATA%\.minecraft\logs\latest.log`.
- Crash reports: `%APPDATA%\.minecraft\crash-reports`.

Ante un problema de conexión, registrar hora y comprobar:

1. `zerotier-cli status`, `listnetworks` y `listpeers`.
2. IP administrada y ruta `DIRECT/RELAY`.
3. Ping, pérdida y acceso TCP 25565.
4. Conexiones establecidas en el host.
5. `latest.log` para separar rechazo de versión, timeout, TPS y errores de mods.

Ante lag grave, recolectar evidencia antes de reiniciar: heap, thread dump, log y, si está activa, captura JFR.
