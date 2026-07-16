[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
$bootstrap=[IO.File]::ReadAllText((Join-Path $root 'bootstrap\CocoBootstrapper.ps1'))

if($engine-notmatch'function Show-CocoSuccessAndWait'-or
   $engine-notmatch"\.Text='ACEPTAR'"-or$engine-notmatch'0x2714'-or
   $engine-notmatch'FromArgb\(78,214,132\)'-or$engine-notmatch'TODO LISTO'){
    throw 'El estado final no contiene confirmacion, visto y jerarquia visual verde.'
}
if($engine-notmatch'\.AcceptButton=\$accept'-or$engine-notmatch'\.Add_Click'-or
   $engine-notmatch'while\(\$script:CocoForm\.Visible-and-not\$script:CocoSuccessAccepted\)'){
    throw 'La ventana final no espera ACEPTAR o Enter antes de cerrarse.'
}
if($engine-notmatch'\[void\]\$accept\.Focus\(\)'){
    throw 'Focus() puede filtrar True al pipeline y ps2exe lo convertiria en un cuadro de mensaje.'
}
if($engine-notmatch'Drawing\.Size\(\[int\]\(640\*\$scale\)'-or
   $engine-match'La actualizacion termino correctamente\. Ya puedes volver a abrir Minecraft'){
    throw 'El texto final puede volver a envolverse debajo de la barra de progreso.'
}
if($engine-notmatch'\$automaticFullCheck=\$MinecraftPid-gt0-and-not\$NetworkOnly'-or
   ([regex]::Matches($engine,'\$ShowOnUpdate-or\$automaticFullCheck')).Count-lt2){
    throw 'Un Bridge antiguo todavia podria cerrar Minecraft sin mostrar la confirmacion visual.'
}
$earlyUi=$engine.IndexOf('$clientUpdateRequired=')
$networkSetup=$engine.IndexOf('if($manifest.network)')
if($earlyUi-lt0-or$networkSetup-lt0-or$earlyUi-gt$networkSetup-or
   $engine-notmatch'(?s)if\(\$clientUpdateRequired\).*?Show-CocoWindow.*?Wait-ForMinecraftExit \$selected\.Root \$true'){
    throw 'La reina no se abre y cierra Minecraft antes de preparar la red para cualquier pack atrasado.'
}
if(([regex]::Matches($engine,'Show-CocoSuccessAndWait')).Count-lt4){
    throw 'No todos los caminos operativos de exito terminan en la confirmacion persistente.'
}
if($bootstrap-notmatch'Panel=\$panel;Accent=\$accent'-or$bootstrap-notmatch'Brand=\$brand'){
    throw 'El bootstrap no comparte los controles necesarios para transformar la ventana de la reina.'
}
if($bootstrap-notmatch"COCO_SHOW_ON_UPDATE-ne'1'"){
    throw 'Una actualizacion confirmada no muestra la reina desde el inicio del bootstrap.'
}
if($engine-notmatch'if\(\$mutex\)\{\$mutex\.ReleaseMutex\(\)\|Out-Null;\$mutexAcquired=\$false;\$mutex\.Dispose\(\);\$mutex=\$null\}'){
    throw 'La confirmacion visual conserva el mutex del updater mientras espera al usuario.'
}

'PASS: final verde y persistente; ACEPTAR/Enter cierra sin filtrar True a ps2exe.'
