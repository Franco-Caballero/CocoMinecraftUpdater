# Coco Minecraft Updater

Sincroniza por JAR el pack Fabric 26.1.2 del mundo Coco. Cada amigo recibe una sola vez `CocoUpdater.exe`; el ejecutable no contiene los mods y descarga únicamente los archivos faltantes o diferentes.

## Primera instalación de un cliente

1. Abrir la instancia correcta de Minecraft hasta el menú principal.
2. Ejecutar `CocoUpdater.exe` una vez.
3. El updater reconoce el `--gameDir`, descarga ZeroTier desde su sitio oficial, verifica SHA-256 y firma Authenticode y muestra un único UAC de Windows para instalar el adaptador y unirse a la red.
4. El host autoriza automáticamente el equipo. El updater solicita un cierre normal de Minecraft, instala el pack exacto y deja Session Bridge.
5. Al volver a abrir Minecraft aparece el servidor `Coco Minecraft` con el endpoint estable `10.77.37.1:25565`.
6. Desde entonces Session Bridge inicia una comprobación al intentar unirse a un servidor. Si red y pack están actualizados, termina inmediatamente; si hay una reparación o actualización, la realiza y muestra la ventana morada sólo cuando hace falta.

No modifica mundos, cuentas, screenshots ni `options.txt`. Reemplaza exactamente los JARs de `mods` y no conserva respaldos permanentes.

Session Bridge checks during login, before registry synchronization. This lets it start the updater even when a client is missing a content mod and cannot finish joining.

## Host y clientes

Sólo `config/coco-host.json`, guardado localmente en la instalación del anfitrión, selecciona el paquete host. Ese archivo nunca se distribuye. El cliente no recibe e4mc ni MCWiFiPnP; ambos roles reciben el mismo Session Bridge/Pack Gate.

La integración ZeroTier está implementada localmente y pendiente de publicación/prueba con el primer amigo. No usa ZeroTier Central ni distribuye tokens administrativos: el host ejecuta un controlador privado y autoriza automáticamente nodos nuevos mientras Minecraft está abierto. e4mc sigue instalado como respaldo durante la validación A/B.

## Publicar mods

Con Minecraft cerrado, ejecutar `dist/CocoPublisher.exe`. Incrementa la versión, compila, valida hashes y roles, crea un release privado como borrador, sube los assets, actualiza la instalación host y finalmente hace visible la versión. Si algo falla, los clientes continúan viendo el release anterior.

Los diagnósticos de cada cliente quedan en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`.

Consulta [docs/OPERACION.md](docs/OPERACION.md) para el flujo operativo y riesgos conocidos.
