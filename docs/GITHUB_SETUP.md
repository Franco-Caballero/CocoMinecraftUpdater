# GitHub: canal estable y publicación

Repositorio: `Franco-Caballero/CocoMinecraftUpdater`.

Estado observado el 2026-07-26: release público, manifiesto, EXE, caché y engine instalados en 0.5.62. El catálogo publicado muestra DREAD, Into The Backrooms, Zombie Apocalypse y COBBLEVERSE; no usa estados para ocultar o bloquear experiencias. Cobbleverse 1.7.42-CF arrancó hasta el menú con DH+Iris, pero aún necesita prueba de mundo/LAN/clientes.

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

El ZIP del engine incorpora además la skin global de `smolbird` bajo
`assets/skins/smolbird.png`. `New-CocoEngine.ps1` la reconstruye desde la
fuente Base64 versionada y comprueba su SHA-256 contra `globalPolicies` antes
de empaquetar; no depende de una ruta privada del computador host.

Los JARs se almacenan como assets con nombre derivado de SHA-256. Un cliente reutiliza cualquier archivo cuyo hash ya coincida y descarga únicamente contenido faltante o diferente.

## Publicación oficial

La publicación se realiza desde el host mediante la interfaz:

```text
dist\CocoPublisher.exe
```

También puede ejecutarse directamente, sin abrir la ventana del Publisher:

```powershell
.\tools\Publish-CocoRelease.ps1 -Version <siguiente-version>
```

La ruta directa usa la misma transacción y aplica su propio preflight: bloquea Minecraft, experiencias administradas, Coco Launcher/Updater, otra instancia del Publisher y listeners LAN en 25564/25565. No omite pruebas ni verificaciones del host.

El Publisher obtiene acceso a GitHub mediante Git Credential Manager y ejecuta una transacción:

1. valida que Minecraft esté cerrado;
2. confirma que `HEAD` coincide con `origin/main` y que la versión solicitada es exactamente la siguiente a la estable;
3. compila Bridge, Gate, engine, bootstrapper y Publisher;
4. refleja altas y bajas de la carpeta `mods`, genera manifiesto y assets, y rechaza los Fabric IDs de `policy/blocked-mod-ids.txt`;
5. ejecuta pruebas de release, recuperación, red, actualización automática con versión antigua cargada, autodetección frente a un destino persistido obsoleto, reparación de TLSkinCape/TLauncher, contención entre el chequeo de red y el updater, cierre inmediato del pipe de `stdin` en el Bridge compatible con Java 25, progreso elevado visible, diagnóstico del engine y confirmación visual persistente; para releases launcher exige además catálogo/locks, backend fijado, identidad, instancia transaccional, reintentos, drenaje de pipes, serialización ZeroTier y lifecycles host/cliente;
6. crea un release borrador;
7. sube y verifica tamaños de assets;
8. instala localmente el bootstrap compilado, actualiza la instalación host e hidrata el caché rápido local con el manifiesto/engine verificados, sin depender de descargar un asset todavía oculto en el borrador;
9. publica el release;
10. confirma y sincroniza el commit de versión.

Si una etapa falla antes de publicar, el canal estable continúa apuntando al release anterior.

## GitHub Actions

El workflow de GitHub es una compilación de respaldo, no el mecanismo oficial de publicación. No reemplaza al Publisher porque no puede validar ni actualizar la instalación host antes de exponer una versión.

## Firma del launcher

El `CocoUpdater.exe` distribuido actualmente no tiene una firma de código con
reputación. El workflow histórico de SignPath que está en
`.github/workflows/signpath-release.yml` falló el 2026-08-28 al autenticarse
contra la API; sus secretos no deben reutilizarse sin regenerar el token en
SignPath. Tampoco se debe firmar después de publicar un release estable: la
firma cambia el SHA-256 del EXE y el `bootstrap.sha256` de `latest.json` debe
describir exactamente el archivo firmado.

La solicitud gratuita vigente para un proyecto open source se inicia en
[SignPath Foundation - Apply](https://signpath.org/apply). El formulario y su
CAPTCHA requieren la cuenta y la aprobación del propietario del proyecto; no se
rellenan ni se envían automáticamente desde este repositorio. La política
requerida por el programa está en [`CODE_SIGNING_POLICY.md`](../CODE_SIGNING_POLICY.md).

Flujo seguro para la primera versión aprobada:

1. El propietario completa y envía el formulario de SignPath Foundation.
2. Instala la aplicación de SignPath para el repositorio y crea un token nuevo;
   el token se guarda solamente como secreto de GitHub, nunca en el repositorio,
   logs, locks ni este documento.
3. Se configura la política de firma con el certificado de producción, se
   actualiza el workflow a la versión vigente de la acción y se comprueba que el
   binario se construye desde el commit del repositorio en un runner de GitHub.
4. Para el siguiente release, se puede dejar el borrador sin publicar con:

   ```powershell
   .\tools\Publish-CocoRelease.ps1 -Version <siguiente-version> -KeepDraft
   ```

   Después se ejecuta manualmente `Sign release candidate` en GitHub Actions
   usando ese tag. El workflow construye desde el tag, firma el EXE, actualiza
   `latest.json` y conserva el release como borrador.
5. Antes de publicarlo se verifica
   `Get-AuthenticodeSignature`, el firmante esperado, el SHA-256 del EXE y el
   `bootstrap.sha256` del manifiesto.
6. Solo después de esas comprobaciones se publica el release estable. El botón
   equivalente en GitHub CLI es `gh release edit <tag> --draft=false`.

Firmar no garantiza que SmartScreen deje de mostrar una advertencia el primer
día: Windows también acumula reputación por editor y por hash. El objetivo de
la firma es mostrar un editor verificable y permitir que esa reputación se
acumule con cada descarga limpia.

## Verificación posterior

Después de publicar:

1. Confirmar que el release no sea draft ni prerelease.
2. Confirmar los tres assets de versión.
3. Descargar el `latest.json` del enlace estable y verificar la versión.
4. Comparar SHA-256 del EXE y engine.
5. Verificar `coco-updater-state.json` y Bridge en el host; en un cliente de prueba, confirmar que Gate provoca cierre/reapertura si la JVM conserva la versión anterior aunque el disco ya esté actualizado.
6. Confirmar que `git status` esté limpio y `main` sincronizada con `origin/main`.

No sobrescribir assets inmutables ni reutilizar un tag publicado para contenido diferente.
