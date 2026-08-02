# Checklist de compatibilidad para nuevas experiencias Coco

Última revisión: 2026-07-26 (America/Santiago).

Agregar un pack al catálogo no significa que esté aprobado: cada experiencia debe conservar su propio lock, evidencia y resultados. La política común vive en el engine; las excepciones justificadas viven en la entrada del pack, nunca como parches invisibles con su nombre hardcodeado.

## 1. Origen, licencia y reproducibilidad

- Registrar página oficial, project ID, file ID, versión exacta y fecha consultada.
- Distinguir explícitamente entre **modpack**, **mundo/mapa**, resource pack y server pack. Si la experiencia anunciada depende de un mundo externo, éste es una dependencia de primera clase: debe tener origen, licencia, versión, hash y política de actualización propios.
- Inspeccionar el archivo fuente: un pack marcado `Map Based` no implica que incluya un `save`. Si no contiene mundo, plantilla, quests o scripts de progresión, no describirlo como minijuego listo para jugar.
- No combinar un mapa creado para una versión posterior con un runtime anterior. La coincidencia de versión/loader se comprueba antes de descargarlo a jugadores y antes de presentarlo como disponible.
- Conservar el ZIP original sólo en caché privada cuando su licencia no permita redistribuirlo.
- Fijar cada archivo por URL de origen permitida, tamaño y SHA-256 en el lock. Importar tanto dependencias requeridas como opcionales y conservar `manifestRequired` como evidencia.
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

Un archivo sólo se excluye por petición explícita y después de probar que ninguna dependencia declarada lo exige. Las excepciones de un pack se registran en `excludedPaths`, no mediante un `if` con su nombre. Essential es la única excepción global decidida por el producto: todo pack debe instalarse sin sus JAR, overrides ni runtime generado. Ninguna otra dependencia opcional se omite por defecto.

## 4. Instalación y datos persistentes

- Overrides y assets sólo pueden escribir rutas relativas seguras.
- Si existe mundo inicial, instalar una copia inmutable como plantilla y crear desde ella el mundo de cada partida; nunca reutilizar o sobrescribir silenciosamente una partida previa.
- Verificar en juego el punto de aparición, modo, inventario, estructuras iniciales y reglas que constituyen la experiencia. Llegar al menú o generar un mundo vanilla sólo aprueba el runtime, no el diseño jugable.
- `saves`, `playerdata`, estadísticas, avances y Distant Horizons nunca pertenecen al conjunto administrado.
- Decidir explícitamente qué archivos se preservan (por ejemplo `options.txt`) y cuáles se reemplazan.
- Preservar los shaders, efectos internos y configuraciones visuales que entregue el pack. No añadir, seleccionar, desactivar ni retirar un shader por una regla genérica: cualquier intervención visual adicional debe pertenecer explícitamente a esa experiencia y tener evidencia y prueba física.
- Para cambios comunes a todos los jugadores de una sola experiencia, declarar mods adicionales en `experiences[].files`, retiros en `pack.excludedPaths`, archivos de settings completos en `preferences.managedFiles` y selección de shader en `preferences.shader`. Usar `writeMode: "initialize"` solo cuando el mod de la experiencia debe conservar cambios posteriores, como coordenadas de un mapa; verificar que una segunda experiencia no reciba ninguno de esos cambios.
- Probar actualización y retiro de mods con backup y rollback provocado.
- Abrir con Minecraft real y confirmar que `servers.dat` se lee; no basta con que un escritor NBT propio acepte su salida.

## 5. Juego, progresión y servidor

- Crear o importar el mundo con el método que espera el pack.
- Determinar si requiere LAN integrada o servidor dedicado y si el tiempo/progresión avanza sin jugadores.
- Abrir LAN, comprobar puerto fijo, anuncio `preparing→ready`, autoingreso de un cliente y reconexión.
- Jugar el tramo inicial suficiente para descubrir scripts, quests, cinemáticas, dimensiones y recetas rotas.
- Cerrar y reabrir el mismo mundo; comprobar inventario, avances, quests y configuración.

## 6. Identidad y red

- Probar una identidad local estable y confirmar que el mismo nombre conserva UUID, inventario y avances.
- Declarar exactamente una variante oficial de CustomSkinLoader compatible con la versión de Minecraft; una versión desconocida debe quedar bloqueada, no inferirse.
- Probar clic y arrastre con PNG 64x64 y 64x32, rechazo de dimensiones inválidas, vista previa de cabeza y copia a `CustomSkinLoader/LocalSkin/skins`.
- Probar también un jugador que no seleccione skin: debe conservar la apariencia predeterminada y abrir Minecraft únicamente con un nombre válido.
- Con dos clientes reales, cambiar una skin, reiniciar/reingresar y comprobar que ambos reciben el mismo SHA-256. Repetir una vez con Coco original para cubrir `NetworkOnly`.
- Si existe `voicechat`, comprobar la metadata interna aunque el JAR tenga nombre `asset_*`, ausencia de onboarding, dispositivos default, `VOICE`, AGC, denoiser, `muted=false` y conexión UDP 25565 entre dos equipos cuando se use el servidor integrado con LAN Coco.
- No generar configuraciones para Plasmo Voice u otro producto sin un adaptador y claves oficiales comprobadas.
- Probar la detección con un perfil TLauncher real si se pretende reutilizar automáticamente su nombre.
- Confirmar que ningún estado, log o diagnóstico copia tokens de launchers.
- Verificar el archivo real de MCWiFiPnP: `OnlineMode=false`, `EnableUUIDFixer=true`, `UseUPnP=false` y puerto 25565. Los nombres kebab-case no son válidos.
- Para versiones sin MCWiFiPnP compatible, mantener el pack bloqueado hasta contar con otro adaptador físicamente probado. Si se usa Lan Server Properties 1.0 en Forge 1.12.2, fijar el JAR por hash sólo para el host, exigir TCP 25565 y documentar que `Online Mode` debe quedar en `OFF`; no escribir ni aceptar un `mcwifipnp.json` ficticio.
- Confirmar que un segundo nodo ZeroTier obtiene autorización, ruta e ingreso; una prueba loopback del host no reemplaza esto.
- Verificar que no se abre e4mc ni otro túnel secundario salvo contingencia deliberada.

## 7. UX, diagnóstico y publicación

- Todas las tareas largas deben usar las etapas visibles de Coco; el pack no puede abrir un descargador oculto.
- Ejecutar `Probar-CocoLauncher-Amigo-SinIdentidad.cmd` y `Probar-CocoLauncher-Amigo-ConIdentidad.cmd` para revisar el cliente exacto: tarjeta unificada siempre visible, progreso automático, pausa final sólo si el nombre no fue confirmado y skin completamente opcional.
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
| Identidad local, UUID y migración | Pendiente/aprobado |
| Segundo equipo ZeroTier | Pendiente/aprobado |
| Diagnóstico provocado | Pendiente/aprobado y Failure ID |
| Decisión de publicación | development/approved y responsable |
