[CmdletBinding()]
param(
    [string]$ChannelPath,
    [string]$GameDir,
    [int64]$MinecraftPid = 0,
    [string]$SessionStatePath,
    [string]$RunningPackVersion,
    [switch]$Preview,
    [switch]$NetworkOnly,
    [switch]$ShowOnUpdate,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Splash = $null
$script:EmbeddedFullbodyBase64 = '__FULLBODY_BASE64__'
$script:CocoRunId=if($env:COCO_RUN_ID-match'^[a-fA-F0-9]{12,32}$'){$env:COCO_RUN_ID.ToLowerInvariant()}else{[guid]::NewGuid().ToString('N')}
$env:COCO_RUN_ID=$script:CocoRunId
$script:CocoBootstrapStarted=[Diagnostics.Stopwatch]::StartNew()
$script:CocoBootstrapLogRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\logs'
New-Item -ItemType Directory -Path $script:CocoBootstrapLogRoot -Force -ErrorAction SilentlyContinue|Out-Null
$script:CocoBootstrapLogPath=Join-Path $script:CocoBootstrapLogRoot "bootstrap-run-$($script:CocoRunId).log"
function Write-CocoBootstrapEvent([string]$Status,[int]$Progress,[string]$Kind='STATE'){
    try{Add-Content -LiteralPath $script:CocoBootstrapLogPath -Value ("{0:o} {1} {2}% elapsedMs={3} {4}"-f(Get-Date),$Kind,$Progress,$script:CocoBootstrapStarted.ElapsedMilliseconds,$Status) -Encoding UTF8}catch{}
}
function Set-CocoBootstrapLabelText($Label,[string]$Text,[single]$MaximumSize,[single]$MinimumSize){
    $Label.Text=$Text
    $candidate=$MaximumSize
    while($candidate-gt$MinimumSize){
        $font=New-Object Drawing.Font($Label.Font.FontFamily,$candidate,$Label.Font.Style)
        $measured=[Windows.Forms.TextRenderer]::MeasureText($Text,$font,$Label.ClientSize,[Windows.Forms.TextFormatFlags]::WordBreak)
        if($measured.Height-le$Label.ClientSize.Height-and$measured.Width-le$Label.ClientSize.Width){
            $Label.Font=$font
            return
        }
        $font.Dispose();$candidate-=0.5
    }
    $Label.Font=New-Object Drawing.Font($Label.Font.FontFamily,$MinimumSize,$Label.Font.Style)
}

function Show-CocoSplash([string]$Status='Preparando el actualizador...') {
    Write-CocoBootstrapEvent $Status 1
    if($Silent -and -not$Preview-and$env:COCO_SHOW_ON_UPDATE-ne'1'){return}
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $key=[Drawing.Color]::FromArgb(1,2,3)
    $form=New-Object Windows.Forms.Form;$form.Text='Coco Minecraft Updater';$form.Size=New-Object Drawing.Size(1080,740)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='None';$form.BackColor=$key;$form.TransparencyKey=$key
    $form.AutoScaleMode='None';$form.ForeColor=[Drawing.Color]::White;$form.TopMost=$false
    $form.Add_FormClosing({param($sender,$eventArgs) if(-not$script:CocoAllowClose){$eventArgs.Cancel=$true}})
    try{$embeddedIcon=[Drawing.Icon]::ExtractAssociatedIcon([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);if($embeddedIcon){$form.Icon=$embeddedIcon}}catch{}
    $panel=New-Object Windows.Forms.Panel;$panel.Location=New-Object Drawing.Point(25,190);$panel.Size=New-Object Drawing.Size(640,460)
    $panel.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $accent=New-Object Windows.Forms.Panel;$accent.Location=New-Object Drawing.Point(0,0);$accent.Size=New-Object Drawing.Size(9,460)
    $accent.BackColor=[Drawing.Color]::FromArgb(177,92,255);$panel.Controls.Add($accent)
    $sparkle=[char]0x2726
    $title=New-Object Windows.Forms.Label;$title.Text='ETAPA 1/10 · INICIANDO COCO';$title.Location=New-Object Drawing.Point(43,42)
    $title.Location=New-Object Drawing.Point(43,30);$title.Size=New-Object Drawing.Size(570,72);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',22)
    $title.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $detail=New-Object Windows.Forms.Label;$detail.Text=$Status;$detail.Location=New-Object Drawing.Point(46,106)
    $detail.Size=New-Object Drawing.Size(570,76);$detail.Font=New-Object Drawing.Font('Segoe UI',12);$detail.ForeColor=[Drawing.Color]::FromArgb(218,210,229)
    $track=New-Object Windows.Forms.Panel;$track.Location=New-Object Drawing.Point(46,190);$track.Size=New-Object Drawing.Size(570,30)
    $track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $fill=New-Object Windows.Forms.Panel;$fill.Size=New-Object Drawing.Size(12,30);$fill.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $brand=New-Object Windows.Forms.Label;$brand.Text="$sparkle  COCO PACK  |  FABRIC 26.1.2";$brand.Location=New-Object Drawing.Point(46,244)
    $brand.Size=New-Object Drawing.Size(570,25);$brand.Font=New-Object Drawing.Font('Segoe UI Semibold',10);$brand.ForeColor=[Drawing.Color]::FromArgb(177,92,255)
    $track.Controls.Add($fill);$panel.Controls.AddRange(@($title,$detail,$track,$brand))
    $art=New-Object Windows.Forms.PictureBox;$art.Location=New-Object Drawing.Point(675,5);$art.Size=New-Object Drawing.Size(380,720)
    $art.SizeMode='Zoom';$art.BackColor=[Drawing.Color]::Transparent
    try{
        if($script:EmbeddedFullbodyBase64.Length -gt 1000){
            $bytes=[Convert]::FromBase64String($script:EmbeddedFullbodyBase64);$memory=New-Object IO.MemoryStream(,$bytes)
            $sourceImage=$null
            try{$sourceImage=[Drawing.Image]::FromStream($memory,$true,$true);$art.Image=[Drawing.Bitmap]::new($sourceImage)}
            finally{if($sourceImage){$sourceImage.Dispose()};$memory.Dispose()}
        }elseif(Test-Path (Join-Path $PSScriptRoot '..\fullbody.png')){
            $sourceImage=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot '..\fullbody.png'))
            try{$art.Image=[Drawing.Bitmap]::new($sourceImage)}finally{$sourceImage.Dispose()}
        }
    }catch{}
    $form.Controls.Add($panel);$form.Controls.Add($art);$art.BringToFront()
    $work=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $scale=[Math]::Min(1.0,[Math]::Min($work.Width/1080.0,$work.Height/740.0))
    if($scale-lt1.0){$form.Scale((New-Object Drawing.SizeF($scale,$scale)))}
    $form.Show();$form.BringToFront();$form.Activate();[Windows.Forms.Application]::DoEvents()
    $script:Splash=$form;$script:SplashDetail=$detail;$script:SplashFill=$fill;$script:SplashTrack=$track
    $script:SplashTitle=$title
    Set-CocoBootstrapLabelText $title $title.Text 22 13
    Set-CocoBootstrapLabelText $detail $detail.Text 12 9
    $global:CocoSharedUi=@{Form=$form;Panel=$panel;Accent=$accent;Title=$title;Detail=$detail;Progress=$fill;Track=$track;Brand=$brand;Started=[Diagnostics.Stopwatch]::StartNew();BaseProgress=12}
}
function Set-CocoSplash([string]$Status,[int]$Progress){
    Write-CocoBootstrapEvent $Status $Progress
    if(-not$script:Splash){return}
    $stage=if($Progress-lt7){'ETAPA 1/10 · BUSCANDO ACTUALIZACIONES'}elseif($Progress-lt12){'ETAPA 2/10 · ACTUALIZANDO COMPONENTES'}else{'ETAPA 2/10 · ABRIENDO EL MOTOR'}
    Set-CocoBootstrapLabelText $script:SplashTitle $stage 22 13
    Set-CocoBootstrapLabelText $script:SplashDetail "$Status`r`nEjecucion: $($script:CocoRunId.Substring(0,8))" 12 9
    $script:SplashFill.Width=[Math]::Max(4,[int]($script:SplashTrack.ClientSize.Width*$Progress/100))
    $script:Splash.Refresh();[Windows.Forms.Application]::DoEvents()
}
function Close-CocoSplash {if($script:Splash){$script:CocoAllowClose=$true;$script:Splash.Close();$script:Splash.Dispose();$script:Splash=$null}}

function Write-CocoBootstrapDiagnostic([Management.Automation.ErrorRecord]$Record){
    try{
        $logRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\logs'
        New-Item -ItemType Directory -Path $logRoot -Force|Out-Null
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        $logPath=Join-Path $logRoot "bootstrap-$stamp-$PID-error.txt"
        $policies=try{Get-ExecutionPolicy -List|Format-Table -AutoSize|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $engineFiles=try{if($engineRoot-and(Test-Path $engineRoot)){Get-ChildItem $engineRoot -Recurse -Force|Select-Object FullName,Length,LastWriteTime|Format-Table -AutoSize|Out-String}else{'Engine root not created.'}}catch{"Unavailable: $($_.Exception.Message)"}
        $processPath=try{[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName}catch{'Unknown'}
        $manifestVersion=try{$manifest.version}catch{'Unknown'}
        $bootstrapLog=try{if(Test-Path -LiteralPath $script:CocoBootstrapLogPath){(Get-Content -LiteralPath $script:CocoBootstrapLogPath -Tail 250)-join"`r`n"}else{'Bootstrap log not created.'}}catch{"Unavailable: $($_.Exception.Message)"}
        $disk=try{$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($env:LOCALAPPDATA)));$drive|Select-Object Name,@{n='FreeGB';e={[math]::Round($_.AvailableFreeSpace/1GB,2)}},@{n='TotalGB';e={[math]::Round($_.TotalSize/1GB,2)}}|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $serviceState=try{Get-Service -Name 'ZeroTierOneService' -ErrorAction Stop|Select-Object Name,Status,StartType|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $relevantProcesses=try{Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{$_.Name-match'(?i)coco|portablemc|java|powershell'}|Select-Object ProcessId,ParentProcessId,Name,CreationDate,CommandLine|Format-List|Out-String}catch{"Unavailable: $($_.Exception.Message)"}
        $report=@"
COCO UPDATER - BOOTSTRAP DIAGNOSTIC
===================================
Run ID: $($script:CocoRunId)
Timestamp: $((Get-Date).ToString('o'))
Elapsed: $($script:CocoBootstrapStarted.Elapsed)
Bootstrap process: $processPath
PID: $PID
Channel path: $ChannelPath
Manifest version: $manifestVersion
Engine root: $engineRoot
Extraction method: $script:CocoExtractionMethod
Windows: $([Environment]::OSVersion.VersionString)
64-bit OS/process: $([Environment]::Is64BitOperatingSystem) / $([Environment]::Is64BitProcess)
PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))
CLR: $([Environment]::Version)
Language mode: $($ExecutionContext.SessionState.LanguageMode)

Execution policies:
$policies
Exception.ToString():
$($Record.Exception.ToString())

ErrorRecord:
$($Record|Format-List * -Force|Out-String)

Script stack trace:
$($Record.ScriptStackTrace)

Invocation:
$($Record.InvocationInfo.PositionMessage)

Bootstrap timeline/log:
$bootstrapLog

Disk:
$disk

ZeroTier service:
$serviceState

Relevant processes:
$relevantProcesses

Engine files:
$engineFiles

Privacy: this report does not copy Microsoft tokens, passwords, cookies or PortableMC account database contents.
"@
        [IO.File]::WriteAllText($logPath,$report,(New-Object Text.UTF8Encoding($true)))
        $desktop=[Environment]::GetFolderPath('Desktop')
        if($desktop-and(Test-Path $desktop)){
            $desktopPath=Join-Path $desktop "CocoUpdater-error-$stamp.txt"
            [IO.File]::WriteAllText($desktopPath,$report,(New-Object Text.UTF8Encoding($true)))
            $logPath=$desktopPath
        }
        Get-ChildItem $logRoot -File -Filter 'bootstrap-*-error.txt' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -Skip 20|Remove-Item -Force -ErrorAction SilentlyContinue
        return $logPath
    }catch{return $null}
}

Show-CocoSplash

trap {
    $diagnosticPath=Write-CocoBootstrapDiagnostic $_
    $friendly=$_.Exception.Message
    if($_.Exception -is [Net.WebException] -or $friendly -match '(?i)conectar|connection|nombre remoto|timed out'){
        $friendly='No pudimos conectar con GitHub tras 4 intentos. Revisa internet y vuelve a abrir este EXE.'
    }elseif($friendly.Length-gt150){$friendly=$friendly.Substring(0,147)+'...'}
    if(-not $script:Splash){Show-CocoSplash}
    if($script:Splash){
        $script:SplashTitle.Text='No se pudo iniciar Coco Updater'
        $failureColor=[Drawing.Color]::FromArgb(255,92,112)
        $script:SplashTitle.ForeColor=$failureColor;$script:SplashFill.BackColor=$failureColor
        $diagnosticName=if($diagnosticPath){[IO.Path]::GetFileName($diagnosticPath)}else{'No disponible'}
        $script:SplashDetail.Text="$friendly`nEnvia por Discord: $diagnosticName"
        $script:SplashFill.Width=12
        $script:Splash.Refresh();[Windows.Forms.Application]::DoEvents();Start-Sleep -Seconds 8
    }
    exit 1
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-VerifiedFile([string]$Url,[string]$Destination,[string]$ExpectedHash,[string]$Label='componente Coco',[int]$ProgressStart=8,[int]$ProgressEnd=11) {
    $partial = "$Destination.partial"
    for($attempt=1;$attempt -le 4;$attempt++){
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        try{
            $request=$null;$response=$null;$input=$null;$output=$null
            $request=[Net.HttpWebRequest]::Create($Url);$request.UserAgent='CocoMinecraftUpdater/Bootstrap';$request.Timeout=30000;$request.ReadWriteTimeout=30000
            $response=$request.GetResponse();$total=[int64]$response.ContentLength;$input=$response.GetResponseStream();$output=[IO.File]::Create($partial)
            $received=[int64]0;$watch=[Diagnostics.Stopwatch]::StartNew();$lastUpdate=[DateTime]::MinValue;$buffer=New-Object byte[] (256KB)
            try{
                while(($read=$input.Read($buffer,0,$buffer.Length))-gt0){
                    $output.Write($buffer,0,$read);$received+=$read
                    if(((Get-Date)-$lastUpdate).TotalMilliseconds-ge250){
                        $lastUpdate=Get-Date;$speed=if($watch.Elapsed.TotalSeconds-gt0){$received/$watch.Elapsed.TotalSeconds}else{0}
                        $percent=if($total-gt0){$ProgressStart+[int](($ProgressEnd-$ProgressStart)*$received/$total)}else{$ProgressStart}
                        Set-CocoSplash ("{0}: {1:N1}/{2:N1} MB | {3:N1} MB/s"-f$Label,($received/1MB),($total/1MB),($speed/1MB)) ([Math]::Min($ProgressEnd,$percent))
                    }
                }
            }finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()}}
            if ((Get-Sha256 $partial) -ne $ExpectedHash.ToLowerInvariant()) { throw 'La descarga no coincide con el hash SHA-256 publicado.' }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        }catch{
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            if($attempt -eq 4){throw}
            Set-CocoSplash "Reintentando conexion ($($attempt + 1)/4)..." 5
            Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))
        }
    }
}

function Download-TextFile([string]$Url,[string]$Destination){
    for($attempt=1;$attempt -le 4;$attempt++){
        try{Invoke-WebRequest -Uri $Url -OutFile "$Destination.new" -UseBasicParsing -TimeoutSec 30;Move-Item "$Destination.new" $Destination -Force;return}
        catch{Remove-Item "$Destination.new" -Force -ErrorAction SilentlyContinue;if($attempt -eq 4){throw};Set-CocoSplash "Reintentando conexion ($($attempt + 1)/4)..." 5;Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))}
    }
}

function Start-CocoBootstrapReplacement([string]$Source,[string]$Destination,[string]$ExpectedHash){
    # An automatic NetworkOnly check can still have the canonical EXE mapped
    # while a manually launched copy is updating it. Replacing a mapped EXE is
    # secondary to running the verified engine, so always defer the operation
    # and never turn a sharing violation into a failed pack update.
    $helper=Join-Path (Split-Path $Destination -Parent) "Apply-CocoBootstrapUpdate-$PID.ps1"
    $logPath=Join-Path (Split-Path $Destination -Parent) 'logs\bootstrap-update.log'
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
            exit 0
        }
        if(Test-Path -LiteralPath $Destination){
            $backup="$Destination.coco-old.$PID"
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            [IO.File]::Replace($Source,$Destination,$backup,$true)
        }else{
            [IO.File]::Move($Source,$Destination)
        }
        if((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()-eq$ExpectedHash){
            if($backup){Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}
            exit 0
        }
    }catch{$lastError=$_.Exception.Message}
    Start-Sleep -Milliseconds 500
}while([DateTime]::UtcNow-lt$deadline)
New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force -ErrorAction SilentlyContinue|Out-Null
Add-Content -LiteralPath $LogPath "No se pudo aplicar el bootstrap pendiente antes del limite de 12 horas. Ultimo error: $lastError" -ErrorAction SilentlyContinue
exit 1
'@
    [IO.File]::WriteAllText($helper,$helperText,(New-Object Text.UTF8Encoding($true)))
    $quotedHelper='"'+($helper-replace'"','\"')+'"'
    $quotedSource='"'+($Source-replace'"','\"')+'"'
    $quotedDestination='"'+($Destination-replace'"','\"')+'"'
    $quotedLog='"'+($logPath-replace'"','\"')+'"'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedHelper,'-WaitPid',$PID,'-Source',$quotedSource,'-Destination',$quotedDestination,'-ExpectedHash',$ExpectedHash,'-LogPath',$quotedLog)
    $env:COCO_BOOTSTRAP_UPDATE_PENDING='1'
}

function Test-CocoEngineExtraction([string]$Destination){
    $baseComplete=(Test-Path -LiteralPath (Join-Path $Destination 'CocoUpdater.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoLauncher.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoSessionService.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetwork.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetworkElevated.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetworkAuthorizer.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'launcher\catalog.json')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'assets\fullbody.png')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'assets\reynaico.ico'))
    if(-not$baseComplete){return $false}
    try{
        $catalog=Get-Content -LiteralPath (Join-Path $Destination 'launcher\catalog.json') -Raw|ConvertFrom-Json
        $managed=@($catalog.experiences|Where-Object managementMode -eq 'managed')
        if(-not$managed.Count){return $false}
        foreach($experience in $managed){
            if([string]$experience.launch.workflow -match 'standalone'-or[string]$experience.runtime.type-eq'standalone'-or(-not[string]$experience.pack.lockPath)){ continue }
            $lockPaths=@([string]$experience.pack.lockPath)
            if($experience.worldTemplate){$lockPaths+=([string]$experience.worldTemplate.lockPath)}
            foreach($declaredPath in $lockPaths){
                $relative=$declaredPath-replace'\\','/'
                if($relative-notmatch'^launcher/experiences/[a-z0-9][a-z0-9.-]{1,95}\.lock\.json$'){return $false}
                if(-not(Test-Path -LiteralPath (Join-Path $Destination ($relative-replace'/','\')) -PathType Leaf)){return $false}
            }
        }
        return $true
    }catch{return $false}
}

function Reset-CocoExtractionDirectory([string]$Destination){
    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

function Expand-CocoEngineArchive([string]$Archive,[string]$Destination){
    $failures=[Collections.Generic.List[string]]::new()
    Reset-CocoExtractionDirectory $Destination

    # Primary path: built into .NET Framework and independent of PowerShell modules.
    try{
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
        if(Test-CocoEngineExtraction $Destination){$script:CocoExtractionMethod='.NET ZipFile';return}
        throw 'La extraccion .NET quedo incompleta.'
    }catch{$failures.Add(".NET: $($_.Exception.Message)")}

    # Windows 10 1803+ normally includes bsdtar even when PowerShell modules are damaged.
    Reset-CocoExtractionDirectory $Destination
    try{
        $tar=Get-Command tar.exe -ErrorAction Stop
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$tar.Source
        $info.Arguments='-xf "'+($Archive-replace'"','\"')+'" -C "'+($Destination-replace'"','\"')+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        [void]$process.Start();$process.WaitForExit();$tarExit=$process.ExitCode;$process.Dispose()
        if($tarExit-eq0-and(Test-CocoEngineExtraction $Destination)){$script:CocoExtractionMethod='Windows tar.exe';return}
        throw "tar.exe termino con codigo $tarExit."
    }catch{$failures.Add("tar: $($_.Exception.Message)")}

    # Keep the normal cmdlet as a tertiary option for machines where it works.
    Reset-CocoExtractionDirectory $Destination
    try{
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force -ErrorAction Stop
        if(Test-CocoEngineExtraction $Destination){$script:CocoExtractionMethod='PowerShell Expand-Archive';return}
        throw 'Expand-Archive dejo archivos incompletos.'
    }catch{$failures.Add("PowerShell: $($_.Exception.Message)")}

    # Last resort: the ZIP namespace used by Windows Explorer (asynchronous COM API).
    Reset-CocoExtractionDirectory $Destination
    $shell=$null;$zipNamespace=$null;$destinationNamespace=$null
    try{
        $shell=New-Object -ComObject Shell.Application
        $zipNamespace=$shell.NameSpace($Archive);$destinationNamespace=$shell.NameSpace($Destination)
        if(-not$zipNamespace-or-not$destinationNamespace){throw 'El Explorador no pudo abrir el ZIP.'}
        $destinationNamespace.CopyHere($zipNamespace.Items(),0x414)
        $deadline=(Get-Date).AddSeconds(45)
        while((Get-Date)-lt$deadline){
            if(Test-CocoEngineExtraction $Destination){$script:CocoExtractionMethod='Windows Explorer ZIP';return}
            Start-Sleep -Milliseconds 250
        }
        throw 'El Explorador excedio el tiempo de extraccion.'
    }catch{$failures.Add("Explorer: $($_.Exception.Message)")}
    finally{
        foreach($item in @($destinationNamespace,$zipNamespace,$shell)){if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}}
    }
    throw "Windows no pudo descomprimir el motor de Coco. Metodos intentados: $($failures -join ' | ')"
}

if ([string]::IsNullOrWhiteSpace($ChannelPath)) {
    $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetExtension($processPath) -ieq '.exe') {
        $ChannelPath = Join-Path (Split-Path $processPath -Parent) 'CocoUpdater.channel.json'
    } else {
        $ChannelPath = Join-Path $PSScriptRoot '..\CocoUpdater.channel.json'
    }
}

$defaultManifestUrl = 'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json'
if (Test-Path -LiteralPath $ChannelPath) {
    $channel = Get-Content -LiteralPath $ChannelPath -Raw | ConvertFrom-Json
} else {
    $channel = [pscustomobject]@{ manifestUrl = $defaultManifestUrl; channel = 'stable' }
}
if ([string]::IsNullOrWhiteSpace($channel.manifestUrl) -or $channel.manifestUrl -like '*REEMPLAZAR_*') {
    throw "Configura manifestUrl en CocoUpdater.channel.json antes de distribuir el actualizador."
}

$cacheRoot = Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'
$manifestCache = Join-Path $cacheRoot 'latest.json'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

Set-CocoSplash 'Comprobando la version mas reciente...' 5
$manifest=$null
if($Silent-and$NetworkOnly-and(Test-Path -LiteralPath $manifestCache)){
    try{
        $cached=Get-Content -LiteralPath $manifestCache -Raw|ConvertFrom-Json
        $cachedEntry=Join-Path $cacheRoot (Join-Path (Join-Path 'engine' ([string]$cached.engine.version)) 'CocoUpdater.ps1')
        if($cached.engine.version-and$cached.engine.sha256-and(Test-Path -LiteralPath $cachedEntry)){$manifest=$cached}
    }catch{$manifest=$null}
}
if(-not$manifest){
    Download-TextFile $channel.manifestUrl $manifestCache
    Set-CocoSplash 'Manifiesto descargado; validando el canal y la version...' 7
    $manifest = Get-Content -LiteralPath $manifestCache -Raw | ConvertFrom-Json
}

if (-not $manifest.engine -or -not $manifest.engine.version -or -not $manifest.engine.url -or -not $manifest.engine.sha256) {
    throw 'El manifiesto remoto no contiene un motor valido.'
}

$engineRoot = Join-Path $cacheRoot (Join-Path 'engine' $manifest.engine.version)
$entryPoint = Join-Path $engineRoot 'CocoUpdater.ps1'
Set-CocoSplash ("Engine {0}: comprobando cache local verificado..."-f$manifest.engine.version) 8
if (-not (Test-Path -LiteralPath $entryPoint)) {
    $engineZip = Join-Path $cacheRoot "engine-$($manifest.engine.version).zip"
    Set-CocoSplash ("Descargando engine {0} y comprobando SHA-256..."-f$manifest.engine.version) 9
    Download-VerifiedFile $manifest.engine.url $engineZip $manifest.engine.sha256 "Descargando engine $($manifest.engine.version)" 9 10
    $temporaryRoot = "$engineRoot.new"
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Set-CocoSplash 'Extrayendo el engine en una carpeta temporal segura...' 10
    Expand-CocoEngineArchive $engineZip $temporaryRoot
    New-Item -ItemType Directory -Path (Split-Path $engineRoot -Parent) -Force | Out-Null
    if(Test-Path -LiteralPath $engineRoot){
        Remove-Item -LiteralPath $engineRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if(Test-Path -LiteralPath $engineRoot){
        Get-ChildItem -LiteralPath $temporaryRoot -Force | Copy-Item -Destination $engineRoot -Recurse -Force
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }else{
        Move-Item -LiteralPath $temporaryRoot -Destination $engineRoot -Force
    }
}

$processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if ([IO.Path]::GetExtension($processPath) -ieq '.exe') {
    $canonicalExe=Join-Path $cacheRoot 'CocoUpdater.exe'
    $canonicalChannel=Join-Path $cacheRoot 'CocoUpdater.channel.json'
    if(-not(Test-Path -LiteralPath $canonicalExe) -and -not[string]::Equals($processPath,$canonicalExe,[StringComparison]::OrdinalIgnoreCase)){
        Copy-Item -LiteralPath $processPath -Destination $canonicalExe -Force
    }
    if((Test-Path -LiteralPath $ChannelPath) -and -not[string]::Equals($ChannelPath,$canonicalChannel,[StringComparison]::OrdinalIgnoreCase)){Copy-Item -LiteralPath $ChannelPath -Destination $canonicalChannel -Force}
    elseif(-not(Test-Path -LiteralPath $canonicalChannel)){$channel|ConvertTo-Json|Set-Content -LiteralPath $canonicalChannel -Encoding UTF8}
    $env:COCO_BOOTSTRAPPER_EXE=$canonicalExe

    if($manifest.bootstrap -and $manifest.bootstrap.url -and $manifest.bootstrap.sha256){
        $canonicalMatches=(Test-Path -LiteralPath $canonicalExe) -and ((Get-Sha256 $canonicalExe) -eq $manifest.bootstrap.sha256.ToLowerInvariant())
        if(-not$canonicalMatches){
            Set-CocoSplash 'Actualizando el EXE canonico sin bloquear esta ejecucion...' 11
            $newExe=Join-Path $cacheRoot "CocoUpdater.$PID.new.exe"
            Download-VerifiedFile $manifest.bootstrap.url $newExe $manifest.bootstrap.sha256 'Actualizando CocoUpdater.exe' 11 12
            Start-CocoBootstrapReplacement $newExe $canonicalExe $manifest.bootstrap.sha256.ToLowerInvariant()
        }
    }
}

$engineParameters = @{ManifestPath=$manifestCache;ManifestUrl=$channel.manifestUrl}
if ($GameDir) { $engineParameters.GameDir=$GameDir }
if ($MinecraftPid -gt 0) { $engineParameters.MinecraftPid=$MinecraftPid }
if ($SessionStatePath) { $engineParameters.SessionStatePath=$SessionStatePath }
if ($RunningPackVersion) { $engineParameters.RunningPackVersion=$RunningPackVersion }
if ($Preview) { $engineParameters.Preview=$true }
if ($NetworkOnly) { $engineParameters.NetworkOnly=$true }
if ($ShowOnUpdate) { $engineParameters.ShowOnUpdate=$true }
if ($Silent) { $engineParameters.Silent=$true }
Set-CocoSplash 'Engine verificado; transfiriendo la ejecucion al launcher...' 12
$env:COCO_ENGINE_ROOT=$engineRoot
$engineSource=[IO.File]::ReadAllText($entryPoint,[Text.Encoding]::UTF8)
$engineBlock=[ScriptBlock]::Create($engineSource)
& $engineBlock @engineParameters
