[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BindAddress,
    [Parameter(Mandatory=$true)][int]$Port,
    [Parameter(Mandatory=$true)][string]$StatePath,
    [Parameter(Mandatory=$true)][int64]$ParentPid,
    [string]$SkinRoot='',
    [string]$LogPath='',
    [switch]$TestMode
)

$ErrorActionPreference='Stop'
if($Port-ne25564){throw 'Puerto de servicio Coco inesperado.'}
if($TestMode){if($BindAddress-ne'127.0.0.1'){throw 'TestMode solo permite loopback.'}}
elseif($BindAddress-ne'10.77.37.1'){throw 'El servicio Coco solo puede escuchar en la IP del host ZeroTier.'}
if([string]::IsNullOrWhiteSpace($StatePath)){throw 'Falta la ruta de estado Coco.'}
if([string]::IsNullOrWhiteSpace($SkinRoot)){
    $SkinRoot=Join-Path (Split-Path (Split-Path $StatePath -Parent) -Parent) 'skins\profiles'
}
New-Item -ItemType Directory -Path $SkinRoot -Force|Out-Null

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

function Get-SkinManifestJson{
    $profiles=@()
    foreach($file in Get-ChildItem -LiteralPath $SkinRoot -File -Filter '*.png'){
        $username=[IO.Path]::GetFileNameWithoutExtension($file.Name)
        if($username-notmatch'^[A-Za-z0-9_]{3,16}$'){continue}
        $profiles+=[ordered]@{username=$username;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=[int64]$file.Length}
    }
    ([ordered]@{schemaVersion=1;profiles=@($profiles|Sort-Object username);observedAtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress)
}

function Test-SkinBytes([byte[]]$Bytes){
    if(-not$Bytes-or$Bytes.Length-lt67-or$Bytes.Length-gt1048576){throw 'SIZE'}
    $signature=[byte[]](137,80,78,71,13,10,26,10)
    for($i=0;$i-lt8;$i++){if($Bytes[$i]-ne$signature[$i]){throw 'PNG'}}
    Add-Type -AssemblyName System.Drawing
    $memory=[IO.MemoryStream]::new($Bytes,$false);$image=$null
    try{
        $image=[Drawing.Image]::FromStream($memory,$true,$true)
        if($image.RawFormat.Guid-ne[Drawing.Imaging.ImageFormat]::Png.Guid-or$image.Width-ne64-or$image.Height-notin@(32,64)){throw 'DIMENSIONS'}
    }finally{if($image){$image.Dispose()};$memory.Dispose()}
}

function Write-SkinResponse($Stream,[string]$Status,[byte[]]$Body){
    if(-not$Body){$Body=[byte[]]@()}
    $header=[Text.Encoding]::ASCII.GetBytes("COCO-SKINS 1 $Status $($Body.Length)`n")
    $Stream.Write($header,0,$header.Length)
    if($Body.Length){$Stream.Write($Body,0,$Body.Length)}
    $Stream.Flush()
}

function Read-ExactBytes($Stream,[int]$Length){
    $buffer=New-Object byte[] $Length;$offset=0
    while($offset-lt$Length){
        $read=$Stream.Read($buffer,$offset,$Length-$offset)
        if($read-le0){throw 'BODY'}
        $offset+=$read
    }
    $buffer
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
            while($request.Length-lt256){$value=$stream.ReadByte();if($value-lt0){break};if($value-eq10){break};if($value-ne13){[void]$request.Append([char]$value)}}
            $line=$request.ToString()
            if($line-eq'COCO-SESSION 1'){
                $body=[Text.Encoding]::UTF8.GetBytes((Get-SessionJson))
                if($body.Length-gt32768){continue}
                $header=[Text.Encoding]::ASCII.GetBytes("COCO-SESSION 1 $($body.Length)`n")
                $stream.Write($header,0,$header.Length);$stream.Write($body,0,$body.Length);$stream.Flush()
                continue
            }
            $parts=@($line-split' ')
            if($parts.Count-lt3-or$parts[0]-ne'COCO-SKINS'-or$parts[1]-ne'1'){continue}
            try{
                switch($parts[2]){
                    'MANIFEST'{
                        if($parts.Count-ne3){throw 'REQUEST'}
                        Write-SkinResponse $stream 'OK' ([Text.Encoding]::UTF8.GetBytes((Get-SkinManifestJson)))
                    }
                    'GET'{
                        if($parts.Count-ne4-or$parts[3]-notmatch'^[A-Za-z0-9_]{3,16}$'){throw 'USERNAME'}
                        $path=Join-Path $SkinRoot "$($parts[3]).png"
                        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'NOT_FOUND'}
                        Write-SkinResponse $stream 'OK' ([IO.File]::ReadAllBytes($path))
                    }
                    'PUT'{
                        if($parts.Count-ne6-or$parts[3]-notmatch'^[A-Za-z0-9_]{3,16}$'){throw 'USERNAME'}
                        $length=0;if(-not[int]::TryParse($parts[4],[ref]$length)-or$length-lt67-or$length-gt1048576){throw 'SIZE'}
                        if($parts[5]-notmatch'^[a-fA-F0-9]{64}$'){throw 'HASH'}
                        $body=Read-ExactBytes $stream $length
                        $sha=[Security.Cryptography.SHA256]::Create();try{$actual=$sha.ComputeHash($body)}finally{$sha.Dispose()}
                        $actualHex=([BitConverter]::ToString($actual)).Replace('-','').ToLowerInvariant()
                        if($actualHex-ne$parts[5].ToLowerInvariant()){throw 'HASH'}
                        Test-SkinBytes $body
                        $ownerRoot=Join-Path $SkinRoot '.owners';New-Item -ItemType Directory -Path $ownerRoot -Force|Out-Null
                        $ownerPath=Join-Path $ownerRoot "$($parts[3]).json"
                        if(Test-Path -LiteralPath $ownerPath){
                            $owner=Get-Content -LiteralPath $ownerPath -Raw|ConvertFrom-Json
                            if($remoteAddress-ne'10.77.37.1'-and[string]$owner.address-ne$remoteAddress){throw 'OWNER'}
                        }else{
                            [IO.File]::WriteAllText($ownerPath,([ordered]@{schemaVersion=1;username=$parts[3];address=$remoteAddress;claimedAtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
                        }
                        $destination=Join-Path $SkinRoot "$($parts[3]).png";$temporary="$destination.new-$PID"
                        [IO.File]::WriteAllBytes($temporary,$body);Move-Item -LiteralPath $temporary -Destination $destination -Force
                        Write-SkinResponse $stream 'OK' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
                        Write-SessionLog "SKIN PUT username=$($parts[3]) remote=$remoteAddress sha256=$actualHex"
                    }
                    default{throw 'REQUEST'}
                }
            }catch{
                $code=([string]$_.Exception.Message-replace'[^A-Z_]','')
                if(-not$code){$code='ERROR'}
                Write-SkinResponse $stream "ERROR_$code" ([byte[]]@())
                Write-SessionLog "Skin request rejected remote=$remoteAddress code=$code"
            }
        }catch{Write-SessionLog "Solicitud rechazada: $($_.Exception.Message)"}
        finally{$client.Dispose()}
    }
}finally{
    $listener.Stop()
    Write-SessionLog 'STOPPED'
}
