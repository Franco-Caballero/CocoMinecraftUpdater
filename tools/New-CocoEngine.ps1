[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Version,
    [Parameter(Mandatory = $true)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$stage = Join-Path $env:TEMP "coco-engine-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'engine\CocoUpdater.ps1') -Destination (Join-Path $stage 'CocoUpdater.ps1') -Force
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zip = Join-Path $OutputDirectory "coco-engine-$Version.zip"
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -LiteralPath (Join-Path $stage 'CocoUpdater.ps1') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item -LiteralPath $stage -Recurse -Force
[pscustomobject]@{ version = $Version; path = $zip; sha256 = $hash; size = (Get-Item $zip).Length } | ConvertTo-Json
