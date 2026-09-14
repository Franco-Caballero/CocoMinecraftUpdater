[CmdletBinding()]
param([string]$EnginePath='')

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engineFile=if([string]::IsNullOrWhiteSpace($EnginePath)){Join-Path $root 'engine\CocoLauncher.ps1'}else{[IO.Path]::GetFullPath($EnginePath)}
. $engineFile

$testRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-standalone-cleanup-test-$([guid]::NewGuid().ToString('N'))"
$experiencesRoot=Join-Path $testRoot 'experiences'
$cacheRoot=Join-Path $testRoot 'cache'
$locationsPath=Join-Path $cacheRoot 'instance-locations.json'
$downloadsDir=Join-Path $cacheRoot 'downloads\standalone-packs'
New-Item -ItemType Directory -Path $experiencesRoot,$downloadsDir -Force|Out-Null

function New-TestStandaloneExperience([string]$Id,[string]$Sha,[string]$Version='1.0.0'){
    [pscustomobject]@{
        id=$Id;instanceId=$Id;name=$Id;managementMode='managed'
        runtime=[pscustomobject]@{type='standalone';executable='game.exe';requiredFiles=@([pscustomobject]@{path='game.exe';size=4;sha256='6ca5cab77e702c787b4c14b3d3bf26bad43da606be6eed04ab0b9720120ae081';archiveSha256=$Sha})}
        pack=[pscustomobject]@{version=$Version;sha256=$Sha;size=10;archives=@([pscustomobject]@{archiveUrl="https://cleanup.invalid/$Id.zip";sha256=$Sha;size=10})}
        files=@()
    }
}

function Set-TestInstalledState($Experience,[string]$InstanceRoot){
    New-Item -ItemType Directory -Path (Join-Path $InstanceRoot '.coco') -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $InstanceRoot 'game.exe'),'game',(New-Object Text.UTF8Encoding($false)))
    $state=[ordered]@{
        schemaVersion=2;experienceId=[string]$Experience.id;sha256=[string]$Experience.pack.sha256
        size=[int64]$Experience.pack.size;version=[string]$Experience.pack.version;archiveShas=@($Experience.pack.archives|ForEach-Object{[string]$_.sha256});role='client';filesSha='none';extraFiles=@()
        installedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $InstanceRoot '.coco\standalone-state.json'),($state|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
}

function New-CacheResidue([string]$Sha,[string[]]$Suffixes){
    foreach($suffix in $Suffixes){[IO.File]::WriteAllText((Join-Path $downloadsDir "$Sha.zip$suffix"),'cache',(New-Object Text.UTF8Encoding($false)))}
}

try{
    $shaInstalled=('a'*64)
    $shaIncomplete=('b'*64)
    $shaOrphan=('c'*64)
    $shaCustom=('d'*64)
    $shaShared=('e'*64)

    $installed=New-TestStandaloneExperience 'installed' $shaInstalled
    $incomplete=New-TestStandaloneExperience 'incomplete' $shaIncomplete
    $custom=New-TestStandaloneExperience 'custom-clean' $shaCustom
    $sharedInstalled=New-TestStandaloneExperience 'shared-installed' $shaShared
    $sharedIncomplete=New-TestStandaloneExperience 'shared-incomplete' $shaShared

    Set-TestInstalledState $installed (Join-Path $experiencesRoot 'installed')
    Set-TestInstalledState $sharedInstalled (Join-Path $experiencesRoot 'shared-installed')
    $customRoot=Join-Path $testRoot 'custom-location'
    Set-TestInstalledState $custom $customRoot
    New-Item -ItemType Directory -Path (Split-Path $locationsPath -Parent) -Force|Out-Null
    [IO.File]::WriteAllText($locationsPath,([ordered]@{'custom-clean'=$customRoot}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Clear-CocoInstanceLocationsCache

    New-CacheResidue $shaInstalled @('','.partial','.repair.partial')
    New-CacheResidue $shaIncomplete @('','.partial')
    New-CacheResidue $shaOrphan @('','.partial')
    New-CacheResidue $shaCustom @('')
    New-CacheResidue $shaShared @('','.partial')
    [IO.File]::WriteAllText((Join-Path $downloadsDir 'keep-me.txt'),'unknown',(New-Object Text.UTF8Encoding($false)))

    $catalog=[pscustomobject]@{experiences=@($installed,$incomplete,$custom,$sharedInstalled,$sharedIncomplete)}
    $result=Invoke-CocoStandaloneInstallerCacheCleanup $catalog $experiencesRoot $cacheRoot $locationsPath

    foreach($name in @("$shaInstalled.zip","$shaInstalled.zip.partial","$shaInstalled.zip.repair.partial","$shaOrphan.zip","$shaOrphan.zip.partial","$shaCustom.zip")){
        if(Test-Path -LiteralPath (Join-Path $downloadsDir $name)){throw "El barrido no elimino el residuo seguro '$name'."}
    }
    foreach($name in @("$shaIncomplete.zip","$shaIncomplete.zip.partial","$shaShared.zip","$shaShared.zip.partial",'keep-me.txt')){
        if(-not(Test-Path -LiteralPath (Join-Path $downloadsDir $name) -PathType Leaf)){throw "El barrido elimino un archivo que debia conservar: '$name'."}
    }
    if($result.Files-ne6){throw "El barrido elimino una cantidad inesperada de archivos: $($result.Files)."}

    # Corrupcion del mismo tamano: el estado por si solo no basta para declarar
    # el juego sano. El instalador debe conservar el ZIP para una reparacion.
    [IO.File]::WriteAllText((Join-Path $customRoot 'game.exe'),'xxxx',(New-Object Text.UTF8Encoding($false)))
    New-CacheResidue $shaCustom @('')
    $corruptResult=Invoke-CocoStandaloneInstallerCacheCleanup $catalog $experiencesRoot $cacheRoot $locationsPath
    if(-not(Test-Path -LiteralPath (Join-Path $downloadsDir "$shaCustom.zip") -PathType Leaf)){
        throw 'El barrido elimino cache de una instalacion con corrupcion de igual tamano.'
    }
    if($corruptResult.Files-ne0){throw 'La limpieza trato una instalacion corrupta como valida.'}
    [IO.File]::WriteAllText((Join-Path $customRoot 'game.exe'),'game',(New-Object Text.UTF8Encoding($false)))

    # Un estado nuevo tambien fija exactamente las partes del pack. Aunque el
    # ejecutable este sano, un fingerprint multipart distinto debe conservar el
    # cache hasta que el estado vuelva a coincidir con el catalogo actual.
    $customStatePath=Join-Path $customRoot '.coco\standalone-state.json'
    $customState=Get-Content -LiteralPath $customStatePath -Raw|ConvertFrom-Json
    $customState.archiveShas=@(('f'*64))
    [IO.File]::WriteAllText($customStatePath,($customState|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    $mismatchResult=Invoke-CocoStandaloneInstallerCacheCleanup $catalog $experiencesRoot $cacheRoot $locationsPath
    if(-not(Test-Path -LiteralPath (Join-Path $downloadsDir "$shaCustom.zip") -PathType Leaf)-or$mismatchResult.Files-ne0){
        throw 'El barrido elimino cache pese a que archiveShas no coincide con el catalogo.'
    }
    $customState.archiveShas=@($custom.pack.archives|ForEach-Object{[string]$_.sha256})
    [IO.File]::WriteAllText($customStatePath,($customState|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))

    # Cuando la experiencia antes incompleta ya tiene estado final, su cache pasa
    # a ser prescindible y debe limpiarse en la siguiente apertura del launcher.
    Set-TestInstalledState $incomplete (Join-Path $experiencesRoot 'incomplete')
    $result2=Invoke-CocoStandaloneInstallerCacheCleanup $catalog $experiencesRoot $cacheRoot $locationsPath
    if((Test-Path -LiteralPath (Join-Path $downloadsDir "$shaIncomplete.zip")) -or (Test-Path -LiteralPath (Join-Path $downloadsDir "$shaIncomplete.zip.partial"))){
        throw 'El barrido no limpio una experiencia que paso a estar instalada.'
    }
    if($result2.Files-ne3){throw "La segunda limpieza elimino una cantidad inesperada: $($result2.Files)."}
    if(-not(Test-Path -LiteralPath (Join-Path $downloadsDir "$shaShared.zip") -PathType Leaf)){
        throw 'Un SHA compartido con una experiencia incompleta no fue protegido.'
    }

    'PASS: limpieza standalone retroactiva elimina instaladores seguros y conserva descargas reanudables.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
