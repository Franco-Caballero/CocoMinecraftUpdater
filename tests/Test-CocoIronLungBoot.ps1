[CmdletBinding()]
param(
    [string]$AuditRoot=(Join-Path $env:TEMP 'coco-iron-lung-runtime-audit'),
    [ValidateRange(60,900)][int]$TimeoutSeconds=480
)

$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$instance=[IO.Path]::GetFullPath((Join-Path $AuditRoot 'experiences\iron-lung'))
$cacheRoot=[IO.Path]::GetFullPath((Join-Path $AuditRoot 'cache'))
$temporaryRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
if(-not$instance.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'La instancia de auditoria debe permanecer dentro de TEMP.'}
if(-not(Test-Path -LiteralPath (Join-Path $instance '.coco\managed-state.json') -PathType Leaf)){throw 'Primero ejecuta Test-CocoIronLungRuntime.ps1 -KeepAuditRoot.'}
$unrelatedJava=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue)
if($unrelatedJava){throw 'La prueba de arranque exige que no exista ningun Java previo.'}

$launcherText=[IO.File]::ReadAllText((Join-Path $repoRoot 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $repoRoot 'launcher\catalog.template.json')
$experience=(($catalog.experiences|Where-Object id -eq 'iron-lung'|Select-Object -First 1)|ConvertTo-Json -Depth 12|ConvertFrom-Json)
$experience.launch.autoJoin=$false
$backend=Join-Path $cacheRoot 'launcher\runtime\portablemc\5.0.4\portablemc.exe'
if(-not(Test-CocoLauncherBackendInstallation $catalog.backend (Split-Path $backend -Parent))){throw 'PortableMC auditado no esta instalado en AuditRoot.'}
$mainDir=Join-Path $cacheRoot 'launcher\shared'
$accountDb=Join-Path $cacheRoot 'launcher\accounts\portablemc_msa.json'
$identity=[pscustomobject]@{mode='offline';username='CocoAudit';uuid=''}
$arguments=[Collections.Generic.List[string]]::new()
foreach($argument in (New-CocoPortableMcStartArguments $experience $identity $mainDir $instance $accountDb)){$arguments.Add($argument)}
$arguments.Add('--jvm-arg=-Xms1G,-Xmx6G')
$portableLog=Join-Path $AuditRoot 'boot-portablemc.log'
Remove-Item -LiteralPath $portableLog -Force -ErrorAction SilentlyContinue
$process=Start-CocoPortableMcGame $backend $arguments.ToArray() $portableLog
$latestLog=Join-Path $instance 'logs\latest.log'
$crashDirectory=Join-Path $instance 'crash-reports'
$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
$success=$false
$javaPids=@()
try{
    while((Get-Date)-lt$deadline){
        Start-Sleep -Seconds 2
        $java=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{
            -not[string]::IsNullOrWhiteSpace($_.CommandLine)-and$_.CommandLine.IndexOf($instance,[StringComparison]::OrdinalIgnoreCase)-ge0
        })
        $javaPids=@($java.ProcessId)
        if(Test-Path -LiteralPath $crashDirectory){
            $crash=Get-ChildItem -LiteralPath $crashDirectory -File -Filter '*.txt'|Sort-Object LastWriteTime -Descending|Select-Object -First 1
            if($crash){throw "Iron Lung genero un crash report: $($crash.FullName)"}
        }
        $text=if(Test-Path -LiteralPath $latestLog){Get-Content -LiteralPath $latestLog -Raw -ErrorAction SilentlyContinue}else{''}
        if($text-match'(?im)(Sound engine started|OpenAL initialized on device)'){
            Start-Sleep -Seconds 12
            $alive=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{
                -not[string]::IsNullOrWhiteSpace($_.CommandLine)-and$_.CommandLine.IndexOf($instance,[StringComparison]::OrdinalIgnoreCase)-ge0
            })
            if($alive.Count){$javaPids=@($alive.ProcessId);$success=$true;break}
        }
        if($process.HasExited-and-not$java.Count){
            $tail=if(Test-Path -LiteralPath $portableLog){(Get-Content -LiteralPath $portableLog -Tail 40)-join"`n"}else{''}
            throw "PortableMC/Minecraft terminaron antes del menu. $tail"
        }
    }
    if(-not$success){throw "Iron Lung no alcanzo el menu dentro de $TimeoutSeconds segundos."}
}finally{
    # Solo termina Java cuya linea de comandos contiene la raiz desechable exacta.
    $targets=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{
        -not[string]::IsNullOrWhiteSpace($_.CommandLine)-and$_.CommandLine.IndexOf($instance,[StringComparison]::OrdinalIgnoreCase)-ge0
    })
    foreach($target in $targets){Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue}
    if(-not$process.HasExited){$process.Kill()}
    $process.Dispose()
}

if(-not$success){throw 'La prueba de arranque Iron Lung no fue satisfactoria.'}
"PASS: Iron Lung cargo mods y alcanzo un menu estable durante 12 segundos; procesos de auditoria cerrados. LatestLog=$latestLog"
