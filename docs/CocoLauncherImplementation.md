# Coco Launcher — implementación y estado

Última revisión: 2026-07-26 (America/Santiago).

Este documento es la fuente canónica del launcher multi-instancia. La auditoría detallada y la evidencia del primer test real están en [CocoLauncherAudit-2026-07-25.md](CocoLauncherAudit-2026-07-25.md).

## Producto actual

El mismo `CocoUpdater.exe` cumple dos funciones:

- Si existe una experiencia administrada activa, prepara su instancia aislada, elige automáticamente esa única partida y abre Minecraft conectado a `10.77.37.1:25565`.
- Si no existe una partida administrada, actualiza Coco original. Coco original sigue abriéndose con el launcher oficial o TLauncher; Bridge conserva la comprobación dentro del juego.

Los amigos nunca eligen un pack. Sólo el host ve el selector de experiencias.

## Identidad

Coco Launcher usa exclusivamente una **identidad local/offline estable**. No ofrece login Microsoft ni copia sesiones, tokens o contraseñas.

Orden de resolución:

1. Reutilizar `identity.json` si ya contiene un nombre local válido.
2. Migrar silenciosamente a local el nombre válido de un estado Microsoft creado por versiones anteriores.
3. Reutilizar un único nombre válido seleccionado en TLauncher o en metadatos locales seguros.
4. Si no existe un nombre inequívoco, dejar vacío el campo permanente de la tarjeta `TU IDENTIDAD COCO`.

El nombre tiene 3–16 letras, números o guion bajo. Determina la identidad de inventario, avances y permisos, por lo que no debe cambiarse después de jugar.

La identidad no bloquea la red, la descarga, la verificación ni la instalación. Nombre y skin forman una única tarjeta permanente: la cabeza queda a la izquierda, el nombre es un campo siempre visible al centro y la acción de skin queda a la derecha. Un nombre válido se guarda con Enter o al salir del campo. Si todavía falta o quedó texto válido sin confirmar, Coco pausa únicamente la creación del proceso, mantiene el foco y muestra `Pulsa Enter para confirmar`; no abre otro formulario ni acepta prematuramente los primeros tres caracteres. Durante los milisegundos en que se construye el proceso cliente la tarjeta se congela y luego el launcher se oculta. En el host permanece editable durante la preparación y mientras la partida está online; los cambios de nombre posteriores al arranque se aplican en la sesión siguiente.

La red privada y el UUID Fixer preservan una identidad offline coherente, pero **no autentican el nombre**. Una persona autorizada en ZeroTier podría suplantar otro nombre. Las sesiones actuales son sólo para el grupo de confianza; antes de ampliar el acceso debe añadirse una política de whitelist/nombres reservados. La evidencia específica de Cobbleverse vive en [`CobbleverseAudit-2026-07-26.md`](CobbleverseAudit-2026-07-26.md).

## Experiencias

| Experiencia | Runtime | Estado en 0.5.61 | Evidencia |
|---|---|---|---|
| Coco original | Fabric 26.1.2 | Producción heredada | Conserva launcher y mundo actuales. |
| Into The Backrooms | Fabric 1.20.1 | Visible | El 2026-07-25 el host y dos amigos entraron y jugaron mediante Coco. |
| DREAD | Forge 1.19.2 | Visible | Lock e instalación existen; falta sesión física completa host + dos clientes. |
| Zombie Apocalypse | Forge 1.12.2 | Visible | La prueba real anterior fue confirmada por el host. Lan Server Properties 1.0 se instala solo al host: puerto 25565 y `Online Mode: OFF`. |
| COBBLEVERSE 1.7.42-CF | Fabric 1.21.1 | Visible | Instalación y arranque real hasta el menú aprobados el 2026-07-26; Cobblemon, shader del pack y DH+Iris/OpenGL cargaron. Usa heap recomendado de 5 GiB y fija DH en 32 chunks para host y clientes. Falta completar LAN/clientes. Crea un mundo aleatorio con Terralith, sin mapa ni semilla prefijados. |

La presencia en el catálogo publicado es la única regla de disponibilidad: toda entrada `managed` con workflow `coco-managed` aparece al host y puede lanzarse. Las etiquetas `blocked`, `experimental`, `normal` y `validated` fueron eliminadas del schema y del engine. Las auditorías conservan evidencia y trabajo pendiente sin alterar visibilidad.

## Flujo del amigo

1. Abre Coco.
2. Coco actualiza bootstrap/engine y muestra etapa, detalle, progreso y Run ID.
3. Verifica ZeroTier.
4. Consulta tres veces la única sesión del host.
5. Si no hay sesión, sincroniza Coco original y termina indicando que se abra con el launcher habitual.
6. Si hay sesión `preparing`, descarga y verifica el pack por adelantado.
7. Relee el nombre local después de preparar todos los archivos. Sólo pausa aquí si todavía no pudo inferirse o configurarse uno seguro.
8. Revalida que siga siendo la misma sesión y que esté `ready`.
9. Abre la instancia aislada con PortableMC y Quick Play.
10. Coco se oculta sólo cuando aparece el Java correcto, permanece supervisando y se cierra cuando Minecraft termina.

## Flujo del host

1. Abre Coco y ve únicamente experiencias no bloqueadas.
2. Elige una experiencia.
3. Coco publica `preparing`, instala/verifica el pack y abre la instancia del host sin autoingreso.
4. El host entra o crea el mundo.
5. Antes de abrir LAN, Coco escribe y valida `mcwifipnp.json`.
6. El host pulsa **Abrir en LAN**.
7. Coco sólo publica `ready` si observó previamente la configuración LAN válida y luego el puerto 25565 abierto.
8. Al cerrar Minecraft publica `stopping`, retira la sesión y vuelve al selector.

Si la LAN se abre antes de que la política esté cargada, Coco no anuncia una partida insegura: pide cerrar y reabrir la LAN.

## Política LAN exacta

MCWiFiPnP deserializa nombres de campos Java y distingue mayúsculas. El archivo por mundo debe contener, como mínimo:

```json
{
  "port": 25565,
  "OnlineMode": false,
  "EnableUUIDFixer": true,
  "UseUPnP": false
}
```

`online-mode`, `enable-uuid-fixer` y `enable-upnp` son nombres inválidos para este mod: Gson los ignora y conserva sus valores predeterminados. Las pruebas ahora rechazan explícitamente ese esquema antiguo.

Fuente oficial: [MCWiFiPnP en Modrinth](https://modrinth.com/mod/mcwifipnp) y [código fuente](https://github.com/Satxm/mcwifipnp).

## Instancias y persistencia

- Producción: `%APPDATA%\CocoMinecraft\experiences\<instanceId>`.
- Backend, cachés y logs: `%LOCALAPPDATA%\CocoMinecraftUpdater`.
- Identidad: bajo la raíz privada de Coco Launcher.
- La instancia de la primera sesión Backrooms fue consolidada en `%APPDATA%\CocoMinecraft\experiences\into-the-backrooms`; ésa es la instalación que se seguirá usando.
- No existe una copia de respaldo del mundo Backrooms ni una segunda instalación temporal.

Los locks administran mods, configs, resource packs y shaders. `saves`, `playerdata`, avances, estadísticas y bases DH no se reemplazan. Las preferencias especiales de cada experiencia viven en `catalog.template.json`, mientras que las decisiones deliberadamente universales viven en `globalPolicies`. `preferences.managedFiles` permite fijar texto completo bajo `config/` o `shaderpacks/` para todos los jugadores de una sola experiencia; los mods adicionales viven en `experiences[].files` y los retiros explícitos en `pack.excludedPaths`.

Políticas universales:

- Essential se excluye de los assets, overrides y restos generados de todas las experiencias presentes y futuras.
- Todas las demás dependencias declaradas por el manifiesto upstream se importan, incluidas las opcionales. El importador conserva `manifestRequired` para poder auditar cuáles eran opcionales; no las elimina.
- CustomSkinLoader es obligatorio. Cada versión de Minecraft debe resolver exactamente una variante compatible; un pack no bloqueado sin variante se rechaza.
- La skin exacta inicial de `smolbird` viaja dentro del engine, fijada por SHA-256.
- Esto no presupone compatibilidad futura: para una versión nueva hay que localizar una versión oficial compatible de CustomSkinLoader, declararla con URL y SHA-256 y validar el arranque. Después de esa declaración, Coco automatiza su descarga, verificación, instalación y la eliminación de variantes incompatibles.

### Skins elegidas por los jugadores

El pie permanente del launcher contiene una sola tarjeta `TU IDENTIDAD COCO` con nombre y vista previa de la cabeza. La cabeza y la zona `TU SKIN` admiten clic y arrastre: el clic abre un selector de Windows limitado a PNG y soltar un único PNG ejecuta el mismo flujo. No existen botones de alturas diferentes ni un formulario técnico separado.

Coco acepta únicamente PNG decodificables de hasta 1 MB y dimensiones exactas 64x64 o 64x32. El nombre del archivo original es irrelevante: la copia se guarda con el nombre de jugador validado. Elegir una skin no pausa red, descarga ni instalación. Si falta identidad, la propia tarjeta marca el campo y pide escribir allí un nombre válido antes de asociar la imagen.

La skin propia es completamente opcional. Si el jugador no elige ningún PNG, conserva la apariencia predeterminada de Minecraft y Coco continúa normalmente; únicamente el nombre local válido puede pausar el último instante antes de crear el proceso del juego.

Rutas locales:

- selección y estado pendiente: `%LOCALAPPDATA%\CocoMinecraftUpdater\launcher\skins\selection.json`;
- registro sincronizado: `%LOCALAPPDATA%\CocoMinecraftUpdater\launcher\skins\profiles\<jugador>.png`;
- destino en cada instalación: `<gameDir>\CustomSkinLoader\LocalSkin\skins\<jugador>.png`.

La selección se copia inmediatamente a Coco original y a todas las instancias administradas existentes. Luego intenta sincronizarse por `10.77.37.1:25564`. Si el host no está disponible, queda pendiente sin bloquear el juego y se reintenta al abrir una experiencia o cuando Bridge ejecuta `NetworkOnly` en Coco original. El host mantiene el registro únicamente mientras su Minecraft original o su sesión administrada está viva. Todos los clientes descargan el manifiesto y cualquier PNG cuyo hash haya cambiado antes de abrir Minecraft.

El protocolo `COCO-SKINS 1` comparte el servicio privado de sesiones, pero usa mensajes `MANIFEST`, `GET` y `PUT`. El listener sólo acepta la subred ZeroTier Coco. La primera subida reserva el nombre para la IP ZeroTier que la realizó; otra IP no puede sobrescribirlo y el host puede reparar una asignación. Esto evita cambios accidentales entre amigos, pero no convierte los nombres offline en autenticación fuerte.

CustomSkinLoader carga skins locales desde archivos presentes en cada cliente; no las distribuye por sí mismo. Por eso Coco replica el mismo registro en todos. Un cambio hecho mientras Minecraft ya está abierto se garantiza para el próximo arranque/reingreso, no como reemplazo visual instantáneo dentro de una JVM ya cargada.

La copia canónica vive de forma persistente en el computador host, no en GitHub ni en una nube. Por tanto, “persistente” significa que sobrevive a cierres, reinicios y nuevas experiencias mientras no se borre `%LOCALAPPDATA%\CocoMinecraftUpdater\launcher\skins` del host. Una reinstalación del sistema, pérdida del disco o eliminación manual de esa carpeta no puede ofrecer permanencia sin incorporar un respaldo externo, que actualmente no forma parte del diseño.

Referencias técnicas: [CustomSkinLoader](https://github.com/xfl03/MCCustomSkinLoader) y su guía oficial [How to Use / LocalSkin](https://github.com/xfl03/MCCustomSkinLoader/wiki/How-to-Use). La redistribución conserva el JAR oficial sin modificar y el catálogo registra origen, licencia y hash.

### Voz sin onboarding

La política de voz es global y basada en el ID interno del mod, no en el nombre del JAR. Esto es necesario porque CurseForge instala archivos como `asset_416089_8280439.jar`; Backrooms contiene dentro de ese archivo `id=voicechat`, Simple Voice Chat `1.20.1-2.6.19`.

Cuando una instancia contiene Simple Voice Chat, Coco actualiza siempre `config/voicechat/voicechat-client.properties` antes del arranque y conserva las claves ajenas. Fuerza:

- `onboarding_finished=true`;
- `microphone=` y `speaker=` vacíos para usar los dispositivos predeterminados del sistema;
- `microphone_activation_type=VOICE` y `voice_activity_detection=true`;
- `automatic_gain_control=true`, `denoiser=true` y `use_natives=true`;
- `muted=false`, `disabled=false`, `run_local_server=true`;
- umbral `-50.0 dB` y ganancia manual neutra `0.0`.

No se escriben las claves antiguas `recording_device`, `voice_activation_type`, `show_wizard` ni archivos raíz que el mod no lee. El usuario puede abrir manualmente los ajustes o el onboarding dentro del juego; Coco sólo evita que sea obligatorio en el primer ingreso. La detección conoce Fabric, Quilt, Forge y NeoForge mediante la metadata interna. Otro producto de voz distinto necesita un adaptador probado: no se le inventa un TOML genérico.

Simple Voice Chat usa UDP. En el servidor integrado cambia dinámicamente al puerto elegido por Abrir en LAN; Coco fija ese puerto en 25565. El manifiesto de red publica `Coco Voice LAN - ZeroTier UDP 25565`; el helper elevado la limita a entrada UDP, perfil Private y `10.77.37.0/24`. TCP y UDP pueden compartir el número de puerto porque son protocolos separados. En clientes se elimina cualquier regla de entrada Coco equivalente.

Referencias: [configuración cliente oficial de Simple Voice Chat](https://modrepo.de/minecraft/voicechat/wiki/client_config), [onboarding 2.5.2+](https://modrepo.de/minecraft/voicechat/wiki/client_setup) y [configuración servidor/UDP](https://modrepo.de/minecraft/voicechat/wiki/server_config).
- Into The Backrooms no declara ni distribuye MakeUp Ultra Fast como shaderpack externo. Sus efectos visuales propios sí se conservan: SP-Backrooms Revamped incluye Veil y shaders internos para VHS, niebla, desenfoque, iluminación, agua, cielo y distorsiones. La preferencia externa de MakeUp que apareció durante la auditoría era una herencia incorrecta de una rutina genérica y fue retirada.
- Regla general: el contenido y la configuración visual entregados por el modpack se instalan y preservan como parte del pack. Coco sólo selecciona o reconfigura un shaderpack cuando existe una excepción explícita, justificada y probada para esa experiencia; la ausencia de esa excepción significa «no intervenir», no «prohibir shaders».
- Las selecciones declarativas admiten Iris, Oculus y OptiFine. Los archivos de opciones propios de un shader se fijan mediante `preferences.shader.companionFiles` o `preferences.managedFiles`, siempre dentro de la instancia correspondiente.
- Las copias de rollback sólo existen durante la transacción y se eliminan al confirmar el nuevo estado.

## UX y diagnóstico

- Bootstrap y updater usan el panel Reina de 640×460; Coco Launcher lo extiende a 640×470 para alojar la tarjeta unificada sin superposición.
- Título y detalle tienen áreas multilínea y reducción controlada de fuente; no usan truncado por cantidad arbitraria de caracteres.
- Nombre y skin viven siempre en una tarjeta unificada dentro del mismo panel, no en formularios Windows aparte.
- Cada ejecución registra Run ID, timeline, etapa, progreso, descargas, runtime y procesos.
- Un fallo visible crea `CocoUpdater-error-*.txt` en el Escritorio sin copiar tokens.

## Puertas del segundo test

Antes de llamarlo listo para más amigos:

1. Publicar una versión nueva sólo después de que toda la regresión pase.
2. Migrar visiblemente al menos un EXE 0.5.57 existente.
3. Hacer una instalación fría Backrooms en un amigo y otra reutilizando caché.
4. Confirmar que la tarjeta comienza vacía en un equipo sin identidad, permite escribir durante la descarga y sólo exige Enter antes de crear Minecraft.
5. Confirmar `OnlineMode=false`, `EnableUUIDFixer=true`, `UseUPnP=false` antes de abrir LAN.
6. Entrar con host + al menos dos clientes, cerrar/reconectar uno y verificar inventario/avances.
7. Provocar un fallo controlado y comprobar el TXT del Escritorio.
8. Repetir la prueba después de cambios en Forge, el pack o el adaptador LAN; los pendientes se documentan, pero no ocultan la experiencia.

No publicar ni modificar el mundo `coco` con Minecraft o la LAN abiertos.
