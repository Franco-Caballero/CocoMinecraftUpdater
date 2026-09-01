[CmdletBinding()]
param(
    [string]$SourcePath=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\heart signal\Heart Signal - S05E01 - Parte 1.mp4'),
    [string]$EpisodeId='s05e01-p01',
    [switch]$RecordVerifiedState
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $root 'engine\CocoLauncher.ps1')

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$experience=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
if(-not$experience){throw 'El catalogo no contiene Heart Signal.'}
$episode=@($experience.content.episodes|Where-Object id -eq $EpisodeId|Select-Object -First 1)[0]
if(-not$episode){throw "Heart Signal no contiene $EpisodeId."}
if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "No existe el archivo de prueba: $SourcePath"}
$source=[IO.Path]::GetFullPath($SourcePath)
$destination=[IO.Path]::GetFullPath((Get-CocoMediaEpisodePath $experience $episode))
if(-not[string]::Equals($source,$destination,[StringComparison]::OrdinalIgnoreCase)){
    throw "La prueba exige que el archivo este en la carpeta administrada de Downloads: $destination"
}
$sourceInfo=Get-Item -LiteralPath $source -Force
if([int64]$sourceInfo.Length-ne[int64]$episode.size){throw "Tamano incorrecto: $($sourceInfo.Length) != $($episode.size)"}
$check=Test-CocoMediaEpisodeFile $experience $episode -RecordVerifiedState:$RecordVerifiedState
if(-not$check.Exists-or-not$check.Matches){throw "SHA-256 incorrecto: obtenido=$($check.ActualHash), esperado=$($check.ExpectedHash)"}
$status=Get-CocoMediaEpisodeLocalStatus $experience $episode
if($RecordVerifiedState-and$status.Status-ne'verified'){throw "El estado local no quedo verificado: $($status.Status)"}
[pscustomobject]@{
    Experience=[string]$experience.name
    Episode=[string]$episode.id
    Path=$source
    Size=[int64]$sourceInfo.Length
    Sha256=[string]$check.ActualHash
    LocalStatus=[string]$status.Status
    StateRecorded=[bool]$RecordVerifiedState
}|ConvertTo-Json -Compress
    "PASS: Heart Signal $EpisodeId coincide con la metadata fijada y queda listo para el reproductor integrado."
