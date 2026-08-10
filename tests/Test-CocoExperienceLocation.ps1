[CmdletBinding()]
param([string]$EnginePath='')

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot -Parent
$engineFile=if([string]::IsNullOrWhiteSpace($EnginePath)){Join-Path $root 'engine\CocoLauncher.ps1'}else{[IO.Path]::GetFullPath($EnginePath)}
. $engineFile
function Test-CocoManagedGameRunning([string]$InstanceRoot,[string]$ExecutableName=''){return $false}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-location-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    $paths=Get-CocoLauncherPaths (Join-Path $root 'engine') $testRoot
    $storePath=[IO.Path]::GetFullPath($paths.InstanceLocationsPath)
    $testRootFull=[IO.Path]::GetFullPath($testRoot).TrimEnd('\')+'\'
    if(-not$storePath.StartsWith($testRootFull,[StringComparison]::OrdinalIgnoreCase)){throw 'El store de ubicaciones de prueba escapa de LauncherTestRoot.'}
    if(-not([IO.Path]::GetFullPath($paths.ExperienceBackupRoot).StartsWith($testRootFull,[StringComparison]::OrdinalIgnoreCase))){throw 'Los respaldos de prueba escapan de LauncherTestRoot.'}

    $experience=[pscustomobject]@{id='location-test';instanceId='location-test';name='Location Test';managementMode='managed';launch=[pscustomobject]@{workflow='coco-managed'}}
    $defaultRoot=Join-Path $paths.ExperiencesRoot 'location-test'
    New-Item -ItemType Directory -Path $defaultRoot -Force|Out-Null
    $emptyUsage=Get-CocoExperienceDiskUsage $defaultRoot
    if($emptyUsage.Installed){throw 'Una carpeta vacia fue marcada como una instalacion.'}
    Remove-Item -LiteralPath $defaultRoot -Recurse -Force

    $customRoot=Join-Path $testRoot 'custom\location-test'
    Set-CocoExperienceInstanceRoot $experience.instanceId $customRoot $storePath
    if((Get-CocoExperienceInstanceRoot $experience $paths.ExperiencesRoot $storePath)-ne[IO.Path]::GetFullPath($customRoot)){throw 'La ubicacion personalizada no se resolvio desde el store de prueba.'}
    $stored=Get-CocoInstanceCustomLocations $storePath
    if([string]$stored.'location-test'-ne[IO.Path]::GetFullPath($customRoot)){throw 'La ubicacion personalizada no se persistio en el store de prueba.'}

    $sourceFile=Join-Path $customRoot 'saves\world\level.dat'
    New-Item -ItemType Directory -Path (Split-Path $sourceFile -Parent) -Force|Out-Null
    [IO.File]::WriteAllText($sourceFile,'world-data',(New-Object Text.UTF8Encoding($false)))
    $newRoot=Join-Path $testRoot 'moved\location-test'
    $move=Move-CocoInstalledExperience $experience.instanceId $customRoot $newRoot $paths.ExperiencesRoot $storePath
    if(-not$move.Moved-or(Test-Path -LiteralPath $customRoot)){throw 'El movimiento no dejo una fuente consistente.'}
    if(-not(Test-Path -LiteralPath (Join-Path $newRoot 'saves\world\level.dat') -PathType Leaf)){throw 'El mundo no llego a la nueva ubicacion.'}
    if((Get-Content -LiteralPath (Join-Path $newRoot 'saves\world\level.dat') -Raw).Trim()-ne'world-data'){throw 'El contenido del mundo cambio al moverlo.'}
    if((Get-CocoExperienceInstanceRoot $experience $paths.ExperiencesRoot $storePath)-ne[IO.Path]::GetFullPath($newRoot)){throw 'El store no se actualizo despues del movimiento.'}

    $occupied=Join-Path $testRoot 'occupied\location-test'
    New-Item -ItemType Directory -Path $occupied -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $occupied 'do-not-touch.txt'),'occupied',(New-Object Text.UTF8Encoding($false)))
    $moveFailed=$false
    try{[void](Move-CocoInstalledExperience $experience.instanceId $newRoot $occupied $paths.ExperiencesRoot $storePath)}catch{$moveFailed=$true}
    if(-not$moveFailed-or-not(Test-Path -LiteralPath (Join-Path $newRoot 'saves\world\level.dat'))){throw 'Un destino ocupado pudo alterar la instalacion actual.'}
    if((Get-Content -LiteralPath (Join-Path $occupied 'do-not-touch.txt') -Raw).Trim()-ne'occupied'){throw 'El movimiento intento sobrescribir un destino existente.'}

    $backupResult=Remove-CocoInstalledExperience $newRoot $paths.ExperiencesRoot $experience.instanceId $storePath $paths.ExperienceBackupRoot
    if(-not$backupResult.Removed-or(Test-Path -LiteralPath $newRoot)){throw 'La liberacion de espacio no elimino la instancia.'}
    if(-not$backupResult.BackupRoot-or-not(Test-Path -LiteralPath (Join-Path $backupResult.BackupRoot 'saves\world\level.dat') -PathType Leaf)){throw 'La liberacion no creo el respaldo del mundo.'}

    $legacy=Join-Path $testRoot 'legacy';New-Item -ItemType Directory -Path (Join-Path $legacy 'config') -Force|Out-Null
    '{}'|Set-Content -LiteralPath (Join-Path $legacy 'config\coco-host.json') -Encoding UTF8
    $global:CocoUiDevRoleOverride='client'
    if((Get-CocoLauncherRole $legacy)-ne'client'){throw 'El override de rol cliente no tiene precedencia en la prueba.'}
    Remove-Variable -Name CocoUiDevRoleOverride -Scope Global -ErrorAction SilentlyContinue
    if((Get-CocoLauncherRole $legacy)-ne'host'){throw 'El marcador host no fue respetado al quitar el override.'}
    Remove-Variable -Name CocoUiDevRoleOverride -Scope Global -ErrorAction SilentlyContinue
    'PASS: rutas de prueba aisladas, persistencia, movimiento seguro, destino ocupado, respaldo y override de rol validados.'
}finally{
    Remove-Variable -Name CocoUiDevRoleOverride -Scope Global -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
