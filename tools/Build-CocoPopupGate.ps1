[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$csPath = Join-Path $root 'engine\CocoPopupGate.cs'
if (-not (Test-Path -LiteralPath $csPath -PathType Leaf)) {
    throw "No existe el codigo fuente: $csPath"
}
$dllPath = Join-Path $root 'engine\CocoPopupGate.dll'
$source = [System.IO.File]::ReadAllText($csPath, [System.Text.Encoding]::UTF8)

# Compile using Add-Type
Add-Type -TypeDefinition $source -OutputAssembly $dllPath -ErrorAction Stop
if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
    throw "Fallo al generar la libreria compilada: $dllPath"
}
$len = (Get-Item -LiteralPath $dllPath).Length
Write-Output "CocoPopupGate.dll compilado correctamente ($len bytes): $dllPath"
