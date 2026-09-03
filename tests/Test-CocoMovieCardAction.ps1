[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba del boton VER PELICULA debe ejecutarse en STA.'}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

function Get-CocoMediaCardTestControls($Control){
    foreach($child in @($Control.Controls)){
        $child
        if($child.Controls.Count-gt0){Get-CocoMediaCardTestControls $child}
    }
}

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$theDrama=@($catalog.experiences|Where-Object id -eq 'the-drama-2026'|Select-Object -First 1)[0]
if(-not$theDrama){throw 'FAIL: The Drama no existe en el catalogo.'}
$mediaCatalog=[pscustomobject]@{experiences=@($theDrama)}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-movie-card-$([guid]::NewGuid().ToString('N'))"
$paths=@{ExperiencesRoot=$tempRoot;InstanceLocationsPath=(Join-Path $tempRoot 'instance-locations.json')}
$panel=New-Object Windows.Forms.Panel;$panel.Size=[Drawing.Size]::new(840,620)
$script:CocoMovieCardCallbackReached=$false

# Sustituye la accion de reproduccion directa por un callback de prueba
function Invoke-CocoMediaMovieAction($Experience){
    if([string]$Experience.id-eq'the-drama-2026'){$script:CocoMovieCardCallbackReached=$true}
}

try{
    Update-CocoExperienceCardsUi $panel $mediaCatalog $paths 'client'
    $allControls=@(Get-CocoMediaCardTestControls $panel)
    $movieButton=@($allControls|Where-Object{$_ -is [Windows.Forms.Button]-and[string]$_.Text-eq'VER PELICULA'}|Select-Object -First 1)[0]
    if(-not$movieButton){throw 'FAIL: no se genero el boton VER PELICULA para la experiencia tipo movie.'}
    $episodeButton=@($allControls|Where-Object{$_ -is [Windows.Forms.Button]-and[string]$_.Text-eq'EPISODIOS'}|Select-Object -First 1)[0]
    if($episodeButton){throw 'FAIL: una pelicula no debe mostrar boton EPISODIOS.'}
    
    $labels=@($allControls|Where-Object{$_ -is [Windows.Forms.Label]})
    $hasEpisodiosText=@($labels|Where-Object{[string]$_.Text-like'*episodio*'}).Count
    if($hasEpisodiosText-gt0){throw 'FAIL: una pelicula no debe mostrar texto de episodios en sus etiquetas.'}
    
    Remove-Item Function:\Invoke-CocoMediaMovieAction -Force
    $movieButton.PerformClick()
    if(-not$script:CocoMovieCardCallbackReached){throw 'FAIL: VER PELICULA depende del nombre de una funcion que desaparece fuera del alcance del launcher.'}
    'PASS: VER PELICULA genera el boton adecuado y conserva su accion directa sin mostrar episodios.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
