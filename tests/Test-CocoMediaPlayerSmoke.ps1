[CmdletBinding()]
param(
    [string]$SourcePath=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\heart signal\Heart Signal - S05E01 - Parte 1.mp4'),
    [string]$SourceUrl='',
    [int]$TimeoutSeconds=20
)

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'El smoke test del reproductor debe ejecutarse en STA.'}
if($SourceUrl -and $SourceUrl-notmatch'^https://'){throw 'La URL de prueba debe usar HTTPS.'}
if(-not$SourceUrl-and-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "No existe el archivo de prueba: $SourcePath"}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration

$form=New-Object Windows.Forms.Form
$form.ClientSize=New-Object Drawing.Size(640,400)
$videoHost=New-Object Windows.Forms.Integration.ElementHost
$videoHost.Dock='Fill'
$media=New-Object System.Windows.Controls.MediaElement
$media.LoadedBehavior='Manual'
$media.UnloadedBehavior='Manual'
$media.Stretch='Uniform'
$videoHost.Child=$media
$form.Controls.Add($videoHost)
$script:CocoMediaSmokeResult='pending'
$media.Add_MediaOpened({
    try{$media.Play();$script:CocoMediaSmokeResult='opened'}catch{$script:CocoMediaSmokeResult="failed: $($_.Exception.Message)"}
    if(-not$form.IsDisposed){$form.BeginInvoke([Action]{if(-not$form.IsDisposed){$form.Close()}})|Out-Null}
})
$media.Add_MediaFailed({
    param($sender,$eventArgs)
    $message=try{[string]$eventArgs.ErrorException.Message}catch{'Windows no pudo decodificar el archivo.'}
    $script:CocoMediaSmokeResult="failed: $message"
    if(-not$form.IsDisposed){$form.BeginInvoke([Action]{if(-not$form.IsDisposed){$form.Close()}})|Out-Null}
})
$startTimer=New-Object Windows.Forms.Timer
$startTimer.Interval=250
$startTimer.Add_Tick({try{$media.Play()}catch{}})
$timer=New-Object Windows.Forms.Timer
$timer.Interval=[Math]::Max(1,$TimeoutSeconds)*1000
$timer.Add_Tick({$script:CocoMediaSmokeResult='timeout';if(-not$form.IsDisposed){$form.Close()}})
$proxy=$null
try{
    if($SourceUrl){
        $proxy=Start-CocoMediaHttpProxy $SourceUrl ([IO.Path]::GetFileName(([Uri]$SourceUrl).AbsolutePath))
        $mediaUri=[Uri]::new([string]$proxy.Url)
    }else{$mediaUri=[Uri]::new([IO.Path]::GetFullPath($SourcePath))}
    $form.Add_Shown({
        try{$media.Source=$mediaUri;$timer.Start();$startTimer.Start()}
        catch{$script:CocoMediaSmokeResult="failed: $($_.Exception.Message)";$form.Close()}
    })
    [void]$form.ShowDialog()
}finally{
    try{$timer.Stop();$startTimer.Stop();$media.Stop()}catch{}
    $timer.Dispose();$startTimer.Dispose();$form.Dispose()
    if($proxy){Stop-CocoMediaHttpProxy $proxy}
}
if($script:CocoMediaSmokeResult -ne 'opened'){throw "MediaElement no abrio el archivo: $script:CocoMediaSmokeResult"}
[pscustomobject]@{Source=if($SourceUrl){$SourceUrl}else{[IO.Path]::GetFullPath($SourcePath)};Result=$script:CocoMediaSmokeResult}|ConvertTo-Json -Compress
'PASS: MediaElement abrio la fuente en la ventana integrada.'
