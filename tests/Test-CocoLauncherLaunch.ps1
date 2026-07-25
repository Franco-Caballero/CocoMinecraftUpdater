[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$experience=$catalog.experiences[0]

if((Get-CocoPortableMcVersionSpec $experience)-ne'fabric:26.1.2:0.19.3'){throw 'El spec Fabric fijado no coincide.'}
$offline=[pscustomobject]@{mode='offline';username='Amigo_1';uuid=''}
$args=New-CocoPortableMcStartArguments $experience $offline 'C:\Coco Shared' 'C:\Coco Instances\original' 'C:\Coco Accounts\msa.json'
$joined=$args-join'|'
foreach($required in '--main-dir|C:\Coco Shared','--mc-dir|C:\Coco Instances\original','--username|Amigo_1'){
    if($joined-notlike"*$required*"){throw "Falta el argumento de lanzamiento '$required'."}
}
if($joined-like'*--auth*'){throw 'La identidad offline activo autenticacion Microsoft.'}
if($joined-like'*--join-server*'){throw 'Coco original intento autoingresar mediante PortableMC.'}

$microsoft=[pscustomobject]@{mode='microsoft';username='';uuid='12345678-1234-1234-1234-123456789abc'}
$args=New-CocoPortableMcStartArguments $experience $microsoft 'C:\Coco Shared' 'C:\Coco Instances\original' 'C:\Coco Accounts\msa.json' -Dry
$joined=$args-join'|'
if($joined-notlike'*--auth|--uuid|12345678-1234-1234-1234-123456789abc*'){throw 'La cuenta Microsoft no usa su UUID autenticado.'}
if($joined-like'*--join-server*'){throw 'Una preparacion seca intento autoingresar.'}

$forge=Get-Content -LiteralPath (Join-Path $root 'launcher\catalog.template.json') -Raw|ConvertFrom-Json
$forge.experiences[0].runtime.loader='forge'
$forge.experiences[0].runtime.minecraftVersion='1.12.2'
$forge.experiences[0].runtime.loaderVersion='1.12.2-14.23.5.2860'
if((Get-CocoPortableMcVersionSpec $forge.experiences[0])-ne'forge::1.12.2-14.23.5.2860'){throw 'El spec Forge legacy fijado no coincide.'}
$backrooms=@($catalog.experiences|Where-Object id -eq 'into-the-backrooms'|Select-Object -First 1)[0]
$backroomsArgs=New-CocoPortableMcStartArguments $backrooms $offline 'C:\Coco Shared' 'C:\Coco Instances\into-the-backrooms' 'C:\Coco Accounts\msa.json'
if(-not@($backroomsArgs|Where-Object{$_-match'^--jvm-arg=-Xms1024m,-Xmx[0-9]+m$'})){throw 'Into The Backrooms no calcula memoria adaptativa.'}
$backroomsJoined=$backroomsArgs-join'|'
foreach($required in '--join-server|10.77.37.1','--join-server-port|25565'){
    if($backroomsJoined-notlike"*$required*"){throw "Into The Backrooms no contiene el autoingreso '$required'."}
}

$rejected=$false
try{[void](New-CocoPortableMcStartArguments $experience ([pscustomobject]@{mode='microsoft';username='';uuid=''}) 'A' 'B' 'C')}catch{$rejected=$_.Exception.Message-match'no fue vinculada'}
if(-not$rejected){throw 'Se permitio lanzar Microsoft sin cuenta vinculada.'}

$testRoot=Join-Path $env:TEMP "coco-launcher-auth-$([guid]::NewGuid())"
try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $fake=Join-Path $testRoot 'fake portablemc.exe'
    Add-Type -TypeDefinition @'
using System;
public static class FakePortableMcAuth {
    public static int Main(string[] args) {
        Console.WriteLine("row\tusername\tuuid");
        Console.WriteLine("sep");
        Console.WriteLine("row\tPremium_1\t12345678-1234-1234-1234-123456789abc");
        return 0;
    }
}
'@ -OutputType ConsoleApplication -OutputAssembly $fake
    $sessions=@(Get-CocoPortableMcAuthSessions $fake (Join-Path $testRoot 'main with spaces') (Join-Path $testRoot 'accounts with spaces\msa.json'))
    if($sessions.Count-ne1-or$sessions[0].Username-ne'Premium_1'-or$sessions[0].Uuid-ne'12345678-1234-1234-1234-123456789abc'){
        throw 'No se analizo correctamente la salida machine de cuentas PortableMC.'
    }
}finally{if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}}

'PASS: argumentos aislados Fabric/Forge, identidad, cuentas machine y autoingreso PortableMC validados.'
