[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
$bootstrap=[IO.File]::ReadAllText((Join-Path $root 'bootstrap\CocoBootstrapper.ps1'))
$network=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoNetwork.ps1'))
$elevated=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoNetworkElevated.ps1'))

$clientUpdateBlock=[regex]::Match($engine,'(?s)\$clientUpdateRequired=.*?if\(\$manifest\.network\)').Value
if($clientUpdateBlock-notmatch '\-not\$Silent\-or\$ShowOnUpdate\-or\$automaticFullCheck'){
    throw '-Silent podria volver a abrir la UI al sincronizar un cliente.'
}

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
if($engine-notmatch'Drawing\.Size\(640,460\)'-or
   $engine-notmatch'function Set-CocoFittedLabelText'-or
   $bootstrap-notmatch'Drawing\.Size\(640,460\)'-or
   $bootstrap-notmatch'function Set-CocoBootstrapLabelText'-or
   $engine-match'La actualizacion termino correctamente\. Ya puedes volver a abrir Minecraft'){
    throw 'Bootstrap/engine no comparten el layout amplio y el ajuste de texto.'
}
$engineFontBlock=[regex]::Match($engine,'(?s)function Set-CocoFittedLabelText\(.*?^}',[Text.RegularExpressions.RegexOptions]::Multiline).Value
$bootstrapFontBlock=[regex]::Match($bootstrap,'(?s)function Set-CocoBootstrapLabelText\(.*?^}',[Text.RegularExpressions.RegexOptions]::Multiline).Value
if($engineFontBlock-match'\$old\.Dispose\(\)'-or$bootstrapFontBlock-match'\$old\.Dispose\(\)'){
    throw 'El ajuste de texto todavia destruye una fuente que WinForms puede estar pintando.'
}
if($engine-notmatch'\$art\.Image=\[Drawing\.Bitmap\]::new\(\$sourceImage\)'-or
   $bootstrap-notmatch'\$art\.Image=\[Drawing\.Bitmap\]::new\(\$sourceImage\)'){
    throw 'La imagen de la reina aun depende de un stream temporal y puede mostrar una X roja.'
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
if($network-notmatch'elevated-\$id-progress\.json'-or
   $network-notmatch'while\(-not\$process\.HasExited\)'-or
   $elevated-notmatch'Esperando autorizacion automatica del host\.\.\. \$remaining s'){
    throw 'La primera instalacion no publica o muestra la cuenta regresiva elevada.'
}
if($engine-notmatch'function Write-CocoEngineDiagnostic'-or
   $engine-notmatch'CocoUpdater-error-\$stamp\.txt'-or
   $engine-notmatch'Envia por Discord'){
    throw 'Los errores del engine no generan un diagnostico visible en el Escritorio.'
}
if($engine-notmatch'Failure ID:'-or$engine-notmatch'TIMELINE DE ETAPAS'-or
   $engine-notmatch'Get-CocoFailureClassification'-or$engine-notmatch'Este informe no copia accessToken'){
    throw 'El TXT del Escritorio no conserva correlacion, timeline, clasificacion y garantia de privacidad.'
}
if($bootstrap-notmatch'Run ID:'-or$bootstrap-notmatch'bootstrap-run-\$\(\$script:CocoRunId\)\.log'){
    throw 'El bootstrap no comparte el Run ID ni su propia cronologia con el diagnostico.'
}

'PASS: final persistente, cuenta regresiva elevada y diagnostico del engine validados.'
