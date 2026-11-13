#requires -Version 5.1
<#
.SYNOPSIS
  Review or locally promote an immutable standalone draft into the SOURCE catalog.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\launcher2\desktop\scripts\Apply-CocoStandaloneDraft.ps1 -DraftId my-game
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\launcher2\desktop\scripts\Apply-CocoStandaloneDraft.ps1 -DraftId my-game -Apply -ApproveReviewedLicenseRights
.NOTES
  Default is read-only dry-run. -Apply is opt-in; local promotion is NOT publishing.
  -RepoRoot allows isolated offline testing/another explicit source checkout.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DraftId,
    [string]$RepoRoot = '',
    [switch]$Apply,
    [switch]$ApproveReviewedLicenseRights,
    [string]$ExpectedCatalogSha256 = '',
    [string]$SourceZipPath = '',
    [string]$SourceZipDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$sha256Pattern = '^[a-fA-F0-9]{64}$'
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Assert-Fields($Object,[string[]]$Expected,[string]$Description) {
    Assert ($Object -is [pscustomobject]) "$Description debe ser objeto"
    $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    Assert ($names.Count -eq $Expected.Count) ("${Description}: propiedades inesperadas o faltantes: esperadas {0}, reales {1} ({2})" -f $Expected.Count,$names.Count,($names -join ','))
    foreach ($field in $Expected) {
        Assert (@($names | Where-Object { $_ -ceq $field }).Count -eq 1) "${Description}: falta la propiedad $field"
    }
}
function Valid-Id([string]$Id) { return $Id -cmatch '^[a-z][a-z0-9-]{0,46}[a-z0-9]$' -and $Id.Length -le 48 }
function Valid-Sha([string]$Sha) { return $null -ne $Sha -and $Sha -cmatch '^[a-f0-9]{64}$' }
function Safe-Relative([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 1024 -or
        $Name.StartsWith('/') -or $Name.Contains('\') -or $Name.Contains(':') -or $Name.EndsWith('/')) { return $false }
    foreach ($part in $Name.Split('/')) {
        if (!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -match '[\x00-\x1f<>"|?*:]') { return $false }
        $stem = ($part.Split('.')[0]).ToUpperInvariant()
        if ($stem -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return $false }
        if ($part.ToLowerInvariant() -in @('saves','playerdata','advancements','stats','distanthorizons','distant_horizons','dh')) { return $false }
    }
    return $Name.Split('/')[0] -ine '.coco'
}
function Assert-NoLink([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $info = Get-Item -LiteralPath $current -Force
            Assert (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Junction/symlink rechazado: $current"
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (!$parent -or $parent -eq $current) { break }
        $current = $parent
    }
}
function Read-Bytes([string]$Path, [long]$Limit) {
    Assert-NoLink $Path
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    Assert (!$info.PSIsContainer -and $info.Length -gt 0 -and $info.Length -le $Limit) "Tamaño inválido: $Path"
    return [IO.File]::ReadAllBytes($Path)
}
function Parse-Json([byte[]]$Bytes, [string]$Description) {
    $decoder = New-Object Text.UTF8Encoding($false,$true)
    try {
        $text = $decoder.GetString($Bytes)
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        Assert ($null -ne $data -and $data -is [pscustomobject]) "$Description debe ser un objeto JSON"
        return $data
    } catch { throw "${Description}: JSON/UTF-8 inválido ($($_.Exception.Message))" }
}
function Sha-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Sha-File([string]$Path) {
    Assert-NoLink $Path
    $stream = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Save-Exclusive([string]$Path, [byte[]]$Bytes) {
    $stream = New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}
function Check-TargetMissing([string]$Path) {
    Assert-NoLink $Path
    Assert (!(Test-Path -LiteralPath $Path)) "Ya existe un archivo/objeto, no se sobrescribirá: $Path"
}
function Verify-Cover([byte[]]$Bytes,[string]$Ext) {
    Assert ($Bytes.Length -ge 12 -and $Bytes.Length -le 20MB) 'Portada fuera del límite 12 B–20 MB'
    $signature = [BitConverter]::ToString($Bytes,0,12)
    if ($Ext -eq 'png') { Assert ($signature.StartsWith('89-50-4E-47-0D-0A-1A-0A')) 'Portada PNG inválida' }
    elseif ($Ext -eq 'jpg') { Assert ($signature.StartsWith('FF-D8-FF')) 'Portada JPG inválida' }
    elseif ($Ext -eq 'webp') {
        Assert ([Text.Encoding]::ASCII.GetString($Bytes,0,4) -eq 'RIFF' -and
            [Text.Encoding]::ASCII.GetString($Bytes,8,4) -eq 'WEBP') 'Portada WEBP inválida'
    } else { throw 'Extensión de portada no admitida' }
}
function Find-CatalogArray([string]$Source) {
    # Find the TOP-LEVEL experiences property without rewriting unrelated JSON.
    $depth = 0; $inString = $false; $escaped = $false; $name = ''; $keyDepth = 0
    for ($i = 0; $i -lt $Source.Length; $i++) {
        $c = $Source[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($c -eq '\') { $escaped = $true; continue }
            if ($c -eq '"') {
                $inString = $false
                if ($depth -eq 1 -and $name -eq 'experiences') {
                    $j = $i + 1
                    while ($j -lt $Source.Length -and [char]::IsWhiteSpace($Source[$j])) { $j++ }
                    if ($j -lt $Source.Length -and $Source[$j] -eq ':') {
                        $j++
                        while ($j -lt $Source.Length -and [char]::IsWhiteSpace($Source[$j])) { $j++ }
                        Assert ($j -lt $Source.Length -and $Source[$j] -eq '[') 'experiences debe ser un arreglo'
                        $arrayDepth = 1; $quoted = $false; $slash = $false
                        for ($k = $j+1; $k -lt $Source.Length; $k++) {
                            $v = $Source[$k]
                            if ($quoted) {
                                if ($slash) { $slash = $false }
                                elseif ($v -eq '\') { $slash = $true }
                                elseif ($v -eq '"') { $quoted = $false }
                                continue
                            }
                            if ($v -eq '"') { $quoted = $true }
                            elseif ($v -eq '[') { $arrayDepth++ }
                            elseif ($v -eq ']') {
                                $arrayDepth--
                                if ($arrayDepth -eq 0) { return @{ Start = $j; End = $k } }
                            }
                        }
                        throw 'Arreglo experiences incompleto'
                    }
                }
                continue
            }
            $name += $c
            continue
        }
        if ($c -eq '"') { $inString = $true; $name = ''; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth-- }
    }
    throw 'No se encontró experiences de nivel superior'
}
function Merge-Catalog([string]$Source,[string]$Candidate, [int]$ExistingCount) {
    $bounds = Find-CatalogArray $Source
    $before = $Source.Substring(0,$bounds.End)
    $tail = $Source.Substring($bounds.End)
    $last = $before.Length - 1
    while ($last -gt $bounds.Start -and [char]::IsWhiteSpace($before[$last])) { $last-- }
    $lineEnding = if ($Source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $indent = '        '
    $snippet = ($Candidate.Trim() -split '`r?`n' | ForEach-Object { $indent + $_ }) -join $lineEnding
    $prefix = $before.Substring(0,$last+1)
    $spaces = $before.Substring($last+1)
    $comma = if ($ExistingCount -gt 0) { ',' } else { '' }
    return $prefix + $comma + $lineEnding + $snippet + $spaces + $tail
}

Assert (Valid-Id $DraftId) 'DraftId inválido (2–48 caracteres ASCII, inicial a-z)'
if ($Apply -and !$ApproveReviewedLicenseRights) {
    throw 'Para aplicar debes revisar origen, licencia y derechos y pasar -ApproveReviewedLicenseRights'
}
if ($ExpectedCatalogSha256) {
    Assert ($ExpectedCatalogSha256 -cmatch $sha256Pattern) 'ExpectedCatalogSha256 inválido'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if ($RepoRoot) { [IO.Path]::GetFullPath($RepoRoot) } else {
    [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\..'))
}
$launcher = Join-Path $root 'launcher'
$drafts = Join-Path $root 'launcher2\drafts'
$draft = Join-Path $drafts $DraftId
$catalogFile = Join-Path $launcher 'catalog.template.json'
$lockFile = Join-Path $launcher "experiences\$DraftId.lock.json"
$assetDir = Join-Path $root 'assets\experiences'
$proposalFile = Join-Path $draft 'catalog-candidate.json'
$sourceLockFile = Join-Path $draft 'source-lock.json'
foreach ($path in @($root,$launcher,$drafts,$draft,$catalogFile,$proposalFile,$sourceLockFile,$assetDir,(Split-Path $lockFile))) {
    Assert-NoLink $path
}
Assert ([IO.Directory]::Exists($draft) -and [IO.Directory]::Exists($assetDir) -and
    [IO.Directory]::Exists((Split-Path $lockFile))) 'Falta el draft o un directorio fuente esperado'
$catalogBytes = Read-Bytes $catalogFile 12MB
$catalogHash = Sha-Bytes $catalogBytes
if ($ExpectedCatalogSha256) {
    Assert ($catalogHash -eq $ExpectedCatalogSha256.ToLowerInvariant()) 'Catálogo cambiado respecto a la revisión anterior'
}
$catalog = Parse-Json $catalogBytes 'Catálogo original'
Assert ($catalog.schemaVersion -eq 1 -and $null -ne $catalog.experiences -and
    $catalog.experiences -is [array]) 'Esquema de catálogo inválido'
$ids = @{}
foreach ($entry in $catalog.experiences) {
    Assert ($entry.id -is [string] -and ![string]::IsNullOrWhiteSpace($entry.id)) 'ID existente inválido'
    $key = $entry.id.ToLowerInvariant()
    Assert (!$ids.ContainsKey($key)) 'IDs duplicados en el catálogo original'
    $ids[$key] = $true
}
Assert (!$ids.ContainsKey($DraftId)) 'El ID del borrador ya existe en el catálogo'

$proposalBytes = Read-Bytes $proposalFile 2MB
$sourceLockBytes = Read-Bytes $sourceLockFile 2MB
$candidate = Parse-Json $proposalBytes 'catalog-candidate.json'
$sourceLock = Parse-Json $sourceLockBytes 'source-lock.json'
Assert-Fields $candidate @('id','name','ui','description','instanceId','managementMode','runtime','pack','hosting','launch','files') 'Candidato'
Assert-Fields $candidate.ui @('imagePath') 'ui'
Assert-Fields $candidate.runtime @('type','executable','requiredFiles') 'runtime'
Assert-Fields $candidate.pack @('packId','lockPath','version','sha256','size','archives') 'pack'
Assert-Fields $candidate.hosting @('mode') 'hosting'
Assert-Fields $candidate.launch @('workflow','arguments','autoJoin','serverName') 'launch'
if (@($candidate.pack.archives).Count -gt 1) {
    Assert-Fields $sourceLock @('schemaVersion','experienceId','type','files','archive','archives') 'source-lock'
} else {
    Assert-Fields $sourceLock @('schemaVersion','experienceId','type','files','archive') 'source-lock'
}
Assert-Fields $sourceLock.archive @('url','sha256','size') 'source-lock.archive'
Assert ($candidate.id -ceq $DraftId -and $candidate.instanceId -ceq $DraftId -and
    $candidate.name -is [string] -and $candidate.name.Trim().Length -gt 0 -and
    $candidate.name.Length -le 120 -and $candidate.name -notmatch '[\x00-\x1f]') 'Metadata de identidad inválida'
Assert ($candidate.managementMode -eq 'managed' -and $candidate.runtime.type -eq 'standalone' -and
    $candidate.hosting.mode -eq 'p2p' -and $candidate.launch.workflow -eq 'coco-standalone' -and
    $candidate.launch.autoJoin -eq $false -and $candidate.launch.arguments -is [array] -and
    @($candidate.launch.arguments).Count -eq 0 -and $candidate.files -is [array] -and
    $candidate.runtime.requiredFiles -is [array] -and $candidate.pack.archives -is [array]) 'Modo standalone/P2P o arrays inesperados'
Assert ($candidate.runtime.executable -is [string] -and (Safe-Relative $candidate.runtime.executable) -and
    $candidate.runtime.executable.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)) 'Ejecutable inválido'
Assert ($candidate.pack.packId -ceq "standalone-$DraftId" -and
    $candidate.pack.lockPath -ceq "launcher/experiences/$DraftId.lock.json" -and
    $candidate.pack.version -is [string] -and $candidate.pack.version.Trim().Length -gt 0 -and
    $candidate.pack.version.Length -le 100 -and $candidate.pack.version -notmatch '[\x00-\x1f]') 'Versión o lockPath inválidos'
Assert (Valid-Sha $candidate.pack.sha256) 'SHA-256 de paquete inválido'
Assert ($candidate.pack.size -is [ValueType] -and [long]$candidate.pack.size -gt 0 -and
    [long]$candidate.pack.size -le 128GB) 'Tamaño de paquete inválido'
$archives = @($candidate.pack.archives)
Assert ($archives.Count -ge 1 -and $archives.Count -le 64) 'El borrador debe declarar entre 1 y 64 archivos ZIP'
$archiveHashes = @{}
$archiveUrls = @{}
[long]$archiveTotal = 0
foreach ($part in $archives) {
    Assert-Fields $part @('archiveUrl','sha256','size') 'pack.archives[]'
    $partUrl = $null
    Assert ([Uri]::TryCreate([string]$part.archiveUrl,[UriKind]::Absolute,[ref]$partUrl) -and
        $partUrl.Scheme -eq 'https' -and $partUrl.Host -and !$partUrl.UserInfo -and
        !$partUrl.Query -and !$partUrl.Fragment -and
        $partUrl.AbsolutePath.EndsWith('.zip',[StringComparison]::OrdinalIgnoreCase)) 'URL HTTPS ZIP inválida'
    Assert ((Valid-Sha $part.sha256) -and $part.size -is [ValueType] -and
        [long]$part.size -gt 0 -and [long]$part.size -lt 2GB) 'Hash/tamaño de parte inválido'
    Assert (!$archiveHashes.ContainsKey($part.sha256) -and !$archiveUrls.ContainsKey($part.archiveUrl)) 'Parte duplicada'
    $archiveHashes[$part.sha256] = $true
    $archiveUrls[$part.archiveUrl] = $true
    $archiveTotal += [long]$part.size
}
$archive = $archives[0]
Assert-Fields $archive @('archiveUrl','sha256','size') 'pack.archives[0]'
$archiveUrl = $null
Assert ([Uri]::TryCreate([string]$archive.archiveUrl,[UriKind]::Absolute,[ref]$archiveUrl) -and
    $archiveUrl.Scheme -eq 'https' -and $archiveUrl.Host -and
    !$archiveUrl.UserInfo -and !$archiveUrl.Query -and !$archiveUrl.Fragment -and
    $archiveUrl.AbsolutePath.EndsWith('.zip',[StringComparison]::OrdinalIgnoreCase)) 'URL HTTPS ZIP inválida'
Assert ($archive.sha256 -ceq $candidate.pack.sha256 -and
    $archiveTotal -eq [long]$candidate.pack.size) 'Hash/tamaño ZIP incoherente en pack.archives'
Assert ($sourceLock.schemaVersion -eq 1 -and $sourceLock.experienceId -ceq $DraftId -and
    $sourceLock.type -eq 'standalone' -and $sourceLock.files -is [array] -and
    @($sourceLock.files).Count -eq 0 -and
    $sourceLock.archive.url -ceq $archive.archiveUrl -and
    $sourceLock.archive.sha256 -ceq $archive.sha256 -and
    [long]$sourceLock.archive.size -eq [long]$archive.size) 'El source-lock no coincide con el paquete'
if ($archives.Count -gt 1) {
    Assert ($sourceLock.archives -is [array] -and $sourceLock.archives.Count -eq $archives.Count) 'Faltan partes en source-lock'
    for ($index=0; $index -lt $archives.Count; $index++) {
        $lockedPart = $sourceLock.archives[$index]
        Assert-Fields $lockedPart @('url','sha256','size') 'source-lock.archives[]'
        Assert ($lockedPart.url -ceq $archives[$index].archiveUrl -and
            $lockedPart.sha256 -ceq $archives[$index].sha256 -and
            [long]$lockedPart.size -eq [long]$archives[$index].size) 'Parte source-lock no coincide'
    }
}
$required = @($candidate.runtime.requiredFiles)
Assert ($required.Count -ge 1 -and $required.Count -le 128) 'requiredFiles vacío o excesivo'
$requiredNames = @{}
foreach ($file in $required) {
    Assert-Fields $file @('path','sha256','size','archiveSha256') 'requiredFile'
    Assert ($file.path -is [string] -and (Safe-Relative $file.path) -and
        (Valid-Sha $file.sha256) -and $archiveHashes.ContainsKey([string]$file.archiveSha256) -and
        [long]$file.size -gt 0 -and [long]$file.size -le 64GB) 'Archivo requerido o hash inválido'
    $key = $file.path.ToLowerInvariant()
    Assert (!$requiredNames.ContainsKey($key)) 'requiredFiles duplicado'
    $requiredNames[$key] = $true
}
Assert ($requiredNames.ContainsKey($candidate.runtime.executable.ToLowerInvariant())) 'El ejecutable no está en requiredFiles'
Assert (@($candidate.files).Count -eq 0) 'No se admite publicar archivos adicionales sin revisión independiente'

$coverPaths = @('png','jpg','webp' | ForEach-Object { Join-Path $draft "cover.$_" })
$present = @($coverPaths | Where-Object { [IO.File]::Exists($_) })
Assert ($present.Count -eq 1) 'El borrador debe contener exactamente una portada cover.png/jpg/webp'
$coverFile = $present[0]
$ext = [IO.Path]::GetExtension($coverFile).Substring(1).ToLowerInvariant()
Assert ($candidate.ui.imagePath -ceq "assets/experiences/$DraftId.$ext") 'imagePath del catálogo no coincide con el borrador'
$coverBytes = Read-Bytes $coverFile 20MB
Verify-Cover $coverBytes $ext
$assetFile = Join-Path $assetDir "$DraftId.$ext"
Check-TargetMissing $lockFile
Check-TargetMissing $assetFile
Assert (!($SourceZipPath -and $SourceZipDirectory)) 'Usa SourceZipPath o SourceZipDirectory, no ambos'
if ($SourceZipDirectory) {
    Assert ([IO.Path]::IsPathRooted($SourceZipDirectory) -and !$SourceZipDirectory.StartsWith('\\')) 'Directorio ZIP debe ser local absoluto'
    Assert-NoLink $SourceZipDirectory
    Assert ([IO.Directory]::Exists($SourceZipDirectory)) 'Falta directorio ZIP'
    $zipNames = @{}
    foreach ($part in $archives) {
        $filename = [Uri]::UnescapeDataString(([Uri]$part.archiveUrl).Segments[-1])
        Assert ((Safe-Relative $filename) -and !$filename.Contains('/') -and !$zipNames.ContainsKey($filename)) 'Nombre de parte ambiguo'
        $zipNames[$filename] = $true
        $localPart = Join-Path $SourceZipDirectory $filename
        Assert-NoLink $localPart
        Assert ([IO.File]::Exists($localPart) -and (Get-Item -LiteralPath $localPart).Length -eq [long]$part.size) 'Parte local falta o tamaño diferente'
        Assert ((Sha-File $localPart) -ceq $part.sha256) 'Parte local NO coincide con SHA-256'
    }
} elseif ($SourceZipPath) {
    Assert ($archives.Count -eq 1) 'Para varias partes usa SourceZipDirectory'
    Assert (![string]::IsNullOrWhiteSpace($SourceZipPath) -and
        [IO.Path]::IsPathRooted($SourceZipPath) -and !$SourceZipPath.StartsWith('\\')) 'SourceZipPath requiere ZIP local absoluto'
    $localZip = [IO.Path]::GetFullPath($SourceZipPath)
    Assert ([IO.Path]::GetExtension($localZip).Equals('.zip',[StringComparison]::OrdinalIgnoreCase)) 'SourceZipPath debe ser ZIP'
    Assert ([IO.File]::Exists($localZip) -and
        (Get-Item -LiteralPath $localZip).Length -eq [long]$archive.size) 'ZIP local no coincide en tamaño'
    Assert ((Sha-File $localZip) -eq $archive.sha256) 'ZIP local NO coincide con el SHA-256 declarado'
} else {
    Write-Warning 'No se indicó -SourceZipPath: se validó coherencia entre hashes del borrador, NO los bytes del ZIP original.'
}

$decoder = New-Object Text.UTF8Encoding($false,$true)
$originalText = $decoder.GetString($catalogBytes)
$candidateText = $decoder.GetString($proposalBytes)
$mergedText = Merge-Catalog $originalText $candidateText $catalog.experiences.Count
$mergedBytes = $utf8.GetBytes($mergedText)
$verified = Parse-Json $mergedBytes 'Catálogo fusionado'
Assert ($verified.experiences.Count -eq ($catalog.experiences.Count+1) -and
    $verified.experiences[-1].id -ceq $DraftId) 'La fusión no preservó el catálogo'
Assert ($mergedBytes.Length -le 12MB) 'El catálogo fusionado excede el límite'

Write-Output "Borrador: $DraftId"
Write-Output "Catálogo original SHA256: $catalogHash"
Write-Output "ZIPs declarados: $($archives.Count), $archiveTotal bytes; primero SHA256: $($archive.sha256)"
Write-Output "Archivos requeridos: $($required.Count)"
Write-Output "Destinos: $catalogFile ; $lockFile ; $assetFile"
if (!$Apply) {
    Write-Output 'DRY-RUN: JSON, ID, hashes declarados, rutas y portada validados; no se modificó nada.'
    Write-Output "Para aplicar después de revisar derechos/licencia:"
    Write-Output ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -DraftId "{1}" -Apply -ApproveReviewedLicenseRights -ExpectedCatalogSha256 {2}' -f $MyInvocation.MyCommand.Path,$DraftId,$catalogHash)
    return
}

# Named OS mutex coordinates parallel uses of THIS tool. It disappears even if
# this process crashes; it does not lock unrelated editors or Git operations.
$mutexName = 'Local\CocoStandalonePromotion-' + (Sha-Bytes ($utf8.GetBytes($root.ToLowerInvariant()))).Substring(0,24)
$mutex = $null
$mutexOwned = $false
$created = New-Object 'Collections.Generic.List[object]'
$tempCatalog = $null; $tempLock = $null; $tempCover = $null; $backup = $null
$catalogCommitted = $false
try {
    $mutex = New-Object Threading.Mutex($false,$mutexName)
    try { $mutexOwned = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $mutexOwned = $true }
    Assert $mutexOwned 'Hay otra promoción Coco ejecutándose en este repositorio'
    $stamp = [Guid]::NewGuid().ToString('N')
    $tempCatalog = Join-Path $launcher (".$DraftId-$stamp.catalog.tmp")
    $tempLock = Join-Path (Split-Path $lockFile) (".$DraftId-$stamp.lock.tmp")
    $tempCover = Join-Path $assetDir (".$DraftId-$stamp.cover.tmp")
    $backup = Join-Path $launcher (".$DraftId-$stamp.backup.tmp")
    Save-Exclusive $tempCatalog $mergedBytes
    Save-Exclusive $tempLock $sourceLockBytes
    Save-Exclusive $tempCover $coverBytes

    # Recheck AFTER staging, BEFORE any destination is made visible.
    Assert ((Sha-File $catalogFile) -eq $catalogHash) 'El catálogo cambió desde la lectura inicial; se canceló sin aplicar'
    Check-TargetMissing $lockFile
    Check-TargetMissing $assetFile
    [IO.File]::Move($tempLock,$lockFile)
    $created.Add(@{Path=$lockFile;Sha=Sha-Bytes $sourceLockBytes})
    [IO.File]::Move($tempCover,$assetFile)
    $created.Add(@{Path=$assetFile;Sha=Sha-Bytes $coverBytes})
    Assert ((Sha-File $catalogFile) -eq $catalogHash) 'El catálogo fue modificado concurrentemente; se retirarán los archivos creados'
    # Atomically swap the source catalog, keeping a private backup. No other
    # source file is replaced. File.Replace is an NTFS atomic file operation.
    [IO.File]::Replace($tempCatalog,$catalogFile,$backup,$false)
    $catalogCommitted = $true
    Assert ((Sha-File $catalogFile) -eq (Sha-Bytes $mergedBytes)) 'El catálogo no coincide con el contenido preparado'
    $created.Clear() # Successful commit: these are real source files now.
    if ([IO.File]::Exists($backup)) {
        try { [IO.File]::Delete($backup) }
        catch { Write-Warning "La copia de seguridad privada no pudo eliminarse: $backup" }
    }
    Write-Output 'APLICADO: source catalog + lock + portada; SIN subir, publicar, ejecutar ni instalar el juego.'
} catch {
    # Only the files created by THIS invocation, still byte-identical, can be
    # rolled back. Never roll back someone else's concurrent edits.
    if ($catalogCommitted -and $backup -and [IO.File]::Exists($backup)) {
        try {
            if ((Sha-File $catalogFile) -eq (Sha-Bytes $mergedBytes)) {
                $restoreStage = Join-Path $launcher (".$DraftId-" + [Guid]::NewGuid().ToString('N') + '.restore.tmp')
                [IO.File]::Copy($backup,$restoreStage)
                [IO.File]::Replace($restoreStage,$catalogFile,$null,$false)
            }
        } catch { Write-Warning 'No se pudo restaurar automáticamente el catálogo; inspeccionar el backup temporal.' }
    }
    if ($catalogCommitted -and (Sha-File $catalogFile) -ne $catalogHash) {
        # The catalog is still promoted (or concurrently modified). Never
        # remove files it could now reference; manual intervention required.
        throw 'El catálogo permanece modificado; no se retiraron los archivos de apoyo. Revisar el backup y las diferencias antes de intervenir.'
    }
    foreach ($item in $created) {
        try {
            if ([IO.File]::Exists($item.Path) -and (Sha-File $item.Path) -eq $item.Sha) {
                [IO.File]::Delete($item.Path)
            }
        } catch { Write-Warning "No se pudo revertir el archivo generado: $($item.Path)" }
    }
    throw
} finally {
    foreach ($path in @($tempCatalog,$tempLock,$tempCover)) {
        if ($path -and [IO.File]::Exists($path)) {
            try { [IO.File]::Delete($path) } catch {}
        }
    }
    if ($mutex) {
        if ($mutexOwned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}
