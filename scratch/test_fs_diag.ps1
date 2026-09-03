Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

$catalog = Get-Content 'launcher\catalog.template.json' -Raw | ConvertFrom-Json
$mediaExp = @($catalog.experiences | Where-Object { [string]$_.runtime.type -eq 'media' })[0]
$episode = $mediaExp.content.episodes[0]
$streamUrl = $episode.streamUrl

. .\engine\CocoLauncher.ps1

$events = [Collections.Generic.List[string]]::new()

$t = New-Object Windows.Forms.Timer
$t.Interval = 500
$step = 0
$t.Add_Tick({
    $openForms = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like '*HEART SIGNAL*' })
    if ($openForms.Count -eq 0) { return }
    $form = $openForms[0]
    $step++
    $events.Add("Step ${step} - WindowState=$($form.WindowState), Bounds=$($form.Bounds), Visible=$($form.Visible)")
    
    if ($step -eq 4) {
        $btn = @($form.Controls | Where-Object { $_.Name -eq 'CocoMediaControlPanel' } | ForEach-Object { $_.Controls } | Where-Object { $_.Name -eq 'CocoMediaFullscreenButton' })[0]
        $events.Add("Clicking Fullscreen button: text=$($btn.Text)")
        $btn.PerformClick()
    }
    if ($step -gt 4 -and $step -le 10) {
        $header = @($form.Controls | Where-Object { $_.Name -eq 'CocoMediaHeader' })[0]
        $footer = @($form.Controls | Where-Object { $_.Name -eq 'CocoMediaControlPanel' })[0]
        $events.Add("After click (step ${step}) - HeaderVisible=$($header.Visible), FooterVisible=$($footer.Visible), WindowState=$($form.WindowState), Bounds=$($form.Bounds)")
    }
    if ($step -eq 11) {
        $form.Close()
        $t.Stop()
    }
})

$t.Start()
try {
    Invoke-CocoMediaPlayerUi $mediaExp $episode $streamUrl
} finally {
    $t.Stop()
    $t.Dispose()
    foreach ($e in $events) {
        Write-Host $e
    }
}
