[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba de accion del selector debe ejecutarse en STA.'}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$template=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
$experience=$template.PSObject.Copy();$experience.content=$template.content.PSObject.Copy();$experience.content.downloadFolderName="coco-media-action-$([Guid]::NewGuid().ToString('N'))"
$episode=@($template.content.episodes|Select-Object -First 1)[0].PSObject.Copy();$episode.streamUrl='https://example.invalid/heart-signal-test.mp4';$episode.sourceUrl='https://example.invalid/heart-signal-test.mp4';$experience.content.episodes=@($episode)
$script:CocoMediaDownloadInProgress=$false;$script:CocoMediaCancelRequested=$false;$script:CocoMediaPlayerCalled=$false;$script:CocoMediaPlayerSource=''
function Invoke-CocoMediaPlayerUi($Experience,$Episode,[string]$Source=''){$script:CocoMediaPlayerCalled=$true;$script:CocoMediaPlayerSource=$Source}
$actionInfo=@(Get-Command Invoke-CocoMediaEpisodeAction -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0]
$action=[System.Management.Automation.ScriptBlock]$actionInfo.ScriptBlock
$dialog=New-Object Windows.Forms.Form
$button=New-Object Windows.Forms.Button;$button.Enabled=$true
$dialog.Tag=[pscustomobject]@{Buttons=@($button)}
$rowInfo=[pscustomobject]@{Experience=$experience;Episode=$episode;Dialog=$dialog;Button=$button;StatusLabel=(New-Object Windows.Forms.Label);Status=$null}
try{
    & $action $rowInfo
    if(-not$script:CocoMediaPlayerCalled){throw 'FAIL: el clic del episodio no llego al reproductor.'}
    if($script:CocoMediaPlayerSource-ne$episode.streamUrl){throw 'FAIL: el clic no conservo la URL de streaming.'}
    if($script:CocoMediaDownloadInProgress){throw 'FAIL: la accion dejo el selector bloqueado.'}
    'PASS: la accion del selector invoco el streaming sin InvokeWithContext ni errores de tipo Object[].'
}finally{
    if($dialog-and-not$dialog.IsDisposed){$dialog.Dispose()}
    $script:CocoMediaDownloadInProgress=$false;$script:CocoMediaCancelRequested=$false
    $testRoot=Get-CocoMediaDownloadRoot $experience
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
