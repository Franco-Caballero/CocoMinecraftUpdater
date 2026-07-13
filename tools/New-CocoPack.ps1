[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$MinecraftRoot,
    [Parameter(Mandatory = $true)] [string]$Role,
    [Parameter(Mandatory = $true)] [string]$Version,
    [Parameter(Mandatory = $true)] [string]$OutputDirectory,
    [string[]]$ConfigFiles = @(),
    [string[]]$ExcludeModPatterns = @(),
    [string[]]$AdditionalModFiles = @()
)

$ErrorActionPreference = 'Stop'
if ($Role -notin @('client', 'host')) { throw 'Role debe ser client u host.' }
$mods = Join-Path $MinecraftRoot 'mods'
if (-not (Test-Path $mods)) { throw "No existe $mods" }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stage = Join-Path $env:TEMP "coco-pack-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path (Join-Path $stage 'mods') -Force | Out-Null
Get-ChildItem -LiteralPath $mods -File -Filter '*.jar' | Where-Object {
    $name = $_.Name
    -not @($ExcludeModPatterns | Where-Object { $name -match $_ })
} | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage 'mods') -Force
}
foreach ($additional in $AdditionalModFiles) {
    if (-not (Test-Path -LiteralPath $additional)) { throw "No existe el mod adicional: $additional" }
    Copy-Item -LiteralPath $additional -Destination (Join-Path $stage 'mods') -Force
}

if ($ConfigFiles.Count -gt 0) {
    foreach ($relativePath in $ConfigFiles) {
        $source = Join-Path $MinecraftRoot $relativePath
        if (-not (Test-Path $source)) { continue }
        $destination = Join-Path $stage $relativePath
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }
}

$zip = Join-Path $OutputDirectory "coco-$Role-$Version.zip"
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item -LiteralPath $stage -Recurse -Force

[pscustomobject]@{ role = $Role; version = $Version; path = $zip; sha256 = $hash; size = (Get-Item $zip).Length } | ConvertTo-Json
