[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $root 'engine\CocoUpdater.ps1'
$bootstrap=Join-Path $root 'bootstrap\CocoBootstrapper.ps1'
$testRoot=Join-Path $env:TEMP "coco-automatic-update-$([guid]::NewGuid())"
$game=Join-Path $testRoot 'game'
$manifestPath=Join-Path $testRoot 'latest.json'
$sessionState=Join-Path $testRoot 'session.json'
$targetPath=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\target.json'
$savedTarget=if(Test-Path $targetPath){[IO.File]::ReadAllBytes($targetPath)}else{$null}
$dummy=$null

try{
    New-Item -ItemType Directory -Path (Join-Path $game 'mods'),(Join-Path $game 'config'),(Join-Path $game 'versions\fabric-loader-26.1.2') -Force|Out-Null
    $jar=Join-Path $game 'mods\bridge.jar'
    [IO.File]::WriteAllText($jar,'already-current-on-disk',(New-Object Text.UTF8Encoding($false)))
    $hash=(Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest=[ordered]@{
        schemaVersion=2;packId='coco-test';version='9.9.9'
        packages=@([ordered]@{role='client';mods=@([ordered]@{name='bridge.jar';url='unused';sha256=$hash;size=[int64](Get-Item $jar).Length})})
        detector=[ordered]@{minecraftVersion='26.1.2';markerPath='config/coco-updater-state.json';groupTokens=@();knownE4mcDomains=@();modRules=@()}
    }
    $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    [pscustomobject]@{packId='coco-test';version='9.9.9';role='client'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $game 'config\coco-updater-state.json') -Encoding UTF8

    $dummy=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    $savedRunningVersion=$env:COCO_RUNNING_PACK_VERSION
    $env:COCO_RUNNING_PACK_VERSION='9.9.8'
    try{
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ManifestPath $manifestPath -GameDir $game -MinecraftPid $dummy.Id -SessionStatePath $sessionState -AutomaticCloseTimeoutSeconds 1 -Silent -TestSuppressUi
    }finally{$env:COCO_RUNNING_PACK_VERSION=$savedRunningVersion}
    if($LASTEXITCODE-ne0){throw "Engine automatico termino con codigo $LASTEXITCODE."}
    $dummy.Refresh()
    if(-not$dummy.HasExited){throw 'Minecraft simulado siguio abierto con una version antigua cargada.'}
    $state=Get-Content -LiteralPath $sessionState -Raw|ConvertFrom-Json
    if($state.message-ne'Coco Pack actualizado'-or$state.detail-notmatch'Vuelve a abrir Minecraft'){
        throw 'El updater no solicito reabrir despues de cerrar la version antigua cargada.'
    }
    $marker=Get-Content -LiteralPath (Join-Path $game 'config\coco-updater-state.json') -Raw|ConvertFrom-Json
    if($marker.version-ne'9.9.9'){throw 'El reinicio automatico altero un pack que ya estaba correcto en disco.'}

    $dummy=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    [pscustomobject]@{
        packId='coco-test';version='9.9.9';role='client'
        installedAt=$dummy.StartTime.AddSeconds(10).ToString('o')
    }|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $game 'config\coco-updater-state.json') -Encoding UTF8
    Remove-Item -LiteralPath $sessionState -Force -ErrorAction SilentlyContinue
    $savedRunningVersion=$env:COCO_RUNNING_PACK_VERSION
    $env:COCO_RUNNING_PACK_VERSION=$null
    try{
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ManifestPath $manifestPath -GameDir $game -MinecraftPid $dummy.Id -SessionStatePath $sessionState -AutomaticCloseTimeoutSeconds 1 -Silent -TestSuppressUi
    }finally{$env:COCO_RUNNING_PACK_VERSION=$savedRunningVersion}
    if($LASTEXITCODE-ne0){throw "Engine manual simulado termino con codigo $LASTEXITCODE."}
    $dummy.Refresh()
    if(-not$dummy.HasExited){throw 'La ejecucion sin version explicita no cerro un Minecraft anterior a installedAt.'}

    $dummy=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru
    [pscustomobject]@{
        packId='coco-test';version='9.9.8';role='client'
        installedAt=$dummy.StartTime.AddSeconds(-10).ToString('o')
    }|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $game 'config\coco-updater-state.json') -Encoding UTF8
    Remove-Item -LiteralPath $sessionState -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ManifestPath $manifestPath -GameDir $game -MinecraftPid $dummy.Id -SessionStatePath $sessionState -AutomaticCloseTimeoutSeconds 1 -Silent -TestSuppressUi
    if($LASTEXITCODE-ne0){throw "Engine legado simulado termino con codigo $LASTEXITCODE."}
    $dummy.Refresh()
    if(-not$dummy.HasExited){throw 'Un Bridge antiguo sin version explicita no cerro Minecraft usando el marcador atrasado.'}
    $legacyLog=Get-ChildItem (Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\logs') -Filter 'updater-*.log' -File|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if(-not$legacyLog-or(Get-Content $legacyLog.FullName -Raw)-notmatch'Actualizacion conocida antes de preparar la red'){
        throw 'El engine no detecto la version legado antes de preparar la red.'
    }

    $bootstrapText=[IO.File]::ReadAllText($bootstrap)
    $engineText=[IO.File]::ReadAllText($engine)
    if($engineText-notmatch'AutomaticCloseTimeoutSeconds\s*=\s*8'-or
       $engineText-notmatch'Intentando cerrar Minecraft automaticamente'){
        throw 'El cliente no solicita cierre inmediato con un fallback automatico breve.'
    }
    if($bootstrapText-match'Move-Item\s+-LiteralPath\s+\$newExe\s+-Destination\s+\$canonicalExe'){
        throw 'El bootstrap vuelve a reemplazar directamente un EXE canonico que puede estar bloqueado.'
    }
    if($bootstrapText-match'File\]::Replace\(\$Source,\$Destination,\$null'-or
       $engineText-match'File\]::Replace\(\$Source,\$Destination,\$null'){
        throw 'El reemplazo diferido usa un backup nulo, invalido en Windows PowerShell 5.1.'
    }
    if($bootstrapText-notmatch'AddHours\(12\)'-or$bootstrapText-notmatch'\[IO\.File\]::Replace'-or
       $bootstrapText-notmatch'Apply-CocoBootstrapUpdate-\$PID'-or
       $engineText-notmatch'AddHours\(12\)'-or$engineText-notmatch'COCO_BOOTSTRAP_UPDATE_PENDING'-or
       $engineText-notmatch'Apply-CocoBootstrapUpdate-V2-\$PID'){
        throw 'El reemplazo diferido del bootstrap no tolera sesiones largas o carreras entre procesos.'
    }
    if($engineText-notmatch'Test-RunningMinecraftPredatesInstalledPack'-or$engineText-notmatch'installedAt\.AddSeconds\(-2\)'){
        throw 'La ejecucion manual no detecta un Minecraft iniciado antes de instalar el pack actual.'
    }
    'PASS: version cargada, proceso previo y marcador legado cierran antes de red; bootstrap bloqueado se difiere.'
}finally{
    if($dummy-and-not$dummy.HasExited){Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    if($savedTarget){[IO.File]::WriteAllBytes($targetPath,$savedTarget)}else{Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue}
}
