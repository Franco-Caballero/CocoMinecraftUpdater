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
    '{"port":12345,"online-mode":true,"enable-upnp":true,"enable-uuid-fixer":false}'|Set-Content -LiteralPath (Join-Path $world 'mcwifipnp.json') -Encoding UTF8
    if((Set-CocoManagedLanWorldConfigurations $instance $iron)-ne1){throw 'No se reparo la configuracion LAN del mundo administrado.'}
    $lan=Get-Content -LiteralPath (Join-Path $world 'mcwifipnp.json') -Raw|ConvertFrom-Json
    if([int]$lan.port-ne25565-or[bool]$lan.'online-mode'-or[bool]$lan.'enable-upnp'-or-not[bool]$lan.'enable-uuid-fixer'){
        throw 'La configuracion LAN administrada no fija puerto/offline/UUID Fixer/UPnP.'
    }
    if((Set-CocoManagedLanWorldConfigurations $instance $iron)-ne0){throw 'Una configuracion LAN ya correcta fue reescrita sin necesidad.'}
    $essential=Join-Path $instance 'essential\essential-loader.properties'
    New-Item -ItemType Directory -Path (Split-Path $essential -Parent) -Force|Out-Null
    "autoUpdate=with-prompt`npendingUpdateVersion=1.4.1`npendingUpdateResolution=true"|Set-Content -LiteralPath $essential -Encoding UTF8
    if(-not(Set-CocoManagedRuntimePolicies $iron $instance)){throw 'No se aplico la politica sin prompts de Essential.'}
    $essentialText=Get-Content -LiteralPath $essential -Raw
    if($essentialText-notmatch'(?m)^autoUpdate=false\r?$'-or$essentialText-match'pendingUpdate'){throw 'Essential conserva un prompt/actualizacion pendiente.'}
    if(Set-CocoManagedRuntimePolicies $iron $instance){throw 'La politica Essential ya correcta se reescribio.'}
    $stage2=Join-Path $instance 'essential\loader\stage1\modlauncher9\stage2.forge.properties'
    New-Item -ItemType Directory -Path (Split-Path $stage2 -Parent) -Force|Out-Null
    "autoUpdate=with-prompt`npendingUpdateVersion=1.7.4"|Set-Content -LiteralPath $stage2 -Encoding UTF8
    if(-not(Set-CocoManagedRuntimePolicies $iron $instance)){throw 'No se retiro el prompt interno stage2 de Essential.'}
    $stage2Text=Get-Content -LiteralPath $stage2 -Raw
    if($stage2Text-notmatch'(?m)^autoUpdate=false\r?$'-or$stage2Text-match'pendingUpdate'){throw 'Essential stage2 conserva un prompt pendiente.'}
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
    foreach($required in 'CocoLauncher.ps1','CocoSessionService.ps1','launcher\experiences\into-the-backrooms.lock.json'){
        if(-not(Test-Path -LiteralPath (Join-Path $expanded $required) -PathType Leaf)){throw "Falta en engine: $required"}
    }

    $updater=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
    foreach($requiredPattern in 'manualLauncher','manualOriginalRunning','-not\$manualOriginalRunning','Start-CocoLauncherUi','-not\$Silent','-not\$NetworkOnly','-not\$DetectOnly'){
        if($updater-notmatch$requiredPattern){throw "La activacion launcher no contiene: $requiredPattern"}
    }
    foreach($requiredFunction in 'Start-CocoLauncherUi','Sync-CocoLegacyInstanceForLauncher','Invoke-CocoLauncherClientSession','Invoke-CocoLauncherHostSession','Resolve-CocoLauncherIdentityUi','Wait-CocoPortableMcGame','Invoke-CocoLauncherNetworkSerialized','Get-CocoLauncherFailureDetail'){
        if($launcherText-notmatch("function\s+"+[regex]::Escape($requiredFunction))){throw "Falta el flujo UI: $requiredFunction"}
    }
    $clientFlow=[regex]::Match($launcherText,'(?s)function Invoke-CocoLauncherClientSession.*?function Invoke-CocoLauncherHostSession').Value
    if(@([regex]::Matches($clientFlow,'Get-CocoSessionAnnouncement')).Count-lt2-or@([regex]::Matches($clientFlow,'Announcement\.sessionId-ne\$sessionId')).Count-lt2){
        throw 'El cliente no revalida la misma sesion despues de preparar/login.'
    }
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
    if($uiFlow-notmatch'AutoScroll=\$true'-or$uiFlow-notmatch'CocoPanel\.Controls\.Add\(\$identityButton\)'){
        throw 'El selector no soporta multiples experiencias sin superponer identidad/cierre.'
    }
    if($uiFlow-notmatch'identityButton\.Enabled=\$false;\$close\.Enabled=\$false'-or$uiFlow-notmatch'Get-CocoLauncherFailureDetail'){
        throw 'La UI no bloquea cierre durante cambios transaccionales o no genera diagnosticos del launcher.'
    }
    if((Get-Command Test-CocoTcpEndpoint).Parameters.ContainsKey('Host')){
        throw 'Test-CocoTcpEndpoint usa el nombre reservado $Host y fallara al enlazar parametros.'
    }
    'PASS: mundo original externo con fallback updater, rol, LAN administrada, UI host/cliente y catalogo versionado validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
