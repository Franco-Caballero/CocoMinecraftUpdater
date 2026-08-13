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
    $gameExeSha=(Get-FileHash -LiteralPath (Join-Path $gameDir 'game.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $gameExeSize=(Get-Item -LiteralPath (Join-Path $gameDir 'game.exe')).Length
    $levelSha=(Get-FileHash -LiteralPath (Join-Path $gameDir 'game_Data\level.bin') -Algorithm SHA256).Hash.ToLowerInvariant()
    $levelSize=(Get-Item -LiteralPath (Join-Path $gameDir 'game_Data\level.bin')).Length

    $modsStage=Join-Path $testRoot 'mods-stage';New-Item -ItemType Directory -Path (Join-Path $modsStage 'BepInEx\plugins'),(Join-Path $modsStage 'BepInEx\config') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\plugins\BigVoice.dll'),'voice-mod',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\plugins\EnhancedControls.dll'),'controls-mod',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\config\BigVoice.cfg'),'default-volume=100',(New-Object Text.UTF8Encoding($false)))
    $modsZipV1=Join-Path $testRoot 'big-walk-mods.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($modsStage,$modsZipV1,[IO.Compression.CompressionLevel]::Optimal,$false)
    $modsSha1=(Get-FileHash -LiteralPath $modsZipV1 -Algorithm SHA256).Hash.ToLowerInvariant()
    $modsSize1=(Get-Item -LiteralPath $modsZipV1).Length
    $hostOnlySource=Join-Path $testRoot 'HostOnly.dll'
    [IO.File]::WriteAllText($hostOnlySource,'host-only',(New-Object Text.UTF8Encoding($false)))
    $hostOnlySha=(Get-FileHash -LiteralPath $hostOnlySource -Algorithm SHA256).Hash.ToLowerInvariant()

    $experience=[pscustomobject]@{
        id='standalone-extras-test';instanceId='standalone-extras-test';name='Extras Test';managementMode='managed'
        runtime=[pscustomobject]@{type='standalone';executable='game.exe';requiredFiles=@(
            [pscustomobject]@{path='game.exe';sha256=$gameExeSha;size=$gameExeSize;archiveSha256=$gameSha},
            [pscustomobject]@{path='game_Data/level.bin';sha256=$levelSha;size=$levelSize;archiveSha256=$gameSha}
        )}
        launch=[pscustomobject]@{workflow='coco-standalone';minimumFreeBytes=0;autoJoin=$false}
        pack=[pscustomobject]@{version='1.0.0';sha256=$gameSha;size=$gameSize;archives=@([pscustomobject]@{archiveUrl=$gameArchive;sha256=$gameSha;size=$gameSize})}
        files=@(
            [pscustomobject]@{path='BepInEx/mods/big-walk-mods.zip';sourceUrl=$modsZipV1;sha256=$modsSha1;size=$modsSize1;policy='replace';role='all'},
            [pscustomobject]@{path='BepInEx/plugins/HostOnly.dll';sourceUrl=$hostOnlySource;sha256=$hostOnlySha;size=(Get-Item $hostOnlySource).Length;policy='replace';role='host'}
        )
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
    if(@($state1.extraFiles).Count-ne2){throw 'El estado no registro todos los archivos extraidos de los mods.'}
    if([int]$state1.schemaVersion-ne2){throw 'El estado standalone no usa el esquema transaccional vigente.'}

    $packCache=Join-Path $cacheRoot "downloads\standalone-packs\$gameSha.zip"
    Remove-Item -LiteralPath $packCache -Force
    [IO.File]::WriteAllText((Join-Path $instance 'game_Data\level.bin'),'corrupt',(New-Object Text.UTF8Encoding($false)))
    $repairStatus=@(Repair-CocoStandaloneRequiredFiles $experience $instance $cacheRoot)
    if($repairStatus.Count-ne2-or(Get-FileHash -LiteralPath (Join-Path $instance 'game_Data\level.bin') -Algorithm SHA256).Hash.ToLowerInvariant()-ne$levelSha){
        throw 'La reparacion standalone no recupero desde su archivo fijado un archivo base corrupto sin cache.'
    }
    if(-not(Test-Path -LiteralPath $packCache -PathType Leaf)){throw 'La reparacion standalone no repuso el paquete verificado en cache.'}

    [IO.File]::WriteAllText((Join-Path $instance 'BepInEx\config\BigVoice.cfg'),'player-volume=37',(New-Object Text.UTF8Encoding($false)))

    $install2=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if($install2.Updated){throw 'Una instalacion idempotente informo actualizacion.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\config\BigVoice.cfg') -Raw)-ne'player-volume=37'){throw 'La apertura idempotente reemplazo una configuracion BepInEx del jugador.'}

    Remove-Item -LiteralPath (Join-Path $instance 'BepInEx\plugins\BigVoice.dll') -Force
    $installRepair=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$installRepair.Updated){throw 'La instalacion no reparo un mod extraido faltante.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'BepInEx\plugins\BigVoice.dll') -PathType Leaf)){throw 'El mod faltante no fue restaurado.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\config\BigVoice.cfg') -Raw)-ne'player-volume=37'){throw 'La reparacion de un mod reemplazo la configuracion BepInEx del jugador.'}

    $legacyState=[ordered]@{
        schemaVersion=1
        experienceId='standalone-extras-test'
        sha256=$gameSha
        size=$gameSize
        version='1.0.0'
        filesSha=$modsSha1
        installedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $instance '.coco\standalone-state.json'),($legacyState|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath (Join-Path $instance 'BepInEx\plugins\EnhancedControls.dll') -Force
    $legacyRepair=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$legacyRepair.Updated){throw 'Un estado legacy sin manifiesto no activo la reparacion de mods.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'BepInEx\plugins\EnhancedControls.dll') -PathType Leaf)){throw 'El mod faltante de un estado legacy no fue restaurado.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\config\BigVoice.cfg') -Raw)-ne'player-volume=37'){throw 'La migracion legacy reemplazo la configuracion BepInEx del jugador.'}

    [IO.File]::WriteAllText((Join-Path $modsStage 'BepInEx\plugins\BigVoice.dll'),'voice-mod-v2',(New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath (Join-Path $modsStage 'BepInEx\plugins\EnhancedControls.dll') -Force
    $modsZipV2=Join-Path $testRoot 'big-walk-mods-v2.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($modsStage,$modsZipV2,[IO.Compression.CompressionLevel]::Optimal,$false)
    $modsSha2=(Get-FileHash -LiteralPath $modsZipV2 -Algorithm SHA256).Hash.ToLowerInvariant()
    $modsSize2=(Get-Item -LiteralPath $modsZipV2).Length
    $experience.files[0].sourceUrl=$modsZipV2;$experience.files[0].sha256=$modsSha2;$experience.files[0].size=$modsSize2

    $install3=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$install3.Updated){throw 'Un cambio de extras no informo actualizacion.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\plugins\BigVoice.dll') -Raw)-ne'voice-mod-v2'){throw 'Los extras actualizados no reemplazaron el contenido.'}
    if(Test-Path -LiteralPath (Join-Path $instance 'BepInEx\plugins\EnhancedControls.dll') -PathType Leaf){throw 'Un plugin retirado del paquete standalone siguio instalado.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'BepInEx\config\BigVoice.cfg') -Raw)-ne'player-volume=37'){throw 'La actualizacion de extras reemplazo la configuracion BepInEx del jugador.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'game.exe') -PathType Leaf)){throw 'La actualizacion de extras borro el juego.'}
    $state3=Get-Content -LiteralPath (Join-Path $instance '.coco\standalone-state.json') -Raw|ConvertFrom-Json
    if([string]$state3.filesSha-ne$modsSha2){throw 'El estado no registro los extras actualizados.'}

    $hostInstall=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot '' host
    if(-not$hostInstall.Updated-or-not(Test-Path -LiteralPath (Join-Path $instance 'BepInEx\plugins\HostOnly.dll') -PathType Leaf)){throw 'El rol host standalone no instalo su archivo exclusivo.'}
    $clientInstall=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$clientInstall.Updated-or(Test-Path -LiteralPath (Join-Path $instance 'BepInEx\plugins\HostOnly.dll') -PathType Leaf)){throw 'El rol cliente standalone conservo un archivo exclusivo del host.'}

    $unsafeArchive=Join-Path $testRoot 'unsafe-game.zip'
    $unsafeZip=[IO.Compression.ZipFile]::Open($unsafeArchive,[IO.Compression.ZipArchiveMode]::Create)
    try{
        $unsafeEntry=$unsafeZip.CreateEntry('../escaped.txt')
        $unsafeWriter=[IO.StreamWriter]::new($unsafeEntry.Open(),[Text.Encoding]::UTF8)
        try{$unsafeWriter.Write('escape')}finally{$unsafeWriter.Dispose()}
    }finally{$unsafeZip.Dispose()}
    $unsafeSha=(Get-FileHash -LiteralPath $unsafeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    $unsafeExperience=[pscustomobject]@{
        id='unsafe-standalone';instanceId='unsafe-standalone';name='Unsafe';managementMode='managed'
        runtime=[pscustomobject]@{type='standalone';executable='unsafe.exe'}
        launch=[pscustomobject]@{workflow='coco-standalone';minimumFreeBytes=0;autoJoin=$false}
        pack=[pscustomobject]@{version='1.0.0';sha256=$unsafeSha;size=(Get-Item $unsafeArchive).Length;archives=@([pscustomobject]@{archiveUrl=$unsafeArchive;sha256=$unsafeSha;size=(Get-Item $unsafeArchive).Length})}
        files=@()
    }
    $unsafeRejected=$false
    try{Install-CocoStandaloneExperience $unsafeExperience $experiencesRoot $cacheRoot|Out-Null}catch{$unsafeRejected=$_.Exception.Message-match'ruta insegura o duplicada'}
    if(-not$unsafeRejected-or(Test-Path -LiteralPath (Join-Path $experiencesRoot 'escaped.txt'))){throw 'La extraccion standalone permitio escapar de la instancia.'}

    'PASS: instalacion standalone con extras, idempotencia y actualizacion de mods validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
