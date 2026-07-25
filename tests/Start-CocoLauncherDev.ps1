[CmdletBinding()]
param(
    [string]$AuditRoot=(Join-Path $env:TEMP 'coco-backrooms-runtime-audit'),
    [ValidateRange(1,12)][int]$RequiredFreeMemoryGb=2,
    [ValidateRange(2048,6144)][int]$DevHeapMb=3072
)

$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$expected=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'coco-backrooms-runtime-audit')).TrimEnd('\')
$audit=[IO.Path]::GetFullPath($AuditRoot).TrimEnd('\')
if(-not[string]::Equals($audit,$expected,[StringComparison]::OrdinalIgnoreCase)){throw "La prueba sólo admite la raíz desechable exacta: $expected"}
$instance=Join-Path $audit 'experiences\dread-arrenek'
if(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{$_.CommandLine-notmatch'GradleDaemon'}){throw 'Cierra cualquier Minecraft/Java antes de iniciar la prueba.'}
if(Get-NetTCPConnection -State Listen -LocalPort 25564,25565 -ErrorAction SilentlyContinue){throw 'Los puertos Coco 25564/25565 ya están ocupados.'}
$os=Get-CimInstance Win32_OperatingSystem
$freeGb=[math]::Round($os.FreePhysicalMemory*1KB/1GB,2)
if($freeGb-lt$RequiredFreeMemoryGb){throw "Memoria insuficiente para la prueba jugable: hay $freeGb GB libres y se exigen $RequiredFreeMemoryGb GB. Cierra aplicaciones pesadas o reinicia Windows y vuelve a ejecutar este archivo."}

$devRoot=Join-Path $audit 'dev-launcher';$engineOutput=Join-Path $devRoot 'build';$engineRoot=Join-Path $devRoot 'engine'
New-Item -ItemType Directory -Path $engineOutput -Force|Out-Null
$manifestForVersion = Get-Content -LiteralPath (Join-Path $repoRoot 'release\latest.json') -Raw | ConvertFrom-Json
$engineResult = & (Join-Path $repoRoot 'tools\New-CocoEngine.ps1') -Version $manifestForVersion.version -OutputDirectory $engineOutput | ConvertFrom-Json
if(Test-Path -LiteralPath $engineRoot){
    try{Remove-Item -LiteralPath $engineRoot -Recurse -Force -ErrorAction Stop}
    catch{$engineRoot=Join-Path $devRoot "engine-$([guid]::NewGuid().ToString('N').Substring(0,8))"}
}
Expand-Archive -LiteralPath $engineResult.path -DestinationPath $engineRoot -Force
$catalogPath=Join-Path $engineRoot 'launcher\catalog.json'
$catalog=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json
$dread=@($catalog.experiences|Where-Object id -eq 'dread-arrenek'|Select-Object -First 1)[0]
if(-not$dread){throw 'El engine de desarrollo no contiene DREAD - A Horror Survival Pack.'}
$dread.launch.memory.recommendedMb=$DevHeapMb
[IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
$manifestPath=Join-Path $devRoot 'latest.dev.json'
Copy-Item -LiteralPath (Join-Path $repoRoot 'release\latest.json') -Destination $manifestPath -Force

$oldEngine=$env:COCO_ENGINE_ROOT;$oldBootstrap=$env:COCO_BOOTSTRAPPER_EXE
try{
    $env:COCO_ENGINE_ROOT=$engineRoot
    Remove-Item Env:COCO_BOOTSTRAPPER_EXE -ErrorAction SilentlyContinue
    & (Join-Path $engineRoot 'CocoUpdater.ps1') -ManifestPath $manifestPath -LauncherTestRoot $audit
}finally{
    if($null-ne$oldEngine){$env:COCO_ENGINE_ROOT=$oldEngine}else{Remove-Item Env:COCO_ENGINE_ROOT -ErrorAction SilentlyContinue}
    if($null-ne$oldBootstrap){$env:COCO_BOOTSTRAPPER_EXE=$oldBootstrap}else{Remove-Item Env:COCO_BOOTSTRAPPER_EXE -ErrorAction SilentlyContinue}
}