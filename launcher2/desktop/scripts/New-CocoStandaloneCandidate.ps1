#requires -Version 5.1
<#
.SYNOPSIS
  Importa un ZIP local en un borrador standalone sin publicar ni instalar el juego.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\launcher2\desktop\scripts\New-CocoStandaloneCandidate.ps1 -ZipPath 'D:\Juego.zip' -Id 'mi-juego' -Name 'Mi juego' -Version '1.0' -ArchiveUrl 'https://github.com/organizacion/repositorio/releases/download/v1/Juego.zip' -CoverPath 'D:\cover.png' -Executable 'MiJuego.exe'
.NOTES
  Solo escribe launcher2/drafts/<id>; nunca modifica el catalogo, saves ni instancias.
  ArchiveUrl es una declaracion para publicacion FUTURA; no se descarga ni verifica online.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('SourceZip')][string]$ZipPath,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ArchiveUrl,
    [Parameter(Mandatory)][string]$CoverPath,
    [Parameter(Mandatory)][string]$Executable,
    [string[]]$RequiredPaths = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Assert-SafePath([string]$Path, [bool]$Directory = $false) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1024 -or
        $Path.StartsWith('/') -or $Path.Contains('\') -or $Path.Contains(':') -or
        $Path.Contains([string][char]0)) {
        throw "Ruta insegura en ZIP: $Path"
    }
    if ($Directory) {
        if (!$Path.EndsWith('/') -or $Path.EndsWith('//')) { throw "Directorio ZIP invalido: $Path" }
        $Path = $Path.Substring(0, $Path.Length - 1)
    } elseif ($Path.EndsWith('/')) { throw "Archivo ZIP invalido: $Path" }

    $parts = $Path.Split('/')
    foreach ($part in $parts) {
        if (!$part -or $part -eq '.' -or $part -eq '..' -or
            $part.EndsWith('.') -or $part.EndsWith(' ') -or
            $part -match '[\x00-\x1f<>"|?*:]') { throw "Componente ZIP inseguro: $Path" }
        $device = ($part.Split('.')[0]).ToUpperInvariant()
        if ($device -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "Nombre reservado de Windows: $Path"
        }
        if ($part.ToLowerInvariant() -in @('saves','playerdata','advancements','stats','distanthorizons','distant_horizons','dh')) {
            throw "El ZIP contiene datos persistentes no administrables: $Path"
        }
    }
    if ($parts[0].Equals('.coco',[StringComparison]::OrdinalIgnoreCase)) {
        throw "El ZIP intenta incluir metadatos reservados: $Path"
    }
    return $Path
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (![string]::IsNullOrEmpty($current)) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $info = Get-Item -LiteralPath $current -Force
            if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Se rechazo un enlace o junction en la ruta: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (!$parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-StreamDigest([IO.Stream]$InputStream) {
    $digest = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] (1024 * 1024)
    [long]$bytes = 0
    try {
        while (($count = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$digest.TransformBlock($buffer, 0, $count, $buffer, 0)
            $bytes += $count
        }
        [void]$digest.TransformFinalBlock($buffer, 0, 0)
        return [pscustomobject]@{
            Sha256 = [BitConverter]::ToString($digest.Hash).Replace('-', '').ToLowerInvariant()
            Size = $bytes
        }
    } finally { $digest.Dispose() }
}

function Write-NewUtf8Json([string]$File, $Object) {
    $json = ConvertTo-Json -InputObject $Object -Depth 32
    $utf8 = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($File, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $utf8.GetBytes($json + [Environment]::NewLine)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Verify-Cover([string]$Path) {
    if (![IO.File]::Exists($Path)) { throw "No existe la portada: $Path" }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -notin @('.png','.jpg','.jpeg','.webp')) { throw 'Portada: usa PNG, JPG o WEBP.' }
    $file = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($file.Length -lt 12 -or $file.Length -gt 20MB) { throw 'Portada vacia o excesivamente grande.' }
        $bytes = New-Object byte[] 12
        [void]$file.Read($bytes, 0, $bytes.Length)
        $png = [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A'
        $jpg = [BitConverter]::ToString($bytes,0,3) -eq 'FF-D8-FF'
        $webp = [Text.Encoding]::ASCII.GetString($bytes,0,4) -eq 'RIFF' -and
            [Text.Encoding]::ASCII.GetString($bytes,8,4) -eq 'WEBP'
        if (!(($ext -eq '.png' -and $png) -or
              ($ext -in @('.jpg','.jpeg') -and $jpg) -or
              ($ext -eq '.webp' -and $webp))) {
            throw 'La firma de la portada no coincide con su extension.'
        }
    } finally { $file.Dispose() }
    return $ext
}

if ($Id -cnotmatch '^[a-z][a-z0-9-]{1,47}$' -or $Id.EndsWith('-')) {
    throw 'Id: usa 2-48 caracteres, inicial minuscula, solo a-z, 0-9 y guiones.'
}
if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Trim().Length -gt 120 -or $Name -match '[\x00-\x1f]') {
    throw 'Nombre invalido (1-120 caracteres).'
}
if ([string]::IsNullOrWhiteSpace($Version) -or $Version.Length -gt 100 -or $Version -match '[\x00-\x1f]') {
    throw 'Version invalida.'
}
$url = $null
if (![Uri]::TryCreate($ArchiveUrl, [UriKind]::Absolute, [ref]$url) -or
    $url.Scheme -ne 'https' -or !$url.Host -or $url.UserInfo -or $url.Query -or $url.Fragment -or
    !$url.AbsolutePath.EndsWith('.zip',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'ArchiveUrl: indica una URL HTTPS directa a un archivo ZIP, sin credenciales/query/fragmento.'
}
$Executable = Assert-SafePath $Executable
if (![IO.Path]::GetExtension($Executable).Equals('.exe',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Executable debe señalar exactamente un .exe dentro del ZIP.'
}
$extraRequired = @()
foreach ($item in $RequiredPaths) { $extraRequired += Assert-SafePath $item }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$launcher2Root = [IO.Path]::GetFullPath((Join-Path $desktopRoot '..'))
$repoRoot = [IO.Path]::GetFullPath((Join-Path $launcher2Root '..'))
$catalogPath = Join-Path $repoRoot 'launcher\catalog.template.json'
$draftRoot = Join-Path $launcher2Root 'drafts'
$outputPath = Join-Path $draftRoot $Id

Assert-NoReparse $draftRoot
Assert-NoReparse $ZipPath
Assert-NoReparse $CoverPath
if (!(Test-Path -LiteralPath $catalogPath -PathType Leaf)) { throw "No se encuentra catalogo base: $catalogPath" }
$sourceCatalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($sourceCatalog.schemaVersion -ne 1 -or !($sourceCatalog.experiences -is [array])) {
    throw 'El catalogo base no tiene la estructura esperada.'
}
if ($sourceCatalog.experiences | Where-Object { $_.id -ieq $Id }) {
    throw "El Id '$Id' ya existe en el catalogo original. No se reemplazara."
}
if (Test-Path -LiteralPath $outputPath) {
    throw "El borrador ya existe: $outputPath. No se sobrescribira."
}
$cover = Verify-Cover $CoverPath
if (!(Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "No existe ZIP local: $ZipPath" }

$zipFile = New-Object IO.FileStream([IO.Path]::GetFullPath($ZipPath), [IO.FileMode]::Open,
    [IO.FileAccess]::Read, [IO.FileShare]::Read)
$archive = $null
try {
    if ($zipFile.Length -lt 22) { throw 'El ZIP esta vacio o truncado.' }
    $archiveHash = Get-StreamDigest $zipFile
    if ($archiveHash.Size -ne $zipFile.Length) { throw 'El ZIP cambio durante la lectura.' }
    $zipFile.Position = 0
    $archive = New-Object IO.Compression.ZipArchive($zipFile, [IO.Compression.ZipArchiveMode]::Read, $true)
    if ($archive.Entries.Count -lt 1 -or $archive.Entries.Count -gt 150000) {
        throw 'El ZIP contiene una cantidad de entradas invalida.'
    }

    $entries = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $files = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
        $isDirectory = $entry.FullName.EndsWith('/')
        $path = Assert-SafePath $entry.FullName $isDirectory
        if ($entries.ContainsKey($path)) { throw "Ruta ZIP duplicada (Windows/case-insensitive): $path" }
        $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixMode -eq 0xA000 -or (($entry.ExternalAttributes -band 0x400) -ne 0)) {
            throw "Enlace simbolico/reparse ZIP no permitido: $path"
        }
        if ($isDirectory -and $entry.Length -ne 0) { throw "Directorio ZIP con datos: $path" }
        if (!$isDirectory -and ($entry.Length -lt 0 -or $entry.Length -gt 64GB)) {
            throw "Archivo ZIP demasiado grande: $path"
        }
        $entries.Add($path, [pscustomobject]@{ Directory = $isDirectory; Entry = $entry })
        if (!$isDirectory) { $files.Add($path, $entry) }
    }
    foreach ($path in $entries.Keys) {
        $parts = $path.Split('/')
        for ($i = 1; $i -lt $parts.Length; $i++) {
            $parent = [string]::Join('/', $parts[0..($i-1)])
            if ($files.ContainsKey($parent)) {
                throw "Archivo que tambien aparece como directorio: $parent"
            }
        }
        if ($files.ContainsKey($path) -and ($entries[$path].Directory)) {
            throw "Archivo y directorio con el mismo destino: $path"
        }
    }
    if (!$files.ContainsKey($Executable)) { throw "Executable no existe en el ZIP: $Executable" }

    $wanted = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $wanted.Add($Executable, $Executable)
    $supportNames = @('UnityPlayer.dll','GameAssembly.dll','winmm.dll','OnlineFix.dll','OnlineFix64.dll',
        'steam_api.dll','steam_api64.dll','EOSSDK-Win64-Shipping.dll','EOSSDK-Win32-Shipping.dll',
        'Custom.dll','UnityCrashHandler64.exe')
    foreach ($path in $files.Keys) {
        $fileName = [IO.Path]::GetFileName($path)
        if ($supportNames -icontains $fileName -and !$wanted.ContainsKey($path)) { $wanted.Add($path, $path) }
    }
    foreach ($path in $extraRequired) {
        if (!$files.ContainsKey($path)) { throw "RequiredPaths no existe en el ZIP: $path" }
        if (!$wanted.ContainsKey($path)) { $wanted.Add($path, $path) }
    }
    if ($wanted.Count -gt 128) { throw 'Demasiados archivos requeridos detectados (maximo 128).' }

    $requiredFiles = New-Object 'Collections.Generic.List[object]'
    $chosen = @($wanted.Keys | Sort-Object)
    foreach ($path in $chosen) {
        $entry = [IO.Compression.ZipArchiveEntry]$files[$path]
        if ($entry.Length -le 0) { throw "Archivo requerido vacio: $path" }
        $entryStream = $entry.Open()
        try { $hash = Get-StreamDigest $entryStream }
        finally { $entryStream.Dispose() }
        if ($hash.Size -ne $entry.Length) { throw "Entrada ZIP truncada: $path" }
        $requiredFiles.Add([ordered]@{
            path = $entry.FullName
            sha256 = $hash.Sha256
            size = [long]$hash.Size
            archiveSha256 = $archiveHash.Sha256
        })
    }
} finally {
    if ($archive) { $archive.Dispose() }
    $zipFile.Dispose()
}

# Esquema identico al de launcher/catalog.template.json; NO altera la fuente original.
$coverTarget = "assets/experiences/$Id$cover"
$candidate = [ordered]@{
    id = $Id
    name = $Name.Trim()
    ui = [ordered]@{ imagePath = $coverTarget }
    description = 'Experiencia standalone nueva: completar descripcion y validar multijugador antes de publicar.'
    instanceId = $Id
    managementMode = 'managed'
    runtime = [ordered]@{
        type = 'standalone'
        executable = [string]$files[$Executable].FullName
        requiredFiles = @($requiredFiles.ToArray())
    }
    pack = [ordered]@{
        packId = "standalone-$Id"
        lockPath = "launcher/experiences/$Id.lock.json"
        version = $Version
        sha256 = $archiveHash.Sha256
        size = [long]$archiveHash.Size
        archives = @([ordered]@{
            archiveUrl = $url.AbsoluteUri
            sha256 = $archiveHash.Sha256
            size = [long]$archiveHash.Size
        })
    }
    hosting = [ordered]@{ mode = 'p2p' }
    launch = [ordered]@{ workflow = 'coco-standalone'; arguments = @(); autoJoin = $false; serverName = "Coco - $Name" }
    files = @()
}
$lock = [ordered]@{
    schemaVersion = 1
    experienceId = $Id
    type = 'standalone'
    files = @()
    archive = [ordered]@{
        url = $url.AbsoluteUri
        sha256 = $archiveHash.Sha256
        size = [long]$archiveHash.Size
    }
}

# Validacion paralela a las reglas basicas de toExperience / toInstallManifest.
$badDigest = @($candidate.runtime.requiredFiles | Where-Object { $_.sha256 -cnotmatch '^[a-f0-9]{64}$' }).Count
if ($candidate.launch.workflow -ne 'coco-standalone' -or $candidate.hosting.mode -ne 'p2p' -or
    $candidate.runtime.requiredFiles.Count -lt 1 -or $candidate.pack.archives.Count -ne 1 -or
    $badDigest -gt 0) {
    throw 'El borrador no cumple el contrato basico standalone.'
}

# Stage exclusivo + rename atomico del directorio; nunca sobrescribe drafts/<id>.
Assert-NoReparse $draftRoot
[void][IO.Directory]::CreateDirectory($draftRoot)
Assert-NoReparse $draftRoot
$stage = Join-Path $draftRoot (".$Id-" + [Guid]::NewGuid().ToString('N') + '.stage')
[void][IO.Directory]::CreateDirectory($stage)
$committed = $false
try {
    Write-NewUtf8Json (Join-Path $stage 'catalog-candidate.json') $candidate
    Write-NewUtf8Json (Join-Path $stage 'source-lock.json') $lock
    [IO.File]::Copy([IO.Path]::GetFullPath($CoverPath), (Join-Path $stage "cover$cover"), $false)
    $review = @(
        "Borrador: $Id"
        "Fuente ZIP LOCAL (nombre): $([IO.Path]::GetFileName($ZipPath))"
        "SHA256 ZIP: $($archiveHash.Sha256) ($($archiveHash.Size) bytes)"
        'ArchiveUrl NO comprobada ni publicada; antes de fusionar debe apuntar a los mismos bytes.'
        'La metadata de P2P es solo propuesta. Valida instalacion, licencias, red y juego real.'
        ''
        'Revision manual, SIN publicar:'
        "1. Copia cover$cover a assets/experiences/$Id$cover"
        "2. Copia source-lock.json a launcher/experiences/$Id.lock.json"
        '3. Agrega el objeto catalog-candidate.json a experiences[] en launcher/catalog.template.json'
        '4. Revisa descripcion, hosting, runtime, reglas de seguridad y URLs.'
        '5. Ejecuta las pruebas del catalogo antes de publicar; no hay merge automatico.'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $stage 'REVIEW.txt'), $review, (New-Object Text.UTF8Encoding($false)))
    Assert-NoReparse $outputPath
    [IO.Directory]::Move($stage, $outputPath)
    $committed = $true
} finally {
    if (!$committed -and [IO.Directory]::Exists($stage)) {
        [IO.Directory]::Delete($stage, $true) # solo nuestro staging GUID
    }
}

Write-Host "Candidato listo, sin publicar: $outputPath"
Write-Host "ZIP SHA256: $($archiveHash.Sha256)"
Write-Host "Archivos requeridos: $($requiredFiles.Count). No se extrajo el juego."
Write-Host 'Siguiente comando para REVISION MANUAL:'
Write-Host ('code --reuse-window "{0}" "{1}" "{2}"' -f $catalogPath,
    (Join-Path $outputPath 'catalog-candidate.json'), (Join-Path $outputPath 'REVIEW.txt'))
