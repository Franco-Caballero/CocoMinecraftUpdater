[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$OutputZipPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "La carpeta origen '$SourceDirectory' no existe."
}

$parent = Split-Path -Parent $OutputZipPath
if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

if (Test-Path -LiteralPath $OutputZipPath) {
    Remove-Item -LiteralPath $OutputZipPath -Force
}

Write-Host "Compressing '$SourceDirectory' into '$OutputZipPath'..."
Compress-Archive -Path (Join-Path $SourceDirectory '*') -DestinationPath $OutputZipPath -CompressionLevel Optimal

$fileItem = Get-Item -LiteralPath $OutputZipPath
$hash = (Get-FileHash -LiteralPath $OutputZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$result = [pscustomobject]@{
    ZipPath   = $fileItem.FullName
    SizeBytes = $fileItem.Length
    Sha256    = $hash
}

$result | ConvertTo-Json -Depth 4
