[CmdletBinding()]
param(
    [string]$ChannelPath,
    [string]$GameDir,
    [int64]$MinecraftPid = 0,
    [string]$SessionStatePath,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-VerifiedFile([string]$Url, [string]$Destination, [string]$ExpectedHash) {
    $partial = "$Destination.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    if ((Get-Sha256 $partial) -ne $ExpectedHash.ToLowerInvariant()) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "La descarga no coincide con el hash SHA-256 publicado."
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

if ([string]::IsNullOrWhiteSpace($ChannelPath)) {
    $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetExtension($processPath) -ieq '.exe') {
        $ChannelPath = Join-Path (Split-Path $processPath -Parent) 'CocoUpdater.channel.json'
    } else {
        $ChannelPath = Join-Path $PSScriptRoot '..\CocoUpdater.channel.json'
    }
}

$defaultManifestUrl = 'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json'
if (Test-Path -LiteralPath $ChannelPath) {
    $channel = Get-Content -LiteralPath $ChannelPath -Raw | ConvertFrom-Json
} else {
    $channel = [pscustomobject]@{ manifestUrl = $defaultManifestUrl; channel = 'stable' }
}
if ([string]::IsNullOrWhiteSpace($channel.manifestUrl) -or $channel.manifestUrl -like '*REEMPLAZAR_*') {
    throw "Configura manifestUrl en CocoUpdater.channel.json antes de distribuir el actualizador."
}

$cacheRoot = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'
$manifestCache = Join-Path $cacheRoot 'latest.json'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

Write-Host 'Buscando actualización del pack Coco...'
Invoke-WebRequest -Uri $channel.manifestUrl -OutFile $manifestCache -UseBasicParsing
$manifest = Get-Content -LiteralPath $manifestCache -Raw | ConvertFrom-Json

if (-not $manifest.engine -or -not $manifest.engine.version -or -not $manifest.engine.url -or -not $manifest.engine.sha256) {
    throw 'El manifiesto remoto no contiene un motor válido.'
}

$engineRoot = Join-Path $cacheRoot (Join-Path 'engine' $manifest.engine.version)
$entryPoint = Join-Path $engineRoot 'CocoUpdater.ps1'
if (-not (Test-Path -LiteralPath $entryPoint)) {
    $engineZip = Join-Path $cacheRoot "engine-$($manifest.engine.version).zip"
    Write-Host "Actualizando el motor a $($manifest.engine.version)..."
    Download-VerifiedFile $manifest.engine.url $engineZip $manifest.engine.sha256
    $temporaryRoot = "$engineRoot.new"
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Expand-Archive -LiteralPath $engineZip -DestinationPath $temporaryRoot -Force
    New-Item -ItemType Directory -Path (Split-Path $engineRoot -Parent) -Force | Out-Null
    Move-Item -LiteralPath $temporaryRoot -Destination $engineRoot -Force
}

$processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([IO.Path]::GetExtension($processPath) -ieq '.exe') {
    $maintenanceRoot = Join-Path $cacheRoot 'bootstrapper'
    New-Item -ItemType Directory -Path $maintenanceRoot -Force | Out-Null
    $maintenanceExe = Join-Path $maintenanceRoot 'CocoUpdater.exe'
    $maintenanceChannel = Join-Path $maintenanceRoot 'CocoUpdater.channel.json'
    if (-not [string]::Equals($processPath, $maintenanceExe, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $processPath -Destination $maintenanceExe -Force
    }
    if ((Test-Path -LiteralPath $ChannelPath) -and -not [string]::Equals($ChannelPath, $maintenanceChannel, [System.StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $ChannelPath -Destination $maintenanceChannel -Force
    } elseif (-not (Test-Path -LiteralPath $maintenanceChannel)) {
        $channel | ConvertTo-Json | Set-Content -LiteralPath $maintenanceChannel -Encoding UTF8
    }
    $env:COCO_BOOTSTRAPPER_EXE = $maintenanceExe
    Copy-Item -LiteralPath $maintenanceExe -Destination (Join-Path $cacheRoot 'CocoUpdater.exe') -Force
    Copy-Item -LiteralPath $maintenanceChannel -Destination (Join-Path $cacheRoot 'CocoUpdater.channel.json') -Force
}

$engineArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entryPoint, '-ManifestPath', $manifestCache, '-ManifestUrl', $channel.manifestUrl)
if ($GameDir) { $engineArguments += @('-GameDir',$GameDir) }
if ($MinecraftPid -gt 0) { $engineArguments += @('-MinecraftPid',$MinecraftPid) }
if ($SessionStatePath) { $engineArguments += @('-SessionStatePath',$SessionStatePath) }
if ($Silent) { $engineArguments += '-Silent' }
& powershell.exe @engineArguments
exit $LASTEXITCODE
