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
$panel=New-Object Windows.Forms.Panel
$panel.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 570),(Get-CocoLauncherUiMetric 340))

try{
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

    $panelHeight=Get-CocoLauncherUiMetric 600
    $dynamicBottom=(Get-CocoLauncherUiMetric 146)+(Get-CocoLauncherUiMetric 340)
    $identityTop=Get-CocoLauncherUiMetric 498
    $footerBottom=(Get-CocoLauncherUiMetric 542)+(Get-CocoLauncherUiMetric 44)
    if($dynamicBottom-ge$identityTop-or$identityTop-ge$panelHeight-or$footerBottom-gt$panelHeight){throw 'FAIL: el layout escalado deja zonas fuera de la ventana.'}
    'PASS: layout host/cliente escalado, scroll, identidad y selector de skin caben sin solaparse.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
