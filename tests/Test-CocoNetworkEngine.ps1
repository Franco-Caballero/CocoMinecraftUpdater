[CmdletBinding()]
param([string]$MinecraftRoot="$env:APPDATA\.minecraft")

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$markerPath=Join-Path $MinecraftRoot 'config\coco-updater-state.json'
if(-not(Test-Path -LiteralPath $markerPath)){throw 'Falta el estado instalado del host para la prueba end-to-end.'}
$marker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
$mods=@(Get-ChildItem -LiteralPath (Join-Path $MinecraftRoot 'mods') -File -Filter '*.jar'|Sort-Object Name|ForEach-Object{
    [ordered]@{
        name=$_.Name;url='https://invalid.local/not-used'
        sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        size=[int64]$_.Length
    }
})
$manifest=[ordered]@{
    schemaVersion=2;packId=[string]$marker.packId;version=[string]$marker.version
    network=[ordered]@{
        provider='zerotier';name='Coco Minecraft';networkId='58997fc5f3c0c001'
        hostAddress='10.77.37.1';subnet='10.77.37.0/24'
        ipPoolStart='10.77.37.2';ipPoolEnd='10.77.37.254'
        minecraftPort=25565;authorizationTimeoutSeconds=30
        firewallRuleName='Coco Minecraft - ZeroTier TCP 25565'
        leaveNetworkIds=@('154a350c866b8062')
        installer=[ordered]@{
            version='1.16.2'
            url='https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi'
            sha256='42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'
            signerSubjectPattern='(?i)ZEROTIER,\s*INC\.'
        }
    }
    packages=@([ordered]@{role='host';mods=$mods})
    detector=[ordered]@{
        minecraftVersion='26.1.2';markerPath='config/coco-updater-state.json'
        groupTokens=@();knownE4mcDomains=@();modRules=@()
    }
}
$temp=Join-Path $env:TEMP "coco-network-engine-$([guid]::NewGuid().ToString('N')).json"
try{
    [IO.File]::WriteAllText($temp,($manifest|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    $engine=Join-Path $root 'engine\CocoUpdater.ps1'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$engine+'"'),'-ManifestPath',('"'+$temp+'"'),'-GameDir',('"'+$MinecraftRoot+'"'),'-Silent')
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    if($process.ExitCode-ne0){throw "CocoUpdater fallo la prueba end-to-end de red con codigo $($process.ExitCode)."}
}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}

$config=Get-Content -LiteralPath (Join-Path $MinecraftRoot 'config\coco-network.json') -Raw|ConvertFrom-Json
if($config.address-ne'10.77.37.1:25565'-or$config.role-ne'host'){throw 'CocoUpdater no persistio el endpoint estable del host.'}
$lan=Get-Content -LiteralPath (Join-Path $MinecraftRoot 'saves\coco\mcwifipnp.json') -Raw|ConvertFrom-Json
if([int]$lan.port-ne25565-or$lan.'enable-upnp'){throw 'CocoUpdater no fijo MCWiFiPnP en TCP 25565 sin UPnP.'}
'PASS: CocoUpdater preparo y verifico la red del host sin alterar el pack.'
