<#
  Coco Launcher 2 / Tauri 2 updater signing key provisioning (Windows only).
  Idempotent: NEVER rotates a working key. The private signing key is protected
  with user-scoped DPAPI at %LOCALAPPDATA%\CocoLauncher2\signing, never in Git.

  Usage:
    .\Configure-Coco2Updater.ps1                      # initialize/reuse, print PUBLIC key
    .\Configure-Coco2Updater.ps1 -RunBuild            # run existing Build-CocoLauncher2.ps1 signed
    .\Configure-Coco2Updater.ps1 -RunBuild -BuildScript C:\trusted\build.ps1

  Note: the Tauri CLI generates an unpassphrased random key using --ci; this
  script immediately DPAPI-encrypts it and removes plaintext. This intentionally
  avoids passing a signing passphrase in process arguments where other processes
  could see it. The protected secret can only be unwrapped by this Windows user.
#>
[CmdletBinding()]
param(
    [switch]$RunBuild,
    [string]$BuildScript,
    [string]$TauriCliPath,
    [string]$SigningDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
if (-not [Environment]::OSVersion.Platform.Equals([PlatformID]::Win32NT)) {
    throw 'DPAPI CurrentUser requiere Windows.'
}
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA no disponible.'
}
if ([string]::IsNullOrWhiteSpace($BuildScript)) {
    $BuildScript = Join-Path $PSScriptRoot 'Build-CocoLauncher2.ps1'
}
if ([string]::IsNullOrWhiteSpace($TauriCliPath)) {
    $TauriCliPath = Join-Path $PSScriptRoot '..\node_modules\.bin\tauri.cmd'
}
if ([string]::IsNullOrWhiteSpace($SigningDirectory)) {
    $SigningDirectory = Join-Path $env:LOCALAPPDATA 'CocoLauncher2\signing'
}

function Assert-NoReparsePoints([string]$Path) {
    # Include every existing ancestor even when the destination itself does
    # not exist yet; otherwise a missing child under a junction can bypass it.
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Ruta de firma enlazada o redirigida no permitida: $current"
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Set-OwnerOnlyAcl([string]$Folder) {
    $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    # icacls updates the DACL without requesting SeSecurityPrivilege to write
    # unrelated inherited audit SACL entries (Set-Acl can fail for normal users).
    $ownerIdentifier = '*' + $owner.Value
    & icacls.exe $Folder '/grant:r' ($ownerIdentifier + ':(OI)(CI)F') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo conceder acceso al propietario.' }
    & icacls.exe $Folder '/inheritance:r' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo quitar herencia de ACL.' }
    foreach ($entry in @((Get-Acl -LiteralPath $Folder).Access)) {
        $sid = $entry.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($sid -ne $owner.Value) {
            & icacls.exe $Folder '/remove' ('*' + $sid) 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'No se pudo quitar un permiso ajeno del directorio de firma.' }
        }
    }
    $after = Get-Acl -LiteralPath $Folder
    $ownerSid = $owner.Value
    foreach ($entry in @($after.Access)) {
        $entrySid = $entry.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        if ($entrySid -ne $ownerSid -or $entry.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            throw 'El directorio de claves no pudo restringirse al propietario.'
        }
    }
}

function Protect-PrivateKey([string]$PlaintextPath, [string]$Destination) {
    $plain = [System.IO.File]::ReadAllBytes($PlaintextPath)
    try {
        if ($plain.Length -lt 80 -or $plain.Length -gt 32768) {
            throw 'El generador devolvio un archivo privado de tamano inesperado.'
        }
        $entropy = [Text.Encoding]::UTF8.GetBytes('CocoLauncher2/Tauri2/signing/v1')
        $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
            $plain, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        try {
            $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $stream.Write($cipher, 0, $cipher.Length); $stream.Flush($true) }
            finally { $stream.Dispose() }
        } finally { [Array]::Clear($cipher, 0, $cipher.Length) }
    } finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Unprotect-PrivateKey([string]$ProtectedPath) {
    $protected = [System.IO.File]::ReadAllBytes($ProtectedPath)
    try {
        $entropy = [Text.Encoding]::UTF8.GetBytes('CocoLauncher2/Tauri2/signing/v1')
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { return [Text.Encoding]::UTF8.GetString($plain) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    } finally { [Array]::Clear($protected, 0, $protected.Length) }
}

$signingRoot = [IO.Path]::GetFullPath($SigningDirectory)
$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
if (-not $signingRoot.StartsWith(($localAppData.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Las claves solo pueden almacenarse dentro de LOCALAPPDATA.'
}
$protectedKey = Join-Path $signingRoot 'private-key.dpapi'
$publicKey = Join-Path $signingRoot 'public-key.pub'
$lock = New-Object System.Threading.Mutex($false, 'Local\CocoLauncher2UpdaterSigningV1')
$lockHeld = $false
$workingKey = $null
$workingPublic = $null
try {
    $lockHeld = $lock.WaitOne([TimeSpan]::FromSeconds(30))
    if (-not $lockHeld) { throw 'Hay otra configuracion de firma en curso.' }
    Assert-NoReparsePoints $signingRoot
    if (-not (Test-Path -LiteralPath $signingRoot -PathType Container)) {
        [IO.Directory]::CreateDirectory($signingRoot) | Out-Null
    }
    Set-OwnerOnlyAcl $signingRoot
    Assert-NoReparsePoints $signingRoot

    $havePrivate = Test-Path -LiteralPath $protectedKey -PathType Leaf
    $havePublic = Test-Path -LiteralPath $publicKey -PathType Leaf
    if ($havePrivate -ne $havePublic) {
        throw 'Vault de firma incompleto: no se generan claves nuevas sobre un estado parcial. Recupera la copia segura.'
    }
    if (-not $havePrivate) {
        if ($RunBuild) { throw 'Faltan las claves: ejecuta primero Configure-Coco2Updater.ps1 sin -RunBuild.' }
        $cli = [IO.Path]::GetFullPath($TauriCliPath)
        if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Tauri CLI no esta instalado; ejecuta npm ci primero.' }
        $workingKey = Join-Path $signingRoot ('setup-' + [guid]::NewGuid().ToString('N') + '.key')
        $workingPublic = $workingKey + '.pub'
        # Tauri signer --ci never prompts. Suppress ALL CLI output: it can
        # contain signing material. The temp plaintext is owner-only.
        # Windows PowerShell 5.1 can promote harmless native stderr warnings
        # into terminating NativeCommandError when ErrorActionPreference=Stop.
        $priorErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $cli signer generate --ci --write-keys $workingKey 2>&1 | Out-Null
            $generatorExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $priorErrorPreference }
        if ($generatorExitCode -ne 0 -or -not (Test-Path -LiteralPath $workingKey -PathType Leaf) -or
            -not (Test-Path -LiteralPath $workingPublic -PathType Leaf)) {
            throw 'No se pudieron generar las claves de firma de Tauri.'
        }
        $candidatePub = (Get-Content -LiteralPath $workingPublic -Raw -Encoding UTF8).Trim()
        if ($candidatePub.Length -lt 40 -or $candidatePub.Length -gt 1024) {
            throw 'La clave publica generada tiene un formato inesperado.'
        }
        # Keep the vault path absent until the public key and encrypted key
        # are both ready. Re-running with an incomplete vault fails closed.
        Move-Item -LiteralPath $workingPublic -Destination $publicKey -ErrorAction Stop
        Protect-PrivateKey $workingKey $protectedKey
    }
    Assert-NoReparsePoints $protectedKey
    Assert-NoReparsePoints $publicKey
    $public = (Get-Content -LiteralPath $publicKey -Raw -Encoding UTF8).Trim()
    if ($public.Length -lt 40 -or $public.Length -gt 1024) { throw 'Clave publica almacenada invalida.' }

    if ($RunBuild) {
        # La firma es inmutable y ya está cifrada/protegida. No bloquear otras
        # comprobaciones de claves durante npm test y el largo build de Rust.
        $lock.ReleaseMutex()
        $lockHeld = $false
        $build = [IO.Path]::GetFullPath($BuildScript)
        if (-not (Test-Path -LiteralPath $build -PathType Leaf)) { throw 'El script de build solicitado no existe.' }
        $previousKey = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY','Process')
        $previousPassword = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD','Process')
        try {
            $private = Unprotect-PrivateKey $protectedKey
            if ([string]::IsNullOrWhiteSpace($private)) { throw 'Clave de firma protegida invalida.' }
            [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', $private, 'Process')
            [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $null, 'Process')
            $private = $null
            & $build
            if (-not $?) { throw 'El build firmado termino con error.' }
        } finally {
            [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', $previousKey, 'Process')
            [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', $previousPassword, 'Process')
            $private = $null
        }
        Write-Output 'Build firmado finalizado. No se ha publicado ningun release.'
    } else {
        # The public key is intended to be copied into plugins.updater.pubkey.
        Write-Output 'Clave publica para plugins.updater.pubkey:'
        Write-Output $public
        Write-Output ('Vault DPAPI privado: ' + $protectedKey)
    }
} finally {
    foreach ($temporary in @($workingKey, $workingPublic)) {
        if (-not [string]::IsNullOrEmpty($temporary) -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lockHeld) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
