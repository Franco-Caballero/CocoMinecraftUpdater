[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root=Split-Path $PSScriptRoot -Parent
$script:CocoEngineRoot=$root
. (Join-Path $root 'engine\CocoLauncher.ps1')
function Get-LayoutDescendantControls($Control){
    foreach($child in @($Control.Controls)){
        $child
        if($child.Controls.Count-gt0){Get-LayoutDescendantControls $child}
    }
}

# Simula una escala reducida para comprobar la grilla de dos columnas.
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
$baseIdentityPopup=New-Object Windows.Forms.Panel
$baseIdentityPopup.Name='CocoIdentityPopup'
$baseIdentityButton=New-Object Windows.Forms.Button
$baseIdentityButton.Name='CocoLauncherIdentityButton'
$baseMinimize=New-Object Windows.Forms.Button
$baseMinimize.Name='CocoLauncherMinimizeButton'
$baseClose=New-Object Windows.Forms.Button
$baseClose.Name='CocoLauncherCloseButton'
$baseForm.Controls.Add($basePanel)
$basePanel.Controls.AddRange(@($baseTitle,$baseDetail,$baseTrack,$baseBrand,$baseDynamic,$baseIdentityPopup,$baseIdentityButton,$baseMinimize,$baseClose))
$script:CocoForm=$baseForm;$script:CocoPanel=$basePanel
$script:CocoAccent=$basePanel.Controls[0];$script:CocoTitle=$baseTitle;$script:CocoDetail=$baseDetail
$script:CocoTrack=$baseTrack;$script:CocoProgress=$baseProgress;$script:CocoBrand=$baseBrand
$script:CocoSkinTile=$baseIdentityPopup;$script:CocoIdentityButton=$baseIdentityButton
$script:CocoLauncherMinimizeButton=$baseMinimize;$script:CocoLauncherCloseButton=$baseClose
Set-CocoLauncherUiLayout
$panel=New-Object Windows.Forms.Panel
$basePanel.Controls.Add($panel)
$panel.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 840),(Get-CocoLauncherUiMetric 570))
$installedRoot=Join-Path $tempRoot 'layout-exp-1'
New-Item -ItemType Directory -Path $installedRoot -Force|Out-Null
Set-Content -LiteralPath (Join-Path $installedRoot 'installed.marker') -Value 'installed' -Encoding UTF8

try{
    $layout=$script:CocoLauncherLayout
    if(-not$layout-or$layout.PanelWidth-ne900-or$layout.PanelHeight-ne870-or$layout.DynamicTop-ne190-or$layout.DynamicWidth-ne840-or$layout.DynamicHeight-ne660-or$layout.IdentityTop-ne-1-or$layout.FooterTop-ne-1){throw 'FAIL: el layout base no conserva la vista vertical ampliada.'}
    $dynamicTop=Get-CocoLauncherUiMetric 190
    $dynamicBottom=$dynamicTop+(Get-CocoLauncherUiMetric 660)
    $panelHeight=Get-CocoLauncherUiMetric 870
    if($dynamicBottom-gt$panelHeight){throw 'FAIL: el layout base deja la vista dinamica fuera del panel.'}
    if($baseDynamic.Location.Y-ne$dynamicTop-or$baseDynamic.Width-ne(Get-CocoLauncherUiMetric 840)-or$baseDynamic.Height-ne(Get-CocoLauncherUiMetric 660)){throw 'FAIL: la zona dinamica no se recoloca con la altura ampliada.'}
    if($baseIdentityPopup.Location.X-ne(Get-CocoLauncherUiMetric 500)-or$baseIdentityPopup.Location.Y-ne(Get-CocoLauncherUiMetric 34)-or$baseIdentityPopup.Height-ne(Get-CocoLauncherUiMetric 92)){throw 'FAIL: el popup de identidad no queda en la cabecera.'}
    if($baseIdentityButton.Location.X-ne(Get-CocoLauncherUiMetric 742)-or$baseIdentityButton.Location.Y-ne(Get-CocoLauncherUiMetric 2)-or$baseIdentityButton.Width-ne(Get-CocoLauncherUiMetric 74)){throw 'FAIL: el boton JUGADOR no queda junto a los controles de ventana.'}
    if($baseMinimize.Location.X-ne(Get-CocoLauncherUiMetric 820)-or$baseClose.Location.X-ne(Get-CocoLauncherUiMetric 858)){throw 'FAIL: los controles minimizar/cerrar no quedan en la cabecera.'}

    foreach($role in 'host','client'){
        Update-CocoExperienceCardsUi $panel $catalog $paths $role
        $cards=@(Get-LayoutDescendantControls $panel|Where-Object{$_ -is [Windows.Forms.Panel]-and[string]$_.Name-eq'CocoExperienceCard'})
        if($cards.Count-ne7){throw "FAIL: $role debe mostrar las 7 tarjetas, encontro $($cards.Count)."}
        $content=@($panel.Controls|Where-Object{[string]$_.Name-eq'CocoExperienceCardsContent'}|Select-Object -First 1)[0]
        if(-not$content){throw "FAIL: $role no agrupa las tarjetas en una superficie de desplazamiento unica."}
        $scrollState=Get-CocoExperienceCardsScrollState $panel
        if(-not$scrollState-or$scrollState.Items.Count-ne1-or$scrollState.Items[0].Control-ne$content){throw "FAIL: $role aun reposiciona tarjetas individuales durante el scroll."}
        $badCards=@($cards|Where-Object{$_.Width-le0-or$_.Height-ne$_.Width-or$_.Location.X-lt0-or$_.Location.Y-lt0})
        if($badCards.Count){throw "FAIL: $role genero tarjetas fuera de escala."}
        if($cards[0].Location.X-eq$cards[1].Location.X-or$cards[0].Location.Y-ne$cards[1].Location.Y){throw "FAIL: $role no genero dos columnas."}
        for($first=0;$first-lt$cards.Count;$first++){
            for($second=$first+1;$second-lt$cards.Count;$second++){
                if($cards[$first].Bounds.IntersectsWith($cards[$second].Bounds)){throw "FAIL: $role genero tarjetas superpuestas."}
            }
        }
        if($panel.AutoScrollMinSize.Height-le$panel.ClientSize.Height){throw "FAIL: $role no conserva un scroll vertical util."}
        $customScroll=@($basePanel.Controls|Where-Object{$_.Name-eq'CocoLauncherScrollBar'}|Select-Object -First 1)[0]
        if($customScroll){throw "FAIL: $role conserva una barra superpuesta; el scroll debe tener un solo riel nativo."}
        if(-not$panel.AutoScroll){throw "FAIL: $role no delega el clipping y el arrastre al viewport nativo."}
        if(-not$scrollState-or[int]$scrollState.ModelVersion-ne4){throw "FAIL: $role no usa el modelo nativo V4 del scroll."}
        if($scrollState.Items.Count-ne1-or$scrollState.Items[0].Control-ne$content){throw "FAIL: $role no conserva una unica superficie desplazable."}
        if($scrollState.Maximum-gt0){
            $before=[int]$panel.VerticalScroll.Value
            Set-CocoExperienceCardsScrollOffset $panel ([int]$scrollState.Maximum)
            $after=[int]$panel.VerticalScroll.Value
            if($after-le$before){throw "FAIL: $role no mueve el viewport nativo al cambiar el offset."}
            Set-CocoExperienceCardsScrollOffset $panel 0
        }
        $maximum=[Math]::Max(0,[int]$panel.VerticalScroll.Maximum-[int]$panel.VerticalScroll.LargeChange+1)
        if($maximum-lt0-or$panel.VerticalScroll.Value-lt0-or$panel.VerticalScroll.Value-gt$maximum){throw "FAIL: $role dejo el scroll fuera de limites."}
        if($panel.VerticalScroll.Value-ne0){throw "FAIL: $role no reinicia la lista en la primera fila."}
        if($role-eq'client'){
            $cardTextControls=@($cards|ForEach-Object{$_.Controls}|ForEach-Object{$_.Controls}|ForEach-Object{$_.Controls})
            $forbiddenLabels=@($cardTextControls|Where-Object{[string]$_.Text-match'JUEGO COOPERATIVO|ONLINE FIX'})
            if($forbiddenLabels.Count){throw 'FAIL: las tarjetas aun muestran categorias de cooperativo u online fix.'}
            $deleteButtons=@($cardTextControls|Where-Object{[string]$_.Text-eq'LIBERAR ESPACIO'})
            if($deleteButtons.Count-ne1){throw 'FAIL: cliente muestra liberar espacio en tarjetas no instaladas o no lo muestra en la instalada.'}
            if($deleteButtons[0].Width-lt(Get-CocoLauncherUiMetric 100)-or$deleteButtons[0].Text-ne'LIBERAR ESPACIO'){throw 'FAIL: el boton Liberar espacio no tiene ancho suficiente.'}
            $installedCard=$cards[0]
            $image=@($installedCard.Controls|Where-Object{$_.Name-eq'CocoExperienceImage'})[0]
            if(-not$image-or$image.Width-ne$installedCard.Width-or$image.Height-ne$installedCard.Height){throw 'FAIL: las portadas no ocupan la tarjeta completa.'}
            $textAnchor=@($image.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text-eq'Experience 1'})[0]
            $firstAction=@($image.Controls|ForEach-Object{$_.Controls}|Where-Object{$_.Text-eq'CAMBIAR CARPETA'})[0]
            if(-not$textAnchor-or-not$firstAction-or$firstAction.Location.X-le$textAnchor.Location.X-or$firstAction.Location.X+($firstAction.Width)-gt$installedCard.Width){throw 'FAIL: las acciones compactas no quedan alineadas dentro de la tarjeta.'}
            $installButtons=@($cardTextControls|Where-Object{[string]$_.Text-eq'INSTALAR'})
            if($installButtons.Count-ne6-or($installButtons|Where-Object{$_.Width-lt(Get-CocoLauncherUiMetric 100)}).Count){throw 'FAIL: las tarjetas no conservan un CTA INSTALAR legible.'}
        }
    }

    'PASS: layout host/cliente escalado, scroll, estado, identidad y selector de skin caben sin solaparse.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if($baseForm-and-not$baseForm.IsDisposed){$baseForm.Dispose()}
    $script:CocoForm=$null;$script:CocoPanel=$null;$script:CocoAccent=$null;$script:CocoTitle=$null;$script:CocoDetail=$null
    $script:CocoTrack=$null;$script:CocoProgress=$null;$script:CocoBrand=$null;$script:CocoSkinTile=$null
    $script:CocoIdentityButton=$null;$script:CocoLauncherMinimizeButton=$null;$script:CocoLauncherCloseButton=$null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
