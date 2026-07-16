# GitHub: canal estable y publicación

Repositorio: `Franco-Caballero/CocoMinecraftUpdater`.

## Canal estable

El bootstrapper consulta:

```text
https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json
```

`latest.json` describe:

- versión y esquema del pack;
- engine y bootstrapper con URL, tamaño y SHA-256;
- paquetes host/cliente;
- assets de mods inmutables por contenido;
- configuración pública de ZeroTier: Network ID, subred, endpoint, MSI versionado, hash y patrón del firmante;
- migraciones iniciales de preferencias de cliente, identificadas y acotadas; actualmente `pingwheel-location-z-v1`;
- configuraciones administradas con ruta, tamaño, SHA-256 y contenido Base64; actualmente `config/Stackable.json` con `maxStack` 256 y `config/jei/jei-client.ini` con `showHiddenIngredients = true`.

El manifiesto no contiene tokens ZeroTier, secretos del controlador ni credenciales GitHub.

## Assets

Cada release estable publica:

- `CocoUpdater.exe`;
- `coco-engine-<versión>.zip`;
- `latest.json`.

Los JARs se almacenan como assets con nombre derivado de SHA-256. Un cliente reutiliza cualquier archivo cuyo hash ya coincida y descarga únicamente contenido faltante o diferente.

## Publicación oficial

La publicación se realiza desde el host mediante:

```text
dist\CocoPublisher.exe
```

El Publisher obtiene acceso a GitHub mediante Git Credential Manager y ejecuta una transacción:

1. valida que Minecraft esté cerrado;
2. confirma que `HEAD` coincide con `origin/main` y que la versión solicitada es exactamente la siguiente a la estable;
3. compila Bridge, Gate, engine, bootstrapper y Publisher;
4. refleja altas y bajas de la carpeta `mods`, genera manifiesto y assets, y rechaza los Fabric IDs de `policy/blocked-mod-ids.txt`;
5. ejecuta pruebas de release, recuperación, red, actualización automática con versión antigua cargada y confirmación visual persistente;
6. crea un release borrador;
7. sube y verifica tamaños de assets;
8. actualiza la instalación host;
9. publica el release;
10. confirma y sincroniza el commit de versión.

Si una etapa falla antes de publicar, el canal estable continúa apuntando al release anterior.

## GitHub Actions

El workflow de GitHub es una compilación de respaldo, no el mecanismo oficial de publicación. No reemplaza al Publisher porque no puede validar ni actualizar la instalación host antes de exponer una versión.

## Verificación posterior

Después de publicar:

1. Confirmar que el release no sea draft ni prerelease.
2. Confirmar los tres assets de versión.
3. Descargar el `latest.json` del enlace estable y verificar la versión.
4. Comparar SHA-256 del EXE y engine.
5. Verificar `coco-updater-state.json` y Bridge en el host; en un cliente de prueba, confirmar que Gate provoca cierre/reapertura si la JVM conserva la versión anterior aunque el disco ya esté actualizado.
6. Confirmar que `git status` esté limpio y `main` sincronizada con `origin/main`.

No sobrescribir assets inmutables ni reutilizar un tag publicado para contenido diferente.
