# GitHub

Repositorio: `Franco-Caballero/CocoMinecraftUpdater`.

El canal estable está integrado dentro del EXE y apunta a:

```text
https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json
```

El Publisher obtiene la credencial mediante Git Credential Manager, crea primero un release borrador y lo publica sólo al terminar todas las verificaciones. Los assets de mods usan nombres basados en SHA-256; el cliente reutiliza JARs correctos y descarga sólo los que cambian.

El manifiesto estable también publica la configuración no secreta de ZeroTier: Network ID, subred, endpoint, URL versionada del MSI, SHA-256 y patrón del firmante. No contiene tokens de ZeroTier Central. La autorización pertenece al controlador local del host y nunca pasa por GitHub Actions.

La acción de GitHub es una compilación de respaldo. La publicación oficial se realiza con `dist\CocoPublisher.exe` desde el host porque también valida y actualiza la instalación local antes de exponer el release.
