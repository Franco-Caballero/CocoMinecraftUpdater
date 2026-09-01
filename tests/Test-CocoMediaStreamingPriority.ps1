[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$template=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
$experience=$template.PSObject.Copy();$experience.content=$template.content.PSObject.Copy();$experience.content.downloadFolderName="coco-media-priority-$([Guid]::NewGuid().ToString('N'))"
$episode=@($template.content.episodes|Where-Object id -eq 's05e01-p01'|Select-Object -First 1)[0].PSObject.Copy()
$button=New-Object Windows.Forms.Button;$button.Enabled=$true
$statusLabel=New-Object Windows.Forms.Label
$dialog=New-Object Windows.Forms.Form;$dialog.Tag=[pscustomobject]@{Buttons=@($button)}
$row=[pscustomobject]@{Experience=$experience;Episode=$episode;Dialog=$dialog;Button=$button;StatusLabel=$statusLabel;Status=$null}
$script:CocoMediaPrioritySource='';$script:CocoMediaPriorityLocalPlayback=$false;$script:CocoMediaPriorityDownload=$false

function Get-CocoMediaEpisodeLocalStatus($Experience,$Episode){
    [pscustomobject]@{Status='verified';Path='C:\this-local-file-must-not-be-opened.mp4';Bytes=1837932680;ExpectedSize=1837932680;PartialBytes=0}
}
function Invoke-CocoMediaPlayerUi($Experience,$Episode,[string]$Source=''){$script:CocoMediaPrioritySource=$Source}
function Invoke-CocoMediaEpisodePlayback($Experience,$Episode){$script:CocoMediaPriorityLocalPlayback=$true}
function Invoke-CocoMediaHttpDownload($Experience,$Episode,[string]$Destination){$script:CocoMediaPriorityDownload=$true}
function Update-CocoMediaEpisodeRowUi($RowInfo){$RowInfo.Button.Text='VER EN COCO'}
function Set-CocoMediaUiStatus([string]$Text,[int]$Percent=0){}

try{
    $script:CocoMediaDownloadInProgress=$false
    Invoke-CocoMediaEpisodeAction $row
    if($script:CocoMediaPrioritySource-ne[string]$episode.streamUrl){throw "El selector no uso el streamUrl remoto; uso observado: '$script:CocoMediaPrioritySource'."}
    if($script:CocoMediaPriorityLocalPlayback){throw 'El selector abrio la copia local aunque existia streamUrl.'}
    if($script:CocoMediaPriorityDownload){throw 'El selector intento descargar antes de abrir el streaming.'}
    'PASS: un episodio con streamUrl siempre abre streaming aunque exista copia local verificada.'
}finally{
    if($dialog-and-not$dialog.IsDisposed){$dialog.Dispose()}
}
