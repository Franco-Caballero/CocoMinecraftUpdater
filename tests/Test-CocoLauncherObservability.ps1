[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcher=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
$engine=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
$bootstrap=[IO.File]::ReadAllText((Join-Path $root 'bootstrap\CocoBootstrapper.ps1'))
$checklist=Join-Path $root 'docs\ModpackCompatibilityChecklist.md'

foreach($pattern in 'function Set-CocoLauncherStep','Archivo \$\(\$ProgressContext\.Index\)/\$\(\$ProgressContext\.Count\)','Verificado y reutilizado desde la cache','INSTALANDO LA INSTANCIA AISLADA','Tiempo transcurrido','function Wait-CocoManagedMinecraftWindow','CONECTANDO AUTOMATICAMENTE','--continue-at','clientFailureCount','terminalFailure','Cierra y vuelve a abrir Coco Launcher','Parcial completo verificado','solicitar rango'){
    if($launcher-notmatch$pattern){throw "Falta observabilidad launcher: $pattern"}
}
foreach($pattern in 'range not satisfiable','responseStatus','partial-invalid-restart-clean'){
    if($engine-notmatch$pattern){throw "Falta observabilidad del descargador: $pattern"}
}
foreach($pattern in 'function Write-CocoStorageDiagnostic',"Write-CocoStorageDiagnostic 'location\.prompt","Write-CocoStorageDiagnostic 'move\.ui","Write-CocoStorageDiagnostic 'delete\.ui","Write-CocoStorageDiagnostic 'install\.ui"){
    if($launcher-notmatch$pattern){throw "Falta diagnostico de almacenamiento launcher: $pattern"}
}
foreach($pattern in 'function Write-CocoTimelineEvent','Failure ID:','Get-CocoFailureClassification','COCO DETECTO UN PROBLEMA'){
    if(($engine+$launcher)-notmatch$pattern){throw "Falta observabilidad/diagnostico: $pattern"}
}
if($bootstrap-notmatch'MB/s'-or$bootstrap-notmatch'Run ID:'){throw 'El bootstrap no informa descarga granular o correlacion.'}
if($engine-notmatch'LOGS AUXILIARES RELEVANTES'-or$engine-notmatch'launcher-session-service\.log'-or$engine-notmatch'BepInEx\\LogOutput\.log'){
    throw 'El diagnostico del Escritorio no consolida los logs auxiliares relevantes.'
}
if($launcher-match'New-Object Drawing\.Point\(\(\$index%2\)\*260') {throw 'El selector host reintrodujo el constructor ambiguo que produce Object[]/op_Multiply.'}
$checklistText=if(Test-Path -LiteralPath $checklist){[IO.File]::ReadAllText($checklist)}else{''}
if([string]::IsNullOrWhiteSpace($checklistText)-or$checklistText-notmatch'fricci.n externa'){throw 'Falta la puerta reutilizable para nuevos modpacks.'}

'PASS: etapas, bytes/archivos, heartbeat, espera Java, diagnostico y checklist protegidos.'
