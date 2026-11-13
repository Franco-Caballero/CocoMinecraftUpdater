<#
The ONLY process that receives TAURI_SIGNING_PRIVATE_KEY is the Tauri signer.
No npm lifecycle, cargo build, installer, or user scripts run with that key.
Invoked by Configure-Coco2Updater.ps1 using its DPAPI vault.
#>
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$config=Get-Content -LiteralPath (Join-Path $root 'src-tauri\tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$version=[string]$config.version
if($version -notmatch '^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$'){throw 'Versión inválida para firmar'}
$cli=Join-Path $root 'node_modules\.bin\tauri.cmd'
$nsis=Join-Path $root 'src-tauri\target\release\bundle\nsis'
$matches=@(Get-ChildItem -LiteralPath $nsis -File -Filter '*-setup.exe' | Where-Object {$_.Name -eq "Coco Launcher 2_${version}_x64-setup.exe"})
if($matches.Count -ne 1){throw 'No hay un único instalador para esta versión'}
$exe=$matches[0].FullName
$sig=$exe+'.sig'
if(Test-Path -LiteralPath $sig){throw 'Firma previa: rechazar posible firma obsoleta'}
if(-not $env:TAURI_SIGNING_PRIVATE_KEY){throw 'Clave protegida no disponible para este proceso'}

Push-Location $root
try {
    # PowerShell 5.1 surfaces harmless native CLI stderr (e.g. Tauri's
    # informational empty-password notice) as NativeCommandError under Stop.
    # Suppress CLI output containing signing details; judge the real exit code.
    $priorPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $cli signer sign --app-version $version $exe 2>&1 | Out-Null
        $signExit=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$priorPreference
    }
    if($signExit -ne 0){throw 'Tauri signer no pudo firmar el instalador'}
    if(-not (Test-Path -LiteralPath $sig -PathType Leaf)){throw 'El firmador no generó la firma'}
    $length=(Get-Item -LiteralPath $sig).Length
    if($length -lt 200 -or $length -gt 4096){throw 'Tamaño inesperado de firma Tauri'}
} finally {Pop-Location}
