# Coco Minecraft Updater

Coco Minecraft Updater distribuye y mantiene un pack Fabric para Minecraft Java en Windows. Sincroniza JARs de forma transaccional, prepara una LAN virtual privada mediante ZeroTier y mantiene un endpoint estable para un mundo alojado con **Abrir en LAN**, sin port forwarding.

## Capacidades

- Detección automática de la instancia mediante `--gameDir`.
- Descarga incremental de mods con verificación SHA-256.
- Separación de paquetes host/cliente mediante un marcador local no distribuido.
- Instalación y reparación automatizada de ZeroTier 1.16.2.
- Validación de URL, hash y firma Authenticode del MSI oficial.
- Autorización mediante un controlador ZeroTier local, sin tokens de Central en artefactos públicos.
- Entrada persistente `Coco Minecraft` en `servers.dat`.
- Session Bridge y Pack Gate para comprobar red y versión antes del login.
- Instalación transaccional y recuperación tras interrupciones.
- Releases inmutables por contenido y actualización automática del bootstrapper.

## Arquitectura

La ruta principal de juego es:

```text
Minecraft TCP
  → adaptador virtual ZeroTier
  → conexión cifrada DIRECT o relay de respaldo
  → host 10.77.37.1:25565
```

ZeroTier opera a nivel IP y no interpreta ni multiplexa el protocolo Minecraft. e4mc permanece exclusivamente en el paquete host como contingencia y no forma parte de la ruta normal.

## Incorporación de un cliente

1. Abrir únicamente la instancia Fabric 26.1.2 correcta hasta el menú principal; dejar cerradas las versiones antiguas.
2. Ejecutar `CocoUpdater.exe` una vez.
3. Aceptar SmartScreen o UAC únicamente si Windows los presenta.
4. Esperar a que el updater muestre la reina, cierre Minecraft automáticamente y luego prepare la red y sincronice el pack.
5. Reabrir Minecraft y seleccionar `Coco Minecraft` en Multijugador.

No se requiere instalar ZeroTier manualmente ni ejecutar el updater manualmente como administrador. En la primera ejecución, el updater valida que el proceso abierto sea realmente Fabric 26.1.2 y usa su `--gameDir` aunque exista un destino antiguo guardado; una versión equivocada produce instrucciones claras en vez de recibir los mods. Los perfiles TLauncher aplicables se ajustan para impedir que TLSkinCape, incompatible con EntityCulling, vuelva a inyectarse. Session Bridge consulta de forma liviana el número de versión pública dentro de Minecraft; si coincide, no inicia el updater completo. Al lanzar el EXE cierra explícitamente su entrada estándar para que `ps2exe` no espere hasta el cierre de Minecraft antes de ejecutar el script. Si el pack está atrasado, abre la reina desde el bootstrap, comprueba primero el estado local, solicita el cierre automático de Minecraft y, si el cierre normal no responde, termina únicamente ese proceso tras ocho segundos. Solo entonces prepara la red, descarga e instala, con el progreso siempre visible. La instalación elevada de ZeroTier publica sus etapas y la cuenta regresiva de autorización en la misma reina aunque el helper permanezca oculto. El trabajo silencioso `NetworkOnly` y la actualización completa usan bloqueos distintos, así que el chequeo de red del arranque no puede retrasar la reina ni el cierre; al tocar ZeroTier se serializan de nuevo, incluso frente a engines antiguos, y un autorizador sano de la misma sesión se reutiliza. El engine reconoce además un chequeo completo asociado al PID de Minecraft, por lo que rescata solicitudes de Bridges antiguos que todavía no conocen esta detección previa. La ejecución manual compara también el inicio de Minecraft con la hora de instalación. Si una actualización terminó con el juego antiguo aún en memoria, el cliente se cierra y solicita reabrir sin descargar de nuevo. Al terminar, la ventana de la reina cambia a un estado verde de confirmación y permanece abierta hasta pulsar `ACEPTAR` o Enter, sin texto bajo la barra ni cuadros booleanos adicionales.

## Integridad del pack

Los clientes reciben exactamente los mods publicados. `%APPDATA%\.minecraft\mods` en el host es la fuente de verdad del Publisher: agregar o quitar un JAR allí agrega o retira ese mod en la publicación siguiente. Durante una actualización normal del host, el updater conserva JAR adicionales con un Fabric ID nuevo para no borrar incorporaciones locales todavía no publicadas. Los IDs retirados permanentemente se registran en `policy/blocked-mod-ids.txt`; actualmente `tsa-decorations` e `inventoryextended` no pueden volver a publicarse en ningún rol. Inventory: Extended se retiró porque duplicaba de forma rota el inventario principal; los datos de jugadores previos quedaron respaldados antes del cambio.

Los archivos declarados como configuración administrada se incluyen con hash y contenido en el manifiesto y se aplican junto con los mods. Actualmente `config/Stackable.json` fija `maxStack` en 256 y `config/jei/jei-client.ini` activa `showHiddenIngredients = true` para host y clientes, de modo que JEI incluya objetos que no estén expuestos correctamente por una pestaña creativa.

El updater no modifica mundos, cuentas ni capturas de pantalla. Las preferencias de cliente se conservan; excepcionalmente, un release puede declarar una migración inicial identificada y acotada. La migración `pingwheel-location-z-v1` cambia una sola vez el valor predeterminado de Ping Wheel desde Mouse 5 a Z, registra su aplicación y nunca vuelve a imponer esa tecla si el jugador la personaliza.

## Publicación

Con Minecraft completamente cerrado:

```text
dist\CocoPublisher.exe
```

El Publisher exige partir de `origin/main` sincronizado y usar exactamente la versión siguiente a la estable, compila componentes, valida roles/hashes y la política de mods bloqueados, ejecuta pruebas —incluida la carrera entre versión cargada y versión en disco—, crea un release borrador, actualiza el host, hidrata el caché local verificado de `NetworkOnly` y publica únicamente si todas las etapas terminan correctamente. Los helpers bootstrap obsoletos se conservan fuera de la raíz activa en un respaldo recuperable.

## Seguridad

- El manifiesto público no contiene credenciales administrativas.
- El firewall del host limita la entrada a TCP 25565 desde la subred ZeroTier.
- Los perfiles offline requieren una política de whitelist independiente de la autorización de red.
- El EXE todavía no dispone de una firma de código con reputación; SmartScreen puede advertir en la primera ejecución.

## Documentación

- [Operación, publicación y soporte](docs/OPERACION.md)
- [Canal estable y arquitectura de GitHub](docs/GITHUB_SETUP.md)

Los diagnósticos se almacenan en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`. Tanto los fallos tempranos del bootstrap como los errores posteriores del engine dejan además `CocoUpdater-error-*.txt` en el Escritorio para enviarlo por soporte.
