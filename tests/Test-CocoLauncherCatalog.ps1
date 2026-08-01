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
if($catalog.catalogVersion-ne'0.3.0'){throw 'El catalogo no refleja la visibilidad directa de todas las experiencias.'}
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
$managedExperiences=@($catalog.experiences|Where-Object managementMode -eq 'managed')
if($managedExperiences.Count-ne5-or
    @($managedExperiences|Where-Object{$_.PSObject.Properties.Name-contains'compatibility'}).Count){
    throw 'Todas las experiencias deben estar visibles por presencia en catalogo, sin estados de bloqueo/experimento.'
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
foreach($managed in @($dread,$backrooms,$cobbleverse,$zombie,$nightfallcraft)){
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
