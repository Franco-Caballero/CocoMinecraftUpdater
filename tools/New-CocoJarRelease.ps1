[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$MinecraftRoot,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$GitHubRepository,
    [Parameter(Mandatory=$true)][string]$ReleaseDirectory,
    [Parameter(Mandatory=$true)][string]$BridgeJar,
    [Parameter(Mandatory=$true)][string]$BootstrapExe,
    [string[]]$ClientExcludePatterns=@('(?i)^e4mc','(?i)^mcwifipnp','(?i)^coco-session-bridge-'),
    [string[]]$HostExcludePatterns=@('(?i)^coco-session-bridge-'),
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
function Get-RoleMods([string]$Role,[string[]]$ExcludePatterns) {
    $files=[System.Collections.Generic.List[IO.FileInfo]]::new()
    Get-ChildItem -LiteralPath (Join-Path $MinecraftRoot 'mods') -File -Filter '*.jar'|Where-Object{
        -not (Test-Excluded $_.Name $ExcludePatterns)
    }|ForEach-Object{$files.Add($_)}
    $files.Add((Get-Item -LiteralPath $BridgeJar))
    return @($files|Sort-Object Name|ForEach-Object{
        $hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $assetName="mod-$hash.jar"
        $destination=Join-Path $jarOutput $assetName
        if(-not(Test-Path -LiteralPath $destination)){Copy-Item -LiteralPath $_.FullName -Destination $destination -Force}
        [ordered]@{
            name=$_.Name
            url="https://github.com/$GitHubRepository/releases/download/$tag/$assetName"
            sha256=$hash
            size=[int64]$_.Length
        }
    })
}

$clientMods=Get-RoleMods 'client' $ClientExcludePatterns
$hostMods=Get-RoleMods 'host' $HostExcludePatterns
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
$manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $ReleaseDirectory 'latest.json') -Encoding UTF8
[pscustomobject]@{version=$Version;clientMods=$clientMods.Count;hostMods=$hostMods.Count;uniqueAssets=@(Get-ChildItem $jarOutput).Count}|ConvertTo-Json
