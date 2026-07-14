[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $projectRoot 'engine\CocoUpdater.ps1'
$sourceJar=Get-ChildItem (Join-Path $projectRoot 'fabric-mod\build\libs') -File -Filter 'coco-session-bridge-*.jar'|Select-Object -First 1
if(-not$sourceJar){throw 'Compila fabric-mod antes de ejecutar esta prueba.'}

$testRoot=Join-Path $env:TEMP "coco-engine-recovery-$([guid]::NewGuid())"
$game=Join-Path $testRoot 'game'
$transient=Join-Path $game '.coco-mods-replacing'
$manifestPath=Join-Path $testRoot 'latest.json'
$targetPath=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\target.json'
$savedTarget=if(Test-Path $targetPath){[IO.File]::ReadAllBytes($targetPath)}else{$null}
try{
    New-Item -ItemType Directory -Path $transient,(Join-Path $game 'versions\fabric-loader-26.1.2') -Force|Out-Null
    Copy-Item $sourceJar.FullName (Join-Path $transient 'bridge.jar')
    Copy-Item $sourceJar.FullName (Join-Path $transient 'extra-that-must-disappear.jar')
    $hash=(Get-FileHash $sourceJar.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest=[ordered]@{
        schemaVersion=2;packId='coco-test';version='9.9.9'
        packages=@([ordered]@{role='client';mods=@([ordered]@{name='bridge.jar';url='unused';sha256=$hash;size=[int64]$sourceJar.Length})})
        detector=[ordered]@{minecraftVersion='26.1.2';markerPath='config/coco-updater-state.json';groupTokens=@();knownE4mcDomains=@();modRules=@()}
    }
    $manifest|ConvertTo-Json -Depth 8|Set-Content $manifestPath -Encoding UTF8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ManifestPath $manifestPath -GameDir $game -Silent
    if($LASTEXITCODE -ne 0){throw "Engine termino con codigo $LASTEXITCODE"}
    if(Test-Path $transient){throw 'La carpeta transitoria no fue eliminada.'}
    $installed=@(Get-ChildItem (Join-Path $game 'mods') -File -Filter '*.jar')
    if($installed.Count -ne 1 -or $installed[0].Name -ne 'bridge.jar'){throw 'La sustitucion exacta de mods fallo.'}
    $state=Get-Content (Join-Path $game 'config\coco-updater-state.json') -Raw|ConvertFrom-Json
    if($state.version-ne'9.9.9'-or$state.role-ne'client'){throw 'El marcador final es incorrecto.'}
    'PASS: recuperacion transaccional, reemplazo exacto y marcador final.'
}finally{
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    if($savedTarget){[IO.File]::WriteAllBytes($targetPath,$savedTarget)}else{Remove-Item $targetPath -Force -ErrorAction SilentlyContinue}
}
