[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'La prueba de callbacks debe ejecutarse en STA.'}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

function Get-CocoCallbackTestControls($Control){
    foreach($child in @($Control.Controls)){
        $child
        if($child.Controls.Count-gt0){Get-CocoCallbackTestControls $child}
    }
}

$tempRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-launcher-callbacks-$([guid]::NewGuid().ToString('N'))"
$paths=@{ExperiencesRoot=$tempRoot;InstanceLocationsPath=(Join-Path $tempRoot 'instance-locations.json')}
$experience=[pscustomobject]@{
    id='callback-exp';instanceId='callback-exp';name='Callback Test';description='Prueba de acciones WinForms'
    managementMode='managed';runtime=[pscustomobject]@{type='minecraft'}
    launch=[pscustomobject]@{workflow='coco-managed'}
}
$catalog=[pscustomobject]@{experiences=@($experience)}
$panel=New-Object Windows.Forms.Panel;$panel.Size=[Drawing.Size]::new(840,620)
$script:CocoCallbackFolderReached=$false
$script:CocoCallbackInstallReached=$false
$script:CocoCallbackFreeSpaceReached=$false

function Invoke-CocoExperienceChangeLocationUi($Info){$script:CocoCallbackFolderReached=$true}
function Invoke-CocoExperienceStorageInstallUi($Info){$script:CocoCallbackInstallReached=$true}
function Invoke-CocoExperienceFreeSpaceUi($Info){$script:CocoCallbackFreeSpaceReached=$true}
function Invoke-CocoMediaOpenFolderUi($Experience){$script:CocoCallbackFolderReached=$true}
function Invoke-CocoMediaEpisodeUi($Experience){}

try{
    Update-CocoExperienceCardsUi $panel $catalog $paths 'host'
    $folderButton=@(Get-CocoCallbackTestControls $panel|Where-Object{$_-is[Windows.Forms.Button]-and[string]$_.Text-eq'CARPETA'}|Select-Object -First 1)[0]
    if(-not$folderButton){throw 'FAIL: no se genero el boton CARPETA.'}
    Remove-Item Function:\Invoke-CocoExperienceChangeLocationUi -Force
    $folderButton.PerformClick()
    if(-not$script:CocoCallbackFolderReached){throw 'FAIL: CARPETA aun depende del nombre de una funcion que desaparece fuera del alcance del launcher.'}

    $form=New-Object Windows.Forms.Form;$form.ClientSize=[Drawing.Size]::new(300,160)
    $identityCard=New-Object Windows.Forms.Panel;$identityCard.Size=[Drawing.Size]::new(200,80);$identityCard.Visible=$false
    $identityText=New-Object Windows.Forms.TextBox;$identityText.Text='Player';$form.Controls.Add($identityCard);$form.Controls.Add($identityText)
    $script:CocoForm=$form;$form.Show();[Windows.Forms.Application]::DoEvents()
    Invoke-CocoLauncherIdentityButton $identityCard $identityText
    if(-not$identityCard.Visible){throw 'FAIL: JUGADOR no pudo abrir el popup de identidad.'}
    Invoke-CocoLauncherIdentityButton $identityCard $identityText
    if($identityCard.Visible){throw 'FAIL: JUGADOR no pudo cerrar el popup de identidad.'}
    $identityCard.Dispose();Invoke-CocoLauncherIdentityButton $identityCard $identityText
    $form.Close();$form.Dispose();$script:CocoForm=$null
    'PASS: CARPETA y JUGADOR sobreviven a callbacks WinForms sin resolucion dinamica ni expresiones NULL.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Close();$script:CocoForm.Dispose()}
    $script:CocoForm=$null
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
