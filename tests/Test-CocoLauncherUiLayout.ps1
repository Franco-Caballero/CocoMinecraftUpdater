[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

# Simula la escala que usa Show-CocoWindow en una pantalla con poca altura.
$script:CocoUiScale=0.8
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-layout-test-$([guid]::NewGuid().ToString('N'))"
$paths=@{ExperiencesRoot=$tempRoot;InstanceLocationsPath=(Join-Path $tempRoot 'instance-locations.json')}
$experiences=@(1..7|ForEach-Object{
    $id='layout-exp-{0}'-f$_
    [pscustomobject]@{
        id=$id;instanceId=$id;name="Experience $_";managementMode='managed'
        launch=[pscustomobject]@{workflow='coco-managed'}
    }
})
$catalog=[pscustomobject]@{experiences=$experiences}
$baseForm=New-Object Windows.Forms.Form
$basePanel=New-Object Windows.Forms.Panel
$basePanel.Controls.Add((New-Object Windows.Forms.Panel))
$basePanel.Controls[0].Tag='CocoLauncherAccent'
$baseTitle=New-Object Windows.Forms.Label
$baseDetail=New-Object Windows.Forms.Label
$baseTrack=New-Object Windows.Forms.Panel
$baseProgress=New-Object Windows.Forms.Panel
$baseTrack.Controls.Add($baseProgress)
$baseBrand=New-Object Windows.Forms.Label
$baseDynamic=New-Object Windows.Forms.Panel
$baseDynamic.Tag='CocoLauncherDynamic'
$baseForm.Controls.Add($basePanel)
$basePanel.Controls.AddRange(@($baseTitle,$baseDetail,$baseTrack,$baseBrand,$baseDynamic))
$script:CocoForm=$baseForm;$script:CocoPanel=$basePanel
$script:CocoAccent=$basePanel.Controls[0];$script:CocoTitle=$baseTitle;$script:CocoDetail=$baseDetail
$script:CocoTrack=$baseTrack;$script:CocoProgress=$baseProgress;$script:CocoBrand=$baseBrand
Set-CocoLauncherUiLayout
$panel=New-Object Windows.Forms.Panel
$panel.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 570),(Get-CocoLauncherUiMetric 340))

try{
    $layout=$script:CocoLauncherLayout
    if(-not$layout-or$layout.PanelHeight-ne790-or$layout.DynamicTop-ne184-or$layout.DynamicHeight-ne480-or$layout.IdentityTop-ne680-or$layout.FooterTop-ne720){throw 'FAIL: el layout base no conserva las zonas verticales nuevas.'}
    $stateBottom=Get-CocoLauncherUiMetric 171
    $dynamicTop=Get-CocoLauncherUiMetric 184
    $dynamicBottom=$dynamicTop+(Get-CocoLauncherUiMetric 480)
    $identityTop=Get-CocoLauncherUiMetric 680
    $identityBottom=$identityTop+(Get-CocoLauncherUiMetric 80)
    $footerTop=Get-CocoLauncherUiMetric 720
    $footerBottom=$footerTop+(Get-CocoLauncherUiMetric 40)
    $panelHeight=Get-CocoLauncherUiMetric 790
    if($stateBottom-ge$dynamicTop-or$dynamicBottom-ge$identityTop-or$identityBottom-gt$panelHeight-or$footerBottom-gt$panelHeight){throw 'FAIL: el layout base deja regiones superpuestas o fuera del panel.'}
    if($baseDynamic.Location.Y-ne$dynamicTop-or$baseDynamic.Height-ne(Get-CocoLauncherUiMetric 480)){throw 'FAIL: la zona dinamica no se recoloca con el layout base.'}

    foreach($role in 'host','client'){
        Update-CocoExperienceCardsUi $panel $catalog $paths $role
        $cards=@($panel.Controls|Where-Object{$_ -is [Windows.Forms.Panel]})
        if($cards.Count-ne7){throw "FAIL: $role debe mostrar las 7 tarjetas, encontro $($cards.Count)."}
        $badCards=@($cards|Where-Object{
            $_.Width-ne(Get-CocoLauncherUiMetric 545)-or
            $_.Height-ne(Get-CocoLauncherUiMetric 64)-or
            $_.Location.X-lt0-or$_.Location.Y-lt0
        })
        if($badCards.Count){throw "FAIL: $role genero tarjetas fuera de escala."}
        if($panel.AutoScrollMinSize.Height-ne(Get-CocoLauncherUiMetric (7*70+22))){throw "FAIL: $role no conserva el scroll de la lista."}
    }

    'PASS: layout host/cliente escalado, scroll, estado, identidad y selector de skin caben sin solaparse.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if($baseForm-and-not$baseForm.IsDisposed){$baseForm.Dispose()}
    $script:CocoForm=$null;$script:CocoPanel=$null;$script:CocoAccent=$null;$script:CocoTitle=$null;$script:CocoDetail=$null
    $script:CocoTrack=$null;$script:CocoProgress=$null;$script:CocoBrand=$null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
