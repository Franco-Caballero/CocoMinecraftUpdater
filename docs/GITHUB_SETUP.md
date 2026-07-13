# Conectar el proyecto a GitHub

## 1. Crear el repositorio

En GitHub, crea un repositorio público vacío, por ejemplo `coco-minecraft-updater`. No añadas README ni `.gitignore` desde GitHub.

## 2. Publicar este proyecto

Desde la carpeta del proyecto:

```powershell
git init
git add .
git commit -m "Initial Coco updater"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/coco-minecraft-updater.git
git push -u origin main
```

## 3. Configurar el canal de actualización

Edita `CocoUpdater.channel.json` y reemplaza:

```text
REEMPLAZAR_USUARIO
REEMPLAZAR_REPOSITORIO
```

por tu usuario y repositorio. Ese mismo archivo se distribuye junto a `CocoUpdater.exe`.

## 4. Obtener el primer ejecutable

En GitHub abre `Actions` → `Build bootstrapper` → ejecuta el flujo o espera al primer push. Descarga el artefacto `coco-updater-bootstrapper`.

Ese artefacto contiene:

```text
CocoUpdater.exe
CocoUpdater.channel.json
```

Los amigos conservan esos dos archivos. Las actualizaciones futuras descargan automáticamente un motor nuevo y los paquetes de mods descritos por `latest.json`.
