# Auditoría COBBLEVERSE 1.7.42-CF — 2026-07-26

## Decisión

COBBLEVERSE queda incluida y visible en el catálogo candidato. Coco Launcher ya no usa estados para ocultar o bloquear experiencias: la auditoría registra lo probado y lo pendiente sin cambiar disponibilidad. El engine público 0.5.60 aún no la contiene.

## Fuente y runtime

- Pack oficial: [COBBLEVERSE 1.7.42-CF, archivo CurseForge 8488030](https://www.curseforge.com/minecraft/modpacks/cobbleverse-cobblemon/files/8488030).
- Project ID 1210677, file ID 8488030, licencia `All Rights Reserved`, distribución `origin-only`.
- Archivo fuente `COBBLEVERSE-1.7.42-CF.zip`: 225.761.641 bytes, SHA-256 `809685d8a40b62ea0dd8a0a2a95c4974811c2f08b393e7843cb88418af38a683`.
- Minecraft 1.21.1, Fabric Loader 0.18.4, Java 21.
- Memoria: mínimo 4 GiB, recomendados 6 GiB, máximo adaptativo 45 % de la RAM física.

El lock `launcher/experiences/cobbleverse.lock.json` contiene los 142 assets del manifiesto. La única entrada marcada opcional es Terralith 2.5.8 y se conserva. La política del importador incluye dependencias requeridas y opcionales; Essential es la única exclusión global.

## Mundo

El ZIP no contiene `saves`, plantilla de mundo ni semilla. La experiencia usa **Crear mundo nuevo** con semilla vacía, por lo que Minecraft elige una semilla aleatoria. “Default” significa el generador normal del pack: Terralith modifica el terreno porque forma parte del manifiesto, pero no existe mapa prefabricado.

Los mundos viven exclusivamente en `%APPDATA%\CocoMinecraft\experiences\cobbleverse\saves`. El instalador no administra ni reemplaza `saves`, datos de jugador o bases de Distant Horizons.

## Archivos agregados por Coco

| Archivo | Rol | Tamaño | SHA-256 |
|---|---:|---:|---|
| `DistantHorizons-3.2.0-b-1.21.1-fabric-neoforge.jar` | all | 30.207.268 | `d6a7a963f794501678113e2545d8b25c90e123ef6b9256bb5716907d059e1ef5` |
| `mcwifipnp-1.9.0-1.21-fabric.jar` | host | 124.782 | `0c660a930eba4ed70f869e090846d68b36c82321ef7d7626a5bef500233dc455` |
| `CustomSkinLoader_Universal-15.0.1.jar` | all/global | 218.215 | `026d8b38ea93edccd647f60568193e79801a377b7bd4e916dcfc0d5482b767fc` |

DH 3.2.0-b declara Minecraft 1.21/1.21.1, Java 21 y rompe Iris 1.7.4 o anterior. Cobbleverse instala Iris 1.8.14-beta.1, por lo que supera ese límite declarado. MCWiFiPnP 1.9.0 declara Minecraft `>=1.20.5 <1.21.2`, Fabric Loader `>=0.15.0` y Java 21.

## Prueba física del host

Instancia: `%APPDATA%\CocoMinecraft\experiences\cobbleverse`.

- Preparación PortableMC: aprobada.
- Árbol instalado: 1.760 archivos administrados y 140 JAR bajo `mods`.
- Essential: 0 artefactos detectados.
- Terralith, DH, MCWiFiPnP y CustomSkinLoader: presentes y con hash exacto.
- Arranque real: código de salida 0.
- Menú: alcanzado (`Sound engine started`).
- Cobblemon: 1.7.3 iniciado.
- Shader del pack: `COBBLEVERSE - Shaders` cargado por Iris.
- DH: `DH Ready`, eventos Iris enlazados y render OpenGL activo.
- Crash report/fatal: ninguno.

El arranque produjo advertencias de assets/mixins propias del pack y un `GL_INVALID_ENUM` durante el cierre. No hubo crash ni fallo de DH. No se creó mundo durante esta prueba; `saves` quedó sin una partida.

## Puertas restantes

Pruebas todavía pendientes:

1. crear un mundo nuevo aleatorio y comprobar spawn, Terralith, estructuras y progresión inicial;
2. cerrar y reabrir el mismo mundo;
3. abrir LAN y comprobar `OnlineMode=false`, `EnableUUIDFixer=true`, `UseUPnP=false`, TCP 25565 y anuncio `ready`;
4. entrar con al menos un cliente real, reconectar y validar identidad/inventario;
5. confirmar que el cliente recibe DH y no recibe MCWiFiPnP;
6. probar actualización/reparación desde caché y desde una instalación fría.
