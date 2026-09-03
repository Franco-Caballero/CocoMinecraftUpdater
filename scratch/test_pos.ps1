Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

$catalog = Get-Content 'launcher\catalog.template.json' -Raw | ConvertFrom-Json
$mediaExp = @($catalog.experiences | Where-Object { [string]$_.runtime.type -eq 'media' })[0]
$episode = $mediaExp.content.episodes[0]
$streamUrl = $episode.streamUrl

. .\engine\CocoLauncher.ps1

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$step = 0
$timer.Add_Tick({
    $window = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like '*HEART SIGNAL*' } | Select-Object -First 1)[0]
    if (-not $window) { return }
    $videoHost = @($window.Controls | Where-Object { $_ -is [Windows.Forms.Integration.ElementHost] })[0]
    $media = $videoHost.Child
    $step++
    Write-Host "Step ${step}: pos=$($media.Position.TotalSeconds), bounds=$($window.Bounds)"
    if ($step -eq 6) {
        Write-Host "Toggling fullscreen..."
        $toggle = [scriptblock]$window.Tag.ToggleFullscreen
        & $toggle
        Write-Host "After toggle: pos=$($media.Position.TotalSeconds)"
    }
    if ($step -eq 9) {
        Write-Host "Toggling exit fullscreen..."
        $toggle = [scriptblock]$window.Tag.ToggleFullscreen
        & $toggle
        Write-Host "After exit: pos=$($media.Position.TotalSeconds)"
    }
    if ($step -eq 12) {
        $window.Close()
        $timer.Stop()
    }
})
$timer.Start()
Invoke-CocoMediaPlayerUi $mediaExp $episode $streamUrl
