$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))

$testRoot=Join-Path $env:TEMP "coco-launcher-client-$([guid]::NewGuid().ToString('N'))"
$engineRoot=Join-Path $testRoot 'engine'
$logPath=Join-Path $testRoot 'client-child.log'
New-Item -ItemType Directory -Path (Join-Path $engineRoot 'launcher'),(Join-Path $testRoot 'legacy') -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $root 'launcher\catalog.template.json') -Destination (Join-Path $engineRoot 'launcher\catalog.json')
$skinPath=Join-Path $engineRoot 'assets\skins\smolbird.png';New-Item -ItemType Directory -Path (Split-Path $skinPath -Parent) -Force|Out-Null
[IO.File]::WriteAllBytes($skinPath,[Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $root 'launcher\assets\skins\smolbird.png.base64'))).Trim()))
$script:CocoEngineRoot=$engineRoot
$script:managedCalls=0
try{
    function Show-CocoWindow{
        $script:CocoForm=New-Object Windows.Forms.Form
        $script:CocoPanel=New-Object Windows.Forms.Panel;$script:CocoPanel.Size=New-Object Drawing.Size(640,460)
        $script:CocoAccent=New-Object Windows.Forms.Panel;$script:CocoBrand=New-Object Windows.Forms.Label
        $script:CocoTitle=New-Object Windows.Forms.Label;$script:CocoDetail=New-Object Windows.Forms.Label
        $script:CocoForm.Controls.Add($script:CocoPanel)
        $script:CocoPanel.Controls.AddRange(@($script:CocoAccent,$script:CocoBrand,$script:CocoTitle,$script:CocoDetail))
    }
    function Set-CocoState{param($Title,$Detail,$Progress)}
    function Write-CocoLog{param($Message)}
    function Ensure-CocoNetwork{[pscustomobject]@{enabled=$true}}
    function Get-CocoSessionAnnouncement{
        param($Catalog)
        $experience=@($Catalog.experiences|Where-Object id -eq 'into-the-backrooms'|Select-Object -First 1)[0]
        [pscustomobject]@{State='ready';Experience=$experience;Announcement=[pscustomobject]@{sessionId='11111111-1111-1111-1111-111111111111'}}
    }
    function Resolve-CocoLauncherIdentityUi{[pscustomobject]@{mode='offline';username='ClientAudit';uuid=''}}
    function Invoke-CocoManagedExperienceLaunch{
        param($Catalog,$ExperienceId,$Identity,$Role,$CatalogRoot,$CacheRoot,$ExperiencesRoot,[switch]$Dry,[switch]$DisableAutoJoin)
        $script:managedCalls++
        if($Dry){return [pscustomobject]@{Status='prepared'}}
        $command="1..12000 | ForEach-Object { Write-Output ('client-line-'+`$_) }; Start-Sleep -Milliseconds 500"
        $process=Start-CocoPortableMcGame (Get-Command powershell.exe -ErrorAction Stop).Source @('-NoProfile','-Command',$command) $logPath
        [pscustomobject]@{Status='launched';Process=$process;LogPath=$logPath}
    }

    # El catalogo plantilla se versiona durante New-CocoEngine; esta prueba
    # directa usa deliberadamente el placeholder actual de la plantilla.
    $manifest=[pscustomobject]@{version='0.5.47';network=$null}
    Start-CocoLauncherUi $manifest (Join-Path $testRoot 'legacy')
    if($script:managedCalls-ne2){throw "El cliente hizo $script:managedCalls preparaciones/lanzamientos; se esperaban dry + launch."}
    if(-not$script:CocoForm.IsDisposed){throw 'La UI cliente no se cerro despues de terminar el juego.'}
    $text=Get-Content -LiteralPath $logPath -Raw
    if($text-notmatch'client-line-12000'){throw 'La UI cliente cerro Coco antes de drenar el proceso lanzado.'}
    'PASS: el cliente selecciona la sesion sin menu, prepara, oculta Coco, supervisa el juego y cierra al terminar.'
}finally{
    if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Dispose()}
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
