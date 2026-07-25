[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$experience=@($catalog.experiences|Where-Object id -eq 'iron-lung'|Select-Object -First 1)[0]
$essentialPath='mods/Essential_1-3-10-6_forge_1-20-1.jar'
if(@($experience.pack.excludedPaths)-notcontains$essentialPath){throw 'Iron Lung no excluye Essential y sus prompts/TOS del runtime Coco.'}
$lock=Read-CocoExperienceLock (Join-Path $root 'launcher\experiences\iron-lung.lock.json') $experience
if($lock.source.projectId-ne1486366-or$lock.source.fileId-ne7762569-or$lock.source.license-ne'All Rights Reserved'-or$lock.source.redistribution-ne'origin-only'){throw 'La procedencia/licencia de Iron Lung no esta fijada correctamente.'}
if($lock.pack.archive.sha256-ne'25989d1fa444e74cde10375e2b14cea5273d688f0a6e221f830ee158f87a7a21'-or[int64]$lock.pack.archive.size-ne1015026){throw 'El ZIP oficial de Iron Lung no coincide con la auditoria.'}
$assets=@($lock.assets)
if($assets.Count-ne78-or($assets|Measure-Object size -Sum).Sum-ne363484401){throw 'Cantidad o tamano total de assets Iron Lung inesperado.'}
$groups=$assets|Group-Object {($_.path-split'/')[0]}|ForEach-Object{@{Name=$_.Name;Count=$_.Count}}
foreach($expected in @{Name='mods';Count=69},@{Name='resourcepacks';Count=8},@{Name='shaderpacks';Count=1}){
    $actual=@($groups|Where-Object{$_.Name-eq$expected.Name}|Select-Object -First 1)[0]
    if(-not$actual-or$actual.Count-ne$expected.Count){throw "Clasificacion Iron Lung incorrecta para $($expected.Name)."}
}
if(Get-ChildItem -LiteralPath (Join-Path $root 'launcher\experiences') -File|Where-Object Extension -in @('.jar','.zip')){throw 'El repositorio contiene binarios del pack que deben descargarse desde origen.'}

$worldLock=Read-CocoWorldTemplateLock (Join-Path $root 'launcher\experiences\iron-lung.world.lock.json') $experience
if($worldLock.status-ne'development'-or$worldLock.source.projectId-ne1455150-or$worldLock.source.fileId-ne7582307){throw 'La procedencia del mapa publico de PaleoTech no esta fijada.'}
if($worldLock.source.sha256-ne'e3b5d966569d5ea1a4f8baa71c1af8c9bbae43076c17a7aeda75d0cdc0c84638'-or[int64]$worldLock.source.size-ne37267162){throw 'El ZIP oficial del mapa no coincide con la auditoria.'}
if($worldLock.source.minecraftVersion-ne'1.21.8'-or$worldLock.source.dataVersion-ne4440-or$worldLock.conversion.targetMinecraftVersion-ne'1.20.1'-or$worldLock.conversion.targetDataVersion-ne3465){throw 'La frontera de conversion 1.21.8 -> 1.20.1 no esta fijada.'}
if([bool]$worldLock.provenance.videoWorldAvailable-or[bool]$worldLock.provenance.publicMapIsUnmodifiedVideoWorld){throw 'El lock afirma incorrectamente que el mundo privado del video esta disponible.'}
if(@($worldLock.conversion.blockReplacements).Count-lt20-or@($worldLock.world.requiredLandmarks).Count-ne2){throw 'Faltan sustituciones o landmarks obligatorios para auditar la conversion.'}
$overlay=@($experience.files|Where-Object path -like 'mods/mcwifipnp*')
if($overlay.Count-ne1-or$overlay[0].role-ne'host'-or$overlay[0].license-ne'Apache-2.0'){throw 'Falta el overlay LAN host permitido para Iron Lung.'}
'PASS: pack y mapa Iron Lung fijados por origen, conversion declarativa y overlay LAN validados.'
