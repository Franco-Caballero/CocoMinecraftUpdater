[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
if($launcherText-match'compatibility\.status'){throw 'El engine aun contiene puertas de visibilidad o lanzamiento por estado.'}
$template=Join-Path $root 'launcher\catalog.template.json'
$catalog=Read-CocoLauncherCatalog $template
$importerText=[IO.File]::ReadAllText((Join-Path $root 'tools\Import-CocoCurseForgePack.ps1'))
if($importerText-match'(?s)entry\.required\)\s*\{\s*throw'-or
    $importerText-notmatch'manifestRequired=\[bool\]\$entry\.required'){
    throw 'El importador no conserva todas las dependencias requeridas y opcionales.'
}
$devHelperText=[IO.File]::ReadAllText((Join-Path $root 'tools\Invoke-CocoExperienceDev.ps1'))
[void][ScriptBlock]::Create($devHelperText)
foreach($required in 'ExperienceId','Prepare','Launch','-Live','Invoke-CocoManagedExperienceLaunch'){
    if($devHelperText-notmatch[regex]::Escape($required)){throw "El helper rapido de experiencias no contiene '$required'."}
}
if($devHelperText-match"ExperienceId\\s*=\\s*'[^']+'"){throw 'El helper rapido quedo hardcodeado a una experiencia.'}
if($catalog.releaseStatus-ne'development'-and$catalog.releaseStatus-ne'approved'){throw 'El catalogo debe declarar development o approved.'}
if($catalog.catalogVersion-ne'0.4.0'){throw 'El catalogo no refleja el schema de contenido episodico.'}
if($catalog.experiences[0].id-ne'coco-original'-or$catalog.backend.version-ne'5.0.4'-or$catalog.backend.commit-ne'0718735'){
    throw 'El catalogo inicial no conserva Coco original o el backend fijado.'
}
$original=@($catalog.experiences|Where-Object id -eq 'coco-original'|Select-Object -First 1)[0]
if($original.managementMode-ne'legacy-current'-or$original.launch.workflow-ne'external-launcher'-or[bool]$original.launch.autoJoin){
    throw 'Coco original no quedo reservado al launcher habitual sin autoingreso Coco.'
}
if($catalog.sessionPolicy.maximumConcurrentSessions-ne1-or$catalog.sessionPolicy.clientSelection-ne'automatic'-or$catalog.sessionPolicy.offlineBehavior-ne'show-no-session'){
    throw 'El catalogo inicial no exige seleccion automatica de la unica sesion Coco.'
}
if($catalog.sessionDiscovery.host-ne'10.77.37.1'-or$catalog.sessionDiscovery.port-ne25564-or$catalog.sessionDiscovery.protocol-ne'coco-session-v1'){
    throw 'El catalogo inicial no fija el descubrimiento privado de sesion.'
}
$dread=@($catalog.experiences|Where-Object id -eq 'dread-arrenek'|Select-Object -First 1)[0]
if(-not$dread-or$dread.runtime.minecraftVersion-ne'1.19.2'-or$dread.runtime.loader-ne'forge'-or$dread.managementMode-ne'managed'-or$dread.launch.workflow-ne'coco-managed'){
    throw 'DREAD - A Horror Survival Pack no esta fijado como experiencia Forge administrada.'
}
$dreadLock=Read-CocoExperienceLock (Join-Path $root (($dread.pack.lockPath)-replace'/','\')) $dread
if(@($dreadLock.assets).Count-ne152){throw 'El lock oficial de DREAD no contiene los 152 assets esperados.'}
$backrooms=@($catalog.experiences|Where-Object id -eq 'into-the-backrooms'|Select-Object -First 1)[0]
$cobbleverse=@($catalog.experiences|Where-Object id -eq 'cobbleverse'|Select-Object -First 1)[0]
$zombie=@($catalog.experiences|Where-Object id -eq 'zombie-apocalypse-slow-zombies'|Select-Object -First 1)[0]
$nightfallcraft=@($catalog.experiences|Where-Object id -eq 'nightfallcraft'|Select-Object -First 1)[0]
if(-not$cobbleverse-or
    $cobbleverse.runtime.minecraftVersion-ne'1.21.1'-or$cobbleverse.runtime.loader-ne'fabric'-or
    $cobbleverse.runtime.loaderVersion-ne'0.18.4'){
    throw 'COBBLEVERSE no esta habilitado como experiencia Fabric 1.21.1.'
}
if(-not$nightfallcraft-or
    $nightfallcraft.runtime.minecraftVersion-ne'1.20.1'-or$nightfallcraft.runtime.loader-ne'forge'-or
    $nightfallcraft.runtime.loaderVersion-ne'47.4.4'){
    throw 'NightfallCraft no esta habilitado como experiencia Forge 1.20.1.'
}
if($zombie.hosting.adapter-ne'lan-server-properties-v1'){
    throw 'Zombie 1.12.2 no esta habilitado con su adaptador LAN legado.'
}
$valorantcraft=@($catalog.experiences|Where-Object id -eq 'valorant-craft'|Select-Object -First 1)[0]
if(-not$valorantcraft-or$valorantcraft.runtime.minecraftVersion-ne'1.20.1'-or$valorantcraft.runtime.loader-ne'forge'-or
    $valorantcraft.runtime.loaderVersion-ne'47.4.4'-or$valorantcraft.pack.sourcePage-ne'https://www.curseforge.com/minecraft/mc-mods/csmain'){
    throw 'VALORANTCraft no esta fijado al runtime y fuente oficiales de CSmain.'
}
$valorantLock=Read-CocoExperienceLock (Join-Path $root (($valorantcraft.pack.lockPath)-replace'/','\')) $valorantcraft
if($valorantLock.pack.mode-ne'assets-only'-or$valorantLock.pack.archive){throw 'VALORANTCraft debe usar una composicion de assets sin archive ficticio.'}
$valorantRequiredPaths=@(
    'mods/csmain-1.0.0-beta.1.jar',
    'mods/tacz-1.20.1-1.1.8-hotfix.jar',
    'tacz/Valorant_gunpack_v0.1.3_hotfix_4.zip',
    'mods/origins-forge-1.20.1-1.10.0.9-all.jar',
    'mods/Valorant_Origins+forge1.20.1+1.4.0.jar',
    'mods/coco-valorant-tools-0.1.0.jar'
)
foreach($requiredPath in $valorantRequiredPaths){
    $match=@($valorantLock.assets|Where-Object path -eq $requiredPath)
    if($match.Count-ne1-or$match[0].role-ne'all'){throw "VALORANTCraft no fija el asset requerido '$requiredPath' para ambos roles."}
}
$valorantCsmain=@($valorantLock.assets|Where-Object path -eq 'mods/csmain-1.0.0-beta.1.jar')[0]
if($valorantCsmain.sourceUrl-ne'https://www.curseforge.com/api/v1/mods/1472644/files/7682938/download'-or
    $valorantCsmain.sha256-ne'a263470939a773b3aa7bb9fe88ec071930e77cd4c8958a40422e5ea249fab7f3'){
    throw 'CSmain no esta fijado al archivo CurseForge verificado.'
}
$valorantTools=@($valorantLock.assets|Where-Object path -eq 'mods/coco-valorant-tools-0.1.0.jar')[0]
if($valorantTools.sourceUrl-ne'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.5.78/coco-valorant-tools-0.1.0.jar'-or
    $valorantTools.sha256-ne'97d07c264ca138021b44919863a8849e348ee324edcffd7e879878b21453f9cc'-or
    [int64]$valorantTools.size-ne15531){
    throw 'Coco VALORANT Tools no esta fijado al JAR first-party compilado.'
}
$valorantStateFile=@($valorantcraft.preferences.managedFiles|Where-Object path -eq 'config/killfeedtacz_state.json')
if($valorantStateFile.Count-ne1-or$valorantStateFile[0].writeMode-ne'initialize'){
    throw 'La configuracion persistente de CSmain debe inicializarse una vez y conservar los spawns del mapa.'
}
$valorantOriginsFile=@($valorantcraft.preferences.managedFiles|Where-Object path -eq 'config/origins.json')
if($valorantOriginsFile.Count-ne1-or[string]$valorantOriginsFile[0].content-notmatch'disableDefaultOrigins\"\s*:\s*true'){
    throw 'VALORANTCraft debe desactivar los origenes base y conservar solo la capa de agentes.'
}
$valorantKeys=$valorantcraft.preferences.keybindings
if([string]$valorantKeys.'key_key.origins.primary_active'-ne'key.keyboard.c'-or
   [string]$valorantKeys.'key_key.origins.secondary_active'-ne'key.keyboard.x'-or
   [string]$valorantKeys.'key_key.coco_valorant_tools.menu'-ne'key.keyboard.m'-or
   [string]$valorantKeys.'key_key.tacz.inspect.desc'-ne'key.keyboard.y'-or
   [string]$valorantKeys.'key_key.killfeedtacz.shop'-ne'key.keyboard.b'-or
   [string]$valorantKeys.'key_key.tacz.reload.desc'-ne'key.keyboard.r'-or
   [string]$valorantKeys.'key_iris.keybind.reload'-ne'key.keyboard.f8'-or
   [string]$valorantKeys.'key_iris.keybind.shaderPackSelection'-ne'key.keyboard.f7'){
    throw 'VALORANTCraft no declara el layout de controles sin conflictos.'
}
try{$valorantState=[string]$valorantStateFile[0].content|ConvertFrom-Json}catch{throw 'La configuracion declarativa de CSmain no es JSON valido.'}
$valorantShop=@($valorantState.shop)
if($valorantState.startItemAll-ne'shop:knife'-or
    $valorantShop.Count-ne10-or
    @($valorantShop|Where-Object{$_.itemId-eq'tacz:modern_kinetic_gun'}).Count-ne7-or
    @($valorantShop|Where-Object{$_.templateSnbt-match'valorant:(classic|ghost|sheriff|vandal|phantom|operator|odin)'}).Count-ne7-or
    @($valorantShop|Where-Object{$_.id-eq'knife'-and$_.itemId-eq'lrtactical:melee'-and$_.enabled-eq$false-and$_.templateSnbt-match'MeleeWeaponId.*killfeedtacz_knife:1b'}).Count-ne1){
    throw 'La tienda de CSmain no contiene el arsenal Valorant y el cuchillo inicial fijados.'
}
$managedExperiences=@($catalog.experiences|Where-Object managementMode -eq 'managed')
if($managedExperiences.Count-ne17-or
    @($managedExperiences|Where-Object{$_.PSObject.Properties.Name-contains'compatibility'}).Count){
    throw 'Todas las experiencias deben estar visibles por presencia en catalogo, sin estados de bloqueo/experimento.'
}
foreach($managed in $managedExperiences){
    $imagePath=if($managed.ui){[string]$managed.ui.imagePath}else{''}
    if([string]::IsNullOrWhiteSpace($imagePath)-or-not(Test-CocoSafeRelativePath $imagePath)-or$imagePath-notmatch'^assets/experiences/[a-z0-9][a-z0-9.-]+\.(jpg|jpeg|png)$'){
        throw "La experiencia '$($managed.id)' no declara una portada segura en assets/experiences."
    }
    $imageFile=Join-Path $root ($imagePath-replace'/','\')
    if(-not(Test-Path -LiteralPath $imageFile -PathType Leaf)){throw "Falta la portada de '$($managed.id)': $imageFile"}
    $image=$null
    try{$image=[Drawing.Image]::FromFile($imageFile)}catch{throw "La portada de '$($managed.id)' no es una imagen valida."}finally{if($image){$image.Dispose()}}
}
$heartSignal=@($catalog.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
if(-not$heartSignal-or$heartSignal.runtime.type-ne'media'-or$heartSignal.launch.workflow-ne'coco-media'-or
   $heartSignal.content.type-ne'episodic-video'-or$heartSignal.content.downloadFolderName-ne'heart signal'){
    throw 'Heart Signal no esta declarado como contenido episodico local.'
}
$heartEpisodes=@($heartSignal.content.episodes)
if($heartEpisodes.Count-ne4){throw 'Heart Signal debe mostrar las dos partes del E01 y las dos partes del E02 como episodios separados.'}
$heartEpisode1=@($heartEpisodes|Where-Object id -eq 's05e01-p01'|Select-Object -First 1)[0]
if(-not$heartEpisode1-or$heartEpisode1.title-ne'Temporada 5 - Episodio 1 - Parte 1'-or
   $heartEpisode1.fileName-ne'Heart Signal - S05E01 - Parte 1.mp4'-or[int64]$heartEpisode1.size-ne1837932680-or
   $heartEpisode1.sha256-ne'fd9f418b00b06a56159d7e07d90cb953c3c5f94c9f7ceb32b2a899acb88b21a4'-or
   $heartEpisode1.streamUrl-notmatch'^https://' -or$heartEpisode1.sourceUrl-notmatch'^https://'){
    throw 'La Parte 1 del E01 de Heart Signal no conserva la metadata o URL publicada.'
}
$heartEpisode2=@($heartEpisodes|Where-Object id -eq 's05e01-p02'|Select-Object -First 1)[0]
if(-not$heartEpisode2-or$heartEpisode2.title-ne'Temporada 5 - Episodio 1 - Parte 2'-or
   $heartEpisode2.fileName-ne'Heart Signal - S05E01 - Parte 2.mp4'-or[int64]$heartEpisode2.size-ne1829237387-or
   $heartEpisode2.sha256-ne'714412a27a5429373e278ed4c1180e229721cc3b4afe212e436aa45496abdc1a'-or
   $heartEpisode2.streamUrl-notmatch'^https://' -or$heartEpisode2.sourceUrl-notmatch'^https://'){
    throw 'La Parte 2 del E01 de Heart Signal no conserva la metadata o URL publicada.'
}
$heartEpisode3=@($heartEpisodes|Where-Object id -eq 's05e02-p01'|Select-Object -First 1)[0]
if(-not$heartEpisode3-or$heartEpisode3.title-ne'Temporada 5 - Episodio 2 - Parte 1'-or
   $heartEpisode3.fileName-ne'Heart Signal - S05E02 - Parte 1.mp4'-or[int64]$heartEpisode3.size-ne1905582124-or
   $heartEpisode3.sha256-ne'fae2f0a69cb7a19ca0ebb373c338f9a24c3be23a41c11e2b91b1c12688a0cf9a'-or
   $heartEpisode3.streamUrl-notmatch'^https://' -or$heartEpisode3.sourceUrl-notmatch'^https://'){
    throw 'La Parte 1 del E02 de Heart Signal no conserva la metadata o URL publicada.'
}
$heartEpisode4=@($heartEpisodes|Where-Object id -eq 's05e02-p02'|Select-Object -First 1)[0]
if(-not$heartEpisode4-or$heartEpisode4.title-ne'Temporada 5 - Episodio 2 - Parte 2'-or
   $heartEpisode4.fileName-ne'Heart Signal - S05E02 - Parte 2.mp4'-or[int64]$heartEpisode4.size-ne1898887829-or
   $heartEpisode4.sha256-ne'd86985cace867d75e73e166814e86c96a8ced2a28ff719ed8e04bf3874a8620d'-or
   $heartEpisode4.streamUrl-notmatch'^https://' -or$heartEpisode4.sourceUrl-notmatch'^https://'){
    throw 'La Parte 2 del E02 de Heart Signal no conserva la metadata o URL publicada.'
}
$bounds=for($i=0;$i-lt$managedExperiences.Count;$i++){Get-CocoExperienceButtonBounds $i}
for($i=0;$i-lt$bounds.Count;$i++){
    if($i -lt 4 -and ($bounds[$i].Left-lt0-or$bounds[$i].Right-gt570-or$bounds[$i].Top-lt0-or$bounds[$i].Bottom-gt100)){
        throw "El boton visible $i escapa del area sin scroll del selector."
    }
    for($j=$i+1;$j-lt$bounds.Count;$j++){
        if($bounds[$i].IntersectsWith($bounds[$j])){throw "Los botones $i y $j se superponen."}
    }
}
$selectorFont=New-Object Drawing.Font('Segoe UI Semibold',8.5)
try{
    foreach($managed in $managedExperiences){
        $measured=[Windows.Forms.TextRenderer]::MeasureText([string]$managed.name,$selectorFont,[Drawing.Size]::new(235,36),[Windows.Forms.TextFormatFlags]::WordBreak)
        if($measured.Width-gt235-or$measured.Height-gt36){throw "El nombre '$($managed.name)' no cabe en su boton visible."}
    }
}finally{$selectorFont.Dispose()}
if($launcherText-notmatch'AutoScrollMinSize=.*hostExperiences\.Count'){throw 'El selector no habilita scroll al crecer mas alla de cuatro experiencias.'}
if($catalog.globalPolicies.essential.mode-ne'exclude'-or$catalog.globalPolicies.customSkinLoader.mode-ne'required'){
    throw 'Essential y CustomSkinLoader no tienen politica global obligatoria.'
}
if(@($catalog.globalPolicies.customSkinLoader.variants).Count-ne1-or
    '1.12.2'-notin@($catalog.globalPolicies.customSkinLoader.variants[0].minecraftVersions)-or
    '1.19.2'-notin@($catalog.globalPolicies.customSkinLoader.variants[0].minecraftVersions)-or
    '1.20.1'-notin@($catalog.globalPolicies.customSkinLoader.variants[0].minecraftVersions)-or
    '1.21.1'-notin@($catalog.globalPolicies.customSkinLoader.variants[0].minecraftVersions)){
    throw 'CustomSkinLoader no fija una variante compatible para todas las experiencias.'
}
$cobbleverseLock=Read-CocoExperienceLock (Join-Path $root (($cobbleverse.pack.lockPath)-replace'/','\')) $cobbleverse
if(@($cobbleverseLock.assets).Count-ne142){throw 'El lock oficial de COBBLEVERSE no contiene los 142 assets declarados.'}
$terralith=@($cobbleverseLock.assets|Where-Object path -eq 'mods/Terralith_1.21.x_v2.5.8.jar')
if($terralith.Count-ne1-or[bool]$terralith[0].manifestRequired){
    throw 'La dependencia opcional Terralith de COBBLEVERSE no fue conservada por la politica inclusiva.'
}
$cobbleverseDh=@($cobbleverse.files|Where-Object path -eq 'mods/DistantHorizons-3.2.0-b-1.21.1-fabric-neoforge.jar')
$cobbleverseLan=@($cobbleverse.files|Where-Object path -eq 'mods/mcwifipnp-1.9.0-1.21-fabric.jar')
if($cobbleverseDh.Count-ne1-or$cobbleverseDh[0].role-ne'all' -or
    $cobbleverseLan.Count-ne1-or$cobbleverseLan[0].role-ne'host'){
    throw 'COBBLEVERSE no fija Distant Horizons para todos y MCWiFiPnP solo para el host.'
}
if($cobbleverse.preferences.worldGeneration.mode-ne'random'-or
    $cobbleverse.preferences.worldGeneration.generator-ne'default'-or
    [bool]$cobbleverse.preferences.worldGeneration.fixedSeed){
    throw 'COBBLEVERSE no conserva la creacion de mundo aleatorio sin semilla fija.'
}
if([int]$cobbleverse.launch.memory.recommendedMb-ne5120){
    throw 'COBBLEVERSE no fija el heap solicitado de 5 GiB.'
}
$cobbleverseDhDistance=@($cobbleverse.preferences.tomlValues|Where-Object{
    $_.path-eq'config/DistantHorizons.toml'-and
    $_.section-eq'client.advanced.graphics.quality'-and
    $_.key-eq'lodChunkRenderDistanceRadius'
})
if($cobbleverseDhDistance.Count-ne1-or[int]$cobbleverseDhDistance[0].value-ne32){
    throw 'COBBLEVERSE no fija declarativamente Distant Horizons en 32 chunks.'
}
$zombieLock=Read-CocoExperienceLock (Join-Path $root (($zombie.pack.lockPath)-replace'/','\')) $zombie
$zombieLan=@($zombieLock.assets|Where-Object path -eq 'mods/lanserverproperties-1.0.jar')
if($zombieLan.Count-ne1-or$zombieLan[0].role-ne'host'-or$zombieLan[0].sha256-ne'15577c28814cda5ce0d6c0e9039a093a6227e2c9ec3716dae9c840ec0a99e263'){
    throw 'Zombie no fija Lan Server Properties 1.0 exclusivamente para el host.'
}
$bigWalk=@($catalog.experiences|Where-Object id -eq 'big-walk'|Select-Object -First 1)[0]
if(-not$bigWalk-or$bigWalk.runtime.type-ne'standalone'-or$bigWalk.runtime.executable-ne'Big Walk.exe'){throw 'Big Walk no esta fijado como experiencia standalone.'}
$bigWalkPart3=@($bigWalk.pack.archives|Where-Object archiveUrl -match 'Big-Walk-Part3\.zip'|Select-Object -First 1)[0]
if(-not$bigWalkPart3-or[int64]$bigWalkPart3.size-ne1282790241-or[string]$bigWalkPart3.sha256-ne'7da9186a60f61e643030c1f2a2925ff7de0d2299160e5f030b2d056b4e4ad96a'){throw 'Big Walk Part3 no coincide con el asset oficial vigente de GitHub.'}
if([int64]$bigWalk.pack.size-ne3848005742){throw 'Big Walk no conserva el tamano total vigente de sus tres partes.'}
$bigWalkRequired=@($bigWalk.runtime.requiredFiles)
$expectedBigWalkRequired=@('Big Walk.exe','OnlineFix64.dll','winmm.dll','Big Walk_Data/Plugins/x86_64/EOSSDK-Win64-Shipping.dll')
if($bigWalkRequired.Count-ne$expectedBigWalkRequired.Count-or@($expectedBigWalkRequired|Where-Object{$_-notin@($bigWalkRequired.path)}).Count-or
   @($bigWalkRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($bigWalk.pack.archives.sha256)}).Count){
    throw 'Big Walk no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$bigWalk.runtimePolicies.defenderExclusion-ne'required'-or[string]$bigWalk.runtimePolicies.onlineFixAppId-ne'3527290'){
    throw 'Big Walk no declara sus politicas standalone de Defender y OnlineFix.'
}
$bigWalkMods=@($bigWalk.files|Where-Object path -eq 'BepInEx/mods/big-walk-mods.zip')
if($bigWalkMods.Count-ne1-or$bigWalkMods[0].role-ne'all'-or
    $bigWalkMods[0].sourceUrl-notmatch'^https://github\.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v\d+\.\d+\.\d+/[^/?#]+$'-or
    $bigWalkMods[0].sha256-notmatch'^[a-fA-F0-9]{64}$'-or
    ([string]$bigWalkMods[0].policy-ne'replace')){
    throw 'Big Walk no declara su paquete de mods BepInEx como asset first-party para ambos roles.'
}
$shiftAtMidnight=@($catalog.experiences|Where-Object id -eq 'shift-at-midnight'|Select-Object -First 1)[0]
if(-not$shiftAtMidnight-or$shiftAtMidnight.runtime.type-ne'standalone'-or$shiftAtMidnight.runtime.executable-ne'ShiftAtMidnight.exe'){throw 'Shift at Midnight no esta fijado como experiencia standalone.'}
$shiftArchive=@($shiftAtMidnight.pack.archives|Where-Object archiveUrl -match 'Shift-At-Midnight\.zip'|Select-Object -First 1)[0]
if(-not$shiftArchive-or[int64]$shiftArchive.size-ne417406156-or[string]$shiftArchive.sha256-ne'92f88cd2ba472591b4029802271c3195e373f220566ff75f4516fdfa43b41669'){throw 'Shift at Midnight no coincide con el asset oficial de GitHub.'}
if([int64]$shiftAtMidnight.pack.size-ne417406156){throw 'Shift at Midnight no conserva el tamano total de su paquete.'}
$shiftRequired=@($shiftAtMidnight.runtime.requiredFiles)
$expectedShiftRequired=@('ShiftAtMidnight.exe','OnlineFix64.dll','winmm.dll','ShiftAtMidnight_Data/Plugins/x86_64/steam_api64.dll')
if($shiftRequired.Count-ne$expectedShiftRequired.Count-or@($expectedShiftRequired|Where-Object{$_-notin@($shiftRequired.path)}).Count-or
   @($shiftRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($shiftAtMidnight.pack.archives.sha256)}).Count){
    throw 'Shift at Midnight no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$shiftAtMidnight.runtimePolicies.defenderExclusion-ne'required'-or[string]$shiftAtMidnight.runtimePolicies.onlineFixAppId-ne'3722330'){
    throw 'Shift at Midnight no declara sus politicas standalone de Defender y OnlineFix.'
}
$peak=@($catalog.experiences|Where-Object id -eq 'peak'|Select-Object -First 1)[0]
if(-not$peak-or$peak.runtime.type-ne'standalone'-or$peak.runtime.executable-ne'PEAK.exe'){throw 'PEAK no esta fijado como experiencia standalone.'}
$peakPart1=@($peak.pack.archives|Where-Object archiveUrl -match 'PEAK-Part1\.zip'|Select-Object -First 1)[0]
$peakPart2=@($peak.pack.archives|Where-Object archiveUrl -match 'PEAK-Part2\.zip'|Select-Object -First 1)[0]
if(-not$peakPart1-or[int64]$peakPart1.size-ne684556663-or[string]$peakPart1.sha256-ne'b777de7135b92e23a2284662d8ac1a0fc9e064d4e094fcf0b2344e6d558c399b'){throw 'PEAK Part 1 no coincide con el asset oficial de GitHub.'}
if(-not$peakPart2-or[int64]$peakPart2.size-ne712227092-or[string]$peakPart2.sha256-ne'ccaca4e114d3cfa87305bb0416e0f352a4c673105dcebc72f39c078b7f0b9777'){throw 'PEAK Part 2 no coincide con el asset oficial de GitHub.'}
if([int64]$peak.pack.size-ne1396783755){throw 'PEAK no conserva el tamano total de sus dos partes.'}
$peakRequired=@($peak.runtime.requiredFiles)
$expectedPeakRequired=@('PEAK.exe','OnlineFix64.dll','Custom.dll','winmm.dll','PEAK_Data/Plugins/x86_64/steam_api64.dll')
if($peakRequired.Count-ne$expectedPeakRequired.Count-or@($expectedPeakRequired|Where-Object{$_-notin@($peakRequired.path)}).Count-or
   @($peakRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($peak.pack.archives.sha256)}).Count){
    throw 'PEAK no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$peak.runtimePolicies.defenderExclusion-ne'required'-or[string]$peak.runtimePolicies.onlineFixAppId-ne'3527290'){
    throw 'PEAK no declara sus politicas standalone de Defender y OnlineFix.'
}
$peakMods=@($peak.files|Where-Object path -eq 'BepInEx/mods/peak-unlimited-mods.zip'|Select-Object -First 1)[0]
if(-not$peakMods-or[int64]$peakMods.size-ne665645-or[string]$peakMods.sha256-ne'c41e4a11c364ea3b5c5d431f96bd60148c83ad669e3bc0cf8a000451caf4ee57'-or[string]$peakMods.role-ne'all'){
    throw 'PEAK no fija su paquete de mods BepInEx (PEAK Unlimited v4.0.1) con rol all.'
}
$machineParty=@($catalog.experiences|Where-Object id -eq 'machine-party'|Select-Object -First 1)[0]
if(-not$machineParty-or[string]$machineParty.runtime.executable-ne'Machine Party.exe'-or$machineParty.runtime.type-ne'standalone'-or$machineParty.managementMode-ne'managed'){
    throw 'La experiencia standalone Machine Party no esta declarada correctamente.'
}
$mpRequired=@($machineParty.runtime.requiredFiles)
if($mpRequired.Count-ne5-or`
   @($mpRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($machineParty.pack.archives.sha256)}).Count){
    throw 'Machine Party no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$machineParty.runtimePolicies.defenderExclusion-ne'required'-or[string]$machineParty.runtimePolicies.onlineFixAppId-ne'4108000'){
    throw 'Machine Party no declara sus politicas standalone de Defender y OnlineFix.'
}
$contentWarning=@($catalog.experiences|Where-Object id -eq 'content-warning'|Select-Object -First 1)[0]
if(-not$contentWarning-or[string]$contentWarning.runtime.executable-ne'Content Warning.exe'-or$contentWarning.runtime.type-ne'standalone'-or$contentWarning.managementMode-ne'managed'){
    throw 'La experiencia standalone Content Warning no esta declarada correctamente.'
}
$cwRequired=@($contentWarning.runtime.requiredFiles)
if($cwRequired.Count-ne5-or`
   @($cwRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($contentWarning.pack.archives.sha256)}).Count){
    throw 'Content Warning no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$contentWarning.runtimePolicies.defenderExclusion-ne'required'-or[string]$contentWarning.runtimePolicies.onlineFixAppId-ne'2881650'){
    throw 'Content Warning no declara sus politicas standalone de Defender y OnlineFix.'
}
$scamLine=@($catalog.experiences|Where-Object id -eq 'scam-line'|Select-Object -First 1)[0]
if(-not$scamLine-or[string]$scamLine.runtime.executable-ne'Scam Line.exe'-or$scamLine.runtime.type-ne'standalone'-or$scamLine.managementMode-ne'managed'){
    throw 'La experiencia standalone Scam Line no esta declarada correctamente.'
}
$slRequired=@($scamLine.runtime.requiredFiles)
if($slRequired.Count-ne4-or`
   @($slRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($scamLine.pack.archives.sha256)}).Count){
    throw 'Scam Line no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$scamLine.runtimePolicies.defenderExclusion-ne'required'-or[string]$scamLine.runtimePolicies.onlineFixAppId-ne'2794590'){
    throw 'Scam Line no declara sus politicas standalone de Defender y OnlineFix.'
}
$lockdownProtocol=@($catalog.experiences|Where-Object id -eq 'lockdown-protocol'|Select-Object -First 1)[0]
if(-not$lockdownProtocol-or[string]$lockdownProtocol.runtime.executable-ne'LockdownProtocol.exe'-or$lockdownProtocol.runtime.type-ne'standalone'-or$lockdownProtocol.managementMode-ne'managed'){
    throw 'La experiencia standalone LOCKDOWN Protocol no esta declarada correctamente.'
}
$lpRequired=@($lockdownProtocol.runtime.requiredFiles)
if($lpRequired.Count-ne4-or`
   @($lpRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($lockdownProtocol.pack.archives.sha256)}).Count){
    throw 'LOCKDOWN Protocol no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$lockdownProtocol.runtimePolicies.defenderExclusion-ne'required'-or[string]$lockdownProtocol.runtimePolicies.onlineFixAppId-ne'2780980'){
    throw 'LOCKDOWN Protocol no declara sus politicas standalone de Defender y OnlineFix.'
}
$cookingSim2=@($catalog.experiences|Where-Object id -eq 'cooking-simulator-2'|Select-Object -First 1)[0]
if(-not$cookingSim2-or[string]$cookingSim2.runtime.executable-ne'Cooking Simulator 2.exe'-or$cookingSim2.runtime.type-ne'standalone'-or$cookingSim2.managementMode-ne'managed'){
    throw 'La experiencia standalone Cooking Simulator 2 no esta declarada correctamente.'
}
$cs2Required=@($cookingSim2.runtime.requiredFiles)
if($cs2Required.Count-ne4-or`
   @($cs2Required|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($cookingSim2.pack.archives.sha256)}).Count){
    throw 'Cooking Simulator 2 no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$cookingSim2.runtimePolicies.defenderExclusion-ne'required'-or[string]$cookingSim2.runtimePolicies.onlineFixAppId-ne'2455360'){
    throw 'Cooking Simulator 2 no declara sus politicas standalone de Defender y OnlineFix.'
}
$repoExp=@($catalog.experiences|Where-Object id -eq 'repo'|Select-Object -First 1)[0]
if(-not$repoExp-or[string]$repoExp.runtime.executable-ne'REPO.exe'-or$repoExp.runtime.type-ne'standalone'-or$repoExp.managementMode-ne'managed'){
    throw 'La experiencia standalone R.E.P.O no esta declarada correctamente.'
}
$repoRequired=@($repoExp.runtime.requiredFiles)
if($repoRequired.Count-ne5-or`
   @($repoRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($repoExp.pack.archives.sha256)}).Count){
    throw 'R.E.P.O no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$repoExp.runtimePolicies.defenderExclusion-ne'required'-or[string]$repoExp.runtimePolicies.onlineFixAppId-ne'3241660'){
    throw 'R.E.P.O no declara sus politicas standalone de Defender y OnlineFix.'
}
$howToFishExp=@($catalog.experiences|Where-Object id -eq 'how-to-fish'|Select-Object -First 1)[0]
if(-not$howToFishExp-or[string]$howToFishExp.runtime.executable-ne'How to Fish.exe'-or$howToFishExp.runtime.type-ne'standalone'-or$howToFishExp.managementMode-ne'managed'){
    throw 'La experiencia standalone How to Fish no esta declarada correctamente.'
}
$htfRequired=@($howToFishExp.runtime.requiredFiles)
if($htfRequired.Count-ne5-or`
   @($htfRequired|Where-Object{[string]$_.sha256-notmatch'^[a-f0-9]{64}$'-or[int64]$_.size-le0-or[string]$_.archiveSha256-notin@($howToFishExp.pack.archives.sha256)}).Count){
    throw 'How to Fish no fija todos sus archivos base reparables por ruta, hash, tamano y archive exacto.'
}
if([string]$howToFishExp.runtimePolicies.defenderExclusion-ne'required'-or[string]$howToFishExp.runtimePolicies.onlineFixAppId-ne'4001890'){
    throw 'How to Fish no declara sus politicas standalone de Defender y OnlineFix.'
}
$smolbird=@($catalog.globalPolicies.customSkinLoader.localSkins|Where-Object username -eq 'smolbird')
if($smolbird.Count-ne1-or$smolbird[0].sha256-ne'fbfb5fdf0c1a71d3904efcbdfe9b403107c133b9137a302f1611e8adc29864fb'){
    throw 'La skin global de smolbird no esta fijada por hash.'
}
if($dread.preferences.shader.pack-ne'DREAD REBORN SHADERS - 6 - Potato.zip'-or-not[bool]$dread.preferences.voiceChatDefaults){
    throw 'Se perdieron los ajustes declarativos de DREAD.'
}
if(-not[bool]$backrooms.preferences.voiceChatDefaults-or$backrooms.preferences.PSObject.Properties.Name-contains'shader'){
    throw 'Backrooms perdio sus ajustes declarativos o Coco intenta forzarle un shaderpack externo que el pack no declara.'
}
if($zombie.preferences.resourcePack-ne'Tissous Zombie Pack 1.12.2 - 2.6.zip'-or-not[bool]$zombie.preferences.optifineEmissive){
    throw 'Se perdieron los ajustes declarativos de Zombie Apocalypse.'
}
$nightfallLock=Read-CocoExperienceLock (Join-Path $root (($nightfallcraft.pack.lockPath)-replace'/','\')) $nightfallcraft
if(@($nightfallLock.assets).Count-ne215){throw 'El lock oficial de NightfallCraft no contiene los 215 assets declarados.'}
foreach($managed in @($dread,$backrooms,$cobbleverse,$zombie,$nightfallcraft,$valorantcraft)){
    if(-not$managed.preferences){throw "Falta politica declarativa en $($managed.id)."}
}
foreach($unsafe in '..\mods\bad.jar','C:\escape.jar','mods//bad.jar','/rooted.jar','mods/../bad.jar'){
    if(Test-CocoSafeRelativePath $unsafe){throw "Ruta insegura aceptada: $unsafe"}
}
foreach($safe in 'mods/example.jar','config/a.json','shaderpacks/pack.zip'){
    if(-not(Test-CocoSafeRelativePath $safe)){throw "Ruta valida rechazada: $safe"}
}

$testRoot=Join-Path $env:TEMP "coco-launcher-catalog-$([guid]::NewGuid())"
try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.experiences=@($bad.experiences[0],$bad.experiences[0])
    $badPath=Join-Path $testRoot 'duplicate.json'
    $bad|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badPath -Encoding UTF8
    $rejected=$false
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{$rejected=$_.Exception.Message-match'duplicado'}
    if(-not$rejected){throw 'El catalogo acepto IDs de experiencia duplicados.'}

    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.releaseStatus='approved'
    $badHeart=@($bad.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
    $badHeart.content.episodes[0].sourceUrl='https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/test/episode.mp4'
    $badHeart.content.episodes[0].size=2147483648
    $badPath=Join-Path $testRoot 'github-size.json'
    $bad|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badPath -Encoding UTF8
    $rejected=$false
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{$rejected=$_.Exception.Message-match'2 GiB'}
    if(-not$rejected){throw 'El catalogo permitio un episodio de GitHub Free mayor o igual a 2 GiB.'}

    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.releaseStatus='approved'
    $badHeart=@($bad.experiences|Where-Object id -eq 'heart-signal'|Select-Object -First 1)[0]
    $badHeart.content.episodes[0].sourceUrl=''
    $badHeart.content.episodes[0].streamUrl='https://example.com/episode.mp4'
    $badHeart.content.episodes[0].size=1
    $badHeart.content.episodes[0].sha256=('a'*64)
    $badHeart.content.episodes=@($badHeart.content.episodes[0])
    $badPath=Join-Path $testRoot 'stream-only.json'
    $bad|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badPath -Encoding UTF8
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{throw 'El catalogo rechazo un episodio aprobado que solo declara streamUrl HTTPS.'}

    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.experiences[0].files=@([pscustomobject]@{path='../saves/coco/level.dat';sha256=('a'*64);size=1;policy='replace'})
    $badPath=Join-Path $testRoot 'traversal.json'
    $bad|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badPath -Encoding UTF8
    $rejected=$false
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{$rejected=$_.Exception.Message-match'insegura'}
    if(-not$rejected){throw 'El catalogo acepto traversal fuera de la instancia.'}

    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.sessionPolicy.clientSelection='manual'
    $badPath=Join-Path $testRoot 'manual-selection.json'
    $bad|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badPath -Encoding UTF8
    $rejected=$false
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{$rejected=$_.Exception.Message-match'automatica'}
    if(-not$rejected){throw 'El catalogo acepto seleccion manual para los clientes.'}

    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.experiences[0].launch.workflow='coco-managed'
    $badPath=Join-Path $testRoot 'legacy-managed.json'
    $bad|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badPath -Encoding UTF8
    $rejected=$false
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{$rejected=$_.Exception.Message-match'Workflow'}
    if(-not$rejected){throw 'El catalogo permitio que Coco Launcher se apropiara del mundo original.'}

    $bad=Get-Content -LiteralPath $template -Raw|ConvertFrom-Json
    $bad.experiences[1] | Add-Member -NotePropertyName worldTemplate -NotePropertyValue ([pscustomobject]@{installRole='client';lockPath='launcher/experiences/into-the-backrooms.lock.json';firstRunPolicy='create-once-preserve-forever'}) -Force
    $badPath=Join-Path $testRoot 'client-world.json'
    $bad|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $badPath -Encoding UTF8
    $rejected=$false
    try{[void](Read-CocoLauncherCatalog $badPath)}catch{$rejected=$_.Exception.Message-match'exclusivamente'}
    if(-not$rejected){throw 'El catalogo permitio instalar el mundo All Rights Reserved en clientes.'}
    'PASS: schema inicial, sesion unica automatica, backend fijado y limites de rutas validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
