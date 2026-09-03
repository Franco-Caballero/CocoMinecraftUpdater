[CmdletBinding()]
param(
    [string]$SourcePath=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\the drama\The.Drama.2026.1080p.Spanish.Hardsub.AAC5.1.mp4'),
    [switch]$RecordVerifiedState,
    [switch]$AllowMissingLocal
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $root 'engine\CocoLauncher.ps1')

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$experience=@($catalog.experiences|Where-Object id -eq 'the-drama-2026'|Select-Object -First 1)[0]
if(-not$experience){throw 'El catalogo no contiene The Drama.'}
if(-not(Test-CocoMovieExperience $experience)){throw 'The Drama no esta reconocido como experiencia movie.'}

$items=@(Get-CocoMediaItems $experience)
if($items.Count-ne1){throw "The Drama debe tener exactamente 1 item de pelicula; encontrados: $($items.Count)."}
$movieItem=$items[0]

if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){
    if(-not$AllowMissingLocal){throw "No existe el archivo de pelicula local: $SourcePath"}
    if([string]$movieItem.streamUrl-notmatch'^https://'){throw 'La pelicula no tiene un streamUrl HTTPS para validacion remota.'}
    if([int64]$movieItem.size-le0-or[string]$movieItem.sha256-notmatch'^[0-9a-fA-F]{64}$'){throw 'La metadata remota de la pelicula no tiene tamano/hash validos.'}
    [pscustomobject]@{Experience=[string]$experience.name;Movie=[string]$movieItem.title;Path='(asset remoto; sin copia local)';Size=[int64]$movieItem.size;Sha256=[string]$movieItem.sha256;LocalStatus='streaming';StateRecorded=$false}|ConvertTo-Json -Compress
    'PASS: The Drama tiene metadata HTTPS/hash valida; no se requirio copia local para validar.'
    return
}

$source=[IO.Path]::GetFullPath($SourcePath)
$destination=[IO.Path]::GetFullPath((Get-CocoMediaEpisodePath $experience $movieItem))
if(-not[string]::Equals($source,$destination,[StringComparison]::OrdinalIgnoreCase)){
    throw "La prueba exige que el archivo este en la carpeta administrada de Downloads: $destination"
}

$sourceInfo=Get-Item -LiteralPath $source -Force
if([int64]$sourceInfo.Length-ne[int64]$movieItem.size){throw "Tamano incorrecto: $($sourceInfo.Length) != $($movieItem.size)"}
$check=Test-CocoMediaEpisodeFile $experience $movieItem -RecordVerifiedState:$RecordVerifiedState
if(-not$check.Exists-or-not$check.Matches){throw "SHA-256 incorrecto: obtenido=$($check.ActualHash), esperado=$($check.ExpectedHash)"}
$status=Get-CocoMediaEpisodeLocalStatus $experience $movieItem
if($RecordVerifiedState-and$status.Status-ne'verified'){throw "El estado local no quedo verificado: $($status.Status)"}

[pscustomobject]@{
    Experience=[string]$experience.name
    Movie=[string]$movieItem.title
    Path=$source
    Size=[int64]$sourceInfo.Length
    Sha256=[string]$check.ActualHash
    LocalStatus=[string]$status.Status
    StateRecorded=[bool]$RecordVerifiedState
} | ConvertTo-Json -Compress

"PASS: The Drama coincide con la metadata fijada y queda lista para el reproductor integrado."
