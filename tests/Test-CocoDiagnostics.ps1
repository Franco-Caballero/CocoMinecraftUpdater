[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$enginePath=Join-Path $root 'engine\CocoUpdater.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($enginePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'CocoUpdater.ps1 no se pudo analizar para probar diagnosticos.'}
$required=@('Write-CocoLog','Set-CocoDiagnosticContext','Write-CocoTimelineEvent','Get-CocoDiagnosticTail','Get-CocoFailureClassification','Write-CocoEngineDiagnostic')
foreach($name in $required){
    $function=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq$name},$true)|Select-Object -First 1)[0]
    if(-not$function){throw "Falta la funcion diagnostica $name."}
    . ([ScriptBlock]::Create($function.Extent.Text))
}

$testRoot=Join-Path $env:TEMP "coco-diagnostics-$([guid]::NewGuid().ToString('N'))"
$oldLocal=$env:LOCALAPPDATA
try{
    $env:LOCALAPPDATA=$testRoot
    $script:CocoLogDirectory=Join-Path $testRoot 'logs';$desktop=Join-Path $testRoot 'Desktop'
    New-Item -ItemType Directory -Path $script:CocoLogDirectory,$desktop,(Join-Path $testRoot 'CocoMinecraftUpdater\launcher') -Force|Out-Null
    $script:CocoDiagnosticDesktopOverride=$desktop
    $script:CocoLogPath=Join-Path $script:CocoLogDirectory 'updater-test.log'
    $script:CocoRunId='11223344556677889900aabbccddeeff'
    $script:CocoRunStartedUtc=[DateTime]::UtcNow;$script:CocoRunWatch=[Diagnostics.Stopwatch]::StartNew()
    $script:CocoTimelinePath=Join-Path $script:CocoLogDirectory "run-$($script:CocoRunId).jsonl"
    $script:CocoTimelineSequence=0;$script:CocoLastTimelineSignature='';$script:CocoLastTimelineAt=[DateTime]::MinValue;$script:CocoCurrentProgress=47
    $script:CocoEngineRoot=$root
    $instance=Join-Path $testRoot 'instance';New-Item -ItemType Directory -Path (Join-Path $instance 'logs'),(Join-Path $instance '.coco') -Force|Out-Null
    'minecraft-tail-marker'|Set-Content -LiteralPath (Join-Path $instance 'logs\latest.log') -Encoding UTF8
    '{"experienceId":"diagnostic-pack"}'|Set-Content -LiteralPath (Join-Path $instance '.coco\managed-state.json') -Encoding UTF8
    $script:CocoDiagnosticContext=[ordered]@{component='launcher';mode='launcher';role='client';experienceId='diagnostic-pack';packVersion='9.9';instanceRoot=$instance;stage='inicio'}
    $identity=@{schemaVersion=1;mode='microsoft';username='TestPlayer';uuid='12345678-1234-1234-1234-123456789abc';decisionSource='test';configuredAtUtc=[DateTime]::UtcNow.ToString('o');accessToken='SECRET-MUST-NOT-LEAK'}
    $identity|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $testRoot 'CocoMinecraftUpdater\launcher\identity.json') -Encoding UTF8
    $script:manifest=[pscustomobject]@{version='9.9'};$script:selected=[pscustomobject]@{Root=$instance}
    $script:ManifestPath='test-manifest.json';$script:MinecraftPid=0;$script:NetworkOnly=$false;$script:Silent=$false;$script:ShowOnUpdate=$false
    Write-CocoTimelineEvent 'ETAPA 4/10 | DESCARGANDO PACK' 'Archivo 4/80 | ejemplo.jar' 47 'download'
    try{throw 'PortableMC no pudo preparar Java/Forge.'}catch{$record=$_}
    $path=Write-CocoEngineDiagnostic $record
    if(-not$path-or-not(Test-Path -LiteralPath $path)){throw 'No se creo el diagnostico en el Escritorio simulado.'}
    $report=Get-Content -LiteralPath $path -Raw
    foreach($marker in 'Failure ID: COCO-','Run ID: 11223344556677889900aabbccddeeff','Classification: RUNTIME','Recommended next action:','ETAPA 4/10 | DESCARGANDO PACK','diagnostic-pack','minecraft-tail-marker','PRIVACIDAD'){
        if($report-notlike"*$marker*"){throw "El diagnostico no contiene: $marker"}
    }
    if($report-like'*SECRET-MUST-NOT-LEAK*'){throw 'El diagnostico filtro un token guardado en identity.json.'}
    'PASS: diagnostico correlacionado, clasificado, accionable y sin tokens validado.'
}finally{
    $env:LOCALAPPDATA=$oldLocal
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
