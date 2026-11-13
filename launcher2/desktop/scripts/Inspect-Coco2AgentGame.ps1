#requires -Version 5.1
<#
.SYNOPSIS
  Inspeccion ZIP local para el agente del HOST. Rapida, read-only y sin ejecutar.
.DESCRIPTION
  Devuelve JSON compacto con ejecutables plausibles, portadas, archivos
  relevantes, riesgos y rutas; el verificador Rust es la autoridad final.
  -HashArchive activa SHA-256 por streaming opcional; de otro modo la receta
  New-CocoStandaloneCandidate ya calcula el hash cuando crea el borrador.
.EXAMPLE
  powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
    .\launcher2\desktop\scripts\Inspect-Coco2AgentGame.ps1 `
    -ZipPath 'D:\Fuentes\juego-autorizado.zip' -Name 'Juego autorizado'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ZipPath,
  [string]$Name = '',
  [switch]$HashArchive
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

function Assert-NoLinks([string]$Path) {
  $p=[IO.Path]::GetFullPath($Path)
  while($p){
    if([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)){
      $f=Get-Item -LiteralPath $p -Force -ErrorAction Stop
      if(($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
        throw "Reparse point/symlink no autorizado: $p"
      }
    }
    $up=[IO.Path]::GetDirectoryName($p)
    if(!$up -or $up -eq $p){break}
    $p=$up
  }
}
function Valid-ZipPath([string]$Value,[bool]$Directory) {
  if(!$Value -or $Value.Length -gt 1024 -or $Value.StartsWith('/') -or
    $Value.Contains('\') -or $Value.Contains(':') -or $Value -match '[\x00-\x1f<>"|?*:]'){
    return $false
  }
  $path=if($Directory){$Value.TrimEnd('/')}else{$Value}
  foreach($piece in $path.Split('/')){
    if(!$piece -or $piece -eq '.' -or $piece -eq '..' -or
      $piece.EndsWith('.') -or $piece.EndsWith(' ')) {return $false}
    $stem=$piece.Split('.')[0].ToUpperInvariant()
    if($stem -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'){return $false}
    if($piece -match '^(?i:saves|playerdata|advancements|stats|distanthorizons|distant_horizons|dh)$'){
      return $false
    }
  }
  return $path.Split('/')[0] -ine '.coco'
}
function Add-Issue([Collections.Generic.List[string]]$Target,[string]$Detail){
  if($Target.Count -lt 24){$Target.Add($Detail)}
}

$watch=[Diagnostics.Stopwatch]::StartNew()
if(!$ZipPath -or ![IO.Path]::IsPathRooted($ZipPath) -or $ZipPath.StartsWith('\\')){
  throw 'La fuente debe ser un ZIP local absoluto, no UNC ni relativo.'
}
$source=[IO.Path]::GetFullPath($ZipPath)
if([IO.Path]::GetExtension($source) -ine '.zip') {throw 'La fuente debe terminar en .zip'}
Assert-NoLinks $source
if(![IO.File]::Exists($source)) {throw "ZIP no existe: $source"}
$stream=New-Object IO.FileStream($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$zip=$null
$digest=$null
try {
  [long]$size=$stream.Length
  if($size -lt 22 -or $size -gt 128GB){throw 'ZIP vacio o fuera de presupuesto (128 GiB)'}
  if($HashArchive){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
      $digest=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
    $stream.Position=0
  }
  $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
  if($zip.Entries.Count -eq 0 -or $zip.Entries.Count -gt 150000){throw 'Conteo ZIP no permitido'}
  $issues=New-Object 'Collections.Generic.List[string]'
  $executables=New-Object 'Collections.Generic.List[string]'
  $covers=New-Object 'Collections.Generic.List[string]'
  $support=New-Object 'Collections.Generic.List[string]'
  $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  [long]$uncompressed=0
  foreach($entry in $zip.Entries){
    $path=$entry.FullName
    $dir=$path.EndsWith('/')
    if(!(Valid-ZipPath $path $dir)){Add-Issue $issues "Ruta insegura/prohibida: $path";continue}
    if(!$seen.Add($path)){Add-Issue $issues "Ruta repetida con casing Windows: $path";continue}
    if(($entry.ExternalAttributes -band 0x400) -ne 0 -or
      (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){
      Add-Issue $issues "Symlink/archivo especial ZIP: $path";continue
    }
    if($entry.Length -gt 64GB -or $entry.Length -lt 0){Add-Issue $issues "Entrada fuera de presupuesto: $path";continue}
    $uncompressed += $entry.Length
    if($dir){continue}
    $fileName=($path.Split('/')[-1])
    if($fileName -match '(?i)\.exe$' -and
      $fileName -notmatch '(?i)(?:unins\w*|setup|install\w*|unrealprereq|crashhandler|vc_redist|dxsetup)\.exe$'){
      if($executables.Count -lt 256){$executables.Add($path)}
    }
    if($fileName -match '(?i)^(?:cover|poster|artwork|icon|banner)\.(?:png|jpe?g|webp)$'){
      if($covers.Count -lt 32){$covers.Add($path)}
    }
    if($fileName -match '(?i)^(?:unityplayer|gameassembly|winmm|steam_api(?:64)?|eossdk-win64-shipping)\.dll$'){
      if($support.Count -lt 128){$support.Add($path)}
    }
  }
  $chosen=$null
  if($issues.Count -eq 0 -and $executables.Count -eq 1){$chosen=$executables[0]}
  $watch.Stop()
  $result=[ordered]@{
    schemaVersion=1
    status='inspection-only-untrusted'
    source=$source
    titleHint=$Name
    zipBytes=$size
    zipSha256=$digest
    shaDeferred=(!$HashArchive)
    entries=$zip.Entries.Count
    uncompressedBytes=$uncompressed
    executableCandidates=@($executables.ToArray())
    uniqueExecutableSuggestion=$chosen
    coverCandidates=@($covers.ToArray())
    supportFiles=@($support.ToArray())
    issues=@($issues.ToArray())
    elapsedMs=$watch.ElapsedMilliseconds
    nextAction=if($issues.Count){'Reject until issues are resolved; native Rust validator is authoritative.'}else{
      if($chosen){'Use explicit executable and legitimate cover/ZIP URL with New-CocoStandaloneCandidate.ps1.'}else{'Agent must select a verified main executable; never guess.'}
    }
  }
  ConvertTo-Json -InputObject $result -Depth 8 -Compress
}finally{
  if($zip){$zip.Dispose()}
  $stream.Dispose()
}
