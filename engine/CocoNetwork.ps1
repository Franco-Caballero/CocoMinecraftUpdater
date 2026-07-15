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

function Get-CocoZeroTierAdapter($Network){
    if(-not$Network){return $null}
    $normalizedMac=([string]$Network.mac).Replace(':','-')
    return @(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object{
        $_.InterfaceDescription-match'ZeroTier'-and($_.MacAddress-eq$normalizedMac-or$_.Name-like"*$($Network.id)*")
    }|Select-Object -First 1)[0]
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
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -NetworkId {1} -WatchPid {2}' -f `
        ($scriptPath-replace'"','\"'),$NetworkConfig.networkId,$WatchPid
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments|Out-Null
    Write-CocoLog "Autorizador ZeroTier iniciado. WatchPid=$WatchPid"
}

function Test-CocoZeroTierInstall([string]$MinimumVersion){
    $cli=Get-CocoZeroTierCli
    if(-not$cli){return $false}
    try{
        $info=Invoke-CocoZeroTierJson $cli @('-j','info')
        return [bool]($info.online-and(Test-CocoVersionAtLeast ([string]$info.version) $MinimumVersion))
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
    $payload=[ordered]@{
        mode=$Role;networkId=[string]$NetworkConfig.networkId;minimumVersion=[string]$NetworkConfig.installer.version
        installerPath=$installerPath;installerSha256=[string]$NetworkConfig.installer.sha256
        signerSubjectPattern=[string]$NetworkConfig.installer.signerSubjectPattern
        profile=if($Role-eq'host'){'Private'}else{'Public'}
        leaveNetworkIds=@($NetworkConfig.leaveNetworkIds)
        firewallRuleName=[string]$NetworkConfig.firewallRuleName
        minecraftPort=[int]$NetworkConfig.minecraftPort;subnet=[string]$NetworkConfig.subnet
    }
    $payload|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $configPath -Encoding UTF8
    $helper=Join-Path $script:CocoEngineRoot 'CocoNetworkElevated.ps1'
    if(-not(Test-Path -LiteralPath $helper)){throw 'Falta el componente elevado de red.'}
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -ResultPath "{2}"' -f `
        ($helper-replace'"','\"'),($configPath-replace'"','\"'),($resultPath-replace'"','\"')
    Set-CocoState 'Configurando red Coco' 'Windows pedira permiso una sola vez. Pulsa Si.' 15
    try{$process=Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -PassThru -Wait}
    catch{throw 'Se cancelo el permiso de administrador. Vuelve a abrir CocoUpdater y pulsa Si.'}
    try{$result=if(Test-Path -LiteralPath $resultPath){Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json}else{$null}}
    finally{Remove-Item -LiteralPath $configPath,$resultPath -Force -ErrorAction SilentlyContinue}
    if($process.ExitCode-ne0-or-not$result-or-not$result.success){
        $message=if($result.message){[string]$result.message}else{"La configuracion elevada termino con codigo $($process.ExitCode)."}
        throw $message
    }
    if($result.rebootRequired){throw 'ZeroTier solicito reiniciar Windows. Reinicia y vuelve a ejecutar CocoUpdater.'}
}

function Wait-CocoZeroTierReady($NetworkConfig,[string]$Role){
    $timeout=if($NetworkConfig.authorizationTimeoutSeconds){[int]$NetworkConfig.authorizationTimeoutSeconds}else{120}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds-lt$timeout){
        $cli=Get-CocoZeroTierCli
        $network=Get-CocoZeroTierNetwork $cli ([string]$NetworkConfig.networkId)
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
    throw 'El host no autorizo esta PC a tiempo. Deja el mundo Coco abierto y vuelve a ejecutar el updater.'
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
    if($Role-eq'host'){
        Ensure-CocoControllerNetwork $config
        Start-CocoNetworkAuthorizer $config $MinecraftPid
    }

    $cli=Get-CocoZeroTierCli
    foreach($obsolete in @($config.leaveNetworkIds)){
        if($cli-and$obsolete-and$obsolete-ne$config.networkId-and(Get-CocoZeroTierNetwork $cli $obsolete)){
            & $cli leave $obsolete 2>&1|Out-Null
        }
    }
    $installRequired=-not(Test-CocoZeroTierInstall ([string]$config.installer.version))
    $network=Get-CocoZeroTierNetwork (Get-CocoZeroTierCli) ([string]$config.networkId)
    $adapter=Get-CocoZeroTierAdapter $network
    $desiredProfile=if($Role-eq'host'){'Private'}else{'Public'}
    $profileOkay=$false
    if($adapter){
        try{$profileOkay=(Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction Stop).NetworkCategory-eq$desiredProfile}catch{}
    }
    $firewallOkay=$Role-ne'host'-or(Test-CocoHostFirewall $config)
    if($installRequired-or-not$network-or-not$adapter-or-not$profileOkay-or-not$firewallOkay){
        if(-not$script:CocoForm){Show-CocoWindow}
        Invoke-CocoNetworkElevation $config $Role $installRequired
    }

    if($Role-eq'host'){[void](Set-CocoHostMember $config)}
    $network=Wait-CocoZeroTierReady $config $Role
    Set-CocoMinecraftNetworkConfig $Root $config $Role
    $stateRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\network'
    New-Item -ItemType Directory -Path $stateRoot -Force|Out-Null
    [ordered]@{
        provider='zerotier';networkId=[string]$config.networkId;status=[string]$network.status
        assignedAddresses=@($network.assignedAddresses);role=$Role;verifiedAt=(Get-Date).ToString('o')
    }|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $stateRoot 'state.json') -Encoding UTF8
    Write-CocoLog "Red Coco lista. Role=$Role Status=$($network.status) Addresses=$($network.assignedAddresses-join',')"
    return [pscustomobject]@{enabled=$true;network=$network;address=("{0}:{1}"-f$config.hostAddress,$config.minecraftPort)}
}
