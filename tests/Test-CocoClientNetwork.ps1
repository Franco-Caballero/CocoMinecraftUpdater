[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$networkPath=Join-Path $root 'engine\CocoNetwork.ps1'
$elevatedPath=Join-Path $root 'engine\CocoNetworkElevated.ps1'
$bootstrapPath=Join-Path $root 'bootstrap\CocoBootstrapper.ps1'
$networkText=[IO.File]::ReadAllText($networkPath)
$elevatedText=[IO.File]::ReadAllText($elevatedPath)
$bootstrapText=[IO.File]::ReadAllText($bootstrapPath)

& {
    . ([scriptblock]::Create($networkText))
    function Get-NetAdapter {
        [CmdletBinding()]param()
        [pscustomobject]@{
            Name='ZeroTier One [58997fc5f3c0c001]';InterfaceDescription='ZeroTier Virtual Port #9'
            ifIndex=42;MacAddress='02-AA-BB-CC-DD-EE';Status='Up'
        }
    }
    function Get-NetIPAddress {
        [CmdletBinding()]param([int]$InterfaceIndex,[string]$AddressFamily)
        if($InterfaceIndex-ne42-or$AddressFamily-ne'IPv4'){return}
        [pscustomobject]@{IPAddress='10.77.37.133';PrefixLength=24;AddressState='Preferred'}
    }

    $config=[pscustomobject]@{networkId='58997fc5f3c0c001'}
    $adapter=Get-CocoZeroTierAdapter $null $config.networkId
    if(-not$adapter-or$adapter.ifIndex-ne42){throw 'No se reconocio el adaptador ZeroTier sin acceso a la CLI.'}
    $synthetic=Get-CocoClientNetworkFromAdapter $adapter $config
    if(-not$synthetic-or$synthetic.status-ne'OK'-or@($synthetic.assignedAddresses)-notcontains'10.77.37.133/24'){
        throw 'No se reconocio la red cliente autorizada mediante su IP administrada.'
    }
}

if($networkText-notmatch"DisplayName\s+-eq\s+'ZeroTier One'"-or$networkText-notmatch'Get-CocoClientNetworkFromAdapter'){
    throw 'La verificacion normal todavia depende de leer la CLI administrativa.'
}
if($elevatedText-notmatch"config\.mode-eq'client'"-or$elevatedText-notmatch"network\.status-eq'OK'"-or
   $elevatedText-notmatch'assignedAddresses'-or$elevatedText-notmatch'authorizationTimeout'){
    throw 'El ayudante elevado no espera y devuelve la autorizacion completa del cliente.'
}
if($bootstrapText-notmatch'\$Silent-and\$NetworkOnly-and\(Test-Path'-or$bootstrapText-notmatch'\$cachedEntry'){
    throw 'El chequeo automatico todavia depende de descargar el manifiesto antes de iniciar el engine.'
}

$temp=Join-Path $env:TEMP ('coco-cached-network-'+[guid]::NewGuid().ToString('N'))
$oldLocalAppData=$env:LOCALAPPDATA
$oldMarker=$env:COCO_CACHE_TEST_MARKER
try{
    $cache=Join-Path $temp 'CocoMinecraftUpdater'
    $engineRoot=Join-Path $cache 'engine\cached-test'
    New-Item -ItemType Directory -Path $engineRoot -Force|Out-Null
    $marker=Join-Path $temp 'engine-ran.txt'
    $env:LOCALAPPDATA=$temp
    $env:COCO_CACHE_TEST_MARKER=$marker
    [ordered]@{
        engine=[ordered]@{version='cached-test';url='https://invalid.example/engine.zip';sha256=('a'*64)}
    }|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $cache 'latest.json') -Encoding UTF8
    [ordered]@{manifestUrl='https://invalid.example/latest.json';channel='test'}|ConvertTo-Json|
        Set-Content -LiteralPath (Join-Path $temp 'channel.json') -Encoding UTF8
    @'
param([string]$ManifestPath,[string]$ManifestUrl,[string]$GameDir,[int64]$MinecraftPid,[string]$SessionStatePath,[switch]$NetworkOnly,[switch]$Silent)
[IO.File]::WriteAllText($env:COCO_CACHE_TEST_MARKER,(Get-Content -LiteralPath $ManifestPath -Raw))
'@|Set-Content -LiteralPath (Join-Path $engineRoot 'CocoUpdater.ps1') -Encoding UTF8
    & ([scriptblock]::Create($bootstrapText)) -ChannelPath (Join-Path $temp 'channel.json') -Silent -NetworkOnly
    if(-not(Test-Path -LiteralPath $marker)){throw 'NetworkOnly no inicio el engine verificado desde cache.'}
}finally{
    $env:LOCALAPPDATA=$oldLocalAppData
    $env:COCO_CACHE_TEST_MARKER=$oldMarker
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

'PASS: cliente estándar reutiliza adaptador/IP, helper espera autorización y NetworkOnly usa caché.'
