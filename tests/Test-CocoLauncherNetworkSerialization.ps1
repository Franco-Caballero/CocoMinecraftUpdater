$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))

$suffix=[guid]::NewGuid().ToString('N')
$networkName="Local\CocoLauncherNetworkTest-$suffix"
$legacyName="Local\CocoLauncherLegacyTest-$suffix"
$testRoot=Join-Path $env:TEMP "coco-launcher-network-$suffix"
$ready=Join-Path $testRoot 'ready'
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
$holder=$null
try{
    $code=@'
param([string]$Name,[string]$Ready)
$mutex=[Threading.Mutex]::new($false,$Name)
try{
    if(-not$mutex.WaitOne(5000)){exit 2}
    [IO.File]::WriteAllText($Ready,'ready')
    Start-Sleep -Milliseconds 1200
    $mutex.ReleaseMutex()|Out-Null
}finally{$mutex.Dispose()}
'@
    $holderScript=Join-Path $testRoot 'holder.ps1'
    [IO.File]::WriteAllText($holderScript,$code,(New-Object Text.UTF8Encoding($true)))
    $holder=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$holderScript+'"'),'-Name',$networkName,'-Ready',('"'+$ready+'"'))
    $deadline=(Get-Date).AddSeconds(5)
    while(-not(Test-Path -LiteralPath $ready)-and(Get-Date)-lt$deadline){Start-Sleep -Milliseconds 50}
    if(-not(Test-Path -LiteralPath $ready)){throw 'El proceso de prueba no adquirio el mutex.'}
    $script:networkOperationRan=$false
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=Invoke-CocoLauncherNetworkSerialized {$script:networkOperationRan=$true;'network-ok'} 5000 $networkName $legacyName
    $watch.Stop()
    if(-not$script:networkOperationRan-or$result-ne'network-ok'){throw 'La operacion serializada no se ejecuto.'}
    if($watch.ElapsedMilliseconds-lt700){throw 'La operacion no espero el mutex de red ocupado.'}
    'PASS: Coco Launcher espera la comprobacion de red en curso y ejecuta una sola reparacion a la vez.'
}finally{
    if($holder-and-not$holder.HasExited){$holder.Kill()}
    if($holder){$holder.Dispose()}
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
