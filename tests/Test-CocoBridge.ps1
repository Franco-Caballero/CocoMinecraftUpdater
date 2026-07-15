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
if($launcher-notmatch'EnvType\.CLIENT'-or$launcher-notmatch'stateIsReady\(\)'-or
   $launcher-notmatch'nextNetworkAttemptAt'-or$launcher-notmatch'bridge-.*\.log'){
    throw 'El launcher temprano no limita clientes, verifica estado, reintenta y registra diagnostico.'
}
if($client-notmatch'ticks % 20 == 0'-or$client-notmatch'ensureNetworkCheck'-or
   $client-notmatch'launchFullCheck'){
    throw 'El Bridge cliente no verifica/reintenta red ni conserva el chequeo completo de login.'
}
if($network-notmatch'(?s)Start-Process\s+powershell\.exe\s+-Verb\s+RunAs\s+-WindowStyle\s+Hidden.*?-Wait'){
    throw 'El ayudante elevado de red podria mostrar una consola PowerShell vacia.'
}

'PASS: launcher temprano, reintento, diagnostico y elevacion oculta validados.'
