# Operación y publicación

## Primera distribución

Entrega a cada amigo la carpeta inicial con:

```text
CocoUpdater.cmd
CocoUpdater.channel.json
bootstrap/CocoBootstrapper.ps1
```

Antes, reemplaza `manifestUrl` en `CocoUpdater.channel.json` por el enlace `latest/download/latest.json` de tu repositorio GitHub.

## Crear paquetes

Con Minecraft cerrado, desde PowerShell:

```powershell
.\tools\New-CocoEngine.ps1 -Version 0.1.0 -OutputDirectory .\release
.\tools\New-CocoPack.ps1 -MinecraftRoot "$env:APPDATA\.minecraft" -Role client -Version 0.1.0 -OutputDirectory .\release
.\tools\New-CocoPack.ps1 -MinecraftRoot "$env:APPDATA\.minecraft" -Role host -Version 0.1.0 -OutputDirectory .\release
```

El segundo paquete se puede preparar desde la instalación host. Antes de publicarlo, elimina del paquete cliente los mods exclusivamente del host si corresponde.

`New-CocoPack.ps1` solo incluye archivos `.jar`. Para excluir mods del host del paquete cliente se puede usar, por ejemplo, `-ExcludeModPatterns '^(?i)e4mc-', '^(?i)mcwifipnp-'`.

## Publicar en GitHub Releases

1. Crea un repositorio GitHub para este proyecto.
2. Crea un release `v0.1.0`.
3. Genera `latest.json` después de crear los ZIP:

```powershell
.\tools\New-CocoReleaseManifest.ps1 -Version 0.1.0 -GitHubRepository TU_USUARIO/coco-minecraft-updater -ReleaseDirectory .\release
```

4. Sube `coco-engine-0.1.0.zip`, `coco-client-0.1.0.zip`, `coco-host-0.1.0.zip` y `latest.json`.
5. Cada actualización repite el proceso con un número de versión mayor.

GitHub Releases entrega assets públicos mediante URL directa. El bootstrapper descarga el manifiesto y el motor nuevo, por lo que no es necesario redistribuir el actualizador cuando cambia el código.

## Qué modifica el actualizador

- Reemplaza `mods` completo sin dejar respaldo permanente. Durante unos segundos usa una carpeta transitoria para que el reemplazo no quede a medio camino; se elimina al finalizar.
- Copia solamente los archivos de configuración incluidos explícitamente en el paquete.
- Escribe `config/coco-updater-state.json` al finalizar con éxito.

No modifica `saves`, `options.txt`, `screenshots`, cuentas ni los directorios de launcher.

La revisión automática durante una sesión de juego se realizará mediante el mod puente de Fabric `Coco Session Bridge`; no se crean tareas programadas ni procesos residentes de Windows.
