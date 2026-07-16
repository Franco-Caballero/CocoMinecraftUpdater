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

1. Abrir la instancia Fabric 26.1.2 correcta hasta el menú principal.
2. Ejecutar `CocoUpdater.exe` una vez.
3. Aceptar SmartScreen o UAC únicamente si Windows los presenta.
4. Esperar a que el updater prepare la red, cierre Minecraft de forma controlada y sincronice el pack.
5. Reabrir Minecraft y seleccionar `Coco Minecraft` en Multijugador.

No se requiere instalar ZeroTier manualmente ni ejecutar el updater manualmente como administrador. Tras la incorporación inicial, Session Bridge realiza verificaciones silenciosas; solo muestra interfaz cuando existe una reparación o actualización. El engine reconoce por sí mismo un chequeo completo asociado al PID de Minecraft, por lo que también muestra la reina cuando la solicitud proviene de un Bridge antiguo que todavía no conoce la señal visual nueva. El chequeo de login informa la versión que Minecraft tiene cargada, no solo la que ya existe en disco; una ejecución manual también compara el inicio de Minecraft con la hora de instalación. Si una actualización terminó con el juego antiguo aún en memoria, el cliente se cierra y solicita reabrir sin descargar de nuevo. Al terminar, la ventana de la reina cambia a un estado verde de confirmación y permanece abierta hasta pulsar `ACEPTAR` o Enter, sin cuadros de diálogo booleanos adicionales.

## Integridad del pack

Los clientes reciben exactamente los mods publicados. `%APPDATA%\.minecraft\mods` en el host es la fuente de verdad del Publisher: agregar o quitar un JAR allí agrega o retira ese mod en la publicación siguiente. Durante una actualización normal del host, el updater conserva JAR adicionales con un Fabric ID nuevo para no borrar incorporaciones locales todavía no publicadas. Los IDs retirados permanentemente se registran en `policy/blocked-mod-ids.txt`; actualmente `tsa-decorations` no puede volver a publicarse en ningún rol.

Los archivos declarados como configuración administrada se incluyen con hash y contenido en el manifiesto y se aplican junto con los mods. Actualmente `config/Stackable.json` fija `maxStack` en 256 y `config/jei/jei-client.ini` activa `showHiddenIngredients = true` para host y clientes, de modo que JEI incluya objetos que no estén expuestos correctamente por una pestaña creativa.

El updater no modifica mundos, cuentas ni capturas de pantalla. Las preferencias de cliente se conservan; excepcionalmente, un release puede declarar una migración inicial identificada y acotada. La migración `pingwheel-location-z-v1` cambia una sola vez el valor predeterminado de Ping Wheel desde Mouse 5 a Z, registra su aplicación y nunca vuelve a imponer esa tecla si el jugador la personaliza.

## Publicación

Con Minecraft completamente cerrado:

```text
dist\CocoPublisher.exe
```

El Publisher exige partir de `origin/main` sincronizado y usar exactamente la versión siguiente a la estable, compila componentes, valida roles/hashes y la política de mods bloqueados, ejecuta pruebas —incluida la carrera entre versión cargada y versión en disco—, crea un release borrador, actualiza el host y publica únicamente si todas las etapas terminan correctamente.

## Seguridad

- El manifiesto público no contiene credenciales administrativas.
- El firewall del host limita la entrada a TCP 25565 desde la subred ZeroTier.
- Los perfiles offline requieren una política de whitelist independiente de la autorización de red.
- El EXE todavía no dispone de una firma de código con reputación; SmartScreen puede advertir en la primera ejecución.

## Documentación

- [Operación, publicación y soporte](docs/OPERACION.md)
- [Canal estable y arquitectura de GitHub](docs/GITHUB_SETUP.md)

Los diagnósticos se almacenan en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`.
