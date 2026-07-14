# Coco Minecraft Updater

Sincroniza por JAR el pack Fabric 26.1.2 del mundo Coco. Cada amigo recibe una sola vez `CocoUpdater.exe`; el ejecutable no contiene los mods y descarga únicamente los archivos faltantes o diferentes.

## Primera instalación de un cliente

1. Abrir la instancia correcta de Minecraft hasta el menú principal.
2. Ejecutar `CocoUpdater.exe` una vez.
3. El updater reconoce el `--gameDir`, solicita un cierre normal de Minecraft, instala el pack exacto y deja Session Bridge.
4. Desde entonces Session Bridge inicia una comprobación al intentar unirse a un servidor. Si el pack está actualizado, termina inmediatamente; si hay una actualización, cierra el cliente de forma segura y muestra la ventana morada hasta terminar. No queda un monitor permanente en segundo plano.

No modifica mundos, cuentas, screenshots ni `options.txt`. Reemplaza exactamente los JARs de `mods` y no conserva respaldos permanentes.

Session Bridge checks during login, before registry synchronization. This lets it start the updater even when a client is missing a content mod and cannot finish joining.

## Host y clientes

Sólo `config/coco-host.json`, guardado localmente en la instalación del anfitrión, selecciona el paquete host. Ese archivo nunca se distribuye. El cliente no recibe e4mc ni MCWiFiPnP; ambos roles reciben el mismo Session Bridge/Pack Gate.

## Publicar mods

Con Minecraft cerrado, ejecutar `dist/CocoPublisher.exe`. Incrementa la versión, compila, valida hashes y roles, crea un release privado como borrador, sube los assets, actualiza la instalación host y finalmente hace visible la versión. Si algo falla, los clientes continúan viendo el release anterior.

Los diagnósticos de cada cliente quedan en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`.

Consulta [docs/OPERACION.md](docs/OPERACION.md) para el flujo operativo y riesgos conocidos.
