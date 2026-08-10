$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$script:CocoEngineRoot=Join-Path $root 'engine'

$existingSession=@(Get-NetTCPConnection -State Listen -LocalPort 25564 -ErrorAction SilentlyContinue)
$existingGame=@(Get-NetTCPConnection -State Listen -LocalPort 25565 -ErrorAction SilentlyContinue)
if($existingSession.Count-or$existingGame.Count){throw 'Los puertos 25564/25565 estan ocupados; no se interrumpe una partida real.'}

$testRoot=Join-Path $env:TEMP "coco-launcher-host-$([guid]::NewGuid().ToString('N'))"
$statePath=Join-Path $testRoot 'active.json'
$readyMarker=Join-Path $testRoot 'ready-observed.txt'
$fakeGame=$null;$watcher=$null
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    $listenerScript=Join-Path $testRoot 'fake-game.ps1'
    [IO.File]::WriteAllText($listenerScript,@'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('10.77.37.1'),25565)
Start-Sleep -Milliseconds 600
try{$listener.Start(8);Start-Sleep -Milliseconds 9500}finally{$listener.Stop()}
'@,(New-Object Text.UTF8Encoding($true)))
    $watcherScript=Join-Path $testRoot 'watch-ready.ps1'
    [IO.File]::WriteAllText($watcherScript,@'
param([string]$StatePath,[string]$Marker)
$deadline=(Get-Date).AddSeconds(12)
while((Get-Date)-lt$deadline){
    if(Test-Path -LiteralPath $StatePath){
        try{if((Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json).state-eq'ready'){[IO.File]::WriteAllText($Marker,'ready');exit 0}}catch{}
    }
    Start-Sleep -Milliseconds 50
}
exit 3
'@,(New-Object Text.UTF8Encoding($true)))
    $watcher=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$watcherScript+'"'),'-StatePath',('"'+$statePath+'"'),'-Marker',('"'+$readyMarker+'"'))

    function Set-CocoState{param($Title,$Detail,$Progress)}
    function Resolve-CocoLauncherIdentityUi{[pscustomobject]@{mode='offline';username='HostAudit';uuid=''}}
    function Invoke-CocoManagedExperienceLaunch{[pscustomobject]@{Status='prepared'}}
    function Start-CocoLauncherExperience{
        $instanceRoot=Join-Path $testRoot 'instance'
        $world=Join-Path $instanceRoot 'saves\host-audit'
        New-Item -ItemType Directory -Path $world -Force|Out-Null
        [IO.File]::WriteAllBytes((Join-Path $world 'level.dat'),[byte[]](1,2,3))
        $script:fakeGame=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$listenerScript+'"'))
        [pscustomobject]@{Status='launched';Installation=[pscustomobject]@{InstanceRoot=$instanceRoot};Process=$script:fakeGame;LogPath=(Join-Path $testRoot 'fake.log')}
    }

    $catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
    $experience=@($catalog.experiences|Where-Object{$_.id-eq'into-the-backrooms'}|Select-Object -First 1)[0]
    $paths=[pscustomobject]@{
        SessionStatePath=$statePath
        SessionLogPath=(Join-Path $testRoot 'session.log')
        CatalogRoot=(Join-Path $root 'launcher')
        CacheRoot=(Join-Path $testRoot 'cache')
        ExperiencesRoot=(Join-Path $testRoot 'experiences')
        IdentityPath=(Join-Path $testRoot 'identity.json')
        SkinRoot=(Join-Path $testRoot 'skins\profiles')
        SkinStatePath=(Join-Path $testRoot 'skins\selection.json')
        MainDir=(Join-Path $testRoot 'shared')
        AccountDb=(Join-Path $testRoot 'accounts.json')
        InstanceLocationsPath=(Join-Path $testRoot 'instance-locations.json')
        ExperienceBackupRoot=(Join-Path $testRoot 'backups\experiences')
    }
    Invoke-CocoLauncherHostSession $catalog $experience $paths (Join-Path $env:APPDATA '.minecraft')
    if($watcher-and-not$watcher.HasExited){$watcher.WaitForExit(5000)|Out-Null}
    if(-not(Test-Path -LiteralPath $readyMarker)){throw 'El host no publico ready despues de detectar Minecraft en 25565.'}
    if(Test-Path -LiteralPath $statePath){throw 'El estado de sesion no se retiro al cerrar el juego.'}
    if(Get-NetTCPConnection -State Listen -LocalPort 25564,25565 -ErrorAction SilentlyContinue){throw 'Quedo un listener de prueba despues del cierre.'}
    'PASS: el host valida 25564, publica preparing/ready al detectar 25565 y retira la sesion al cerrar Minecraft.'
}finally{
    foreach($process in @($fakeGame,$watcher)){if($process){try{if(-not$process.HasExited){$process.Kill()}}catch{};try{$process.Dispose()}catch{}}}
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
