[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BindAddress,
    [Parameter(Mandatory=$true)][int]$Port,
    [Parameter(Mandatory=$true)][string]$StatePath,
    [Parameter(Mandatory=$true)][int64]$ParentPid,
    [string]$LogPath='',
    [switch]$TestMode
)

$ErrorActionPreference='Stop'
if($Port-ne25564){throw 'Puerto de servicio Coco inesperado.'}
if($TestMode){if($BindAddress-ne'127.0.0.1'){throw 'TestMode solo permite loopback.'}}
elseif($BindAddress-ne'10.77.37.1'){throw 'El servicio Coco solo puede escuchar en la IP del host ZeroTier.'}
if([string]::IsNullOrWhiteSpace($StatePath)){throw 'Falta la ruta de estado Coco.'}

function Write-SessionLog([string]$Message){
    if([string]::IsNullOrWhiteSpace($LogPath)){return}
    try{
        $parent=Split-Path $LogPath -Parent
        New-Item -ItemType Directory -Path $parent -Force|Out-Null
        Add-Content -LiteralPath $LogPath -Value ("{0} {1}"-f(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Message) -Encoding UTF8
    }catch{}
}

function Get-SessionJson{
    $offline=[ordered]@{schemaVersion=1;state='offline';observedAtUtc=[DateTime]::UtcNow.ToString('o')}
    if(-not(Test-Path -LiteralPath $StatePath -PathType Leaf)){return ($offline|ConvertTo-Json -Compress)}
    try{
        $text=Get-Content -LiteralPath $StatePath -Raw
        if([Text.Encoding]::UTF8.GetByteCount($text)-gt32768){throw 'Estado demasiado grande.'}
        $state=$text|ConvertFrom-Json
        if([int]$state.schemaVersion-ne1-or$state.state-notin@('preparing','ready','stopping')){throw 'Estado no permitido.'}
        $expires=[DateTime]::Parse([string]$state.expiresAtUtc).ToUniversalTime()
        $now=[DateTime]::UtcNow
        if($expires-le$now-and($TestMode-or$state.state-eq'stopping')){return ($offline|ConvertTo-Json -Compress)}
        # En producción este proceso es el lease holder: sólo existe mientras
        # vive el launcher padre. Renueva la respuesta aunque el hilo UI esté
        # instalando un pack grande y no pueda reescribir active.json.
        if(-not$TestMode-and$state.state-in@('preparing','ready')){
            $state.issuedAtUtc=$now.ToString('o')
            $state.expiresAtUtc=$now.AddSeconds(30).ToString('o')
        }
        return ($state|ConvertTo-Json -Compress)
    }catch{
        Write-SessionLog "Estado rechazado: $($_.Exception.Message)"
        return ($offline|ConvertTo-Json -Compress)
    }
}

$address=[Net.IPAddress]::Parse($BindAddress)
$listener=[Net.Sockets.TcpListener]::new($address,$Port)
try{
    $listener.Start(8)
    Write-SessionLog "READY $BindAddress`:$Port ParentPid=$ParentPid"
    while($true){
        if($ParentPid-gt0-and-not(Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)){break}
        if(-not$listener.Pending()){Start-Sleep -Milliseconds 150;continue}
        $client=$listener.AcceptTcpClient()
        try{
            $remote=[Net.IPEndPoint]$client.Client.RemoteEndPoint
            $remoteAddress=$remote.Address.ToString()
            if(-not$TestMode-and$remoteAddress-notmatch'^10\.77\.37\.(?:[1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$'){continue}
            $stream=$client.GetStream();$stream.ReadTimeout=2000;$stream.WriteTimeout=2000
            $request=[Text.StringBuilder]::new()
            while($request.Length-lt64){$value=$stream.ReadByte();if($value-lt0){break};if($value-eq10){break};if($value-ne13){[void]$request.Append([char]$value)}}
            if($request.ToString()-ne'COCO-SESSION 1'){continue}
            $json=Get-SessionJson
            $body=[Text.Encoding]::UTF8.GetBytes($json)
            if($body.Length-gt32768){continue}
            $header=[Text.Encoding]::ASCII.GetBytes("COCO-SESSION 1 $($body.Length)`n")
            $stream.Write($header,0,$header.Length);$stream.Write($body,0,$body.Length);$stream.Flush()
        }catch{Write-SessionLog "Solicitud rechazada: $($_.Exception.Message)"}
        finally{$client.Dispose()}
    }
}finally{
    $listener.Stop()
    Write-SessionLog 'STOPPED'
}
