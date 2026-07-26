[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$testRoot=Join-Path $env:TEMP "coco-skins-$([guid]::NewGuid())"
$service=$null
try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    Add-Type -AssemblyName System.Drawing
    $source=Join-Path $testRoot 'source.png'
    $bitmap=[Drawing.Bitmap]::new(64,64)
    try{
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try{$graphics.Clear([Drawing.Color]::FromArgb(255,140,40,190))}finally{$graphics.Dispose()}
        $bitmap.Save($source,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$bitmap.Dispose()}
    $invalid=Join-Path $testRoot 'invalid.png'
    $bitmap=[Drawing.Bitmap]::new(32,32);try{$bitmap.Save($invalid,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
    $rejected=$false;try{[void](Test-CocoSkinPng $invalid)}catch{$rejected=$_.Exception.Message-match'64x64'}
    if(-not$rejected){throw 'Coco acepto una skin con dimensiones invalidas.'}

    $catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
    $catalog.sessionDiscovery.host='127.0.0.1'
    $hostSkins=Join-Path $testRoot 'host-skins';$state=Join-Path $testRoot 'active.json';$log=Join-Path $testRoot 'service.log'
    [IO.File]::WriteAllText($state,'{"schemaVersion":1,"state":"ready","sessionId":"11111111-1111-1111-1111-111111111111","experienceId":"into-the-backrooms","packVersion":"2.0.3","issuedAtUtc":"2026-07-25T00:00:00Z","expiresAtUtc":"2099-07-25T00:00:00Z"}')
    $serviceScript=Join-Path $root 'engine\CocoSessionService.ps1'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$serviceScript+'"'),'-BindAddress','127.0.0.1','-Port','25564','-StatePath',('"'+$state+'"'),'-SkinRoot',('"'+$hostSkins+'"'),'-ParentPid',[string]$PID,'-LogPath',('"'+$log+'"'),'-TestMode')
    $start=[Diagnostics.ProcessStartInfo]::new('powershell.exe',($arguments-join' '));$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $service=[Diagnostics.Process]::Start($start)
    $deadline=(Get-Date).AddSeconds(5);while((Get-Date)-lt$deadline-and-not(Test-CocoTcpEndpoint '127.0.0.1' 25564 200)){if($service.HasExited){throw 'El servicio de skins termino anticipadamente.'};Start-Sleep -Milliseconds 100}
    if(-not(Test-CocoTcpEndpoint '127.0.0.1' 25564 200)){throw 'El servicio de skins no abrio loopback.'}
    if(-not(Test-CocoSkinServiceEndpoint '127.0.0.1' 25564 500)){throw 'El puerto abrio, pero no expuso el protocolo de skins Coco.'}

    # No elegir una skin es un estado normal: el jugador conserva la apariencia
    # predeterminada y la sincronizacion no puede bloquear su lanzamiento.
    $clientWithoutSkin=[pscustomobject]@{
        SkinRoot=(Join-Path $testRoot 'client-without-skin\profiles')
        SkinStatePath=(Join-Path $testRoot 'client-without-skin\selection.json')
    }
    $withoutSkin=Sync-CocoSkinRegistry $catalog $clientWithoutSkin ([pscustomobject]@{mode='offline';username='NoSkin';uuid=''})
    if(-not$withoutSkin.Online-or$withoutSkin.Pending-or$withoutSkin.Uploaded-or$withoutSkin.Downloaded-ne0){
        throw "Un jugador sin skin propia no pudo continuar normalmente: $($withoutSkin.Error)"
    }
    $emptyInstance=Join-Path $testRoot 'empty-instance'
    if((Install-CocoSkinRegistry $clientWithoutSkin.SkinRoot $emptyInstance)-ne0){
        throw 'Coco invento una skin para un jugador que no eligio ninguna.'
    }

    $clientA=[pscustomobject]@{SkinRoot=(Join-Path $testRoot 'client-a\profiles');SkinStatePath=(Join-Path $testRoot 'client-a\selection.json')}
    $identity=[pscustomobject]@{mode='offline';username='PlayerOne';uuid=''}
    [void](Import-CocoUserSkin $source $identity.username $clientA.SkinRoot $clientA.SkinStatePath)
    $sync=Sync-CocoSkinRegistry $catalog $clientA $identity
    if(-not$sync.Online-or-not$sync.Uploaded-or$sync.Pending){throw "La skin local no se subio: $($sync.Error)"}
    $hostSkin=Join-Path $hostSkins 'PlayerOne.png'
    if(-not(Test-Path $hostSkin)-or(Get-FileHash $hostSkin -Algorithm SHA256).Hash-ne(Get-FileHash $source -Algorithm SHA256).Hash){throw 'El host no conservo la skin exacta.'}

    $clientB=[pscustomobject]@{SkinRoot=(Join-Path $testRoot 'client-b\profiles');SkinStatePath=(Join-Path $testRoot 'client-b\selection.json')}
    $sync=Sync-CocoSkinRegistry $catalog $clientB ([pscustomobject]@{mode='offline';username='PlayerTwo';uuid=''})
    if(-not$sync.Online-or$sync.Downloaded-ne1-or-not(Test-Path (Join-Path $clientB.SkinRoot 'PlayerOne.png'))){throw "Otro cliente no recibio la skin: $($sync.Error)"}
    $instance=Join-Path $testRoot 'instance';New-Item -ItemType Directory -Path $instance -Force|Out-Null
    if((Install-CocoSkinRegistry $clientB.SkinRoot $instance)-ne1-or-not(Test-Path (Join-Path $instance 'CustomSkinLoader\LocalSkin\skins\PlayerOne.png'))){throw 'La skin sincronizada no se instalo en LocalSkin.'}
    $original=Join-Path $testRoot 'original-minecraft';New-Item -ItemType Directory -Path $original -Force|Out-Null
    if((Install-CocoSkinRegistry $clientB.SkinRoot $original)-ne1-or-not(Test-Path (Join-Path $original 'CustomSkinLoader\LocalSkin\skins\PlayerOne.png'))){throw 'La skin sincronizada no llego al mundo original.'}
    $preview=New-CocoSkinHeadPreview (Join-Path $clientB.SkinRoot 'PlayerOne.png') 40
    try{if(-not$preview-or$preview.Width-ne40-or$preview.Height-ne40){throw 'La previsualizacion de cabeza no tiene el tamano esperado.'}}finally{if($preview){$preview.Dispose()}}
    'PASS: skin opcional, PNG, preview, subida privada, manifiesto y LocalSkin de experiencias/mundo original sincronizados.'
}finally{
    if($service){try{if(-not$service.HasExited){$service.Kill()}}catch{};try{$service.Dispose()}catch{}}
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
