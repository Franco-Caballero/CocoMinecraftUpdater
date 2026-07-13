[CmdletBinding()]
param(
    [string]$ManifestPath
)

$projectRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $projectRoot 'manifests\latest.template.json'
}
$engine = Join-Path $projectRoot 'engine\CocoUpdater.ps1'
& $engine -ManifestPath $ManifestPath -DetectOnly
