[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$experience=@($catalog.experiences|Where-Object id -eq 'dread-arrenek')[0]
$offline=[pscustomobject]@{mode='offline';username='Amigo_1';uuid=''}

if((Get-CocoPortableMcVersionSpec $experience)-ne'forge::1.19.2-43.5.0'){throw 'El spec Forge de DREAD no coincide.'}
$args=New-CocoPortableMcStartArguments $experience $offline 'C:\Coco Shared' 'C:\Coco Instances\dread' 'C:\Coco Accounts\unused.json'
$joined=$args-join'|'
foreach($required in '--main-dir|C:\Coco Shared','--mc-dir|C:\Coco Instances\dread','--username|Amigo_1'){
    if($joined-notlike"*$required*"){throw "Falta el argumento '$required'."}
}
if($joined-like'*--auth*'-or$joined-like'*--uuid*'){throw 'La identidad local activo autenticacion o UUID premium.'}

$backrooms=@($catalog.experiences|Where-Object id -eq 'into-the-backrooms')[0]
$backroomsArgs=New-CocoPortableMcStartArguments $backrooms $offline 'C:\Coco Shared' 'C:\Coco Instances\into-the-backrooms' 'C:\Coco Accounts\unused.json'
if(-not@($backroomsArgs|Where-Object{$_-match'^--jvm-arg=-Xms1024m,-Xmx[0-9]+m$'})){throw 'Backrooms no calcula memoria adaptativa.'}
$backroomsJoined=$backroomsArgs-join'|'
foreach($required in '--join-server|10.77.37.1','--join-server-port|25565'){
    if($backroomsJoined-notlike"*$required*"){throw "Backrooms no contiene el autoingreso '$required'."}
}

$rejected=$false
try{[void](New-CocoPortableMcStartArguments $experience ([pscustomobject]@{mode='microsoft';username='Premium';uuid='12345678-1234-1234-1234-123456789abc'}) 'A' 'B' 'C')}catch{$rejected=$_.Exception.Message-match'local'}
if(-not$rejected){throw 'PortableMC todavia permite el flujo premium eliminado.'}

$zombie=@($catalog.experiences|Where-Object id -eq 'zombie-apocalypse-slow-zombies')[0]
$zombieArgs=New-CocoPortableMcStartArguments $zombie $offline 'C:\Coco Shared' 'C:\Coco Instances\zombies' 'C:\Coco Accounts\unused.json'
if(($zombieArgs-join'|')-notlike'*forge::1.12.2-14.23.5.2855*'){throw 'Zombie no prepara Forge 1.12.2 con el loader fijado.'}

$cobbleverse=@($catalog.experiences|Where-Object id -eq 'cobbleverse')[0]
$cobbleverseArgs=New-CocoPortableMcStartArguments $cobbleverse $offline 'C:\Coco Shared' 'C:\Coco Instances\cobbleverse' 'C:\Coco Accounts\unused.json'
$cobbleverseJoined=$cobbleverseArgs-join'|'
if($cobbleverseJoined-notlike'*fabric:1.21.1:0.18.4*'){throw 'COBBLEVERSE no prepara Fabric 0.18.4 para Minecraft 1.21.1.'}
$machineparty=@($catalog.experiences|Where-Object id -eq 'machine-party')[0]
if($machineparty.runtime.type-ne'standalone'-or$machineparty.launch.workflow-ne'coco-standalone'){
    throw 'Machine Party no esta configurado con el workflow standalone esperado.'
}

'PASS: lanzamiento local aislado, autoingreso y experiencias Zombie/COBBLEVERSE/Machine-Party habilitadas validados.'
