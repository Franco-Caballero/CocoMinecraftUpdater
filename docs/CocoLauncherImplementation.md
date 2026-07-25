# Coco Launcher — diseño, implementación y estado

Última revisión: 2026-07-22 (America/Santiago).

## Qué estamos construyendo

Coco Updater incorporará, mediante el mismo canal estable y el mismo EXE que ya tienen los amigos, **Coco Launcher para experiencias nuevas**. En esos packs el jugador abrirá un acceso directo único; Coco actualizará su engine, descubrirá la única partida activa, preparará una instancia aislada con la versión/loader/Java/pack correctos, preparará ZeroTier y abrirá Minecraft conectado directamente. **Coco original queda fuera de ese launcher:** conserva `%APPDATA%\.minecraft` y se abre con el launcher oficial o TLauncher exactamente como hoy.

La versión launcher **aún no está publicada**. Producción continúa en Coco Pack 0.5.47 y el mundo `coco` no se ha movido ni modificado.

Estado de esta rama:

| Área | Estado comprobable |
|---|---|
| Migración desde el EXE existente y acceso directo | Implementada, conectada a la apertura manual del mismo EXE y cubierta por regresiones. |
| Coco original | Flujo externo congelado: no aparece en el selector, Coco Launcher no lo abre, no lo autoingresa y no modifica su instancia al abrirse. Bridge/Updater conservan el funcionamiento publicado. |
| Política de una sola sesión y selección automática | Congelada en el catálogo y validada por prueba. |
| Backend Minecraft | PortableMC 5.0.4 fijado por release, commit, tamaño, hash del ZIP y hash del EXE; instalador transaccional implementado. |
| Fabric actual y Forge legacy | Instalaciones secas reales aprobadas para Fabric 0.19.3/Minecraft 26.1.2/Java 25 y Forge 14.23.5.2860/Minecraft 1.12.2/Java 8. |
| Detección premium/offline | Implementada sin leer ni copiar tokens; resolución automática cuando la evidencia es inequívoca y pregunta sólo cuando es ambigua. |
| Argumentos de instancia y autoingreso | Implementados y probados para Fabric y Forge; Iron Lung abrió y ejecutó Quick Play hasta `10.77.37.1:25565` desde una raíz fría. |
| Servicio de sesión y UI | Implementados: selector desplazable sólo host, cliente sin selector, `offline/preparing/ready/stopping`, verificación real de escucha, heartbeat, expiración y cierre limpio. |
| Instancias y recuperación | Instalación transaccional, caché por hash, backups, opciones preservadas y `servers.dat` inicial implementados. |
| Iron Lung | Runtime aprobado parcialmente: lock oficial, instalación fría, reintentos, autorreparación, arranque, autoingreso y `servers.dat` leído por Minecraft. **Experiencia jugable bloqueada:** el ZIP no incluye mundo, quests ni guion; el mapa externo enlazado sólo se publica para 1.21.8–1.21.11 mientras el pack usa 1.20.1. Un mundo aleatorio/LAN funcionó, pero no contiene el submarino. |
| Progreso y soporte | Implementados Run ID compartido, timeline JSONL, etapas visibles, progreso por bytes/archivos, heartbeat de Forge/Java y TXT del Escritorio clasificado y probado sin filtrar tokens. |

## Qué ve exactamente el usuario

La misma ventana de la reina permanece como superficie de estado. Su título usa `ETAPA N/10`, la descripción dice qué se está haciendo y la barra avanza con trabajo medible. Cada ejecución muestra un Run ID corto; el ID completo queda en logs y diagnósticos.

### Amigo: no hay experiencia especial online

1. Hace doble clic en el acceso directo **Coco Launcher**. Una copia antigua del EXE se autoactualiza y deriva al EXE canónico; no se crea una segunda instalación junto al archivo de Descargas.
2. Ve `ETAPA 1/10 | INICIANDO COCO LAUNCHER`, versión del engine e ID de ejecución.
3. Ve la comprobación/actualización del engine y `ETAPA 2/10 | PREPARANDO LA RED PRIVADA`. Si Windows necesita instalar o reparar ZeroTier, aparece el UAC normal; el helper queda oculto pero la reina muestra su etapa y cuenta regresiva.
4. Ve `ETAPA 3/10 | BUSCANDO PARTIDA COCO`. Coco consulta tres veces para no interpretar un instante de arranque del host como offline.
5. Si no hay otra experiencia, ve `NO HAY EXPERIENCIA ESPECIAL ONLINE`; Coco ejecuta el sincronizador clásico sobre Coco original.
6. Termina en `ETAPA 10/10 | COCO ORIGINAL LISTO`. Coco **no** abre ese Minecraft: el amigo lo sigue abriendo con Launcher oficial/TLauncher, y Bridge continúa comprobándolo dentro del juego como antes.

### Amigo: existe una experiencia administrada

1. Los primeros tres pasos son iguales. No aparece selector: sólo puede existir una sesión online y Coco la elige.
2. Si el host todavía está preparando, Coco instala por adelantado y espera `ready`; no abre un cliente destinado a fallar.
3. Durante el pack muestra archivo `N/total`, nombre, si vino de caché o red, MB descargados, velocidad, ETA y confirmación SHA-256. La barra usa bytes totales fijados por el lock.
4. Durante la aplicación muestra archivo `N/total` y `preservado`, `ya verificado`, `instalado` o retiro. Mundo, `playerdata` y datos persistentes están fuera del área administrada. Ante fallo se ejecuta rollback.
5. Durante PortableMC/Forge/Java muestra intento, tiempo transcurrido y heartbeat cada segundo. Las descargas válidas sobreviven a los cuatro reintentos.
6. La identidad guardada o inequívoca se usa silenciosamente. Un TLauncher free claro aporta su nombre sin abrir TLauncher. Microsoft sólo abre el navegador oficial si Coco aún no posee sesión; una máquina ambigua pregunta una sola vez y guarda la decisión.
7. Ve `ETAPA 8/10 | ABRIENDO MINECRAFT`. Coco espera hasta detectar un `java/javaw` cuya línea de comandos contiene exactamente la raíz de esa instancia.
8. Ve `ETAPA 9/10 | CONECTANDO AUTOMATICAMENTE`; entonces Coco se oculta. La pantalla roja `Forge loading` pertenece a Minecraft y es esperable. Quick Play apunta a `10.77.37.1:25565`; no se elige servidor ni pack.
9. Coco permanece oculto supervisando PortableMC y sus pipes hasta cerrar Minecraft. Si el proceso termina con error, Coco reaparece y entrega el diagnóstico; si termina bien, Coco se cierra.

### Host

1. Ve bootstrap, red e identidad con el mismo feedback.
2. Como único host, ve el selector desplazable de experiencias; sus amigos nunca lo ven.
3. Al elegir un pack se publica `preparing`, se inicia el servicio de sesión y se ejecutan descarga, instalación, runtime y apertura con el mismo detalle anterior.
4. Coco espera el Java de la instancia y muestra `ETAPA 9/10 | MINECRAFT ABIERTO`: el host entra/crea el mundo y pulsa **Abrir en LAN**. Esta intervención sigue siendo necesaria para experiencias LAN; Coco no elige un mundo a ciegas.
5. Al detectar TCP 25565 publica `ready` y muestra `ETAPA 10/10 | PARTIDA ONLINE`. Desde entonces los amigos que abran Coco entran automáticamente.
6. Al cerrar Minecraft, Coco retira la sesión y el servicio, vuelve al selector y permite iniciar otra experiencia.

### Si algo falla

La reina conserva la etapa y causa amigable, y añade `Envia por Discord: CocoUpdater-error-AAAA...txt`. Ese archivo del Escritorio contiene:

- Failure ID y Run ID correlacionados con todos los logs;
- última etapa/progreso y timeline cronológico JSONL;
- experiencia, rol, versión e instancia afectada;
- excepción completa, stack e invocación;
- colas de engine, PortableMC y `latest.log` de esa instancia;
- estado administrado, ZeroTier, puertos, procesos, Windows, RAM, disco y caché;
- clasificación (`PACK-INTEGRITY`, `RUNTIME`, `IDENTITY`, `ZEROTIER`, etc.) y siguiente acción recomendada.

No copia contraseñas, cookies, `accessToken` ni la base Microsoft. Una regresión dinámica crea un informe real, comprueba sus marcadores y prueba que un token señuelo en `identity.json` no aparezca. La política para aplicar esta misma auditoría a próximos packs está en [ModpackCompatibilityChecklist.md](ModpackCompatibilityChecklist.md).

## Respuesta exacta sobre premium y free

### Lo que Coco sí puede saber automáticamente

Coco puede inspeccionar **metadatos no secretos** del computador:

1. Una decisión Coco guardada anteriormente siempre prevalece.
2. Si el perfil seleccionado de TLauncher declara `free`/`tlauncher`, Coco elige identidad local y reutiliza automáticamente el nombre válido.
3. Si TLauncher declara una cuenta Microsoft/Mojang, Coco elige la ruta Microsoft.
4. Si existen perfiles del launcher oficial y no hay una señal contradictoria, Coco intenta Microsoft.

Coco sólo lee tipo, cuenta seleccionada y nombre. No devuelve, registra, copia ni transforma `accessToken`, contraseña o cookies. El archivo propio `identity.json` contiene únicamente modo, nombre/UUID confirmados, origen de la decisión y fecha.

### Lo que ningún launcher puede adivinar de forma infalible

La presencia del launcher oficial no prueba por sí sola que la sesión siga válida ni que esa cuenta posea Minecraft Java. La prueba definitiva la entrega Microsoft/Xbox/Minecraft durante la autenticación. Del mismo modo, una máquina nueva sin perfiles no permite deducir si la persona desea una identidad Microsoft o local.

Por eso el UX definitivo no comienza preguntando “¿premium o free?” a todos. Es este:

```text
Abrir Coco
  |
  +-- decisión Coco ya guardada ------------------> usarla silenciosamente
  |
  +-- TLauncher dice claramente free ------------> usar nombre local silenciosamente
  |
  +-- perfil local indica Microsoft -------------> intentar Microsoft automáticamente
  |                                                   |
  |                                                   +-- sesión Coco válida: nada visible
  |                                                   +-- falta sesión: navegador Microsoft una vez
  |
  +-- evidencia ausente o contradictoria ----------> una única pregunta
                                                        “Continuar con Microsoft”
                                                        “Usar identidad local”
```

En el caso ambiguo sí es indispensable una elección humana: cualquier automatismo cambiaría potencialmente la identidad/UUID. Esa elección se guarda y no reaparece en cada pack. Si elige identidad local, Coco pide el nombre sólo si tampoco pudo obtener uno válido.

Si Coco eligió Microsoft por evidencia local y el login demuestra que la cuenta no posee Java, se explica el resultado y se ofrece cambiar explícitamente a identidad local. **Nunca** se cae silenciosamente de Microsoft a offline: eso puede crear otro UUID y separar inventario, avances o permisos.

### Qué ve una cuenta Microsoft

PortableMC mantiene su propia base de sesión bajo la raíz privada de Coco. En el primer uso que realmente lo requiera, abre el flujo web oficial de Microsoft. El jugador nunca escribe su contraseña dentro de Coco. El navegador puede reconocer una sesión ya abierta y reducirlo a elegir/confirmar la cuenta, pero Microsoft puede exigir contraseña, consentimiento o MFA; no es técnicamente honesto prometer cero clics esa primera vez.

Después, PortableMC renueva la sesión y Coco lanza silenciosamente mientras siga autorizada. No se importan tokens del launcher oficial porque no existe un mecanismo soportado y seguro para apropiarse de la sesión privada de otra aplicación.

### Qué ve una cuenta local/no-premium

Si TLauncher ya declara inequívocamente una cuenta free seleccionada y un nombre válido, no ve ninguna pregunta: Coco guarda esa identidad local y lanza PortableMC con ese nombre. TLauncher no participa ni se abre.

Esto funciona porque el servidor Coco actual usa `online-mode=false` y UUID Fixer. No permite entrar en servidores que exigen licencia. La identidad local debe permanecer estable y el servidor debe proteger nombres/whitelist antes de considerar segura una comunidad no confiable.

### Por qué TLauncher permite free y Prism oficial no

No es una capacidad mágica de TLauncher. TLauncher construye deliberadamente una sesión local sin autenticar; esa sesión sólo entra a servidores cuya verificación de licencia está deshabilitada. Su propia documentación distingue ese caso y aclara que TLauncher Premium tampoco equivale a una licencia oficial.

Prism Launcher oficial permite crear una entrada offline, pero su código de lanzamiento busca una cuenta que posea el juego; sin ella termina en modo demo. Usar Prism para ambos grupos requeriría mantener un fork que cambie esa política. Coco no hará pasar un fork como Prism oficial.

## Backend decidido: PortableMC

Se descartó CmlLib.Core como base primaria: su release investigado era de enero de 2025 y sólo afirmaba pruebas hasta Minecraft 1.21, evidencia insuficiente para 26.1.2. Prism permanece como referencia de UX, no como motor.

PortableMC 5.0.4 fue publicado el 2026-06-12 y soporta desde CLI:

- versiones Mojang;
- Fabric, Forge, NeoForge, Quilt y loaders legacy;
- búsqueda/descarga de Java adecuado;
- autenticación Microsoft o identidad local;
- raíces compartidas e instancias separadas;
- `--join-server` y corrección de Quick Play para versiones anteriores.

La auditoría local comprobó:

```text
release       v5.0.4
commit        0718735
ZIP SHA-256   4482bb5325f9e09573ebe578ff5e9984e5205c45962cbc08d2524e1b51ab6315
EXE SHA-256   0d33f459bc9182269ac9fc1e5299ec5d2243798ee34ed6cea44a88d097642025
Fabric        fabric:26.1.2:0.19.3, instalación seca completa aprobada
Forge         forge::1.12.2-14.23.5.2860, instalación seca completa aprobada
```

El ejecutable oficial no lleva Authenticode. El release publica una firma separada —también fijada por tamaño y SHA-256— y la huella PGP `f659b0f0b84a26cac635d72948caee8dc3456b2f`; en tiempo de ejecución Coco no confía en “latest”, nombre o TLS solamente: exige tamaño y hash exactos del ZIP, bloquea Zip Slip, extrae a stage, exige tamaño/hash exactos del EXE y ejecuta `--version` para comprobar versión y commit antes de conmutar. El Publisher deberá agregar verificación criptográfica de la firma/procedencia antes de actualizar esos pines.

Fuentes:

- [PortableMC: repositorio oficial](https://github.com/theorzr/portablemc)
- [PortableMC v5.0.4](https://github.com/theorzr/portablemc/releases/tag/v5.0.4)
- [Documentación oficial de PortableMC](https://docs.rs/portablemc/latest/portablemc/)
- [Restricción offline observada en Prism oficial](https://github.com/PrismLauncher/PrismLauncher/blob/8ae894c7b1f74a58405a2dabd5614dae4ef3f08c/launcher/ui/pages/global/AccountListPage.cpp#L137-L149)
- [TLauncher: sesión inválida y servidores sin verificación](https://tlauncher.org/en/invalid-session.html)
- [TLauncher Premium no es licencia Minecraft](https://tlauncher.org/en/premium.html)
- [Microsoft: login interactivo y SSO mediante WAM](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-acquire-token-wam)

### Evaluación de FreeSM Launcher 2.2.2

FreeSM sí fue auditado después de elegir PortableMC. No es un launcher abandonado: la versión 2.2.2, publicada el 2026-07-13 y fijada al commit `6d415912b11792ff0bf8c966bf8b819585862bed`, está basada en Prism Launcher 11.0.3. Su diferencia central respecto de Prism oficial es eliminar la restricción para cuentas offline; además ofrece Ely.by/authlib-injector, GUI madura, importación y administración de CurseForge/Modrinth/FTB, instancias, Java, logs y reparación.

Su CLI heredada es mejor de lo que inicialmente se había asumido: admite `--launch <instancia>`, `--server <host:puerto>`, `--profile <cuenta>` y FreeSM agrega `--offline <nombre>`. Por tanto puede abrir una instancia existente, entrar automáticamente y lanzar una identidad local sin crear antes una cuenta persistente.

No obstante, no reemplaza mejor al backend Coco actual:

- en una raíz limpia ejecuta el Setup Wizard antes de la acción solicitada; si no existe una cuenta válida agrega una página de login incluso cuando se proporcionó `--offline`;
- `--import` termina en `NewInstanceDialog`, por lo que importar el primer pack no es headless ni cero intervención;
- no descubre la sesión Coco, no administra ZeroTier/firewall, no distingue host/cliente, no aplica overlays LAN ni preserva el updater/Bridge original;
- para evitar los diálogos Coco tendría que escribir formatos internos de Prism/FreeSM —acoplamiento frágil— o mantener un fork C++/Qt GPL-3.0 de un proyecto grande;
- su ventaja de navegador de packs no ayuda al cliente, porque Coco debe instalar exactamente la versión elegida por el host sin mostrarle catálogos ni decisiones;
- no ofrece una mejora inherente de FPS/TPS: después del lanzamiento Minecraft ejecuta el mismo Java, loader, mods y argumentos. Si el GUI queda residente puede consumir más recursos que un backend CLI pequeño, aunque el impacto frente al propio modpack normalmente sería secundario.

Sí deja dos ideas útiles: su soporte actual de CurseForge puede servir como referencia ante cambios de API/CDN y sería una herramienta cómoda para que el Publisher explore/importara packs. También puede mantenerse como backend alternativo experimental si PortableMC falla en una versión futura. No se adopta para clientes sin una prueba A/B que demuestre instalación headless, primera ejecución sin wizard, lanzamiento Microsoft/offline y menor mantenimiento.

Fuentes de esta evaluación:

- [Repositorio oficial de FreeSM](https://github.com/FreesmTeam/FreesmLauncher)
- [Release FreeSM 2.2.2](https://github.com/FreesmTeam/FreesmLauncher/releases/tag/2.2.2)
- [CLI FreeSM: `--server`, `--profile` y `--offline`](https://github.com/FreesmTeam/FreesmLauncher/blob/2.2.2/launcher/Application.cpp#L317-L330)
- [Setup Wizard de FreeSM](https://github.com/FreesmTeam/FreesmLauncher/blob/2.2.2/launcher/Application.cpp#L1225-L1313)
- [Importación interactiva de instancias](https://github.com/FreesmTeam/FreesmLauncher/blob/2.2.2/launcher/ui/MainWindow.cpp#L893-L924)
- [CLI oficial heredada de Prism](https://prismlauncher.org/wiki/getting-started/command-line-interface/)

## Arquitectura local

```text
%LOCALAPPDATA%\CocoMinecraftUpdater\
  CocoUpdater.exe                         # EXE canónico, renombrado visualmente Coco Launcher
  latest.json / engine\<versión>\        # canal compatible con 0.5.47
    launcher\catalog.json                # catálogo ligado a esa versión de engine
    launcher\experiences\*.lock.json    # procedencia y hashes de cada pack
  launcher\
    identity.json                         # sin secretos
    accounts\portablemc_msa.json          # sesión del backend; privada
    runtime\portablemc\5.0.4\
    shared\                               # assets, libraries, versions y JVM deduplicados
    session\                              # estado efímero
  downloads\                              # objetos por SHA-256
  backups\legacy-launchers\              # copias viejas, recuperables
  logs\

%APPDATA%\.minecraft\                     # Coco original permanente; launcher habitual
%APPDATA%\CocoMinecraft\experiences\
  iron-lung\                              # mods/config/world propios
  <otra-experiencia>\
```

El runtime, catálogo y engine pueden reemplazarse; los mundos, screenshots, opciones personales y datos generados viven fuera de esas carpetas reemplazables.

## Flujo de Coco original: deliberadamente sin cambios

Para jugar el mundo original nadie abre Coco Launcher:

```text
Host: launcher habitual -> Minecraft Coco original -> mundo coco -> Abrir en LAN
Amigo: launcher habitual -> Minecraft Coco original -> Multijugador -> Coco Minecraft
```

El Bridge y Coco Updater continúan comprobando red y versión como en producción 0.5.47. Si una persona ejecuta el EXE mientras el Minecraft original compatible está abierto, se conserva directamente el flujo updater. Si lo abre sin Minecraft, Coco consulta primero la sesión: una experiencia administrada activa usa el flujo nuevo; sin ella sincroniza Coco original y termina indicándole que lo abra con su launcher habitual. `coco-original` permanece en el catálogo como metadato de compatibilidad/versionado, marcado `external-launcher`, pero no se ofrece como botón, no puede publicarse por el servicio de sesión y no puede lanzarse mediante PortableMC.

## Flujo completo de todas las entidades

### A. El host agrega una experiencia

1. El Publisher importa el manifiesto oficial del pack a un stage, registra procedencia/licencia y resuelve Minecraft, loader, Java, cliente, servidor, configs, scripts, resource packs y shaders.
2. Normaliza cada archivo administrado con ruta relativa, tamaño, SHA-256, rol y política (`replace`, `merge`, `preserve` o `migrate`).
3. Instala cliente y server pack en raíces temporales; nunca prueba sobre `%APPDATA%\.minecraft` ni sobre `saves\coco`.
4. PortableMC instala en seco el runtime exacto. Las pruebas arrancan cliente/host en un entorno desechable y comprueban compatibilidad, puerto y autoingreso.
5. El Publisher sólo publica el catálogo después de validar hashes, roles, migración desde la versión pública anterior y todas las regresiones del updater/red.
6. Al abrir Coco, el host ve el nuevo pack como disponible. Los clientes todavía no eligen nada.

### B. El host inicia una partida

1. El host abre **Coco Launcher**.
2. Coco se autoactualiza y consulta el catálogo.
3. Sólo el host ve y usa el selector de experiencias administradas. Coco original no aparece. Si ya existe una sesión administrada, debe terminarla primero; el catálogo exige máximo una.
4. Coco publica estado `preparing` con `experienceId`, `packVersion` y un identificador efímero; todavía no anuncia un endpoint listo.
5. Prepara ZeroTier, runtime, instancia cliente/host y mundo propio de esa experiencia.
6. Para LAN integrada, abre Minecraft sin intentar conectarlo contra sí mismo. El host entra o crea el mundo y usa **Abrir en LAN**. Coco preconfigura los mundos de esa instancia con TCP 25565, `online-mode=false`, UUID Fixer y UPnP desactivado; cuando el puerto responde cambia a `ready`. El tiempo del mundo no corre mientras permanece en el menú.
7. Para server pack dedicado, Coco inicia el servidor sólo en ese momento, espera su readiness real y entonces cambia a `ready`. No se deja tickeando antes por comodidad.
8. Al salir/cerrar el host, Coco retira la sesión o la deja expirar inmediatamente. No queda otra experiencia “activa” por haber usado antes el mundo original.

### C. Un amigo abre Coco cuando el host está offline

1. Coco se autoactualiza, repara el acceso directo y ZeroTier si corresponde.
2. Consulta tres veces de forma breve al servicio de sesión del host para no confundir un arranque simultáneo con ausencia real.
3. Si continúa `offline`, ejecuta el sincronizador clásico sobre Coco original: detecta rol, descarga el release publicado y verifica todos los mods como antes.
4. La UI termina en **“Coco original listo”**. No muestra selector, no abre Minecraft y no descarga una experiencia que nadie está jugando.
5. El amigo abre después su launcher oficial/TLauncher y entra por la lista de servidores. Dentro del juego, Bridge conserva el chequeo de versión y el cierre/actualización automática si quedó atrasado.

### D. Un amigo abre Coco durante `preparing`

1. Coco obtiene la única experiencia anunciada; el amigo no la elige.
2. Comienza a descargar/verificar en paralelo esa instancia mientras el host carga.
3. Resuelve identidad automáticamente según la política anterior.
4. Muestra progreso y “El host está preparando Iron Lung”; no lanza un cliente condenado a fallar.
5. Al recibir `ready`, valida que `experienceId` y `packVersion` coincidan y comprueba TCP.

### E. Un amigo abre Coco durante `ready`

1. Coco selecciona automáticamente la única sesión.
2. Comprueba espacio, catálogo, archivos, loader, Java, identidad y ZeroTier.
3. Si faltan archivos, los instala transaccionalmente; los intactos se reutilizan por hash.
4. En la primera instalación escribe `servers.dat` como recuperación. Si el jugador ya tiene uno, nunca lo reemplaza.
5. Ejecuta PortableMC con raíz compartida, `--mc-dir` aislado, identidad fijada y `--join-server`/puerto.
6. PortableMC verifica runtime y abre Minecraft. En versión moderna usa Quick Play; en legacy aplica `--server`/`--port` mediante su corrección integrada.
7. El jugador aterriza en el servidor sin ver TLauncher, launcher oficial ni lista de servidores.

Si la sesión desaparece durante la preparación, Coco detiene el autoarranque y conserva la descarga válida para la próxima vez. Si el servidor cae después de lanzar, Minecraft muestra su error normal y la entrada en `servers.dat` permite reintentar.

## Servicio de sesión única

No basta con “entrar primero al mundo original”: para saber qué pack preparar antes de abrir Minecraft hace falta una señal externa al juego. La implementación usa un servicio mínimo del host accesible sólo por ZeroTier.

Estados válidos:

```text
offline     no hay partida
preparing   experiencia elegida; pack/host aún no listo
ready       endpoint probado y versión congelada
stopping    ya no se aceptan autoarranques
```

Cada respuesta contiene schema, sessionId, estado, experienceId, packVersion, host, puerto, timestamps y expiración. El cliente rechaza schema desconocido, experiencia no presente en su catálogo, puerto inválido, versión distinta o respuesta expirada. La regla administrada de Firewall limita el puerto de control a `10.77.37.0/24` y a la interfaz ZeroTier. La falta de servicio equivale a `offline`, nunca a elegir Coco original por suposición.

## Packs, archivos y mundos

Una experiencia incluye más que `mods`:

```text
Minecraft + loader + Java
mods y dependencias
config, defaultconfigs, scripts y kubejs
resourcepacks, shaderpacks y datapacks
pack cliente y server pack
modo de hosting y endpoint
mundo propio y reglas de preservación
```

Son reemplazables sólo si el manifiesto los administra. Se preservan por defecto `saves`, screenshots, logs, crash reports, JourneyMap, Distant Horizons, opciones/keybinds y cuentas. Una experiencia nunca puede escribir fuera de su raíz declarada.

El sistema actual de objetos por SHA-256 se generaliza porque permite deduplicar mods/configs entre packs y evita redescargas. No se realoja contenido de CurseForge sólo porque pueda descargarse: el Publisher registra permiso y origen; cuando la licencia no permita redistribuir, Coco usa el archivo oficial o una importación autorizada.

## Iron Lung: primera experiencia implementada

La experiencia indicada es [The Iron Lung Experience en CurseForge](https://www.curseforge.com/minecraft/modpacks/iron-lung-exploration-modpack). La importación auditada fijó:

```text
Project ID                  1486366
File ID                     7762569
Archivo                     RoseRocket's Iron Lung Modpack 1.0
Minecraft / loader          1.20.1 / Forge 47.4.10
Licencia                    All Rights Reserved
ZIP oficial                 1.015.026 bytes
SHA-256 ZIP                 25989d1fa444e74cde10375e2b14cea5273d688f0a6e221f830ee158f87a7a21
Assets requeridos           78: 69 mods, 8 resource packs, 1 shader pack
Tamaño assets               363.484.401 bytes
Overrides efectivos         273 configs y un resource pack adicional, entre otros archivos
Server pack oficial         no existe
```

Por la licencia no se suben sus binarios al repositorio de Coco. El lock guarda el endpoint oficial exacto de cada `projectID/fileID`, tamaño y SHA-256; cada amigo descarga desde CurseForge y Coco deduplica el resultado localmente. El único overlay Coco es MCWiFiPnP 1.7.6 Forge, Apache-2.0, sólo para el host.

La prueba real desechable construyó inicialmente una instancia host con 70 JAR, nueve resource packs efectivos, un shader pack y Forge/Java administrados. PortableMC completó la instalación seca. El 2026-07-22 `Test-CocoIronLungBoot.ps1` abrió esa instancia dos veces, cargó Forge y los mods, alcanzó `OpenAL initialized`/`Sound engine started`, se mantuvo estable durante 12 segundos y cerró solamente el Java de auditoría. El segundo arranque usó una reconstrucción fría y tardó 58,2 segundos hasta completar la prueba.

La primera instalación fría descargó desde los orígenes fijados 80 objetos del pack/overlay, además de PortableMC, Java, Forge, librerías y assets Mojang. Una conexión de Mojang se cerró en el asset 4044/4044 después de unos 822 MB. Ese incidente descubrió dos defectos y quedó convertido en regresión: Coco ahora prepara el runtime antes de abrir Minecraft con hasta cuatro intentos reanudables, y la captura asíncrona de salida usa un handler administrado en vez de ejecutar un `ScriptBlock` sin runspace. La continuación real reutilizó todos los objetos verificados y reparó un JAR alterado conservando respaldo.

El log de arranque contiene advertencias del propio pack (mixins opcionales ausentes, fallback de PhysX, recursos con nombres inválidos y texturas faltantes), pero ningún crash ni terminación prematura; llegó al menú y el motor de sonido. `Failed to verify authentication` es esperado en esta prueba offline aislada. No se reinterpretan esas advertencias como aprobación de una partida completa: falta abrir un mundo y validar la sesión LAN real.

La prueba posterior de autoingreso descubrió que Essential 1.3.10.6 bloqueaba Forge con un diálogo externo de actualización y después podía esperar su onboarding/TOS. No existe otra dependencia `mods.toml`/`fabric.mod.json` del pack hacia Essential y Coco ya aporta la red/hosting que esa utilidad social pretendía cubrir. Por eso Iron Lung excluye únicamente `mods/Essential_1-3-10-6_forge_1-20-1.jar`: queda respaldado al migrar una instancia previa y no se descarga en una instalación nueva. La reconstrucción fría final descargó 79 objetos/313.455.590 bytes, terminó en 92,6 segundos, dejó 400 archivos administrados y 1.569.135.096 bytes totales; la segunda preparación tomó 4,6 segundos. El runtime contiene 69 JAR host (68 del pack más MCWiFiPnP). Sobre esa raíz totalmente nueva, el flujo productivo host preparó, abrió Minecraft y registró `Connecting to 10.77.37.1, 25565` en 50 segundos, sin prompt de Essential, TOS ni launcher externo. Después cambió transaccionalmente al rol cliente de 68 JAR, repitió el mismo autoingreso en 40,8 segundos y volvió a host restaurando MCWiFiPnP; ambos roles quedaron comprobados. Una tercera apertura host corrigió y verificó la recuperación `servers.dat`: Minecraft 1.20.1 exige NBT sin compresión, leyó el archivo sin `EOFException` y volvió a intentar el endpoint en 45,6 segundos.

El mapa enlazado por el autor es opcional. Su archivo actual no corresponde a Minecraft 1.20.1, de modo que Coco no lo mezcla ni lo degrada: la primera sesión crea un mundo aislado propio.

## Migración desde Coco Updater 0.5.47

1. El amigo abre por última vez cualquier EXE Coco auténtico que ya tenga.
2. El bootstrap viejo consulta el mismo `latest.json`; los campos nuevos son aditivos y obtiene el engine nuevo sin otro instalador.
3. El engine instala/actualiza el EXE canónico en `%LOCALAPPDATA%\CocoMinecraftUpdater` con la lógica tolerante existente.
4. Crea o repara `Coco Launcher.lnk` en el Escritorio apuntando al canónico, nunca a una instancia.
5. Si la copia ejecutada está en Escritorio/Descargas, tiene nombre y ProductName Coco válidos y no es el canónico, un helper espera que termine y la mueve a respaldo. No borra ejecutables arbitrarios.
6. Desde entonces se usa el acceso directo. Una copia vieja que reaparezca sigue siendo un bootstrap capaz de alcanzar el canal estable.

`NetworkOnly`, Bridge, recuperación de engine y Publisher permanecen compatibles durante la transición. No se publicará mientras Minecraft/LAN estén abiertos.

## Pruebas y puertas antes de publicar

- Parseo PowerShell y todas las regresiones existentes.
- Catálogo: sesión única automática, IDs, loader/Java, rutas, hashes y puertos.
- Backend: doble hash/tamaño, versión+commit, Zip Slip, stage, respaldo y reutilización.
- Identidad: TLauncher free/Microsoft, launcher oficial, ambigüedad, persistencia y prueba de que ningún token llega al estado Coco.
- Lanzamiento: specs Fabric/Forge, roots aisladas, identidad y autoingreso.
- Migración real 0.5.47 → launcher sin segundo EXE ni pérdida del canónico.
- Servicio de sesión: expiración, host offline, preparing, ready, caída, respuesta maliciosa, puerto ocupado y comprobación de que el proceso realmente quedó escuchando.
- Supervisión: Coco cliente se oculta pero permanece vivo hasta que PortableMC/Minecraft termina; una regresión llena más que el buffer de ambos pipes para impedir bloqueos por cierre temprano.
- Contención: Coco Launcher usa los mismos mutex de ZeroTier que Bridge/engines anteriores y no ejecuta dos reparaciones de red simultáneas.
- Iron Lung: lock, instalación fría/reanudable, autorreparación, arranque visible, autoingreso y lectura real de `servers.dat` ya aprobados. El mundo aleatorio abrió y LAN escuchó realmente en 25565, pero eso sólo valida el runtime: faltan un escenario 1.20.1 que contenga el submarino, auditoría de errores del contenido, host+cliente LAN, Microsoft real, cliente local/offline, reconexión y segundo inicio del mundo definitivo.
- Verificación explícita de que ninguna prueba escribe en `saves\coco`, `playerdata` o DH.

## Auditoría integral del flujo (2026-07-22)

La palabra **aprobado** se reserva a una prueba que ejercitó esa transición. “Simulado” significa que se ejecutó el mismo código productivo, sustituyendo solamente Minecraft o el segundo computador por un proceso/puerto controlado. “Pendiente físico” no se presenta como aprobado.

| Etapa | Acción de Coco y entidades involucradas | Evidencia actual | Fallo y recuperación diseñada | Estado |
|---|---|---|---|---|
| 1. EXE antiguo | El EXE 0.5.47 consulta `latest.json`, descarga engine/bootstrap por hash, copia el canónico a `%LOCALAPPDATA%`, crea `Coco Launcher.lnk` y archiva una copia auténtica de Descargas/Escritorio. | Reemplazo, antidegradación, acceso directo y helper de archivo pasan regresiones. | El engine funciona aunque Windows mantenga mapeado el EXE; el reemplazo queda pendiente y nunca degrada una versión mayor. | Implementado; migración visible usando un EXE 0.5.47 real sigue siendo puerta de publicación. |
| 2. Activación | Apertura manual sin Minecraft original compatible entra a Launcher. Apertura desde Bridge, `NetworkOnly`, Publisher o con Coco original abierto conserva el updater clásico. | Regresión de integración inspecciona todas las condiciones de activación. | Si falta el catálogo/engine launcher, el flujo no inventa una experiencia y cae en el tratamiento de error del engine. El Publisher rechaza `releaseStatus=development`. | Aprobado por regresión; publicación bloqueada deliberadamente. |
| 3. Red | Launcher toma el mutex nuevo y el legado, repara ZeroTier si hace falta y libera ambos; Bridge no puede competir con él. | Contención con un proceso real que mantiene ocupado el mutex; `NetworkOnly` y pruebas ZeroTier existentes aprobadas. | Espera visible hasta 120 s; error accionable/diagnóstico si otra reparación no termina. | Aprobado en este Windows; elevación desde una PC limpia queda pendiente físico. |
| 4. Descubrimiento | Host publica sólo una sesión en `10.77.37.1:25564`; el servicio restringe origen, protocolo, tamaño y lease. Cliente valida ID, versión, endpoint y fechas. | Servicio real enlazado a la IP ZeroTier local y consultado por TCP; estados, expiración y payload malicioso cubiertos. | El host comprueba que el proceso no haya muerto y que 25564 escuche antes de abrir el juego. Sin respuesta el cliente trata al host como offline. | Aprobado local; falta segundo nodo ZeroTier. |
| 5. Sin sesión | Cliente sincroniza Coco original y no abre otra instancia. Bridge dentro del mundo original sigue siendo el publicado. | Separación externa/interna y fallback clásico pasan integración; regresiones 0.5.47 siguen pasando. | Minecraft original abierto fuerza el camino clásico; nunca se modifica `saves\coco` desde las pruebas launcher. | Aprobado por regresión; comportamiento publicado ya validado en sesiones reales. |
| 6. Catálogo y pack | Engine contiene catálogo más todos los locks referenciados. Cada binario se obtiene desde origen fijado por tamaño y SHA-256. | Iron Lung descargado desde cero; backend verifica ZIP, EXE, versión y commit; empaquetado ahora enumera locks genéricamente, sin nombres hardcodeados. | Descarga transitoria reintenta cuatro veces; objetos válidos se reutilizan. Stage y Zip Slip se validan antes de conmutar. | Aprobado para Iron Lung. Verificación PGP del backend en Publisher permanece como hardening pendiente. |
| 7. Instalación | Se construye un stage, se preservan mundos/opciones, se respaldan archivos retirados y se registra estado administrado. Rol host agrega MCWiFiPnP; cliente lo retira. | Instalación fría de 1,57 GB, segunda preparación de 4,6 s, corrupción deliberada reparada y cambio host/cliente comprobado. | Rollback restaura backups si falla una conmutación; no se toca una instancia mientras su Java está vivo. | Aprobado. |
| 8. Identidad | Se reutiliza decisión Coco; TLauncher free inequívoco usa nombre local; evidencia Microsoft lleva a PortableMC; ambigüedad pregunta una vez. | Metadatos free/Microsoft/ambiguos y ausencia de tokens en `identity.json` pasan regresiones. Lanzamiento offline `CocoAudit` fue real. | Nunca cambia silenciosamente Microsoft a offline. Login/selección se guarda; fallo muestra diagnóstico y permite decisión explícita. | Offline backend aprobado; TLauncher real y Microsoft real pendientes físicos. |
| 9. Preparación runtime | PortableMC instala Java 17, Forge 47.4.10 y assets antes del lanzamiento. | Corte real de Mojang reanudado; prueba específica fuerza primer intento fallido y segundo correcto. | Hasta cuatro intentos con backoff, conservando todo objeto/hash ya válido. | Aprobado. |
| 10. Lanzamiento cliente | Cliente no ve selector. Prepara durante `preparing`; revalida la misma sesión; en `ready` abre con Quick Play. Coco se oculta y supervisa PortableMC hasta el cierre. | Ciclo UI cliente completo simulado; 12.000 líneas saturan los pipes si Coco deja de leer. Lanzamiento Minecraft real llegó al endpoint en roles host y cliente. | Código no cero vuelve a mostrar Coco con log/diagnóstico. Botones de cerrar/identidad se deshabilitan durante cambios transaccionales. | Aprobado salvo conexión exitosa a un host real. |
| 11. Lanzamiento host | Sólo host elige pack; Coco publica `preparing`, abre sin autoentrada y espera que el jugador abra LAN. | Además del ciclo simulado, Forge 1.20.1 creó `Coco Iron Lung Audit`, inició el servidor integrado y MCWiFiPnP abrió TCP 25565. El jugador entró correctamente al Overworld. | Puerto 25565 ocupado se rechaza antes de abrir. Cierre Minecraft publica `stopping`, mata el servicio y elimina el estado. El aviso posterior `Failed to access world` fue un bloqueo transitorio de `session.lock` al intentar abrir de nuevo un mundo ya en proceso, no corrupción: el mundo cargó y guardó después. | Runtime/LAN local aprobado; escenario Iron Lung y cliente real siguen bloqueados. |
| 12. Interfaz multijuego | Selector host usa una lista con scroll; identidad/cierre quedan fuera y no se superponen. Amigos jamás eligen experiencia. | Regresión estructural y flujo cliente sin selector. | El catálogo prohíbe más de una sesión concurrente; cada nuevo lock se empaqueta automáticamente. | Aprobado. |
| 13. Essential | El JAR opcional se excluye antes de descargar; una instalación previa administrada lo mueve a respaldo. | Dependencias del pack auditadas; arranques posteriores sin prompt, onboarding ni TOS. | Política defensiva desactiva updates si quedaron archivos de loader históricos. | Aprobado. |
| 14. Recuperación manual | Primera instalación crea una entrada `servers.dat`; Quick Play sigue siendo la ruta principal. | Se detectó el GZip incorrecto mediante log real, se cambió a NBT sin compresión, un parser estructural lo valida y Minecraft lo leyó sin `EOFException`. | Coco nunca reemplaza después la lista editada por el jugador. | Aprobado contra Minecraft 1.20.1 real. |
| 15. Cierre y residuos | Cliente oculto espera el final del juego; host retira lease/servicio; tests sólo matan procesos con gameDir desechable. | La instancia desechable conserva ahora `saves\Coco Iron Lung Audit` como evidencia del smoke test; no es el mundo definitivo ni se copiará a producción. | Backups y logs quedan recuperables; ninguna limpieza recursiva apunta a `.minecraft` o a la raíz de usuario. | Aprobado para el aislamiento; cierre final del ensayo visible aún debe observarse. |

### Qué Minecraft se abrió realmente

No se abrió “el servidor” ni el mundo `coco`. Se reutilizó una sola instancia desechable de Iron Lung y se cambió transaccionalmente de rol:

1. **Host:** 69 JAR (68 del pack + MCWiFiPnP), Forge 47.4.10 y Java 17. Llegó al menú/motor de sonido y, con Quick Play habilitado sólo para medir el cliente común, intentó el endpoint apagado.
2. **Cliente:** la misma raíz pasó a 68 JAR, sin MCWiFiPnP, y repitió el intento automático.
3. **Host restaurado:** volvió a 69 JAR. La última apertura verificó el `servers.dat` corregido.

Después de esos arranques técnicos se hizo la primera prueba host visible. Se creó el mundo desechable `Coco Iron Lung Audit`, el servidor integrado aceptó a `smolbird`, MCWiFiPnP abrió LAN en TCP 25565 y la captura mostró el resource pack IRON OCEANS y shaders activos. Esto valida generación, entrada y apertura LAN local, pero reveló que el pack no trae el escenario del submarino: el mundo fue un Overworld aleatorio.

La página del autor dice que el mapa es opcional y externo. El ZIP auditado no contiene `saves`, plantilla de mundo, quests ni scripts de progresión. El único archivo publicado actualmente por PaleoTech para ese mapa está marcado 1.21.8–1.21.11/26.1 snapshot, incompatible como dependencia aprobada del modpack Forge 1.20.1. Iron Lung queda por tanto separado en dos estados: **motor/runtime parcialmente aprobado** y **experiencia jugable bloqueada** hasta conseguir o construir un mundo 1.20.1 con procedencia y licencia válidas.

Fuentes conservadas para esta decisión: [modpack oficial y explicación del mapa opcional](https://www.curseforge.com/minecraft/modpacks/iron-lung-exploration-modpack), [mundo THE LUNG de PaleoTech](https://www.curseforge.com/minecraft/worlds/the-lung-simple-starters-an-iron-lung-inspired) y [único archivo/versiones publicadas del mundo](https://www.curseforge.com/minecraft/worlds/the-lung-simple-starters-an-iron-lung-inspired/files/7582307).

El log de la partida mostró además referencias inválidas dentro de `ThalassonecrothrixOrOrganisorumRevampAndBigUpdate.jar` (`os:cymbophyta`, `os:infected_wood`, `os:deleted_mod_element`, `os:organisorum_wood_log`), intentos repetidos de insertar `os:mob_spawner_phase_based` ya eliminado y cajas de colisión de tamaño anómalo. No impidieron este arranque, pero deben reproducirse y resolverse o aceptarse explícitamente antes de aprobar gameplay.

### Correcciones descubiertas durante la auditoría

- Spec Forge corregido a `forge::1.20.1-47.4.10`.
- Preparación runtime separada y reanudable tras el corte real de Mojang.
- Callbacks PowerShell fuera de runspace reemplazados por un capturador C#.
- Essential excluido por bloqueo de update/onboarding, tras comprobar dependencias.
- Cliente mantiene Coco vivo y oculto para drenar los pipes hasta cerrar Minecraft.
- Launcher comparte mutex ZeroTier con Bridge y engines antiguos.
- Parámetro reservado `$Host` renombrado; habría abortado el botón de alojar.
- Servicio 25564 debe demostrar escucha y permanecer vivo, no sólo crear un proceso.
- Locks de experiencias empaquetados/verificados desde el catálogo, sin hardcodear Iron Lung.
- Selector host preparado para múltiples packs sin superponer controles.
- Cierre/identidad bloqueados durante instalaciones y diagnósticos generados en fallos launcher.
- Contrato visual reutilizable de diez etapas, descarga por bytes/archivo, instalación por archivo y heartbeat de PortableMC; el cliente no oculta Coco hasta observar Java de su instancia.
- Run ID heredado desde bootstrap, timeline JSONL con throttling y diagnóstico de Escritorio clasificado, contextual y probado para no filtrar tokens de identidad.
- Checklist independiente para que exclusiones, prompts, roles, mundos, progresión y pruebas físicas se auditen de nuevo en cada modpack.
- `servers.dat` cambiado de GZip a NBT sin compresión después de reproducir `EOFException` en Minecraft.

### Lo que falta realmente antes de publicar

1. En la instancia desechable host, crear un mundo, cerrarlo normalmente, volver a abrirlo y comprobar que el tiempo/progresión sólo comienza al entrar.
2. Abrir LAN real en 25565 y conectar una segunda instancia; comprobar login, spawn, desconexión, reconexión y cierre de sesión. La misma máquina sirve como smoke test de Minecraft, no como prueba de otro nodo.
3. Ejecutar el flujo completo en un amigo físico con TLauncher/free: EXE antiguo, actualización, acceso directo, elevación si corresponde, descarga fría y autoentrada.
4. Ejecutar el flujo completo en una cuenta Microsoft real: navegador oficial una vez, renovación y segundo lanzamiento sin pregunta.
5. Repetir el control 25564 y juego 25565 desde un segundo nodo ZeroTier físico; confirmar firewall/NAT/latencia y que no necesita enlaces manuales.
6. Probar de forma visible la migración exacta 0.5.47 → candidato launcher y confirmar que la copia vieja queda respaldada y el canónico/acceso directo sobreviven al reinicio.
7. Decidir si el grupo confiable acepta `online-mode=false` + UUID Fixer + autorización automática ZeroTier. Antes de usarlo con desconocidos hace falta whitelist o un mecanismo de invitación más fuerte.
8. Construir el release candidato, ejecutar todas las puertas del Publisher, verificar PGP/procedencia del backend y sólo entonces cambiar deliberadamente `releaseStatus` de `development` a `approved`. El Publisher aborta antes de publicar mientras siga en desarrollo. Producción continúa en 0.5.47 mientras falte cualquiera de estas puertas.

### Dónde están las instancias y cómo probar en una sola máquina

Rutas de producción por usuario:

```text
%APPDATA%\CocoMinecraft\experiences\<instanceId>\   instancia, mods, config y saves del pack
%LOCALAPPDATA%\CocoMinecraftUpdater\launcher\       identidad, cuenta PortableMC, backend y datos compartidos
%LOCALAPPDATA%\CocoMinecraftUpdater\downloads\      objetos descargados y deduplicados por hash
```

La auditoría desechable actual está en `%TEMP%\coco-iron-lung-runtime-audit`; la instancia concreta es `experiences\iron-lung` dentro de esa raíz y se conserva para continuar las pruebas de mundo/LAN. La prueba escribe `cold-install-report.json` cuando parte vacía y `resume-install-report.json` en continuaciones, sin sobrescribir evidencia futura; las métricas de la ejecución fría ya realizada quedan registradas arriba. El caché de importación oficial independiente está en `%TEMP%\coco-curseforge-import-cache`, pero la reconstrucción fría no lo usó. Ninguna de esas rutas es la futura instalación real del host.

Hay tres niveles de validación:

1. **Mismo Windows, procesos aislados:** permite verificar desde caché vacío la descarga, hashes, instalación, Forge/Java, arranque, autorreparación y conexión de dos Minecraft con game directories diferentes. Para evitar falsos positivos se deben usar raíces de prueba separadas. Sirve para runtime y autoingreso, pero no reproduce un segundo nodo ZeroTier ni separa `%APPDATA%`, credenciales, SmartScreen o permisos de administrador.
2. **Cliente físico remoto:** es la última puerta antes de publicar para SmartScreen/reputación, NAT y ruta ZeroTier reales, cuenta Microsoft real, latencia y diferencias de hardware. La red de juego 25565 ya fue validada con seis clientes; lo nuevo que debe comprobarse externamente es el control 25564 y el flujo launcher completo.

Dos clientes en el mismo Windows pueden conectarse al mismo servidor integrado, pero eso no equivale a dos computadores: comparten el nodo ZeroTier y, si se usa la UI productiva sin aislamiento, también identidad, caché y marcador de rol. Por eso una segunda instancia local es útil como smoke test; una VM es la réplica fiel.

El 2026-07-22 pasó además `Test-CocoLauncherLocalZeroTier.ps1`: levantó el servicio con sus restricciones productivas sobre `10.77.37.1:25564`, publicó temporalmente Iron Lung, lo consultó a través del adaptador real y retiró el proceso/estado. Esto valida bind, protocolo y filtro de origen en el host, pero no reemplaza un segundo nodo.

La regresión ampliada de observabilidad del 2026-07-22 pasó los 15 tests launcher más diagnóstico/UI. Una ejecución conjunta incluyó accidentalmente la prueba real de autoingreso y agotó el timeout del arnés después de crear `javaw.exe` en `%TEMP%\coco-iron-lung-runtime-audit`; se verificó la ruta completa antes de terminar únicamente ese PID. La comprobación final dejó cero Java de auditoría y cero listeners `25564/25565`. No se abrió ni modificó el mundo `coco`.

Se agregó `tests\Start-CocoLauncherDev.ps1` como entrada visible para la siguiente prueba física. Empaqueta el engine nuevo bajo la auditoría, abre la misma UI host sin sustituir el EXE 0.5.47 y fuerza caché/instancias/sesión a `%TEMP%\coco-iron-lung-runtime-audit`. Sólo admite esa ruta exacta, exige cero Java y cero listeners Coco y rechaza comenzar con menos de 7 GB libres. El primer preflight real se detuvo correctamente con 2,76 GB libres: no abrió Minecraft, no creó mundos y no tocó producción. Después de liberar memoria, ése es el comando canónico de la prueba host visible.

El primer inicio visible del runner, ya con un techo de heap de prueba de 4 GB, encontró antes de Java un error `Object[]/op_Multiply` al construir con `New-Object` las coordenadas calculadas del botón host. El diagnóstico rojo y el TXT del Escritorio funcionaron como estaba previsto. Se reemplazó por constructores tipados `Drawing.Size/Point`, se agregó una regresión contra el patrón ambiguo y se relanzó desde cero; no hubo mundo ni Java que recuperar del intento fallido.

Por decisión del host no se usará una VM. En el mismo Windows se puede avanzar con dos raíces aisladas y heaps limitados, pero la validación final de red/identidad/elevación exige un amigo u otro computador físico. La capacidad observada fue Windows 11 Home, 15,6 GB de RAM y aproximadamente 23 GB libres en C:, por lo que dos clientes Iron Lung simultáneos requieren cerrar aplicaciones y limitar memoria; no se presentará esa prueba local como equivalente a dos equipos ZeroTier.

## Registro de decisiones

- 2026-07-22: se mantuvo producción en 0.5.47; se implementó catálogo inicial, migración segura y detección local de identidad.
- 2026-07-22: Prism oficial fue descartado como backend único por su política de propiedad para offline; CmlLib.Core quedó descartado por evidencia de compatibilidad insuficiente.
- 2026-07-22: PortableMC 5.0.4/commit `0718735` fue auditado, fijado e instalado en seco con Fabric 26.1.2 y Forge 1.12.2.
- 2026-07-22: se decidió que los clientes nunca eligen experiencia: con cero sesiones ven offline; con una sesión la preparación y el lanzamiento son automáticos. Sólo el host selecciona qué alojar.
- 2026-07-22: se congeló el UX de identidad: autodetección primero, login Microsoft sólo cuando corresponde y una pregunta única exclusivamente en máquinas ambiguas.
- 2026-07-22: se importó Iron Lung 1486366/7762569 desde origen, se rechazó redistribuir binarios All Rights Reserved y se aprobó la instalación desechable Forge 47.4.10.
- 2026-07-22: la auditoría real encontró y corrigió el spec Forge (`forge::1.20.1-47.4.10`) y una regresión histórica donde `-Silent` podía abrir UI.
- 2026-07-22: se activó la apertura manual como launcher, se agregó selector sólo host, cliente automático, recuperación `servers.dat`, memoria adaptativa y control LAN por mundo; la transición continúa sin publicar hasta la prueba visible multiusuario.
- 2026-07-22: Coco original quedó explícitamente fuera de PortableMC. Sin sesión administrada, abrir el mismo EXE ejecuta el updater clásico; con sesión administrada, prepara y lanza automáticamente ese juego. Bridge mantiene el flujo original dentro de Minecraft.
- 2026-07-22: se descartó usar una VM; las pruebas aisladas continúan en este Windows y un cliente físico remoto seguirá siendo puerta de publicación.
- 2026-07-22: la reconstrucción fría y dos arranques visibles de Iron Lung aprobaron Forge/Java/mods. Un corte real de Mojang motivó preparación previa con cuatro reintentos reanudables; un aborto de PowerShell código 5 motivó reemplazar el callback asíncrono por un capturador C# con regresiones dedicadas.
- 2026-07-22: la prueba productiva de autoingreso encontró un bloqueo de Essential Loader y onboarding/TOS potencial. Al comprobar que ningún mod lo requiere, se excluyó sólo Essential de Iron Lung; el siguiente arranque llegó a `10.77.37.1:25565` automáticamente y sin diálogos.
- 2026-07-22: la auditoría del pegamento host/cliente corrigió cuatro fallos que el arranque directo no cubría: cierre prematuro de Coco y sus pipes, carrera de mutex ZeroTier, uso del nombre reservado `$Host` y ausencia de verificación de escucha del servicio 25564. Se agregaron ciclos UI supervisados y lifecycle host a las puertas del Publisher.
- 2026-07-22: el empaquetado dejó de hardcodear Iron Lung; engine, bootstrap, caché y pruebas exigen automáticamente todos los locks declarados por experiencias administradas.
- 2026-07-22: el log real reveló `EOFException` en la lista de servidores de recuperación. Minecraft 1.20.1 usa NBT sin compresión; el generador fue corregido, validado estructuralmente y releído en un arranque real sin repetir el error.
- 2026-07-22: el catálogo quedó en `releaseStatus=development` y el Publisher lo rechaza explícitamente; ninguna ejecución accidental puede publicar la transición antes de completar las puertas físicas y aprobarla de forma consciente.
- 2026-07-22: la primera partida host real confirmó Forge, generación, ingreso, shaders/resource packs y LAN 25565, pero desmintió que el modpack por sí solo iniciara en un submarino. El pack no incluye mundo ni progresión; el mapa externo disponible es 1.21.8–1.21.11 frente al runtime 1.20.1. Se reclasificó Iron Lung como runtime parcialmente aprobado y experiencia jugable bloqueada, y se añadieron puertas obligatorias para mundos externos y spawn real.
