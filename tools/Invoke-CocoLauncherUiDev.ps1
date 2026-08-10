[CmdletBinding()]
param(
    [ValidateSet('client','host')][string]$Role = 'client',
    [switch]$CreateDummyInstances,
    [switch]$TestLocationPrompt,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'
$CocoUiDevRequestedRole = [string]$Role
$repoRoot = Split-Path $PSScriptRoot -Parent
$devRoot = Join-Path $env:TEMP ("coco-launcher-ui-dev-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$buildRoot = Join-Path $devRoot "build"
$engineRoot = Join-Path $devRoot "engine"
$testExperiencesRoot = Join-Path $devRoot "experiences"
$testMinecraftRoot = Join-Path $devRoot "minecraft"

New-Item -ItemType Directory -Path $buildRoot,$engineRoot,$testExperiencesRoot,$testMinecraftRoot -Force | Out-Null

if ($CocoUiDevRequestedRole -eq 'host') {
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
$global:CocoUiDevRoleOverride = $CocoUiDevRequestedRole
$null = . $updaterPath -ManifestPath $manifestJson -DetectOnly
. $launcherPath

$script:CocoEngineRoot = $engineRoot
$global:CocoUiDevTestLocationPrompt = $TestLocationPrompt
$global:CocoUiDevDummyInstaller = {
    param($Experience,[string]$InstanceRoot,$Paths)
    New-Item -ItemType Directory -Path $InstanceRoot -Force | Out-Null
    $marker = Join-Path $InstanceRoot '.coco-ui-dev-dummy.json'
    $payload = [ordered]@{
        experienceId = [string]$Experience.id
        name = [string]$Experience.name
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        testOnly = $true
    }
    [IO.File]::WriteAllText($marker, ($payload | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $data = Join-Path $InstanceRoot 'dummy-game-data.bin'
    $stream = [IO.File]::Create($data)
    try { $stream.SetLength(4MB) } finally { $stream.Dispose() }
    [pscustomobject]@{ InstanceRoot = $InstanceRoot; Updated = $true; TestDummy = $true }
}

if($NoUi){
    try{
        [pscustomobject]@{Role=$CocoUiDevRequestedRole;EngineRoot=$engineRoot;ExperiencesRoot=$testExperiencesRoot;StorePath=(Join-Path $devRoot 'cache\instance-locations.json')}
    }finally{
        Remove-Variable -Name CocoUiDevRoleOverride,CocoUiDevTestLocationPrompt,CocoUiDevDummyInstaller -Scope Global -ErrorAction SilentlyContinue
    }
    return
}

Write-Host "Abriendo Coco Launcher en modo de prueba ($CocoUiDevRequestedRole)..." -ForegroundColor Cyan
Write-Host "Rol de prueba forzado: $CocoUiDevRequestedRole | Engine: $engineRoot" -ForegroundColor Green
try {
    Start-CocoLauncherUi -Manifest $release -LegacyMinecraftRoot $testMinecraftRoot -LauncherTestRoot $devRoot -RoleOverride $CocoUiDevRequestedRole
} finally {
    Remove-Variable -Name CocoUiDevRoleOverride,CocoUiDevTestLocationPrompt,CocoUiDevDummyInstaller -Scope Global -ErrorAction SilentlyContinue
}
