[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$engine=Join-Path $projectRoot 'engine\CocoUpdater.ps1'
$manifest=Join-Path $PSScriptRoot 'mini-manifest.json'
$testRoot=Join-Path $env:TEMP "coco-network-install-$([guid]::NewGuid())"
$game=Join-Path $testRoot 'game'
$targetPath=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\target.json'
$savedTarget=if(Test-Path $targetPath){[IO.File]::ReadAllBytes($targetPath)}else{$null}
try{
    New-Item -ItemType Directory -Path (Join-Path $game 'mods'),(Join-Path $game 'versions\fabric-loader-26.1.2') -Force|Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ManifestPath $manifest -GameDir $game -Silent
    if($LASTEXITCODE -ne 0){throw "Instalacion de red termino con codigo $LASTEXITCODE"}
    if(@(Get-ChildItem (Join-Path $game 'mods') -File -Filter '*.jar').Count -ne 2){throw 'No quedaron exactamente los dos JARs remotos.'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine -ManifestPath $manifest -GameDir $game -Silent
    $watch.Stop()
    if($LASTEXITCODE -ne 0 -or $watch.Elapsed.TotalSeconds -gt 5){throw 'La segunda verificacion no reutilizo la instalacion actual.'}
    'PASS: descarga GitHub, SHA-256, instalacion exacta y reutilizacion.'
}finally{
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    if($savedTarget){[IO.File]::WriteAllBytes($targetPath,$savedTarget)}else{Remove-Item $targetPath -Force -ErrorAction SilentlyContinue}
}
