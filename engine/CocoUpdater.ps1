[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [string]$ManifestUrl,
    [string]$GameDir,
    [int64]$MinecraftPid = 0,
    [string]$SessionStatePath,
    [switch]$Preview,
    [switch]$DetectOnly,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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
function Write-CocoLog([string]$Text) {
    try { Add-Content -LiteralPath $script:CocoLogPath -Value ("{0:o} {1}" -f (Get-Date),$Text) -Encoding UTF8 } catch { }
}
Write-CocoLog "Inicio. EnginePid=$PID GameDir='$GameDir' MinecraftPid=$MinecraftPid Silent=$Silent"
if($global:CocoSharedUi){
    $script:CocoForm=$global:CocoSharedUi.Form;$script:CocoTitle=$global:CocoSharedUi.Title
    $script:CocoDetail=$global:CocoSharedUi.Detail;$script:CocoProgress=$global:CocoSharedUi.Progress
    $script:CocoTrack=$global:CocoSharedUi.Track
    $script:CocoVisualWorkStarted=$global:CocoSharedUi.Started
}

function Set-CocoState([string]$Message, [string]$Detail, [int]$Progress, [bool]$Visible = $true, [string]$Action = '') {
    $Progress = [Math]::Max(0, [Math]::Min(100, $Progress))
    $script:CocoCurrentProgress = $Progress
    if ($SessionStatePath) {
        New-Item -ItemType Directory -Path (Split-Path $SessionStatePath -Parent) -Force | Out-Null
        $tmp = "$SessionStatePath.tmp"
        [pscustomobject]@{message=$Message;detail=$Detail;progress=$Progress;visible=$Visible;action=$Action;updatedAt=(Get-Date).ToString('o')} |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $SessionStatePath -Force
    }
    if ($script:CocoForm) {
        $uiProgress=$Progress
        if($global:CocoSharedUi){$uiProgress=[Math]::Min(100,[int]($global:CocoSharedUi.BaseProgress+(100-$global:CocoSharedUi.BaseProgress)*$Progress/100))}
        $script:CocoTitle.Text=$Message; $script:CocoDetail.Text=$Detail
        $trackWidth=if($script:CocoTrack){$script:CocoTrack.ClientSize.Width}else{570}
        $script:CocoProgress.Width=[Math]::Max(4,[int]($trackWidth*$uiProgress/100))
        $script:CocoForm.Refresh(); [Windows.Forms.Application]::DoEvents()
    }
}

function Show-CocoWindow {
    if ($script:CocoForm) { return }
    $script:CocoVisualWorkStarted = [Diagnostics.Stopwatch]::StartNew()
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $key=[Drawing.Color]::FromArgb(1,2,3)
    $f=New-Object Windows.Forms.Form; $f.Text='Coco Minecraft Updater'; $f.Size=New-Object Drawing.Size(1080,740)
    $f.StartPosition='CenterScreen'; $f.FormBorderStyle='None'; $f.MaximizeBox=$false; $f.ShowInTaskbar=$true
    $f.AutoScaleMode='None'; $f.TopMost=$true
    $f.Add_FormClosing({param($sender,$eventArgs) if(-not$script:CocoAllowClose){$eventArgs.Cancel=$true}})
    $f.BackColor=$key; $f.TransparencyKey=$key; $f.ForeColor=[Drawing.Color]::White
    $iconPath=Join-Path $script:CocoEngineRoot 'assets\reynaico.ico'
    if(Test-Path $iconPath){$f.Icon=New-Object Drawing.Icon($iconPath)}
    $panel=New-Object Windows.Forms.Panel; $panel.Location=New-Object Drawing.Point(25,190); $panel.Size=New-Object Drawing.Size(780,350)
    $panel.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $accent=New-Object Windows.Forms.Panel; $accent.Location=New-Object Drawing.Point(0,0); $accent.Size=New-Object Drawing.Size(9,350)
    $accent.BackColor=[Drawing.Color]::FromArgb(177,92,255); $panel.Controls.Add($accent)
    $t=New-Object Windows.Forms.Label; $t.Location=New-Object Drawing.Point(43,42); $t.Size=New-Object Drawing.Size(590,52)
    $t.Font=New-Object Drawing.Font('Segoe UI Semibold',22); $t.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $d=New-Object Windows.Forms.Label; $d.Location=New-Object Drawing.Point(46,108); $d.Size=New-Object Drawing.Size(570,46)
    $d.Font=New-Object Drawing.Font('Segoe UI',12); $d.ForeColor=[Drawing.Color]::FromArgb(218,210,229)
    $track=New-Object Windows.Forms.Panel; $track.Location=New-Object Drawing.Point(46,180); $track.Size=New-Object Drawing.Size(570,30)
    $track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $p=New-Object Windows.Forms.Panel; $p.Location=New-Object Drawing.Point(0,0); $p.Size=New-Object Drawing.Size(4,30)
    $p.BackColor=[Drawing.Color]::FromArgb(177,92,255); $track.Controls.Add($p)
    $sparkle=[char]0x2726
    $b=New-Object Windows.Forms.Label; $b.Text="$sparkle  COCO PACK  |  FABRIC 26.1.2"; $b.Location=New-Object Drawing.Point(46,244)
    $b.Size=New-Object Drawing.Size(620,25); $b.Font=New-Object Drawing.Font('Segoe UI Semibold',10); $b.ForeColor=[Drawing.Color]::FromArgb(177,92,255)
    $panel.Controls.AddRange(@($t,$d,$track,$b))
    $artPath=Join-Path $script:CocoEngineRoot 'assets\fullbody.png'
    $art=New-Object Windows.Forms.PictureBox; $art.Location=New-Object Drawing.Point(675,5); $art.Size=New-Object Drawing.Size(380,720)
    $art.SizeMode='Zoom'; $art.BackColor=[Drawing.Color]::Transparent
    if(Test-Path $artPath){$art.Image=[Drawing.Image]::FromFile($artPath)}
    $f.Controls.Add($panel); $f.Controls.Add($art); $art.BringToFront()
    $work=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $scale=[Math]::Min(1.0,[Math]::Min($work.Width/1080.0,$work.Height/740.0))
    if($scale-lt1.0){$f.Scale((New-Object Drawing.SizeF($scale,$scale)))}
    $f.Show(); $f.BringToFront(); $f.Activate(); [Windows.Forms.Application]::DoEvents()
    $script:CocoForm=$f; $script:CocoTitle=$t; $script:CocoDetail=$d; $script:CocoProgress=$p; $script:CocoTrack=$track
}

function Write-Status([string]$Message) {
    # Un EXE sin consola convierte Write-Host en cuadros de dialogo; el estado vive en la UI.
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Get-CandidateRoots {
    $roots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $persisted=Get-PersistedTarget
    if($persisted){
        Repair-InterruptedInstall $persisted
        if((Test-GameDirectory $persisted)-and(Test-Path (Join-Path $persisted 'config\coco-updater-state.json'))){
            return @((Resolve-Path -LiteralPath $persisted).Path)
        }
    }
    $known = @(
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

function Get-RunningGameDirectories {
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction Stop | ForEach-Object {
            $commandLine = $_.CommandLine
            if ($commandLine -match '(?i)--gameDir\s+"([^"]+)"') { [void]$paths.Add($matches[1]) }
            elseif ($commandLine -match '(?i)--gameDir\s+([^\s]+)') { [void]$paths.Add($matches[1]) }
        }
    } catch { }
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
            $evidence.Add('Minecraft abierto con este --gameDir (+1000000)')
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

function Download-VerifiedFile([string]$Url, [string]$Destination, [string]$ExpectedHash, [int64]$CompletedBytes = 0, [int64]$AllBytes = 0) {
    $partial = "$Destination.partial"
    for ($attempt=1; $attempt -le 4; $attempt++) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        try {
            $request=$null;$response=$null;$input=$null;$output=$null
            $request=[Net.HttpWebRequest]::Create($Url); $request.UserAgent='CocoMinecraftUpdater/1.0'
            $request.Timeout=30000; $request.ReadWriteTimeout=30000; $request.AutomaticDecompression=[Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
            $response=$request.GetResponse(); $total=[int64]$response.ContentLength
            $input=$response.GetResponseStream(); $output=[IO.File]::Create($partial)
            $buffer=New-Object byte[] (256KB); $received=[int64]0; $watch=[Diagnostics.Stopwatch]::StartNew()
            try {
                while (($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $output.Write($buffer,0,$read); $received += $read
                    $percent=if($AllBytes -gt 0){5+[int](70*($CompletedBytes+$received)/$AllBytes)}elseif($total -gt 0){5+[int](70*$received/$total)}else{25}
                    $speed=if($watch.Elapsed.TotalSeconds -gt 0){$received/$watch.Elapsed.TotalSeconds}else{0}
                    $eta=if($speed -gt 0 -and $total -gt 0){[TimeSpan]::FromSeconds(($total-$received)/$speed)}else{[TimeSpan]::Zero}
                    $detail='{0:N1} / {1:N1} MB  |  {2:N1} MB/s  |  faltan ~{3:mm\:ss}' -f ($received/1MB),($total/1MB),($speed/1MB),$eta
                    Set-CocoState 'Descargando mods' $detail $percent
                }
            } finally { if($output){$output.Dispose()}; if($input){$input.Dispose()}; if($response){$response.Dispose()} }
            if ((Get-Sha256 $partial) -ne $ExpectedHash.ToLowerInvariant()) { throw 'La descarga no coincide con el SHA-256 publicado.' }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        } catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if($attempt -eq 4){throw}
            Write-CocoLog "Descarga fallida (intento $attempt): $($_.Exception.Message)"
            Set-CocoState 'Reintentando descarga' "Intento $($attempt + 1) de 4..." ([Math]::Max(5,$script:CocoCurrentProgress))
            Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))
        }
    }
}

function Ensure-BootstrapUpdate($Manifest) {
    $canonical=$env:COCO_BOOTSTRAPPER_EXE
    if(-not$canonical-or-not$Manifest.bootstrap-or-not$Manifest.bootstrap.url-or-not$Manifest.bootstrap.sha256){return}
    try{
        if((Test-Path $canonical)-and(Get-Sha256 $canonical)-eq$Manifest.bootstrap.sha256.ToLowerInvariant()){return}
        $newExe=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\CocoUpdater.new.exe'
        if(-not((Test-Path $newExe)-and(Get-Sha256 $newExe)-eq$Manifest.bootstrap.sha256.ToLowerInvariant())){
            Download-VerifiedFile $Manifest.bootstrap.url $newExe $Manifest.bootstrap.sha256
        }
        $helper=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\Apply-CocoBootstrapUpdate-V2.ps1'
        $helperText=@'
param([int64]$WaitPid,[string]$Source,[string]$Destination,[string]$ExpectedHash,[string]$LogPath)
Wait-Process -Id $WaitPid -ErrorAction SilentlyContinue
for($i=0;$i-lt40;$i++){
    try{
        if((Test-Path $Destination)-and(Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant()-eq$ExpectedHash){Add-Content $LogPath "Bootstrap actualizado correctamente.";exit 0}
        Move-Item -LiteralPath $Source -Destination $Destination -Force
    }
    catch{Start-Sleep -Milliseconds 250}
}
Add-Content $LogPath "No se pudo reemplazar el bootstrap despues de 40 intentos."
exit 1
'@
        [IO.File]::WriteAllText($helper,$helperText,(New-Object Text.UTF8Encoding($true)))
        $quotedHelper='"'+($helper-replace'"','\"')+'"'
        $quotedSource='"'+($newExe-replace'"','\"')+'"'
        $quotedDestination='"'+($canonical-replace'"','\"')+'"'
        $quotedLog='"'+($script:CocoLogPath-replace'"','\"')+'"'
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedHelper,'-WaitPid',$PID,'-Source',$quotedSource,'-Destination',$quotedDestination,'-ExpectedHash',$Manifest.bootstrap.sha256,'-LogPath',$quotedLog)
        Write-CocoLog 'Se programo la reparacion/actualizacion diferida del bootstrap.'
    }catch{Write-CocoLog "No se pudo programar la actualizacion del bootstrap: $($_.Exception.Message)"}
}

function Test-MinecraftRunning([string]$Root) {
    if ($MinecraftPid -gt 0) { return [bool](Get-Process -Id $MinecraftPid -ErrorAction SilentlyContinue) }
    $running = Get-RunningGameDirectories
    return [bool]($running | Where-Object { [string]::Equals($_.TrimEnd('\'), $Root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) })
}

function Request-ClientMinecraftClose([string]$Root) {
    $requested=$false
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

function Wait-ForMinecraftExit([string]$Root) {
    while ($true) {
        if (-not (Test-MinecraftRunning $Root)) { return }
        Set-CocoState 'Preparando actualizacion' 'Esperando a que Minecraft termine de cerrarse...' 3
        Start-Sleep -Seconds 5
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
    return $stage
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

    $markerPath = Join-Path $Root $Manifest.detector.markerPath
    New-Item -ItemType Directory -Path (Split-Path $markerPath -Parent) -Force | Out-Null
    [pscustomobject]@{
        packId = $Manifest.packId
        version = $Manifest.version
        role = $Package.role
        installedAt = (Get-Date).ToString('o')
        target = $Root
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
    Set-CocoState 'Coco Pack actualizado' 'Ya puedes volver a abrir Minecraft' 100
    Start-Sleep -Seconds 5
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
        if ($actual.Count -ne @($package.mods).Count) { return $false }
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
    Set-CocoState 'Coco Pack actualizado' 'Ya puedes volver a abrir Minecraft' 100
    Start-Sleep -Seconds 5
}

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\CocoMinecraftUpdater')
    if (-not $mutex.WaitOne(0)) { exit 0 }
    $engineParent=Split-Path $script:CocoEngineRoot -Parent
    if((Split-Path $engineParent -Leaf)-eq'engine'){
        Get-ChildItem -LiteralPath $engineParent -Directory -ErrorAction SilentlyContinue |
            Where-Object FullName -ne $script:CocoEngineRoot | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $cacheRoot=Split-Path $engineParent -Parent
        Get-ChildItem -LiteralPath $cacheRoot -File -Filter 'engine-*.zip' -ErrorAction SilentlyContinue |
            Where-Object Name -ne "engine-$((Split-Path $script:CocoEngineRoot -Leaf)).zip" | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "No existe el manifiesto: $ManifestPath" }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.packId -or -not $manifest.version -or -not $manifest.detector) { throw 'Manifiesto incompleto.' }
    Ensure-BootstrapUpdate $manifest
    if($Preview){Show-CocoPreview;exit 0}

    if (-not $Silent) { Show-CocoWindow }
    Set-CocoState 'Buscando Minecraft' 'Identificando automaticamente la instalacion correcta...' 6
    if($GameDir){Repair-InterruptedInstall $GameDir}
    $runningDirs = Get-RunningGameDirectories
    if ($GameDir -and (Test-GameDirectory $GameDir)) {
        $candidates = @(Get-CandidateScore (Resolve-Path -LiteralPath $GameDir).Path $manifest $runningDirs)
    } else {
        $candidates = @(Get-CandidateRoots | ForEach-Object { Get-CandidateScore $_ $manifest $runningDirs })
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
    if (Test-CurrentVersion $selected.Root $manifest $role) {
        Set-CocoState 'Coco Pack actualizado' "Version $($manifest.version) | Todo listo" 100 $false
        exit 0
    }
    if (-not $script:CocoForm) { Show-CocoWindow }
    if ((Test-MinecraftRunning $selected.Root) -and $role -eq 'client' -and $MinecraftPid -gt 0) {
        Set-CocoState 'Actualizacion encontrada' 'Cerrando Minecraft de forma segura...' 2 $true 'closeMinecraft'
    } elseif ((Test-MinecraftRunning $selected.Root) -and $role -eq 'client') {
        Set-CocoState 'Primera instalacion' 'Cerrando Minecraft de forma segura...' 2
        if(-not(Request-ClientMinecraftClose $selected.Root)){
            Set-CocoState 'Primera instalacion' 'Cierra Minecraft una vez para instalar Session Bridge' 2
        }
    } elseif (Test-MinecraftRunning $selected.Root) {
        Set-CocoState 'Actualizacion encontrada' 'Eres el host: cierra Minecraft cuando termine la sesion LAN' 2
    }
    Wait-ForMinecraftExit $selected.Root
    $stage = Stage-Package $package $manifest $selected.Root
    Install-StagedPackage $selected.Root $stage $package $manifest
    Write-CocoLog 'Actualizacion completada correctamente.'
    Write-Status 'Actualizacion terminada.'
    exit 0
} catch {
    Write-CocoLog ("ERROR: " + ($_ | Out-String))
    if (-not $script:CocoForm) { Show-CocoWindow }
    $friendly=$_.Exception.Message
    if($friendly -match '(?i)access.*denied|acceso.*denegado|unauthorized'){$friendly='Windows bloqueo el acceso a la carpeta de Minecraft. Revisa permisos o el antivirus.'}
    elseif($friendly -match '(?i)conectar|connection|nombre remoto|timed out'){$friendly='No pudimos completar la descarga. Revisa internet y vuelve a intentarlo.'}
    elseif($friendly.Length-gt150){$friendly=$friendly.Substring(0,147)+'...'}
    Set-CocoState 'No se pudo actualizar' $friendly 0
    Start-Sleep -Seconds 10
    exit 1
} finally {
    if ($mutex) { $mutex.ReleaseMutex() | Out-Null; $mutex.Dispose() }
}
