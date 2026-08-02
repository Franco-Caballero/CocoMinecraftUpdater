[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$testRoot=Join-Path $env:TEMP "coco-launcher-session-$([guid]::NewGuid())"
$service=$null
try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $statePath=Join-Path $testRoot 'active.json'
    $sessionId=[guid]::NewGuid().ToString()
    $externalRejected=$false
    try{[void](Publish-CocoSessionAnnouncement $catalog 'coco-original' preparing $sessionId $statePath 30)}catch{$externalRejected=$_.Exception.Message-match'launcher externo'}
    if(-not$externalRejected){throw 'El servicio permitio anunciar Coco original como experiencia administrada.'}

    $published=Publish-CocoSessionAnnouncement $catalog 'into-the-backrooms' preparing $sessionId $statePath 30
    $validated=Test-CocoSessionAnnouncement $catalog $published
    if($validated.State-ne'preparing'-or$validated.Experience.id-ne'into-the-backrooms'){throw 'La sesion publicada no se valido.'}

    $bad=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    $bad.packVersion='malicious-version'
    $rejected=$false
    try{[void](Test-CocoSessionAnnouncement $catalog $bad)}catch{$rejected=$_.Exception.Message-match'packVersion'}
    if(-not$rejected){throw 'Se acepto una sesion con packVersion distinto al catalogo.'}

    $published=Publish-CocoSessionAnnouncement $catalog 'into-the-backrooms' ready $sessionId $statePath 30
    $loopback=Get-Content -LiteralPath (Join-Path $root 'launcher\catalog.template.json') -Raw|ConvertFrom-Json
    $loopback.sessionDiscovery.host='127.0.0.1'
    $log=Join-Path $testRoot 'service.log'
    $script=Join-Path $root 'engine\CocoSessionService.ps1'
    $serviceText=[IO.File]::ReadAllText($script)
    if($serviceText-notmatch"-not\`$TestMode-and\`$state\.state-in@\('preparing','ready'\)"-or$serviceText-notmatch'AddSeconds\(30\)'){
        throw 'El servicio no mantiene el lease mientras el launcher host instala.'
    }
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'),'-BindAddress','127.0.0.1','-Port','25564','-StatePath',('"'+$statePath+'"'),'-ParentPid',[string]$PID,'-LogPath',('"'+$log+'"'),'-TestMode')
    $service=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
    $deadline=(Get-Date).AddSeconds(8)
    do{Start-Sleep -Milliseconds 100;if(Test-Path $log){$ready=try{(Get-Content $log -Raw -ErrorAction SilentlyContinue)-match'READY'}catch{$false}}}while(-not$ready-and-not$service.HasExited-and(Get-Date)-lt$deadline)
    if(-not$ready){throw 'El servicio de sesion de prueba no inicio.'}
    $remote=Get-CocoSessionAnnouncement $loopback
    if($remote.State-ne'ready'-or$remote.Announcement.sessionId-ne$sessionId){throw 'El cliente no obtuvo la unica sesion ready.'}
    $action=Get-CocoClientSessionAction $remote
    if($action.Action-ne'launch'-or$action.Experience.id-ne'into-the-backrooms'){throw 'El cliente no auto-selecciono la unica sesion ready.'}

    $expired=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
    $expired.expiresAtUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    $expired|ConvertTo-Json -Compress|Set-Content -LiteralPath $statePath -Encoding UTF8
    $remote=Get-CocoSessionAnnouncement $loopback
    if($remote.State-ne'offline'){throw 'El servicio no convirtio una sesion expirada en offline.'}
    $action=Get-CocoClientSessionAction $remote
    if($action.Action-ne'wait'-or$action.Message-ne'No hay ninguna partida Coco online'){throw 'El UX offline no coincide.'}

    'PASS: publicacion, protocolo TCP, sesion unica, coincidencia de pack y expiracion validados.'
}finally{
    if($service-and-not$service.HasExited){Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue}
    if($service){$service.Dispose()}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
