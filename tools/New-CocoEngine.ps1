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
foreach($helper in 'CocoNetwork.ps1','CocoNetworkElevated.ps1','CocoNetworkAuthorizer.ps1'){
    Copy-Item -LiteralPath (Join-Path $projectRoot "engine\$helper") -Destination (Join-Path $stage $helper) -Force
}
$assets=Join-Path $stage 'assets'
New-Item -ItemType Directory -Path $assets -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'fullbody.png') -Destination (Join-Path $assets 'fullbody.png') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'reynaico.ico') -Destination (Join-Path $assets 'reynaico.ico') -Force
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zip = Join-Path $OutputDirectory "coco-engine-$Version.zip"
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item -LiteralPath $stage -Recurse -Force
[pscustomobject]@{ version = $Version; path = $zip; sha256 = $hash; size = (Get-Item $zip).Length } | ConvertTo-Json
