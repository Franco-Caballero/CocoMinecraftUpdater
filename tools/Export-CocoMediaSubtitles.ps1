<#
.SYNOPSIS
    Export-CocoMediaSubtitles.ps1 - Extrae la pista de subtitulos en espanol de un archivo MKV/MP4 a formato SRT en 1 segundo.

.DESCRIPTION
    Aprovecha ffprobe y ffmpeg locales para inspeccionar las pistas de subtitulos de un video
    original y extraer la pista en espanol sin recodificar ni tocar el video, produciendo un archivo
    .srt liviano listo para subir a GitHub Releases y vincular en Coco Launcher.

.PARAMETER SourceVideo
    Ruta al archivo de video (MKV, MP4, etc.).

.PARAMETER OutputPath
    Ruta de destino para el archivo .srt. Por defecto: <mismo-directorio>\<nombre-base>.es.srt.

.PARAMETER Language
    Filtro de idioma (por defecto: 'spa'). Acepta 'es', 'spa', 'spanish', 'espanol'.

.PARAMETER ListOnly
    Muestra las pistas de subtitulos encontradas sin realizar la extraccion.

.EXAMPLE
    .\tools\Export-CocoMediaSubtitles.ps1 -SourceVideo "C:\Peliculas\The.Drama.2026.1080p.mkv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$SourceVideo,

    [Parameter(Position=1)]
    [string]$OutputPath,

    [string]$Language='spa',

    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourceVideo -PathType Leaf)) {
    throw "No existe el archivo de video especificado: $SourceVideo"
}

$ffprobe = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue

if (-not $ffprobe -or -not $ffmpeg) {
    throw "ffprobe.exe y/o ffmpeg.exe no se encontraron en el PATH del sistema."
}

Write-Host "Inspeccionando pistas en '$([IO.Path]::GetFileName($SourceVideo))'..." -ForegroundColor Cyan

# Ejecutar ffprobe para obtener streams en JSON
$probeJson = & $ffprobe.Source -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language,title -of json "$SourceVideo" | Out-String
$probeData = try { $probeJson | ConvertFrom-Json } catch { $null }

$subStreams = if ($probeData -and $probeData.streams) { @($probeData.streams) } else { @() }

if ($subStreams.Count -eq 0) {
    throw "El archivo de video no contiene pistas de subtitulos embebidas."
}

Write-Host "Pistas de subtitulos encontradas ($($subStreams.Count)):" -ForegroundColor Yellow
$chosenStream = $null
$subIndexInSubStreams = 0

for ($i = 0; $i -lt $subStreams.Count; $i++) {
    $s = $subStreams[$i]
    $lang = if ($s.tags -and $s.tags.language) { [string]$s.tags.language } else { 'und' }
    $title = if ($s.tags -and $s.tags.title) { [string]$s.tags.title } else { '' }
    $codec = [string]$s.codec_name

    $isSpanish = ($lang -match '(?i)^(es|spa|esl)$') -or ($title -match '(?i)spanish|español|espanol')
    $marker = if ($isSpanish) { " [SELECCIONADA: ESPAÑOL]" } else { "" }

    Write-Host ("  [{0}] Stream #{1} | Codec: {2} | Idioma: {3} | Titulo: '{4}'{5}" -f $i, $s.index, $codec, $lang, $title, $marker) -ForegroundColor $(if ($isSpanish) { 'Green' } else { 'Gray' })

    if ($isSpanish -and -not $chosenStream) {
        $chosenStream = $s
        $subIndexInSubStreams = $i
    }
}

if ($ListOnly) {
    return
}

if (-not $chosenStream) {
    # Si ninguna dice espanol, si solo hay 1 pista, seleccionarla
    if ($subStreams.Count -eq 1) {
        $chosenStream = $subStreams[0]
        $subIndexInSubStreams = 0
        Write-Host "Ninguna pista marcada como espanol explicitamente; seleccionando la unica pista disponible." -ForegroundColor Yellow
    } else {
        throw "No se encontro una pista de subtitulos en espanol (spa/es/spanish). Usa -ListOnly para ver las pistas disponibles."
    }
}

# Resolver ruta de salida
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path $SourceVideo -Parent
    $baseName = [IO.Path]::GetFileNameWithoutExtension($SourceVideo)
    $OutputPath = Join-Path $parent "$baseName.es.srt"
}

$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Write-Host "`nExtrayendo pista de subtitulos a '$OutputPath'..." -ForegroundColor Cyan

# Extraer en 1 segundo con ffmpeg usando mapeo relativo a subtitulos (0:s:<subIndexInSubStreams>)
$process = Start-Process -FilePath $ffmpeg.Source -ArgumentList @(
    '-y',
    '-v', 'error',
    '-i', $SourceVideo,
    '-map', "0:s:$subIndexInSubStreams",
    '-c:s', 'srt',
    $OutputPath
) -NoNewWindow -PassThru -Wait

if ($process.ExitCode -ne 0) {
    throw "ffmpeg fallo al extraer los subtitulos (ExitCode: $($process.ExitCode))."
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw "El archivo de salida no fue creado: $OutputPath"
}

$outputInfo = Get-Item -LiteralPath $OutputPath -Force
Write-Host ("`nEXITO: Subtitulo extraido correctamente ({0:N1} KB):`n  {1}" -f ($outputInfo.Length / 1KB), $OutputPath) -ForegroundColor Green

# Mostrar muestra de los primeros cues
$sampleLines = Get-Content -LiteralPath $OutputPath -TotalCount 12
Write-Host "`nMuestra del subtitulo extraido:" -ForegroundColor Gray
$sampleLines | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

[pscustomobject]@{
    SourceVideo = $SourceVideo
    OutputPath = $OutputPath
    SizeBytes = $outputInfo.Length
    StreamIndex = $chosenStream.index
}
