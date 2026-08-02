[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'forge-mod\src\main\java\cl\coco\valorant\CocoValorantTools.java'
$clientPath = Join-Path $root 'forge-mod\src\main\java\cl\coco\valorant\CocoValorantClient.java'
$tomlPath = Join-Path $root 'forge-mod\src\main\resources\META-INF\mods.toml'
$lockPath = Join-Path $root 'launcher\experiences\valorant-craft.lock.json'

foreach ($path in $sourcePath, $clientPath, $tomlPath, $lockPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Falta el archivo de Coco VALORANT Tools: $path"
    }
}

$source = Get-Content -LiteralPath $sourcePath -Raw
$client = Get-Content -LiteralPath $clientPath -Raw
$toml = Get-Content -LiteralPath $tomlPath -Raw
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$asset = @($lock.assets | Where-Object path -eq 'mods/coco-valorant-tools-0.1.0.jar') | Select-Object -First 1

foreach ($required in '@Mod(CocoValorantTools.MOD_ID)', 'orb_of_origin', 'BlockEvent.BreakEvent', 'BlockEvent.EntityPlaceEvent', 'GameType.ADVENTURE', 'coco host') {
    if ($source -notmatch [regex]::Escape($required)) {
        throw "Coco VALORANT Tools no contiene la proteccion/automatizacion esperada: $required"
    }
}
if ($client -notmatch 'GLFW_KEY_M' -or $client -notmatch 'sendCommand\("coco menu"\)') {
    throw 'El menu rapido de Coco VALORANT Tools no esta vinculado a M.'
}
if ($toml -notmatch 'modLoader="javafml"' -or $toml -notmatch 'modId="\$\{mod_id\}"' -or $toml -notmatch 'modId="forge"') {
    throw 'El manifiesto Forge de Coco VALORANT Tools no fija sus dependencias.'
}
if (-not $asset -or $asset.role -ne 'all' -or $asset.sourceUrl -notmatch '^https://github\.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0\.5\.78/coco-valorant-tools-0\.1\.0\.jar$' -or
    [string]$asset.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [int64]$asset.size -le 0) {
    throw 'El JAR de Coco VALORANT Tools no esta fijado como asset first-party verificable.'
}

Write-Host 'OK: Coco VALORANT Tools declara Orb, menu M, roles host/jugador y proteccion Adventure/mapa.' -ForegroundColor Green
