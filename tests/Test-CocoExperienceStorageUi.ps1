[CmdletBinding()]
param([string]$EnginePath='')

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot -Parent
$engineFile=if([string]::IsNullOrWhiteSpace($EnginePath)){Join-Path $root 'engine\CocoLauncher.ps1'}else{[IO.Path]::GetFullPath($EnginePath)}
. $engineFile
function Test-CocoManagedGameRunning([string]$InstanceRoot,[string]$ExecutableName=''){return $false}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-storage-ui-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    $paths=Get-CocoLauncherPaths (Join-Path $root 'engine') $testRoot
    $installedRoot=Join-Path $paths.ExperiencesRoot 'installed'
    New-Item -ItemType Directory -Path $installedRoot -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $installedRoot 'data.bin'),'installed',(New-Object Text.UTF8Encoding($false)))
    $catalog=[pscustomobject]@{experiences=@(
        [pscustomobject]@{id='installed';instanceId='installed';name='Installed';managementMode='managed';launch=[pscustomobject]@{workflow='coco-managed'}},
        [pscustomobject]@{id='missing';instanceId='missing';name='Missing';managementMode='managed';launch=[pscustomobject]@{workflow='coco-managed'}}
    )}
    $promptExperience=$catalog.experiences[1]
    $promptForm=New-Object Windows.Forms.Form
    $promptForm.Size=New-Object Drawing.Size(200,100)
    $script:CocoForm=$promptForm
    $script:CocoPromptTicks=0
    $promptTimer=New-Object Windows.Forms.Timer
    $promptTimer.Interval=100
    $promptTimer.Add_Tick({
        $script:CocoPromptTicks++
        foreach($window in @([Windows.Forms.Application]::OpenForms)){
            $default=@($window.Controls|Where-Object{$_-is[Windows.Forms.Button]-and$_.Text-eq'INSTALAR EN RUTA POR DEFECTO'})[0]
            if($default){$default.PerformClick();return}
            if($script:CocoPromptTicks-gt50){$window.DialogResult=[Windows.Forms.DialogResult]::Cancel;$window.Close();return}
        }
    })
    $promptForm.Show()
    $promptTimer.Start()
    $promptResult=Prompt-CocoExperienceLocationChoice $promptExperience $paths.ExperiencesRoot $paths.InstanceLocationsPath
    $promptTimer.Stop();$promptTimer.Dispose();$promptForm.Close();$promptForm.Dispose();$script:CocoForm=$null
    if(-not$promptResult.Confirmed-or$promptResult.Choice-ne'default'){throw 'El modal no confirmo la ruta por defecto mediante su boton principal.'}
    $panel=New-Object Windows.Forms.Panel
    $panel.Size=New-Object Drawing.Size(570,340)
    Update-CocoExperienceCardsUi $panel $catalog $paths 'client'
    $cards=@($panel.Controls|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag})
    if($cards.Count-ne2){throw "La UI cliente creo $($cards.Count) tarjetas y se esperaban 2."}
    $missingCard=@($cards|Where-Object{$_.Tag.ExperienceId-eq'missing'})[0]
    $installedCard=@($cards|Where-Object{$_.Tag.ExperienceId-eq'installed'})[0]
    $missingButtons=@($missingCard.Controls|Where-Object{$_-is[Windows.Forms.Button]})
    $installedButtons=@($installedCard.Controls|Where-Object{$_-is[Windows.Forms.Button]})
    if($missingButtons.Count-ne2-or$installedButtons.Count-ne2){throw 'La UI cliente no conserva los dos botones de almacenamiento por tarjeta.'}
    $missingFree=@($missingButtons|Where-Object Text -eq 'LIBERAR ESPACIO')[0]
    $missingMove=@($missingButtons|Where-Object Text -eq 'INSTALAR')[0]
    $installedFree=@($installedButtons|Where-Object Text -eq 'LIBERAR ESPACIO')[0]
    if($missingFree.Enabled-or-not$missingMove.Enabled-or-not$installedFree.Enabled){throw 'Los estados de botones cliente no reflejan instalado/no instalado.'}
    if(([string]$missingCard.Controls[2].Text)-notmatch'No instalado'-or([string]$missingCard.Controls[2].Text)-notmatch'CLIC PARA INSTALAR'){throw 'La tarjeta no instalada no ofrece la indicacion de instalacion.'}

    $panel.Controls.Clear()
    Update-CocoExperienceCardsUi $panel $catalog $paths 'host'
    $hostCards=@($panel.Controls|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag})
    foreach($hostCard in $hostCards){
        $buttons=@($hostCard.Controls|Where-Object{$_-is[Windows.Forms.Button]})
        if($buttons.Count-ne3){throw 'La UI host no muestra ALOJAR, CARPETA y BORRAR en cada tarjeta.'}
    }
    $missingHost=@($hostCards|Where-Object{$_.Tag.ExperienceId-eq'missing'})[0]
    $missingDelete=@($missingHost.Controls|Where-Object{$_-is[Windows.Forms.Button]-and$_.Text-eq'BORRAR'})[0]
    if($missingDelete.Enabled){throw 'BORRAR debe estar deshabilitado para una instancia no instalada.'}
    $panel.Dispose()
    'PASS: tarjetas cliente/host, rutas, estados y botones de almacenamiento validados.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
