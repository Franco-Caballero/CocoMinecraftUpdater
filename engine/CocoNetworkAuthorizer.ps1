[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{16}$')][string]$NetworkId,
    [int64]$WatchPid=0,
    [int]$PollSeconds=2,
    [int]$MaximumHours=12,
    [switch]$Once
)

$ErrorActionPreference='Stop'
if($NetworkId-ne'58997fc5f3c0c001'){exit 2}
$stateRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\network'
$logRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\logs'
New-Item -ItemType Directory -Path $stateRoot,$logRoot -Force|Out-Null
$logPath=Join-Path $logRoot 'zerotier-authorizer.log'
$statusPath=Join-Path $stateRoot "authorizer-$NetworkId.json"

function Write-AuthorizerLog([string]$Text){
    try{Add-Content -LiteralPath $logPath -Value ("{0:o} {1}"-f(Get-Date),$Text) -Encoding UTF8}catch{}
}
function Write-AuthorizerStatus([bool]$Healthy,[string]$Error='',[bool]$Running=$true){
    try{
        $tmp="$statusPath.tmp-$PID"
        [ordered]@{healthy=$Healthy;running=$Running;error=$Error;processId=$PID;watchPid=$WatchPid;updatedAt=(Get-Date).ToString('o')}|
            ConvertTo-Json|Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $statusPath -Force
    }catch{}
}
function Get-ControllerToken {
    $paths=@(
        $env:COCO_ZEROTIER_TOKEN_PATH,
        'C:\ProgramData\ZeroTier\One\authtoken.secret',
        'C:\ProgramData\ZeroTier\authtoken.secret'
    )|Where-Object{$_}
    $path=@($paths|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
    if(-not$path){throw 'No se encontro el token local de ZeroTier.'}
    return (Get-Content -LiteralPath $path -Raw).Trim()
}
function Invoke-AuthorizationPass {
    $token=Get-ControllerToken
    $headers=@{'X-ZT1-Auth'=$token}
    $base=if($env:COCO_ZEROTIER_API_BASE){$env:COCO_ZEROTIER_API_BASE.TrimEnd('/')}else{'http://127.0.0.1:9993'}
    $members=Invoke-RestMethod -Method Get -Uri "$base/controller/network/$NetworkId/member" -Headers $headers -TimeoutSec 10
    $authorizedAny=$false
    foreach($property in @($members.PSObject.Properties)){
        $nodeId=[string]$property.Name
        if($nodeId-notmatch'^[0-9a-f]{10}$'){continue}
        $uri="$base/controller/network/$NetworkId/member/$nodeId"
        $member=Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 10
        if($member.authorized){continue}
        $body=@{authorized=$true}|ConvertTo-Json -Compress
        $updated=Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 10
        if(-not$updated.authorized){throw "El controlador no autorizo el nodo $nodeId."}
        $authorizedAny=$true
        Write-AuthorizerLog "Nodo autorizado automaticamente: $nodeId"
    }
    if($authorizedAny){
        # A first join can receive ACCESS_DENIED a few milliseconds before this pass.
        # Republishing the network config makes the controller reissue it promptly,
        # instead of making the friend wait for ZeroTier's next slow config retry.
        $networkUri="$base/controller/network/$NetworkId"
        $network=Invoke-RestMethod -Method Get -Uri $networkUri -Headers $headers -TimeoutSec 10
        $refreshed=Invoke-RestMethod -Method Post -Uri $networkUri -Headers $headers -ContentType 'application/json' `
            -Body ($network|ConvertTo-Json -Depth 16 -Compress) -TimeoutSec 10
        if(-not$refreshed-or[string]$refreshed.id-ne$NetworkId){throw 'No se pudo refrescar la configuracion de la red.'}
        Write-AuthorizerLog "Configuracion de red republicada tras autorizar nuevos nodos. Revision=$($refreshed.revision)"
    }
}

$mutexName='Local\CocoZeroTierAuthorizer-'+$NetworkId
$mutex=New-Object Threading.Mutex($false,$mutexName)
if(-not$mutex.WaitOne(0)){exit 0}
try{
    Write-AuthorizerLog "Autorizador iniciado. NetworkId=$NetworkId WatchPid=$WatchPid"
    $deadline=(Get-Date).AddHours([Math]::Max(1,$MaximumHours))
    do{
        try{
            Invoke-AuthorizationPass
            Write-AuthorizerStatus $true
        }catch{
            Write-AuthorizerLog "Error temporal: $($_.Exception.Message)"
            Write-AuthorizerStatus $false $_.Exception.Message
            if($Once){throw}
        }
        if($Once){break}
        if($WatchPid-gt0-and-not(Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)){break}
        if($WatchPid-le0-and(Get-Date)-ge$deadline){break}
        Start-Sleep -Seconds ([Math]::Max(1,$PollSeconds))
    }while($true)
    Write-AuthorizerLog 'Autorizador detenido.'
}finally{
    Write-AuthorizerStatus $true '' $false
    $mutex.ReleaseMutex()|Out-Null
    $mutex.Dispose()
}
