[CmdletBinding()]
param([string]$EnginePath='')

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engineFile=if([string]::IsNullOrWhiteSpace($EnginePath)){Join-Path $root 'engine\CocoLauncher.ps1'}else{[IO.Path]::GetFullPath($EnginePath)}
. $engineFile
function Test-CocoManagedGameRunning([string]$InstanceRoot,[string]$ExecutableName=''){return $false}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-standalone-extras-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $gameArchive=Join-Path $testRoot 'game.zip'
    $gameDir=Join-Path $testRoot 'game-src';New-Item -ItemType Directory -Path $gameDir -Force|Out-Null
    New-Item -ItemType Directory -Path (Join-Path $gameDir 'game_Data') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $gameDir 'game.exe'),'game-exe',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $gameDir 'game_Data\level.bin'),'world',(New-Object Text.UTF8Encoding($false)))
    [IO.Compression.ZipFile]::CreateFromDirectory($gameDir,$gameArchive,[IO.Compression.CompressionLevel]::Optimal,$false)
    $gameSha=(Get-FileHash -LiteralPath $gameArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    $gameSize=(Get-Item -LiteralPath $gameArchive).Length

    $modsStage=Join-Path $testRoot 'mods-stage';New-Item -ItemType Directory -Path (Join-Path $modsStage 'BepInEx\plugins') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\plugins\BigVoice.dll'),'voice-mod',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\plugins\EnhancedControls.dll'),'controls-mod',(New-Object Text.UTF8Encoding($false)))
    $modsZipV1=Join-Path $testRoot 'big-walk-mods.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($modsStage,$modsZipV1,[IO.Compression.CompressionLevel]::Optimal,$false)
    $modsSha1=(Get-FileHash -LiteralPath $modsZipV1 -Algorithm SHA256).Hash.ToLowerInvariant()
    $modsSize1=(Get-Item -LiteralPath $modsZipV1).Length

    $experience=[pscustomobject]@{
        id='standalone-extras-test';instanceId='standalone-extras-test';name='Extras Test';managementMode='managed'
        runtime=[pscustomobject]@{type='standalone';executable='game.exe'}
        launch=[pscustomobject]@{workflow='coco-standalone';minimumFreeBytes=0;autoJoin=$false}
        pack=[pscustomobject]@{version='1.0.0';sha256=$gameSha;size=$gameSize;archives=@([pscustomobject]@{archiveUrl=$gameArchive;sha256=$gameSha;size=$gameSize})}
        files=@([pscustomobject]@{path='BepInEx/mods/big-walk-mods.zip';sourceUrl=$modsZipV1;sha256=$modsSha1;size=$modsSize1;policy='replace';role='all'})
    }
    $experiencesRoot=Join-Path $testRoot 'experiences'
    $cacheRoot=Join-Path $testRoot 'cache'
    New-Item -ItemType Directory -Path $experiencesRoot,$cacheRoot -Force|Out-Null

    $install1=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$install1.Updated){throw 'La primera instalacion standalone no informo actualizacion.'}
    $instance=Join-Path $experiencesRoot 'standalone-extras-test'
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'game.exe') -PathType Leaf)){throw 'El juego no se extrajo.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'BepInEx\plugins\BigVoice.dll') -PathType Leaf)){throw 'El paquete de mods no se aplico.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\plugins\BigVoice.dll') -Raw)-ne'voice-mod'){throw 'El contenido del mod no coincide.'}
    $state1=Get-Content -LiteralPath (Join-Path $instance '.coco\standalone-state.json') -Raw|ConvertFrom-Json
    if([string]$state1.filesSha-ne$modsSha1){throw "El estado no registro los extras (filesSha=$($state1.filesSha))."}

    $install2=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if($install2.Updated){throw 'Una instalacion idempotente informo actualizacion.'}

    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\plugins\BigVoice.dll'),'voice-mod-v2',(New-Object Text.UTF8Encoding($false)))
    $modsZipV2=Join-Path $testRoot 'big-walk-mods-v2.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($modsStage,$modsZipV2,[IO.Compression.CompressionLevel]::Optimal,$false)
    $modsSha2=(Get-FileHash -LiteralPath $modsZipV2 -Algorithm SHA256).Hash.ToLowerInvariant()
    $modsSize2=(Get-Item -LiteralPath $modsZipV2).Length
    $experience.files[0].sourceUrl=$modsZipV2;$experience.files[0].sha256=$modsSha2;$experience.files[0].size=$modsSize2

    $install3=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$install3.Updated){throw 'Un cambio de extras no informo actualizacion.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\plugins\BigVoice.dll') -Raw)-ne'voice-mod-v2'){throw 'Los extras actualizados no reemplazaron el contenido.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'game.exe') -PathType Leaf)){throw 'La actualizacion de extras borro el juego.'}
    $state3=Get-Content -LiteralPath (Join-Path $instance '.coco\standalone-state.json') -Raw|ConvertFrom-Json
    if([string]$state3.filesSha-ne$modsSha2){throw 'El estado no registro los extras actualizados.'}

    'PASS: instalacion standalone con extras, idempotencia y actualizacion de mods validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}