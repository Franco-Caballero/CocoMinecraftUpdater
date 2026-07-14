# GitHub

Repositorio: `Franco-Caballero/CocoMinecraftUpdater`.

El canal estable está integrado dentro del EXE y apunta a:

```text
https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json
```

El Publisher obtiene la credencial mediante Git Credential Manager, crea primero un release borrador y lo publica sólo al terminar todas las verificaciones. Los assets de mods usan nombres basados en SHA-256; el cliente reutiliza JARs correctos y descarga sólo los que cambian.

La acción de GitHub es una compilación de respaldo. La publicación oficial se realiza con `dist\CocoPublisher.exe` desde el host porque también valida y actualiza la instalación local antes de exponer el release.
