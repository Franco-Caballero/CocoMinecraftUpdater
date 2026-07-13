[CmdletBinding()]
param(
    [string]$ChannelPath,
    [string]$GameDir,
    [int64]$MinecraftPid = 0,
    [string]$SessionStatePath,
    [switch]$Preview,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
$script:Splash = $null

function Show-CocoSplash([string]$Status='Preparando el actualizador…') {
    if($Silent -and -not $Preview){return}
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form;$form.Text='Coco Minecraft Updater';$form.Size=New-Object Drawing.Size(560,210)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='None';$form.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $title=New-Object Windows.Forms.Label;$title.Text='✦ COCO UPDATER ✦';$title.Location=New-Object Drawing.Point(34,31)
    $title.Size=New-Object Drawing.Size(490,48);$title.TextAlign='MiddleCenter';$title.Font=New-Object Drawing.Font('Segoe UI Semibold',22)
    $title.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $detail=New-Object Windows.Forms.Label;$detail.Text=$Status;$detail.Location=New-Object Drawing.Point(34,91)
    $detail.Size=New-Object Drawing.Size(490,30);$detail.TextAlign='MiddleCenter';$detail.Font=New-Object Drawing.Font('Segoe UI',12)
    $detail.ForeColor=[Drawing.Color]::White
    $track=New-Object Windows.Forms.Panel;$track.Location=New-Object Drawing.Point(48,145);$track.Size=New-Object Drawing.Size(464,12)
    $track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $fill=New-Object Windows.Forms.Panel;$fill.Size=New-Object Drawing.Size(95,12);$fill.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $track.Controls.Add($fill);$form.Controls.AddRange(@($title,$detail,$track));$form.Show();[Windows.Forms.Application]::DoEvents()
    $script:Splash=$form;$script:SplashDetail=$detail;$script:SplashFill=$fill
}
function Set-CocoSplash([string]$Status,[int]$Progress){
    if(-not$script:Splash){return};$script:SplashDetail.Text=$Status;$script:SplashFill.Width=[Math]::Max(4,[int](4.64*$Progress))
    $script:Splash.Refresh();[Windows.Forms.Application]::DoEvents()
}
function Close-CocoSplash {if($script:Splash){$script:Splash.Close();$script:Splash.Dispose();$script:Splash=$null}}

Show-CocoSplash

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
Set-CocoSplash 'Comprobando la versión más reciente…' 35
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
    Set-CocoSplash 'Preparando la interfaz visual…' 62
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
if ($Preview) { $engineArguments += '-Preview' }
if ($Silent) { $engineArguments += '-Silent' }
Set-CocoSplash 'Abriendo Coco Updater…' 100
Close-CocoSplash
& powershell.exe @engineArguments
exit $LASTEXITCODE
