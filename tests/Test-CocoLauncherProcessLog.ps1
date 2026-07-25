$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))

$testRoot=Join-Path $env:TEMP ('coco-launcher-process-log-'+[guid]::NewGuid().ToString('N'))
$log=Join-Path $testRoot 'portablemc.log'
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    # Supera ampliamente el buffer habitual del pipe. Si Coco deja de leer al
    # ocultarse, este hijo se bloquea y la regresion vence por timeout.
    $command="1..12000 | ForEach-Object { Write-Output ('coco-stdout-'+`$_) }; [Console]::Error.WriteLine('coco-stderr')"
    $process=Start-CocoPortableMcGame (Get-Command powershell.exe -ErrorAction Stop).Source @('-NoProfile','-Command',$command) $log
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $exitCode=Wait-CocoPortableMcGame $process -Dispose
    $watch.Stop()
    if($watch.Elapsed.TotalSeconds-gt30){throw 'El supervisor no dreno los pipes dentro del plazo esperado.'}
    if($exitCode-ne0){throw "El proceso de prueba termino con codigo $exitCode."}
    $deadline=(Get-Date).AddSeconds(5)
    do{
        $text=if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log -Raw}else{''}
        if($text-match'coco-stdout-12000'-and$text-match'coco-stderr'){break}
        Start-Sleep -Milliseconds 100
    }while((Get-Date)-lt$deadline)
    if($text-notmatch'coco-stdout-12000'-or$text-notmatch'coco-stderr'){throw 'El capturador no dreno stdout y stderr completos.'}
    'PASS: Coco supervisa el proceso hasta el final y drena ambos pipes sin callbacks PowerShell.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
