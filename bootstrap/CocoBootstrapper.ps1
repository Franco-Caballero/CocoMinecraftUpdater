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

function Show-CocoSplash([string]$Status='Preparando el actualizador...') {
    if($Silent -and -not $Preview){return}
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $key=[Drawing.Color]::FromArgb(1,2,3)
    $form=New-Object Windows.Forms.Form;$form.Text='Coco Minecraft Updater';$form.Size=New-Object Drawing.Size(1080,740)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='None';$form.BackColor=$key;$form.TransparencyKey=$key
    $form.AutoScaleMode='None';$form.ForeColor=[Drawing.Color]::White;$form.TopMost=$true
    $form.Add_FormClosing({param($sender,$eventArgs) if(-not$script:CocoAllowClose){$eventArgs.Cancel=$true}})
    try{$embeddedIcon=[Drawing.Icon]::ExtractAssociatedIcon([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName);if($embeddedIcon){$form.Icon=$embeddedIcon}}catch{}
    $panel=New-Object Windows.Forms.Panel;$panel.Location=New-Object Drawing.Point(25,190);$panel.Size=New-Object Drawing.Size(780,350)
    $panel.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $accent=New-Object Windows.Forms.Panel;$accent.Location=New-Object Drawing.Point(0,0);$accent.Size=New-Object Drawing.Size(9,350)
    $accent.BackColor=[Drawing.Color]::FromArgb(177,92,255);$panel.Controls.Add($accent)
    $sparkle=[char]0x2726
    $title=New-Object Windows.Forms.Label;$title.Text='Preparando Coco Updater';$title.Location=New-Object Drawing.Point(43,42)
    $title.Size=New-Object Drawing.Size(590,52);$title.Font=New-Object Drawing.Font('Segoe UI Semibold',22)
    $title.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $detail=New-Object Windows.Forms.Label;$detail.Text=$Status;$detail.Location=New-Object Drawing.Point(46,108)
    $detail.Size=New-Object Drawing.Size(570,46);$detail.Font=New-Object Drawing.Font('Segoe UI',12);$detail.ForeColor=[Drawing.Color]::FromArgb(218,210,229)
    $track=New-Object Windows.Forms.Panel;$track.Location=New-Object Drawing.Point(46,180);$track.Size=New-Object Drawing.Size(570,30)
    $track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $fill=New-Object Windows.Forms.Panel;$fill.Size=New-Object Drawing.Size(12,30);$fill.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $brand=New-Object Windows.Forms.Label;$brand.Text="$sparkle  COCO PACK  |  FABRIC 26.1.2";$brand.Location=New-Object Drawing.Point(46,244)
    $brand.Size=New-Object Drawing.Size(620,25);$brand.Font=New-Object Drawing.Font('Segoe UI Semibold',10);$brand.ForeColor=[Drawing.Color]::FromArgb(177,92,255)
    $track.Controls.Add($fill);$panel.Controls.AddRange(@($title,$detail,$track,$brand))
    $art=New-Object Windows.Forms.PictureBox;$art.Location=New-Object Drawing.Point(675,5);$art.Size=New-Object Drawing.Size(380,720)
    $art.SizeMode='Zoom';$art.BackColor=[Drawing.Color]::Transparent
    try{
        if($script:EmbeddedFullbodyBase64.Length -gt 1000){
            $bytes=[Convert]::FromBase64String($script:EmbeddedFullbodyBase64);$memory=New-Object IO.MemoryStream(,$bytes)
            $art.Image=[Drawing.Image]::FromStream($memory);$script:EmbeddedImageStream=$memory
        }elseif(Test-Path (Join-Path $PSScriptRoot '..\fullbody.png')){$art.Image=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot '..\fullbody.png'))}
    }catch{}
    $form.Controls.Add($panel);$form.Controls.Add($art);$art.BringToFront()
    $work=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $scale=[Math]::Min(1.0,[Math]::Min($work.Width/1080.0,$work.Height/740.0))
    if($scale-lt1.0){$form.Scale((New-Object Drawing.SizeF($scale,$scale)))}
    $form.Show();$form.BringToFront();$form.Activate();[Windows.Forms.Application]::DoEvents()
    $script:Splash=$form;$script:SplashDetail=$detail;$script:SplashFill=$fill;$script:SplashTrack=$track
    $script:SplashTitle=$title
    $global:CocoSharedUi=@{Form=$form;Panel=$panel;Accent=$accent;Title=$title;Detail=$detail;Progress=$fill;Track=$track;Brand=$brand;Started=[Diagnostics.Stopwatch]::StartNew();BaseProgress=12}
}
function Set-CocoSplash([string]$Status,[int]$Progress){
    if(-not$script:Splash){return};$script:SplashTitle.Text='Preparando Coco Updater';$script:SplashDetail.Text=$Status;$script:SplashFill.Width=[Math]::Max(4,[int]($script:SplashTrack.ClientSize.Width*$Progress/100))
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
        $report=@"
Coco Updater diagnostic
Timestamp: $((Get-Date).ToString('o'))
Bootstrap process: $processPath
PID: $PID
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

Engine files:
$engineFiles
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

function Download-VerifiedFile([string]$Url, [string]$Destination, [string]$ExpectedHash) {
    $partial = "$Destination.partial"
    for($attempt=1;$attempt -le 4;$attempt++){
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        try{
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 30
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
do{
    try{
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
    return (Test-Path -LiteralPath (Join-Path $Destination 'CocoUpdater.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetwork.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetworkElevated.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetworkAuthorizer.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'assets\fullbody.png')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'assets\reynaico.ico'))
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
    $manifest = Get-Content -LiteralPath $manifestCache -Raw | ConvertFrom-Json
}

if (-not $manifest.engine -or -not $manifest.engine.version -or -not $manifest.engine.url -or -not $manifest.engine.sha256) {
    throw 'El manifiesto remoto no contiene un motor valido.'
}

$engineRoot = Join-Path $cacheRoot (Join-Path 'engine' $manifest.engine.version)
$entryPoint = Join-Path $engineRoot 'CocoUpdater.ps1'
if (-not (Test-Path -LiteralPath $entryPoint)) {
    $engineZip = Join-Path $cacheRoot "engine-$($manifest.engine.version).zip"
    Set-CocoSplash 'Preparando la interfaz visual...' 9
    Download-VerifiedFile $manifest.engine.url $engineZip $manifest.engine.sha256
    $temporaryRoot = "$engineRoot.new"
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Expand-CocoEngineArchive $engineZip $temporaryRoot
    New-Item -ItemType Directory -Path (Split-Path $engineRoot -Parent) -Force | Out-Null
    Move-Item -LiteralPath $temporaryRoot -Destination $engineRoot -Force
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
            Set-CocoSplash 'Actualizando Coco Updater...' 11
            $newExe=Join-Path $cacheRoot "CocoUpdater.$PID.new.exe"
            Download-VerifiedFile $manifest.bootstrap.url $newExe $manifest.bootstrap.sha256
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
Set-CocoSplash 'Analizando la instalacion de Minecraft...' 12
$env:COCO_ENGINE_ROOT=$engineRoot
$engineSource=[IO.File]::ReadAllText($entryPoint,[Text.Encoding]::UTF8)
$engineBlock=[ScriptBlock]::Create($engineSource)
& $engineBlock @engineParameters
