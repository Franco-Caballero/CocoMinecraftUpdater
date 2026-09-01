[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba del boton EPISODIOS debe ejecutarse en STA.'}
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
$heartSignal=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
if(-not$heartSignal){throw 'FAIL: Heart Signal no existe en el catalogo.'}
$mediaCatalog=[pscustomobject]@{experiences=@($heartSignal)}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-media-card-$([guid]::NewGuid().ToString('N'))"
$paths=@{ExperiencesRoot=$tempRoot;InstanceLocationsPath=(Join-Path $tempRoot 'instance-locations.json')}
$panel=New-Object Windows.Forms.Panel;$panel.Size=[Drawing.Size]::new(840,620)
$script:CocoMediaCardCallbackReached=$false

# Sustituye la UI modal por un marcador, construye la tarjeta y despues elimina
# el nombre de la funcion. El clic debe seguir funcionando mediante el bloque
# capturado, igual que en un launcher actualizado desde una version antigua.
function Invoke-CocoMediaEpisodeUi($Experience){
    if([string]$Experience.id-eq'heart-signal'){$script:CocoMediaCardCallbackReached=$true}
}

try{
    Update-CocoExperienceCardsUi $panel $mediaCatalog $paths 'client'
    $episodeButton=@(Get-CocoMediaCardTestControls $panel|Where-Object{$_ -is [Windows.Forms.Button]-and[string]$_.Text-eq'EPISODIOS'}|Select-Object -First 1)[0]
    if(-not$episodeButton){throw 'FAIL: no se genero el boton EPISODIOS.'}
    Remove-Item Function:\Invoke-CocoMediaEpisodeUi -Force
    $episodeButton.PerformClick()
    if(-not$script:CocoMediaCardCallbackReached){throw 'FAIL: EPISODIOS depende del nombre de una funcion que desaparece fuera del alcance del launcher.'}
    'PASS: EPISODIOS conserva su accion en un callback WinForms aislado.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
