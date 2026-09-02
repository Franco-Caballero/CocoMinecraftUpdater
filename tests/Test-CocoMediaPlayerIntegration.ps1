[CmdletBinding()]
param(
    [string]$SourceUrl='https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/heart-signal-s05e01-parts-20260901/Heart.Signal.-.S05E01.-.Parte.1.mp4',
    [string]$SourcePath=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\heart signal\Heart Signal - S05E01 - Parte 1.mp4'),
    [switch]$UseLocal,
    [switch]$SkipFullscreen,
    [int]$PlaySeconds=15
)

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba integrada debe ejecutarse en STA.'}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$template=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
$experience=$template.PSObject.Copy()
$experience.content=$template.content.PSObject.Copy()
$experience.content.downloadFolderName="coco-media-ui-smoke-$([Guid]::NewGuid().ToString('N'))"
$episode=@($template.content.episodes|Where-Object id -eq 's05e01-p01'|Select-Object -First 1)[0].PSObject.Copy()
$episode.title=if($UseLocal){'UI smoke local'}else{'UI smoke remoto'}
$episode.streamUrl=if($UseLocal){''}else{$SourceUrl}
$experience.content.episodes=@($episode)
$windowTitle="Heart Signal - $($episode.title)"
$script:CocoUiPositionBeforeClose=0.0
$script:CocoUiPaused=$false
$script:CocoUiResumed=$false
$script:CocoUiFullscreenTested=$false
$script:CocoUiPausePosition=0.0
$script:CocoUiPositionDuringPause=0.0
$script:CocoUiPositionText=''
$script:CocoUiPausedAtUtc=[DateTime]::MinValue
$script:CocoUiResumedAtUtc=[DateTime]::MinValue
$script:CocoUiFailure=''
$script:CocoUiTimedOut=$false
$timer=New-Object Windows.Forms.Timer
$timer.Interval=100
$startedAt=[DateTime]::UtcNow
$timer.Add_Tick({
    $window=$null
    try{
        $now=[DateTime]::UtcNow
        $elapsed=($now-$startedAt).TotalSeconds
        $window=@([Windows.Forms.Application]::OpenForms|Where-Object{$_.Text-eq$windowTitle}|Select-Object -First 1)[0]
        if($elapsed-ge35){
            $script:CocoUiTimedOut=$true;$script:CocoUiFailure='La prueba del reproductor excedio el tiempo limite.'
            if($window-and-not$window.IsDisposed){$window.Close()};$timer.Stop();return
        }
        if(-not$window){return}
        $videoHost=@($window.Controls|Where-Object{$_-is[Windows.Forms.Integration.ElementHost]}|Select-Object -First 1)[0]
        $mediaView=if($videoHost){$videoHost.Child}else{$null}
        $position=if($mediaView){[double]$mediaView.Position.TotalSeconds}else{0.0}
        $controlPanel=@($window.Controls|Where-Object{$_.Name-eq'CocoMediaControlPanel'}|Select-Object -First 1)[0]
        if(-not$controlPanel){return}
        $positionLabel=@($controlPanel.Controls|Where-Object{$_.Name-eq'CocoMediaPosition'}|Select-Object -First 1)[0]
        if($positionLabel){$script:CocoUiPositionText=[string]$positionLabel.Text}
        $pauseButton=@($controlPanel.Controls|Where-Object{$_.Text-eq'PAUSAR'}|Select-Object -First 1)[0]
        $playControl=@($controlPanel.Controls|Where-Object{$_.Name-eq'CocoMediaPlayButton'}|Select-Object -First 1)[0]
        $statusControl=@($controlPanel.Controls|Where-Object{$_.Name-eq'CocoMediaStatus'}|Select-Object -First 1)[0]
        $seekControl=@($controlPanel.Controls|Where-Object{$_.Name-eq'CocoMediaSeekBar'}|Select-Object -First 1)[0]
        $fullscreenControl=@($controlPanel.Controls|Where-Object{$_.Name-eq'CocoMediaFullscreenButton'}|Select-Object -First 1)[0]
        if($playControl-and$statusControl-and$statusControl.Left-ne($playControl.Right+8)){$script:CocoUiFailure='El estado Reproduciendo no quedo junto al boton de reproduccion.'}
        if($fullscreenControl-and$fullscreenControl.Text-ne'PANTALLA COMPLETA'){$script:CocoUiFailure='El boton de pantalla completa no muestra el texto completo.'}
        if($seekControl-and$fullscreenControl-and($seekControl.Right-ge$fullscreenControl.Left-or$fullscreenControl.Right-gt($controlPanel.ClientSize.Width-16))){$script:CocoUiFailure='La barra de reproduccion invade los controles derechos o toca el borde del reproductor.'}
        if(-not$script:CocoUiPaused-and$position-ge2-and$pauseButton){
            $script:CocoUiPausePosition=$position;$pauseButton.PerformClick();$script:CocoUiPaused=$true;$script:CocoUiPausedAtUtc=$now;return
        }
        if($script:CocoUiPaused-and-not$script:CocoUiResumed-and($now-$script:CocoUiPausedAtUtc).TotalSeconds-ge2){
            $script:CocoUiPositionDuringPause=$position
            if($script:CocoUiPositionDuringPause-gt($script:CocoUiPausePosition+0.75)){$script:CocoUiFailure='La posicion avanzo demasiado mientras el boton PAUSAR estaba activo.'}
            $resumeButton=@($controlPanel.Controls|Where-Object{$_.Text-eq'REPRODUCIR'}|Select-Object -First 1)[0]
            if($resumeButton){$resumeButton.PerformClick();$script:CocoUiResumed=$true;$script:CocoUiResumedAtUtc=$now};return
        }
        if(-not$SkipFullscreen-and$script:CocoUiResumed-and-not$script:CocoUiFullscreenTested-and($now-$script:CocoUiResumedAtUtc).TotalSeconds-ge1-and$fullscreenControl){
            $fullscreenControl.PerformClick()
            $headerControl=@($window.Controls|Where-Object{$_.Name-eq'CocoMediaHeader'}|Select-Object -First 1)[0]
            $footerControl=@($window.Controls|Where-Object{$_.Name-eq'CocoMediaControlPanel'}|Select-Object -First 1)[0]
            $screenBounds=[Windows.Forms.Screen]::FromControl($window).Bounds
            if($headerControl.Visible-or$footerControl.Visible-or$window.Bounds-ne$screenBounds){$script:CocoUiFailure='El boton no activo correctamente la pantalla completa real.'}
            else{
                $toggleAction=if($window.Tag-and$window.Tag.PSObject.Properties.Name-contains'ToggleFullscreen'){[System.Management.Automation.ScriptBlock]$window.Tag.ToggleFullscreen}else{$null}
                if($toggleAction){&$toggleAction}else{$footerControl.Visible=$true;$fullscreenControl.PerformClick()}
                [Windows.Forms.Application]::DoEvents()
                if($fullscreenControl-and$fullscreenControl.Text-ne'PANTALLA COMPLETA'){$script:CocoUiFailure='Escape no restauro el texto de pantalla completa.'}
                if(($headerControl-and-not$headerControl.Visible)-or($footerControl-and-not$footerControl.Visible)){$script:CocoUiFailure='El reproductor no pudo salir de pantalla completa.'}
            }
            $script:CocoUiFullscreenTested=$true
            if($mediaView){$script:CocoUiPositionBeforeClose=$mediaView.Position.TotalSeconds}
            $window.Close();$timer.Stop();return
        }
        if($script:CocoUiResumed-and($now-$script:CocoUiResumedAtUtc).TotalSeconds-ge3-or$elapsed-ge$PlaySeconds){
            if($mediaView){$script:CocoUiPositionBeforeClose=$mediaView.Position.TotalSeconds}
            $window.Close();$timer.Stop()
        }
    }catch{
        $script:CocoUiFailure="La prueba del reproductor lanzo una excepcion: $($_.Exception.Message)"
        if($window-and-not$window.IsDisposed){try{$window.Close()}catch{}}
        $timer.Stop()
    }
})
$playback=$null
try{
    $timer.Start()
    $source=if($UseLocal){$SourcePath}else{$SourceUrl}
    Invoke-CocoMediaPlayerUi $experience $episode $source
    $playback=Get-CocoMediaPlaybackState $experience $episode
    if($script:CocoUiFailure){throw $script:CocoUiFailure}
    if(-not$script:CocoUiPaused){throw 'La prueba no pudo pulsar PAUSAR durante la reproduccion.'}
    if(-not$script:CocoUiResumed){throw 'La prueba no pudo pulsar REPRODUCIR para reanudar.'}
    if(-not$SkipFullscreen-and-not$script:CocoUiFullscreenTested){throw 'La prueba no pudo validar el modo pantalla completa.'}
    if($playback.PositionSeconds-le0){throw "La ventana se cerro sin persistir una posicion positiva (position=$($playback.PositionSeconds); duration=$($playback.DurationSeconds); mediaPosition=$script:CocoUiPositionBeforeClose)."}
    [pscustomobject]@{PositionSeconds=$playback.PositionSeconds;DurationSeconds=$playback.DurationSeconds;PositionText=$script:CocoUiPositionText;PausedAt=$script:CocoUiPausePosition;PositionDuringPause=$script:CocoUiPositionDuringPause;Resumed=$script:CocoUiResumed}|ConvertTo-Json -Compress
    'PASS: la ventana integrada reprodujo, pauso, reanudo y persistio la posicion al cerrarse.'
}finally{
    $timer.Stop();$timer.Dispose()
    $testRoot=Get-CocoMediaDownloadRoot $experience
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
