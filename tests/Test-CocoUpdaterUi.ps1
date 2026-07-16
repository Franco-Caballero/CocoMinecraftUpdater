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
if(([regex]::Matches($engine,'Show-CocoSuccessAndWait')).Count-lt4){
    throw 'No todos los caminos operativos de exito terminan en la confirmacion persistente.'
}
if($bootstrap-notmatch'Panel=\$panel;Accent=\$accent'-or$bootstrap-notmatch'Brand=\$brand'){
    throw 'El bootstrap no comparte los controles necesarios para transformar la ventana de la reina.'
}
if($engine-notmatch'if\(\$mutex\)\{\$mutex\.ReleaseMutex\(\)\|Out-Null;\$mutex\.Dispose\(\);\$mutex=\$null\}'){
    throw 'La confirmacion visual conserva el mutex del updater mientras espera al usuario.'
}

'PASS: final verde, legible y persistente hasta ACEPTAR/Enter validado.'
