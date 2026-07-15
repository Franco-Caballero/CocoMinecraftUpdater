[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MinecraftRoot,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$GitHubRepository,
    [Parameter(Mandatory=$true)][string]$ReleaseDirectory,
    [Parameter(Mandatory=$true)][string]$BridgeJar,
    [Parameter(Mandatory=$true)][string]$BootstrapExe,
    [string[]]$ClientExcludePatterns=@('(?i)^e4mc','(?i)^mcwifipnp','(?i)^serversidehorror-','(?i)^deimos-','(?i)^coco-session-bridge-','(?i)^fly-speed-modifier-'),
    [string[]]$HostExcludePatterns=@('(?i)^coco-session-bridge-','(?i)^fly-speed-modifier-'),
    [string[]]$KnownE4mcDomains=@()
)

$ErrorActionPreference='Stop'
$tag="v$Version"
$jarOutput=Join-Path $ReleaseDirectory 'jars'
New-Item -ItemType Directory -Path $jarOutput -Force|Out-Null
Get-ChildItem -LiteralPath $jarOutput -File -ErrorAction SilentlyContinue|Remove-Item -Force

function Test-Excluded([string]$Name,[string[]]$Patterns) {
    return [bool]@($Patterns|Where-Object{$Name -match $_}).Count
}
function Get-FabricModId([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry=$archive.GetEntry('fabric.mod.json')
        if(-not$entry){return $null}
        $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
        try { return ($reader.ReadToEnd()|ConvertFrom-Json).id } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}
function Get-RoleMods([string]$Role,[string[]]$ExcludePatterns) {
    $files=[System.Collections.Generic.List[IO.FileInfo]]::new()
    Get-ChildItem -LiteralPath (Join-Path $MinecraftRoot 'mods') -File -Filter '*.jar'|Where-Object{
        -not (Test-Excluded $_.Name $ExcludePatterns)
    }|ForEach-Object{$files.Add($_)}
    $files.Add((Get-Item -LiteralPath $BridgeJar))
    $prepared=@($files|ForEach-Object{
        [pscustomobject]@{
            File=$_
            Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            ModId=Get-FabricModId $_.FullName
        }
    })
    $conflicts=@($prepared|Where-Object ModId|Group-Object ModId|Where-Object{(@($_.Group.Hash|Select-Object -Unique)).Count -gt 1})
    if($conflicts){throw "Hay IDs Fabric repetidos con contenido diferente para $Role`: $($conflicts.Name -join ', ')"}
    $deduplicated=@($prepared|Group-Object Hash|ForEach-Object{
        $_.Group|Sort-Object @{Expression={if($_.File.BaseName -match '\(\d+\)$'){1}else{0}}},@{Expression={$_.File.Name.Length}},@{Expression={$_.File.Name}}|Select-Object -First 1
    })
    return @($deduplicated|Sort-Object {$_.File.Name}|ForEach-Object{
        $hash=$_.Hash
        $file=$_.File
        $assetName="mod-$hash.jar"
        $destination=Join-Path $jarOutput $assetName
        if(-not(Test-Path -LiteralPath $destination)){Copy-Item -LiteralPath $file.FullName -Destination $destination -Force}
        [ordered]@{
            name=$file.Name
            fabricId=$_.ModId
            url="https://github.com/$GitHubRepository/releases/download/mod-assets/$assetName"
            sha256=$hash
            size=[int64]$file.Length
        }
    })
}

$clientMods=Get-RoleMods 'client' $ClientExcludePatterns
$hostMods=Get-RoleMods 'host' $HostExcludePatterns
$managedConfigRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'managed-config'
if(-not(Test-Path -LiteralPath $managedConfigRoot)){throw "Falta el directorio de configuracion administrada: $managedConfigRoot"}
$managedConfigFiles=@(Get-ChildItem -LiteralPath $managedConfigRoot -Recurse -File|Sort-Object FullName|ForEach-Object{
    $relative=$_.FullName.Substring($managedConfigRoot.Length).TrimStart('\','/')-replace'\\','/'
    $bytes=[IO.File]::ReadAllBytes($_.FullName)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    [ordered]@{
        path="config/$relative"
        sha256=$hash
        size=[int64]$bytes.Length
        contentBase64=[Convert]::ToBase64String($bytes)
    }
})
if(-not@($managedConfigFiles|Where-Object{$_.path-eq'config/Stackable.json'})){throw 'Falta managed-config\Stackable.json.'}
$enginePath=Join-Path $ReleaseDirectory "coco-engine-$Version.zip"
if(-not(Test-Path $enginePath)){throw "Falta $enginePath"}
$manifest=[ordered]@{
    schemaVersion=2; packId='coco-fabric-26.1.2'; version=$Version
    publishedAt=(Get-Date).ToUniversalTime().ToString('o')
    engine=[ordered]@{
        version=$Version
        url="https://github.com/$GitHubRepository/releases/download/$tag/coco-engine-$Version.zip"
        sha256=(Get-FileHash $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
        size=[int64](Get-Item $enginePath).Length
    }
    bootstrap=[ordered]@{
        version=$Version
        url="https://github.com/$GitHubRepository/releases/download/$tag/CocoUpdater.exe"
        sha256=(Get-FileHash -LiteralPath $BootstrapExe -Algorithm SHA256).Hash.ToLowerInvariant()
        size=[int64](Get-Item -LiteralPath $BootstrapExe).Length
    }
    network=[ordered]@{
        provider='zerotier';name='Coco Minecraft';networkId='58997fc5f3c0c001'
        hostAddress='10.77.37.1';subnet='10.77.37.0/24'
        ipPoolStart='10.77.37.2';ipPoolEnd='10.77.37.254'
        minecraftPort=25565;authorizationTimeoutSeconds=120
        firewallRuleName='Coco Minecraft - ZeroTier TCP 25565'
        leaveNetworkIds=@('154a350c866b8062')
        installer=[ordered]@{
            version='1.16.2'
            url='https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi'
            sha256='42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'
            signerSubjectPattern='(?i)ZEROTIER,\s*INC\.'
        }
    }
    clientSettingsMigrations=@(
        [ordered]@{
            id='pingwheel-location-z-v1'
            type='minecraft-option-default'
            key='key_key.pingwheel.ping_location'
            from='key.mouse.5'
            to='key.keyboard.z'
        }
    )
    managedConfigFiles=$managedConfigFiles
    packages=@(
        [ordered]@{role='client';mods=$clientMods},
        [ordered]@{role='host';mods=$hostMods}
    )
    detector=[ordered]@{
        minecraftVersion='26.1.2';markerPath='config/coco-updater-state.json'
        groupTokens=@('smolbird','nadicon','nazorepulgadora','cuisinho2','Shayjiji','Shukaloslw','ZoeSokolov88')
        knownE4mcDomains=@($KnownE4mcDomains)
        modRules=@(
            [ordered]@{name='Sodium';pattern='(?i)^sodium-.*26\.1\.2.*\.jar$';weight=15},
            [ordered]@{name='Iris';pattern='(?i)^iris-.*26\.1\.2.*\.jar$';weight=15},
            [ordered]@{name='JourneyMap';pattern='(?i)^journeymap-.*26\.1\.2.*\.jar$';weight=20},
            [ordered]@{name='Distant Horizons';pattern='(?i)^DistantHorizons-.*26\.1\.2.*\.jar$';weight=20},
            [ordered]@{name='Fabric API';pattern='(?i)^fabric-api-.*26\.1\.2.*\.jar$';weight=10}
        )
    }
}
$manifestJson=$manifest|ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $ReleaseDirectory 'latest.json'),$manifestJson,(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{version=$Version;clientMods=$clientMods.Count;hostMods=$hostMods.Count;uniqueAssets=@(Get-ChildItem $jarOutput).Count}|ConvertTo-Json
