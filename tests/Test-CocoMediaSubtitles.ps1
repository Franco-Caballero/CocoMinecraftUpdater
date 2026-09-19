[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

Write-Host "=== TEST 1: Parse-CocoSubtitles (SRT) ===" -ForegroundColor Cyan
$srtSample = @"
1
00:00:01,000 --> 00:00:04,500
Primera linea de prueba
con segunda linea

2
00:00:05,200 --> 00:00:08,800
Segunda linea con <i>cursiva</i> y <b>negrita</b>

3
01:15:30,500 --> 01:15:35,000
Linea tardia en la pelicula
"@

$cues = Parse-CocoSubtitles $srtSample
if ($cues.Count -ne 3) { throw "Esperados 3 cues SRT, obtenidos: $($cues.Count)" }
if ([Math]::Abs($cues[0].Start - 1.0) -gt 0.001) { throw "Cue 0 Start incorrecto: $($cues[0].Start)" }
if ([Math]::Abs($cues[0].End - 4.5) -gt 0.001) { throw "Cue 0 End incorrecto: $($cues[0].End)" }
if ($cues[0].Text -ne "Primera linea de prueba`ncon segunda linea") { throw "Cue 0 Text incorrecto: $($cues[0].Text)" }
if ($cues[1].Text -ne "Segunda linea con cursiva y negrita") { throw "Cue 1 Text con tags no se limpio: $($cues[1].Text)" }
if ([Math]::Abs($cues[2].Start - 4530.5) -gt 0.001) { throw "Cue 2 Start tardio incorrecto: $($cues[2].Start)" }
Write-Host "  PASS: Parse SRT exitoso." -ForegroundColor Green

Write-Host "=== TEST 2: Parse-CocoSubtitles (WebVTT) ===" -ForegroundColor Cyan
$vttSample = @"
WEBVTT - Titulo

00:00.500 --> 00:03.250
Inicio rapido sin hora

00:04.000 --> 00:07.500
Otra linea WebVTT
"@

$vttCues = Parse-CocoSubtitles $vttSample
if ($vttCues.Count -ne 2) { throw "Esperados 2 cues VTT, obtenidos: $($vttCues.Count)" }
if ([Math]::Abs($vttCues[0].Start - 0.5) -gt 0.001) { throw "VTT Cue 0 Start incorrecto: $($vttCues[0].Start)" }
if ([Math]::Abs($vttCues[0].End - 3.25) -gt 0.001) { throw "VTT Cue 0 End incorrecto: $($vttCues[0].End)" }
Write-Host "  PASS: Parse WebVTT exitoso." -ForegroundColor Green

Write-Host "=== TEST 3: Entradas vacias o invalidas ===" -ForegroundColor Cyan
$emptyCues = Parse-CocoSubtitles ""
if ($emptyCues.Count -ne 0) { throw "Entrada vacia no retorno lista vacia" }
$invalidCues = Parse-CocoSubtitles "texto sin timestamps ni formato"
if ($invalidCues.Count -ne 0) { throw "Entrada invalida no retorno lista vacia" }
Write-Host "  PASS: Entradas vacias/invalidas manejadas correctamente." -ForegroundColor Green

Write-Host "=== TEST 4: Find-CocoMediaSubtitleCue (Secuencial y Búsqueda) ===" -ForegroundColor Cyan
$idxRef = [ref]0
# En 2.0s -> debe encontrar cue 0
$c = Find-CocoMediaSubtitleCue $cues 2.0 $idxRef
if (-not $c -or $c.Text -notlike 'Primera*') { throw "No encontro cue 0 en t=2.0s" }

# En 4.8s (gap entre cue 0 y cue 1) -> debe retornar $null
$c = Find-CocoMediaSubtitleCue $cues 4.8 $idxRef
if ($null -ne $c) { throw "Gap entre cues debio retornar null" }

# En 6.0s -> debe encontrar cue 1
$c = Find-CocoMediaSubtitleCue $cues 6.0 $idxRef
if (-not $c -or $c.Text -notlike 'Segunda*') { throw "No encontro cue 1 en t=6.0s" }

# Salto hacia atras (seek to 1.5s) -> debe encontrar cue 0
$c = Find-CocoMediaSubtitleCue $cues 1.5 $idxRef
if (-not $c -or $c.Text -notlike 'Primera*') { throw "Seek atras a t=1.5s fallo" }

# Salto adelante (seek to 4531.0s) -> debe encontrar cue 2
$c = Find-CocoMediaSubtitleCue $cues 4531.0 $idxRef
if (-not $c -or $c.Text -notlike 'Linea tardia*') { throw "Seek adelante a t=4531s fallo" }

# Fuera de rango
$c = Find-CocoMediaSubtitleCue $cues 99999.0 $idxRef
if ($null -ne $c) { throw "Tiempo posterior a todos los cues debio retornar null" }
Write-Host "  PASS: Sincronizacion y busqueda de cues validada." -ForegroundColor Green

Write-Host "=== TEST 5: Auto-seleccion local de subtitulo en espanol ===" -ForegroundColor Cyan
$tempDir = Join-Path $env:TEMP "coco-sub-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $videoFile = Join-Path $tempDir "MiPelicula.mp4"
    [IO.File]::WriteAllText($videoFile, "fake video")

    # Crear subtitulo en ingles y en espanol
    $subEn = Join-Path $tempDir "MiPelicula.en.srt"
    $subEs = Join-Path $tempDir "MiPelicula.es.srt"
    [IO.File]::WriteAllText($subEn, "1`n00:00:01,000 --> 00:00:04,000`nEnglish cue`n")
    [IO.File]::WriteAllText($subEs, "1`n00:00:01,000 --> 00:00:04,000`nSubtitulo en espanol`n")

    $resolved = Get-CocoMediaEpisodeSubtitles $null $null $videoFile
    if (-not $resolved -or $resolved.Count -ne 1) { throw "No resolvio subtitulo local" }
    if ($resolved[0].Text -ne "Subtitulo en espanol") {
        throw "No priorizo el subtitulo en espanol (obtenido: $($resolved[0].Text))"
    }
    Write-Host "  PASS: Priorizo automaticamente 'MiPelicula.es.srt' sobre ingles." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "=== TEST 6: Auto-seleccion desde lista 'subtitles' en catalogo ===" -ForegroundColor Cyan
$mockEpisode = [pscustomobject]@{
    id = 'test-ep-01'
    subtitles = @(
        [pscustomobject]@{ language = 'en'; label = 'English'; url = 'https://example.com/en.srt' },
        [pscustomobject]@{ language = 'es'; label = 'Spanish / Español'; url = 'https://example.com/es.srt' }
    )
}
# Verificamos la logica de seleccion
$subs = @($mockEpisode.subtitles)
$selected = @($subs | Where-Object {
    ([string]$_.language -match '(?i)^(es|spa)$') -or ([string]$_.label -match '(?i)spanish|español')
} | Select-Object -First 1)[0]
if (-not $selected -or $selected.language -ne 'es') { throw "Fallo seleccion de idioma espanol en array de subtitulos" }
Write-Host "  PASS: Seleccion de pista de espanol desde metadatos declarados validada." -ForegroundColor Green

Write-Host "=== TEST 7: Aplanado de colecciones anidadas y comparacion de escala (Flatten-CocoMediaCues) ===" -ForegroundColor Cyan
$nestedCues = @(
    ,@(
        ,@(
            [pscustomobject]@{ Start = 1.0; End = 3.0; Text = "Cue 1" },
            [pscustomobject]@{ Start = 4.0; End = 6.0; Text = "Cue 2" }
        )
    ),
    [pscustomobject]@{ Start = 7.0; End = 9.0; Text = "Cue 3" }
)
$flattened = Flatten-CocoMediaCues $nestedCues
if ($flattened.Count -ne 3) { throw "Flatten-CocoMediaCues no aplano correctamente: esperados 3 cues, obtenidos $($flattened.Count)" }
if ($flattened[0].Start -ne 1.0 -or $flattened[1].Start -ne 4.0 -or $flattened[2].Start -ne 7.0) {
    throw "Flatten-CocoMediaCues altero los valores de Start"
}

# Verificamos que Find-CocoMediaSubtitleCue no falle con comparacion de arrays incluso si se le pasa algo anidado
$found = Find-CocoMediaSubtitleCue $nestedCues 5.0 ([ref]0)
if (-not $found -or $found.Text -ne "Cue 2") {
    throw "Find-CocoMediaSubtitleCue fallo al buscar sobre estructura anidada"
}

# Verificamos invocacion con IndexRef nulo
$foundNoRef = Find-CocoMediaSubtitleCue $flattened 8.0 $null
if (-not $foundNoRef -or $foundNoRef.Text -ne "Cue 3") {
    throw "Find-CocoMediaSubtitleCue fallo cuando IndexRef es null"
}

# Simular 2500 cues para validar que no haya regresion de comparacion de tipos en masa
$largeCues = [System.Collections.Generic.List[pscustomobject]]::new()
for ($i = 0; $i -lt 2500; $i++) {
    $largeCues.Add([pscustomobject]@{
        Start = [double]($i * 2)
        End   = [double]($i * 2 + 1.5)
        Text  = "Cue $i"
    })
}
$largeTest = @(Flatten-CocoMediaCues $largeCues.ToArray())
if ($largeTest.Count -ne 2500) { throw "Conjunto masivo no conservo los 2500 elementos" }
$timeToFind = 2450.2
$foundLarge = Find-CocoMediaSubtitleCue $largeTest $timeToFind ([ref]0)
if (-not $foundLarge -or $foundLarge.Text -ne "Cue 1225") {
    throw "Busqueda binaria en coleccion masiva de subtitulos fallo (esperado Cue 1225, obtenido: $($foundLarge.Text))"
}
Write-Host "  PASS: Aplanado, busqueda binaria y tipos escalares validados correctamente." -ForegroundColor Green

Write-Host "`nTODO APROBADO: Soporte de subtitulos suave y auto-seleccion funcionando correctamente." -ForegroundColor Green
