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
$blockedModIdsPath='policy\blocked-mod-ids.txt'
if(-not(Test-Path $blockedModIdsPath)){throw 'Falta la politica de mods bloqueados.'}
$blockedModIds=@(Get-Content $blockedModIdsPath|ForEach-Object{$_.Trim()}|Where-Object{$_-and-not$_.StartsWith('#')}|Select-Object -Unique)
$publishedBlockedIds=@($manifest.packages.mods.fabricId|Where-Object{$_-and$_-in$blockedModIds}|Select-Object -Unique)
if($publishedBlockedIds.Count){throw "El manifiesto contiene IDs prohibidos: $($publishedBlockedIds -join ', ')."}
if((Get-FileHash $BootstrapExe -Algorithm SHA256).Hash.ToLowerInvariant()-ne$manifest.bootstrap.sha256){throw 'Hash de bootstrap incorrecto.'}
$engine=Join-Path $ReleaseDirectory "coco-engine-$Version.zip"
if((Get-FileHash $engine -Algorithm SHA256).Hash.ToLowerInvariant()-ne$manifest.engine.sha256){throw 'Hash del engine incorrecto.'}

$network=$manifest.network
if(-not$network-or$network.provider-ne'zerotier'){throw 'Falta la configuracion ZeroTier.'}
if($network.networkId-notmatch'^[0-9a-f]{16}$'-or$network.networkId-ne'58997fc5f3c0c001'){throw 'Network ID Coco inesperado.'}
if($network.hostAddress-ne'10.77.37.1'-or$network.subnet-ne'10.77.37.0/24'-or[int]$network.minecraftPort-ne25565-or[int]$network.sessionPort-ne25564){throw 'Endpoint Coco inesperado.'}
if($network.sessionFirewallRuleName-ne'Coco Launcher - ZeroTier TCP 25564'){throw 'Regla de sesion Coco inesperada.'}
if($network.installer.url-notmatch'^https://download\.zerotier\.com/RELEASES/1\.16\.2/'){throw 'El MSI no usa la fuente oficial versionada.'}
if($network.installer.sha256-notmatch'^[0-9a-f]{64}$'){throw 'SHA-256 de ZeroTier invalido.'}
if(-not$network.installer.signerSubjectPattern){throw 'Falta validar el firmante Authenticode de ZeroTier.'}
$pingMigration=@($manifest.clientSettingsMigrations|Where-Object{$_.id-eq'pingwheel-location-z-v1'})
if($pingMigration.Count-ne1-or$pingMigration[0].type-ne'minecraft-option-default'-or
   $pingMigration[0].key-ne'key_key.pingwheel.ping_location'-or
   $pingMigration[0].from-ne'key.mouse.5'-or$pingMigration[0].to-ne'key.keyboard.z'){
    throw 'Falta la migracion unica de Ping Wheel a Z.'
}
$managedStackable=@($manifest.managedConfigFiles|Where-Object{$_.path-eq'config/Stackable.json'})
if($managedStackable.Count-ne1){throw 'Falta la configuracion administrada de Stackable.'}
$stackableBytes=[Convert]::FromBase64String([string]$managedStackable[0].contentBase64)
if($stackableBytes.Length-ne[int64]$managedStackable[0].size){throw 'Tamano incorrecto de Stackable.json.'}
$stackableSha=[Security.Cryptography.SHA256]::Create()
try{$stackableHash=([BitConverter]::ToString($stackableSha.ComputeHash($stackableBytes))).Replace('-','').ToLowerInvariant()}finally{$stackableSha.Dispose()}
if($stackableHash-ne$managedStackable[0].sha256){throw 'Hash incorrecto de Stackable.json.'}
$stackableConfig=[Text.Encoding]::UTF8.GetString($stackableBytes)|ConvertFrom-Json
if([int]$stackableConfig.maxStack-ne256){throw 'Stackable.json no limita los stacks a 256.'}
$managedJei=@($manifest.managedConfigFiles|Where-Object{$_.path-eq'config/jei/jei-client.ini'})
if($managedJei.Count-ne1){throw 'Falta la configuracion administrada de JEI.'}
$jeiBytes=[Convert]::FromBase64String([string]$managedJei[0].contentBase64)
if($jeiBytes.Length-ne[int64]$managedJei[0].size){throw 'Tamano incorrecto de jei-client.ini.'}
$jeiSha=[Security.Cryptography.SHA256]::Create()
try{$jeiHash=([BitConverter]::ToString($jeiSha.ComputeHash($jeiBytes))).Replace('-','').ToLowerInvariant()}finally{$jeiSha.Dispose()}
if($jeiHash-ne$managedJei[0].sha256){throw 'Hash incorrecto de jei-client.ini.'}
$jeiText=[Text.Encoding]::UTF8.GetString($jeiBytes)
if($jeiText-notmatch'(?m)^\s*showHiddenIngredients\s*=\s*true\s*$'){throw 'JEI no muestra los ingredientes ocultos.'}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$engineArchive=[IO.Compression.ZipFile]::OpenRead((Resolve-Path $engine))
try{
    $entryNames=@($engineArchive.Entries|ForEach-Object{$_.FullName-replace'\\','/'})
    foreach($required in 'CocoUpdater.ps1','CocoLauncher.ps1','CocoSessionService.ps1','CocoNetwork.ps1','CocoNetworkElevated.ps1','CocoNetworkAuthorizer.ps1','launcher/catalog.json','assets/fullbody.png','assets/reynaico.ico'){
        if($entryNames-notcontains$required){throw "Falta $required en el engine."}
    }
    $launcherCatalog=Get-Content -LiteralPath 'launcher\catalog.template.json' -Raw|ConvertFrom-Json
    foreach($experience in @($launcherCatalog.experiences|Where-Object managementMode -eq 'managed')){
        $lockPaths=@([string]$experience.pack.lockPath)
        if($experience.worldTemplate){$lockPaths+=([string]$experience.worldTemplate.lockPath)}
        foreach($declaredPath in $lockPaths){
            $lockPath=$declaredPath-replace'\\','/'
            if($lockPath-notmatch'^launcher/experiences/[a-z0-9][a-z0-9.-]{1,95}\.lock\.json$'-or$entryNames-notcontains$lockPath){throw "Falta el lock de '$($experience.id)' en el engine."}
        }
    }
}finally{$engineArchive.Dispose()}

$valorantLock=Get-Content 'launcher\experiences\valorant-craft.lock.json' -Raw|ConvertFrom-Json
$valorantTools=@($valorantLock.assets|Where-Object path -eq 'mods/coco-valorant-tools-0.1.0.jar')|Select-Object -First 1
$valorantToolsPath=Join-Path (Join-Path $ReleaseDirectory 'experience-assets') 'coco-valorant-tools-0.1.0.jar'
if(-not$valorantTools-or-not(Test-Path -LiteralPath $valorantToolsPath -PathType Leaf)){throw 'Falta el asset first-party de Coco VALORANT Tools.'}
if((Get-Item -LiteralPath $valorantToolsPath).Length-ne[int64]$valorantTools.size-or
   (Get-FileHash -LiteralPath $valorantToolsPath -Algorithm SHA256).Hash.ToLowerInvariant()-ne([string]$valorantTools.sha256).ToLowerInvariant()){
    throw 'El asset first-party de Coco VALORANT Tools no coincide con su lock.'
}

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
    if(@($mods.fabricId|Where-Object{$_-eq'inventoryextended'}).Count){throw "Inventory: Extended roto sigue presente en $role."}
    if(@($mods.name|Where-Object{$_-match'(?i)coco-session-bridge'}).Count -ne 1){throw "Session Bridge debe aparecer una vez en $role."}
}
$client=@($manifest.packages|Where-Object role -eq client).mods.name
$hostMods=@($manifest.packages|Where-Object role -eq host).mods.name
if($client-match'(?i)^(e4mc|mcwifipnp|serversidehorror-|deimos-)'){throw 'El paquete cliente contiene mods exclusivos del host.'}
if(-not($hostMods-match'(?i)^e4mc')-or-not($hostMods-match'(?i)^mcwifipnp')-or-not($hostMods-match'(?i)^serversidehorror-')-or-not($hostMods-match'(?i)^deimos-')){throw 'El paquete host no contiene todos los mods exclusivos requeridos.'}

$scripts=@('bootstrap\CocoBootstrapper.ps1','engine\CocoUpdater.ps1','engine\CocoLauncher.ps1','engine\CocoSessionService.ps1','engine\CocoNetwork.ps1','engine\CocoNetworkElevated.ps1','engine\CocoNetworkAuthorizer.ps1','publisher\CocoPublisher.ps1','tools\Import-CocoCurseForgePack.ps1','tools\New-CocoJarRelease.ps1','tools\Build-CocoValorantTools.ps1','tools\Publish-CocoRelease.ps1')
foreach($script in $scripts){[void][scriptblock]::Create([IO.File]::ReadAllText((Resolve-Path $script)))}
'PASS: manifiesto, hashes, assets, roles y sintaxis validados.'
