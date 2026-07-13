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
$script:EmbeddedFullbodyBase64 = '__FULLBODY_BASE64__'

function Show-CocoSplash([string]$Status='Preparando el actualizador...') {
    if($Silent -and -not $Preview){return}
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $key=[Drawing.Color]::FromArgb(1,2,3)
    $form=New-Object Windows.Forms.Form;$form.Text='Coco Minecraft Updater';$form.Size=New-Object Drawing.Size(1080,740)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='None';$form.BackColor=$key;$form.TransparencyKey=$key
    $form.AutoScaleMode='None';$form.ForeColor=[Drawing.Color]::White
    $panel=New-Object Windows.Forms.Panel;$panel.Location=New-Object Drawing.Point(25,190);$panel.Size=New-Object Drawing.Size(780,350)
    $panel.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $accent=New-Object Windows.Forms.Panel;$accent.Location=New-Object Drawing.Point(0,0);$accent.Size=New-Object Drawing.Size(9,350)
    $accent.BackColor=[Drawing.Color]::FromArgb(177,92,255);$panel.Controls.Add($accent)
    $sparkle=[char]0x2726
    $title=New-Object Windows.Forms.Label;$title.Text='Preparando Coco Updater';$title.Location=New-Object Drawing.Point(43,42)
    $title.Size=New-Object Drawing.Size(590,52);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',22)
    $title.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $detail=New-Object Windows.Forms.Label;$detail.Text=$Status;$detail.Location=New-Object Drawing.Point(46,108)
    $detail.Size=New-Object Drawing.Size(570,46);$detail.Font=New-Object Drawing.Font('Segoe UI',12);$detail.ForeColor=[Drawing.Color]::FromArgb(218,210,229)
    $track=New-Object Windows.Forms.Panel;$track.Location=New-Object Drawing.Point(46,180);$track.Size=New-Object Drawing.Size(570,30)
    $track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $fill=New-Object Windows.Forms.Panel;$fill.Size=New-Object Drawing.Size(12,30);$fill.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $brand=New-Object Windows.Forms.Label;$brand.Text="$sparkle  COCO PACK  |  FABRIC 26.1.2";$brand.Location=New-Object Drawing.Point(46,244)
    $brand.Size=New-Object Drawing.Size(620,25);$brand.Font=New-Object Drawing.Font('Segoe UI Semibold',10);$brand.ForeColor=[Drawing.Color]::FromArgb(177,92,255)
    $track.Controls.Add($fill);$panel.Controls.AddRange(@($title,$detail,$track,$brand))
    $art=New-Object Windows.Forms.PictureBox;$art.Location=New-Object Drawing.Point(675,5);$art.Size=New-Object Drawing.Size(380,720)
    $art.SizeMode='Zoom';$art.BackColor=[Drawing.Color]::Transparent
    try{
        if($script:EmbeddedFullbodyBase64.Length -gt 1000){
            $bytes=[Convert]::FromBase64String($script:EmbeddedFullbodyBase64);$memory=New-Object IO.MemoryStream(,$bytes)
            $art.Image=[Drawing.Image]::FromStream($memory);$script:EmbeddedImageStream=$memory
        }elseif(Test-Path (Join-Path $PSScriptRoot '..\fullbody.png')){$art.Image=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot '..\fullbody.png'))}
    }catch{}
    $form.Controls.Add($panel);$form.Controls.Add($art);$art.BringToFront();$form.Show();[Windows.Forms.Application]::DoEvents()
    $script:Splash=$form;$script:SplashDetail=$detail;$script:SplashFill=$fill
    $script:SplashTitle=$title
    $global:CocoSharedUi=@{Form=$form;Title=$title;Detail=$detail;Progress=$fill;Started=[Diagnostics.Stopwatch]::StartNew();BaseProgress=12}
}
function Set-CocoSplash([string]$Status,[int]$Progress){
    if(-not$script:Splash){return};$script:SplashTitle.Text='Preparando Coco Updater';$script:SplashDetail.Text=$Status;$script:SplashFill.Width=[Math]::Max(4,[int](5.7*$Progress))
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

Set-CocoSplash 'Comprobando la version mas reciente...' 5
Invoke-WebRequest -Uri $channel.manifestUrl -OutFile $manifestCache -UseBasicParsing
$manifest = Get-Content -LiteralPath $manifestCache -Raw | ConvertFrom-Json

if (-not $manifest.engine -or -not $manifest.engine.version -or -not $manifest.engine.url -or -not $manifest.engine.sha256) {
    throw 'El manifiesto remoto no contiene un motor valido.'
}

$engineRoot = Join-Path $cacheRoot (Join-Path 'engine' $manifest.engine.version)
$entryPoint = Join-Path $engineRoot 'CocoUpdater.ps1'
if (-not (Test-Path -LiteralPath $entryPoint)) {
    $engineZip = Join-Path $cacheRoot "engine-$($manifest.engine.version).zip"
    Set-CocoSplash 'Preparando la interfaz visual...' 9
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

$engineParameters = @{ManifestPath=$manifestCache;ManifestUrl=$channel.manifestUrl}
if ($GameDir) { $engineParameters.GameDir=$GameDir }
if ($MinecraftPid -gt 0) { $engineParameters.MinecraftPid=$MinecraftPid }
if ($SessionStatePath) { $engineParameters.SessionStatePath=$SessionStatePath }
if ($Preview) { $engineParameters.Preview=$true }
if ($Silent) { $engineParameters.Silent=$true }
Set-CocoSplash 'Analizando la instalacion de Minecraft...' 12
try{
    & $entryPoint @engineParameters
}catch{
    if(-not$script:Splash){Show-CocoSplash}
    $script:SplashTitle.Text='No se pudo iniciar Coco Updater'
    $script:SplashDetail.Text=$_.Exception.Message
    $script:SplashFill.Width=12
    $script:Splash.Refresh();[Windows.Forms.Application]::DoEvents();Start-Sleep -Seconds 8
    exit 1
}
