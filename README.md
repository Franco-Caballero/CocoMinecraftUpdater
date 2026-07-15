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

No se requiere instalar ZeroTier manualmente ni ejecutar el updater manualmente como administrador. Tras la incorporación inicial, Session Bridge realiza verificaciones silenciosas; solo muestra interfaz cuando existe una reparación o actualización.

## Integridad del pack

Los clientes reciben exactamente los mods publicados. La instalación host actúa como fuente del Publisher y conserva JAR adicionales con un Fabric ID nuevo, evitando que una actualización normal elimine incorporaciones locales pendientes de publicación. El Publisher también bloquea eliminaciones accidentales de IDs ya publicados.

El updater no modifica mundos, cuentas, capturas de pantalla ni `options.txt`.

## Publicación

Con Minecraft completamente cerrado:

```text
dist\CocoPublisher.exe
```

El Publisher incrementa la versión, compila componentes, valida roles/hashes, ejecuta pruebas, crea un release borrador, actualiza el host y publica únicamente si todas las etapas terminan correctamente.

## Seguridad

- El manifiesto público no contiene credenciales administrativas.
- El firewall del host limita la entrada a TCP 25565 desde la subred ZeroTier.
- Los perfiles offline requieren una política de whitelist independiente de la autorización de red.
- El EXE todavía no dispone de una firma de código con reputación; SmartScreen puede advertir en la primera ejecución.

## Documentación

- [Operación, publicación y soporte](docs/OPERACION.md)
- [Canal estable y arquitectura de GitHub](docs/GITHUB_SETUP.md)

Los diagnósticos se almacenan en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`.
