# Auditoría completa de Coco Launcher — 2026-07-25

## Alcance

Se revisaron historial Git, catálogo, locks, engine, bootstrap, updater, Publisher, tests, logs, procesos, instancias temporales, documentación y evidencia del primer test multiusuario.

## Evidencia del primer éxito

El Run ID `3e4d7c6ba0604244bf71e777af98c2f5` abrió Into The Backrooms como host. La sesión permaneció activa aproximadamente entre 05:43 y 07:51 del 2026-07-25. El mundo `New World (2)` fue creado a las 05:44 y modificado hasta el final de la sesión. El usuario confirmó que dos amigos se unieron y jugaron.

Esto valida físicamente Backrooms, el servicio de sesión, ZeroTier, la instancia del host, el ingreso de dos clientes y el juego básico. No valida automáticamente DREAD ni Zombie 1.12.2.

## Hallazgos

| Severidad | Hallazgo | Consecuencia | Corrección |
|---|---|---|---|
| Crítica | Coco escribía `online-mode`, `enable-uuid-fixer` y `enable-upnp`; MCWiFiPnP espera `OnlineMode`, `EnableUUIDFixer` y `UseUPnP`. | El mod ignoraba los campos y la LAN seguía online hasta el cambio manual. | Esquema oficial exacto, validador y regresión negativa. |
| Crítica | La prueba anterior sólo releía el JSON incorrecto generado por Coco. | Informaba éxito sin comprobar lo que consume el mod. | La prueba exige los nombres oficiales y rechaza kebab-case. |
| Alta | El bootstrap compartido medía 780×350, pero el launcher colocaba controles hasta y=438. | Controles invisibles o fuera del panel en el EXE publicado. | Panel unificado 640×460 y layout normalizado. |
| Alta | Una rutina genérica mezclaba shaders, voice configs, skin y resource pack Zombie sin distinguir políticas globales de ajustes por pack. | Contaminación entre experiencias y rutas inexistentes en clientes. | DREAD/Zombies/Backrooms quedaron declarativos; Essential y skin/CSL quedaron como políticas globales intencionales. |
| Alta | El catálogo atribuía MakeUp Ultra Fast a Backrooms aunque ni el lock oficial ni la instancia validada contienen ese shaderpack externo. | Una instalación futura podía seleccionar un shader ajeno si el archivo aparecía por contaminación. | Se retiró la preferencia y se agregó una regresión que comprueba que Coco no lo inyecte en una instalación limpia; los shaders internos de SP-Backrooms Revamped se conservan. |
| Alta | Zombie 1.12.2 carece de MCWiFiPnP compatible. | No existe garantía de puerto 25565, offline o UUID estable. | Experiencia bloqueada hasta implementar y probar un adaptador real. |
| Alta | El único mundo exitoso vivía bajo `%TEMP%`. | Windows o una limpieza podía borrar la primera partida. | Respaldo completo verificado por SHA-256; fuente preservada. |
| Media | Tests y Publisher conservaban Iron Lung ya retirado. | Cuelgues, falsa cobertura y publicaciones bloqueadas por un pack inexistente. | Tests eliminados y Publisher desacoplado. |
| Media | Documentación seguía en 0.5.47, Iron Lung y flujo premium. | Operación contradictoria con el producto real 0.5.57. | Documentación canónica reescrita. |
| Media | Títulos y detalles dependían de tamaños rígidos/truncado. | Palabras cortadas en bootstrap, progreso y errores. | Etiquetas multilínea con ajuste de fuente medido. |
| Seguridad | Offline + UUID Fixer estabiliza UUID, pero no autentica nombres. | Un miembro de la red puede suplantar otro nombre. | Riesgo documentado; whitelist/nombres reservados queda como endurecimiento previo a ampliar el grupo. |

## Identidad

Se decidió retirar el modo premium del UX nuevo. Todos los jugadores usan identidad local, tengan o no licencia. Coco intenta reutilizar únicamente el nombre no secreto ya seleccionado localmente; nunca copia tokens. Si no puede determinar un único nombre válido, deja disponible el campo permanente de la tarjeta unificada.

La preparación de red, mods, runtime y configuraciones es independiente de la identidad. El jugador puede editar nombre y skin en la misma tarjeta durante ese trabajo; si al terminar aún no existe un nombre, sólo se pausa la apertura de Minecraft. El cliente congela la tarjeta al construir el proceso para evitar una identidad a medio cambio.

El wizard de Simple Voice Chat fallaba porque Backrooms usa un JAR CurseForge genérico y la detección buscaba texto en el nombre del archivo. Además se intentaban claves que 2.6.19 no consume. La reparación inspecciona `fabric.mod.json`/metadata Forge, escribe la ruta oficial anidada y actualiza archivos existentes. Una verificación posterior del `latest.log` real confirmó que el servidor integrado cambia la voz al puerto LAN 25565; por ello la red administrada abre UDP 25565 privado, no el 24454 predeterminado de servidores dedicados.

Los estados Microsoft creados por 0.5.50–0.5.57 se migran conservando el nombre y eliminando el UUID externo. Los argumentos PortableMC rechazan cualquier modo distinto de `offline`.

## Estado por experiencia

- **Into The Backrooms:** validada por el primer test real; requiere repetir instalación fría/reconexión en el segundo test.
- **DREAD:** experimental; todavía no debe considerarse probado por compartir engine.
- **Zombie Apocalypse 1.12.2:** bloqueada.
- **Iron Lung:** retirada del catálogo, Publisher, pruebas y temporales.

## Datos y limpieza

Inicialmente se hizo una copia verificada del mundo para protegerlo durante la auditoría. Por decisión posterior del usuario, esa copia fue eliminada y la instancia probada completa se movió a `%APPDATA%\CocoMinecraft\experiences\into-the-backrooms`. También se eliminó la raíz temporal —caché, Zombie incompleto y OWZA—, por lo que existe una sola instalación Backrooms administrada. No se tocó `%APPDATA%\.minecraft\saves\coco`.

CustomSkinLoader 15.0.1 quedó comprobado en el log de la sesión Backrooms: inicializó su bootstrap Fabric y aplicó sus transformadores. La skin inicial `smolbird` se distribuye desde el engine con SHA-256 `fbfb5fdf0c1a71d3904efcbdfe9b403107c133b9137a302f1611e8adc29864fb`. El launcher añade además selección visual por clic/arrastre, validación PNG, vista previa, registro privado sincronizado y réplica a la ruta LocalSkin del mundo original y las experiencias.

Durante la publicación 0.5.58, la actualización visible del host reprodujo una excepción GDI+ `Graphics.DrawString: El parámetro no es válido` y una X roja en la imagen. La causa fue doble: el reajuste de texto destruía la fuente anterior antes de que terminara un pintado reentrante de WinForms, y `Image.FromStream` dejaba al `PictureBox` dependiendo de un stream temporal. La corrección conserva las fuentes hasta cerrar el control y clona la imagen a un `Bitmap` independiente tanto en bootstrap como en engine.

La política obligatoria no convierte a CustomSkinLoader en universal por inferencia. El catálogo contiene una variante 15.0.1 validada para Minecraft 1.19.2 y 1.20.1. Una experiencia futura en otra versión queda rechazada hasta declarar y probar otra variante compatible; una vez declarada, la preparación sí es automática.

Backrooms sí tiene una canalización visual propia: el JAR de SP-Backrooms Revamped empaqueta Veil y programas internos para VHS, fog, motion blur, luces, agua, cielo y distorsiones. Eso es distinto de un ZIP seleccionable en `shaderpacks`. Coco no elimina ni desactiva esa canalización; simplemente dejó de atribuirle MakeUp Ultra Fast sin evidencia.

## Verificación automatizada

Las regresiones cubren:

- identidad local automática, ambigua y migrada;
- ausencia de tokens;
- rechazo del modo Microsoft;
- Quick Play y aislamiento;
- bloqueo de experiencias incompatibles;
- esquema real de MCWiFiPnP;
- ciclo cliente y host;
- catálogo, locks, rollback, red, observabilidad y empaquetado.

La prueba física sigue siendo obligatoria: mocks no pueden demostrar que Forge/Fabric, un mod concreto, dos PCs y una red real se comporten bien juntos.

## Próximo test

Usar Backrooms, no DREAD/Zombie. Antes de abrir LAN comprobar el estado visual de Coco. Conectar dos clientes, reconectar uno, verificar identidad/inventario y recoger Run IDs/logs. Si falla, conservar toda la instancia y enviar el TXT del Escritorio; no cambiar manualmente varias opciones antes de registrar la causa.
