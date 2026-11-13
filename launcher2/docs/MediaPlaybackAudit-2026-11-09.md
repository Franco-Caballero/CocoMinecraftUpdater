# Películas: decodificador propio y Resident Evil (2026)

Trabajo de 2026-11-09, Coco 2 0.6.48.

## Diagnóstico de Mickey 17

El anfitrión ve la película; su amiga oye audio con imagen negra. El asset publicado fue inspeccionado con ffprobe por HTTPS: HEVC/H.265 Main de 8 bits, `hev1`, 1918×1036, 24000/1001 fps, audio AAC 5.1, duración 8216,62 s. SHA-256 remoto existente `aee69272e7b31577482903749779b72637da055c516acd14dd8697fc727f3f83`, 1.955.022.383 bytes. No se modificó ni reemplazó.

El reproductor anterior utilizaba `<video>` de WebView2, cuyo soporte HEVC depende de Windows, GPU y controladores. Que funcione el mismo archivo en el host refuerza una incompatibilidad de decodificación/render en el cliente; no demuestra cuál componente falla en su PC. No se obtuvo diagnóstico remoto de ese equipo.

El anfitrión eligió conservar originales e incorporar decodificador propio. Se detuvo la conversión H.264 iniciada para Resident Evil y no se publicó ninguna versión recodificada.

## Integración inicial (0.6.48)

mpv x86_64 baseline (sin requisito v3/AVX2), build 20261109, mpv `v0.42.0-11-g8bc468896` con FFmpeg `N-128713-g0f89d936b`. Paquete oficial del proyecto de builds shinchiro, hash fijado: `7e9588d62c5b830ac2413a3a475b5588e445406e0466dd6333477e631237ec4a`.

- `mpv.exe`: 121.617.408 bytes, SHA-256 `ec653e7b902fea224721ba1139bc7d6e03a79dc69b8b97b52eb7534825346c03`.
- `d3dcompiler_43.dll`: SHA-256 `4b074a3976399dc735484f5d43d04b519b7bdee8ac719d9ab8ed6bd4e6be0345`.
- Los binarios se verifican al preparar y antes de ejecutarlos; el input Lua se compara con los bytes compilados. Copyright, GPL y procedencias viajan como recursos.
- Proceso independiente en una superficie hija de la misma ventana de Coco. Controles React conservados con adaptador local: progreso, volumen, búsqueda, velocidad, pausa y fullscreen. La superficie central deja libres el encabezado y la barra de controles; se oculta al mostrar ayuda o cierre/finalización.
- No instala códecs, asociaciones ni actualizadores de mpv. Configuración externa y scripts del usuario desactivados; solo carga el puente propio. Decoder por software disponible si no sirve la aceleración de vídeo.
- Solo acepta URLs loopback de streams activos ya preparados por Coco. IPC público restringido a acciones tipadas, sin comandos arbitrarios ni rutas del cliente. Sesiones identificadas para impedir cierres/resizes de respuestas antiguas. Job Object con kill-on-close evita audio huérfano si Coco termina.
- La prueba real detectó serialización de lectura/escritura sobre un mismo pipe síncrono: órdenes podían esperar a nuevos eventos. Se separaron las conexiones de eventos y controles, con escrituras de control no bloqueantes. La misma prueba pasó después en 2,30 s con Mickey 17 y 2,52 s con Resident Evil.
- Eliminados «Coco cinema · Película», etiqueta MP4/WEBM y menú contextual del visor. Bindings predeterminados/OSC del motor desactivados; solo acciones propias.

## Resident Evil

Original encontrado en Descargas, no en la ruta scratch indicada inicialmente. ffprobe: HEVC Main 10, `yuv420p10le`, 1920×804, 25 fps, AAC 5.1, 5632,75 s. Se comparte sin recodificar, 1.682.982.853 bytes, SHA-256 `3b8591e2171698fe907b0b2c52f3e1d248ba73ddf088f8d0e7456d9b7c03687c`.

Asset: `resident-evil-2026/Resident.Evil.2026.1080p.HEVC10.AAC5.1.mp4`. Subida nativa desde el archivo original con nombre de asset limpio, sin copia completa para renombrarlo. Digest y tamaño de GitHub coinciden. Reseña breve basada en https://residentevil.movie/ ; portada horizontal oficial de https://www.sonypictures.com/movies/residentevil8 . No se anuncian subtítulos españoles: el original tiene texto inglés y los SRT encontrados también son ingleses/otros idiomas.

Reseñas de Love Island USA, Heart Signal, The Drama y Leviticus reemplazan textos de uso/Downloads. Fuentes de premisas: https://a24screenings.com/the-drama y https://www.neonrated.com/film/leviticus . Catálogo sincronizado: 36 experiencias, seis de medios. La guía maestra incorpora películas/series y sus límites reales de distribución.

## Evidencia y límites

Pruebas opt-in `real_embedded_hevc_decoder_controls_and_shutdown` usaron la función de arranque/IPC del producto, superficie Win32 propia y los dos originales. `hwdec=no`: vídeo y audio decodificados, seek a 180 s, reproducción, pausa, mute, volumen 25 %, velocidad 1,25, puente de input y terminación del decoder aprobados. Se extrajeron fotogramas PNG reales del renderer y se inspeccionaron: tienen imagen, no negro. Audio se mantuvo silenciado durante la prueba; no se afirma escucha subjetiva.

Pruebas del adaptador ejecutan controles tempranos, StrictMode A→B, respuestas tardías y bloqueo del menú contextual. El control de escritorio no estuvo disponible: `DESKTOP_IDENTITY_REQUIRED` y después `Computer Use native pipe is unavailable`. Por tanto no se afirma inspección visual completa del frontend instalado ni validación en el PC de la amiga. Se probó el backend embebido y el adaptador por separado; esa limitación se conserva en la entrega.

Trabajo pesado, runtime y evidencia en D:. El motor añade unos 126 MB instalado (comprimido una sola vez en el Setup), sin duplicar ni convertir cada película. Caché del build reutilizable en `D:\CocoWork\tools\mpv-20261109`.

Validación final de fuentes: Rust 303 PASS, 0 FAIL, 8 opt-in ignoradas; pruebas PowerShell de catálogo/lanzamiento/instancia/integración PASS. Preflight Node 536 PASS, 0 FAIL, 31 opt-in SKIP. Los fixtures de UI anteriores se ajustaron al navegador de prueba; las pruebas nuevas cubren el adaptador nativo. El empaquetado desde D: necesita un junction temporal con ruta relativa porque Tauri 2.10.2 descarta el prefijo de unidad de recursos absolutos Windows; se retira solo ese enlace tras compilar, conservando el caché verificado.

## Publicación e instalación

Resident Evil publicado como prerelease (no Latest): digest GitHub y tamaño coinciden con el original; petición pública Range devolvió 206, `bytes 0-31/1682982853` y cabecera MP4 `ftyp`.

Setup 0.6.48 firmado para actualización, 57.154.885 bytes, SHA-256 `2105faad0f2dfa7e41f9c7c471f4f8f1c9c68ff32dab02cd70f7b7afa298c7fe`. Candidato `0.6.48-2105FAAD0F2D`; feed, Setup versionado y enlace estable descargados desde GitHub y cotejados por hash. Latest de Coco 1 conservado en `v0.5.186`. Extracción NSIS verificó también SHA de mpv.exe y d3dcompiler_43.dll y bytes del script, además del PE/MSI/firma habituales.

Instalación silenciosa del candidato exacto en el host: exit 0, PE versión 0.6.48, ambos binarios del motor instalado coinciden con sus hashes fijados; Coco reabierto. No se afirma validación del cliente remoto hasta que la amiga actualice y pruebe. La firma Ed25519 del updater no es una firma Authenticode Windows.

Limpieza de esta tarea: eliminados el MP4 H.264 incompleto (379.846.704 bytes) y la copia temporal de Mickey (1.955.022.383 bytes), 2.334.869.087 bytes lógicos. Fuente Resident Evil de Descargas y asset original de Mickey preservados. Workspace temporal del builder y su junction propio retirados; runtime reutilizable en D: conservado. Los PNG/logs de evidencia son pequeños y no se distribuyen como contenido del catálogo.

## Regresión visual reproducida por el anfitrión en 0.6.48

Después de publicar, el anfitrión confirmó negro con audio también en su PC, donde el visor anterior sí mostraba Mickey. Las pruebas anteriores validaban decodificación y controles del backend, pero no demostraban que la superficie estuviera por delante de WebView2 en la aplicación real. No se considera resuelto con aquella evidencia.

La presentación usaba MoveWindow + ShowWindow sin ordenar ventanas hermanas. Se reemplazó por SetWindowPos(HWND_TOP, SWP_NOACTIVATE | SHOWWINDOW/HIDEWINDOW), limitado al rectángulo hijo del vídeo. Una prueba Windows crea una ventana opaca hermana encima de la superficie y exige que presentar el vídeo lo coloque primero en el Z-order; pasó junto a las tres pruebas nativas del motor. Se añadió un log pequeño de dimensiones de presentación, sin URLs/tokens. Corrección candidata 0.6.49; requiere prueba del frontend real antes de publicar.

El anfitrión probó la corrección de Z-order en el frontend de desarrollo y confirmó que ya había imagen. Su captura mostró una segunda limitación: el área central reservaba 82 px arriba y 116 abajo, reduciendo la película y creando bandas laterales innecesarias incluso en fullscreen.

Se cambió a una superficie de tamaño completo con región Win32: mientras se muestran los controles, solo se excluyen sus franjas de la región visible del hijo nativo; el viewport del renderer conserva siempre el tamaño total. Al quedar inactivo se restaura toda la región. La imagen mantiene su proporción, sin zoom ni recorte permanente. La prueba nativa comprueba tanto Z-order como dimensiones completas y región de controles; la prueba del adaptador exige el mismo ancho/alto con controles visibles u ocultos. Esta segunda corrección pasó pruebas de tipos, cinco pruebas del adaptador y cuatro pruebas nativas. Comprobación visual final del anfitrión pendiente antes de publicar 0.6.49.

## Entrega corregida 0.6.49

Se publicó la corrección tras la confirmación de imagen del anfitrión y las pruebas de tamaño/región, conservando pendiente la valoración visual final del ajuste fullscreen. Node preflight 537 PASS, 0 FAIL, 31 opt-in SKIP; TypeScript/Vite, presentación Windows 4/4 y adaptador 5/5 PASS. NSIS extraído, firma y recursos del motor verificados.

Setup 57.318.293 bytes, SHA-256 `3b1a790b2e57e7e4934b88bcbd39006c61785e391a49245240cad4be5569afd8`, candidato `0.6.49-3B1A790B2E57`. Publicador verificó por descarga Setup versionado, enlace estable y feed 0.6.49; Latest de Coco 1 sigue `v0.5.186`. Instalación silenciosa exitosa y PE instalado 0.6.49; ventana normal reabierta. Servidor y sesión de desarrollo cerrados. Se retiró además el archivo 7z temporal del motor (34.136.096 bytes), conservando el runtime reutilizable verificado en D:.

Pendientes: confirmación subjetiva del último ajuste de tamaño por el anfitrión y reproducción/controles en el PC de la amiga tras actualizar. El problema original de su Windows sigue siendo un diagnóstico probable de soporte HEVC; no se afirma haber inspeccionado ese equipo.

## Regresión de subtítulos en 0.6.49 y corrección candidata 0.6.50

El anfitrión envió una captura del minuto 5:24 de Mickey 17: la segunda línea de los subtítulos incrustados quedaba tapada por la franja inferior de controles. El contrato de mantener el viewport fijo mediante SetWindowRgn era incorrecto: una región Win32 elimina píxeles del vídeo, incluidos subtítulos ya incrustados. Las pruebas anteriores comprobaron esa región, pero no debieron tratar el recorte como comportamiento válido.

0.6.50 elimina SetWindowRgn y las propiedades de clipping de la API. El adaptador calcula un viewport libre usando la altura real del encabezado y controles (offsetHeight, sin transformaciones de animación); cuando la UI se oculta usa toda la ventana. mpv mantiene proporción y zoom/panscan cero, mostrando el fotograma entero dentro de ese rectángulo. Los márgenes laterales mientras se ven controles son temporales y permiten conservar toda la imagen; en reproducción inactiva no se reserva espacio para la UI.

La prueba Windows exige Z-order correcto, ausencia de región de recorte y dimensiones del área libre/fullscreen. Pruebas del adaptador comprueban 1920×882 en y=82 con controles de 82/116 y 1920×1080 en y=0 cuando se ocultan. Motor 4 PASS, adaptador 5 PASS y TypeScript PASS. Se abrió una versión de desarrollo y se pidió comprobar ambas líneas en 5:24 y la expansión al quedar inactivo, antes de finalizar la entrega.

## Candidato 0.6.50: composición DOM y decodificador libVLC

El anfitrión confirmó los subtítulos completos con el área libre, pero reprodujo otro defecto: el HWND de vídeo tapaba el reloj flotante de la barra y dejaba márgenes por reservar espacio. Los enfoques anteriores de región Win32 y área libre quedan **descartados**.

El candidato actual elimina el HWND hijo y toda API de posicionamiento/recorte. libVLC 3.0.24 decodifica el original por software y entrega RGBA en dos slots de memoria compartida de WebView2; un canvas copia fotogramas completos estables. Los controles, su reloj y la imagen comparten compositor DOM. El ajuste usa toda la ventana con la menor razón de escala, conservando proporción y tocando el primer borde, independientemente de la visibilidad de controles. No cambia ni recodifica el archivo de película.

VLC oficial: `https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/vlc-3.0.24-win64.7z`, SHA-256 `1ed59c09152e78aff84663fa76efab26057716576db74332858810e5ef54ae1f`. El runtime empaqueta 365 archivos (148.561.581 bytes) fijados individualmente por tamaño/hash, con avisos y licencia; caché en D:. El instalador retira solo los recursos propios del motor mpv obsoleto.

La prueba real `real_vlc_hevc_frames_and_controls` aprobó Resident Evil HEVC Main 10: fotogramas RGBA no negros, pista de audio, búsqueda, pausa, volumen y velocidad. Se corrigió un detalle esencial: el callback de formato puede entregar 832 filas codificadas para una imagen visible de 804. Ahora se leen dimensiones visibles y SAR antes de configurar salida. El fotograma inspeccionado conserva 1920×804, sin relleno del códec. Evidencia local: `D:\CocoWork\Media-2026-11-09\vlc-visible-test.log` y `resident-vlc-visible.png`.

Las seis pruebas del adaptador/canvas y TypeScript aprobaron. La suite Rust completa aprobó 303 pruebas, con 8 opt-in omitidas. La nueva ventana de desarrollo está abierta; sigue pendiente la confirmación del anfitrión sobre ajuste completo, subtítulos y reloj flotante en este recorrido integrado. No se considera validado el PC de la amiga ni publicada esta versión.

La suite de código del builder aprobó 538 pruebas, con 31 opt-in omitidas. Se probó también el original de Mickey 17 por su URL publicada con libVLC: 1918×1036 visibles, stride 7680, fotograma RGBA inspeccionado con subtítulo español completo, audio/búsqueda/pausa/volumen/velocidad PASS. Evidencia: `mickey-vlc-retest.log`, `mickey-vlc-visible.png` en el mismo workspace de D:. La primera ejecución detectó una carrera del test al consultar `hasVideo` durante una escritura; la prueba ahora espera una secuencia completa y toma el bloqueo del fotograma antes de leer estado y píxeles. No se cambió el código de reproducción para ocultar el fallo. Esta prueba del SDK no sustituye la comprobación visual integrada pendiente.

Setup 0.6.50: 59.292.940 bytes, SHA-256 `6bd5ecaacc5e3a796d91c796f0fc18d55c1a82c76e62b11d14f250c0ebdb08d9`, candidato `0.6.50-6BD5ECAACC5E`. Verificación Ed25519/Minisign, comentario confiable y feed PASS. QA del candidato: seis pruebas PASS; extracción NSIS final: tres PASS, una inspección del script omitida por limitación de 7-Zip. Se verificaron los 365 archivos del runtime contra el manifiesto, el PE y el MSI. No se ejecutó desinstalación de prueba sobre el perfil real. Los RGBA temporales y el archivo de descarga del runtime se eliminaron tras conservar PNG/logs; el caché reutilizable permanece en D:.

## Entrega de 0.6.50

Publicado en `coco2-channel`: se descargaron y cotejaron por SHA-256 tanto el Setup versionado como `CocoLauncher2-Setup.exe`, y se verificó el feed servido. Latest de Coco 1 permanece en `v0.5.186`. Instalación silenciosa del anfitrión completada con código 0; versión instalada 0.6.50 y los 365 archivos libVLC cotejados contra el manifiesto. `player/mpv.exe` obsoleto ausente. Se cerraron únicamente la aplicación debug y su Vite; se abrió la aplicación normal instalada. Logs: `canvas-release-build.log` y `canvas-publish.log` en el workspace de D:.

Tras la entrega, el anfitrión respondió «Sí, ahora todo se ve bien» a la comprobación de Mickey 17 en la nueva ventana: espacio de imagen correcto, subtítulos completos y reloj al pasar sobre la barra por encima del vídeo. Queda validado visualmente ese recorrido integrado en su PC. La reproducción en el PC de la amiga permanece pendiente; esta confirmación no se extrapola a ese equipo.
