[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$scripts=@(
    'engine\CocoUpdater.ps1',
    'engine\CocoNetwork.ps1',
    'engine\CocoNetworkElevated.ps1',
    'engine\CocoNetworkAuthorizer.ps1'
)
foreach($relative in $scripts){
    $path=Join-Path $root $relative
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Error de sintaxis en $relative`: $($errors[0].Message)"}
}

$networkId='58997fc5f3c0c001'
$cliCandidates=@(
    'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
    'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
    'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
    'C:\Program Files\ZeroTier\One\zerotier-cli.exe'
)
$cli=@($cliCandidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
if($cli){
    $info=(& $cli -j info 2>&1|Out-String)|ConvertFrom-Json
    if(-not$info.online-or[version]$info.version-lt[version]'1.16.2'){throw 'La instalacion viva de ZeroTier no esta ONLINE o es antigua.'}
    $networks=@((& $cli -j listnetworks 2>&1|Out-String)|ConvertFrom-Json)
    $network=@($networks|Where-Object{$_.id-eq$networkId-or$_.nwid-eq$networkId}|Select-Object -First 1)[0]
    if(-not$network-or$network.status-ne'OK'-or@($network.assignedAddresses)-notcontains'10.77.37.1/24'){
        throw 'La red Coco viva del host no esta lista en 10.77.37.1/24.'
    }
    $mac=([string]$network.mac).Replace(':','-')
    $adapter=@(Get-NetAdapter|Where-Object{$_.InterfaceDescription-match'ZeroTier'-and$_.MacAddress-eq$mac}|Select-Object -First 1)[0]
    if(-not$adapter){throw 'No se encontro el adaptador ZeroTier vivo.'}
    if((Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex).NetworkCategory-ne'Private'){throw 'El adaptador ZeroTier del host no esta en perfil Private.'}

    $rule=Get-NetFirewallRule -DisplayName 'Coco Minecraft - ZeroTier TCP 25565' -ErrorAction Stop
    $port=$rule|Get-NetFirewallPortFilter
    $address=$rule|Get-NetFirewallAddressFilter
    $remote=@($address.RemoteAddress)
    $subnetOkay=$remote-contains'10.77.37.0/24'-or$remote-contains'10.77.37.0/255.255.255.0'
    if($rule.Action-ne'Allow'-or$rule.Direction-ne'Inbound'-or$port.Protocol-ne'TCP'-or[int]$port.LocalPort-ne25565-or-not$subnetOkay){
        throw 'La regla de Firewall viva no esta limitada a TCP 25565 y la subred Coco.'
    }

    $authorizer=Join-Path $root 'engine\CocoNetworkAuthorizer.ps1'
    $token=(Get-Content 'C:\ProgramData\ZeroTier\One\authtoken.secret' -Raw).Trim()
    $headers=@{'X-ZT1-Auth'=$token}
    $fakeNode=[guid]::NewGuid().ToString('N').Substring(0,10)
    $memberUri="http://127.0.0.1:9993/controller/network/$networkId/member/$fakeNode"
    try{
        $pending=Invoke-RestMethod -Method Post -Uri $memberUri -Headers $headers -ContentType 'application/json' -Body '{"authorized":false}' -TimeoutSec 10
        if($pending.authorized){throw 'El miembro sintetico no quedo pendiente.'}
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -NetworkId {1} -Once' -f ($authorizer-replace'"','\"'),$networkId
        $pass=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
        if($pass.ExitCode-ne0){throw 'El autorizador local no completo una pasada.'}
        $authorized=Invoke-RestMethod -Method Get -Uri $memberUri -Headers $headers -TimeoutSec 10
        if(-not$authorized.authorized){throw 'El autorizador local no acepto un nodo pendiente.'}
        $recentLog=Get-Content (Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\logs\zerotier-authorizer.log') -Tail 6|Out-String
        if($recentLog-notmatch[regex]::Escape("Nodo autorizado automaticamente: $fakeNode")-or
            $recentLog-notmatch'Configuracion de red republicada'){
            throw 'El autorizador no republico la red despues de aceptar el nodo.'
        }
    }finally{
        try{Invoke-RestMethod -Method Delete -Uri $memberUri -Headers $headers -TimeoutSec 10|Out-Null}catch{}
    }

    $statusPath=Join-Path $env:LOCALAPPDATA "CocoMinecraftUpdater\network\authorizer-$networkId.json"
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
    $watch=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 5') -PassThru
    $authorizerProcess=$null
    try{
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -NetworkId {1} -WatchPid {2} -PollSeconds 1' -f ($authorizer-replace'"','\"'),$networkId,$watch.Id
        $authorizerProcess=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
        $deadline=(Get-Date).AddSeconds(4);$heartbeat=$null
        do{
            if(Test-Path -LiteralPath $statusPath){try{$heartbeat=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json}catch{}}
            if($heartbeat.healthy-and$heartbeat.running-and[int64]$heartbeat.watchPid-eq$watch.Id){break}
            Start-Sleep -Milliseconds 200
        }while((Get-Date)-lt$deadline)
        if(-not$heartbeat.healthy-or-not$heartbeat.running-or[int64]$heartbeat.watchPid-ne$watch.Id){throw 'El autorizador persistente no publico un heartbeat sano.'}
        $watch.WaitForExit()
        if(-not$authorizerProcess.WaitForExit(5000)){throw 'El autorizador no se detuvo al terminar Minecraft simulado.'}
        $stopped=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
        if($stopped.running){throw 'El heartbeat del autorizador no registro su cierre.'}
    }finally{
        if($watch-and-not$watch.HasExited){Stop-Process -Id $watch.Id -Force -ErrorAction SilentlyContinue}
        if($authorizerProcess-and-not$authorizerProcess.HasExited){Stop-Process -Id $authorizerProcess.Id -Force -ErrorAction SilentlyContinue}
    }
}

$msi=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\network\ZeroTier-One-1.16.2.msi'
if(Test-Path -LiteralPath $msi){
    $expected='42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'
    if((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()-ne$expected){throw 'El MSI cacheado no coincide con su SHA-256 fijado.'}
    $signature=Get-AuthenticodeSignature -LiteralPath $msi
    if($signature.Status-ne'Valid'-or$signature.SignerCertificate.Subject-notmatch'(?i)ZEROTIER,\s*INC\.'){
        throw 'El MSI cacheado no tiene la firma Authenticode esperada.'
    }
}

'PASS: integracion ZeroTier, controles de seguridad y estado vivo validados.'
