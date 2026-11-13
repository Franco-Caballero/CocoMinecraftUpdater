# Partidas LAN con Coco Launcher 2

ZeroTier transporta la red entre los equipos; el juego debe crear una sesión LAN y descubrirla o conectarse a ella. Estar autorizado en ZeroTier no demuestra que exista una partida ni que el buscador del juego esté utilizando ese adaptador.

Coco comprueba al abrir la aplicación el adaptador de la red `58997fc5f3c0c001`, incluso si ZeroTier venía instalado desde Coco 1. Cuando hace falta, la preparación de Windows solicita UAC y configura ese adaptador como **Privado**, con métrica **IPv4 1** y métrica automática desactivada. Lo identifica por la red Coco o su dirección `10.77.37.0/24`; no modifica otros adaptadores ZeroTier, VPN ni IPv6. La espera después de rechazar un permiso de Defender es independiente de la de red. Un error al cambiar el adaptador se registra y no se comunica como una reparación completada.

## Comprobar Move or Die

1. Ambos equipos necesitan el launcher actualizado y la misma versión del juego. Mantener Coco abierto permite al anfitrión autorizar miembros nuevos automáticamente.
2. Aceptar la autorización de Windows si Coco detecta que necesita preparar su adaptador. Reiniciar el juego en ambos equipos para que vuelva a elegir su interfaz de red.
3. El anfitrión debe crear una partida en el modo LAN del juego; abrir el menú o una sesión exclusivamente online no publica necesariamente una partida LAN. Entonces el cliente vuelve a buscar.
4. Si sigue sin aparecer, comprobar en **ambos** equipos membresía ZeroTier autorizada, dirección `10.77.37.x`, perfil y métrica del adaptador Coco. En el anfitrión, comprobar que el controlador permite broadcast. Revisar las reglas de firewall para el ejecutable que realmente usa sockets: Move or Die utiliza `Love\win\love.exe`, y una regla de la antigua carpeta de Coco 1 no cubre automáticamente la nueva carpeta de Coco 2.

Diagnóstico local sin cambiar Windows:

```powershell
Get-NetIPInterface -AddressFamily IPv4 |
    Sort-Object InterfaceMetric |
    Select-Object InterfaceAlias, InterfaceMetric, AutomaticMetric, ConnectionState
Get-NetConnectionProfile |
    Select-Object InterfaceAlias, NetworkCategory
```

No desactivar el firewall ni otras VPN como solución permanente, ni publicar tokens del controlador. Un adaptador corregido y pruebas locales aprobadas no sustituyen una prueba real host + cliente. Si solo se ha verificado un equipo, la conectividad y el descubrimiento desde el otro permanecen pendientes.
