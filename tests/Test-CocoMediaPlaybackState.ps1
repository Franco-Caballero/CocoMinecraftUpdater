[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $root 'engine\CocoLauncher.ps1')

$folderName="coco-media-state-test-$([guid]::NewGuid().ToString('N'))"
$experience=[pscustomobject]@{
    id='heart-signal-state-test';runtime=[pscustomobject]@{type='media'}
    content=[pscustomobject]@{type='episodic-video';downloadFolderName=$folderName}
}
$episode=[pscustomobject]@{
    id='s01e01';title='Test';fileName='test.mp4';sourceUrl='';streamUrl='';size=[int64]123456
    sha256=('a'*64)
}
$downloadRoot=Get-CocoMediaDownloadRoot $experience
try{
    Write-CocoMediaPlaybackState $experience $episode 123.5 3600.0 $false
    $state=Get-CocoMediaPlaybackState $experience $episode
    if([Math]::Abs($state.PositionSeconds-123.5)-gt0.001-or[Math]::Abs($state.DurationSeconds-3600.0)-gt0.001-or$state.Completed){throw 'La posicion inicial no se persistio correctamente.'}
    Write-CocoMediaState $experience $episode
    $state=Get-CocoMediaPlaybackState $experience $episode
    if([Math]::Abs($state.PositionSeconds-123.5)-gt0.001-or[Math]::Abs($state.DurationSeconds-3600.0)-gt0.001){throw 'La verificacion del archivo borro la posicion persistida.'}
    Write-CocoMediaPlaybackState $experience $episode 3600.0 3600.0 $true
    $state=Get-CocoMediaPlaybackState $experience $episode
    if(-not$state.Completed-or[Math]::Abs($state.PositionSeconds-3600.0)-gt0.001){throw 'El estado finalizado no se persistio correctamente.'}
    [pscustomobject]@{PositionSeconds=$state.PositionSeconds;DurationSeconds=$state.DurationSeconds;Completed=$state.Completed}|ConvertTo-Json -Compress
    'PASS: la posicion y el estado finalizado sobreviven a la actualizacion de metadata.'
}finally{
    if((Split-Path -Leaf $downloadRoot)-like'coco-media-state-test-*'-and(Test-Path -LiteralPath $downloadRoot)){Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
