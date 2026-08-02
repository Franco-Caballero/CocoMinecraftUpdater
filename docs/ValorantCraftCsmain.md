# VALORANTCraft con CSmain

## Flujo comodo con botones

La experiencia instala `Coco VALORANT Tools` en host y clientes. Al entrar, cada jugador pulsa `M` (o usa el boton/comando `/coco menu`) y ve solo las acciones que le corresponden:

- Jugador: abrir seleccion de agente, elegir T/CT/espectador, marcarse listo y consultar controles.
- Host: las mismas acciones, mas panel para equilibrar equipos, iniciar cuando todos estan listos, iniciar una prueba, preparar el lobby, guardar CSmain y activar/desactivar edicion del mapa.

El host se identifica por permisos de operador (`permission level 2`); los amigos no necesitan ejecutar comandos. Para conservar esta separacion, el host debe ser el unico operador del mundo. La tecla `M` se entrega a todos mediante el mod, incluido cada cliente nuevo.

El lobby aplica Adventure a jugadores que todavia no estan participando en una ronda y, ademas, cancela rotura, colocacion, liquidos, modificaciones de herramientas y pisoteo. El modo edicion es temporal y solo lo puede activar el host desde su panel. Al iniciar, CSmain recupera Survival y mantiene el control de las rondas; no se fuerza Adventure durante el combate.

Estado: integración en desarrollo, CSmain 1.0.0-beta.1, Minecraft 1.20.1 Forge 47.4.4.

## Qué aporta CSmain

CSmain es el controlador de partida. No se recrean en Coco las rondas ni la bomba:

- equipos T, CT y espectador, con selección manual y auto balance;
- warmup, freeze/buy, ronda viva, plantado de bomba y fin de ronda;
- dos sitios de bomba configurables;
- economía por rondas, kills, plant y defuse;
- tienda con tecla B;
- respawn y limpieza de inventario al comenzar la ronda;
- recarga/relleno de munición administrado por el propio controlador.

La integración usa TACZ como arma base. El lock instala el mismo TACZ 1.1.8-hotfix que ya tenía la instancia, CSmain en ambos lados, el gunpack Valorant válido bajo tacz/, Origins, Valorant Origins, LR Tactical, Player Animator, GeckoLib, el pack de cuchillos y MCWiFiPnP solo en el host.

La tienda inicial se escribe una sola vez en config/killfeedtacz_state.json. Contiene los IDs valorant:classic, ghost, sheriff, vandal, phantom, operator y odin; las compras posteriores reutilizan el NBT del arma TACZ, por lo que no se entregan armas genéricas. CSmain usa `startItemAll: "shop:knife"` para entregar un `Eternal Karambit` gratuito al inicio de cada ronda; la entrada está desactivada para compras y solo sirve como carga inicial.

## Preparación de un mapa

Los mundos existentes no se reemplazan. CSmain guarda los spawns y sitios en la configuración de la instancia, no dentro de cada mundo. Por eso hay que preparar el mapa elegido una vez, como operador, estando físicamente en cada punto:

~~~text
/cs hub on
/cs setspawn hub
/cs setspawn t
/cs setspawn ct
/cs setspawn bomb1
/cs setspawn bomb2
/cs save
~~~

Después se inicia la partida con:

~~~text
/cs start
~~~

Antes de abrir Minecraft se puede revisar la instalacion viva con:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-CocoValorantPreflight.ps1
~~~

El preflight confirma mods, gunpack, CSmain, Coco VALORANT Tools/Orb, cuchillo inicial, LAN y datapacks antiguos. Si marca
`Mapa CSmain` como pendiente, todavia hay que ejecutar los cinco `setspawn` dentro del mapa y luego
`/cs save`; no se inventan coordenadas automaticamente.

Si se cambia entre VALORANT - Ascent y VALORANT - Haven, hay que repetir los cinco setspawn para el mapa nuevo y guardar. La beta mantiene un único conjunto de coordenadas por instancia.

## Restaurar el mapa

La fuente de Ascent y Haven es el proyecto [VALORANT x Minecraft Project](https://ommo.me/valorant-x-minecraft).
La comparacion local coincide con esa fuente: el `icon.png` es identico y los chunks comunes del mapa tambien.

El restaurador descarga el ZIP oficial, valida SHA-256, conserva la metadata compatible con Minecraft 1.20.1,
instala el Orb permanente y mueve el mundo actual a un backup recuperable. Por defecto solo hace simulacion:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\tools\Restore-CocoValorantMap.ps1 -Map Ascent
~~~

Para aplicarlo, con Minecraft cerrado:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\tools\Restore-CocoValorantMap.ps1 -Map Ascent -Apply
~~~

El `-Apply` no borra el mundo anterior: lo mueve a `%LOCALAPPDATA%\CocoMinecraftUpdater\backups\`.
No se debe ejecutar mientras haya una partida abierta.

## Selección de agente

Los agentes no los selecciona CSmain. La instalación desactiva los orígenes base de Origins y reemplaza la capa `origins:origin` por una lista exclusiva de Phoenix, Jett, Sova, Harbor, Omen, Skye, Breach, Neon, Sage e Iso. No aparecen Elytrian, Arachnid ni los demás roles de Origins.

La primera vez que un jugador entra al mundo con Origins cargado aparece automáticamente la pantalla de selección. En un mundo existente, o si hay que volver a elegir, el host puede abrirla para el jugador con:

~~~text
/origin gui <jugador> origins:origin
~~~

El jugador elige el agente en esa pantalla y confirma. Como alternativa, el host puede entregar un Orb of Origin:

~~~text
/give <jugador> origins:orb_of_origin 1
~~~

El jugador usa el orbe con clic derecho. Para revisar o asignar directamente desde el host:

~~~text
/origin get <jugador> origins:origin
/origin set <jugador> origins:origin valorant_origins:jett
~~~

La elección se hace en el hub, antes de `/cs start`, no durante cada ronda. Permanece guardada por jugador aunque CSmain limpie el inventario y reinicie la munición. La tecla `O` sirve para ver el agente/poderes actuales; para cambiarlo se usa la GUI de `/origin gui` o el Orb of Origin.

La instalación viva preparada para Ascent y Haven incluye además el datapack `coco_agent_orb`: todos los jugadores conectados reciben un orbe si no tienen uno en el inventario. Como el objeto original se consume al abrirlo, el servidor lo repone en el siguiente tick; en la práctica es infinito para jugadores nuevos y antiguos. El mismo datapack entrega un `Eternal Karambit` (`wtyj:eternal_karambit`) en el hub si falta, mientras CSmain lo entrega de forma nativa al comenzar cada ronda. No modifica `playerdata` ni reemplaza mundos.

## Flujo de los jugadores

1. El host selecciona VALORANTCraft y abre el mundo preparado.
2. Los amigos entran a la misma experiencia; el cliente usa la sesión LAN de 10.77.37.1:25565.
3. Cada jugador elige agente en la GUI de Origins y después equipo desde la pantalla de CSmain o con `/joint`, `/joinct` o `/joinspec`.
4. En la fase de compra se pulsa B; las armas compradas se entregan con la variante Valorant correcta.
5. El host ejecuta `/cs start`. CSmain controla el cambio de fase, Spike, victoria, economía y munición.
6. Al comenzar la siguiente ronda se limpia el inventario de combate y se vuelve a entregar la carga inicial; no se arrastra el cargador usado de la ronda anterior.

Las habilidades son aproximaciones de Valorant Origins y sus cooldowns funcionan con las teclas `C` (primaria) y `X` (secundaria). El agente queda separado del equipo: por ejemplo, un Jett puede jugar T o CT.

El layout jugable reserva `R` exclusivamente para recargar, `B` para la tienda, `G` para recoger la C4, `F` para melee, `V` para zoom, `Y` para inspeccionar, `F7/F8` para las funciones de Iris y `F9` para la receta de JEI. Las funciones de combate de LR Tactical, el swap de mano y los atajos creativos quedan desactivados para no robar teclas al combate.

## Instalaciones nuevas y mundos existentes

`Coco VALORANT Tools` es ahora la fuente distribuible del Orb: lo entrega al entrar y lo repone si el jugador lo consume, sin depender de editar `saves`. El datapack `coco_agent_orb` se conserva solo como compatibilidad para Ascent/Haven ya preparados; que falte en un mundo nuevo no bloquea el preflight. El cuchillo de ronda no depende del Orb: CSmain lo crea desde `startItemAll: "shop:knife"`.

## Fuentes fijadas

- [CSmain en CurseForge](https://www.curseforge.com/minecraft/mc-mods/csmain)
- [CSmain en Modrinth](https://modrinth.com/mod/csmain)
- [Guía oficial de instalación y comandos](https://github.com/kaptyter-del/Setup_CSMAIN/blob/main/README.md)
- [Gunpack Valorant para TACZ](https://www.curseforge.com/minecraft/customization/tacz-valorant-gun-pack-for-tacz)
