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

    $experience=[pscustomobject]@{id='test-pack';instanceId='test-pack';managementMode='managed';runtime=[pscustomobject]@{minecraftVersion='1.20.1';loader='forge';loaderVersion='47.4.10'};pack=[pscustomobject]@{version='1.0'};files=@()}
    $lock=[pscustomobject]@{schemaVersion=1;source=[pscustomobject]@{provider='curseforge';redistribution='origin-only'};runtime=$experience.runtime;pack=[pscustomobject]@{archive=$pack;overridesRoot='overrides'};assets=@($mod)}
    $instance=Join-Path $experiences 'test-pack';New-Item -ItemType Directory -Path (Join-Path $instance 'saves\world') -Force|Out-Null
    'world-must-survive'|Set-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Encoding UTF8
    'user-options'|Set-Content -LiteralPath (Join-Path $instance 'options.txt') -Encoding UTF8
    $result=Install-CocoManagedExperience $experience $lock $experiences $cache client
    if((Get-Content -LiteralPath (Join-Path $instance 'options.txt') -Raw).Trim()-ne'user-options'){throw 'El instalador reemplazo options.txt del usuario.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'mods\example.jar'))-or-not(Test-Path -LiteralPath (Join-Path $instance 'config\pack.json'))){throw 'Faltan archivos administrados instalados.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Raw).Trim()-ne'world-must-survive'){throw 'El instalador altero el mundo.'}
    if(-not(Test-Path -LiteralPath $result.StatePath)){throw 'Falta el estado de instancia administrada.'}

    $experience.pack.version='1.1';$lock.assets=@()
    $result2=Install-CocoManagedExperience $experience $lock $experiences $cache client
    if(Test-Path -LiteralPath (Join-Path $instance 'mods\example.jar')){throw 'Un mod retirado siguio activo.'}
    if(-not$result2.BackupRoot-or-not(Get-ChildItem -LiteralPath $result2.BackupRoot -Recurse -Filter 'example.jar' -ErrorAction SilentlyContinue)){throw 'El mod retirado no quedo respaldado.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Raw).Trim()-ne'world-must-survive'){throw 'La actualizacion altero el mundo.'}

    'PASS: instancia aislada, overrides, cache por hash, preservacion y retiro recuperable validados.'
}finally{if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}}
