[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$testRoot=Join-Path $env:TEMP "coco-launcher-local-zerotier-$([guid]::NewGuid())"
$service=$null

try{
    $address=@(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '10.77.37.1' -ErrorAction SilentlyContinue)
    if(-not$address.Count){throw 'Este equipo no tiene activa la IP host ZeroTier 10.77.37.1.'}
    $listener=@(Get-NetTCPConnection -State Listen -LocalPort 25564 -ErrorAction SilentlyContinue)
    if($listener.Count){throw 'El puerto 25564 ya esta ocupado; no se interrumpe una sesion Coco real.'}

    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $statePath=Join-Path $testRoot 'active.json'
    $logPath=Join-Path $testRoot 'service.log'
    $sessionId=[guid]::NewGuid().ToString()
    [void](Publish-CocoSessionAnnouncement $catalog 'into-the-backrooms' ready $sessionId $statePath 30)
    $service=Start-CocoSessionService (Join-Path $root 'engine\CocoSessionService.ps1') $statePath $logPath $PID

    $deadline=(Get-Date).AddSeconds(8)
    do{
        Start-Sleep -Milliseconds 100
        $ready=(Test-Path -LiteralPath $logPath)-and((Get-Content -LiteralPath $logPath -Raw)-match'READY 10\.77\.37\.1:25564')
    }while(-not$ready-and-not$service.HasExited-and(Get-Date)-lt$deadline)
    if(-not$ready){throw 'El servicio no pudo escuchar sobre la interfaz ZeroTier real.'}

    $remote=Get-CocoSessionAnnouncement $catalog
    if($remote.State-ne'ready'-or$remote.Experience.id-ne'into-the-backrooms'-or$remote.Announcement.sessionId-ne$sessionId){
        throw 'La consulta local por ZeroTier no recupero la sesion administrada exacta.'
    }
    'PASS: servicio productivo 10.77.37.1:25564, filtro de origen y consulta local ZeroTier validados.'
}finally{
    if($service-and-not$service.HasExited){Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue}
    if($service){$service.Dispose()}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
