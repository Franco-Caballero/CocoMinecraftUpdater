#requires -Version 5.1
<#
.SYNOPSIS
  Fetch and verify the pinned official ZeroTier 1.16.2 MSI for a FUTURE Tauri
  bundle. Does NOT run MSI, msiexec, UAC, ZeroTier or any service.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\launcher2\desktop\scripts\Get-Coco2ZeroTierMsi.ps1
.NOTES
  Optional -SourceMsiPath and -TauriRoot are for offline verification/fixtures.
  Never weaken the fixed URL, SHA256, file size or publisher to make a build pass.
#>
[CmdletBinding()]
param(
    [string]$TauriRoot = '',
    [string]$SourceMsiPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedSha256 = '42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'
$expectedBytes = 12003840
$officialUrl = 'https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi'
$expectedSigner = 'ZeroTier, Inc.'
$codeSigningOid = '1.3.6.1.5.5.7.3.3'

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Enlace/junction no admitido en ruta MSI: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (!$parent -or $parent -eq $current) { break }
        $current = $parent
    }
}
function Test-VerifiedMsi([string]$Path) {
    Assert-NoReparse $Path
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -ne $expectedBytes -or
        !$file.Extension.Equals('.msi',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'ZeroTier MSI rechazado: nombre o tamaño diferente del oficial fijado'
    }
    $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($sha -cne $expectedSha256) { throw 'ZeroTier MSI rechazado: SHA-256 no coincide con el pin' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ([string]$signature.Status -cne 'Valid') {
        throw 'ZeroTier MSI rechazado: firma Authenticode inválida o no confiable'
    }
    if ($null -eq $signature.SignerCertificate) {
        throw 'ZeroTier MSI rechazado: no existe certificado del firmante'
    }
    $publisher = $signature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)
    if (!$publisher.Equals($expectedSigner,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'ZeroTier MSI rechazado: editor del certificado distinto de ZeroTier, Inc.'
    }
    $codeSigning = $false
    foreach ($extension in $signature.SignerCertificate.Extensions) {
        if ($extension -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            foreach ($usage in $extension.EnhancedKeyUsages) {
                if ($usage.Value -ceq $codeSigningOid) { $codeSigning = $true }
            }
        }
    }
    if (!$codeSigning) { throw 'ZeroTier MSI rechazado: certificado sin uso de firma de código' }
    return $sha
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Preparación Authenticode: solo Windows con certificados de confianza del sistema'
}
$root = if ($TauriRoot) { [IO.Path]::GetFullPath($TauriRoot) } else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src-tauri'))
}
$resources = Join-Path $root 'resources'
$destination = Join-Path $resources 'ZeroTierOne.msi'
if (![IO.Directory]::Exists($root) -or ![IO.Directory]::Exists($resources)) {
    throw 'Falta src-tauri/resources; no se crean carpetas arbitrarias'
}
Assert-NoReparse $root
Assert-NoReparse $resources
Assert-NoReparse $destination
if ([IO.File]::Exists($destination)) {
    # Never replace a modified or unexpected MSI; require manual intervention.
    $verified = Test-VerifiedMsi $destination
    Write-Output "ZeroTier 1.16.2: artefacto existente verificado (SHA256 $verified)"
    return
}

$temporary = Join-Path $resources ('.ZeroTierOne-' + [Guid]::NewGuid().ToString('N') + '.msi')
try {
    if ($SourceMsiPath) {
        if (![IO.Path]::IsPathRooted($SourceMsiPath)) { throw 'SourceMsiPath debe ser absoluto' }
        $source = [IO.Path]::GetFullPath($SourceMsiPath)
        Assert-NoReparse $source
        if (![IO.File]::Exists($source) -or ![IO.Path]::GetExtension($source).Equals('.msi',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'SourceMsiPath no es un MSI local válido'
        }
        [IO.File]::Copy($source,$temporary,$false)
    } else {
        # Exact version-pinned HTTPS URL. SHA and Authenticode are BOTH verified.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $officialUrl -UseBasicParsing -MaximumRedirection 3 -TimeoutSec 120 -OutFile $temporary -ErrorAction Stop | Out-Null
    }
    $verified = Test-VerifiedMsi $temporary
    [IO.File]::Move($temporary,$destination) # refuses an existing destination
    try {
        [void](Test-VerifiedMsi $destination)
    } catch {
        try {
            if ([IO.File]::Exists($destination) -and
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $verified) {
                [IO.File]::Delete($destination)
            }
        } catch {}
        throw
    }
    Write-Output "ZeroTier 1.16.2 verificado para empaquetar: $destination"
    Write-Output "SHA256: $verified; editor Authenticode: $expectedSigner; NO se instaló en este equipo."
} finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
