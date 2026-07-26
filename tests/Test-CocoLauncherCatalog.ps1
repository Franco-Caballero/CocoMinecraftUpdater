[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$template=Join-Path $root 'launcher\catalog.template.json'
$catalog=Read-CocoLauncherCatalog $template
if($catalog.releaseStatus-ne'development'-and$catalog.releaseStatus-ne'approved'){throw 'El catalogo debe declarar development o approved.'}
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
$zombie=@($catalog.experiences|Where-Object id -eq 'zombie-apocalypse-slow-zombies'|Select-Object -First 1)[0]
if($backrooms.compatibility.status-ne'validated'){throw 'Backrooms no conserva la aprobacion del primer test real.'}
if($dread.compatibility.status-ne'experimental'){throw 'DREAD no esta marcado como experimental.'}
if($zombie.compatibility.status-ne'blocked'){throw 'Zombie 1.12.2 no esta bloqueado pese a carecer de adaptador LAN validado.'}
if($catalog.globalPolicies.essential.mode-ne'exclude'-or$catalog.globalPolicies.customSkinLoader.mode-ne'required'){
    throw 'Essential y CustomSkinLoader no tienen politica global obligatoria.'
}
if(@($catalog.globalPolicies.customSkinLoader.variants).Count-ne1-or
    '1.19.2'-notin@($catalog.globalPolicies.customSkinLoader.variants[0].minecraftVersions)-or
    '1.20.1'-notin@($catalog.globalPolicies.customSkinLoader.variants[0].minecraftVersions)){
    throw 'CustomSkinLoader no fija una variante compatible para DREAD y Backrooms.'
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
foreach($managed in @($dread,$backrooms,$zombie)){
    if(-not$managed.preferences-or-not$managed.compatibility.summary){throw "Falta politica declarativa en $($managed.id)."}
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
