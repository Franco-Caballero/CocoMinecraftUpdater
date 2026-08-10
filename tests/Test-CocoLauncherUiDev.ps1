[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$scriptPath=Join-Path $root 'tools\Invoke-CocoLauncherUiDev.ps1'
$result=& $scriptPath -Role client -NoUi
if(-not$result-or[string]$result.Role-ne'client'){throw 'El probador UI no conserva client despues de cargar CocoUpdater y el engine.'}
if(-not([IO.Path]::GetFullPath([string]$result.ExperiencesRoot).StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'El probador UI no aislo las experiencias en TEMP.'}
'PASS: el probador UI conserva client y sus rutas ficticias sin abrir la UI.'
