# Operación

## Roles y ubicaciones

- Host: instalación que contiene `config\coco-host.json`; recibe los componentes exclusivos de servidor LAN.
- Cliente: instalación sin ese marcador; recibe el conjunto exacto de mods publicado para conexión.
- EXE canónico: `%LOCALAPPDATA%\CocoMinecraftUpdater\CocoUpdater.exe`.
- Estado: `%APPDATA%\.minecraft\config\coco-updater-state.json`.
- Destino detectado: `%LOCALAPPDATA%\CocoMinecraftUpdater\target.json`.

`config\coco-host.json` nunca se distribuye.

## Primera instalación

1. Mantener Minecraft del host abierto para que el autorizador ZeroTier esté disponible.
2. En el equipo cliente, abrir la instancia Fabric 26.1.2 correcta hasta el menú.
3. Ejecutar el `CocoUpdater.exe` del release estable.
4. Aceptar SmartScreen/UAC si Windows lo solicita.
5. El updater detecta `--gameDir`, instala o repara ZeroTier, espera autorización, sincroniza mods e instala Bridge/Gate.
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

Bridge ejecuta `-NetworkOnly` al arrancar y consulta dentro de Minecraft únicamente el número de versión pública al iniciar login. Si coincide, no lanza el updater completo; si difiere o la consulta falla, inicia el flujo visual y reintentable. Red y actualización usan archivos de sesión separados para que un resultado de red no pueda borrar una orden de cierre. El chequeo completo informa además la versión cargada en la JVM; al abrir el EXE manualmente, el engine compara el inicio del proceso con `installedAt`. Si el disco ya contiene el release nuevo pero Minecraft sigue ejecutando el Bridge anterior, cierra solo ese cliente y pide reabrir sin reinstalar. El engine considera visible cualquier chequeo completo asociado a un PID de Minecraft, aunque el Bridge antiguo no envíe `ShowOnUpdate`; `NetworkOnly` sigue siendo una comprobación separada de red. El chequeo se reintenta hasta tres veces si el proceso no llega a producir estado. Una instalación realmente actualizada no abre el updater de mods ni mantiene un monitor periódico. Cuando hubo trabajo visible, el final correcto se reconoce por `TODO LISTO`, color verde y el botón `ACEPTAR`; la ventana no se cierra por tiempo, Enter equivale a pulsar el botón y no aparece texto superpuesto ni un cuadro booleano posterior.

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
- rechaza en la fuente viva y en el manifiesto cualquier ID de `policy\blocked-mod-ids.txt`; `tsa-decorations` está retirado permanentemente;
- verifica tamaños, SHA-256 y assets;
- prueba recuperación transaccional;
- instala el bootstrap compilado directamente en el host antes de ejecutar el engine, porque los assets de un release borrador todavía no son descargables de forma anónima;
- mantiene el release como borrador hasta actualizar correctamente el host.

## ZeroTier

- Red: `Coco Minecraft` (`58997fc5f3c0c001`).
- Subred: `10.77.37.0/24`.
- Endpoint: `10.77.37.1:25565`.
- Controlador local asociado al nodo `58997fc5f3`.
- El host autoriza nodos pendientes mientras Minecraft está abierto.
- El firewall permite únicamente TCP 25565 desde la subred ZeroTier por la interfaz virtual.
- Los clientes usan perfil Public; el host usa Private.

El helper elevado valida el MSI oficial y espera estado `OK` e IP. Las comprobaciones posteriores no necesitan leer la CLI administrativa. `-NetworkOnly` reutiliza engine/manifiesto verificados en caché para iniciar rápidamente desde Bridge.

No borrar `C:\ProgramData\ZeroTier\One\identity.secret`: la identidad del controlador determina el Network ID.

### Respaldo e4mc

e4mc permanece instalado solo en el host. En operación ZeroTier se detiene con `/e4mc stop` después de abrir la LAN. Como contingencia, mantenerlo activo y usar el dominio temporal mostrado por Minecraft.

## Seguridad

- No publicar tokens ZeroTier, credenciales GitHub ni secretos del controlador.
- La autorización automática está limitada a la ventana en que Minecraft del host está activo.
- Conocer el Network ID permite solicitar incorporación; firewall y whitelist siguen siendo controles independientes.
- `online-mode=false` permite perfiles offline y, por tanto, suplantación de nombres si no existe whitelist.
- SmartScreen puede advertir porque el EXE aún no posee una firma de código con reputación.

## Recuperación y diagnóstico

Si Windows se interrumpe durante el reemplazo de `mods`, el siguiente inicio restaura la transacción pendiente antes de continuar. Las descargas se verifican por SHA-256 y se reintentan. La autoactualización del EXE canónico es secundaria: si otra instancia lo mantiene bloqueado, se deja un reemplazo verificado pendiente durante hasta 12 horas y el engine continúa; esa condición no debe presentarse como fallo de mods o de conexión.

Logs:

- Updater: `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`.
- Bridge: `bridge-<PID>.log` dentro de la misma carpeta.
- Auto-reemplazo del EXE: `bootstrap-update.log` dentro de la misma carpeta.
- Minecraft: `%APPDATA%\.minecraft\logs\latest.log`.
- Crash reports: `%APPDATA%\.minecraft\crash-reports`.

Ante un problema de conexión, registrar hora y comprobar:

1. `zerotier-cli status`, `listnetworks` y `listpeers`.
2. IP administrada y ruta `DIRECT/RELAY`.
3. Ping, pérdida y acceso TCP 25565.
4. Conexiones establecidas en el host.
5. `latest.log` para separar rechazo de versión, timeout, TPS y errores de mods.

Ante lag grave, recolectar evidencia antes de reiniciar: heap, thread dump, log y, si está activa, captura JFR.
