[CmdletBinding()]
param(
    [ValidateSet('client','host')][string]$Role = 'client',
    [switch]$CreateDummyInstances,
    [switch]$TestLocationPrompt
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$devRoot = Join-Path $env:TEMP ("coco-launcher-ui-dev-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$buildRoot = Join-Path $devRoot "build"
$engineRoot = Join-Path $devRoot "engine"
$testExperiencesRoot = Join-Path $devRoot "experiences"
$testMinecraftRoot = Join-Path $devRoot "minecraft"

New-Item -ItemType Directory -Path $buildRoot,$engineRoot,$testExperiencesRoot,$testMinecraftRoot -Force | Out-Null

if ($Role -eq 'host') {
    New-Item -ItemType Directory -Path (Join-Path $testMinecraftRoot 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $testMinecraftRoot 'config\coco-host.json') -Value '{"role":"host"}' -Encoding UTF8
}

if ($CreateDummyInstances) {
    # 1. Big Walk: 1.2 GB dummy instance
    $bigWalkDir = Join-Path $testExperiencesRoot 'big-walk'
    New-Item -ItemType Directory -Path $bigWalkDir -Force | Out-Null
    $bwFile = [IO.File]::Create((Join-Path $bigWalkDir 'dummy_game_data.bin'))
    $bwFile.SetLength(1250000000) # ~1.16 GB
    $bwFile.Close()

    # 2. Cobbleverse: 350 MB dummy instance
    $cobbleDir = Join-Path $testExperiencesRoot 'cobbleverse'
    New-Item -ItemType Directory -Path $cobbleDir -Force | Out-Null
    $cobFile = [IO.File]::Create((Join-Path $cobbleDir 'cobbleverse_data.bin'))
    $cobFile.SetLength(350000000) # ~333 MB
    $cobFile.Close()

    Write-Host "Instancias dummy creadas en: $testExperiencesRoot" -ForegroundColor Green
}

$release = Get-Content -LiteralPath (Join-Path $repoRoot 'release\latest.json') -Raw | ConvertFrom-Json
$built = & (Join-Path $repoRoot 'tools\New-CocoEngine.ps1') -Version ([string]$release.version) -OutputDirectory $buildRoot | ConvertFrom-Json
Expand-Archive -LiteralPath $built.path -DestinationPath $engineRoot

$manifestJson = Join-Path $repoRoot 'release\latest.json'
$updaterPath = Join-Path $engineRoot 'CocoUpdater.ps1'
$launcherPath = Join-Path $engineRoot 'CocoLauncher.ps1'
. $updaterPath -ManifestPath $manifestJson -DetectOnly
. $launcherPath

function Get-CocoLauncherRole([string]$LegacyMinecraftRoot) { return $Role }

$script:CocoEngineRoot = $engineRoot

if ($TestLocationPrompt) {
    $catalog = Read-CocoLauncherCatalog (Join-Path $engineRoot 'launcher\catalog.json')
    $sampleExp = @($catalog.experiences | Where-Object managementMode -eq 'managed')[0]
    Prompt-CocoExperienceLocationChoice $sampleExp $testExperiencesRoot
}

Write-Host "Abriendo Coco Launcher en modo de prueba ($Role)..." -ForegroundColor Cyan
Start-CocoLauncherUi -Manifest $release -LegacyMinecraftRoot $testMinecraftRoot -LauncherTestRoot $devRoot
