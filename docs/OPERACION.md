# Operación

## Lo único que reciben los amigos

Comparte el `CocoUpdater.exe` publicado en el release más reciente. No necesitan JSON, ZIP ni acceso a GitHub. El primer EXE instala una copia canónica en `%LOCALAPPDATA%\CocoMinecraftUpdater\CocoUpdater.exe`; Session Bridge siempre llama a esa copia y el bootstrapper la puede reemplazar por versiones nuevas.

Para eliminar ambigüedad en la primera ejecución, el amigo debe abrir primero la instancia Fabric 26.1.2 correcta y luego ejecutar el EXE. El proceso abierto aporta el `--gameDir` exacto. Si Minecraft no está abierto, se elige siempre el candidato con mayor puntuación por versión Fabric, mods, logs, actividad y marcadores previos.

## Publicar una actualización

1. Cierra Minecraft y confirma que la sesión LAN terminó.
2. Deja en `%APPDATA%\.minecraft\mods` los JARs que debe usar el pack.
3. Ejecuta `dist\CocoPublisher.exe`.
4. Espera el mensaje de éxito. No abras Minecraft mientras publica.

El Publisher incrementa automáticamente el último número de versión. Excluye `fly-speed-modifier` mientras siga mal empaquetado, deduplica archivos idénticos, rechaza IDs Fabric repetidos con contenido diferente y separa automáticamente host/cliente. El release permanece como borrador hasta que:

- Bridge, Gate, engine, bootstrapper y Publisher compilan;
- manifiesto, tamaños y SHA-256 pasan la validación;
- la prueba de recuperación transaccional pasa;
- todos los assets aparecen en GitHub con el tamaño correcto;
- la instalación host queda actualizada.

Después se publica y los clientes lo detectan en el próximo intento de conexión a un servidor. Session Bridge no mantiene un monitor periódico. Nunca publiques durante una sesión: el Publisher lo bloquea para evitar que clientes nuevos intenten entrar a un Gate antiguo.

## Recuperación y soporte

Si Windows se apaga durante el reemplazo de `mods`, el próximo inicio restaura automáticamente `.coco-mods-replacing` antes de continuar. Las descargas se verifican por SHA-256 y se reintentan cuatro veces.

Para diagnosticar un PC, pide la carpeta `%LOCALAPPDATA%\CocoMinecraftUpdater\logs`. El updater conserva los 40 registros más recientes.

## Riesgo de Windows

`CocoUpdater.exe` no está firmado con un certificado de firma de código confiable. SmartScreen o un antivirus pueden advertir o bloquear la primera ejecución. La solución definitiva es firmar cada EXE con un certificado que genere reputación; cambiar el icono o empaquetarlo de otra manera no reemplaza esa firma.
