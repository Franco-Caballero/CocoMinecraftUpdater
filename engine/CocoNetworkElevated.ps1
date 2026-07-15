[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)

$ErrorActionPreference='Stop'

function Write-Result([bool]$Success,[string]$Message,[hashtable]$Extra=@{}){
    $value=[ordered]@{success=$Success;message=$Message;updatedAt=(Get-Date).ToString('o')}
    foreach($key in $Extra.Keys){$value[$key]=$Extra[$key]}
    $tmp="$ResultPath.tmp"
    $value|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $ResultPath -Force
}

function Get-CliPath {
    $candidates=@(
        $env:COCO_ZEROTIER_CLI,
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
        'C:\Program Files\ZeroTier\One\zerotier-cli.exe'
    )|Where-Object{$_}
    return @($candidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
}

function Invoke-CliJson([string]$Cli,[string[]]$Arguments){
    $text=(& $Cli @Arguments 2>&1|Out-String).Trim()
    if($LASTEXITCODE-ne0){throw "ZeroTier CLI termino con codigo $LASTEXITCODE`: $text"}
    if(-not$text){return $null}
    return $text|ConvertFrom-Json
}

function Get-Network([string]$Cli,[string]$NetworkId){
    $items=@(Invoke-CliJson $Cli @('-j','listnetworks'))
    return @($items|Where-Object{$_.id-eq$NetworkId-or$_.nwid-eq$NetworkId}|Select-Object -First 1)[0]
}

function Test-VersionAtLeast([string]$Actual,[string]$Minimum){
    try{return [version]$Actual-ge[version]$Minimum}catch{return $false}
}

try{
    $config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
    if($config.networkId-ne'58997fc5f3c0c001'){throw 'Network ID Coco inesperado.'}
    if($config.mode-notin@('host','client')){throw 'Rol Coco invalido.'}
    if($config.profile-notin@('Public','Private')){throw 'Perfil de red invalido.'}
    if(($config.mode-eq'host'-and$config.profile-ne'Private')-or($config.mode-eq'client'-and$config.profile-ne'Public')){throw 'El perfil no coincide con el rol Coco.'}
    if([int]$config.minecraftPort-ne25565-or$config.subnet-ne'10.77.37.0/24'-or$config.firewallRuleName-ne'Coco Minecraft - ZeroTier TCP 25565'){
        throw 'La configuracion elevada contiene una regla de red inesperada.'
    }
    if($config.minimumVersion-ne'1.16.2'-or([string]$config.installerSha256).ToLowerInvariant()-ne'42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'){
        throw 'La configuracion elevada contiene un instalador ZeroTier inesperado.'
    }
    if(@($config.leaveNetworkIds|Where-Object{$_-and$_-ne'154a350c866b8062'}).Count){throw 'No se permite abandonar una red ZeroTier desconocida.'}

    $installer=$null
    $cli=Get-CliPath
    $needsInstall=-not$cli
    if($cli){
        try{
            $info=Invoke-CliJson $cli @('-j','info')
            if(-not(Test-VersionAtLeast ([string]$info.version) ([string]$config.minimumVersion))){$needsInstall=$true}
        }catch{$needsInstall=$true}
    }

    if($needsInstall){
        if(-not$config.installerPath-or-not(Test-Path -LiteralPath $config.installerPath)){throw 'Falta el instalador verificado de ZeroTier.'}
        $hash=(Get-FileHash -LiteralPath $config.installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash-ne([string]$config.installerSha256).ToLowerInvariant()){throw 'El MSI de ZeroTier no coincide con el SHA-256 esperado.'}
        $signature=Get-AuthenticodeSignature -LiteralPath $config.installerPath
        if($signature.Status-ne'Valid'-or-not$signature.SignerCertificate-or$signature.SignerCertificate.Subject-notmatch([string]$config.signerSubjectPattern)){
            throw 'La firma Authenticode del instalador de ZeroTier no es valida.'
        }
        $arguments=@('/i',('"'+$config.installerPath+'"'),'/qn','/norestart')
        for($attempt=1;$attempt-le4;$attempt++){
            $installer=Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru -Wait
            if($installer.ExitCode-ne1618){break}
            if($attempt-lt4){Start-Sleep -Seconds (5*$attempt)}
        }
        if($installer.ExitCode-notin@(0,1641,3010)){throw "El instalador de ZeroTier termino con codigo $($installer.ExitCode)."}
    }

    $rebootRequired=[bool]($installer-and$installer.ExitCode-in@(1641,3010))
    try{$service=Get-Service -Name 'ZeroTierOneService' -ErrorAction Stop}catch{
        if($rebootRequired){throw 'ZeroTier se instalo, pero Windows necesita reiniciarse para activar el adaptador. Reinicia y vuelve a ejecutar CocoUpdater.'}
        throw
    }
    if($service.StartType-ne'Automatic'){Set-Service -Name 'ZeroTierOneService' -StartupType Automatic}
    if($service.Status-ne'Running'){Start-Service -Name 'ZeroTierOneService'}
    $deadline=(Get-Date).AddSeconds(45)
    do{
        $cli=Get-CliPath
        if($cli){try{$info=Invoke-CliJson $cli @('-j','info')}catch{$info=$null}}
        if($info-and$info.online){break}
        Start-Sleep -Milliseconds 500
    }while((Get-Date)-lt$deadline)
    if(-not$cli-or-not$info-or-not$info.online){throw 'El servicio ZeroTier no quedo ONLINE.'}

    foreach($obsolete in @($config.leaveNetworkIds)){
        if($obsolete-and$obsolete-ne$config.networkId){& $cli leave $obsolete 2>&1|Out-Null}
    }
    $network=Get-Network $cli $config.networkId
    if(-not$network){
        $join=(& $cli join $config.networkId 2>&1|Out-String).Trim()
        if($LASTEXITCODE-ne0-or$join-notmatch'200\s+join\s+OK'){throw "No se pudo unir a la red Coco: $join"}
    }

    $deadline=(Get-Date).AddSeconds(60)
    do{
        $network=Get-Network $cli $config.networkId
        if($network){break}
        Start-Sleep -Milliseconds 500
    }while((Get-Date)-lt$deadline)
    if(-not$network){throw 'ZeroTier no creo el adaptador de la red Coco.'}

    $normalizedMac=([string]$network.mac).Replace(':','-')
    $adapter=$null
    $deadline=(Get-Date).AddSeconds(45)
    do{
        $adapter=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object{
            $_.InterfaceDescription-match'ZeroTier'-and($_.MacAddress-eq$normalizedMac-or$_.Name-like"*$($config.networkId)*")
        }|Select-Object -First 1)[0]
        if($adapter){break}
        Start-Sleep -Milliseconds 500
    }while((Get-Date)-lt$deadline)
    if(-not$adapter){throw 'No se encontro el adaptador virtual de la red Coco.'}

    $profileSet=$false
    $deadline=(Get-Date).AddSeconds(45)
    do{
        try{
            Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory $config.profile -ErrorAction Stop
            $current=Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
            if($current.NetworkCategory-eq$config.profile){$profileSet=$true;break}
        }catch{}
        Start-Sleep -Milliseconds 500
    }while((Get-Date)-lt$deadline)
    if(-not$profileSet){throw "Windows no permitio establecer el perfil ZeroTier como $($config.profile)."}
    if($config.mode-eq'host'){
        Remove-NetFirewallRule -DisplayName $config.firewallRuleName -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $config.firewallRuleName -Direction Inbound -Action Allow -Protocol TCP `
            -LocalPort ([int]$config.minecraftPort) -RemoteAddress $config.subnet -Profile Private `
            -InterfaceAlias $adapter.Name -ErrorAction Stop|Out-Null
    }else{
        Remove-NetFirewallRule -DisplayName $config.firewallRuleName -ErrorAction SilentlyContinue
    }

    Write-Result $true 'ZeroTier configurado.' @{cli=$cli;adapter=$adapter.Name;interfaceIndex=$adapter.ifIndex;rebootRequired=$rebootRequired}
    exit 0
}catch{
    try{Write-Result $false $_.Exception.Message}catch{}
    exit 1
}
