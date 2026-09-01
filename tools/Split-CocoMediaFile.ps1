[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [string]$OutputDirectory='',
    [string]$Part1Name='',
    [string]$Part2Name='',
    [string]$FfmpegPath='',
    [string]$FfprobePath='',
    [double]$SplitAtSeconds=0
)

$ErrorActionPreference='Stop'
$maximumGitHubReleaseAssetBytes=[int64]2147483648

function Resolve-CocoMediaTool([string]$RequestedPath,[string]$CommandName,[string[]]$FallbackPaths){
    if(-not[string]::IsNullOrWhiteSpace($RequestedPath)){
        $resolved=[IO.Path]::GetFullPath($RequestedPath)
        if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "No existe $CommandName en '$resolved'."}
        return $resolved
    }
    $command=Get-Command $CommandName -ErrorAction SilentlyContinue
    if($command){return [IO.Path]::GetFullPath($command.Source)}
    foreach($fallback in $FallbackPaths){if($fallback-and(Test-Path -LiteralPath $fallback -PathType Leaf)){return [IO.Path]::GetFullPath($fallback)}}
    throw "No se encontro $CommandName. Instala FFmpeg o pasa -$($CommandName.Substring(0,1).ToUpperInvariant()+$CommandName.Substring(1))Path."
}

function Assert-CocoMediaOutputName([string]$Name,[string]$Label){
    if([string]::IsNullOrWhiteSpace($Name)-or[IO.Path]::GetFileName($Name)-ne$Name-or
       $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars())-ge0-or
       [IO.Path]::GetExtension($Name).ToLowerInvariant()-ne'.mp4'){
        throw "$Label debe ser un nombre de archivo MP4 seguro."
    }
}

$inputFull=[IO.Path]::GetFullPath($InputPath)
if(-not(Test-Path -LiteralPath $inputFull -PathType Leaf)){throw "No existe el archivo de entrada: $inputFull"}
if([IO.Path]::GetExtension($inputFull).ToLowerInvariant()-ne'.mp4'){throw 'Split-CocoMediaFile solo acepta un MP4 como entrada.'}
$inputItem=Get-Item -LiteralPath $inputFull -Force
if([int64]$inputItem.Length-le0){throw 'El archivo de entrada esta vacio.'}

if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=Split-Path $inputFull -Parent}
$outputFull=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputFull -Force|Out-Null
if([string]::IsNullOrWhiteSpace($Part1Name)){$Part1Name="{0} - Parte 1.mp4"-f[IO.Path]::GetFileNameWithoutExtension($inputFull)}
if([string]::IsNullOrWhiteSpace($Part2Name)){$Part2Name="{0} - Parte 2.mp4"-f[IO.Path]::GetFileNameWithoutExtension($inputFull)}
Assert-CocoMediaOutputName $Part1Name 'Part1Name';Assert-CocoMediaOutputName $Part2Name 'Part2Name'
if([string]::Equals($Part1Name,$Part2Name,[StringComparison]::OrdinalIgnoreCase)){throw 'Las partes deben tener nombres distintos.'}
$destination1=Join-Path $outputFull $Part1Name;$destination2=Join-Path $outputFull $Part2Name
foreach($destination in @($destination1,$destination2)){if(Test-Path -LiteralPath $destination -PathType Leaf){throw "El destino ya existe: $destination"}}

$ffmpeg=Resolve-CocoMediaTool $FfmpegPath 'ffmpeg' @(
    'C:\Users\smol\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-full_build\bin\ffmpeg.exe',
    'C:\Users\smol\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg.Shared_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-full_build-shared\bin\ffmpeg.exe'
)
$probeFallbacks=@()
if(-not[string]::IsNullOrWhiteSpace($FfmpegPath)){$probeFallbacks+=Join-Path (Split-Path $ffmpeg -Parent) 'ffprobe.exe'}
$probe=Resolve-CocoMediaTool $FfprobePath 'ffprobe' ($probeFallbacks+@(
    'C:\Users\smol\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-full_build\bin\ffprobe.exe',
    'C:\Users\smol\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg.Shared_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-full_build-shared\bin\ffprobe.exe'
))

$durationText=& $probe -v error -show_entries format=duration -of default=nw=1:nk=1 $inputFull 2>$null
if($LASTEXITCODE-ne0){throw 'ffprobe no pudo leer la duracion del MP4.'}
$duration=0.0
if(-not[double]::TryParse(([string]$durationText).Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$duration)-or$duration-le1){throw "Duracion MP4 invalida: $durationText"}
if($SplitAtSeconds-le0){$SplitAtSeconds=$duration/2.0}
if($SplitAtSeconds-le1-or$SplitAtSeconds-ge($duration-1)){throw "El punto de corte debe estar dentro de 1 y $([Math]::Round($duration-1,3)) segundos."}

$staging=Join-Path $outputFull ('.coco-media-split-{0}'-f[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force|Out-Null
try{
    $rawPattern=Join-Path $staging 'raw-%d.mp4'
    & $ffmpeg -hide_banner -loglevel error -y -i $inputFull -map 0 -c copy -f segment -segment_time ([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:R}',$SplitAtSeconds)) -reset_timestamps 1 -segment_format mp4 $rawPattern
    if($LASTEXITCODE-ne0){throw "ffmpeg no pudo segmentar el archivo (codigo $LASTEXITCODE)."}
    $rawParts=@(Get-ChildItem -LiteralPath $staging -Filter 'raw-*.mp4' -File|Sort-Object Name)
    if($rawParts.Count-ne2){throw "La segmentacion produjo $($rawParts.Count) partes; se esperaban exactamente 2."}
    $staged1=Join-Path $staging 'part-1.mp4';$staged2=Join-Path $staging 'part-2.mp4'
    foreach($pair in @(@($rawParts[0],$staged1),@($rawParts[1],$staged2))){
        & $ffmpeg -hide_banner -loglevel error -y -i $pair[0].FullName -map 0 -c copy -movflags +faststart $pair[1]
        if($LASTEXITCODE-ne0){throw "ffmpeg no pudo preparar $($pair[1])."}
    }
    $results=@()
    foreach($pair in @(@($staged1,$destination1),@($staged2,$destination2))){
        $json=& $probe -v error -show_entries format=duration,size:stream=codec_type,codec_name -of json $pair[0]|ConvertFrom-Json
        if($LASTEXITCODE-ne0-or-not$json.format-or[double]$json.format.duration-le1){throw "ffprobe no pudo validar '$($pair[0])'."}
        if(@($json.streams|Where-Object codec_type -eq 'video').Count-ne1){throw "'$($pair[0])' no contiene exactamente un stream de video."}
        if([int64](Get-Item -LiteralPath $pair[0]).Length-ge$maximumGitHubReleaseAssetBytes){throw "'$($pair[0])' supera 2 GiB y no es apto para GitHub Releases."}
        $results+=[pscustomobject]@{Path=$pair[1];Name=[IO.Path]::GetFileName($pair[1]);Size=[int64](Get-Item -LiteralPath $pair[0]).Length;Sha256=(Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash.ToLowerInvariant();DurationSeconds=[double]$json.format.duration;Streams=@($json.streams|ForEach-Object{"$($_.codec_type):$($_.codec_name)"}) -join ', '}
    }
    [IO.File]::Move($staged1,$destination1);[IO.File]::Move($staged2,$destination2)
    $results|ConvertTo-Json -Depth 4
}finally{
    if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue}
}
