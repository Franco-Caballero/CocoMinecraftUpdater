[CmdletBinding()]
param(
    [string]$AuditRoot=(Join-Path $env:TEMP 'coco-iron-lung-runtime-audit'),
    [ValidateSet('client','host')][string]$Role='host',
    [ValidateRange(60,900)][int]$TimeoutSeconds=480
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$expected=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'coco-iron-lung-runtime-audit'))
$audit=[IO.Path]::GetFullPath($AuditRoot)
if(-not[string]::Equals($audit,$expected,[StringComparison]::OrdinalIgnoreCase)){throw "AuditRoot no es la raiz desechable exacta: $expected"}
$instance=Join-Path $audit 'experiences\iron-lung'
if(-not(Test-Path -LiteralPath (Join-Path $instance '.coco\managed-state.json') -PathType Leaf)){throw 'Falta la instalacion fria de Iron Lung.'}
if(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue){throw 'La prueba exige que no exista otro Java abierto.'}
if(Get-NetTCPConnection -LocalPort 25565 -State Listen -ErrorAction SilentlyContinue){throw 'El puerto 25565 debe estar apagado para distinguir el intento de autoingreso.'}

$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Download-VerifiedFile([string]$Url,[string]$Destination,[string]$ExpectedHash){throw "La prueba caliente intento descargar inesperadamente: $Url"}

$latestLog=Join-Path $instance 'logs\latest.log'
Remove-Item -LiteralPath $latestLog -Force -ErrorAction SilentlyContinue
$identity=[pscustomobject]@{mode='offline';username='CocoAudit';uuid=''}
$launch=$null;$connected=$false
try{
    $launch=Invoke-CocoManagedExperienceLaunch $catalog iron-lung $identity $Role (Join-Path $root 'launcher') (Join-Path $audit 'cache') (Join-Path $audit 'experiences')
    if($launch.Status-ne'launched'){throw 'Coco no devolvio un lanzamiento real.'}
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    while((Get-Date)-lt$deadline){
        Start-Sleep -Seconds 2
        $text=if(Test-Path -LiteralPath $latestLog){Get-Content -LiteralPath $latestLog -Raw -ErrorAction SilentlyContinue}else{''}
        if($text-match'(?i)Connecting to (?:/)?10\.77\.37\.1[,:]\s*25565'){$connected=$true;break}
        $auditJava=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{
            $_.CommandLine-and$_.CommandLine.IndexOf($instance,[StringComparison]::OrdinalIgnoreCase)-ge0
        })
        if($launch.Process.HasExited-and-not$auditJava.Count){
            $tail=if(Test-Path -LiteralPath $launch.LogPath){(Get-Content -LiteralPath $launch.LogPath -Tail 40)-join"`n"}else{''}
            throw "PortableMC/Minecraft terminaron antes del autoingreso. $tail"
        }
    }
    if(-not$connected){throw "Minecraft no intento 10.77.37.1:25565 dentro de $TimeoutSeconds segundos."}
}finally{
    $targets=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{
        $_.CommandLine-and$_.CommandLine.IndexOf($instance,[StringComparison]::OrdinalIgnoreCase)-ge0
    })
    foreach($target in $targets){Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue}
    if($launch-and$launch.Process){if(-not$launch.Process.HasExited){$launch.Process.Kill()};$launch.Process.Dispose()}
}

"PASS: Coco preparo el rol $Role, lanzo y Minecraft intento autoingresar a 10.77.37.1:25565 sin lista ni launcher externo."
