[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Version,
    [Parameter(Mandatory = $true)] [string]$GitHubRepository,
    [Parameter(Mandatory = $true)] [string]$ReleaseDirectory,
    [string]$Tag = "v$Version",
    [string[]]$KnownE4mcDomains = @()
)

$ErrorActionPreference = 'Stop'

function Get-Asset([string]$FileName, [string]$Role) {
    $path = Join-Path $ReleaseDirectory $FileName
    if (-not (Test-Path $path)) { throw "No se encontro el asset: $path" }
    [pscustomobject]@{
        role = $Role
        url = "https://github.com/$GitHubRepository/releases/download/$Tag/$FileName"
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        size = (Get-Item -LiteralPath $path).Length
    }
}

$engine = Get-Asset "coco-engine-$Version.zip" 'engine'
$client = Get-Asset "coco-client-$Version.zip" 'client'
$hostAsset = Get-Asset "coco-host-$Version.zip" 'host'

$manifest = [ordered]@{
    schemaVersion = 1
    packId = 'coco-fabric-26.1.2'
    version = $Version
    publishedAt = (Get-Date).ToUniversalTime().ToString('o')
    engine = [ordered]@{
        version = $Version
        url = $engine.url
        sha256 = $engine.sha256
        size = $engine.size
    }
    network = [ordered]@{
        provider = 'zerotier'; name = 'Coco Minecraft'; networkId = '58997fc5f3c0c001'
        hostAddress = '10.77.37.1'; subnet = '10.77.37.0/24'
        ipPoolStart = '10.77.37.2'; ipPoolEnd = '10.77.37.254'
        minecraftPort = 25565; authorizationTimeoutSeconds = 120
        firewallRuleName = 'Coco Minecraft - ZeroTier TCP 25565'
        leaveNetworkIds = @('154a350c866b8062')
        installer = [ordered]@{
            version = '1.16.2'
            url = 'https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi'
            sha256 = '42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670'
            signerSubjectPattern = '(?i)ZEROTIER,\s*INC\.'
        }
    }
    packages = @(
        [ordered]@{ role = 'client'; url = $client.url; sha256 = $client.sha256; size = $client.size },
        [ordered]@{ role = 'host'; url = $hostAsset.url; sha256 = $hostAsset.sha256; size = $hostAsset.size }
    )
    detector = [ordered]@{
        minecraftVersion = '26.1.2'
        markerPath = 'config/coco-updater-state.json'
        groupTokens = @('smolbird', 'nadicon', 'nazorepulgadora', 'cuisinho2', 'Shayjiji', 'Shukaloslw', 'ZoeSokolov88')
        knownE4mcDomains = @($KnownE4mcDomains)
        modRules = @(
            [ordered]@{ name = 'Sodium'; pattern = '(?i)^sodium-.*26\.1\.2.*\.jar$'; weight = 15 },
            [ordered]@{ name = 'Iris'; pattern = '(?i)^iris-.*26\.1\.2.*\.jar$'; weight = 15 },
            [ordered]@{ name = 'JourneyMap'; pattern = '(?i)^journeymap-.*26\.1\.2.*\.jar$'; weight = 20 },
            [ordered]@{ name = 'Distant Horizons'; pattern = '(?i)^DistantHorizons-.*26\.1\.2.*\.jar$'; weight = 20 },
            [ordered]@{ name = 'Fabric API'; pattern = '(?i)^fabric-api-.*26\.1\.2.*\.jar$'; weight = 10 }
        )
    }
}

$output = Join-Path $ReleaseDirectory 'latest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output -Encoding UTF8
Write-Output $output
