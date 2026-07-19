function Get-CocoZeroTierCli {
    $candidates=@(
        $env:COCO_ZEROTIER_CLI,
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
        'C:\Program Files\ZeroTier\One\zerotier-cli.exe'
    )|Where-Object{$_}
    return @($candidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
}

function Invoke-CocoZeroTierJson([string]$Cli,[string[]]$Arguments){
    if(-not$Cli){return $null}
    $text=(& $Cli @Arguments 2>&1|Out-String).Trim()
    if($LASTEXITCODE-ne0){throw "ZeroTier CLI termino con codigo $LASTEXITCODE`: $text"}
    if(-not$text){return $null}
    return $text|ConvertFrom-Json
}

function Get-CocoZeroTierNetwork([string]$Cli,[string]$NetworkId){
    try{
        $items=@(Invoke-CocoZeroTierJson $Cli @('-j','listnetworks'))
        return @($items|Where-Object{$_.id-eq$NetworkId-or$_.nwid-eq$NetworkId}|Select-Object -First 1)[0]
    }catch{return $null}
}

function Test-CocoVersionAtLeast([string]$Actual,[string]$Minimum){
    try{return [version]$Actual-ge[version]$Minimum}catch{return $false}
}

function Get-CocoZeroTierAdapter($Network,[string]$NetworkId=''){
    $normalizedMac=if($Network){([string]$Network.mac).Replace(':','-')}else{''}
    $expectedId=if($Network-and$Network.id){[string]$Network.id}else{$NetworkId}
    return @(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object{
        $_.InterfaceDescription-match'ZeroTier'-and(
            ($normalizedMac-and$_.MacAddress-eq$normalizedMac)-or
            ($expectedId-and$_.Name-like"*$expectedId*")
        )
    }|Select-Object -First 1)[0]
}

function Get-CocoClientNetworkFromAdapter($Adapter,$NetworkConfig){
    if(-not$Adapter-or$Adapter.InterfaceDescription-notmatch'ZeroTier'-or$Adapter.Name-notlike"*$($NetworkConfig.networkId)*"){return $null}
    try{
        $addresses=@(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop|Where-Object{
            $_.IPAddress-match'^10\.77\.37\.(\d{1,3})$'-and
            [int]([regex]::Match($_.IPAddress,'(\d+)$').Value)-ge2-and
            [int]([regex]::Match($_.IPAddress,'(\d+)$').Value)-le254-and
            $_.AddressState-ne'Duplicate'
        })
        if(-not$addresses.Count){return $null}
        return [pscustomobject]@{
            id=[string]$NetworkConfig.networkId;nwid=[string]$NetworkConfig.networkId;status='OK'
            assignedAddresses=@($addresses|ForEach-Object{"$($_.IPAddress)/$($_.PrefixLength)"})
            mac=([string]$Adapter.MacAddress).Replace('-',':').ToLowerInvariant()
        }
    }catch{return $null}
}

function Get-CocoControllerToken {
    $paths=@(
        $env:COCO_ZEROTIER_TOKEN_PATH,
        'C:\ProgramData\ZeroTier\One\authtoken.secret',
        'C:\ProgramData\ZeroTier\authtoken.secret'
    )|Where-Object{$_}
    $path=@($paths|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
    if(-not$path){throw 'No se encontro el token local del controlador ZeroTier.'}
    return (Get-Content -LiteralPath $path -Raw).Trim()
}

function Invoke-CocoController([string]$Method,[string]$Path,$Body=$null){
    $base=if($env:COCO_ZEROTIER_API_BASE){$env:COCO_ZEROTIER_API_BASE.TrimEnd('/')}else{'http://127.0.0.1:9993'}
    $headers=@{'X-ZT1-Auth'=(Get-CocoControllerToken)}
    $parameters=@{Method=$Method;Uri="$base$Path";Headers=$headers;TimeoutSec=10}
    if($null-ne$Body){$parameters.ContentType='application/json';$parameters.Body=($Body|ConvertTo-Json -Depth 20)}
    return Invoke-RestMethod @parameters
}

function Ensure-CocoControllerNetwork($NetworkConfig){
    $networkId=[string]$NetworkConfig.networkId
    $status=Invoke-CocoController 'Get' '/status'
    if(([string]$status.address)-ne$networkId.Substring(0,10)){
        throw 'La identidad ZeroTier del host no coincide con el controlador Coco. No reinstales ni borres ProgramData de ZeroTier.'
    }
    $body=[ordered]@{
        name=[string]$NetworkConfig.name
        private=$true
        v4AssignMode=[ordered]@{zt=$true}
        ipAssignmentPools=@([ordered]@{
            ipRangeStart=[string]$NetworkConfig.ipPoolStart
            ipRangeEnd=[string]$NetworkConfig.ipPoolEnd
        })
        routes=@([ordered]@{target=[string]$NetworkConfig.subnet;via=$null})
    }
    $network=Invoke-CocoController 'Post' "/controller/network/$networkId" $body
    if(-not$network-or$network.id-ne$networkId-or-not$network.private){throw 'No se pudo preparar el controlador local de la red Coco.'}
    Write-CocoLog "Controlador local verificado. NetworkId=$networkId"
}

function Set-CocoHostMember($NetworkConfig){
    $status=Invoke-CocoController 'Get' '/status'
    $nodeId=[string]$status.address
    if($nodeId-notmatch'^[0-9a-f]{10}$'){throw 'El controlador local devolvio un Node ID invalido.'}
    $path="/controller/network/$($NetworkConfig.networkId)/member/$nodeId"
    $member=Invoke-CocoController 'Get' $path
    $desiredIp=[string]$NetworkConfig.hostAddress
    if(-not$member.authorized-or@($member.ipAssignments)-notcontains$desiredIp){
        $member=Invoke-CocoController 'Post' $path @{authorized=$true;ipAssignments=@($desiredIp)}
    }
    if(-not$member.authorized-or@($member.ipAssignments)-notcontains$desiredIp){throw 'No se pudo autorizar el host en su controlador local.'}
    return $nodeId
}

function Start-CocoNetworkAuthorizer($NetworkConfig,[int64]$WatchPid){
    $scriptPath=Join-Path $script:CocoEngineRoot 'CocoNetworkAuthorizer.ps1'
    if(-not(Test-Path -LiteralPath $scriptPath)){throw 'Falta el autorizador ZeroTier del host.'}
    if($WatchPid-le0){
        $onceArguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -NetworkId {1} -Once' -f `
            ($scriptPath-replace'"','\"'),$NetworkConfig.networkId
        $once=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $onceArguments -PassThru -Wait
        if($once.ExitCode-ne0){throw 'El autorizador ZeroTier no completo su verificacion inicial.'}
        Write-CocoLog 'Autorizador ZeroTier verificado en modo puntual.'
        return
    }
    $statusPath=Join-Path $env:LOCALAPPDATA "CocoMinecraftUpdater\network\authorizer-$($NetworkConfig.networkId).json"
    if(Test-Path -LiteralPath $statusPath){
        try{
            $existing=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
            $existingProcess=if([int64]$existing.processId-gt0){Get-Process -Id ([int64]$existing.processId) -ErrorAction SilentlyContinue}else{$null}
            if($existing.healthy-and$existing.running-and$existingProcess-and
               [int64]$existing.watchPid-eq$WatchPid-and([datetime]$existing.updatedAt)-gt(Get-Date).AddSeconds(-15)){
                Write-CocoLog "Autorizador ZeroTier existente reutilizado. WatchPid=$WatchPid ProcessId=$($existing.processId)"
                return
            }
        }catch{}
    }
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -NetworkId {1} -WatchPid {2}' -f `
        ($scriptPath-replace'"','\"'),$NetworkConfig.networkId,$WatchPid
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments|Out-Null
    $deadline=(Get-Date).AddSeconds(8)
    do{
        if(Test-Path -LiteralPath $statusPath){
            try{
                $status=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
                if($status.healthy-and$status.running-and([datetime]$status.updatedAt)-gt(Get-Date).AddSeconds(-15)){
                    Write-CocoLog "Autorizador ZeroTier verificado. WatchPid=$WatchPid ProcessId=$($status.processId)"
                    return
                }
                if($status.error){Write-CocoLog "Autorizador aun no listo: $($status.error)"}
            }catch{}
        }
        Start-Sleep -Milliseconds 250
    }while((Get-Date)-lt$deadline)
    throw 'El autorizador ZeroTier del host no pudo iniciar correctamente.'
}

function Test-CocoZeroTierInstall([string]$MinimumVersion){
    $cli=Get-CocoZeroTierCli
    if(-not$cli){return $false}
    try{
        $service=Get-Service -Name 'ZeroTierOneService' -ErrorAction Stop
        $products=@(
            Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue|
                ForEach-Object{Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue}|Where-Object DisplayName -eq 'ZeroTier One'
        )
        $version=@($products|Where-Object{Test-CocoVersionAtLeast ([string]$_.DisplayVersion) $MinimumVersion}|Select-Object -First 1)[0]
        return [bool]($service-and$version)
    }catch{return $false}
}

function Test-CocoHostFirewall($NetworkConfig){
    try{
        $rule=Get-NetFirewallRule -DisplayName ([string]$NetworkConfig.firewallRuleName) -ErrorAction Stop
        $port=$rule|Get-NetFirewallPortFilter
        $address=$rule|Get-NetFirewallAddressFilter
        $interface=$rule|Get-NetFirewallInterfaceFilter
        $remote=@($address.RemoteAddress)
        $subnetOkay=$remote-contains([string]$NetworkConfig.subnet)-or
            ([string]$NetworkConfig.subnet-eq'10.77.37.0/24'-and$remote-contains'10.77.37.0/255.255.255.0')
        return [bool]($rule.Enabled-eq'True'-and$rule.Direction-eq'Inbound'-and$rule.Action-eq'Allow'-and
            $rule.Profile.ToString()-match'Private'-and$port.Protocol-eq'TCP'-and[int]$port.LocalPort-eq[int]$NetworkConfig.minecraftPort-and
            $subnetOkay-and$interface.InterfaceAlias-match'ZeroTier')
    }catch{return $false}
}

function Test-CocoClientFirewallClean($NetworkConfig){
    return -not[bool](Get-NetFirewallRule -DisplayName ([string]$NetworkConfig.firewallRuleName) -ErrorAction SilentlyContinue)
}

function Get-CocoPeerMode($NetworkConfig,[string]$Role){
    if($Role-ne'client'){return 'UNKNOWN'}
    try{
        $peers=@(Invoke-CocoZeroTierJson (Get-CocoZeroTierCli) @('-j','listpeers'))
        $controller=$NetworkConfig.networkId.Substring(0,10)
        $peer=@($peers|Where-Object address -eq $controller|Select-Object -First 1)[0]
        if(-not$peer){return 'UNKNOWN'}
        $active=@($peer.paths|Where-Object active)
        if($peer.tunneled -or -not $active.Count){return 'RELAY'}
        return 'DIRECT'
    }catch{return 'UNKNOWN'}
}

function Invoke-CocoNetworkElevation($NetworkConfig,[string]$Role,[bool]$InstallRequired){
    $networkRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\network'
    New-Item -ItemType Directory -Path $networkRoot -Force|Out-Null
    $installerPath=$null
    if($InstallRequired){
        $installerPath=Join-Path $networkRoot ("ZeroTier-One-{0}.msi"-f$NetworkConfig.installer.version)
        if(-not((Test-Path -LiteralPath $installerPath)-and(Get-Sha256 $installerPath)-eq([string]$NetworkConfig.installer.sha256).ToLowerInvariant())){
            Set-CocoState 'Preparando red Coco' 'Descargando ZeroTier desde su sitio oficial...' 12
            Download-VerifiedFile $NetworkConfig.installer.url $installerPath $NetworkConfig.installer.sha256
        }
        $signature=Get-AuthenticodeSignature -LiteralPath $installerPath
        if($signature.Status-ne'Valid'-or-not$signature.SignerCertificate-or$signature.SignerCertificate.Subject-notmatch([string]$NetworkConfig.installer.signerSubjectPattern)){
            throw 'La firma oficial del instalador ZeroTier no es valida.'
        }
    }

    $id=[guid]::NewGuid().ToString('N')
    $configPath=Join-Path $networkRoot "elevated-$id.json"
    $resultPath=Join-Path $networkRoot "elevated-$id-result.json"
    $progressPath=Join-Path $networkRoot "elevated-$id-progress.json"
    $payload=[ordered]@{
        mode=$Role;networkId=[string]$NetworkConfig.networkId;minimumVersion=[string]$NetworkConfig.installer.version
        installerPath=$installerPath;installerSha256=[string]$NetworkConfig.installer.sha256
        signerSubjectPattern=[string]$NetworkConfig.installer.signerSubjectPattern
        profile=if($Role-eq'host'){'Private'}else{'Public'}
        leaveNetworkIds=@($NetworkConfig.leaveNetworkIds)
        firewallRuleName=[string]$NetworkConfig.firewallRuleName
        minecraftPort=[int]$NetworkConfig.minecraftPort;subnet=[string]$NetworkConfig.subnet
        authorizationTimeoutSeconds=if($NetworkConfig.authorizationTimeoutSeconds){[int]$NetworkConfig.authorizationTimeoutSeconds}else{120}
    }
    $payload|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $configPath -Encoding UTF8
    $helper=Join-Path $script:CocoEngineRoot 'CocoNetworkElevated.ps1'
    if(-not(Test-Path -LiteralPath $helper)){throw 'Falta el componente elevado de red.'}
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -ResultPath "{2}" -ProgressPath "{3}"' -f `
        ($helper-replace'"','\"'),($configPath-replace'"','\"'),($resultPath-replace'"','\"'),($progressPath-replace'"','\"')
    Set-CocoState 'Configurando red Coco' 'Windows pedira permiso una sola vez. Pulsa Si.' 15
    try{$process=Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru}
    catch{throw 'Se cancelo el permiso de administrador. Vuelve a abrir CocoUpdater y pulsa Si.'}
    while(-not$process.HasExited){
        if(Test-Path -LiteralPath $progressPath){
            try{
                $networkProgress=Get-Content -LiteralPath $progressPath -Raw|ConvertFrom-Json
                if($networkProgress.message-and$networkProgress.detail){
                    Set-CocoState ([string]$networkProgress.message) ([string]$networkProgress.detail) ([int]$networkProgress.progress)
                }
            }catch{}
        }elseif($script:CocoForm){[Windows.Forms.Application]::DoEvents()}
        Start-Sleep -Milliseconds 250
        $process.Refresh()
    }
    try{$result=if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json}else{$null}}
    finally{Remove-Item -LiteralPath $configPath,$resultPath,$progressPath -Force -ErrorAction SilentlyContinue}
    if($process.ExitCode-ne0-or-not$result-or-not$result.success){
        $message=if($result.message){[string]$result.message}else{"La configuracion elevada termino con codigo $($process.ExitCode)."}
        throw $message
    }
    $script:CocoNetworkRebootRequired=[bool]$result.rebootRequired
    $script:CocoElevatedNetworkStatus=[string]$result.networkStatus
    $script:CocoElevatedAssignedAddresses=@($result.assignedAddresses)
    $script:CocoElevatedPeerMode=[string]$result.peerMode
    if($script:CocoNetworkRebootRequired){Write-CocoLog 'ZeroTier recomendo reiniciar Windows; se intentara completar sin reinicio.'}
    return $result
}

function Wait-CocoZeroTierReady($NetworkConfig,[string]$Role){
    $timeout=if($NetworkConfig.authorizationTimeoutSeconds){[int]$NetworkConfig.authorizationTimeoutSeconds}else{120}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt$timeout){
        $cli=Get-CocoZeroTierCli
        $network=Get-CocoZeroTierNetwork $cli ([string]$NetworkConfig.networkId)
        if($Role-eq'client'){
            $adapter=Get-CocoZeroTierAdapter $network ([string]$NetworkConfig.networkId)
            $adapterNetwork=Get-CocoClientNetworkFromAdapter $adapter $NetworkConfig
            if($adapterNetwork){return $adapterNetwork}
        }
        if($Role-eq'host'-and$network-and$network.status-ne'OK'){
            try{[void](Set-CocoHostMember $NetworkConfig)}catch{Write-CocoLog "Autorizacion host pendiente: $($_.Exception.Message)"}
        }
        if($network-and$network.status-eq'OK'){
            $addresses=@($network.assignedAddresses|ForEach-Object{([string]$_-split'/')[0]})
            if($Role-ne'host'-or$addresses-contains([string]$NetworkConfig.hostAddress)){return $network}
        }
        $remaining=[Math]::Max(0,$timeout-[int]$watch.Elapsed.TotalSeconds)
        Set-CocoState 'Conectando red Coco' "Esperando autorizacion automatica del host... $remaining s" 22
        Start-Sleep -Seconds 2
    }
    if($script:CocoNetworkRebootRequired){throw 'ZeroTier necesita reiniciar Windows para terminar. Reinicia y vuelve a ejecutar CocoUpdater.'}
    throw 'El host no autorizo esta PC a tiempo. Deja Minecraft del host abierto y vuelve a ejecutar CocoUpdater.'
}

function Set-CocoMinecraftNetworkConfig([string]$Root,$NetworkConfig,[string]$Role){
    $configRoot=Join-Path $Root 'config'
    New-Item -ItemType Directory -Path $configRoot -Force|Out-Null
    $path=Join-Path $configRoot 'coco-network.json'
    [ordered]@{
        provider='zerotier';networkId=[string]$NetworkConfig.networkId;serverName='Coco Minecraft'
        host=[string]$NetworkConfig.hostAddress;port=[int]$NetworkConfig.minecraftPort
        address=("{0}:{1}"-f$NetworkConfig.hostAddress,$NetworkConfig.minecraftPort)
        role=$Role;updatedAt=(Get-Date).ToString('o')
    }|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
    if($Role-eq'host'){
        $lanConfig=Join-Path $Root 'saves\coco\mcwifipnp.json'
        if(Test-Path -LiteralPath $lanConfig){
            $lan=Get-Content -LiteralPath $lanConfig -Raw|ConvertFrom-Json
            $lan.port=[int]$NetworkConfig.minecraftPort
            $lan.'enable-upnp'=$false
            $lan|ConvertTo-Json|Set-Content -LiteralPath $lanConfig -Encoding UTF8
        }
    }
}

function Ensure-CocoNetwork([string]$Root,[string]$Role,$Manifest){
    if(-not$Manifest.network-or$Manifest.network.provider-ne'zerotier'){return [pscustomobject]@{enabled=$false}}
    $config=$Manifest.network
    if($config.networkId-ne'58997fc5f3c0c001'){throw 'El manifiesto contiene un Network ID Coco inesperado.'}
    if($config.hostAddress-notmatch'^10\.77\.37\.1$'-or$config.subnet-ne'10.77.37.0/24'){throw 'El manifiesto contiene una red Coco inesperada.'}
    if([int]$config.minecraftPort-ne25565){throw 'El manifiesto contiene un puerto Coco inesperado.'}
    if($config.installer.version-ne'1.16.2'-or
        $config.installer.url-ne'https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi'-or
        ([string]$config.installer.sha256).ToLowerInvariant()-ne'42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'){
        throw 'El manifiesto contiene un instalador ZeroTier inesperado.'
    }
    $unexpectedLeaves=@($config.leaveNetworkIds|Where-Object{$_-and$_-ne'154a350c866b8062'})
    if($unexpectedLeaves.Count){throw 'El manifiesto intento abandonar una red ZeroTier no reconocida.'}

    Set-CocoState 'Verificando red Coco' 'Preparando la LAN virtual privada...' 10
    $cli=Get-CocoZeroTierCli
    foreach($obsolete in @($config.leaveNetworkIds)){
        if($cli-and$obsolete-and$obsolete-ne$config.networkId-and(Get-CocoZeroTierNetwork $cli $obsolete)){
            & $cli leave $obsolete 2>&1|Out-Null
        }
    }
    $network=Get-CocoZeroTierNetwork (Get-CocoZeroTierCli) ([string]$config.networkId)
    $adapter=Get-CocoZeroTierAdapter $network ([string]$config.networkId)
    if($Role-eq'client'-and-not$network){$network=Get-CocoClientNetworkFromAdapter $adapter $config}
    $installRequired=-not(Test-CocoZeroTierInstall ([string]$config.installer.version))
    $desiredProfile=if($Role-eq'host'){'Private'}else{'Public'}
    $profileOkay=$false
    if($adapter){
        try{$profileOkay=(Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction Stop).NetworkCategory-eq$desiredProfile}catch{}
    }
    $firewallOkay=if($Role-eq'host'){Test-CocoHostFirewall $config}else{Test-CocoClientFirewallClean $config}
    if($installRequired-or-not$network-or-not$adapter-or-not$profileOkay-or-not$firewallOkay){
        if(-not$script:CocoForm){Show-CocoWindow}
        [void](Invoke-CocoNetworkElevation $config $Role $installRequired)
    }

    if($Role-eq'host'){
        # Installation/service repair must happen before using the local API.
        # Fix the host member first so the authorizer never gives it a random IP.
        Ensure-CocoControllerNetwork $config
        [void](Set-CocoHostMember $config)
        Start-CocoNetworkAuthorizer $config $MinecraftPid
    }
    $network=Wait-CocoZeroTierReady $config $Role
    $peerMode=Get-CocoPeerMode $config $Role
    if($peerMode-eq'UNKNOWN'-and$script:CocoElevatedPeerMode){$peerMode=$script:CocoElevatedPeerMode}
    Set-CocoMinecraftNetworkConfig $Root $config $Role
    $stateRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\network'
    New-Item -ItemType Directory -Path $stateRoot -Force|Out-Null
    [ordered]@{
        provider='zerotier';networkId=[string]$config.networkId;status=[string]$network.status
        assignedAddresses=@($network.assignedAddresses);role=$Role;peerMode=$peerMode;verifiedAt=(Get-Date).ToString('o')
    }|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'state.json') -Encoding UTF8
    Write-CocoLog "Red Coco lista. Role=$Role Status=$($network.status) PeerMode=$peerMode Addresses=$($network.assignedAddresses-join',')"
    return [pscustomobject]@{enabled=$true;network=$network;address=("{0}:{1}"-f$config.hostAddress,$config.minecraftPort)}
}
