[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$zombie=@($catalog.experiences|Where-Object id -eq 'zombie-apocalypse-slow-zombies')[0]
$testRoot=Join-Path $env:TEMP ("coco-zombie-lan-$PID-$([guid]::NewGuid().ToString('N'))")

try{
    $mods=Join-Path $testRoot 'mods'
    New-Item -ItemType Directory -Path $mods -Force|Out-Null
    if(Test-CocoManagedLanWorldConfigurations $testRoot $zombie){throw 'El adaptador Zombie acepto una instancia sin el JAR fijado.'}
    $source=Join-Path $env:TEMP 'lanserverproperties-1.0.jar'
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){
        Invoke-WebRequest -UseBasicParsing -Uri 'https://www.curseforge.com/api/v1/mods/387365/files/2994188/download' -OutFile $source
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $mods 'lanserverproperties-1.0.jar')
    if(-not(Test-CocoManagedLanWorldConfigurations $testRoot $zombie)){throw 'El adaptador Zombie fijado no fue reconocido.'}
    if((Set-CocoManagedLanWorldConfigurations $testRoot $zombie)-ne0){throw 'Zombie intento escribir una configuracion MCWiFiPnP incompatible.'}
    'PASS: Zombie exige el adaptador LAN 1.12.2 fijado por hash y no mezcla configuracion MCWiFiPnP.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
