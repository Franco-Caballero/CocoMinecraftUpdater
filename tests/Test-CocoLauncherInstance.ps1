[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$testRoot=Join-Path $env:TEMP "coco-launcher-instance-$([guid]::NewGuid())"
try{
    $experiences=Join-Path $testRoot 'experiences';$cache=Join-Path $testRoot 'cache';$source=Join-Path $testRoot 'source'
    New-Item -ItemType Directory -Path (Join-Path $source 'overrides\config'),(Join-Path $source 'overrides') -Force|Out-Null
    '{"version":1}'|Set-Content -LiteralPath (Join-Path $source 'overrides\config\pack.json') -Encoding UTF8
    'pack-options'|Set-Content -LiteralPath (Join-Path $source 'overrides\options.txt') -Encoding UTF8
    $packZip=Join-Path $testRoot 'pack.zip';Compress-Archive -Path (Join-Path $source '*') -DestinationPath $packZip
    $packHash=(Get-FileHash $packZip -Algorithm SHA256).Hash.ToLowerInvariant();$packSize=(Get-Item $packZip).Length
    $pack=[pscustomobject]@{name='pack.zip';path='mods/pack.zip';sourceUrl='https://www.curseforge.com/api/v1/mods/1/files/2/download';sha256=$packHash;size=$packSize;projectId=1;fileId=2;role='source-pack'}
    $packCache=Get-CocoLockedAssetCachePath $cache $pack;New-Item -ItemType Directory -Path (Split-Path $packCache -Parent) -Force|Out-Null;Copy-Item -LiteralPath $packZip -Destination $packCache

    $modSource=Join-Path $testRoot 'example.jar';[IO.File]::WriteAllBytes($modSource,[byte[]](0x50,0x4b,0x03,0x04,1,2,3,4))
    $modHash=(Get-FileHash $modSource -Algorithm SHA256).Hash.ToLowerInvariant();$modSize=(Get-Item $modSource).Length
    $mod=[pscustomobject]@{name='example.jar';path='mods/example.jar';sourceUrl='https://www.curseforge.com/api/v1/mods/3/files/4/download';sha256=$modHash;size=$modSize;projectId=3;fileId=4;role='all'}
    $modCache=Get-CocoLockedAssetCachePath $cache $mod;Copy-Item -LiteralPath $modSource -Destination $modCache

    $cslSource=Join-Path $testRoot 'CustomSkinLoader_Test.jar';[IO.File]::WriteAllBytes($cslSource,[byte[]](0x50,0x4b,0x03,0x04,9,8,7,6))
    $cslHash=(Get-FileHash $cslSource -Algorithm SHA256).Hash.ToLowerInvariant();$cslSize=(Get-Item $cslSource).Length
    $csl=[pscustomobject]@{name='CustomSkinLoader_Test.jar';path='mods/CustomSkinLoader_Test.jar';sourceUrl='https://example.invalid/CustomSkinLoader_Test.jar';sha256=$cslHash;size=$cslSize;role='all';policy='replace';minecraftVersions=@('1.20.1')}
    $cslCache=Get-CocoLockedAssetCachePath $cache $csl;Copy-Item -LiteralPath $cslSource -Destination $cslCache
    $globalPolicies=[pscustomobject]@{customSkinLoader=[pscustomobject]@{mode='required';variants=@($csl)};essential=[pscustomobject]@{mode='exclude'}}

    $experience=[pscustomobject]@{id='test-pack';instanceId='test-pack';managementMode='managed';runtime=[pscustomobject]@{minecraftVersion='1.20.1';loader='forge';loaderVersion='47.4.10'};pack=[pscustomobject]@{version='1.0'};files=@()}
    $lock=[pscustomobject]@{schemaVersion=1;source=[pscustomobject]@{provider='curseforge';redistribution='origin-only'};runtime=$experience.runtime;pack=[pscustomobject]@{archive=$pack;overridesRoot='overrides'};assets=@($mod)}
    $instance=Join-Path $experiences 'test-pack';New-Item -ItemType Directory -Path (Join-Path $instance 'saves\world') -Force|Out-Null
    'world-must-survive'|Set-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Encoding UTF8
    'user-options'|Set-Content -LiteralPath (Join-Path $instance 'options.txt') -Encoding UTF8
    $result=Install-CocoManagedExperience $experience $lock $experiences $cache client $globalPolicies
    if((Get-Content -LiteralPath (Join-Path $instance 'options.txt') -Raw).Trim()-ne'user-options'){throw 'El instalador reemplazo options.txt del usuario.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'mods\example.jar'))-or-not(Test-Path -LiteralPath (Join-Path $instance 'config\pack.json'))){throw 'Faltan archivos administrados instalados.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Raw).Trim()-ne'world-must-survive'){throw 'El instalador altero el mundo.'}
    if(-not(Test-Path -LiteralPath $result.StatePath)){throw 'Falta el estado de instancia administrada.'}
    $hiddenConfig=Get-Item -LiteralPath (Join-Path $instance 'config\pack.json')
    $hiddenConfig.Attributes=$hiddenConfig.Attributes-bor[IO.FileAttributes]::Hidden
    [void](Install-CocoManagedExperience $experience $lock $experiences $cache client $globalPolicies)
    $hiddenConfig=Get-Item -LiteralPath (Join-Path $instance 'config\pack.json') -Force
    $hiddenConfig.Attributes=$hiddenConfig.Attributes-band(-bnot[IO.FileAttributes]::Hidden)

    $replacementSource=Join-Path $testRoot 'example-v2.jar';[IO.File]::WriteAllBytes($replacementSource,[byte[]](0x50,0x4b,0x03,0x04,5,6,7,8))
    $replacementHash=(Get-FileHash $replacementSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $replacement=[pscustomobject]@{name='example-v2.jar';path='mods/example.jar';sourceUrl='https://www.curseforge.com/api/v1/mods/5/files/6/download';sha256=$replacementHash;size=(Get-Item $replacementSource).Length;projectId=5;fileId=6;role='all'}
    Copy-Item -LiteralPath $replacementSource -Destination (Get-CocoLockedAssetCachePath $cache $replacement)
    $childSource=Join-Path $testRoot 'child.jar';[IO.File]::WriteAllBytes($childSource,[byte[]](0x50,0x4b,0x03,0x04,9,10,11,12))
    $childHash=(Get-FileHash $childSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $child=[pscustomobject]@{name='child.jar';path='mods/collision/child.jar';sourceUrl='https://www.curseforge.com/api/v1/mods/7/files/8/download';sha256=$childHash;size=(Get-Item $childSource).Length;projectId=7;fileId=8;role='all'}
    Copy-Item -LiteralPath $childSource -Destination (Get-CocoLockedAssetCachePath $cache $child)
    [IO.File]::WriteAllText((Join-Path $instance 'mods\collision'),'impide crear el directorio',(New-Object Text.UTF8Encoding($false)))
    $experience.pack.version='1.0.5';$lock.assets=@($replacement,$child)
    $rollbackError=''
    try{[void](Install-CocoManagedExperience $experience $lock $experiences $cache client $globalPolicies)}catch{$rollbackError=$_.Exception.Message}
    if(-not$rollbackError-or$rollbackError-match'Reverse'){throw 'La regresion no provoco rollback o este oculto el error original.'}
    if((Get-FileHash (Join-Path $instance 'mods\example.jar') -Algorithm SHA256).Hash.ToLowerInvariant()-ne$modHash){
        throw 'El rollback no restauro el mod anterior despues de un fallo intermedio.'
    }
    Remove-Item -LiteralPath (Join-Path $instance 'mods\collision') -Force

    $experience.pack.version='1.1';$lock.assets=@()
    $result2=Install-CocoManagedExperience $experience $lock $experiences $cache client $globalPolicies
    if(Test-Path -LiteralPath (Join-Path $instance 'mods\example.jar')){throw 'Un mod retirado siguio activo.'}
    if($result2.BackupRoot-or@(Get-ChildItem (Join-Path $cache 'backups\experiences') -Recurse -File -ErrorAction SilentlyContinue).Count){throw 'La actualización dejo backups persistentes de la experiencia.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Raw).Trim()-ne'world-must-survive'){throw 'La actualizacion altero el mundo.'}

    'PASS: instancia unica, rollback transaccional, cache por hash, preservacion y retiro sin backups persistentes validados.'
}finally{if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}}
