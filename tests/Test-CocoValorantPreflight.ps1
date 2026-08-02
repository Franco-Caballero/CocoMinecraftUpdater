[CmdletBinding()]
param(
    [string]$InstanceRoot = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'CocoMinecraft\experiences\valorant-craft'),
    [switch]$RequireMapSetup
)

$ErrorActionPreference = 'Stop'

$checks = New-Object System.Collections.Generic.List[object]

function Add-PreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail,
        [bool]$Critical = $true
    )

    $checks.Add([pscustomobject]@{
            Name     = $Name
            Passed   = $Passed
            Critical = $Critical
            Detail   = $Detail
        })
}

function Get-FirstMatchingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Name -match $Pattern } | Select-Object -First 1
}

function Test-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Expected
    )

    $property = $Object.PSObject.Properties[$Name]
    return $null -ne $property -and [string]$property.Value -eq [string]$Expected
}

$rootExists = Test-Path -LiteralPath $InstanceRoot -PathType Container
Add-PreflightCheck -Name 'Instancia administrada' -Passed $rootExists -Detail $InstanceRoot

if (-not $rootExists) {
    $checks | Format-Table -AutoSize
    throw "No existe la instancia administrada: $InstanceRoot"
}

$modsPath = Join-Path $InstanceRoot 'mods'
$taczPath = Join-Path $InstanceRoot 'tacz'
$configPath = Join-Path $InstanceRoot 'config'
$savesPath = Join-Path $InstanceRoot 'saves'
$repoRoot = Split-Path -Parent $PSScriptRoot
$lockPath = Join-Path $repoRoot 'launcher\experiences\valorant-craft.lock.json'
$valorantLock = Test-JsonFile -Path $lockPath

$requiredMods = @(
    @{ Name = 'TACZ'; Pattern = '^tacz-.*\.jar$' },
    @{ Name = 'CSmain'; Pattern = '^csmain-.*\.jar$' },
    @{ Name = 'Origins Forge'; Pattern = '^origins-forge-.*\.jar$' },
    @{ Name = 'Valorant Origins'; Pattern = '^Valorant_Origins\+.*\.jar$' },
    @{ Name = 'MCWiFiPnP'; Pattern = '^MCWiFiPnP-.*\.jar$' },
    @{ Name = 'Coco VALORANT Tools'; Pattern = '^coco-valorant-tools-.*\.jar$' }
)

foreach ($requiredMod in $requiredMods) {
    $mod = Get-FirstMatchingFile -Path $modsPath -Pattern $requiredMod.Pattern
    Add-PreflightCheck -Name "Mod $($requiredMod.Name)" -Passed ($null -ne $mod) -Detail $(if ($mod) { $mod.Name } else { 'FALTA' })
}

$toolsMod = Get-FirstMatchingFile -Path $modsPath -Pattern '^coco-valorant-tools-.*\.jar$'
$toolsAsset = if ($null -ne $valorantLock) {
    @($valorantLock.assets | Where-Object { $_.path -eq 'mods/coco-valorant-tools-0.1.0.jar' } | Select-Object -First 1)
}
else {
    $null
}
$toolsHashOk = $false
if ($toolsMod -and $toolsAsset) {
    $toolsHash = (Get-FileHash -LiteralPath $toolsMod.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $toolsHashOk = $toolsMod.Length -eq [int64]$toolsAsset.size -and $toolsHash -eq ([string]$toolsAsset.sha256).ToLowerInvariant()
    Add-PreflightCheck -Name 'Coco VALORANT Tools verificado' -Passed $toolsHashOk -Detail "$($toolsMod.Name), SHA256=$toolsHash"
}
else {
    Add-PreflightCheck -Name 'Coco VALORANT Tools verificado' -Passed $false -Detail 'FALTA el asset o su referencia en el lock'
}

$gunpack = Get-FirstMatchingFile -Path $taczPath -Pattern '^Valorant_gunpack_.*\.zip$'
$gunpackHashOk = $false
if ($gunpack) {
    $gunpackHash = (Get-FileHash -LiteralPath $gunpack.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $lock = $valorantLock
    $expectedGunpackHash = @($lock.assets | Where-Object { $_.path -eq 'tacz/Valorant_gunpack_v0.1.3_hotfix_4.zip' } | Select-Object -First 1).sha256
    $gunpackHashOk = $null -ne $expectedGunpackHash -and $gunpackHash -eq $expectedGunpackHash.ToLowerInvariant()
    Add-PreflightCheck -Name 'Gunpack Valorant oficial' -Passed $gunpackHashOk -Detail "$($gunpack.Name), SHA256=$gunpackHash"
}
else {
    Add-PreflightCheck -Name 'Gunpack Valorant oficial' -Passed $false -Detail 'FALTA en tacz/'
}

$statePath = Join-Path $configPath 'killfeedtacz_state.json'
$state = Test-JsonFile -Path $statePath
$stateOk = $null -ne $state
if ($stateOk) {
    $requiredStateProperties = @(
        'warmupSeconds', 'freezeSeconds', 'buySeconds', 'roundSeconds',
        'bombSeconds', 'plantTicks', 'defuseTicks', 'defuseKitTicks',
        'winRounds', 'bombEnabled', 'giveBombAtRoundStart',
        'autoRespawnRoundStart', 'scopeRestrictionEnabled', 'startItemAll', 'classic1', 'ammoBox', 'shop'
    )
    $missingStateProperties = @($requiredStateProperties | Where-Object { $null -eq $state.PSObject.Properties[$_] })
    $knifeEntries = @($state.shop | Where-Object {
            $_.id -eq 'knife' -and
            $_.itemId -eq 'lrtactical:melee' -and
            $_.templateSnbt -match 'killfeedtacz_knife:1b'
        })
    $stateOk = $missingStateProperties.Count -eq 0 -and
        [string]$state.startItemAll -eq 'shop:knife' -and
        $knifeEntries.Count -eq 1
    $stateDetail = if ($stateOk) {
        'CSmain state, tienda, cuchillo inicial y carga de ronda presentes'
    }
    elseif ($missingStateProperties.Count -gt 0) {
        "Faltan claves: $($missingStateProperties -join ', ')"
    }
    else {
        'Falta startItemAll=shop:knife o la entrada de cuchillo TACZ'
    }
}
else {
    $stateDetail = 'FALTA o JSON inválido'
}
Add-PreflightCheck -Name 'Configuración CSmain' -Passed $stateOk -Detail $stateDetail

$worlds = @()
if (Test-Path -LiteralPath $savesPath -PathType Container) {
    $worlds = @(Get-ChildItem -LiteralPath $savesPath -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') })
}
Add-PreflightCheck -Name 'Mundos VALORANT disponibles' -Passed ($worlds.Count -ge 1) -Detail "$($worlds.Count) mundo(s) con level.dat"

$mapSetupWorlds = 0
foreach ($world in $worlds) {
    $worldName = $world.Name
    $datapackPath = Join-Path $world.FullName 'datapacks\coco_agent_orb'
    $packMetaPath = Join-Path $datapackPath 'pack.mcmeta'
    $tickPath = Join-Path $datapackPath 'data\minecraft\tags\functions\tick.json'
    $orbFunctionPath = Join-Path $datapackPath 'data\coco_agent_orb\functions\tick.mcfunction'
    $orbPackOk = (Test-Path -LiteralPath $packMetaPath -PathType Leaf) -and
        (Test-Path -LiteralPath $tickPath -PathType Leaf) -and
        (Test-Path -LiteralPath $orbFunctionPath -PathType Leaf) -and
        ((Get-Content -LiteralPath $orbFunctionPath -Raw) -match 'origins:orb_of_origin')
    Add-PreflightCheck -Name "Datapack legado de Orb: $worldName" -Passed $orbPackOk -Critical $false -Detail $(if ($orbPackOk) { 'presente (compatibilidad con mundos existentes)' } else { 'opcional; Coco VALORANT Tools distribuye el Orb' })

    $wifiPath = Join-Path $world.FullName 'mcwifipnp.json'
    $wifi = Test-JsonFile -Path $wifiPath
    $wifiOk = $null -ne $wifi -and
        (Test-PropertyValue -Object $wifi -Name 'port' -Expected 25565) -and
        (Test-PropertyValue -Object $wifi -Name 'UseUPnP' -Expected $false) -and
        (Test-PropertyValue -Object $wifi -Name 'OnlineMode' -Expected $false) -and
        (Test-PropertyValue -Object $wifi -Name 'EnableUUIDFixer' -Expected $true)
    Add-PreflightCheck -Name "LAN MCWiFiPnP: $worldName" -Passed $wifiOk -Detail $(if ($wifiOk) { '25565/offline/UUIDFixer' } else { 'FALTA o configuración incorrecta' })

    $invalidDatapacks = @(Get-ChildItem -LiteralPath (Join-Path $world.FullName 'datapacks') -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(valorant_match|valorant_only_origins)' })
    Add-PreflightCheck -Name "Datapacks antiguos: $worldName" -Passed ($invalidDatapacks.Count -eq 0) -Detail $(if ($invalidDatapacks.Count -eq 0) { 'ninguno activo' } else { $invalidDatapacks.Name -join ', ' })

    $setupProperties = @('hubX', 'hubY', 'hubZ', 'spawnTX', 'spawnTY', 'spawnTZ', 'spawnCTX', 'spawnCTY', 'spawnCTZ', 'bombX', 'bombY', 'bombZ', 'bomb2X', 'bomb2Y', 'bomb2Z')
    $defaultSetup = @{
        hubX = 0.5; hubY = 80; hubZ = 0.5
        spawnTX = 0.5; spawnTY = 64; spawnTZ = 6.5
        spawnCTX = 0.5; spawnCTY = 64; spawnCTZ = -6.5
        bombX = 0; bombY = 64; bombZ = 0
        bomb2X = 10; bomb2Y = 64; bomb2Z = 0
    }
    $worldState = Test-JsonFile -Path (Join-Path $world.FullName 'serverconfig\killfeedtacz-server.json')
    if ($null -eq $worldState) {
        $worldState = $state
    }
    $missingSetup = @($setupProperties | Where-Object { $null -eq $worldState.PSObject.Properties[$_] })
    $nonDefaultSetup = @($setupProperties | Where-Object {
            $property = $worldState.PSObject.Properties[$_]
            $null -ne $property -and [double]$property.Value -ne [double]$defaultSetup[$_]
        })
    $worldSetupOk = $missingSetup.Count -eq 0 -and $nonDefaultSetup.Count -eq $setupProperties.Count
    if ($worldSetupOk) { $mapSetupWorlds++ }
    Add-PreflightCheck -Name "Mapa CSmain: $worldName" -Passed $worldSetupOk -Critical $false -Detail $(if ($worldSetupOk) { 'hub, T, CT y dos sitios configurados' } else { 'pendiente: usar /cs setspawn ... y /cs save (los defaults no cuentan)' })
}

$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(java|javaw|Minecraft)\.exe$' -and $_.CommandLine -and $_.CommandLine -match [regex]::Escape($InstanceRoot) })
Add-PreflightCheck -Name 'Minecraft cerrado para preparar' -Passed ($processes.Count -eq 0) -Detail $(if ($processes.Count -eq 0) { 'sin proceso usando esta instancia' } else { 'hay un proceso usando la instancia' }) -Critical $false

$criticalFailures = @($checks | Where-Object { $_.Critical -and -not $_.Passed })
$mapReady = $worlds.Count -ge 1 -and $worlds.Count -eq $mapSetupWorlds
$gameReady = $criticalFailures.Count -eq 0 -and $mapReady

Write-Host ''
Write-Host 'Preflight VALORANTCraft / CSmain' -ForegroundColor Cyan
$checks | Format-Table -Property @{ Label = 'OK'; Expression = { if ($_.Passed) { 'OK' } else { 'PENDIENTE' } } }, Name, Detail -AutoSize
Write-Host "Mapa configurado: $mapReady"
Write-Host "Listo para prueba de partida: $gameReady"

if ($RequireMapSetup -and -not $gameReady) {
    throw 'El preflight no está listo para una partida: falta configuración del mapa o hay dependencias críticas.'
}

if ($criticalFailures.Count -gt 0) {
    exit 1
}
