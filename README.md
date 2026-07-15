# Coco Minecraft Updater

Sincroniza por JAR el pack Fabric 26.1.2 del mundo Coco. Cada amigo recibe una sola vez `CocoUpdater.exe`; el ejecutable no contiene los mods y descarga únicamente los archivos faltantes o diferentes.

## Primera instalación de un cliente

1. Abrir la instancia correcta de Minecraft hasta el menú principal.
2. Ejecutar `CocoUpdater.exe` una vez.
3. El updater reconoce el `--gameDir`, descarga ZeroTier desde su sitio oficial, verifica SHA-256 y firma Authenticode y muestra un único UAC de Windows para instalar el adaptador y unirse a la red. Después de aceptar UAC, el ayudante administrativo permanece oculto; no aparece una consola PowerShell vacía.
4. El host autoriza automáticamente el equipo. El updater solicita un cierre normal de Minecraft, instala el pack exacto y deja Session Bridge.
5. Al volver a abrir Minecraft aparece el servidor `Coco Minecraft` con el endpoint estable `10.77.37.1:25565`.
6. Desde entonces Session Bridge comprueba silenciosamente sólo la red al arrancar Minecraft. El entrypoint principal inicia el chequeo temprano y los eventos cliente verifican el resultado y reintentan si no aparece el estado listo. Al iniciar un login comprueba además el pack; si hay una reparación o actualización, la realiza y muestra la ventana morada sólo cuando hace falta.

No modifica mundos, cuentas, screenshots ni `options.txt`. Los clientes reciben exactamente los JARs publicados. El host conserva mods adicionales con un Fabric ID nuevo para que puedan incorporarse a la siguiente publicación sin perderse; versiones viejas con el mismo ID no se duplican.

Session Bridge checks during login, before registry synchronization. This lets it start the updater even when a client is missing a content mod and cannot finish joining.

## Host y clientes

Sólo `config/coco-host.json`, guardado localmente en la instalación del anfitrión, selecciona el paquete host. Ese archivo nunca se distribuye. El cliente no recibe e4mc ni MCWiFiPnP; ambos roles reciben el mismo Session Bridge/Pack Gate.

La integración ZeroTier está publicada y reforzada; queda pendiente completar el primer ensayo en el Windows de un amigo. El engine carga sus componentes desde memoria para funcionar también con la política predeterminada `Restricted`, sin pedir al usuario que debilite la seguridad de PowerShell. No usa ZeroTier Central ni distribuye tokens administrativos: el host ejecuta un controlador privado y autoriza automáticamente nodos nuevos mientras Minecraft está abierto. e4mc sigue instalado como respaldo durante la validación A/B.

## Publicar mods

Con Minecraft cerrado, ejecutar `dist/CocoPublisher.exe`. Incrementa la versión, compila, valida hashes y roles, crea un release privado como borrador, sube los assets, actualiza la instalación host y finalmente hace visible la versión. Si algo falla, los clientes continúan viendo el release anterior.

Los diagnósticos de cada cliente quedan en `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`. Los intentos realizados desde Minecraft se registran como `bridge-<PID>.log`, por lo que un fallo de arranque ya no queda silencioso.

Consulta [docs/OPERACION.md](docs/OPERACION.md) para el flujo operativo y riesgos conocidos.
