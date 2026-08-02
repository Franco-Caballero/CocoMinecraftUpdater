$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pack=Join-Path $root 'launcher\experiences\valorant-craft\agent-orb-datapack'
$meta=Join-Path $pack 'pack.mcmeta'
$tickTag=Join-Path $pack 'data\minecraft\tags\functions\tick.json'
$tick=Join-Path $pack 'data\coco_agent_orb\functions\tick.mcfunction'
$knife=Join-Path $pack 'data\coco_agent_orb\functions\give_knife.mcfunction'
$layer=Join-Path $pack 'data\origins\origin_layers\origin.json'
foreach($path in @($meta,$tickTag,$tick,$knife,$layer)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Falta el archivo del datapack: $path"}}
$layerJson=Get-Content -LiteralPath $layer -Raw|ConvertFrom-Json
if(-not[bool]$layerJson.replace-or@($layerJson.origins).Count-ne10){throw 'La capa de Origins no reemplaza la lista por los diez agentes.'}
if(@($layerJson.origins|Where-Object { [string]$_ -notmatch '^valorant_origins:' }).Count){throw 'La capa de Origins contiene un origen que no es agente Valorant.'}
$metadata=Get-Content -LiteralPath $meta -Raw|ConvertFrom-Json
if([int]$metadata.pack.pack_format -ne 15){throw 'El datapack no fija el formato de Minecraft 1.20.1 (15).'}
$tag=Get-Content -LiteralPath $tickTag -Raw|ConvertFrom-Json
if(@($tag.values)-notcontains 'coco_agent_orb:tick'){throw 'El datapack no registra su funcion tick.'}
$function=Get-Content -LiteralPath $tick -Raw
if($function-notmatch 'execute as @a unless entity @s\[nbt=\{Inventory:\[\{id:"origins:orb_of_origin"\}\]\}\] run give @s origins:orb_of_origin 1'){
    throw 'La funcion no repone el Orb of Origin cuando falta del inventario.'
}
$knifeFunction=Get-Content -LiteralPath $knife -Raw
if($knifeFunction-notmatch 'execute as @a unless entity @s\[nbt=\{Inventory:\[\{id:"lrtactical:melee"\}\]\}\] run give @s lrtactical:melee\{MeleeWeaponId:"wtyj:eternal_karambit"\} 1'){
    throw 'La funcion no entrega el cuchillo Valorant por defecto cuando falta del inventario.'
}
if($function-notmatch 'lrtactical:melee\{MeleeWeaponId:"wtyj:eternal_karambit"\}'){
    throw 'El tick del datapack no repone el cuchillo tras el reinicio de ronda.'
}
Write-Output 'PASS: datapack de agentes, Orb of Origin permanente y cuchillo Valorant validados.'
