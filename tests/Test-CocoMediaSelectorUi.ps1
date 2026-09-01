[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba del selector debe ejecutarse en STA.'}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$template=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
$experience=$template.PSObject.Copy();$experience.content=$template.content.PSObject.Copy();$experience.content.downloadFolderName="coco-media-selector-$([Guid]::NewGuid().ToString('N'))"
$parent=New-Object Windows.Forms.Form;$parent.Name='CocoMediaSelectorTestParent';$parent.ClientSize=New-Object Drawing.Size(640,420)
$script:CocoForm=$parent;$script:CocoMediaDownloadInProgress=$false;$script:CocoMediaSelectorSeen=$false;$script:CocoMediaSelectorClosed=$false;$script:CocoMediaSelectorFailure=''
$timer=New-Object Windows.Forms.Timer;$timer.Interval=100
$timer.Add_Tick({
    $selector=@([Windows.Forms.Application]::OpenForms|Where-Object Name -eq 'CocoMediaEpisodeSelector'|Select-Object -First 1)[0]
    if(-not$selector){return}
    $script:CocoMediaSelectorSeen=$true
    if($selector.FormBorderStyle-ne[Windows.Forms.FormBorderStyle]::None){$script:CocoMediaSelectorFailure='El selector conserva el marco clasico.'}
    $cancel=@($selector.Controls|ForEach-Object{$_.Controls}|Where-Object Name -eq 'CocoMediaCancelButton'|Select-Object -First 1)[0]
    $folder=@($selector.Controls|ForEach-Object{$_.Controls}|Where-Object Name -eq 'CocoMediaOpenFolderButton'|Select-Object -First 1)[0]
    $removedSelectorControls=@($selector.Controls|ForEach-Object{$_.Controls}|Where-Object Name -in @('CocoMediaSelectorInfo','CocoMediaSelectorStatus','CocoMediaSelectorSubtitle'))
    $header=@($selector.Controls|Where-Object Name -eq 'CocoMediaSelectorHeader'|Select-Object -First 1)[0]
    $rows=@($selector.Controls|ForEach-Object{$_.Controls}|ForEach-Object{$_.Controls}|Where-Object Name -eq 'CocoMediaEpisodeRow')
    if(-not$cancel){$script:CocoMediaSelectorFailure='No aparecio el boton CANCELAR moderno.';return}
    if($folder){$script:CocoMediaSelectorFailure='El selector de video aun muestra una accion de carpeta.';return}
    if($removedSelectorControls.Count){$script:CocoMediaSelectorFailure='El selector aun conserva una seccion de texto redundante.';return}
    if(-not$header){$script:CocoMediaSelectorFailure='No aparecio la cabecera propia del selector.';return}
    if($rows.Count-ne2){$script:CocoMediaSelectorFailure="El selector mostro $($rows.Count) filas; se esperaban 2.";return}
    $cancel.PerformClick();$timer.Stop()
})
$timer.Start()
$downloadRoot=Get-CocoMediaDownloadRoot $experience
try{
    Invoke-CocoMediaEpisodeUi $experience
    $script:CocoMediaSelectorClosed=$true
    if($script:CocoMediaSelectorFailure){throw $script:CocoMediaSelectorFailure}
    if(-not$script:CocoMediaSelectorSeen){throw 'El selector no llego a mostrarse.'}
    'PASS: el selector moderno mostro las dos partes y CANCELAR lo cerro cuando no habia descarga activa.'
}finally{
    $timer.Stop();$timer.Dispose()
    if($parent-and-not$parent.IsDisposed){$parent.Dispose()}
    $script:CocoForm=$null
    if(Test-Path -LiteralPath $downloadRoot){Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
