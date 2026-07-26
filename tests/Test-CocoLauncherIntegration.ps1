[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $env:TEMP "coco-launcher-integration-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    $launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
    . ([ScriptBlock]::Create($launcherText))
    $catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
    $original=@($catalog.experiences|Where-Object id -eq 'coco-original'|Select-Object -First 1)[0]
    $iron=@($catalog.experiences|Where-Object id -eq 'into-the-backrooms'|Select-Object -First 1)[0]

    $externalRejected=$false
    try{[void](Start-CocoLauncherExperience $catalog $original ([pscustomobject]@{mode='offline';username='Audit';uuid=''}) client ([pscustomobject]@{}) $testRoot)}catch{$externalRejected=$_.Exception.Message-match'launcher habitual'}
    if(-not$externalRejected){throw 'Coco Launcher aun puede abrir Coco original por PortableMC.'}

    $legacy=Join-Path $testRoot 'legacy';New-Item -ItemType Directory -Path $legacy -Force|Out-Null
    if((Get-CocoLauncherRole $legacy)-ne'client'){throw 'Un equipo sin marcador host no fue clasificado como cliente.'}
    New-Item -ItemType Directory -Path (Join-Path $legacy 'config') -Force|Out-Null
    '{}'|Set-Content -LiteralPath (Join-Path $legacy 'config\coco-host.json') -Encoding UTF8
    if((Get-CocoLauncherRole $legacy)-ne'host'){throw 'El marcador host existente no fue respetado.'}

    $instance=Join-Path $testRoot 'experiences\into-the-backrooms';$world=Join-Path $instance 'saves\audit-world'
    New-Item -ItemType Directory -Path $world -Force|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $world 'level.dat'),[byte[]](1,2,3))
    '{"port":12345,"online-mode":false,"enable-upnp":false,"enable-uuid-fixer":true}'|Set-Content -LiteralPath (Join-Path $world 'mcwifipnp.json') -Encoding UTF8
    if(Test-CocoManagedLanWorldConfigurations $instance $iron){throw 'El validador acepto los nombres kebab-case que MCWiFiPnP ignora.'}
    if((Set-CocoManagedLanWorldConfigurations $instance $iron)-ne1){throw 'No se reparo la configuracion LAN del mundo administrado.'}
    $lan=Get-Content -LiteralPath (Join-Path $world 'mcwifipnp.json') -Raw|ConvertFrom-Json
    if([int]$lan.port-ne25565-or[bool]$lan.OnlineMode-or[bool]$lan.UseUPnP-or-not[bool]$lan.EnableUUIDFixer){
        throw 'La configuracion LAN administrada no fija puerto/offline/UUID Fixer/UPnP.'
    }
    if(-not(Test-CocoManagedLanWorldConfigurations $instance $iron)){throw 'La configuracion oficial de MCWiFiPnP no fue reconocida.'}
    if((Set-CocoManagedLanWorldConfigurations $instance $iron)-ne0){throw 'Una configuracion LAN ya correcta fue reescrita sin necesidad.'}
    "key_key.sprint:key.keyboard.r`nkey_key.sneak:key.keyboard.c`nfov:0.0`nresourcePacks:[]" |
        Set-Content -LiteralPath (Join-Path $instance 'options.txt') -Encoding UTF8
    Set-CocoManagedInstancePreferences $iron $instance
    $options=Get-Content -LiteralPath (Join-Path $instance 'options.txt') -Raw
    if($options-notmatch'key_key\.sprint:key\.keyboard\.left\.control'-or$options-notmatch'key_key\.sneak:key\.keyboard\.left\.shift'-or$options-notmatch'(?m)^fov:0\.625$'){
        throw 'Las preferencias declarativas de Backrooms no se aplicaron.'
    }
    if($options-match'Tissous'-or(Test-Path (Join-Path $instance 'optionsof.txt'))-or(Test-Path (Join-Path $instance 'CustomSkinLoader\skins\smolbird.png'))){
        throw 'Backrooms recibio preferencias privadas o pertenecientes a otro pack.'
    }
    if(Test-Path (Join-Path $instance 'optionsshaders.txt')){
        throw 'Coco genero optionsshaders.txt en una instalacion limpia aunque Backrooms no declara un shaderpack externo.'
    }
    $managedExperience=(($iron|ConvertTo-Json -Depth 20)|ConvertFrom-Json)
    $managedExperience.preferences | Add-Member -NotePropertyName managedFiles -NotePropertyValue @(
        [pscustomobject]@{path='config/coco-audit.toml';content="enabled=true`nvalue=7`n"}
    ) -Force
    Set-CocoManagedInstancePreferences $managedExperience $instance
    if([IO.File]::ReadAllText((Join-Path $instance 'config\coco-audit.toml'))-cne"enabled=true`nvalue=7`n"){
        throw 'Una configuracion declarativa especifica de experiencia no se aplico exactamente.'
    }
    if(-not(Write-CocoManagedServerList $instance $iron)){throw 'No se creo la recuperacion servers.dat inicial.'}
    $serverBytes=[IO.File]::ReadAllBytes((Join-Path $instance 'servers.dat'))
    $input=[IO.MemoryStream]::new($serverBytes);$reader=[IO.BinaryReader]::new($input,(New-Object Text.UTF8Encoding($false)),$true)
    $readU16={([int]$reader.ReadByte()-shl8)-bor[int]$reader.ReadByte()}
    $readI32={([int]$reader.ReadByte()-shl24)-bor([int]$reader.ReadByte()-shl16)-bor([int]$reader.ReadByte()-shl8)-bor[int]$reader.ReadByte()}
    $readString={param()$length=&$readU16;[Text.Encoding]::UTF8.GetString($reader.ReadBytes($length))}
    try{
        if($reader.ReadByte()-ne10-or(& $readString)-ne''){throw 'servers.dat no comienza con un compound NBT sin compresion.'}
        if($reader.ReadByte()-ne9-or(& $readString)-ne'servers'-or$reader.ReadByte()-ne10-or(& $readI32)-ne1){throw 'servers.dat no declara una lista de un servidor.'}
        $fields=@{}
        while(($tag=$reader.ReadByte())-ne0){
            $key=&$readString
            if($tag-eq8){$fields[$key]=&$readString}elseif($tag-eq1){$fields[$key]=$reader.ReadByte()}else{throw "Tag NBT inesperado en servers.dat: $tag"}
        }
        if($reader.ReadByte()-ne0-or$input.Position-ne$input.Length){throw 'servers.dat no termina exactamente al cerrar el compound raiz.'}
    }finally{$reader.Dispose();$input.Dispose()}
    if($fields.name-ne'Coco - Backrooms'-or$fields.ip-ne'10.77.37.1:25565'-or[int]$fields.hidden-ne0){throw 'servers.dat no contiene la experiencia y endpoint fijados.'}
    $serverHash=(Get-FileHash (Join-Path $instance 'servers.dat') -Algorithm SHA256).Hash
    if((Write-CocoManagedServerList $instance $iron)-or(Get-FileHash (Join-Path $instance 'servers.dat') -Algorithm SHA256).Hash-ne$serverHash){throw 'Coco reemplazo una lista de servidores ya existente.'}

    $output=Join-Path $testRoot 'engine';New-Item -ItemType Directory -Path $output -Force|Out-Null
    $build=& (Join-Path $root 'tools\New-CocoEngine.ps1') -Version '9.8.7' -OutputDirectory $output|ConvertFrom-Json
    $expanded=Join-Path $testRoot 'expanded';Expand-Archive -LiteralPath $build.path -DestinationPath $expanded
    $packaged=Read-CocoLauncherCatalog (Join-Path $expanded 'launcher\catalog.json')
    $packagedOriginal=@($packaged.experiences|Where-Object id -eq 'coco-original'|Select-Object -First 1)[0]
    if($packagedOriginal.pack.version-ne'9.8.7'){throw 'El engine no vinculo catalogo y version publicada.'}
    foreach($required in 'CocoLauncher.ps1','CocoSessionService.ps1','launcher\experiences\into-the-backrooms.lock.json','assets\skins\smolbird.png'){
        if(-not(Test-Path -LiteralPath (Join-Path $expanded $required) -PathType Leaf)){throw "Falta en engine: $required"}
    }
    $embeddedSkin=Join-Path $expanded 'assets\skins\smolbird.png'
    if((Get-FileHash $embeddedSkin -Algorithm SHA256).Hash.ToLowerInvariant()-ne'fbfb5fdf0c1a71d3904efcbdfe9b403107c133b9137a302f1611e8adc29864fb'){
        throw 'El engine no contiene la skin exacta de smolbird.'
    }
    $fakeCsl=Join-Path $instance 'mods\CustomSkinLoader_Test.jar';New-Item -ItemType Directory -Path (Split-Path $fakeCsl -Parent) -Force|Out-Null
    [IO.File]::WriteAllBytes($fakeCsl,[byte[]](9,8,7,6))
    [IO.File]::WriteAllBytes((Join-Path $instance 'mods\CustomSkinLoader_Old.jar'),[byte[]](1,2,3))
    $fakeHash=(Get-FileHash $fakeCsl -Algorithm SHA256).Hash.ToLowerInvariant()
    $global=[pscustomobject]@{customSkinLoader=[pscustomobject]@{mode='required';variants=@([pscustomobject]@{minecraftVersions=@('1.20.1');path='mods/CustomSkinLoader_Test.jar';sha256=$fakeHash});localSkins=@([pscustomobject]@{username='smolbird';embeddedPath='assets/skins/smolbird.png';sha256='fbfb5fdf0c1a71d3904efcbdfe9b403107c133b9137a302f1611e8adc29864fb'})}}
    Set-CocoGlobalSkinAssets $global $iron $instance $expanded
    $installedSkin=Join-Path $instance 'CustomSkinLoader\LocalSkin\skins\smolbird.png'
    if(-not(Test-Path $installedSkin)-or(Get-FileHash $installedSkin -Algorithm SHA256).Hash.ToLowerInvariant()-ne'fbfb5fdf0c1a71d3904efcbdfe9b403107c133b9137a302f1611e8adc29864fb'){
        throw 'La skin global de smolbird no se instalo en la ruta oficial LocalSkin.'
    }
    if(Test-Path (Join-Path $instance 'mods\CustomSkinLoader_Old.jar')){throw 'Una version vieja de CustomSkinLoader siguio junto a la variante compatible.'}
    New-Item -ItemType Directory -Path (Join-Path $instance 'essential') -Force|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $instance 'mods\essential-test.jar'),[byte[]](1))
    if((Remove-CocoEssentialArtifacts $instance)-lt2-or(Test-Path (Join-Path $instance 'essential'))-or(Test-Path (Join-Path $instance 'mods\essential-test.jar'))){
        throw 'Essential no se elimino globalmente de la experiencia.'
    }

    $updater=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
    foreach($requiredPattern in 'manualLauncher','manualOriginalRunning','-not\$manualOriginalRunning','Start-CocoLauncherUi','-not\$Silent','-not\$NetworkOnly','-not\$DetectOnly'){
        if($updater-notmatch$requiredPattern){throw "La activacion launcher no contiene: $requiredPattern"}
    }
    foreach($requiredFunction in 'Start-CocoLauncherUi','Sync-CocoLegacyInstanceForLauncher','Invoke-CocoLauncherClientSession','Invoke-CocoLauncherHostSession','Resolve-CocoLauncherIdentityUi','Wait-CocoPortableMcGame','Invoke-CocoLauncherNetworkSerialized','Get-CocoLauncherFailureDetail','Import-CocoUserSkin','Sync-CocoSkinRegistry','Sync-CocoOriginalSkinRegistry','Test-CocoSkinServiceEndpoint'){
        if($launcherText-notmatch("function\s+"+[regex]::Escape($requiredFunction))){throw "Falta el flujo UI: $requiredFunction"}
    }
    $clientFlow=[regex]::Match($launcherText,'(?s)function Invoke-CocoLauncherClientSession.*?function Invoke-CocoLauncherHostSession').Value
    if(@([regex]::Matches($clientFlow,'Get-CocoSessionAnnouncement')).Count-lt2-or@([regex]::Matches($clientFlow,'Announcement\.sessionId-ne\$sessionId')).Count-lt2){
        throw 'El cliente no revalida la misma sesion despues de preparar/login.'
    }
    if($clientFlow.IndexOf('$identity=Resolve-CocoLauncherIdentityUi')-lt$clientFlow.LastIndexOf('Invoke-CocoManagedExperienceLaunch $Catalog $action.Experience.id $dummy')-or
       $clientFlow.IndexOf('$identity=Resolve-CocoLauncherIdentityUi')-gt$clientFlow.IndexOf('Start-CocoLauncherExperience')){
        throw 'La identidad no se resuelve entre la preparacion independiente del pack y la apertura de Minecraft.'
    }
    if($launcherText-match'Se usa en todas las experiencias y conserva inventario'){
        throw 'El selector de nombre conserva el texto explicativo retirado por UX.'
    }
    if($launcherText-notmatch'AllowDrop=\$true'-or$launcherText-notmatch'Windows\.Forms\.OpenFileDialog'-or$launcherText-notmatch'CLIC O ARRASTRA UN PNG'){
        throw 'La UI no ofrece un selector de skin reconocible por clic y arrastre.'
    }
    if($updater-notmatch'Sync-CocoOriginalSkinRegistry'){
        throw 'NetworkOnly no sincroniza skins para el mundo original.'
    }
    $unknownExperience=[pscustomobject]@{runtime=[pscustomobject]@{minecraftVersion='9.9.9'}}
    $unknownRejected=$false;try{[void](Get-CocoCustomSkinLoaderVariant $catalog.globalPolicies $unknownExperience)}catch{$unknownRejected=$_.Exception.Message-match'9\.9\.9'}
    if(-not$unknownRejected){throw 'Una version futura sin variante probada de CustomSkinLoader fue aceptada por inferencia.'}
    $uiFlow=[regex]::Match($launcherText,'(?s)function Start-CocoLauncherUi.*$').Value
    if($uiFlow-notmatch"managementMode-eq'managed'"-or$uiFlow-notmatch"if\(\`$session\.State-eq'offline'\)"-or$uiFlow-notmatch'Sync-CocoLegacyInstanceForLauncher'){
        throw 'La UI no separo el selector administrado del fallback updater de Coco original.'
    }
    if($uiFlow-notmatch'Form\.Hide\(\)'-or$uiFlow-notmatch'Wait-CocoPortableMcGame \$launch\.Process -PumpUi -Dispose'){
        throw 'El cliente no conserva Coco oculto para supervisar PortableMC/Minecraft y drenar sus pipes.'
    }
    if($uiFlow-notmatch'Invoke-CocoLauncherNetworkSerialized'){
        throw 'Coco Launcher no serializa su reparacion ZeroTier con Bridge y engines anteriores.'
    }
    if($uiFlow-notmatch'AutoScroll=\$true'-or$uiFlow-notmatch'CocoPanel\.Controls\.Add\(\$identityCard\)'-or$uiFlow-notmatch'TU IDENTIDAD COCO'){
        throw 'El selector no soporta multiples experiencias o no contiene la tarjeta unificada de identidad.'
    }
    if($uiFlow-notmatch'\$close\.Enabled=\$false'-or$uiFlow-notmatch'finally\{\$identityText\.Enabled=\$true;\$skinTile\.Enabled=\$true;\$close\.Enabled=\$true\}'-or$uiFlow-notmatch'Get-CocoLauncherFailureDetail'){
        throw 'La UI no conserva identidad/skin durante la preparacion, no bloquea el cierre transaccional o no genera diagnosticos.'
    }
    if((Get-Command Test-CocoTcpEndpoint).Parameters.ContainsKey('Host')){
        throw 'Test-CocoTcpEndpoint usa el nombre reservado $Host y fallara al enlazar parametros.'
    }
    'PASS: mundo original externo con fallback updater, rol, LAN administrada, UI host/cliente y catalogo versionado validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
