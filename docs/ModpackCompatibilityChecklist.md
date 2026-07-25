# Checklist de compatibilidad para nuevas experiencias Coco

Última revisión: 2026-07-22 (America/Santiago).

Este documento convierte lo aprendido con Iron Lung en una puerta repetible. Agregar un pack al catálogo no significa que esté aprobado: cada experiencia debe conservar su propio lock, evidencia y resultados. La política común vive en el engine; las excepciones justificadas viven en la entrada del pack, nunca como parches invisibles con su nombre hardcodeado.

## 1. Origen, licencia y reproducibilidad

- Registrar página oficial, project ID, file ID, versión exacta y fecha consultada.
- Distinguir explícitamente entre **modpack**, **mundo/mapa**, resource pack y server pack. Si la experiencia anunciada depende de un mundo externo, éste es una dependencia de primera clase: debe tener origen, licencia, versión, hash y política de actualización propios.
- Inspeccionar el archivo fuente: un pack marcado `Map Based` no implica que incluya un `save`. Si no contiene mundo, plantilla, quests o scripts de progresión, no describirlo como minijuego listo para jugar.
- No combinar un mapa creado para una versión posterior con un runtime anterior. La coincidencia de versión/loader se comprueba antes de descargarlo a jugadores y antes de presentarlo como disponible.
- Conservar el ZIP original sólo en caché privada cuando su licencia no permita redistribuirlo.
- Fijar cada archivo por URL de origen permitida, tamaño y SHA-256 en el lock.
- Confirmar que una instalación sin caché y una reanudación parcial producen el mismo árbol administrado.
- Documentar qué puede publicarse en GitHub y qué debe descargarse directamente del autor.

## 2. Runtime y lados cliente/host

- Fijar Minecraft, loader y versión del loader; comprobar el Java elegido realmente por PortableMC.
- Separar `client`, `host` y `all`; no entregar al cliente utilidades exclusivas del host.
- Verificar número de JAR y tamaño final por rol.
- Probar preparación fría, segunda preparación, cambio host→cliente→host y reparación de un archivo corrupto.
- Confirmar memoria recomendada con el hardware real; no copiar ciegamente la recomendación del autor.
- Antes de una prueba jugable local, exigir memoria física libre suficiente; abortar antes de Java es preferible a validar un arranque bajo paginación extrema.

## 3. Auditoría de fricción externa

Buscar antes del primer juego real:

- launchers, auto-updaters o descargas propias;
- diálogos de actualización, onboarding, TOS, login, telemetría o anuncios;
- mods sociales que dupliquen la red/hosting de Coco;
- ventanas externas que bloqueen el arranque sin aparecer en el log principal.

Un archivo sólo se excluye después de probar que ninguna dependencia declarada lo exige. La exclusión se registra en `excludedPaths` con motivo y evidencia. Iron Lung estableció el patrón: Essential era opcional, abría actualización/onboarding y Coco ya cubría su función de red; por eso se excluyó en el catálogo, no mediante una condición `if Iron Lung`.

## 4. Instalación y datos persistentes

- Overrides y assets sólo pueden escribir rutas relativas seguras.
- Si existe mundo inicial, instalar una copia inmutable como plantilla y crear desde ella el mundo de cada partida; nunca reutilizar o sobrescribir silenciosamente una partida previa.
- Verificar en juego el punto de aparición, modo, inventario, estructuras iniciales y reglas que constituyen la experiencia. Llegar al menú o generar un mundo vanilla sólo aprueba el runtime, no el diseño jugable.
- `saves`, `playerdata`, estadísticas, avances y Distant Horizons nunca pertenecen al conjunto administrado.
- Decidir explícitamente qué archivos se preservan (por ejemplo `options.txt`) y cuáles se reemplazan.
- Probar actualización y retiro de mods con backup y rollback provocado.
- Abrir con Minecraft real y confirmar que `servers.dat` se lee; no basta con que un escritor NBT propio acepte su salida.

## 5. Juego, progresión y servidor

- Crear o importar el mundo con el método que espera el pack.
- Determinar si requiere LAN integrada o servidor dedicado y si el tiempo/progresión avanza sin jugadores.
- Abrir LAN, comprobar puerto fijo, anuncio `preparing→ready`, autoingreso de un cliente y reconexión.
- Jugar el tramo inicial suficiente para descubrir scripts, quests, cinemáticas, dimensiones y recetas rotas.
- Cerrar y reabrir el mismo mundo; comprobar inventario, avances, quests y configuración.

## 6. Identidad y red

- Probar identidad local estable y Microsoft real por separado.
- Probar la detección con un perfil TLauncher real si se pretende cubrirlo.
- Confirmar que un segundo nodo ZeroTier obtiene autorización, ruta e ingreso; una prueba loopback del host no reemplaza esto.
- Verificar que no se abre e4mc ni otro túnel secundario salvo contingencia deliberada.

## 7. UX, diagnóstico y publicación

- Todas las tareas largas deben usar las etapas visibles de Coco; el pack no puede abrir un descargador oculto.
- Descargas: archivo N/total, nombre, caché/descarga, MB, velocidad, ETA y verificación.
- Instalación: archivo N/total y resultado (`preservado`, `ya verificado`, `instalado` o retiro).
- Runtime: heartbeat con intento y tiempo transcurrido aunque Forge/Mojang no entregue porcentaje.
- Arranque: Coco confirma que apareció Java para esa instancia antes de ocultarse.
- Provocar al menos un fallo de hash, disco/red o runtime y comprobar el TXT correlacionado del Escritorio.
- Mantener `releaseStatus=development` hasta aprobar instalación fría, mundo real, host+cliente, identidades, migración y recuperación.

## Ficha mínima por experiencia

La documentación de cada pack debe incluir:

| Evidencia | Resultado |
|---|---|
| Fuente/licencia/lock | Pendiente o enlace/fecha/hash |
| Runtime Java/Minecraft/loader | Pendiente o versiones observadas |
| Archivos host/cliente | Pendiente o conteos/tamaños |
| Exclusiones y dependencias | Ninguna o lista con justificación |
| Instalación fría/reanudación/reparación | Pendiente/aprobado con tiempos |
| Arranque y prompts externos | Pendiente/aprobado |
| Mundo y progresión | Pendiente/aprobado |
| LAN, autoingreso y reconexión | Pendiente/aprobado |
| Identidad local/Microsoft | Pendiente/aprobado |
| Segundo equipo ZeroTier | Pendiente/aprobado |
| Diagnóstico provocado | Pendiente/aprobado y Failure ID |
| Decisión de publicación | development/approved y responsable |
