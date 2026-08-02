[CmdletBinding()]
param(
    [ValidateSet('Ascent', 'Haven')][string]$Map = 'Ascent',
    [string]$InstanceRoot = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'CocoMinecraft\experiences\valorant-craft'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mapDefinitions = @{
    Ascent = [pscustomobject]@{
        WorldName = 'VALORANT - Ascent'
        ArchiveName = 'MC x VAL - Ascent.zip'
        SourceUrl = 'https://ommo.me/dist/cdn/MC%20x%20VAL%20-%20Ascent.zip'
        Sha256 = '4e14bb28354f3d199a4dfe9fcfe59b11e032a180057a71a937bb3be935cccfc3'
    }
    Haven = [pscustomobject]@{
        WorldName = 'VALORANT - Haven'
        ArchiveName = 'MC x VAL - Haven V2.zip'
        SourceUrl = 'https://ommo.me/dist/cdn/MC%20x%20VAL%20-%20Haven%20V2.zip'
        Sha256 = '2daa1cdda3d518505ee1d18a6e1bee19c9687411b4e87291e32dca9a8ae89a3e'
    }
}
$definition = $mapDefinitions[$Map]

$fullInstanceRoot = [IO.Path]::GetFullPath($InstanceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$savesRoot = Join-Path $fullInstanceRoot 'saves'
$worldPath = Join-Path $savesRoot $definition.WorldName
$cacheRoot = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\map-cache\valorant-x-minecraft'
$workRoot = Join-Path $env:TEMP ('coco-valorant-map-restore-' + [guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $cacheRoot $definition.ArchiveName
$orbSource = Join-Path $repoRoot 'launcher\experiences\valorant-craft\agent-orb-datapack'

function Test-CocoPathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $childFull = [IO.Path]::GetFullPath($Child).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    return $childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CocoSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Copy-CocoDirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $fullInstanceRoot -PathType Container)) {
    throw "No existe la instancia administrada: $fullInstanceRoot"
}
if (-not (Test-Path -LiteralPath $orbSource -PathType Container)) {
    throw "No existe el datapack de Orb en el repositorio: $orbSource"
}
if (-not (Test-CocoPathInside -Child $worldPath -Parent $fullInstanceRoot)) {
    throw 'La ruta del mundo no esta contenida en la instancia administrada.'
}

$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(java|javaw|CocoPublisher)\.exe$' -and
        (($_.Name -match '^CocoPublisher\.exe$') -or ($_.CommandLine -match '(?i)minecraft|forge|fabric'))
    })
if ($running.Count -gt 0) {
    throw 'Cierra Minecraft y CocoPublisher antes de restaurar un mundo.'
}

New-Item -ItemType Directory -Path $cacheRoot, $workRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or (Get-CocoSha256 -Path $archivePath) -ne $definition.Sha256) {
    $downloadPath = Join-Path $workRoot $definition.ArchiveName
    Write-Host "Descargando fuente oficial de $Map..."
    Invoke-WebRequest -UseBasicParsing -Uri $definition.SourceUrl -OutFile $downloadPath
    $downloadHash = Get-CocoSha256 -Path $downloadPath
    if ($downloadHash -ne $definition.Sha256) {
        throw "El SHA-256 de la descarga no coincide. Esperado $($definition.Sha256), recibido $downloadHash"
    }
    Copy-Item -LiteralPath $downloadPath -Destination $archivePath -Force
}
$archiveHash = Get-CocoSha256 -Path $archivePath
if ($archiveHash -ne $definition.Sha256) {
    throw "La cache del mapa no coincide con la fuente oficial: $archivePath"
}

$extractRoot = Join-Path $workRoot 'extracted'
Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
$levelFiles = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'level.dat')
if ($levelFiles.Count -ne 1) {
    throw "La fuente oficial debe contener exactamente un level.dat; se encontraron $($levelFiles.Count)."
}
$sourceWorld = Split-Path -Parent $levelFiles[0].FullName
if (-not (Test-Path -LiteralPath (Join-Path $sourceWorld 'region') -PathType Container)) {
    throw 'La fuente oficial no contiene region/. '
}

$sourceIconHash = Get-CocoSha256 -Path (Join-Path $sourceWorld 'icon.png')
$liveWorldExists = Test-Path -LiteralPath $worldPath -PathType Container
$liveIconMatch = $false
$liveRegionCommon = 0
$liveRegionIdentical = 0
if ($liveWorldExists) {
    $liveIconPath = Join-Path $worldPath 'icon.png'
    if (Test-Path -LiteralPath $liveIconPath -PathType Leaf) {
        $liveIconMatch = (Get-CocoSha256 -Path $liveIconPath) -eq $sourceIconHash
    }
    if (-not $liveIconMatch) {
        throw "El mundo existente '$($definition.WorldName)' no coincide con la fuente oficial por icon.png; se detiene por seguridad."
    }
    $sourceRegionsPath = Join-Path $sourceWorld 'region'
    $liveRegionsPath = Join-Path $worldPath 'region'
    foreach ($liveRegion in @(Get-ChildItem -LiteralPath $liveRegionsPath -File -Filter '*.mca' -ErrorAction SilentlyContinue)) {
        $sourceRegion = Join-Path $sourceRegionsPath $liveRegion.Name
        if (Test-Path -LiteralPath $sourceRegion -PathType Leaf) {
            $liveRegionCommon++
            if ((Get-CocoSha256 -Path $liveRegion.FullName) -eq (Get-CocoSha256 -Path $sourceRegion)) {
                $liveRegionIdentical++
            }
        }
    }
}

$stagedWorld = Join-Path $workRoot 'world'
Copy-CocoDirectoryContents -Source $sourceWorld -Destination $stagedWorld

# Keep the 1.20.1-compatible metadata and server settings from the managed instance.
# The official map ZIP is published for 1.20.4+, while this experience runs 1.20.1.
if ($liveWorldExists) {
    foreach ($metadataName in @('level.dat', 'level.dat_old')) {
        $currentMetadata = Join-Path $worldPath $metadataName
        if (Test-Path -LiteralPath $currentMetadata -PathType Leaf) {
            Copy-Item -LiteralPath $currentMetadata -Destination (Join-Path $stagedWorld $metadataName) -Force
        }
    }
    $currentServerConfig = Join-Path $worldPath 'serverconfig'
    if (Test-Path -LiteralPath $currentServerConfig -PathType Container) {
        $stagedServerConfig = Join-Path $stagedWorld 'serverconfig'
        if (Test-Path -LiteralPath $stagedServerConfig) {
            Remove-Item -LiteralPath $stagedServerConfig -Recurse -Force
        }
        Copy-Item -LiteralPath $currentServerConfig -Destination $stagedWorld -Recurse -Force
    }
    $currentWifi = Join-Path $worldPath 'mcwifipnp.json'
    if (Test-Path -LiteralPath $currentWifi -PathType Leaf) {
        Copy-Item -LiteralPath $currentWifi -Destination (Join-Path $stagedWorld 'mcwifipnp.json') -Force
    }
}

# A clean map must not retain the previous player's inventory, advancements or statistics.
foreach ($cleanPath in @('playerdata', 'advancements', 'stats', 'session.lock')) {
    $path = Join-Path $stagedWorld $cleanPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

$stagedDatapacks = Join-Path $stagedWorld 'datapacks'
New-Item -ItemType Directory -Path $stagedDatapacks -Force | Out-Null
$stagedOrb = Join-Path $stagedDatapacks 'coco_agent_orb'
if (Test-Path -LiteralPath $stagedOrb) {
    Remove-Item -LiteralPath $stagedOrb -Recurse -Force
}
Copy-CocoDirectoryContents -Source $orbSource -Destination $stagedOrb

$backupStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $env:LOCALAPPDATA "CocoMinecraftUpdater\backups\valorant-map-reset-$($Map.ToLowerInvariant())-$backupStamp"
$backupWorld = Join-Path $backupRoot $definition.WorldName

Write-Host ''
Write-Host "Mapa fuente: $($definition.SourceUrl)"
Write-Host "SHA-256: $archiveHash"
Write-Host "Fuente coincide con icon.png local: $liveIconMatch"
Write-Host "Chunks region comunes: $liveRegionCommon; identicos: $liveRegionIdentical"
Write-Host "Destino: $worldPath"
Write-Host "Respaldo que se usaria: $backupWorld"

if (-not $Apply) {
    Write-Host 'DRY RUN: no se modifico el mundo. Usa -Apply para respaldar y restaurar.' -ForegroundColor Yellow
    exit 0
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
if ($liveWorldExists) {
    Move-Item -LiteralPath $worldPath -Destination $backupRoot
}
try {
    Move-Item -LiteralPath $stagedWorld -Destination $worldPath
}
catch {
    if ($liveWorldExists -and -not (Test-Path -LiteralPath $worldPath)) {
        Move-Item -LiteralPath $backupWorld -Destination $savesRoot
    }
    throw
}

Write-Host "RESTAURADO: $worldPath" -ForegroundColor Green
Write-Host "BACKUP RECUPERABLE: $backupWorld" -ForegroundColor Green
