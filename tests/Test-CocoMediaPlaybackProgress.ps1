[CmdletBinding()]
param(
    [string]$SourcePath=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\heart signal\Heart Signal - S05E01 - Parte 1.mp4'),
    [string]$SourceUrl='',
    [int]$HoldSeconds=8,
    [int]$TimeoutSeconds=30
)

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba de progreso debe ejecutarse en STA.'}
if($SourceUrl-and$SourceUrl-notmatch'^https://'){throw 'La URL de prueba debe usar HTTPS.'}
if(-not$SourceUrl-and-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "No existe el archivo de prueba: $SourcePath"}
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration

$proxy=$null
try{
    if($SourceUrl){
        $proxy=Start-CocoMediaHttpProxy $SourceUrl ([IO.Path]::GetFileName(([Uri]$SourceUrl).AbsolutePath))
        $mediaUri=[Uri]::new([string]$proxy.Url)
    }else{$mediaUri=[Uri]::new([IO.Path]::GetFullPath($SourcePath))}
    $form=New-Object Windows.Forms.Form;$form.ClientSize=New-Object Drawing.Size(640,400)
    $videoHost=New-Object Windows.Forms.Integration.ElementHost;$videoHost.Dock='Fill'
    $media=New-Object System.Windows.Controls.MediaElement;$media.LoadedBehavior='Manual';$media.UnloadedBehavior='Manual';$media.Stretch='Uniform';$media.ScrubbingEnabled=$true
    $videoHost.Child=$media;$form.Controls.Add($videoHost)
    $script:CocoMediaProgressOpened=$false;$script:CocoMediaProgressDuration=0.0;$script:CocoMediaProgressPosition=0.0;$script:CocoMediaProgressFailure=''
    $media.Add_MediaOpened({$script:CocoMediaProgressOpened=$true;if($media.NaturalDuration.HasTimeSpan){$script:CocoMediaProgressDuration=$media.NaturalDuration.TimeSpan.TotalSeconds};$media.Play()})
    $media.Add_MediaFailed({param($sender,$eventArgs)$message=try{[string]$eventArgs.ErrorException.Message}catch{'desconocido'};$script:CocoMediaProgressFailure=$message})
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $startTimer=New-Object Windows.Forms.Timer;$startTimer.Interval=250
    $startTimer.Add_Tick({if($script:CocoMediaProgressOpened){$startTimer.Stop()}else{try{$media.Play()}catch{}}})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=250
    $timer.Add_Tick({
        if(($script:CocoMediaProgressOpened-and$watch.Elapsed.TotalSeconds-ge$HoldSeconds)-or$watch.Elapsed.TotalSeconds-ge$TimeoutSeconds){
            $script:CocoMediaProgressPosition=$media.Position.TotalSeconds;$form.Close()
        }
    })
    $form.Add_Shown({try{$media.Source=$mediaUri;$timer.Start();$startTimer.Start()}catch{$script:CocoMediaProgressFailure=$_.Exception.Message;$form.Close()}})
    try{[void]$form.ShowDialog()}finally{$timer.Stop();$startTimer.Stop();$timer.Dispose();$startTimer.Dispose();$media.Stop();$form.Dispose()}
    if($script:CocoMediaProgressFailure){throw "MediaElement fallo: $script:CocoMediaProgressFailure"}
    [pscustomobject]@{Source=if($SourceUrl){$SourceUrl}else{[IO.Path]::GetFullPath($SourcePath)};Opened=$script:CocoMediaProgressOpened;DurationSeconds=$script:CocoMediaProgressDuration;PositionSeconds=$script:CocoMediaProgressPosition}|ConvertTo-Json -Compress
    if(-not$script:CocoMediaProgressOpened){throw 'MediaElement no abrio la fuente.'}
    if($script:CocoMediaProgressPosition-le0){throw 'MediaElement abrio la fuente pero no avanzo la posicion.'}
    'PASS: MediaElement avanzo la posicion mientras reproducia.'
}finally{
    if($proxy){Stop-CocoMediaHttpProxy $proxy}
}
