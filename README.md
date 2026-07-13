# Coco Minecraft Updater

Actualizador de mods para el mundo compartido **Coco**. Detecta el directorio real de Minecraft sin depender del launcher y sincroniza el pack publicado en GitHub Releases sin conservar respaldos permanentes.

## Flujo para los amigos

1. Reciben una sola vez únicamente `CocoUpdater.exe`.
2. Hacen doble clic en `CocoUpdater.exe`.
3. El bootstrapper consulta el manifiesto remoto, actualiza el motor si es necesario y ejecuta la sincronización.
4. Si Minecraft está abierto, identifica su `--gameDir`, descarga la actualización y espera a que el juego se cierre para aplicarla.

El pack instala **Coco Session Bridge & Pack Gate**. Desde entonces el Bridge inicia el updater solo mientras Minecraft está abierto, muestra el progreso dentro del juego y el servidor rechaza clientes atrasados. No se toca `saves`, `screenshots`, cuentas ni `options.txt`; no se guardan respaldos permanentes.

## Publicación

El archivo remoto `latest.json` vive en GitHub Releases y describe cada JAR por nombre, tamaño y SHA-256. El updater descarga únicamente los mods faltantes o modificados, reutiliza los correctos y elimina los sobrantes. El EXE inicial no contiene mods y no necesita volver a distribuirse para cambios del pack o del motor.

Ver [docs/OPERACION.md](docs/OPERACION.md) para publicar una versión y [docs/GITHUB_SETUP.md](docs/GITHUB_SETUP.md) para conectarlo a GitHub.
