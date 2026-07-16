[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$gate=[IO.File]::ReadAllText((Join-Path $root 'fabric-mod\src\main\java\cl\coco\minecraft\CocoPackGate.java'))
$launcher=[IO.File]::ReadAllText((Join-Path $root 'fabric-mod\src\main\java\cl\coco\minecraft\CocoUpdaterLauncher.java'))
$client=[IO.File]::ReadAllText((Join-Path $root 'fabric-mod\src\client\java\cl\coco\minecraft\client\CocoSessionBridge.java'))
$network=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoNetwork.ps1'))

if($gate-notmatch'CocoUpdaterLauncher\.initializeEarly\(\)'){
    throw 'El entrypoint principal no inicia CocoUpdater temprano.'
}
if($gate-notmatch'Coco Updater se abrira y cerrara Minecraft automaticamente'-or
   $gate-notmatch'Espera .*TODO LISTO .*ACEPTAR'){
    throw 'El rechazo del servidor todavia pide cerrar Minecraft manualmente o no explica la confirmacion final.'
}
if($launcher-notmatch'EnvType\.CLIENT'-or$launcher-notmatch'stateIsReady\(\)'-or
   $launcher-notmatch'nextNetworkAttemptAt'-or$launcher-notmatch'bridge-.*\.log'-or
   $launcher-notmatch'NETWORK_STATE_FILE'-or$launcher-notmatch'UPDATE_STATE_FILE'){
    throw 'El launcher temprano no limita clientes, verifica estado, reintenta y registra diagnostico.'
}
if($client-notmatch'ticks % 20 == 0'-or$client-notmatch'ensureNetworkCheck'-or
   $client-notmatch'checkLatestAndLaunchFullUpdate'-or$client-notmatch'ensureFullCheck'){
    throw 'El Bridge cliente no verifica/reintenta red ni conserva el chequeo completo de login.'
}
if($launcher-notmatch'HttpClient'-or$launcher-notmatch'MANIFEST_VERSION'-or
   $launcher-notmatch'PACK_VERSION\.equals\(result\)'-or
   $launcher-notmatch'if \(launchUpdater\) launchFullCheck'){
    throw 'Un cliente actualizado todavia podria abrir el updater completo solo para consultar la version.'
}
if($launcher-notmatch'COCO_RUNNING_PACK_VERSION'-or$launcher-notmatch'CocoProtocol\.PACK_VERSION'-or
   $launcher-notmatch'COCO_SHOW_ON_UPDATE'-or$launcher-notmatch'fullAttempts >= 3'){
    throw 'El chequeo completo no informa la version cargada, no muestra reparaciones o no reintenta fallos.'
}
if($launcher-match'command\.add\("-RunningPackVersion"\)'-or$launcher-match'command\.add\("-ShowOnUpdate"\)'){
    throw 'El Bridge nuevo dejo de ser compatible con un bootstrap canonico anterior.'
}
if($network-notmatch'(?s)Start-Process\s+powershell\.exe\s+-Verb\s+RunAs\s+-WindowStyle\s+Hidden.*?-Wait'){
    throw 'El ayudante elevado de red podria mostrar una consola PowerShell vacia.'
}

'PASS: launcher temprano, reintento, diagnostico y elevacion oculta validados.'
