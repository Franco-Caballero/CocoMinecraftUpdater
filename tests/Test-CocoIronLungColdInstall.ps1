[CmdletBinding()]
param(
    [string]$AuditRoot=(Join-Path $env:TEMP 'coco-iron-lung-runtime-audit'),
    [switch]$Reset,
    [switch]$Resume
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$expectedAuditRoot=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'coco-iron-lung-runtime-audit'))
$resolvedAuditRoot=[IO.Path]::GetFullPath($AuditRoot)
if(-not[string]::Equals($resolvedAuditRoot,$expectedAuditRoot,[StringComparison]::OrdinalIgnoreCase)){
    throw "La prueba destructiva solo admite la raiz desechable exacta: $expectedAuditRoot"
}
if(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue){
    throw 'La instalacion fria exige que no exista ningun Java abierto.'
}
if($Reset-and(Test-Path -LiteralPath $resolvedAuditRoot)){
    Remove-Item -LiteralPath $resolvedAuditRoot -Recurse -Force
}
if((Test-Path -LiteralPath $resolvedAuditRoot)-and-not$Resume){throw 'AuditRoot ya existe; usa -Reset para una instalacion fria o -Resume para continuar una descarga interrumpida.'}
if(-not(Test-Path -LiteralPath $resolvedAuditRoot)){New-Item -ItemType Directory -Path $resolvedAuditRoot -Force|Out-Null}

$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Download-VerifiedFile([string]$Url,[string]$Destination,[string]$ExpectedHash){
    $parent=Split-Path $Destination -Parent
    if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $partial="$Destination.partial"
    for($attempt=1;$attempt-le4;$attempt++){
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        try{
            Write-Host ("DOWNLOAD {0}/4 {1}"-f$attempt,$Url)
            $request=[Net.HttpWebRequest]::Create($Url)
            $request.UserAgent='CocoMinecraftUpdater/1.0'
            $request.Timeout=30000;$request.ReadWriteTimeout=30000
            $request.AutomaticDecompression=[Net.DecompressionMethods]::GZip-bor[Net.DecompressionMethods]::Deflate
            $response=$request.GetResponse();$input=$response.GetResponseStream();$output=[IO.File]::Create($partial)
            try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose();$response.Dispose()}
            if((Get-Sha256 $partial)-ne$ExpectedHash.ToLowerInvariant()){throw 'SHA-256 inesperado.'}
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        }catch{
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if($attempt-eq4){throw}
            Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))
        }
    }
}

$cacheRoot=Join-Path $resolvedAuditRoot 'cache'
$experiencesRoot=Join-Path $resolvedAuditRoot 'experiences'
$identity=[pscustomobject]@{mode='offline';username='CocoAudit';uuid=''}
$watch=[Diagnostics.Stopwatch]::StartNew()
$first=Invoke-CocoManagedExperienceLaunch $catalog iron-lung $identity host (Join-Path $root 'launcher') $cacheRoot $experiencesRoot -Dry
$coldSeconds=[math]::Round($watch.Elapsed.TotalSeconds,1)
$instance=$first.Installation.InstanceRoot
$statePath=Join-Path $instance '.coco\managed-state.json'
if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){throw 'La instalacion fria no escribio su estado transaccional.'}
$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
if(@(Get-ChildItem -LiteralPath (Join-Path $instance 'mods') -File -Filter '*.jar').Count-ne69){throw 'La instalacion fria no produjo los 69 mods host sin Essential.'}
if(Test-Path -LiteralPath (Join-Path $instance 'saves\coco')){throw 'La instalacion fria copio el mundo original.'}

$watch.Restart()
$second=Invoke-CocoManagedExperienceLaunch $catalog iron-lung $identity host (Join-Path $root 'launcher') $cacheRoot $experiencesRoot -Dry
$warmSeconds=[math]::Round($watch.Elapsed.TotalSeconds,1)
if($second.Result.ExitCode-ne0){throw 'La segunda preparacion no fue idempotente.'}

$overlay=@($catalog.experiences|Where-Object {$_.id -eq 'iron-lung'}|Select-Object -ExpandProperty files|Where-Object {$_.role -eq 'host'}|Select-Object -First 1)[0]
$overlayPath=Join-Path $instance (([string]$overlay.path)-replace'/','\')
[IO.File]::WriteAllBytes($overlayPath,[byte[]](1,2,3,4,5,6,7,8))
$repair=Invoke-CocoManagedExperienceLaunch $catalog iron-lung $identity host (Join-Path $root 'launcher') $cacheRoot $experiencesRoot -Dry
if((Get-Sha256 $overlayPath)-ne([string]$overlay.sha256).ToLowerInvariant()){throw 'Coco no reparo el overlay host alterado.'}
$backup=@(Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'backups\experiences\iron-lung') -Recurse -File -ErrorAction SilentlyContinue|Where-Object Name -eq([IO.Path]::GetFileName($overlayPath)))
if(-not$backup.Count){throw 'La autorreparacion no conservo respaldo del archivo alterado.'}

$objectFiles=@(Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'objects') -File)
$report=[ordered]@{
    schemaVersion=1
    completedAtUtc=[DateTime]::UtcNow.ToString('o')
    resumed=[bool]$Resume
    auditRoot=$resolvedAuditRoot
    instanceRoot=$instance
    coldSeconds=$coldSeconds
    warmSeconds=$warmSeconds
    managedFiles=@($state.files).Count
    objectFiles=$objectFiles.Count
    objectBytes=[int64](($objectFiles|Measure-Object Length -Sum).Sum)
    totalBytes=[int64]((Get-ChildItem -LiteralPath $resolvedAuditRoot -Recurse -File|Measure-Object Length -Sum).Sum)
    repairBackupCount=$backup.Count
}
$reportName=if($Resume){'resume-install-report.json'}else{'cold-install-report.json'}
[IO.File]::WriteAllText((Join-Path $resolvedAuditRoot $reportName),($report|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
"PASS: instalacion fria desde origen, segundo inicio idempotente y autorreparacion aprobados. Cold=$coldSeconds s Warm=$warmSeconds s AuditRoot=$resolvedAuditRoot"
