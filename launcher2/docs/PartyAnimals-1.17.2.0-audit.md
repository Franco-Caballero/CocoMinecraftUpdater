# Party Animals 1.17.2.0

Trabajo autorizado por el anfitrión el 2026-11-08. El anfitrión pidió trasladar también la fuente y todos los archivos pesados a D:. Fuente preservada en `D:\CocoWork\PartyAnimals-1.17.2.0\source` (1.909 archivos, 12.475.929.180 bytes); paquetes, herramientas y evidencias de trabajo en el mismo directorio padre. El repositorio conserva únicamente código, metadatos y recursos pequeños. Instalación elegida: `D:\CocoGames\party-animals`.

## Supresión específica de esta versión

Esta distribución no tiene `winmm.dll`, `OnlineFix64.dll` ni `OnlineFix.ini`. Usa una `version.dll` x64 de 3.316.736 bytes, SHA-256 original `df90a04c073a869e3086afdae5fe846fbe5b8fb2025c392e30644dedf9f849f3`. No se aplicó a ciegas la receta MessageBox/MessageBeep de otros juegos: esta DLL no importa MessageBox y resuelve ShellExecuteW dinámicamente. No se modificaron DLL oficiales de Steam ni Windows, ni se bloquearon navegadores o red de otros programas.

Preparación reproducible: `desktop/scripts/Prepare-PartyAnimals.py`; rechaza cualquier otro hash o instrucciones inesperadas antes de escribir. DLL preparada SHA-256 `2f2648b84507c813da18c1dac5965d84a8c96973f767c8dc12b54a8bb3eb1b0c`.

- Rutina de hilo RVA `0x65d0`, offset de archivo `0x59d0`: sus tres primeros bytes se sustituyen por `xor eax,eax; ret`. El hilo, creado desde RVA `0x9ece`, termina antes de crear `Documents\OnlineFix\UPlay\online-fix.me.url` o llamar al navegador. ABI Windows x64, retorno DWORD 0, sin cambiar la pila del llamador.
- Resolución dinámica: el único literal `ShellExecuteW` pasa a un símbolo inexistente de idéntica longitud. En el flujo inspeccionado, el resultado de GetProcAddress se comprueba contra null antes de invocarlo (RVA `0x6c55`). Respaldo independiente de la desactivación del hilo.
- Splash inyectado: en el wrapper RVA `0x10b550`, la llamada a preparación RVA `0x10c270` se sustituye en offset `0x10a959` por `xor eax,eax` y NOP. Se toma la rama existente de fallo/sin video, que marca completado el splash y conserva liberación de contexto y retorno del hilo. No se suprime la inicialización del juego ni el intercambio de frames de Unity.
- El paquete no incluye accesos `.url`. La DLL preparada se fija en `requiredFiles`: la verificación de lanzamiento de Coco rechaza bytes distintos; la preparación no vuelve a copiar la DLL original.

Estos cambios no prueban ausencia universal de ventanas de errores del juego, Steam, Windows, futuras versiones o componentes distintos. Las pruebas de primer arranque, menú y multijugador deben declararse por separado; no sustituirlas por una promesa de «nunca».

## Empaquetado y ficha

ZIP independientes, sin ZIP dividido `.z01` ni concatenación de archivos de instalación: `New-CocoMultipartArchives.py` agrupa archivos completos con presupuesto de 1.800.000.000 bytes por parte. Cada ZIP conserva rutas relativas al directorio del juego y dispone de tamaño/SHA-256 propio; el inventario registra además SHA-256 por archivo. La reanudación verifica contenido y fuente antes de reutilizar una parte completa.

Ficha Steam app 1260320. Portada oficial 616×353: `https://cdn.akamai.steamstatic.com/steam/apps/1260320/capsule_616x353.jpg`. Preview oficial Steam 257056877: `https://cdn.akamai.steamstatic.com/steam/apps/257056877/microtrailer.webm`, 1.305.188 bytes. Descripción en español y galería proceden de la API oficial de Steam consultada para esta alta.

## Evidencia de entrega

Pendiente de completar con inventario final, instalación nativa, arranque, publicación de assets y Setup. Multijugador y otro PC pendientes. Las capturas de UI no estuvieron disponibles: el proveedor nativo informó pipe inexistente y el alternativo rechazó la captura por identidad de conversación no disponible; no se simuló inspección visual.

La revisión automática rechazó la eliminación de nuestra copia parcial temporal `D:\CocoWork\PartyAnimals-1.17.2.0\party-animals-test` sin aportar motivo específico. Se conserva, aproximadamente 11,1 GB. No es la instalación final ni la fuente original.

## Inventario de partes

| Parte | Bytes | SHA-256 |
|---|---:|---|
| party-animals-1.17.2.0-part01.zip | 1375450423 | `f977fc03556ada1725b471ef78a635943d0c8563e1b06616b8b2dcb7f440a651` |
| party-animals-1.17.2.0-part02.zip | 1793130049 | `0785be87ac0ff691d0282dd2ec18bdb4d0f00d1d49886fbe71c776cf0d7f9703` |
| party-animals-1.17.2.0-part03.zip | 1793376382 | `b59e89ffaf55c6e93b06e7c76bfcaaf0a4f2ba5e859dfbb198087041890143e3` |
| party-animals-1.17.2.0-part04.zip | 1787094187 | `e13152276b9d0f84bf74216c24fde6cc8f5dbf1a2dc7a91dbc79327ce34653fa` |
| party-animals-1.17.2.0-part05.zip | 1776219800 | `a423e8545f5a062ba18a85d70409a10f64cc1dfca91e592ac3796b3704dc2b9d` |
| party-animals-1.17.2.0-part06.zip | 1709217433 | `c8eb87054595db2a6cda5dbf885c05c51ae6ae69e45c82c37066ab8dc5da0c48` |
| party-animals-1.17.2.0-part07.zip | 1771007138 | `8f2ebeaa35094cf2117193849c191163539698214c549517eaa0ab7b036423e3` |

Descarga total: **12.005.495.412 bytes**; descomprimido: **12.475.929.180 bytes**. La compresi?n ahorr? solo **3,77 %**: los bundles de Unity ya ven?an comprimidos. No se recomprimieron los bytes ya subidos. La reanudaci?n en D:, incluyendo verificaci?n/reutilizaci?n de partes completas, tard? 360,4 s. GitHub confirm? `digest: sha256:?` y tama?o de las siete partes subidas al borrador.

La ruta TEMP larga en D: reprodujo de forma aislada un fallo real de `MoveFileW` al publicar el ZIP verificado en cach?. Se corrigi? usando las rutas extendidas que devuelve `std::fs::canonicalize`, conservando el movimiento at?mico sin reemplazo. Hay una regresi?n con rutas mayores a 260 caracteres y conflicto concurrente. La prueba de streams de media usa un contador global y pas? al ejecutarse aislada; la suite completa se valida en serie para evitar interferencia entre pruebas.

La primera prueba de instalaci?n real se interrumpi? antes de extraer: acumulaba m?s de 140 s de CPU en la compilaci?n de pruebas sin optimizar. Solo SHA-256 y descompresi?n se optimizan ahora en el perfil de desarrollo (`sha2`, `miniz_oxide`); la aplicaci?n p?blica ya usaba el perfil Release optimizado. No se desactiv? ninguna verificaci?n de integridad.

## Publicaci?n completada

Siete ZIP publicados en `party-animals-1.17.2.0` (prerelease, no Latest). Cada URL p?blica respondi? HTTP 206, Content-Range con tama?o exacto y cabecera ZIP. Coco 2 **0.6.38** firmado y publicado en `coco2-channel`: Setup **20.777.892 bytes**, SHA-256 `39d555243b400d4123d7bf044966a29f5edf450328b93f4344d52149dd5a7d3e`. El publisher descarg? y compar? el Setup versionado y el enlace fijo, y verific? `latest.json`. Latest de Coco 1 sigue `v0.5.184`. Setup instalado silenciosamente en el host; PE instalado ProductVersion/FileVersion **0.6.38**, aplicaci?n abierta. Ubicaci?n registrada de Party Animals: `D:\CocoGames\party-animals`, preservando entradas ajenas y copia del mapa previo en D:.
