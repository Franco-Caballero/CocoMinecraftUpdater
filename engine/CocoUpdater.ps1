[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [string]$ManifestUrl,
    [string]$GameDir,
    [int64]$MinecraftPid = 0,
    [string]$SessionStatePath,
    [string]$RunningPackVersion,
    [ValidateRange(1,120)][int]$AutomaticCloseTimeoutSeconds = 8,
    [switch]$Preview,
    [switch]$DetectOnly,
    [switch]$NetworkOnly,
    [switch]$ShowOnUpdate,
    [switch]$Silent,
    [switch]$TestSuppressUi,
    [string]$LauncherTestRoot
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if([string]::IsNullOrWhiteSpace($RunningPackVersion)-and-not[string]::IsNullOrWhiteSpace($env:COCO_RUNNING_PACK_VERSION)){
    $RunningPackVersion=$env:COCO_RUNNING_PACK_VERSION
}
if($env:COCO_SHOW_ON_UPDATE-eq'1'){$ShowOnUpdate=$true}
$automaticFullCheck=$MinecraftPid-gt0-and-not$NetworkOnly
$script:CocoEngineRoot=if($env:COCO_ENGINE_ROOT-and(Test-Path -LiteralPath $env:COCO_ENGINE_ROOT)){$env:COCO_ENGINE_ROOT}else{$PSScriptRoot}
$script:CocoForm = $null
$script:CocoCurrentProgress = 0
$script:CocoVisualWorkStarted = $null
$script:CocoLogDirectory = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\logs'
New-Item -ItemType Directory -Path $script:CocoLogDirectory -Force | Out-Null
Get-ChildItem -LiteralPath $script:CocoLogDirectory -File -Filter '*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 40 | Remove-Item -Force -ErrorAction SilentlyContinue
$sessionDirectory=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\session'
Get-ChildItem -LiteralPath $sessionDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-7) | Remove-Item -Force -ErrorAction SilentlyContinue
$downloadRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\downloads'
Get-ChildItem -LiteralPath $downloadRoot -Directory -Filter 'stage-*' -ErrorAction SilentlyContinue |
    Where-Object LastWriteTime -lt (Get-Date).AddDays(-1) | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$script:CocoLogPath = Join-Path $script:CocoLogDirectory ("updater-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),$PID)
$script:CocoRunId=if($env:COCO_RUN_ID-match'^[a-fA-F0-9]{12,32}$'){$env:COCO_RUN_ID.ToLowerInvariant()}else{[guid]::NewGuid().ToString('N')}
$env:COCO_RUN_ID=$script:CocoRunId
$script:CocoRunStartedUtc=[DateTime]::UtcNow
$script:CocoRunWatch=[Diagnostics.Stopwatch]::StartNew()
$script:CocoTimelinePath=Join-Path $script:CocoLogDirectory "run-$($script:CocoRunId).jsonl"
$script:CocoTimelineSequence=0
$script:CocoLastTimelineSignature=''
$script:CocoLastTimelineAt=[DateTime]::MinValue
$script:CocoDiagnosticContext=[ordered]@{component='engine';mode=if($NetworkOnly){'network-only'}elseif($DetectOnly){'detect-only'}else{'updater'};role='';experienceId='';packVersion='';instanceRoot='';stage='Engine iniciado'}
function Write-CocoLog([string]$Text) {
    try { Add-Content -LiteralPath $script:CocoLogPath -Value ("{0:o} {1}" -f (Get-Date),$Text) -Encoding UTF8 } catch { }
}
function Set-CocoDiagnosticContext([hashtable]$Values){
    if(-not$Values){return}
    foreach($key in $Values.Keys){$script:CocoDiagnosticContext[[string]$key]=[string]$Values[$key]}
}
function Write-CocoTimelineEvent([string]$Message,[string]$Detail,[int]$Progress,[string]$Action=''){
    try{
        $now=[DateTime]::UtcNow
        $signature="$Message|$Detail|$Progress|$Action"
        # Descargas pueden informar varios chunks por milisegundo. Conservamos
        # cada cambio de etapa y, dentro de una misma etapa, hasta cuatro
        # muestras por segundo: suficiente para reconstruir velocidad/progreso
        # sin crear diagnósticos gigantes.
        $stageChanged=$Message-ne$script:CocoDiagnosticContext.stage
        if(-not$stageChanged-and$signature-eq$script:CocoLastTimelineSignature){return}
        if(-not$stageChanged-and($now-$script:CocoLastTimelineAt).TotalMilliseconds-lt250){return}
        $script:CocoDiagnosticContext.stage=$Message
        $script:CocoTimelineSequence++
        $event=[ordered]@{
            timestampUtc=$now.ToString('o');elapsedMs=[int64]$script:CocoRunWatch.ElapsedMilliseconds
            sequence=$script:CocoTimelineSequence;runId=$script:CocoRunId;component=[string]$script:CocoDiagnosticContext.component
            mode=[string]$script:CocoDiagnosticContext.mode;role=[string]$script:CocoDiagnosticContext.role
            experienceId=[string]$script:CocoDiagnosticContext.experienceId;packVersion=[string]$script:CocoDiagnosticContext.packVersion
            instanceRoot=[string]$script:CocoDiagnosticContext.instanceRoot;message=$Message;detail=$Detail
            progress=$Progress;action=$Action
        }
        Add-Content -LiteralPath $script:CocoTimelinePath -Value ($event|ConvertTo-Json -Compress) -Encoding UTF8
        Write-CocoLog ("STATE {0}% | {1} | {2} | Action={3}"-f$Progress,$Message,$Detail,$Action)
        $script:CocoLastTimelineSignature=$signature;$script:CocoLastTimelineAt=$now
    }catch{}
}
function Get-CocoDiagnosticTail([string]$Path,[int]$Lines=120){
    try{
        if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){return "No existe: $Path"}
        return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop)-join"`r`n")
    }catch{return "No disponible ($Path): $($_.Exception.Message)"}
}
function Get-CocoFailureClassification([string]$Message){
    $value=([string]$Message).ToLowerInvariant()
    if($value-match'416|range not satisfiable|parcial invalido|hash|sha-?256|tamano fijado|integridad|zip slip'){return [pscustomobject]@{Code='PACK-INTEGRITY';Action='Coco descarto el fragmento incompatible y reintentara una descarga limpia verificada. Si vuelve a fallar, envia este TXT del Escritorio.'}}
    if($value-match'espacio|disk|disco|no space'){return [pscustomobject]@{Code='DISK-SPACE';Action='Libera espacio en C: y vuelve a abrir Coco; las descargas verificadas ya completas se reutilizan.'}}
    if($value-match'identidad|identity|username|nombre local|jugador'){return [pscustomobject]@{Code='IDENTITY';Action='Reabre Coco, revisa el nombre del jugador y usa siempre la misma identidad local.'}}
    if($value-match'zerotier|adaptador|network id|autoriz|25564|red coco'){return [pscustomobject]@{Code='ZEROTIER';Action='Comprueba que el host tenga Coco/Minecraft abierto y vuelve a ejecutar; adjunta este informe si vuelve a fallar.'}}
    if($value-match'25565|puerto|listen|socket|connection|conectar|timeout|timed out|nombre remoto'){return [pscustomobject]@{Code='CONNECTIVITY';Action='Verifica internet/host y vuelve a abrir Coco. No borres la instancia: el proceso es reanudable.'}}
    if($value-match'access|acceso|denegado|permission|administrador|uac'){return [pscustomobject]@{Code='WINDOWS-PERMISSION';Action='Permite Coco/ZeroTier en Windows o antivirus y vuelve a ejecutar. No hace falta mover la instancia.'}}
    if($value-match'java|forge|fabric|portablemc|minecraft.*codigo|loader'){return [pscustomobject]@{Code='RUNTIME';Action='Reabre Coco para reparar Java/loader. Conserva este TXT y el launcher log indicado.'}}
    [pscustomobject]@{Code='INTERNAL';Action='No borres nada. Envia este TXT completo junto con la hora aproximada del fallo.'}
}
function Write-CocoEngineDiagnostic([Management.Automation.ErrorRecord]$Record){
    try{
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        $failureId="COCO-$($script:CocoRunId)-$('{0:D4}'-f($script:CocoTimelineSequence+1))"
        $diagnosticPath=Join-Path $script:CocoLogDirectory "engine-$stamp-$PID-error.txt"
        $classification=Get-CocoFailureClassification ([string]$Record.Exception.Message)
        try{Write-CocoTimelineEvent 'ERROR' ("$($classification.Code): $($Record.Exception.Message)") $script:CocoCurrentProgress 'failure'}catch{}
        $manifestVersion=try{if($manifest-and$manifest.version){[string]$manifest.version}else{'Unknown'}}catch{'Unknown'}
        $selectedRoot=try{if($selected-and$selected.Root){[string]$selected.Root}elseif($script:CocoDiagnosticContext.instanceRoot){[string]$script:CocoDiagnosticContext.instanceRoot}else{'Unknown'}}catch{'Unknown'}
        $contextJson=try{$script:CocoDiagnosticContext|ConvertTo-Json -Depth 6}catch{'Unavailable'}
        $timeline=Get-CocoDiagnosticTail $script:CocoTimelinePath 300
        $bootstrapTimeline=Get-CocoDiagnosticTail (Join-Path $script:CocoLogDirectory "bootstrap-run-$($script:CocoRunId).log") 250
        $updaterLog=Get-CocoDiagnosticTail $script:CocoLogPath 1000
        $networkStatePath=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\network\state.json'
        $networkState=Get-CocoDiagnosticTail $networkStatePath 120
        $serviceState=try{Get-Service -Name 'ZeroTierOneService' -ErrorAction Stop|Select-Object Name,Status,StartType|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $networkAdapters=try{Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object{$_.Name-match'ZeroTier'-or$_.InterfaceDescription-match'ZeroTier'}|Select-Object Name,Status,MacAddress,LinkSpeed,ifIndex|Format-Table -AutoSize|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $ports=try{Get-NetTCPConnection -LocalPort 25564,25565 -ErrorAction Stop|Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess|Format-Table -AutoSize|Out-String}catch{'No Coco TCP connections/listeners observed.'}
        $javaProcesses=try{Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop|Select-Object ProcessId,Name,CreationDate,CommandLine|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $cocoProcesses=try{Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{$_.Name-match'(?i)CocoUpdater|powershell|portablemc'-and$_.CommandLine-match'(?i)coco|portablemc'}|Select-Object ProcessId,ParentProcessId,Name,CreationDate,CommandLine|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $computer=try{Get-CimInstance Win32_ComputerSystem -ErrorAction Stop|Select-Object Manufacturer,Model,@{n='PhysicalMemoryGB';e={[math]::Round($_.TotalPhysicalMemory/1GB,2)}}|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $disk=try{$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($(if($selectedRoot-ne'Unknown'){$selectedRoot}else{$env:LOCALAPPDATA}))));$drive|Select-Object Name,DriveFormat,@{n='FreeGB';e={[math]::Round($_.AvailableFreeSpace/1GB,2)}},@{n='TotalGB';e={[math]::Round($_.TotalSize/1GB,2)}}|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $identityPath=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\launcher\identity.json'
        $identity=try{if(Test-Path -LiteralPath $identityPath){$value=Get-Content -LiteralPath $identityPath -Raw|ConvertFrom-Json;[pscustomobject]@{schemaVersion=$value.schemaVersion;mode=$value.mode;username=$value.username;uuid=$value.uuid;decisionSource=$value.decisionSource;configuredAtUtc=$value.configuredAtUtc}|Format-List|Out-String}else{'No Coco launcher identity configured.'}}catch{"Unavailable: $($_.Exception.Message)"}
        $managedStatePath=if($selectedRoot-ne'Unknown'){Join-Path $selectedRoot '.coco\managed-state.json'}else{''}
        $managedState=Get-CocoDiagnosticTail $managedStatePath 180
        $minecraftLogPath=if($selectedRoot-ne'Unknown'){Join-Path $selectedRoot 'logs\latest.log'}else{''}
        $minecraftLog=Get-CocoDiagnosticTail $minecraftLogPath 220
        $ipTextPath=if($selectedRoot-ne'Unknown'){Join-Path $selectedRoot 'ip.txt'}else{''}
        $standaloneIpText=Get-CocoDiagnosticTail $ipTextPath 80
        $recentLauncherLogs=''
        try{
            foreach($file in @(Get-ChildItem -LiteralPath $script:CocoLogDirectory -File -Filter 'launcher-*.log' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 3)){
                $recentLauncherLogs+="`r`n--- $($file.FullName) ---`r`n$(Get-CocoDiagnosticTail $file.FullName 140)`r`n"
            }
            if(-not$recentLauncherLogs){$recentLauncherLogs='No launcher logs found.'}
            if($standaloneIpText){$recentLauncherLogs+="`r`n--- STANDALONE IP CONFIG (ip.txt) ---`r`n$standaloneIpText`r`n"}
        }catch{$recentLauncherLogs="Unavailable: $($_.Exception.Message)"}
        $sessionServiceLog=Get-CocoDiagnosticTail (Join-Path $script:CocoLogDirectory 'launcher-session-service.log') 250
        $locationStoreLog=Get-CocoDiagnosticTail (Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\instance-locations.json') 120
        $standaloneDiagnosticsLog='';$bepInExLog='';$bepInExErrorLog='';$instanceStateLog='';$unityPlayerLog=''
        if($selectedRoot-ne'Unknown'){
            $standaloneDiagnosticsLog=Get-CocoDiagnosticTail (Join-Path $selectedRoot 'logs\standalone-diagnostics.log') 300
            $bepInExLog=Get-CocoDiagnosticTail (Join-Path $selectedRoot 'BepInEx\LogOutput.log') 300
            $bepInExErrorLog=Get-CocoDiagnosticTail (Join-Path $selectedRoot 'BepInEx\ErrorLog.log') 300
            $instanceStateLog=Get-CocoDiagnosticTail (Join-Path $selectedRoot '.coco\standalone-state.json') 120
            if([string]::IsNullOrWhiteSpace($standaloneDiagnosticsLog)){$standaloneDiagnosticsLog=Get-CocoDiagnosticTail (Join-Path $selectedRoot 'logs\latest.log') 300}
            $appInfoFiles=@(Get-ChildItem -LiteralPath $selectedRoot -Filter 'app.info' -Recurse -File -ErrorAction SilentlyContinue)
            foreach($appInfo in $appInfoFiles){
                try{
                    $lines=@(Get-Content -LiteralPath $appInfo.FullName|ForEach-Object{$_.Trim()}|Where-Object{$_})
                    if($lines.Count-ge2){
                        $company=$lines[0];$product=$lines[1]
                        $candidatePlayerLog=Join-Path ([Environment]::GetFolderPath('UserProfile')) "AppData\LocalLow\$company\$product\Player.log"
                        if(Test-Path -LiteralPath $candidatePlayerLog -PathType Leaf){
                            $unityPlayerLog=Get-CocoDiagnosticTail $candidatePlayerLog 350
                            break
                        }
                    }
                }catch{}
            }
        }
        $cacheSummary=try{
            $cacheRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'
            $downloads=Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'downloads') -Recurse -File -ErrorAction SilentlyContinue
            $runtime=Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'launcher\runtime') -Recurse -File -ErrorAction SilentlyContinue
            [pscustomobject]@{CacheRoot=$cacheRoot;DownloadedFiles=@($downloads).Count;DownloadedBytes=(@($downloads|Measure-Object Length -Sum).Sum);RuntimeFiles=@($runtime).Count;RuntimeBytes=(@($runtime|Measure-Object Length -Sum).Sum)}|Format-List|Out-String
        }catch{"Unavailable: $($_.Exception.Message)"}
        $report=@"
COCO LAUNCHER - DIAGNOSTICO COMPLETO
====================================
Failure ID: $failureId
Run ID: $($script:CocoRunId)
Timestamp: $((Get-Date).ToString('o'))
Elapsed: $($script:CocoRunWatch.Elapsed)
Classification: $($classification.Code)
Recommended next action: $($classification.Action)
Last visible stage: $($script:CocoDiagnosticContext.stage)
Last progress: $($script:CocoCurrentProgress)%

RESUMEN DE LA OPERACION
-----------------------
$contextJson
Engine PID / Minecraft PID: $PID / $MinecraftPid
Manifest version/path: $manifestVersion / $ManifestPath
Engine root: $script:CocoEngineRoot
Selected/instance root: $selectedRoot
NetworkOnly / Silent / ShowOnUpdate: $NetworkOnly / $Silent / $ShowOnUpdate

ERROR ORIGINAL
--------------
$($Record.Exception.ToString())

ErrorRecord:
$($Record|Format-List * -Force|Out-String)

Script stack trace:
$($Record.ScriptStackTrace)

Invocation:
$($Record.InvocationInfo.PositionMessage)

TIMELINE DE ETAPAS (JSONL, orden cronologico)
------------------------------------------------
$timeline

TIMELINE DEL BOOTSTRAP (mismo Run ID)
------------------------------------
$bootstrapTimeline

LOG DEL ENGINE
--------------
$updaterLog

LOGS PORTABLEMC/MINECRAFT RECIENTES
----------------------------------
$recentLauncherLogs

LOGS AUXILIARES RELEVANTES (INCLUIDOS PARA NO BUSCAR OTRAS RUTAS)
------------------------------------------------------------------
--- launcher-session-service.log ---
$sessionServiceLog

--- instance-locations.json ---
$locationStoreLog

--- standalone-diagnostics.log / latest.log ---
$standaloneDiagnosticsLog

--- BepInEx/LogOutput.log ---
$bepInExLog

--- BepInEx/ErrorLog.log ---
$bepInExErrorLog

--- .coco/standalone-state.json ---
$instanceStateLog

--- Unity Player.log ---
$unityPlayerLog

ULTIMO latest.log DE LA INSTANCIA
---------------------------------
$minecraftLog

ESTADO DE INSTALACION ADMINISTRADA
---------------------------------
$managedState

IDENTIDAD COCO (sin tokens ni contrasenas)
-----------------------------------------
$identity

RED ZEROTIER
------------
Service:
$serviceState
Adapters:
$networkAdapters
Connections/listeners 25564/25565:
$ports
Last network state:
$networkState

PROCESOS RELEVANTES
-------------------
Java/Minecraft:
$javaProcesses
Coco/PortableMC:
$cocoProcesses

EQUIPO Y CAPACIDAD
------------------
Windows: $([Environment]::OSVersion.VersionString)
PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))
Language mode: $($ExecutionContext.SessionState.LanguageMode)
64-bit OS/process: $([Environment]::Is64BitOperatingSystem) / $([Environment]::Is64BitProcess)
$computer
$disk
Cache:
$cacheSummary

PRIVACIDAD
----------
Este informe no copia accessToken, contrasenas, cookies ni bases privadas de otros launchers.
Puede contener nombre/UUID de Minecraft, rutas locales, IP ZeroTier y lineas de comando necesarias para diagnosticar.
"@
        [IO.File]::WriteAllText($diagnosticPath,$report,(New-Object Text.UTF8Encoding($true)))
        $desktop=if($script:CocoDiagnosticDesktopOverride){[string]$script:CocoDiagnosticDesktopOverride}else{[Environment]::GetFolderPath('Desktop')}
        if($desktop-and(Test-Path -LiteralPath $desktop)){
            $desktopPath=Join-Path $desktop "CocoUpdater-error-$stamp.txt"
            [IO.File]::WriteAllText($desktopPath,$report,(New-Object Text.UTF8Encoding($true)))
            $diagnosticPath=$desktopPath
        }
        Get-ChildItem -LiteralPath $script:CocoLogDirectory -File -Filter 'engine-*-error.txt' -ErrorAction SilentlyContinue|
            Sort-Object LastWriteTime -Descending|Select-Object -Skip 20|Remove-Item -Force -ErrorAction SilentlyContinue
        return $diagnosticPath
    }catch{
        try{Write-CocoLog "No se pudo construir el diagnostico completo: $($_.Exception.Message)"}catch{}
        return $null
    }
}
Write-CocoLog "Inicio. EnginePid=$PID GameDir='$GameDir' MinecraftPid=$MinecraftPid RunningPackVersion='$RunningPackVersion' Silent=$Silent ShowOnUpdate=$ShowOnUpdate"
if($global:CocoSharedUi){
    $script:CocoForm=$global:CocoSharedUi.Form;$script:CocoTitle=$global:CocoSharedUi.Title
    try {
        if ('CocoNativeWindow' -as [type]) { [CocoNativeWindow]::EnableMinimize($script:CocoForm.Handle) }
        $script:CocoForm.Add_Activated({
            try {
                if ($script:CocoForm.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
                    $script:CocoForm.WindowState = [Windows.Forms.FormWindowState]::Normal
                    $script:CocoForm.BringToFront()
                }
            } catch {}
        })
    } catch {}
    $script:CocoDetail=$global:CocoSharedUi.Detail;$script:CocoProgress=$global:CocoSharedUi.Progress
    $script:CocoTrack=$global:CocoSharedUi.Track
    $script:CocoPanel=$global:CocoSharedUi.Panel;$script:CocoAccent=$global:CocoSharedUi.Accent;$script:CocoBrand=$global:CocoSharedUi.Brand
    if(-not$script:CocoPanel){$script:CocoPanel=@($script:CocoForm.Controls|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Controls.Count-ge4}|Select-Object -First 1)[0]}
    if($script:CocoPanel-and-not$script:CocoAccent){$script:CocoAccent=@($script:CocoPanel.Controls|Where-Object{$_-is[Windows.Forms.Panel]-and$_.Width-lt20}|Select-Object -First 1)[0]}
    if($script:CocoPanel-and-not$script:CocoBrand){$script:CocoBrand=@($script:CocoPanel.Controls|Where-Object{$_-is[Windows.Forms.Label]-and$_.Text-match'COCO PACK'}|Select-Object -First 1)[0]}
    # El launcher agrega una lista desplazable debajo del estado. Conserva
    # exactamente ese mismo lienzo desde el primer frame para que el progreso
    # y el texto de estado nunca caigan encima de las tarjetas host/cliente.
    if($script:CocoPanel){$script:CocoPanel.Size=New-Object Drawing.Size(640,790)}
    if($script:CocoAccent){$script:CocoAccent.Size=New-Object Drawing.Size(9,790)}
    if($script:CocoTitle){$script:CocoTitle.Location=New-Object Drawing.Point(43,24);$script:CocoTitle.Size=New-Object Drawing.Size(570,42)}
    if($script:CocoDetail){$script:CocoDetail.Location=New-Object Drawing.Point(46,70);$script:CocoDetail.Size=New-Object Drawing.Size(570,48)}
    if($script:CocoTrack){$script:CocoTrack.Location=New-Object Drawing.Point(46,126);$script:CocoTrack.Size=New-Object Drawing.Size(570,20)}
    if($script:CocoBrand){$script:CocoBrand.Location=New-Object Drawing.Point(46,151);$script:CocoBrand.Size=New-Object Drawing.Size(570,20)}
    $script:CocoVisualWorkStarted=$global:CocoSharedUi.Started
}

function Set-CocoFittedLabelText(
    $Label,
    [string]$Text,
    [string]$Family,
    [single]$MaximumSize,
    [single]$MinimumSize,
    [Drawing.FontStyle]$Style=[Drawing.FontStyle]::Regular
){
    if(-not$Label){return}
    $Label.AutoSize=$false
    if($Label.PSObject.Properties.Name-contains'AutoEllipsis'){$Label.AutoEllipsis=$false}
    if($Label.PSObject.Properties.Name-contains'UseCompatibleTextRendering'){$Label.UseCompatibleTextRendering=$true}
    $chosen=$MinimumSize
    for($size=$MaximumSize;$size-ge$MinimumSize;$size-=0.5){
        $candidate=New-Object Drawing.Font($Family,[single]$size,$Style)
        try{
            $flags=[Windows.Forms.TextFormatFlags]::WordBreak-bor[Windows.Forms.TextFormatFlags]::NoPadding
            $measured=[Windows.Forms.TextRenderer]::MeasureText($Text,$candidate,(New-Object Drawing.Size($Label.ClientSize.Width,4096)),$flags)
            if($measured.Height-le$Label.ClientSize.Height){$chosen=$size;break}
        }finally{$candidate.Dispose()}
    }
    $old=$Label.Font
    $Label.Font=New-Object Drawing.Font($Family,[single]$chosen,$Style)
    $Label.Text=$Text
    # No destruir la fuente anterior aquí. Refresh/DoEvents puede reingresar al
    # pintado del Label mientras GDI+ todavía referencia ese objeto y termina en
    # Graphics.DrawString: "El parámetro no es válido". La ventana es corta y
    # Control.Dispose liberará las fuentes asociadas al cerrar.
}

function Set-CocoState([string]$Message, [string]$Detail, [int]$Progress, [bool]$Visible = $true, [string]$Action = '') {
    $Progress = [Math]::Max(0, [Math]::Min(100, $Progress))
    $script:CocoCurrentProgress = $Progress
    Write-CocoTimelineEvent $Message $Detail $Progress $Action
    if ($SessionStatePath) {
        New-Item -ItemType Directory -Path (Split-Path $SessionStatePath -Parent) -Force | Out-Null
        $tmp = "$SessionStatePath.tmp"
        [pscustomobject]@{message=$Message;detail=$Detail;progress=$Progress;visible=$Visible;action=$Action;updatedAt=(Get-Date).ToString('o')} |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $SessionStatePath -Force
    }
    if ($script:CocoForm) {
        if($Action-eq'failure'-and('System.Drawing.Color'-as[type])){
            $failureColor=[Drawing.Color]::FromArgb(255,92,112)
            if($script:CocoAccent){$script:CocoAccent.BackColor=$failureColor}
            if($script:CocoProgress){$script:CocoProgress.BackColor=$failureColor}
            if($script:CocoTitle){$script:CocoTitle.ForeColor=$failureColor}
        }elseif($Action-ne'failure'-and('System.Drawing.Color'-as[type])){
            $normalColor=[Drawing.Color]::FromArgb(177,92,255)
            if($script:CocoAccent){$script:CocoAccent.BackColor=$normalColor}
            if($script:CocoProgress){$script:CocoProgress.BackColor=$normalColor}
            if($script:CocoTitle){$script:CocoTitle.ForeColor=[Drawing.Color]::FromArgb(224,190,255)}
        }
        $uiProgress=$Progress
        if($global:CocoSharedUi){$uiProgress=[Math]::Min(100,[int]($global:CocoSharedUi.BaseProgress+(100-$global:CocoSharedUi.BaseProgress)*$Progress/100))}
        Set-CocoFittedLabelText $script:CocoTitle $Message 'Segoe UI Semibold' 22 11 ([Drawing.FontStyle]::Bold)
        Set-CocoFittedLabelText $script:CocoDetail $Detail 'Segoe UI' 12 8 ([Drawing.FontStyle]::Regular)
        $trackWidth=if($script:CocoTrack){$script:CocoTrack.ClientSize.Width}else{570}
        $script:CocoProgress.Width=[Math]::Max(4,[int]($trackWidth*$uiProgress/100))
        $script:CocoForm.Refresh(); [Windows.Forms.Application]::DoEvents()
    }
}

function Show-CocoWindow {
    if($TestSuppressUi){return}
    if ($script:CocoForm) { return }
    $script:CocoVisualWorkStarted = [Diagnostics.Stopwatch]::StartNew()
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    if(-not('CocoNativeWindow'-as[type])){
        $nativeSrc=@'
using System;
using System.Runtime.InteropServices;
public static class CocoNativeWindow {
    [DllImport("user32.dll", EntryPoint = "GetWindowLong", SetLastError = true)]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    public const int GWL_STYLE = -16;
    public const int WS_MINIMIZEBOX = 0x00020000;
    public const int WS_SYSMENU = 0x00080000;
    public static void EnableMinimize(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return;
        try {
            if (IntPtr.Size == 8) {
                long style = GetWindowLongPtr64(hWnd, GWL_STYLE).ToInt64();
                style |= (long)(WS_MINIMIZEBOX | WS_SYSMENU);
                SetWindowLongPtr64(hWnd, GWL_STYLE, new IntPtr(style));
            } else {
                int style = GetWindowLong32(hWnd, GWL_STYLE);
                style |= (WS_MINIMIZEBOX | WS_SYSMENU);
                SetWindowLong32(hWnd, GWL_STYLE, style);
            }
        } catch {}
    }
}
'@
        Add-Type -TypeDefinition $nativeSrc -ErrorAction SilentlyContinue
    }
    [Windows.Forms.Application]::EnableVisualStyles()
    $key=[Drawing.Color]::FromArgb(1,2,3)
    $f=New-Object Windows.Forms.Form; $f.Text='Coco Minecraft Updater'; $f.Size=New-Object Drawing.Size(1080,840)
    $f.StartPosition='CenterScreen'; $f.FormBorderStyle='None'; $f.MaximizeBox=$false; $f.ShowInTaskbar=$true
    $f.AutoScaleMode='None'; $f.TopMost=$false
    $f.Add_FormClosing({param($sender,$eventArgs) if(-not$script:CocoAllowClose){$eventArgs.Cancel=$true}})
    $f.Add_HandleCreated({
        try {
            if ('CocoNativeWindow' -as [type]) { [CocoNativeWindow]::EnableMinimize($f.Handle) }
        } catch {}
    })
    $f.Add_Activated({
        try {
            if ($f.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
                $f.WindowState = [Windows.Forms.FormWindowState]::Normal
                $f.BringToFront()
            }
        } catch {}
    })
    $f.BackColor=$key; $f.TransparencyKey=$key; $f.ForeColor=[Drawing.Color]::White
    $iconPath=Join-Path $script:CocoEngineRoot 'assets\reynaico.ico'
    if(Test-Path $iconPath){$f.Icon=New-Object Drawing.Icon($iconPath)}
    $panel=New-Object Windows.Forms.Panel; $panel.Location=New-Object Drawing.Point(25,190); $panel.Size=New-Object Drawing.Size(640,600)
    $panel.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $accent=New-Object Windows.Forms.Panel; $accent.Location=New-Object Drawing.Point(0,0); $accent.Size=New-Object Drawing.Size(9,600)
    $accent.BackColor=[Drawing.Color]::FromArgb(177,92,255); $panel.Controls.Add($accent)
    $t=New-Object Windows.Forms.Label; $t.Location=New-Object Drawing.Point(43,16); $t.Size=New-Object Drawing.Size(570,40)
    $t.Font=New-Object Drawing.Font('Segoe UI Semibold',16); $t.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $d=New-Object Windows.Forms.Label; $d.Location=New-Object Drawing.Point(46,58); $d.Size=New-Object Drawing.Size(570,36)
    $d.Font=New-Object Drawing.Font('Segoe UI',10.5); $d.ForeColor=[Drawing.Color]::FromArgb(218,210,229)
    $track=New-Object Windows.Forms.Panel; $track.Location=New-Object Drawing.Point(46,98); $track.Size=New-Object Drawing.Size(570,20)
    $track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $p=New-Object Windows.Forms.Panel; $p.Location=New-Object Drawing.Point(0,0); $p.Size=New-Object Drawing.Size(4,20)
    $p.BackColor=[Drawing.Color]::FromArgb(177,92,255); $track.Controls.Add($p)
    $sparkle=[char]0x2726
    $b=New-Object Windows.Forms.Label; $b.Text="$sparkle  COCO PACK  |  FABRIC 26.1.2"; $b.Location=New-Object Drawing.Point(46,122)
    $b.Size=New-Object Drawing.Size(570,20); $b.Font=New-Object Drawing.Font('Segoe UI Semibold',9); $b.ForeColor=[Drawing.Color]::FromArgb(177,92,255)
    $panel.Controls.AddRange(@($t,$d,$track,$b))
    $artPath=Join-Path $script:CocoEngineRoot 'assets\fullbody.png'
    $art=New-Object Windows.Forms.PictureBox; $art.Location=New-Object Drawing.Point(675,5); $art.Size=New-Object Drawing.Size(380,810)
    $art.SizeMode='Zoom'; $art.BackColor=[Drawing.Color]::Transparent
    if(Test-Path $artPath){
        try{
            $bytes=[IO.File]::ReadAllBytes($artPath);$ms=[IO.MemoryStream]::new($bytes,$false);$sourceImage=$null
            try{
                $sourceImage=[Drawing.Image]::FromStream($ms,$true,$true)
                # Image.FromStream exige que el stream siga vivo. Clonar a un
                # Bitmap independiente evita la X roja cuando el GC lo recoge.
                $art.Image=[Drawing.Bitmap]::new($sourceImage)
            }finally{
                if($sourceImage){$sourceImage.Dispose()}
                $ms.Dispose()
            }
        }catch{$art.Image=$null}
    }
    $f.Controls.Add($panel); $f.Controls.Add($art); $art.BringToFront()
    $work=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $scale=[Math]::Min(1.0,[Math]::Min($work.Width/1080.0,$work.Height/740.0))
    # El launcher agrega controles despues de crear esta ventana. Conserva la
    # escala usada aqui para que esos controles nuevos usen las mismas
    # coordenadas y no terminen fuera del lienzo en pantallas pequenas.
    $script:CocoUiScale=$scale
    if($scale-lt1.0){$f.Scale((New-Object Drawing.SizeF($scale,$scale)))}
    $f.Show(); $f.BringToFront(); $f.Activate()
    try {
        if ('CocoNativeWindow' -as [type]) { [CocoNativeWindow]::EnableMinimize($f.Handle) }
    } catch {}
    [Windows.Forms.Application]::DoEvents()
    $script:CocoForm=$f; $script:CocoPanel=$panel; $script:CocoAccent=$accent; $script:CocoTitle=$t; $script:CocoDetail=$d
    $script:CocoProgress=$p; $script:CocoTrack=$track; $script:CocoBrand=$b
}

function Show-CocoSuccessAndWait([string]$Version,[string]$Detail="Ya puedes volver a abrir Minecraft.") {
    $stateDetail="Coco Pack $Version esta listo. $Detail"
    Set-CocoState 'Coco Pack actualizado' $stateDetail 100 $true
    if(-not$script:CocoForm){return}

    $green=[Drawing.Color]::FromArgb(78,214,132)
    $greenDark=[Drawing.Color]::FromArgb(30,92,61)
    $scale=[Math]::Max(0.55,[Math]::Min(1.0,$script:CocoForm.Width/1080.0))
    Set-CocoFittedLabelText $script:CocoTitle "$([char]0x2714)  TODO LISTO" 'Segoe UI Semibold' ([single](27*$scale)) ([single](15*$scale)) ([Drawing.FontStyle]::Bold)
    $script:CocoTitle.ForeColor=$green
    Set-CocoFittedLabelText $script:CocoDetail "Coco Pack $Version esta listo.`n$Detail" 'Segoe UI Semibold' ([single](14*$scale)) ([single](8*$scale)) ([Drawing.FontStyle]::Bold)
    $script:CocoDetail.ForeColor=[Drawing.Color]::White
    $script:CocoProgress.BackColor=$green
    $script:CocoProgress.Width=$script:CocoTrack.ClientSize.Width
    $script:CocoTrack.BackColor=$greenDark
    if($script:CocoAccent){$script:CocoAccent.BackColor=$green}
    if($script:CocoBrand){$script:CocoBrand.Text="$([char]0x2714)  ACTUALIZACION COMPLETADA";$script:CocoBrand.ForeColor=$green}

    $accept=New-Object Windows.Forms.Button
    $accept.Name='CocoAcceptButton';$accept.Text='ACEPTAR'
    $accept.Location=New-Object Drawing.Point([int](430*$scale),[int](282*$scale))
    $accept.Size=New-Object Drawing.Size([int](190*$scale),[int](48*$scale))
    $accept.Font=New-Object Drawing.Font('Segoe UI Semibold',[single](13*$scale))
    $accept.ForeColor=[Drawing.Color]::FromArgb(14,35,24);$accept.BackColor=$green
    $accept.FlatStyle=[Windows.Forms.FlatStyle]::Flat;$accept.FlatAppearance.BorderSize=0
    $accept.Cursor=[Windows.Forms.Cursors]::Hand;$accept.TabStop=$true
    $accept.Add_Click({$script:CocoSuccessAccepted=$true})
    if($script:CocoPanel){$script:CocoPanel.Controls.Add($accept)}else{$script:CocoForm.Controls.Add($accept)}
    $script:CocoForm.AcceptButton=$accept
    $script:CocoSuccessAccepted=$false
    $script:CocoForm.BringToFront();$script:CocoForm.Activate();[void]$accept.Focus();$script:CocoForm.Refresh()
    while($script:CocoForm.Visible-and-not$script:CocoSuccessAccepted){
        [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50
    }
    $script:CocoAllowClose=$true
    if($script:CocoForm.Visible){$script:CocoForm.Close()}
}

function Write-Status([string]$Message) {
    # Un EXE sin consola convierte Write-Host en cuadros de dialogo; el estado vive en la UI.
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CocoFabricModId([string]$Path) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=[IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $entry=$archive.GetEntry('fabric.mod.json')
            if(-not$entry){return $null}
            $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
            try{return [string](($reader.ReadToEnd()|ConvertFrom-Json).id)}finally{$reader.Dispose()}
        } finally {$archive.Dispose()}
    } catch {return $null}
}

function Get-FileText([string]$Path, [int]$TailLines = 2500) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { return (Get-Content -LiteralPath $Path -Tail $TailLines -ErrorAction Stop) -join "`n" }
    catch { return '' }
}

function Test-GameDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    (Test-Path (Join-Path $Path 'mods')) -and (
        (Test-Path (Join-Path $Path 'versions')) -or
        (Test-Path (Join-Path $Path 'logs')) -or
        (Test-Path (Join-Path $Path 'options.txt'))
    )
}

function Repair-InterruptedInstall([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }
    $mods = Join-Path $Root 'mods'
    $transient = Join-Path $Root '.coco-mods-replacing'
    if ((Test-Path -LiteralPath $transient) -and -not (Test-Path -LiteralPath $mods)) {
        Move-Item -LiteralPath $transient -Destination $mods -Force
    } elseif ((Test-Path -LiteralPath $transient) -and (Test-Path -LiteralPath $mods)) {
        Remove-Item -LiteralPath $transient -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-PersistedTarget {
    $path = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\target.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($saved.path) { return [string]$saved.path }
    } catch { }
    return $null
}

function Get-CandidateRoots([string[]]$PreferredRoots=@()) {
    $roots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $persisted=Get-PersistedTarget
    if($persisted){
        Repair-InterruptedInstall $persisted
    }
    $known = @($PreferredRoots)+@(
        $persisted,
        (Join-Path $env:APPDATA '.minecraft'),
        (Join-Path $env:LOCALAPPDATA '.minecraft'),
        (Join-Path $env:USERPROFILE '.minecraft')
    )
    foreach ($path in $known) {
        Repair-InterruptedInstall $path
        if (Test-GameDirectory $path) { [void]$roots.Add((Resolve-Path -LiteralPath $path).Path) }
    }

    $scopes = @(
        $env:APPDATA,
        $env:LOCALAPPDATA,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'OneDrive')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($scope in $scopes) {
        try {
            Get-ChildItem -LiteralPath $scope -Directory -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'mods' -or $_.Name -eq '.coco-mods-replacing' } | ForEach-Object {
                $candidate = $_.Parent.FullName
                Repair-InterruptedInstall $candidate
                if (Test-GameDirectory $candidate) { [void]$roots.Add($candidate) }
            }
        } catch { }
    }
    return @($roots | Sort-Object)
}

function Get-RunningMinecraftInstances($Manifest) {
    $instances=[System.Collections.Generic.List[object]]::new()
    try {
        Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction Stop | ForEach-Object {
            $commandLine=[string]$_.CommandLine
            $gameDir=$null;$versionId='desconocida'
            if($commandLine-match'(?i)--gameDir\s+"([^"]+)"'){$gameDir=$matches[1]}
            elseif($commandLine-match'(?i)--gameDir\s+([^\s]+)'){$gameDir=$matches[1]}
            if(-not$gameDir){return}
            if($commandLine-match'(?i)--version\s+"([^"]+)"'){$versionId=$matches[1]}
            elseif($commandLine-match'(?i)--version\s+([^\s]+)'){$versionId=$matches[1]}
            $isMinecraft=$commandLine-match'(?i)KnotClient|net\.minecraft\.client|--assetsDir'
            if(-not$isMinecraft){return}
            $isFabric=$versionId-match'(?i)fabric'-or$commandLine-match'(?i)fabric-loader|KnotClient'
            $versionPattern="(?:^|[-_+ .])"+[regex]::Escape([string]$Manifest.detector.minecraftVersion)+"(?:$|[-_+ .])"
            $isExpectedVersion=$versionId-match$versionPattern
            if(-not$isExpectedVersion){
                $isExpectedVersion=$commandLine-match("(?i)(?:^|[\\/;\s_-])"+[regex]::Escape([string]$Manifest.detector.minecraftVersion)+"(?:[\\/;\s_+.-]|$)")
            }
            $instances.Add([pscustomobject]@{
                ProcessId=[int64]$_.ProcessId;GameDir=[string]$gameDir;VersionId=[string]$versionId
                Compatible=[bool]($isFabric-and$isExpectedVersion)
            })
        }
    } catch { }
    return @($instances)
}

function Get-RunningGameDirectories {
    # Los cierres y las esperas deben reconocer cualquier version que use la
    # carpeta seleccionada. La seleccion inicial, en cambio, usa solamente las
    # instancias compatibles de Get-RunningMinecraftInstances.
    $paths=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try{
        Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction Stop|ForEach-Object{
            $commandLine=[string]$_.CommandLine
            if($commandLine-match'(?i)--gameDir\s+"([^"]+)"'){[void]$paths.Add($matches[1])}
            elseif($commandLine-match'(?i)--gameDir\s+([^\s]+)'){[void]$paths.Add($matches[1])}
        }
    }catch{}
    return @($paths)
}

function Get-RecencyScore([string]$Path, [int]$Maximum) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $ageHours = ((Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime).TotalHours
    if ($ageHours -le 24) { return $Maximum }
    if ($ageHours -le 168) { return [math]::Floor($Maximum * 0.7) }
    if ($ageHours -le 720) { return [math]::Floor($Maximum * 0.35) }
    return 0
}

function Get-CandidateScore([string]$Root, $Manifest, [string[]]$RunningGameDirs) {
    $evidence = [System.Collections.Generic.List[string]]::new()
    $score = 0
    $markerPath = Join-Path $Root $Manifest.detector.markerPath
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.packId -eq $Manifest.packId) {
                $score += 100000
                $evidence.Add('marcador Coco instalado previamente (+100000)')
            }
        } catch { }
    }

    foreach ($running in $RunningGameDirs) {
        if ([string]::Equals($Root.TrimEnd('\'), $running.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $score += 1000000
            $evidence.Add("Minecraft Fabric $($Manifest.detector.minecraftVersion) abierto con este --gameDir (+1000000)")
        }
    }

    $versionsPath = Join-Path $Root 'versions'
    $fabricFound = $false
    if (Test-Path -LiteralPath $versionsPath) {
        $fabricFound = @(Get-ChildItem -LiteralPath $versionsPath -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match [regex]::Escape($Manifest.detector.minecraftVersion) -and $_.Name -match '(?i)fabric'
        }).Count -gt 0
    }
    if ($fabricFound) { $score += 80; $evidence.Add("Fabric $($Manifest.detector.minecraftVersion) (+80)") }

    $modNames = @(Get-ChildItem -LiteralPath (Join-Path $Root 'mods') -File -ErrorAction SilentlyContinue | ForEach-Object Name)
    foreach ($rule in @($Manifest.detector.modRules)) {
        if ($modNames | Where-Object { $_ -match $rule.pattern }) {
            $score += [int]$rule.weight
            $evidence.Add("mod: $($rule.name) (+$($rule.weight))")
        }
    }

    $latestLog = Join-Path $Root 'logs\latest.log'
    $logText = Get-FileText $latestLog
    if ($logText) {
        $score += Get-RecencyScore $latestLog 30
        if ($logText -match '(?i)Connecting to|Joined server|se ha unido a la partida|logged in with entity id') {
            $score += 35; $evidence.Add('sesion multijugador registrada (+35)')
        }
        foreach ($token in @($Manifest.detector.groupTokens)) {
            if ($token -and $logText -match [regex]::Escape($token)) {
                $score += 12; $evidence.Add("token de grupo: $token (+12)")
            }
        }
        foreach ($domain in @($Manifest.detector.knownE4mcDomains)) {
            if ($domain -and $logText -match [regex]::Escape($domain)) {
                $score += 45; $evidence.Add("dominio e4mc conocido (+45)")
            }
        }
    }

    $supportFiles = @(
        (Join-Path $Root 'servers.dat'),
        (Join-Path $Root 'usercache.json'),
        (Join-Path $Root 'journeymap'),
        (Join-Path $Root 'Distant_Horizons_server_data')
    )
    foreach ($file in $supportFiles) { $score += Get-RecencyScore $file 10 }

    return [pscustomobject]@{ Root = $Root; Score = $score; Evidence = @($evidence); LatestLog = $latestLog }
}

function Get-Role([string]$Root, $Manifest) {
    # La marca de host es deliberadamente local y nunca forma parte de los packs.
    # Esto evita clasificar como host a amigos que recibieron una copia de los mismos mods.
    if (Test-Path -LiteralPath (Join-Path $Root 'config\coco-host.json')) { return 'host' }
    return 'client'
}

function Disable-TLauncherSkinCape([string]$Root,$Manifest){
    $versionsRoot=Join-Path $Root 'versions'
    if(-not(Test-Path -LiteralPath $versionsRoot)){return 0}
    $repaired=0
    $versionPattern="(?:^|[-_+ .])"+[regex]::Escape([string]$Manifest.detector.minecraftVersion)+"(?:$|[-_+ .])"
    $versionDirectories=@(Get-ChildItem -LiteralPath $versionsRoot -Directory -ErrorAction SilentlyContinue|Where-Object{
        $_.Name-match'(?i)fabric'-and$_.Name-match$versionPattern
    })
    foreach($directory in $versionDirectories){
        $files=@(
            (Join-Path $directory.FullName 'TLauncherAdditional.json'),
            (Join-Path $directory.FullName ($directory.Name+'.json'))
        )|Where-Object{Test-Path -LiteralPath $_}|Select-Object -Unique
        foreach($path in $files){
            try{
                $config=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
                $changed=$false
                foreach($name in 'activateSkinCapeForUserVersion','skinVersion'){
                    $property=$config.PSObject.Properties[$name]
                    if($property-and[bool]$property.Value){$property.Value=$false;$changed=$true}
                }
                if($changed){
                    $tmp="$path.coco-$PID.tmp"
                    $json=$config|ConvertTo-Json -Depth 100
                    [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
                    Move-Item -LiteralPath $tmp -Destination $path -Force
                    $repaired++
                    Write-CocoLog "TLSkinCape de TLauncher desactivado en '$path'."
                }
            }catch{Write-CocoLog "No se pudo ajustar TLSkinCape en '$path': $($_.Exception.Message)"}
        }
    }
    return $repaired
}

function Download-VerifiedFile(
    [string]$Url,
    [string]$Destination,
    [string]$ExpectedHash,
    [int64]$CompletedBytes = 0,
    [int64]$AllBytes = 0,
    [string]$ActivityTitle='Descargando archivos',
    [string]$DetailPrefix='',
    [ValidateRange(0,100)][int]$ProgressStart=5,
    [ValidateRange(0,100)][int]$ProgressEnd=75
) {
    $partial = "$Destination.partial"
    for ($attempt=1; $attempt -le 4; $attempt++) {
        $resumeBytes=if(Test-Path -LiteralPath $partial -PathType Leaf){[int64](Get-Item -LiteralPath $partial).Length}else{[int64]0}
        $hashMismatch=$false
        try {
            $request=$null;$response=$null;$input=$null;$output=$null
            $request=[Net.HttpWebRequest]::Create($Url); $request.UserAgent='CocoMinecraftUpdater/1.0'
            $request.Timeout=30000; $request.ReadWriteTimeout=30000; $request.AutomaticDecompression=[Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            if($resumeBytes-gt0){$request.AddRange($resumeBytes)}
            $response=$request.GetResponse()
            $resumed=($resumeBytes-gt0-and$response.StatusCode-eq[Net.HttpStatusCode]::PartialContent)
            if($resumeBytes-gt0-and-not$resumed){
                Write-CocoLog "El servidor no acepto reanudar '$Url'; reiniciando el archivo parcial de $resumeBytes bytes."
                $resumeBytes=0
            }
            $total=[int64]$response.ContentLength
            if($resumed){$total+=$resumeBytes}
            $input=$response.GetResponseStream()
            $output=if($resumed){[IO.File]::Open($partial,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)}else{[IO.File]::Create($partial)}
            $buffer=New-Object byte[] (1MB); $received=[int64]$resumeBytes; $watch=[Diagnostics.Stopwatch]::StartNew(); $lastUi=[DateTime]::MinValue
            Write-CocoLog "Descarga verificada: intento=$attempt; reanudada=$resumed; bytesIniciales=$resumeBytes; total=$total; destino=$Destination"
            try {
                while (($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $output.Write($buffer,0,$read); $received += $read
                    $now=[DateTime]::UtcNow
                    if (($now - $lastUi).TotalMilliseconds -ge 150 -or $received -eq $total) {
                        $lastUi=$now
                        $span=[Math]::Max(0,$ProgressEnd-$ProgressStart)
                        $percent=if($AllBytes -gt 0){$ProgressStart+[int]($span*($CompletedBytes+$received)/$AllBytes)}elseif($total -gt 0){$ProgressStart+[int]($span*$received/$total)}else{$ProgressStart+[int]($span/2)}
                        $percent=[Math]::Max($ProgressStart,[Math]::Min($ProgressEnd,$percent))
                        $speed=if($watch.Elapsed.TotalSeconds -gt 0){$received/$watch.Elapsed.TotalSeconds}else{0}
                        $eta=if($speed -gt 0 -and $total -gt 0){[TimeSpan]::FromSeconds(($total-$received)/$speed)}else{[TimeSpan]::Zero}
                        $transfer='{0:N1} / {1:N1} MB  |  {2:N1} MB/s  |  faltan ~{3:mm\:ss}' -f ($received/1MB),($total/1MB),($speed/1MB),$eta
                        $detail=if($DetailPrefix){"$DetailPrefix`r`n$transfer"}else{$transfer}
                        Set-CocoState $ActivityTitle $detail $percent
                    }
                }
            } finally { if($output){$output.Dispose()}; if($input){$input.Dispose()}; if($response){$response.Dispose()} }
            if ((Get-Sha256 $partial) -ne $ExpectedHash.ToLowerInvariant()) { $hashMismatch=$true; throw 'La descarga no coincide con el SHA-256 publicado.' }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        } catch {
            $responseStatus=0
            foreach($candidate in @($_.Exception,$_.Exception.InnerException,$_.Exception.InnerException.InnerException)){
                try{if($candidate-and$candidate.Response){$responseStatus=[int]$candidate.Response.StatusCode;break}}catch{}
            }
            $rangeRejected=($responseStatus-eq416)
            if($hashMismatch-or$rangeRejected){Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue}
            $partialBytes=if(Test-Path -LiteralPath $partial -PathType Leaf){(Get-Item -LiteralPath $partial).Length}else{0}
            if($attempt -eq 4){throw}
            $retryMode=if($rangeRejected){'partial-invalid-restart-clean'}elseif($hashMismatch){'hash-mismatch-discard'}else{'partial-preserved'}
            Write-CocoLog "Descarga fallida (intento $attempt): $($_.Exception.Message) | mode=$retryMode | Parcial conservado: $partialBytes bytes"
            $retryPrefix=if($DetailPrefix){$DetailPrefix+' | '}else{''}
            Set-CocoState 'Reintentando descarga' ("{0}Intento {1} de 4; se conserva todo archivo ya verificado."-f$retryPrefix,($attempt+1)) ([Math]::Max($ProgressStart,$script:CocoCurrentProgress))
            Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))
        }
    }
}

function Ensure-BootstrapUpdate($Manifest) {
    $canonical=$env:COCO_BOOTSTRAPPER_EXE
    if($env:COCO_BOOTSTRAP_UPDATE_PENDING-or-not$canonical-or-not$Manifest.bootstrap-or-not$Manifest.bootstrap.url-or-not$Manifest.bootstrap.sha256){return}
    try{
        if((Test-Path $canonical)-and(Get-Sha256 $canonical)-eq$Manifest.bootstrap.sha256.ToLowerInvariant()){return}
        $newExe=Join-Path $env:LOCALAPPDATA "CocoMinecraftUpdater\CocoUpdater.$PID.new.exe"
        Download-VerifiedFile $Manifest.bootstrap.url $newExe $Manifest.bootstrap.sha256
        $helper=Join-Path $env:LOCALAPPDATA "CocoMinecraftUpdater\Apply-CocoBootstrapUpdate-V2-$PID.ps1"
        $helperText=@'
param([int64]$WaitPid,[string]$Source,[string]$Destination,[string]$ExpectedHash,[string]$LogPath)
Wait-Process -Id $WaitPid -ErrorAction SilentlyContinue
$deadline=[DateTime]::UtcNow.AddHours(12)
$lastError=''
$sourceVersion=try{[version]([Diagnostics.FileVersionInfo]::GetVersionInfo($Source).FileVersion)}catch{$null}
do{
    try{
        $destinationVersion=if(Test-Path -LiteralPath $Destination){try{[version]([Diagnostics.FileVersionInfo]::GetVersionInfo($Destination).FileVersion)}catch{$null}}else{$null}
        if($sourceVersion-and$destinationVersion-and$destinationVersion-gt$sourceVersion){
            Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $LogPath "Bootstrap pendiente $sourceVersion omitido: el destino ya tiene $destinationVersion." -ErrorAction SilentlyContinue
            exit 0
        }
        if((Test-Path -LiteralPath $Destination)-and(Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()-eq$ExpectedHash){
            Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $LogPath "Bootstrap actualizado correctamente." -ErrorAction SilentlyContinue
            exit 0
        }
        if(Test-Path -LiteralPath $Destination){
            $backup="$Destination.coco-old.$PID"
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            [IO.File]::Replace($Source,$Destination,$backup,$true)
        }else{[IO.File]::Move($Source,$Destination)}
        if((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()-eq$ExpectedHash){
            if($backup){Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}
            Add-Content -LiteralPath $LogPath "Bootstrap actualizado correctamente." -ErrorAction SilentlyContinue
            exit 0
        }
    }
    catch{$lastError=$_.Exception.Message}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow-lt$deadline)
Add-Content -LiteralPath $LogPath "No se pudo aplicar el bootstrap pendiente antes del limite de 12 horas. Ultimo error: $lastError" -ErrorAction SilentlyContinue
exit 1
'@
        [IO.File]::WriteAllText($helper,$helperText,(New-Object Text.UTF8Encoding($true)))
        $quotedHelper='"'+($helper-replace'"','\"')+'"'
        $quotedSource='"'+($newExe-replace'"','\"')+'"'
        $quotedDestination='"'+($canonical-replace'"','\"')+'"'
        $quotedLog='"'+($script:CocoLogPath-replace'"','\"')+'"'
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedHelper,'-WaitPid',$PID,'-Source',$quotedSource,'-Destination',$quotedDestination,'-ExpectedHash',$Manifest.bootstrap.sha256,'-LogPath',$quotedLog)
        $env:COCO_BOOTSTRAP_UPDATE_PENDING='1'
        Write-CocoLog 'Se programo la reparacion/actualizacion diferida del bootstrap.'
    }catch{Write-CocoLog "No se pudo programar la actualizacion del bootstrap: $($_.Exception.Message)"}
}

function Test-MinecraftRunning([string]$Root) {
    if ($MinecraftPid -gt 0) { return [bool](Get-Process -Id $MinecraftPid -ErrorAction SilentlyContinue) }
    $running = Get-RunningGameDirectories
    return [bool]($running | Where-Object { [string]::Equals($_.TrimEnd('\'), $Root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) })
}

function Test-RunningMinecraftPredatesInstalledPack([string]$Root,$Manifest) {
    $markerPath=Join-Path $Root $Manifest.detector.markerPath
    if(-not(Test-Path -LiteralPath $markerPath)){return $false}
    try{
        $installedAtText=[string]((Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json).installedAt)
        if([string]::IsNullOrWhiteSpace($installedAtText)){return $false}
        $installedAt=[DateTimeOffset]::Parse($installedAtText,[Globalization.CultureInfo]::InvariantCulture)
        $processes=[Collections.Generic.List[Diagnostics.Process]]::new()
        if($MinecraftPid-gt0){
            $known=Get-Process -Id $MinecraftPid -ErrorAction SilentlyContinue
            if($known){$processes.Add($known)}
        }else{
            Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue|ForEach-Object{
                $line=$_.CommandLine;$runningGameDir=$null
                if($line-match'(?i)--gameDir\s+"([^"]+)"'){$runningGameDir=$matches[1]}
                elseif($line-match'(?i)--gameDir\s+([^\s]+)'){$runningGameDir=$matches[1]}
                if($runningGameDir-and[string]::Equals($runningGameDir.TrimEnd('\'),$Root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){
                    $candidate=Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
                    if($candidate){$processes.Add($candidate)}
                }
            }
        }
        foreach($process in $processes){
            $started=[DateTimeOffset]$process.StartTime
            if($started-lt$installedAt.AddSeconds(-2)){return $true}
        }
    }catch{Write-CocoLog "No se pudo comparar inicio de Minecraft con installedAt: $($_.Exception.Message)"}
    return $false
}

function Request-ClientMinecraftClose([string]$Root) {
    $requested=$false
    if($MinecraftPid -gt 0){
        try{
            $minecraftProcess=Get-Process -Id $MinecraftPid -ErrorAction SilentlyContinue
            if($minecraftProcess){
                if($minecraftProcess.MainWindowHandle -ne 0){
                    $requested=$minecraftProcess.CloseMainWindow() -or $requested
                    Write-CocoLog "Cierre normal solicitado al PID de Minecraft $MinecraftPid."
                }else{
                    Write-CocoLog "El PID de Minecraft $MinecraftPid no expone una ventana principal."
                }
            }
        }catch{Write-CocoLog "No se pudo solicitar cierre al PID $MinecraftPid`: $($_.Exception.Message)"}
        if($requested){return $true}
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction Stop | ForEach-Object {
            $line=$_.CommandLine
            $runningGameDir=$null
            if($line -match '(?i)--gameDir\s+"([^"]+)"'){$runningGameDir=$matches[1]}
            elseif($line -match '(?i)--gameDir\s+([^\s]+)'){$runningGameDir=$matches[1]}
            if($runningGameDir -and [string]::Equals($runningGameDir.TrimEnd('\'),$Root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){
                $process=Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
                if($process -and $process.MainWindowHandle -ne 0){$requested=$process.CloseMainWindow() -or $requested}
            }
        }
    }catch{Write-CocoLog "No se pudo solicitar cierre normal: $($_.Exception.Message)"}
    return $requested
}

function Stop-ClientMinecraft([string]$Root) {
    if($MinecraftPid -gt 0){
        $process=Get-Process -Id $MinecraftPid -ErrorAction SilentlyContinue
        if($process){
            Write-CocoLog "Minecraft no respondio al cierre normal; terminando PID $MinecraftPid."
            Stop-Process -Id $MinecraftPid -Force -ErrorAction Stop
        }
        return
    }
    Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        $line=$_.CommandLine
        $runningGameDir=$null
        if($line -match '(?i)--gameDir\s+"([^"]+)"'){$runningGameDir=$matches[1]}
        elseif($line -match '(?i)--gameDir\s+([^\s]+)'){$runningGameDir=$matches[1]}
        if($runningGameDir -and [string]::Equals($runningGameDir.TrimEnd('\'),$Root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){
            Write-CocoLog "Minecraft no respondio al cierre normal; terminando PID $($_.ProcessId)."
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Wait-ForMinecraftExit([string]$Root,[bool]$CloseClientAutomatically=$false) {
    $wait=[Diagnostics.Stopwatch]::StartNew()
    $lastCloseAttempt=-10
    while ($true) {
        if (-not (Test-MinecraftRunning $Root)) { return }
        if($CloseClientAutomatically){
            if(($wait.Elapsed.TotalSeconds-$lastCloseAttempt)-ge5){
                [void](Request-ClientMinecraftClose $Root)
                $lastCloseAttempt=$wait.Elapsed.TotalSeconds
            }
            if($wait.Elapsed.TotalSeconds-ge$AutomaticCloseTimeoutSeconds){
                Set-CocoState 'Cerrando Minecraft' 'Minecraft no respondio; completando el cierre automaticamente...' 3
                Stop-ClientMinecraft $Root
            }else{
                Set-CocoState 'Cerrando Minecraft' 'Intentando cerrar Minecraft automaticamente...' 3
            }
        }else{
            Set-CocoState 'Preparando actualizacion' 'Esperando a que Minecraft termine de cerrarse...' 3
        }
        Start-Sleep -Milliseconds 500
    }
}

function Stage-Package($Package, $Manifest, [string]$Root) {
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\downloads'
    $stage = Join-Path $cacheRoot "stage-$([guid]::NewGuid())"
    $stageMods = Join-Path $stage 'mods'
    $jarCache = Join-Path $cacheRoot 'jars'
    New-Item -ItemType Directory -Path $stageMods,$jarCache -Force | Out-Null
    if (-not $Package.mods -or @($Package.mods).Count -eq 0) { throw 'El manifiesto no contiene mods para este rol.' }

    $needed = [System.Collections.Generic.List[object]]::new()
    foreach ($mod in @($Package.mods)) {
        $installed = Join-Path (Join-Path $Root 'mods') $mod.name
        if ((Test-Path -LiteralPath $installed) -and (Get-Sha256 $installed) -eq $mod.sha256.ToLowerInvariant()) {
            Copy-Item -LiteralPath $installed -Destination (Join-Path $stageMods $mod.name) -Force
        } else { $needed.Add($mod) }
    }
    $allBytes = [int64](($needed | Measure-Object -Property size -Sum).Sum)
    $completed = [int64]0
    foreach ($mod in $needed) {
        $safeCacheName = "$($mod.sha256)-$($mod.name)"
        $cached = Join-Path $jarCache $safeCacheName
        if (-not ((Test-Path -LiteralPath $cached) -and (Get-Sha256 $cached) -eq $mod.sha256.ToLowerInvariant())) {
            Download-VerifiedFile $mod.url $cached $mod.sha256 $completed $allBytes
        }
        Copy-Item -LiteralPath $cached -Destination (Join-Path $stageMods $mod.name) -Force
        $completed += [int64]$mod.size
    }
    foreach($managed in @($Manifest.managedConfigFiles)){
        if(-not$managed){continue}
        $relative=([string]$managed.path)-replace'/','\'
        if(-not$relative-or[IO.Path]::IsPathRooted($relative)-or$relative-notmatch'(?i)^config\\'-or
           @($relative-split'\\'|Where-Object{$_-eq'..'}).Count){throw "Ruta de configuracion administrada invalida: $relative"}
        $stageFull=[IO.Path]::GetFullPath($stage).TrimEnd('\')+'\'
        $destination=[IO.Path]::GetFullPath((Join-Path $stage $relative))
        if(-not$destination.StartsWith($stageFull,[StringComparison]::OrdinalIgnoreCase)){throw "Ruta fuera del staging: $relative"}
        try{$bytes=[Convert]::FromBase64String([string]$managed.contentBase64)}catch{throw "Contenido Base64 invalido para $relative"}
        if($bytes.Length-ne[int64]$managed.size){throw "Tamano invalido para $relative"}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        if($hash-ne([string]$managed.sha256).ToLowerInvariant()){throw "Hash invalido para $relative"}
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
        [IO.File]::WriteAllBytes($destination,$bytes)
    }
    if($Package.role-eq'host'){
        # The host's mods folder is also the Publisher's source of truth. Keep
        # newly added, unique Fabric mods until they can be published. Never
        # keep an old filename when its Fabric ID is already supplied by the
        # manifest, since that would create a duplicate-ID startup crash.
        $stagedIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Get-ChildItem -LiteralPath $stageMods -File -Filter '*.jar'|ForEach-Object{
            $modId=Get-CocoFabricModId $_.FullName
            if($modId){[void]$stagedIds.Add($modId)}
        }
        $manifestNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($mod in @($Package.mods)){[void]$manifestNames.Add([string]$mod.name)}
        Get-ChildItem -LiteralPath (Join-Path $Root 'mods') -File -Filter '*.jar' -ErrorAction SilentlyContinue|ForEach-Object{
            if($manifestNames.Contains($_.Name)){return}
            $modId=Get-CocoFabricModId $_.FullName
            if($modId-and$stagedIds.Contains($modId)){
                Write-CocoLog "JAR extra del host omitido por ID Fabric duplicado: $($_.Name) [$modId]"
                return
            }
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stageMods $_.Name) -Force
            if($modId){[void]$stagedIds.Add($modId)}
            Write-CocoLog "JAR adicional del host preservado: $($_.Name)$(if($modId){" [$modId]"})"
        }
    }
    return $stage
}

function Invoke-CocoClientSettingsMigrations([string]$Root, $Manifest) {
    $applied=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $markerPath=Join-Path $Root $Manifest.detector.markerPath
    if(Test-Path -LiteralPath $markerPath){
        try{
            $previous=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
            foreach($id in @($previous.appliedClientSettingsMigrations)){
                if($id){[void]$applied.Add([string]$id)}
            }
        }catch{Write-CocoLog "No se pudo leer el historial de migraciones de cliente: $($_.Exception.Message)"}
    }

    foreach($migration in @($Manifest.clientSettingsMigrations)){
        $id=[string]$migration.id
        if(-not$id-or$applied.Contains($id)){continue}
        if([string]$migration.type-ne'minecraft-option-default'){
            throw "Tipo de migracion de cliente no soportado: $($migration.type)"
        }
        $key=[string]$migration.key
        $from=[string]$migration.from
        $to=[string]$migration.to
        if(-not$key-or-not$to-or$key.Contains(':')-or$key.Contains("`r")-or$key.Contains("`n")-or
           $from.Contains("`r")-or$from.Contains("`n")-or$to.Contains("`r")-or$to.Contains("`n")){
            throw "Migracion de cliente invalida: $id"
        }

        try{
            $optionsPath=Join-Path $Root 'options.txt'
            $lines=[Collections.Generic.List[string]]::new()
            if(Test-Path -LiteralPath $optionsPath){$lines.AddRange([string[]][IO.File]::ReadAllLines($optionsPath))}
            $prefix="$key`:"
            $indices=@(for($i=0;$i-lt$lines.Count;$i++){if($lines[$i].StartsWith($prefix,[StringComparison]::Ordinal)){,$i}})
            $changed=$false
            if($indices.Count-eq0){
                $lines.Add("$prefix$to")
                $changed=$true
                Write-CocoLog "Migracion ${id}: valor inicial agregado para $key."
            }elseif($indices.Count-eq1-and$lines[$indices[0]]-ceq"$prefix$from"){
                $lines[$indices[0]]="$prefix$to"
                $changed=$true
                Write-CocoLog "Migracion ${id}: valor predeterminado actualizado para $key."
            }else{
                Write-CocoLog "Migracion ${id}: $key ya fue personalizado; se conserva sin cambios."
            }

            if($changed){
                if(Test-Path -LiteralPath $optionsPath){
                    $safeId=$id-replace'[^A-Za-z0-9._-]','_'
                    Copy-Item -LiteralPath $optionsPath -Destination "$optionsPath.coco-before-$safeId.bak" -Force
                }
                $tmp="$optionsPath.coco.tmp"
                [IO.File]::WriteAllLines($tmp,$lines,(New-Object Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $tmp -Destination $optionsPath -Force
            }
            [void]$applied.Add($id)
        }catch{
            Write-CocoLog "Migracion ${id} omitida sin bloquear el pack: $($_.Exception.Message)"
        }
    }
    return @($applied|Sort-Object)
}

function Install-StagedPackage([string]$Root, [string]$Stage, $Package, $Manifest) {
    Set-CocoState 'Instalando Coco Pack' 'Ajustando exactamente la carpeta de mods...' 78
    $oldMods = Join-Path $Root 'mods'
    $transientMods = Join-Path $Root '.coco-mods-replacing'
    Repair-InterruptedInstall $Root
    if (Test-Path -LiteralPath $transientMods) { throw 'No se pudo limpiar una instalacion interrumpida anterior.' }
    if (Test-Path $oldMods) { Move-Item -LiteralPath $oldMods -Destination $transientMods -Force }
    try {
        Move-Item -LiteralPath (Join-Path $Stage 'mods') -Destination $oldMods -Force
    } catch {
        if ((Test-Path $transientMods) -and -not (Test-Path $oldMods)) {
            Move-Item -LiteralPath $transientMods -Destination $oldMods -Force
        }
        throw
    }
    Remove-Item -LiteralPath $transientMods -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path (Join-Path $Stage 'config')) {
        Set-CocoState 'Aplicando configuracion' 'Sincronizando ajustes del pack...' 82
        $targetConfig = Join-Path $Root 'config'
        New-Item -ItemType Directory -Path $targetConfig -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $Stage 'config') -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $targetConfig -Recurse -Force
        }
    }

    $appliedClientSettingsMigrations=@(Invoke-CocoClientSettingsMigrations $Root $Manifest)

    $markerPath = Join-Path $Root $Manifest.detector.markerPath
    New-Item -ItemType Directory -Path (Split-Path $markerPath -Parent) -Force | Out-Null
    [pscustomobject]@{
        packId = $Manifest.packId
        version = $Manifest.version
        role = $Package.role
        installedAt = (Get-Date).ToString('o')
        target = $Root
        appliedClientSettingsMigrations = $appliedClientSettingsMigrations
    } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
    $targetPath = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\target.json'
    New-Item -ItemType Directory -Path (Split-Path $targetPath -Parent) -Force | Out-Null
    [pscustomobject]@{path=$Root;packId=$Manifest.packId;updatedAt=(Get-Date).ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath $targetPath -Encoding UTF8
    Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\downloads\jars') -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $elapsed = if($script:CocoVisualWorkStarted){$script:CocoVisualWorkStarted.Elapsed.TotalSeconds}else{7}
    $remaining = [Math]::Max(0, 7 - $elapsed)
    $startProgress = [Math]::Min(99,[Math]::Max(85,$script:CocoCurrentProgress))
    $start = [Diagnostics.Stopwatch]::StartNew()
    while ($start.Elapsed.TotalSeconds -lt $remaining) {
        $fraction = if($remaining -gt 0){$start.Elapsed.TotalSeconds/$remaining}else{1}
        $smooth = $startProgress + [int]((99-$startProgress) * $fraction)
        Set-CocoState 'Instalando Coco Pack' 'Aplicando y verificando archivos...' $smooth
        Start-Sleep -Milliseconds 25
    }
}

function Test-CurrentVersion([string]$Root, $Manifest, [string]$Role) {
    $markerPath = Join-Path $Root $Manifest.detector.markerPath
    if (-not (Test-Path $markerPath)) { return $false }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if (-not ($marker.packId -eq $Manifest.packId -and $marker.version -eq $Manifest.version -and $marker.role -eq $Role)) { return $false }
        $package = @($Manifest.packages | Where-Object role -eq $Role) | Select-Object -First 1
        if (-not $package -or -not $package.mods) { return $false }
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $Root 'mods') -File -Filter '*.jar' -ErrorAction SilentlyContinue)
        if ($role-ne'host'-and$actual.Count -ne @($package.mods).Count) { return $false }
        foreach ($mod in @($package.mods)) {
            $path = Join-Path (Join-Path $Root 'mods') $mod.name
            if (-not (Test-Path -LiteralPath $path)) { return $false }
            if ((Get-Sha256 $path) -ne $mod.sha256.ToLowerInvariant()) { return $false }
        }
        return $true
    } catch { return $false }
}

function Show-CocoPreview {
    Show-CocoWindow
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt 11){
        $seconds=$watch.Elapsed.TotalSeconds
        if($seconds -lt 2){
            $p=[int](5+10*$seconds/2);Set-CocoState 'Buscando Minecraft' 'Identificando automaticamente la instalacion correcta...' $p
        }elseif($seconds -lt 7){
            $fraction=($seconds-2)/5;$p=[int](15+58*$fraction)
            $downloaded=101*$fraction;Set-CocoState 'Descargando mods' ('{0:N1} / 101,0 MB  |  20,2 MB/s  |  faltan ~00:{1:00}' -f $downloaded,[Math]::Max(0,[int](5-5*$fraction))) $p
        }else{
            $fraction=($seconds-7)/4;$p=[int](73+26*$fraction);Set-CocoState 'Instalando Coco Pack' 'Aplicando y verificando archivos...' $p
        }
        Start-Sleep -Milliseconds 25
    }
    Set-CocoState 'Coco Pack actualizado' 'Vista previa completada' 100
    Start-Sleep -Seconds 5
}

$launcherLibrary=Join-Path $script:CocoEngineRoot 'CocoLauncher.ps1'
if(Test-Path -LiteralPath $launcherLibrary){
    $launcherSource=[IO.File]::ReadAllText($launcherLibrary,[Text.Encoding]::UTF8)
    $launcherBlock=[ScriptBlock]::Create($launcherSource)
    . $launcherBlock
}

$networkLibrary=Join-Path $script:CocoEngineRoot 'CocoNetwork.ps1'
if(Test-Path -LiteralPath $networkLibrary){
    # El bootstrapper ejecuta el engine desde memoria para funcionar incluso
    # cuando Windows conserva la politica predeterminada Restricted. Cargar un
    # .ps1 secundario por ruta volveria a activar ese bloqueo, por lo que este
    # componente se incorpora al mismo contexto de memoria.
    $networkSource=[IO.File]::ReadAllText($networkLibrary,[Text.Encoding]::UTF8)
    $networkBlock=[ScriptBlock]::Create($networkSource)
    . $networkBlock
}

$mutex=$null;$mutexAcquired=$false
$networkMutex=$null;$networkMutexAcquired=$false
$legacyNetworkMutex=$null;$legacyNetworkMutexAcquired=$false
function Enter-CocoMutex($Mutex,[int]$TimeoutMilliseconds){
    try{return $Mutex.WaitOne($TimeoutMilliseconds)}
    catch [Threading.AbandonedMutexException]{
        Write-CocoLog 'Se recupero un bloqueo abandonado por una ejecucion anterior.'
        return $true
    }
}

try {
    # La preparacion silenciosa de red al arrancar Minecraft no debe bloquear
    # una actualizacion completa disparada durante el login. Cada trabajo tiene
    # su propia exclusión; el updater completo toma además la de red solamente
    # cuando realmente va a modificar o verificar ZeroTier.
    $mutexName=if($NetworkOnly){'Local\CocoMinecraftUpdaterNetwork'}else{'Local\CocoMinecraftUpdaterUpdate'}
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired=if($NetworkOnly){Enter-CocoMutex $mutex 0}else{Enter-CocoMutex $mutex 30000}
    if (-not $mutexAcquired) { exit 0 }
    $engineParent=Split-Path $script:CocoEngineRoot -Parent
    if((Split-Path $engineParent -Leaf)-eq'engine'){
        $currentVer=try{[version](Split-Path $script:CocoEngineRoot -Leaf)}catch{$null}
        Get-ChildItem -LiteralPath $engineParent -Directory -ErrorAction SilentlyContinue | Where-Object {
            $dirVer=try{[version]$_.Name}catch{$null}
            if($currentVer -and $dirVer){ return $dirVer -lt $currentVer }
            return $_.FullName -ne $script:CocoEngineRoot
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $cacheRoot=Split-Path $engineParent -Parent
        Get-ChildItem -LiteralPath $cacheRoot -File -Filter 'engine-*.zip' -ErrorAction SilentlyContinue |
            Where-Object Name -ne "engine-$((Split-Path $script:CocoEngineRoot -Leaf)).zip" | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "No existe el manifiesto: $ManifestPath" }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.packId -or -not $manifest.version -or -not $manifest.detector) { throw 'Manifiesto incompleto.' }
    Ensure-BootstrapUpdate $manifest
    if(-not$TestSuppressUi-and(Get-Command Initialize-CocoLauncherMigration -ErrorAction SilentlyContinue)){
        $canonical=$env:COCO_BOOTSTRAPPER_EXE
        if($canonical){Initialize-CocoLauncherMigration $canonical (-not$NetworkOnly)}
    }
    if($Preview){Show-CocoPreview;exit 0}

    # Una ejecucion manual del mismo EXE canónico ya es Coco Launcher. Los
    # modos invocados por Bridge, Publisher, pruebas o recuperación conservan
    # exactamente el engine updater anterior.
    $manualOriginalRunning=$false
    if(-not$Silent-and-not$TestSuppressUi-and-not$DetectOnly-and-not$NetworkOnly-and[string]::IsNullOrWhiteSpace($GameDir)-and$MinecraftPid-le0){
        $manualOriginalRunning=@(Get-RunningMinecraftInstances $manifest|Where-Object Compatible).Count-gt0
    }
    $manualLauncher=-not$Silent-and-not$TestSuppressUi-and-not$DetectOnly-and-not$NetworkOnly-and-not$manualOriginalRunning-and
        [string]::IsNullOrWhiteSpace($GameDir)-and$MinecraftPid-le0-and
        [string]::IsNullOrWhiteSpace($SessionStatePath)-and-not$automaticFullCheck
    $catalogPath=Join-Path $script:CocoEngineRoot 'launcher\catalog.json'
    if($manualLauncher-and(Test-Path -LiteralPath $catalogPath -PathType Leaf)-and(Get-Command Start-CocoLauncherUi -ErrorAction SilentlyContinue)){
        $launcherCandidates=@(Get-CandidateRoots|ForEach-Object{Get-CandidateScore $_ $manifest @()}|Sort-Object @{Expression='Score';Descending=$true},@{Expression='Root';Descending=$false})
        $legacyRoot=if($launcherCandidates.Count){[string]$launcherCandidates[0].Root}else{Join-Path $env:APPDATA '.minecraft'}
        Write-CocoLog "Modo Coco Launcher para experiencias administradas. LegacyRoot de deteccion de identidad='$legacyRoot'"
        Start-CocoLauncherUi $manifest $legacyRoot $LauncherTestRoot
        exit 0
    }

    if (-not $Silent) { Show-CocoWindow }
    Set-CocoState 'Buscando Minecraft' 'Identificando automaticamente la instalacion correcta...' 6
    if($GameDir){Repair-InterruptedInstall $GameDir}
    $runningInstances=@(Get-RunningMinecraftInstances $manifest)
    $compatibleRunningDirs=@($runningInstances|Where-Object Compatible|ForEach-Object GameDir|Select-Object -Unique)
    if(-not$GameDir-and$compatibleRunningDirs.Count-gt1){
        throw "Hay mas de un Minecraft Fabric $($manifest.detector.minecraftVersion) abierto. Deja abierta solo la instalacion que quieres actualizar."
    }
    if(-not$GameDir-and$runningInstances.Count-and-not$compatibleRunningDirs.Count){
        $versions=@($runningInstances|ForEach-Object VersionId|Select-Object -Unique)-join', '
        throw "El Minecraft abierto no es Fabric $($manifest.detector.minecraftVersion) (detectado: $versions). Abre la version Coco correcta hasta el menu y vuelve a ejecutar el updater."
    }
    $runningDirs=$compatibleRunningDirs
    if ($GameDir -and (Test-GameDirectory $GameDir)) {
        $candidates = @(Get-CandidateScore (Resolve-Path -LiteralPath $GameDir).Path $manifest $runningDirs)
    } else {
        $candidates = @(Get-CandidateRoots $compatibleRunningDirs | ForEach-Object { Get-CandidateScore $_ $manifest $runningDirs })
    }
    if ($candidates.Count -eq 0) { throw 'No se encontro ninguna carpeta de Minecraft con mods.' }
    $selected = $candidates | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Root'; Descending = $false } | Select-Object -First 1
    $role = Get-Role $selected.Root $manifest
    $package = @($manifest.packages | Where-Object { $_.role -eq $role }) | Select-Object -First 1
    if (-not $package) { $package = @($manifest.packages | Where-Object { $_.role -eq 'client' }) | Select-Object -First 1 }
    if (-not $package) { throw "No hay paquete para el rol $role." }

    Write-Status "Destino elegido: $($selected.Root)"
    Write-Status "Evidencia: $($selected.Evidence -join '; ')"
    Write-CocoLog "Destino='$($selected.Root)' Score=$($selected.Score) Role=$role Version=$($manifest.version)"
    Write-CocoLog "Evidencia=$($selected.Evidence -join '; ')"
    if ($DetectOnly) {
        [pscustomobject]@{
            selected = $selected
            role = $role
            candidates = @($candidates | Sort-Object Score -Descending)
        } | ConvertTo-Json -Depth 6
        exit 0
    }
    $tlauncherRepairs=if($NetworkOnly){0}else{Disable-TLauncherSkinCape $selected.Root $manifest}
    if($tlauncherRepairs){Write-CocoLog "Compatibilidad TLauncher reparada en $tlauncherRepairs archivo(s)."}
    $explicitRunningVersionOutdated=$MinecraftPid-gt0-and-not[string]::IsNullOrWhiteSpace($RunningPackVersion)-and-not[string]::Equals($RunningPackVersion,[string]$manifest.version,[StringComparison]::OrdinalIgnoreCase)
    $runningPredatesInstalledPack=Test-RunningMinecraftPredatesInstalledPack $selected.Root $manifest
    $installedMarkerVersion=''
    try{
        $installedMarkerPath=Join-Path $selected.Root $manifest.detector.markerPath
        if(Test-Path -LiteralPath $installedMarkerPath){$installedMarkerVersion=[string]((Get-Content -LiteralPath $installedMarkerPath -Raw|ConvertFrom-Json).version)}
    }catch{$installedMarkerVersion=''}
    $installedMarkerOutdated=-not[string]::IsNullOrWhiteSpace($installedMarkerVersion)-and-not[string]::Equals($installedMarkerVersion,[string]$manifest.version,[StringComparison]::OrdinalIgnoreCase)
    $earlyClientUpdateKnown=$automaticFullCheck-and$role-eq'client'-and($explicitRunningVersionOutdated-or$runningPredatesInstalledPack-or$installedMarkerOutdated)
    $minecraftExitHandled=$false
    if($earlyClientUpdateKnown){
        Write-CocoLog "Actualizacion conocida antes de preparar la red. RunningPackVersion='$RunningPackVersion' InstalledMarker='$installedMarkerVersion' Published='$($manifest.version)' PredatesInstall=$runningPredatesInstalledPack"
    }
    # Esta comprobacion es completamente local. Debe ocurrir antes de la red
    # para cubrir Bridges muy antiguos que no informan su version cargada.
    $diskCurrent=Test-CurrentVersion $selected.Root $manifest $role
    $runningClientOutdated=$role-eq'client'-and($explicitRunningVersionOutdated-or$runningPredatesInstalledPack)
    $clientUpdateRequired=-not$NetworkOnly-and$role-eq'client'-and(-not$diskCurrent-or$runningClientOutdated)
    if($clientUpdateRequired){
        if(-not$script:CocoForm-and(-not$Silent-or$ShowOnUpdate-or$automaticFullCheck)){Show-CocoWindow}
        Set-CocoState 'Actualizacion encontrada' 'Intentando cerrar Minecraft automaticamente...' 2 $true 'closeMinecraft'
        Write-CocoLog "Cierre de Minecraft previo a red. DiskCurrent=$diskCurrent RunningClientOutdated=$runningClientOutdated"
        if(Test-MinecraftRunning $selected.Root){[void](Request-ClientMinecraftClose $selected.Root)}
        Wait-ForMinecraftExit $selected.Root $true
        $minecraftExitHandled=$true
    }
    if($manifest.network){
        if(-not(Get-Command Ensure-CocoNetwork -ErrorAction SilentlyContinue)){throw 'El engine no contiene los componentes de red requeridos por este pack.'}
        if($NetworkOnly){
            [void](Ensure-CocoNetwork $selected.Root $role $manifest)
        }else{
            $networkMutex=New-Object System.Threading.Mutex($false,'Local\CocoMinecraftUpdaterNetwork')
            $networkWait=[Diagnostics.Stopwatch]::StartNew()
            while(-not($networkMutexAcquired=Enter-CocoMutex $networkMutex 250)){
                if($networkWait.Elapsed.TotalSeconds-ge120){throw 'La comprobacion de red anterior no termino. Vuelve a intentarlo.'}
                if($script:CocoForm){
                    Set-CocoState 'Preparando red Coco' 'Esperando que termine la comprobacion de red anterior...' 4
                    [Windows.Forms.Application]::DoEvents()
                }
            }
            # Compatibilidad con 0.5.39 y anteriores: esos engines usaban este
            # mutex unico. Se espera solo despues de mostrar UI y cerrar MC.
            $legacyNetworkMutex=New-Object System.Threading.Mutex($false,'Local\CocoMinecraftUpdater')
            while(-not($legacyNetworkMutexAcquired=Enter-CocoMutex $legacyNetworkMutex 250)){
                if($networkWait.Elapsed.TotalSeconds-ge120){throw 'La comprobacion anterior no termino. Vuelve a intentarlo.'}
                if($script:CocoForm){
                    Set-CocoState 'Preparando red Coco' 'Esperando que termine la comprobacion anterior...' 4
                    [Windows.Forms.Application]::DoEvents()
                }
            }
            try{[void](Ensure-CocoNetwork $selected.Root $role $manifest)}finally{
                if($legacyNetworkMutexAcquired){$legacyNetworkMutex.ReleaseMutex()|Out-Null;$legacyNetworkMutexAcquired=$false}
                $legacyNetworkMutex.Dispose();$legacyNetworkMutex=$null
                if($networkMutexAcquired){$networkMutex.ReleaseMutex()|Out-Null;$networkMutexAcquired=$false}
                $networkMutex.Dispose();$networkMutex=$null
            }
        }
    }
    if($NetworkOnly-and
       (Get-Command Sync-CocoOriginalSkinRegistry -ErrorAction SilentlyContinue)-and
       (Get-Command Get-CocoLauncherPaths -ErrorAction SilentlyContinue)){
        try{
            $skinCatalogPath=Join-Path $script:CocoEngineRoot 'launcher\catalog.json'
            if(-not(Test-Path -LiteralPath $skinCatalogPath -PathType Leaf)){
                $developmentCatalog=Join-Path (Split-Path $script:CocoEngineRoot -Parent) 'launcher\catalog.template.json'
                if(Test-Path -LiteralPath $developmentCatalog -PathType Leaf){$skinCatalogPath=$developmentCatalog}
            }
            if(Test-Path -LiteralPath $skinCatalogPath -PathType Leaf){
                $skinCatalog=Read-CocoLauncherCatalog $skinCatalogPath
                $skinPaths=Get-CocoLauncherPaths $script:CocoEngineRoot
                $skinResult=Sync-CocoOriginalSkinRegistry $skinCatalog $skinPaths $selected.Root $role $MinecraftPid
                Write-CocoLog "Skins Coco original: Online=$($skinResult.Online) Uploaded=$($skinResult.Uploaded) Downloaded=$($skinResult.Downloaded) Pending=$($skinResult.Pending) Error='$($skinResult.Error)'"
            }else{
                Write-CocoLog 'Sincronizacion de skins omitida: el engine no contiene launcher/catalog.json.'
            }
        }catch{
            # Una caida del registro visual no debe impedir que ZeroTier ni el
            # mundo original arranquen. La seleccion queda pendiente y se
            # reintenta automaticamente en la proxima apertura.
            Write-CocoLog "Sincronizacion de skins no bloqueante: $($_.Exception.Message)"
        }
    }
    if($NetworkOnly){
        Set-CocoState 'Red Coco lista' 'La LAN virtual esta preparada' 100 $false
        exit 0
    }
    if ($diskCurrent -and -not$runningClientOutdated) {
        Set-CocoState 'Coco Pack actualizado' "Version $($manifest.version) | Todo listo" 100 $false
        if($mutex){$mutex.ReleaseMutex()|Out-Null;$mutexAcquired=$false;$mutex.Dispose();$mutex=$null}
        if($script:CocoForm){Show-CocoSuccessAndWait ([string]$manifest.version) 'No hay nada pendiente. Puedes abrir Minecraft y jugar.'}
        exit 0
    }
    if (-not $script:CocoForm -and (-not$Silent-or$ShowOnUpdate-or$automaticFullCheck)) { Show-CocoWindow }
    if($runningClientOutdated){
        Write-CocoLog "Minecraft requiere reinicio aunque el disco ya este actualizado. RunningPackVersion='$RunningPackVersion' Published='$($manifest.version)' PredatesInstall=$runningPredatesInstalledPack"
    }
    if(-not$minecraftExitHandled-and(Test-MinecraftRunning $selected.Root)){
        Set-CocoState 'Actualizacion encontrada' 'Eres el host: cierra Minecraft cuando termine la sesion LAN' 2
    }
    if(-not$minecraftExitHandled){Wait-ForMinecraftExit $selected.Root ($role -eq 'client')}
    if($diskCurrent){
        Write-CocoLog 'Minecraft antiguo cerrado; los archivos del pack ya estaban actualizados en disco.'
        if($mutex){$mutex.ReleaseMutex()|Out-Null;$mutexAcquired=$false;$mutex.Dispose();$mutex=$null}
        Show-CocoSuccessAndWait ([string]$manifest.version) 'La version nueva ya estaba instalada. Vuelve a abrir Minecraft.'
        exit 0
    }
    $stage = Stage-Package $package $manifest $selected.Root
    Install-StagedPackage $selected.Root $stage $package $manifest
    Write-CocoLog 'Actualizacion completada correctamente.'
    Write-Status 'Actualizacion terminada.'
    if($mutex){$mutex.ReleaseMutex()|Out-Null;$mutexAcquired=$false;$mutex.Dispose();$mutex=$null}
    Show-CocoSuccessAndWait ([string]$manifest.version) 'Ya puedes volver a abrir Minecraft.'
    exit 0
} catch {
    Write-CocoLog ("ERROR: " + ($_ | Out-String))
    $diagnosticPath=Write-CocoEngineDiagnostic $_
    if (-not $script:CocoForm -and (-not$Silent-or$ShowOnUpdate-or$automaticFullCheck)) { Show-CocoWindow }
    $friendly=$_.Exception.Message
    if($friendly -match '(?i)ZeroTier|red Coco|Network ID|autoriz|adaptador virtual|servicio.*ONLINE|permiso de administrador'){$friendly=$_.Exception.Message}
    elseif($friendly -match '(?i)access.*denied|acceso.*denegado|unauthorized'){$friendly='Windows bloqueo el acceso a la carpeta de Minecraft. Revisa permisos o el antivirus.'}
    elseif($friendly -match '(?i)conectar|connection|nombre remoto|timed out'){$friendly='No pudimos completar la descarga. Revisa internet y vuelve a intentarlo.'}
    elseif($friendly.Length-gt150){$friendly=$friendly.Substring(0,147)+'...'}
    if($diagnosticPath){$friendly+="`nEnvia por Discord: $([IO.Path]::GetFileName($diagnosticPath))"}
    if(Get-Command Get-CocoFailureClassification -ErrorAction SilentlyContinue){$kind=Get-CocoFailureClassification ([string]$_.Exception.Message);$friendly+="`nCodigo: $($kind.Code) | $($kind.Action)"}
    Set-CocoState 'NO SE PUDO COMPLETAR COCO' $friendly 0 $true 'failure'
    Start-Sleep -Seconds 10
    exit 1
} finally {
    if($networkMutex){
        if($networkMutexAcquired){$networkMutex.ReleaseMutex()|Out-Null}
        $networkMutex.Dispose()
    }
    if($legacyNetworkMutex){
        if($legacyNetworkMutexAcquired){$legacyNetworkMutex.ReleaseMutex()|Out-Null}
        $legacyNetworkMutex.Dispose()
    }
    if ($mutex) {
        if($mutexAcquired){$mutex.ReleaseMutex() | Out-Null}
        $mutex.Dispose()
    }
}
