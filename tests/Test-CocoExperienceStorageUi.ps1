[CmdletBinding()]
param([string]$EnginePath='')

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot -Parent
$engineFile=if([string]::IsNullOrWhiteSpace($EnginePath)){Join-Path $root 'engine\CocoLauncher.ps1'}else{[IO.Path]::GetFullPath($EnginePath)}
. $engineFile
function Test-CocoManagedGameRunning([string]$InstanceRoot,[string]$ExecutableName=''){return $false}
function Get-TestDescendantButtons($Control){
    foreach($child in @($Control.Controls)){
        if($child-is[Windows.Forms.Button]){$child}
        if($child.Controls.Count-gt0){Get-TestDescendantButtons $child}
    }
}
function Get-TestDescendantControls($Control){
    foreach($child in @($Control.Controls)){
        $child
        if($child.Controls.Count-gt0){Get-TestDescendantControls $child}
    }
}

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
            $default=@(Get-TestDescendantButtons $window|Where-Object{$_.Text-eq'INSTALAR EN RUTA POR DEFECTO'})[0]
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
    $cards=@(Get-TestDescendantControls $panel|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag-and[string]$_.Name-eq'CocoExperienceCard'})
    if($cards.Count-ne2){throw "La UI cliente creo $($cards.Count) tarjetas y se esperaban 2."}
    $missingCard=@($cards|Where-Object{$_.Tag.ExperienceId-eq'missing'})[0]
    $installedCard=@($cards|Where-Object{$_.Tag.ExperienceId-eq'installed'})[0]
    $missingButtons=@(Get-TestDescendantButtons $missingCard)
    $installedButtons=@(Get-TestDescendantButtons $installedCard)
    if($missingButtons.Count-ne1-or$installedButtons.Count-ne3){throw "La UI cliente no conserva los botones de almacenamiento esperados. missing=$($missingButtons.Count) installed=$($installedButtons.Count)"}
    $missingFree=@($missingButtons|Where-Object{[string]$_.Text-in@('BORRAR','LIBERAR ESPACIO')})[0]
    $missingMove=@($missingButtons|Where-Object Text -eq 'INSTALAR')[0]
    $installedFree=@($installedButtons|Where-Object{[string]$_.Text-in@('BORRAR','LIBERAR ESPACIO')})[0]
    if($missingFree-or-not$missingMove.Enabled-or-not$installedFree.Enabled){throw 'Los estados de botones cliente no reflejan instalado/no instalado.'}
    $missingStatus=@($missingCard|ForEach-Object{Get-TestDescendantControls $_}|Where-Object{[string]$_.Text-match'NO INSTALADO'})[0]
    if(-not$missingStatus){throw 'La tarjeta no instalada no ofrece la indicacion de instalacion.'}

    $panel.Controls.Clear()
    Update-CocoExperienceCardsUi $panel $catalog $paths 'host'
    $hostCards=@(Get-TestDescendantControls $panel|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag-and[string]$_.Name-eq'CocoExperienceCard'})
    $installedHost=@($hostCards|Where-Object{$_.Tag.ExperienceId-eq'installed'})[0]
    $installedButtons=@(Get-TestDescendantButtons $installedHost)
    if($installedButtons.Count-ne3){throw 'La UI host no muestra ABRIR, CARPETA y BORRAR en la tarjeta instalada.'}
    $missingHost=@($hostCards|Where-Object{$_.Tag.ExperienceId-eq'missing'})[0]
    $missingButtons=@(Get-TestDescendantButtons $missingHost)
    if($missingButtons.Count-ne1-or$missingButtons[0].Text-ne'INSTALAR'){throw 'La UI host debe mostrar solo INSTALAR en una instancia no instalada.'}

    # Validacion de estado durante instalacion:
    # 1. La experiencia que se instala muestra INSTALANDO... (deshabilitado, en tono destacado)
    # 2. Otros juegos quedan con botones en gris y deshabilitados
    # 3. Contenido multimedia (peliculas/series) permanece completamente habilitado y accesible
    $catalogWithMedia=[pscustomobject]@{experiences=@(
        $catalog.experiences[0],
        $catalog.experiences[1],
        [pscustomobject]@{
            id='test-movie';name='Test Movie';managementMode='managed'
            runtime=[pscustomobject]@{type='media'}
            content=[pscustomobject]@{type='movie';downloadFolderName='test-movie';movie=[pscustomobject]@{id='m1';title='Test Movie';fileName='test.mp4';sourceUrl='https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.5.0/test.mp4';streamUrl='https://example.com/stream.mp4'}}
            launch=[pscustomobject]@{workflow='coco-media'}
        }
    )}
    $script:CocoStorageInstallInProgress=$true
    $script:CocoInstallingExperienceId='missing'
    $script:CocoInstallingExperienceName='Missing Game'
    try{
        $panel.Controls.Clear()
        Update-CocoExperienceCardsUi $panel $catalogWithMedia $paths 'client'
        $installingCards=@(Get-TestDescendantControls $panel|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag-and[string]$_.Name-eq'CocoExperienceCard'})
        $instCard=@($installingCards|Where-Object{$_.Tag.ExperienceId-eq'missing'})[0]
        $instBtn=@(Get-TestDescendantButtons $instCard)
        if($instBtn.Count-ne1-or$instBtn[0].Text-ne'INSTALANDO...'-or$instBtn[0].Enabled){throw "La tarjeta que se instala debe mostrar 'INSTALANDO...' deshabilitado."}
        $instStatus=@($instCard|ForEach-Object{Get-TestDescendantControls $_}|Where-Object{[string]$_.Text-match'INSTALANDO ARCHIVOS'})[0]
        if(-not$instStatus){throw 'La tarjeta que se instala debe mostrar la indicacion de instalacion de archivos.'}

        $otherGameCard=@($installingCards|Where-Object{$_.Tag.ExperienceId-eq'installed'})[0]
        $otherGameBtns=@(Get-TestDescendantButtons $otherGameCard)
        if($otherGameBtns.Count-ne3){throw 'Otro juego instalado debe conservar sus 3 botones.'}
        foreach($btn in $otherGameBtns){
            if($btn.Enabled){throw "El boton '$($btn.Text)' de otro juego debe estar deshabilitado durante la instalacion."}
            if($btn.BackColor -ne [Drawing.Color]::FromArgb(44,36,50)){throw "El boton '$($btn.Text)' debe tener color de fondo gris (44,36,50)."}
        }

        $mediaCard=@($installingCards|Where-Object{$_.Tag.ExperienceId-eq'test-movie'})[0]
        $mediaBtns=@(Get-TestDescendantButtons $mediaCard)
        if($mediaBtns.Count-ne1-or$mediaBtns[0].Text-ne'VER PELICULA'-or-not$mediaBtns[0].Enabled){throw 'El contenido multimedia debe permanecer habilitado (VER PELICULA) durante la instalacion.'}

        # Comprobar tambien en modo Host
        $panel.Controls.Clear()
        Update-CocoExperienceCardsUi $panel $catalogWithMedia $paths 'host'
        $hostInstallingCards=@(Get-TestDescendantControls $panel|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag-and[string]$_.Name-eq'CocoExperienceCard'})
        $hostOtherCard=@($hostInstallingCards|Where-Object{$_.Tag.ExperienceId-eq'installed'})[0]
        $hostOtherBtns=@(Get-TestDescendantButtons $hostOtherCard)
        foreach($btn in $hostOtherBtns){
            if($btn.Enabled){throw "En modo host, el boton '$($btn.Text)' de otro juego debe estar deshabilitado durante la instalacion."}
        }
        $hostMediaCard=@($hostInstallingCards|Where-Object{$_.Tag.ExperienceId-eq'test-movie'})[0]
        $hostMediaBtns=@(Get-TestDescendantButtons $hostMediaCard)
        if($hostMediaBtns.Count-ne1-or-not$hostMediaBtns[0].Enabled){throw 'En modo host, el contenido multimedia debe permanecer habilitado.'}
    }finally{
        $script:CocoStorageInstallInProgress=$false
        $script:CocoInstallingExperienceId=''
        $script:CocoInstallingExperienceName=''
    }

    # Al finalizar la instalacion, los botones vuelven a su estado normal
    $panel.Controls.Clear()
    Update-CocoExperienceCardsUi $panel $catalogWithMedia $paths 'client'
    $restoredCards=@(Get-TestDescendantControls $panel|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Tag-and[string]$_.Name-eq'CocoExperienceCard'})
    $restoredMissing=@($restoredCards|Where-Object{$_.Tag.ExperienceId-eq'missing'})[0]
    $restoredMissingBtn=@(Get-TestDescendantButtons $restoredMissing)[0]
    if($restoredMissingBtn.Text-ne'INSTALAR'-or-not$restoredMissingBtn.Enabled){throw 'Tras la instalacion, el boton de instalacion debe volver a INSTALAR habilitado.'}

    $panel.Dispose()
    'PASS: tarjetas cliente/host, rutas, estados, botones de almacenamiento y modo instalando con multimedia validados.'
}finally{
    if($panel-and-not$panel.IsDisposed){$panel.Dispose()}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
