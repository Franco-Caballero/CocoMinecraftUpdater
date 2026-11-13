<#
  Deterministic, offline Tauri v2 updater manifest for the EXACT signed NSIS EXE.
  No GitHub requests, uploads, builds, installer execution, or key access.

  Example:
    .\New-Coco2UpdateFeed.ps1 `
      -InstallerPath '..\src-tauri\target\release\bundle\nsis\Coco Launcher 2_0.2.0_x64-setup.exe' `
      -Version '0.2.0' `
      -DownloadUrl 'https://github.com/OWNER/REPO/releases/download/v0.2.0/Coco%20Launcher%202_0.2.0_x64-setup.exe'

  Requires bundle.createUpdaterArtifacts = true (v2) and a sibling .exe.sig
  produced by Tauri itself. The signature text goes INLINE in latest.json.
  The EXE can be shared by itself; no additional zip is needed with v2 mode.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$DownloadUrl,
    [string]$SignaturePath,
    [string]$OutputPath,
    [string]$TauriConfigPath,
    [string]$ExpectedSha256,
    [string]$Notes = '',
    [switch]$ReplaceExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($TauriConfigPath)) {
    $TauriConfigPath = Join-Path $PSScriptRoot '..\src-tauri\tauri.conf.json'
}

function Parse-Semver([string]$InputVersion) {
    # Require full version; no guessing, shorthand, or silent coercion.
    $pattern = '^(?:v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    if ($InputVersion -cnotmatch $pattern) { throw "Version SemVer invalida: $InputVersion" }
    return ($InputVersion -replace '^v', '')
}

function Compare-Semver([string]$Left, [string]$Right) {
    $leftVersion = Parse-Semver $Left
    $rightVersion = Parse-Semver $Right
    $leftCore = ($leftVersion -split '[-+]')[0].Split('.')
    $rightCore = ($rightVersion -split '[-+]')[0].Split('.')
    for ($index = 0; $index -lt 3; $index++) {
        $a = [bigint]::Parse($leftCore[$index]); $b = [bigint]::Parse($rightCore[$index])
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }
    # Conservative: do not automatically compare prerelease precedence.
    if ($leftVersion -ne $rightVersion) { return 0 }
    return 0
}

$semver = Parse-Semver $Version
$installer = [IO.Path]::GetFullPath($InstallerPath)
$installerName = [IO.Path]::GetFileName($installer)
if ($installerName -cnotmatch '(?i)-setup\.exe$') {
    throw 'La entrada debe ser el instalador NSIS exacto *-setup.exe, no un ZIP, MSI ni copia renombrada.'
}
if ($installerName -cnotmatch ('(?i)^.+_' + [regex]::Escape($semver) + '_x64-setup\.exe$')) {
    throw 'El instalador debe conservar el nombre Tauri NSIS <producto>_<version>_x64-setup.exe.'
}
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'Instalador NSIS no encontrado.' }
if ([IO.File]::GetAttributes($installer).HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Instalador enlazado no permitido.'
}
$installerInfo = Get-Item -LiteralPath $installer -Force
if ($installerInfo.Length -lt 64) { throw 'Instalador EXE truncado.' }
$magic = New-Object byte[] 2
$stream = [IO.File]::Open($installer, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { if ($stream.Read($magic, 0, 2) -ne 2 -or $magic[0] -ne 77 -or $magic[1] -ne 90) { throw 'El instalador no tiene encabezado ejecutable PE MZ.' } }
finally { $stream.Dispose() }

$canonicalSig = $installer + '.sig'
if (-not [string]::IsNullOrWhiteSpace($SignaturePath)) {
    if (-not [string]::Equals([IO.Path]::GetFullPath($SignaturePath), $canonicalSig,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'La firma debe corresponder a la ruta EXACTA <instalador>.sig.'
    }
}
if (-not (Test-Path -LiteralPath $canonicalSig -PathType Leaf)) {
    throw 'Falta la firma nativa de Tauri: <instalador>.exe.sig (activa bundle.createUpdaterArtifacts=true).'
}
if ([IO.File]::GetAttributes($canonicalSig).HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw 'Firma enlazada no permitida.'
}
$signatureInfo = Get-Item -LiteralPath $canonicalSig
if ($signatureInfo.Length -lt 64 -or $signatureInfo.Length -gt 16384) {
    throw 'Tamaño de firma Tauri no valido.'
}
$signature = (Get-Content -LiteralPath $canonicalSig -Encoding ASCII -Raw).Trim()
if ($signature -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
    throw 'La firma debe contener el Base64 generado por Tauri, no un nombre de archivo o URL.'
}
try {
    $signatureBytes = [Convert]::FromBase64String($signature)
    if ($signatureBytes.Length -lt 64) { throw 'Firma Tauri demasiado corta.' }
} catch { throw 'Firma Tauri Base64 invalida.' }

$configFile = [IO.Path]::GetFullPath($TauriConfigPath)
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { throw 'No se encontro tauri.conf.json para cotejar la version.' }
$config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not [string]::Equals([string]$config.version, $semver, [StringComparison]::Ordinal)) {
    throw "La version $semver no coincide con la version $($config.version) de tauri.conf.json."
}

# Tauri v2 updater can directly install a signed NSIS EXE; reject v1 zip feeds.
if ($null -eq $config.bundle -or $null -eq $config.bundle.createUpdaterArtifacts -or
    $config.bundle.createUpdaterArtifacts -cne $true) {
    throw 'Activa bundle.createUpdaterArtifacts=true en Tauri 2; sin ello los updates NSIS no son validos.'
}

$uri = $null
if (-not [Uri]::TryCreate($DownloadUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or
    -not [string]::IsNullOrEmpty($uri.UserInfo) -or
    -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment) -or $uri.Port -ne 443) {
    throw 'URL invalida: requiere HTTPS directo a github.com/releases/download, sin credenciales/query/fragment.'
}
$segments = $uri.AbsolutePath.Trim('/').Split('/')
if ($segments.Length -ne 6 -or $segments[2] -cne 'releases' -or $segments[3] -cne 'download' -or
    [string]::IsNullOrWhiteSpace($segments[0]) -or [string]::IsNullOrWhiteSpace($segments[1])) {
    throw 'La URL debe ser github.com/OWNER/REPO/releases/download/TAG/INSTALADOR.exe.'
}
if ([Uri]::UnescapeDataString($segments[5]) -cne $installerName) {
    throw 'La URL no apunta al nombre EXACTO del instalador firmado.'
}
# Coco 2 keeps every Setup in its one fixed release; the versioned asset name
# (checked above against the binary) carries the version instead of the tag.
$fixedChannel = [Uri]::UnescapeDataString($segments[4]) -ceq 'coco2-channel'
if (-not $fixedChannel -and [Uri]::UnescapeDataString($segments[4]) -cnotmatch '^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw 'El tag de GitHub no identifica una version SemVer.'
}
if (-not $fixedChannel -and (Parse-Semver ([Uri]::UnescapeDataString($segments[4]))) -cne $semver) {
    throw 'El tag de GitHub no coincide con la version del binario.'
}

$sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and
    $sha256 -cne $ExpectedSha256.ToLowerInvariant()) {
    throw 'SHA-256 del instalador no coincide con el esperado.'
}
if ($Notes.Length -gt 2000) { throw 'Notas de version demasiado largas.' }

$feed = [ordered]@{
    version = $semver
    platforms = [ordered]@{
        'windows-x86_64' = [ordered]@{
            signature = $signature
            url = $uri.AbsoluteUri
        }
    }
}
if (-not [string]::IsNullOrEmpty($Notes)) { $feed['notes'] = $Notes }
$payload = ($feed | ConvertTo-Json -Depth 8) + "`n"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Path $installer -Parent) 'latest.json'
}
$out = [IO.Path]::GetFullPath($OutputPath)
if ([string]::Equals($out, $installer, [StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals($out, $canonicalSig, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'No se puede escribir el feed sobre el instalador ni su firma.'
}
if ([IO.Path]::GetFileName($out) -cne 'latest.json') {
    throw 'El archivo de salida de GitHub debe llamarse latest.json.'
}
$destinationFolder = Split-Path -Path $out -Parent
if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) { throw 'El directorio de salida no existe.' }
if (Test-Path -LiteralPath $out) {
    if (-not $ReplaceExisting) { throw 'latest.json ya existe; usa -ReplaceExisting para actualizarlo.' }
    $prior = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrEmpty([string]$prior.version)) { throw 'Feed anterior sin version valida.' }
    $previousVersion = Parse-Semver ([string]$prior.version)
    if ($previousVersion -eq $semver) { throw 'No se sobrescribe un feed de la misma version.' }
    if ((Compare-Semver $semver $previousVersion) -le 0) { throw 'El nuevo feed debe avanzar la version anterior.' }
}

$tempOutput = Join-Path $destinationFolder ('.latest-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($tempOutput, $payload, (New-Object Text.UTF8Encoding($false)))
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha256) {
        throw 'El instalador cambio mientras se preparaba el feed.'
    }
    if ((Get-Content -LiteralPath $canonicalSig -Encoding ASCII -Raw).Trim() -cne $signature) {
        throw 'La firma cambio mientras se preparaba el feed.'
    }
    if (Test-Path -LiteralPath $out) {
        # Retain previous feed if replacement fails unexpectedly.
        [IO.File]::Replace($tempOutput, $out, $null)
    } else {
        [IO.File]::Move($tempOutput, $out)
    }
} finally {
    if (Test-Path -LiteralPath $tempOutput) { Remove-Item -LiteralPath $tempOutput -Force }
}
Write-Output ('Feed Tauri creado: ' + $out)
Write-Output ('Instalador SHA-256 (confirmacion, NO firma): ' + $sha256)
Write-Output 'Sin publicar: sube el EXE y latest.json al release GitHub con URL exacta.'
