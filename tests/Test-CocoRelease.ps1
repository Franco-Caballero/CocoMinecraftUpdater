[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$ReleaseDirectory='release',
    [string]$BootstrapExe='dist\CocoUpdater.exe'
)

$ErrorActionPreference='Stop'
$manifestPath=Join-Path $ReleaseDirectory 'latest.json'
if(-not(Test-Path $manifestPath)){throw 'Falta latest.json.'}
$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json
if($manifest.version -ne $Version -or $manifest.schemaVersion -ne 2){throw 'Version o esquema incorrecto en latest.json.'}
if((Get-FileHash $BootstrapExe -Algorithm SHA256).Hash.ToLowerInvariant()-ne$manifest.bootstrap.sha256){throw 'Hash de bootstrap incorrecto.'}
$engine=Join-Path $ReleaseDirectory "coco-engine-$Version.zip"
if((Get-FileHash $engine -Algorithm SHA256).Hash.ToLowerInvariant()-ne$manifest.engine.sha256){throw 'Hash del engine incorrecto.'}

$network=$manifest.network
if(-not$network-or$network.provider-ne'zerotier'){throw 'Falta la configuracion ZeroTier.'}
if($network.networkId-notmatch'^[0-9a-f]{16}$'-or$network.networkId-ne'58997fc5f3c0c001'){throw 'Network ID Coco inesperado.'}
if($network.hostAddress-ne'10.77.37.1'-or$network.subnet-ne'10.77.37.0/24'-or[int]$network.minecraftPort-ne25565){throw 'Endpoint Coco inesperado.'}
if($network.installer.url-notmatch'^https://download\.zerotier\.com/RELEASES/1\.16\.2/'){throw 'El MSI no usa la fuente oficial versionada.'}
if($network.installer.sha256-notmatch'^[0-9a-f]{64}$'){throw 'SHA-256 de ZeroTier invalido.'}
if(-not$network.installer.signerSubjectPattern){throw 'Falta validar el firmante Authenticode de ZeroTier.'}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$engineArchive=[IO.Compression.ZipFile]::OpenRead((Resolve-Path $engine))
try{
    $entryNames=@($engineArchive.Entries|ForEach-Object{$_.FullName-replace'\\','/'})
    foreach($required in 'CocoUpdater.ps1','CocoNetwork.ps1','CocoNetworkElevated.ps1','CocoNetworkAuthorizer.ps1','assets/fullbody.png','assets/reynaico.ico'){
        if($entryNames-notcontains$required){throw "Falta $required en el engine."}
    }
}finally{$engineArchive.Dispose()}

foreach($role in 'client','host'){
    $package=@($manifest.packages|Where-Object role -eq $role)
    if($package.Count -ne 1){throw "Debe existir exactamente un paquete $role."}
    $mods=@($package[0].mods)
    if(-not$mods.Count){throw "El paquete $role esta vacio."}
    if(@($mods|Group-Object name|Where-Object Count -gt 1).Count){throw "Hay nombres repetidos en $role."}
    if(@($mods|Group-Object sha256|Where-Object Count -gt 1).Count){throw "Hay contenido repetido en $role."}
    foreach($mod in $mods){
        if($mod.url -notmatch '/releases/download/mod-assets/mod-[0-9a-f]{64}\.jar$'){throw "URL no incremental para $($mod.name)."}
        $asset=Join-Path (Join-Path $ReleaseDirectory 'jars') "mod-$($mod.sha256).jar"
        if(-not(Test-Path $asset)){throw "Falta el asset de $($mod.name)."}
        if((Get-Item $asset).Length-ne[int64]$mod.size){throw "Tamano incorrecto para $($mod.name)."}
        if((Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant()-ne$mod.sha256){throw "Hash incorrecto para $($mod.name)."}
    }
    if(@($mods.name|Where-Object{$_-match'(?i)fly-speed-modifier'}).Count){throw "fly-speed-modifier roto sigue presente en $role."}
    if(@($mods.name|Where-Object{$_-match'(?i)coco-session-bridge'}).Count -ne 1){throw "Session Bridge debe aparecer una vez en $role."}
}
$client=@($manifest.packages|Where-Object role -eq client).mods.name
$hostMods=@($manifest.packages|Where-Object role -eq host).mods.name
if($client-match'(?i)^(e4mc|mcwifipnp)'){throw 'El paquete cliente contiene mods exclusivos del host.'}
if(-not($hostMods-match'(?i)^e4mc')-or-not($hostMods-match'(?i)^mcwifipnp')){throw 'El paquete host no contiene e4mc/mcwifipnp.'}

$scripts=@('bootstrap\CocoBootstrapper.ps1','engine\CocoUpdater.ps1','engine\CocoNetwork.ps1','engine\CocoNetworkElevated.ps1','engine\CocoNetworkAuthorizer.ps1','publisher\CocoPublisher.ps1','tools\New-CocoJarRelease.ps1','tools\Publish-CocoRelease.ps1')
foreach($script in $scripts){[void][scriptblock]::Create([IO.File]::ReadAllText((Resolve-Path $script)))}
'PASS: manifiesto, hashes, assets, roles y sintaxis validados.'
