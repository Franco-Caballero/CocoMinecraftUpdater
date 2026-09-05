if(-not([System.Management.Automation.PSTypeName]'CocoPopupGate').Type){
    $gateRoot=if($PSScriptRoot){$PSScriptRoot}elseif($script:CocoEngineRoot){$script:CocoEngineRoot}else{try{Split-Path -Parent $MyInvocation.MyCommand.Path}catch{}}
    $gateDll=if($gateRoot){Join-Path $gateRoot 'CocoPopupGate.dll'}else{Join-Path (Get-Location) 'engine\CocoPopupGate.dll'}
    if(-not(Test-Path -LiteralPath $gateDll)){
        $altDll=Join-Path (Get-Location) 'engine\CocoPopupGate.dll'
        if(Test-Path -LiteralPath $altDll){$gateDll=$altDll}
    }
    if(Test-Path -LiteralPath $gateDll){
        try{
            $dllBytes=[System.IO.File]::ReadAllBytes($gateDll)
            [void][System.Reflection.Assembly]::Load($dllBytes)
        }catch{
            try{ [void][System.Reflection.Assembly]::LoadFrom($gateDll) }catch{}
        }
    }
}
try{ [CocoPopupGate]::EnablePerMonitorDpi() }catch{}

function ConvertFrom-CocoCodePoints([int[]]$CodePoints){
    -join ($CodePoints|ForEach-Object{[char]$_})
}

# Etiquetas rusas de ventanas online-fix, construidas por puntos de codigo para mantener el engine en ASCII.
$cocoRuPlay=(ConvertFrom-CocoCodePoints @(0x0438,0x0433,0x0440,0x0430,0x0442,0x044C))
$cocoRuEnter=(ConvertFrom-CocoCodePoints @(0x0432,0x043E,0x0439,0x0442,0x0438))
$cocoRuStart=(ConvertFrom-CocoCodePoints @(0x043D,0x0430,0x0447,0x0430,0x0442,0x044C))
$cocoRuGo=(ConvertFrom-CocoCodePoints @(0x0441,0x0442,0x0430,0x0440,0x0442))
$cocoRuAccept=(ConvertFrom-CocoCodePoints @(0x043F,0x0440,0x0438,0x043D,0x044F,0x0442,0x044C))
$cocoRuContinue=(ConvertFrom-CocoCodePoints @(0x043F,0x0440,0x043E,0x0434,0x043E,0x043B,0x0436,0x0438,0x0442,0x044C))
$cocoRuClose=(ConvertFrom-CocoCodePoints @(0x0437,0x0430,0x043A,0x0440,0x044B,0x0442,0x044C))
$cocoRuOk=(ConvertFrom-CocoCodePoints @(0x043E,0x043A))

$script:CocoPopupGateDefaults=[pscustomobject]@{
    markers=@('online-fix','onlinefix','online fix','credits','créditos','fix made by','the fix is made by','online-fix.me','cs.rin.ru','you will get this message only once','freesteam','steamfix','ofme')
    buttonLabels=@('ok','accept','aceptar','play','play!','start','start game','empezar','begin','enter','entrar','continue','continuar','go','ir','jugar','join','unirse',$cocoRuPlay,($cocoRuPlay+'!'),$cocoRuEnter,$cocoRuStart,$cocoRuGo,$cocoRuAccept,$cocoRuContinue,$cocoRuClose,$cocoRuOk)
    dialogClasses=@('#32770')
}

$script:CocoIdentityButton=$null
$script:CocoIdentityTextBox=$null
$script:CocoIdentityStatus=$null
$script:CocoIdentityOpenAction=$null
$script:CocoIdentityConfirmedName=''

function Get-CocoPopupGateConfig($Experience){
    $config=[ordered]@{
        markers=@($script:CocoPopupGateDefaults.markers)
        buttonLabels=@($script:CocoPopupGateDefaults.buttonLabels)
        dialogClasses=@($script:CocoPopupGateDefaults.dialogClasses)
    }
    $override=$null
    try{$override=$Experience.preferences.popupGate}catch{}
    if($override){
        foreach($key in @('markers','buttonLabels','dialogClasses')){
            $value=$null
            try{$value=@($override.$key)|Where-Object{$_-ne$null-and"$($_)".Trim()}}catch{}
            if(@($value).Count){$config[$key]=@($value|ForEach-Object{"$_"})}
        }
    }
    return $config
}

function Prepare-CocoStandalonePopupGate($Experience){
    if(-not([System.Management.Automation.PSTypeName]'CocoPopupGate').Type){return $false}
    $config=Get-CocoPopupGateConfig $Experience
    [void]([CocoPopupGate]::StartSessionWatcher(0,([string]::Join('|',$config.markers)),([string]::Join('|',$config.buttonLabels)),([string]::Join('|',$config.dialogClasses))))
    Write-CocoLog "POPUPGATE: vigilante pre-armado (markers=$(@($config.markers).Count);labels=$(@($config.buttonLabels).Count))."
    return $true
}

function Start-CocoStandalonePopupGate($Process,$Experience){
    if(-not$Process-or$Process.HasExited){return $false}
    if(-not([System.Management.Automation.PSTypeName]'CocoPopupGate').Type){return $false}
    $config=Get-CocoPopupGateConfig $Experience
    if([CocoPopupGate]::IsRunning()){
        [CocoPopupGate]::BindProcessId([int]$Process.Id)
    }else{
        [void]([CocoPopupGate]::StartSessionWatcher([int]$Process.Id,([string]::Join('|',$config.markers)),([string]::Join('|',$config.buttonLabels)),([string]::Join('|',$config.dialogClasses))))
    }
    Write-CocoLog "POPUPGATE: vigilante activo para PID $($Process.Id) (markers=$(@($config.markers).Count);labels=$(@($config.buttonLabels).Count))."
    return $true
}

function Stop-CocoStandalonePopupGate{
    if(-not([System.Management.Automation.PSTypeName]'CocoPopupGate').Type){return}
    try{
        $diagnostics=[CocoPopupGate]::TakeDiagnostics()
        if($diagnostics){Write-CocoLog "POPUPGATE candidatos no atendidos: $diagnostics"}
        Write-CocoLog "POPUPGATE: vigilante detenido ($([CocoPopupGate]::Describe()))."
    }catch{}
    try{[CocoPopupGate]::StopSessionWatcher()}catch{}
}

$cocoLogVar=Get-Variable -Name 'CocoLogPath' -Scope Script -ErrorAction SilentlyContinue
if(-not$cocoLogVar-or-not$cocoLogVar.Value){$script:CocoLogPath=''}
if(-not(Get-Command Write-CocoLog -ErrorAction SilentlyContinue)){
    function Write-CocoLog([string]$Text){
        if($script:CocoLogPath){
            try{ Add-Content -LiteralPath $script:CocoLogPath -Value ("{0:o} {1}" -f (Get-Date),$Text) -Encoding UTF8 }catch{}
        }
    }
}

function Write-CocoStorageDiagnostic([string]$Event,[hashtable]$Data=@{}){
    # Diagnostico de soporte para instalaciones y rutas. Solo recibe datos de
    # experiencia/filesystem; nunca registrar credenciales, tokens ni archivos.
    try{
        $fields=[Collections.Generic.List[string]]::new()
        foreach($key in @($Data.Keys|Sort-Object)){
            $value=[string]$Data[$key]
            if($null-eq$value){$value=''}
            $value=$value-replace'[\r\n|]',' '
            $fields.Add(('{0}={1}'-f$key,$value))
        }
        $suffix=if($fields.Count){' | '+($fields-join' | ')}else{''}
        Write-CocoLog ("STORAGE {0}{1}"-f$Event,$suffix)
    }catch{}
}

function Test-CocoPathWithin([string]$Path,[string]$Root){
    if([string]::IsNullOrWhiteSpace($Path)-or[string]::IsNullOrWhiteSpace($Root)){return $false}
    try{
        $resolvedPath=[IO.Path]::GetFullPath($Path).TrimEnd('\')
        $resolvedRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\')
        if($resolvedPath.StartsWith($resolvedRoot+'\',[StringComparison]::OrdinalIgnoreCase)){return $true}
    }catch{}
    try{
        $normP=$Path.Replace('/','\').TrimEnd('\')
        $normR=$Root.Replace('/','\').TrimEnd('\')
        if($normP.StartsWith($normR+'\',[StringComparison]::OrdinalIgnoreCase)-and-not$normP.Contains('..\')-and-not$normP.Contains('/..')){
            return $true
        }
    }catch{}
    return $false
}

function Get-CocoExperienceButtonBounds([ValidateRange(0,999)][int]$Index){
    [Drawing.Rectangle]::new([int](($Index%2)*260),[int]([math]::Floor($Index/2)*50),245,42)
}

function Get-CocoExperienceDiskUsage([string]$InstanceRoot){
    if(-not$InstanceRoot-or-not(Test-Path -LiteralPath $InstanceRoot -PathType Container)){return [pscustomobject]@{Bytes=0;Label='No instalado';Installed=$false}}
    $totalBytes=0
    $fileCount=0
    try{
        foreach($file in [IO.Directory]::EnumerateFiles($InstanceRoot,'*','AllDirectories')){
            $fileCount++
            try{$totalBytes+=(New-Object IO.FileInfo($file)).Length}catch{}
        }
    }catch{
        return [pscustomobject]@{Bytes=$totalBytes;Label='No disponible';Installed=$true;FileCount=$fileCount;Error=$_.Exception.Message}
    }
    if($fileCount-eq0){return [pscustomobject]@{Bytes=0;Label='No instalado';Installed=$false;FileCount=0}}
    $label=if($totalBytes-ge1GB){'{0:N1} GB'-f($totalBytes/1GB)}elseif($totalBytes-ge1MB){'{0:N0} MB'-f($totalBytes/1MB)}elseif($totalBytes-gt0){'{0:N0} KB'-f($totalBytes/1KB)}else{'Vacio'}
    [pscustomobject]@{Bytes=$totalBytes;Label=$label;Installed=$true;FileCount=$fileCount}
}

function Test-CocoExperienceStagePath([string]$StagePath,[string]$InstanceRoot){
    if([string]::IsNullOrWhiteSpace($StagePath)-or[string]::IsNullOrWhiteSpace($InstanceRoot)){return $false}
    try{
        $fullStage=[IO.Path]::GetFullPath($StagePath).TrimEnd('\')
        $fullInstance=[IO.Path]::GetFullPath($InstanceRoot).TrimEnd('\')
        $prefix=$fullInstance+'.coco-stage-'
        if(-not$fullStage.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $false}
        $suffix=$fullStage.Substring($prefix.Length)
        return $suffix-match'^[a-fA-F0-9]{32}$'-and
            [string]::Equals((Split-Path $fullStage -Parent),(Split-Path $fullInstance -Parent),[StringComparison]::OrdinalIgnoreCase)
    }catch{return $false}
}

function Remove-CocoStaleExperienceStages([string]$InstanceRoot){
    if([string]::IsNullOrWhiteSpace($InstanceRoot)){return 0}
    $fullInstance=[IO.Path]::GetFullPath($InstanceRoot).TrimEnd('\')
    $parent=Split-Path $fullInstance -Parent
    $leaf=Split-Path $fullInstance -Leaf
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){return 0}
    $removed=0
    foreach($candidate in @(Get-ChildItem -LiteralPath $parent -Directory -Filter "$leaf.coco-stage-*" -Force -ErrorAction SilentlyContinue)){
        if(-not(Test-CocoExperienceStagePath $candidate.FullName $fullInstance)){continue}
        try{
            Remove-Item -LiteralPath $candidate.FullName -Recurse -Force -ErrorAction Stop
            $removed++
            Write-CocoLog "Staging obsoleto de experiencia eliminado: $($candidate.FullName)"
        }catch{
            Write-CocoLog "No se pudo eliminar staging obsoleto '$($candidate.FullName)': $($_.Exception.Message)"
        }
    }
    return $removed
}

function Get-CocoCompactPath([string]$Path,[int]$MaxLength=38){
    if([string]::IsNullOrWhiteSpace($Path)){return ''}
    $cleanPath=$Path.TrimEnd('\')
    if($cleanPath.Length -le $MaxLength){return $cleanPath}
    $drive=[IO.Path]::GetPathRoot($cleanPath)
    $leaf=Split-Path $cleanPath -Leaf
    $parent=Split-Path (Split-Path $cleanPath -Parent) -Leaf
    if($parent){
        $candidate="$drive...\$parent\$leaf"
        if($candidate.Length -le $MaxLength){return $candidate}
    }
    return "$drive...\$leaf"
}

function Get-CocoInstanceLocationsStorePath([string]$StorePath='') {
    if([string]::IsNullOrWhiteSpace($StorePath)-and-not[string]::IsNullOrWhiteSpace([string]$script:CocoInstanceLocationsPath)){
        $StorePath=[string]$script:CocoInstanceLocationsPath
    }
    if([string]::IsNullOrWhiteSpace($StorePath)){
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $localAppData) { $localAppData = $env:LOCALAPPDATA }
        $StorePath=Join-Path $localAppData 'CocoMinecraftUpdater\instance-locations.json'
    }
    $fullPath=[IO.Path]::GetFullPath($StorePath)
    $dir=Split-Path $fullPath -Parent
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    $fullPath
}

function Get-CocoInstanceCustomLocations([string]$StorePath='') {
    $store = Get-CocoInstanceLocationsStorePath $StorePath
    if (Test-Path -LiteralPath $store -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $store -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($json) { return $json }
        } catch {}
    }
    return [pscustomobject]@{}
}

function Get-CocoExperienceInstanceRoot([object]$Experience, $DefaultExperiencesRoot, [string]$StorePath='') {
    $expRoot = if ($DefaultExperiencesRoot -is [hashtable]) {
        [string]$DefaultExperiencesRoot['ExperiencesRoot']
    } elseif ($DefaultExperiencesRoot -and $DefaultExperiencesRoot.ExperiencesRoot) {
        [string]$DefaultExperiencesRoot.ExperiencesRoot
    } else {
        [string]$DefaultExperiencesRoot
    }
    if (-not $Experience) { return $expRoot }
    $expId = [string]$Experience.id
    $instanceId = [string]$Experience.instanceId
    if (-not $instanceId) { $instanceId = $expId }
    
    $store = Get-CocoInstanceCustomLocations $StorePath
    $custom = $null
    if ($store) {
        if ($store.PSObject.Properties[$instanceId]) { $custom = [string]$store.PSObject.Properties[$instanceId].Value }
        elseif ($store.PSObject.Properties[$expId]) { $custom = [string]$store.PSObject.Properties[$expId].Value }
    }
    if (-not [string]::IsNullOrWhiteSpace($custom)) {
        return $custom
    }
    return (Join-Path $expRoot $instanceId)
}

function Test-CocoExperienceLocationConflict([string]$InstanceId,[string]$InstanceRoot,[string]$StorePath='') {
    if([string]::IsNullOrWhiteSpace($InstanceId)-or[string]::IsNullOrWhiteSpace($InstanceRoot)){return $false}
    $full=[IO.Path]::GetFullPath($InstanceRoot)
    $locations=Get-CocoInstanceCustomLocations $StorePath
    if(-not$locations){return $false}
    foreach($property in $locations.PSObject.Properties){
        if([string]$property.Name-eq$InstanceId){continue}
        if([string]::IsNullOrWhiteSpace([string]$property.Value)){continue}
        try{
            if([IO.Path]::GetFullPath([string]$property.Value).TrimEnd('\').Equals($full.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){return $true}
        }catch{}
    }
    return $false
}

function Set-CocoExperienceInstanceRoot([string]$InstanceId, [string]$CustomPath, [string]$StorePath='') {
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return }
    $storePath = Get-CocoInstanceLocationsStorePath $StorePath
    $normalizedPath=if([string]::IsNullOrWhiteSpace($CustomPath)){''}else{[IO.Path]::GetFullPath($CustomPath)}
    Write-CocoStorageDiagnostic 'location.store.request' @{instanceId=$InstanceId;customPath=$normalizedPath;storePath=$storePath}
    if(-not[string]::IsNullOrWhiteSpace($CustomPath)-and(Test-CocoExperienceLocationConflict $InstanceId $normalizedPath $storePath)){
        Write-CocoStorageDiagnostic 'location.store.conflict' @{instanceId=$InstanceId;customPath=$normalizedPath;storePath=$storePath}
        throw 'La ubicacion ya esta asignada a otra experiencia.'
    }
    $locations = Get-CocoInstanceCustomLocations $storePath
    $dict = [ordered]@{}
    if ($locations) {
        foreach ($prop in $locations.PSObject.Properties) {
            $dict[$prop.Name] = [string]$prop.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($CustomPath)) {
        if ($dict.Contains($InstanceId)) { $dict.Remove($InstanceId) }
    } else {
        $dict[$InstanceId] = [IO.Path]::GetFullPath($CustomPath)
    }
    $json = ConvertTo-Json -InputObject $dict -Depth 2
    $temporary="$storePath.coco-$PID-$([guid]::NewGuid().ToString('N')).tmp"
    try{
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $storePath -Force
        Write-CocoStorageDiagnostic 'location.store.saved' @{instanceId=$InstanceId;customPath=$normalizedPath;storePath=$storePath;entryCount=$dict.Count}
    }catch{
        Write-CocoStorageDiagnostic 'location.store.error' @{instanceId=$InstanceId;customPath=$normalizedPath;storePath=$storePath;error=$_.Exception.Message}
        throw
    }finally{
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Backup-CocoExperienceUserData([string]$InstanceRoot,[string]$InstanceId,[string]$BackupRoot=''){
    $protected=@('saves','playerdata','stats','advancements')
    $present=@($protected|Where-Object{Test-Path -LiteralPath (Join-Path $InstanceRoot $_)})
    if(-not$present.Count){return $null}
    if([string]::IsNullOrWhiteSpace($BackupRoot)){
        $localAppData=[Environment]::GetFolderPath('LocalApplicationData')
        if(-not$localAppData){$localAppData=$env:LOCALAPPDATA}
        $BackupRoot=Join-Path $localAppData 'CocoMinecraftUpdater\backups\experiences'
    }
    $safeId=if([string]::IsNullOrWhiteSpace($InstanceId)){'instance'}else{[regex]::Replace($InstanceId,'[^A-Za-z0-9._-]','_')}
    $destination=Join-Path $BackupRoot ("{0}-{1}-{2}"-f$safeId,(Get-Date -Format 'yyyyMMdd-HHmmss'),[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    try{
        foreach($relative in $present){
            Copy-Item -LiteralPath (Join-Path $InstanceRoot $relative) -Destination (Join-Path $destination $relative) -Recurse -Force -ErrorAction Stop
        }
        Write-CocoLog "Respaldo de datos del jugador creado antes de liberar espacio: $destination"
        return $destination
    }catch{
        Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        throw "No se pudo crear el respaldo de datos antes de eliminar la instancia: $($_.Exception.Message)"
    }
}

function Remove-CocoInstalledExperience([string]$InstanceRoot, [string]$ExperiencesRoot, [string]$InstanceId='', [string]$StorePath='', [string]$BackupRoot=''){
    if(-not$InstanceRoot-or-not$ExperiencesRoot){throw 'La ruta de la instancia o la raiz de experiencias no fue proporcionada.'}
    $fullInstance = [IO.Path]::GetFullPath($InstanceRoot)
    $fullExperiences = [IO.Path]::GetFullPath($ExperiencesRoot)
    Write-CocoStorageDiagnostic 'delete.start' @{instanceId=$InstanceId;instanceRoot=$fullInstance;experiencesRoot=$fullExperiences;storePath=$StorePath;backupRoot=$BackupRoot}
    $rootPath = [IO.Path]::GetPathRoot($fullInstance)
    if ($fullInstance.TrimEnd('\') -eq $rootPath.TrimEnd('\')) { Write-CocoStorageDiagnostic 'delete.rejected.root' @{instanceId=$InstanceId;instanceRoot=$fullInstance};throw 'No se puede eliminar un directorio raiz del sistema.' }
    if(-not(Test-CocoPathWithin $InstanceRoot $ExperiencesRoot)) {
        $locations = Get-CocoInstanceCustomLocations $StorePath
        $isCustom = $false
        if ($locations) {
            foreach ($prop in $locations.PSObject.Properties) {
                if ([string]$prop.Value -and [IO.Path]::GetFullPath([string]$prop.Value).Equals($fullInstance, [StringComparison]::OrdinalIgnoreCase)) {
                    $isCustom = $true
                    break
                }
            }
        }
        if (-not $isCustom) { Write-CocoStorageDiagnostic 'delete.rejected.outside-root' @{instanceId=$InstanceId;instanceRoot=$fullInstance;experiencesRoot=$fullExperiences};throw 'La ruta de la instancia escapa del directorio de experiencias.' }
    }
    if(-not(Test-Path -LiteralPath $InstanceRoot -PathType Container)){Write-CocoStorageDiagnostic 'delete.not-installed' @{instanceId=$InstanceId;instanceRoot=$fullInstance};return [pscustomobject]@{Removed=$false;Reason='not-installed'}}
    $running=Test-CocoManagedGameRunning $InstanceRoot
    Write-CocoStorageDiagnostic 'delete.preflight' @{instanceId=$InstanceId;instanceRoot=$fullInstance;running=$running}
    if($running){Write-CocoStorageDiagnostic 'delete.rejected.running' @{instanceId=$InstanceId;instanceRoot=$fullInstance};throw 'La experiencia esta abierta. Cierrala antes de eliminarla.'}
    $backup=Backup-CocoExperienceUserData $InstanceRoot $InstanceId $BackupRoot
    Write-CocoStorageDiagnostic 'delete.backup.complete' @{instanceId=$InstanceId;instanceRoot=$fullInstance;backupRoot=$backup}
    Remove-Item -LiteralPath $InstanceRoot -Recurse -Force
    Write-CocoLog "Experiencia eliminada para liberar espacio: $InstanceRoot"
    Write-CocoStorageDiagnostic 'delete.complete' @{instanceId=$InstanceId;instanceRoot=$fullInstance;backupRoot=$backup}
    [pscustomobject]@{Removed=$true;Reason='deleted';BackupRoot=$backup}
}

function Prompt-CocoExperienceLocationChoice($Experience, [string]$DefaultExperiencesRoot, [string]$StorePath='') {
    if (-not $Experience) { return [pscustomobject]@{Confirmed=$false;Cancelled=$true;Choice='invalid'} }
    $expId = [string]$Experience.id
    $instanceId = [string]$Experience.instanceId
    if (-not $instanceId) { $instanceId = $expId }
    Write-CocoStorageDiagnostic 'location.prompt.start' @{experienceId=$expId;instanceId=$instanceId;defaultRoot=$DefaultExperiencesRoot;storePath=$StorePath}
    
    $store = Get-CocoInstanceCustomLocations $StorePath
    if ($store -and ($store.PSObject.Properties[$instanceId] -or $store.PSObject.Properties[$expId])) {
        $mappedRoot=Get-CocoExperienceInstanceRoot $Experience $DefaultExperiencesRoot $StorePath
        Write-CocoStorageDiagnostic 'location.prompt.existing-mapping' @{experienceId=$expId;instanceId=$instanceId;root=$mappedRoot;storePath=$StorePath}
        return [pscustomobject]@{Confirmed=$true;Cancelled=$false;Choice='existing';Root=$mappedRoot}
    }
    
    $instanceRoot = Join-Path $DefaultExperiencesRoot $instanceId
    if ((Get-CocoExperienceDiskUsage $instanceRoot).Installed) {
        Write-CocoStorageDiagnostic 'location.prompt.existing-default' @{experienceId=$expId;instanceId=$instanceId;root=$instanceRoot}
        return [pscustomobject]@{Confirmed=$true;Cancelled=$false;Choice='existing';Root=$instanceRoot}
    }
    
    if (-not $script:CocoForm -or $script:CocoForm.IsDisposed) { Write-CocoStorageDiagnostic 'location.prompt.rejected.no-window' @{experienceId=$expId;instanceId=$instanceId};throw 'No se puede elegir la ubicacion: la ventana de Coco Launcher no esta disponible.' }
    
    $experienceName=[string]$Experience.name
    $dialog=New-Object Windows.Forms.Form
    $dialog.Name='CocoInstallLocationDialog';$dialog.Text=("Instalar {0}"-f$experienceName);$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='None';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.KeyPreview=$true;$dialog.ShowInTaskbar=$false;$dialog.TopMost=$false;$dialog.BackColor=[Drawing.Color]::FromArgb(53,35,67);$dialog.Padding=New-Object Windows.Forms.Padding(1);$dialog.ClientSize=New-Object Drawing.Size(660,315);$dialog.MinimumSize=New-Object Drawing.Size(660,315)
    $dialog.Add_Paint({param($sender,$eventArgs)$pen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(84,59,106),1);try{$eventArgs.Graphics.DrawRectangle($pen,0,0,$sender.ClientSize.Width-1,$sender.ClientSize.Height-1)}finally{$pen.Dispose()}}.GetNewClosure())

    $header=New-Object Windows.Forms.Panel;$header.Name='CocoInstallLocationHeader';$header.Dock='Top';$header.Height=78;$header.BackColor=[Drawing.Color]::FromArgb(27,19,38)
    $accent=New-Object Windows.Forms.Panel;$accent.Name='CocoInstallLocationAccent';$accent.Dock='Left';$accent.Width=5;$accent.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $heading=New-Object Windows.Forms.Label;$heading.Name='CocoInstallLocationTitle';$heading.Text='INSTALAR EXPERIENCIA';$heading.Font=New-Object Drawing.Font('Segoe UI Semibold',14);$heading.ForeColor=[Drawing.Color]::White;$heading.AutoEllipsis=$true
    $subHeading=New-Object Windows.Forms.Label;$subHeading.Name='CocoInstallLocationSubtitle';$subHeading.Text=("Elige donde guardar {0}"-f$experienceName);$subHeading.Font=New-Object Drawing.Font('Segoe UI',8.5);$subHeading.ForeColor=[Drawing.Color]::FromArgb(177,162,193);$subHeading.AutoEllipsis=$true
    $closeButton=New-Object Windows.Forms.Button;$closeButton.Name='CocoInstallLocationCloseButton';$closeButton.Text='X';$closeButton.AccessibleName='Cerrar';$closeButton.Font=New-Object Drawing.Font('Segoe UI Semibold',9);Set-CocoMediaButtonStyle $closeButton ([Drawing.Color]::FromArgb(27,19,38)) ([Drawing.Color]::FromArgb(218,210,229)) ([Drawing.Color]::FromArgb(150,48,70));$closeButton.Add_Click({$dialog.Tag='cancelled';$dialog.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Close()}.GetNewClosure())
    $header.Controls.AddRange(@($accent,$heading,$subHeading,$closeButton))

    $body=New-Object Windows.Forms.Panel;$body.Name='CocoInstallLocationBody';$body.Dock='Fill';$body.BackColor=[Drawing.Color]::FromArgb(22,13,34)
    $intro=New-Object Windows.Forms.Label;$intro.Name='CocoInstallLocationIntro';$intro.Text='La instalacion se guardara en una carpeta separada para esta experiencia.';$intro.Font=New-Object Drawing.Font('Segoe UI Semibold',8.5);$intro.ForeColor=[Drawing.Color]::FromArgb(235,228,241);$intro.AutoEllipsis=$true
    $pathCard=New-Object Windows.Forms.Panel;$pathCard.Name='CocoInstallLocationPathCard';$pathCard.BackColor=[Drawing.Color]::FromArgb(32,22,48)
    $pathCaption=New-Object Windows.Forms.Label;$pathCaption.Name='CocoInstallLocationPathCaption';$pathCaption.Text='RUTA PREDETERMINADA';$pathCaption.Font=New-Object Drawing.Font('Segoe UI Semibold',7.5);$pathCaption.ForeColor=[Drawing.Color]::FromArgb(177,162,193)
    $pathLabel=New-Object Windows.Forms.Label;$pathLabel.Name='CocoInstallLocationPath';$pathLabel.Text=$instanceRoot;$pathLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',9);$pathLabel.ForeColor=[Drawing.Color]::White;$pathLabel.AutoEllipsis=$true
    $pathCard.Controls.AddRange(@($pathCaption,$pathLabel))
    $hint=New-Object Windows.Forms.Label;$hint.Name='CocoInstallLocationHint';$hint.Text='Tambien puedes elegir otra carpeta. Coco creara dentro la carpeta de la instancia.';$hint.Font=New-Object Drawing.Font('Segoe UI',8);$hint.ForeColor=[Drawing.Color]::FromArgb(177,162,193);$hint.AutoEllipsis=$true
    $toolTip=New-Object Windows.Forms.ToolTip;$toolTip.AutoPopDelay=6000;$toolTip.InitialDelay=350;$toolTip.ReshowDelay=100;$toolTip.SetToolTip($pathLabel,$instanceRoot)
    $body.Controls.AddRange(@($intro,$pathCard,$hint))

    $footer=New-Object Windows.Forms.Panel;$footer.Name='CocoInstallLocationFooter';$footer.Dock='Bottom';$footer.Height=82;$footer.BackColor=[Drawing.Color]::FromArgb(27,19,38)
    $footerLine=New-Object Windows.Forms.Panel;$footerLine.Name='CocoInstallLocationFooterLine';$footerLine.Dock='Top';$footerLine.Height=1;$footerLine.BackColor=[Drawing.Color]::FromArgb(72,52,91)
    $defaultBtn=New-Object Windows.Forms.Button;$defaultBtn.Name='CocoInstallLocationDefaultButton';$defaultBtn.Text='INSTALAR EN RUTA POR DEFECTO';$defaultBtn.AccessibleName='Instalar en ruta por defecto';$defaultBtn.Size=New-Object Drawing.Size(280,38);Set-CocoMediaButtonStyle $defaultBtn ([Drawing.Color]::FromArgb(177,92,255)) ([Drawing.Color]::White) ([Drawing.Color]::FromArgb(196,121,255));$defaultBtn.DialogResult=[Windows.Forms.DialogResult]::OK;$defaultBtn.Add_Click({$dialog.Tag='default'}.GetNewClosure())
    $customBtn=New-Object Windows.Forms.Button;$customBtn.Name='CocoInstallLocationCustomButton';$customBtn.Text='ELEGIR OTRA CARPETA';$customBtn.AccessibleName='Elegir otra carpeta';$customBtn.Size=New-Object Drawing.Size(176,38);Set-CocoMediaButtonStyle $customBtn ([Drawing.Color]::FromArgb(83,47,117)) ([Drawing.Color]::White) ([Drawing.Color]::FromArgb(102,61,140))
    $cancelBtn=New-Object Windows.Forms.Button;$cancelBtn.Name='CocoInstallLocationCancelButton';$cancelBtn.Text='CANCELAR';$cancelBtn.AccessibleName='Cancelar';$cancelBtn.Size=New-Object Drawing.Size(94,38);Set-CocoMediaButtonStyle $cancelBtn ([Drawing.Color]::FromArgb(38,27,52)) ([Drawing.Color]::FromArgb(218,210,229)) ([Drawing.Color]::FromArgb(67,46,88));$cancelBtn.DialogResult=[Windows.Forms.DialogResult]::Cancel;$cancelBtn.Add_Click({$dialog.Tag='cancelled'}.GetNewClosure())
    $footer.Controls.AddRange(@($footerLine,$defaultBtn,$customBtn,$cancelBtn))

    $layoutInstallDialog={
        $width=[Math]::Max(1,[int]$dialog.ClientSize.Width);$headerWidth=[Math]::Max(220,$width-66)
        $heading.Location=New-Object Drawing.Point(22,11);$heading.Size=New-Object Drawing.Size($headerWidth,25)
        $subHeading.Location=New-Object Drawing.Point(22,42);$subHeading.Size=New-Object Drawing.Size($headerWidth,18)
        $closeButton.Location=New-Object Drawing.Point([Math]::Max(0,$width-46),20);$closeButton.Size=New-Object Drawing.Size(34,34)
        $bodyWidth=[Math]::Max(1,[int]$body.ClientSize.Width);$bodyHeight=[Math]::Max(1,[int]$body.ClientSize.Height);$margin=22
        $intro.Location=New-Object Drawing.Point($margin,18);$intro.Size=New-Object Drawing.Size([Math]::Max(1,$bodyWidth-($margin*2)),22)
        $pathCard.Location=New-Object Drawing.Point($margin,48);$pathCard.Size=New-Object Drawing.Size([Math]::Max(1,$bodyWidth-($margin*2)),70)
        $pathCaption.Location=New-Object Drawing.Point(14,10);$pathCaption.Size=New-Object Drawing.Size([Math]::Max(1,$pathCard.ClientSize.Width-28),16)
        $pathLabel.Location=New-Object Drawing.Point(14,31);$pathLabel.Size=New-Object Drawing.Size([Math]::Max(1,$pathCard.ClientSize.Width-28),28)
        $hint.Location=New-Object Drawing.Point($margin,128);$hint.Size=New-Object Drawing.Size([Math]::Max(1,$bodyWidth-($margin*2)),22)
        $footerWidth=[int][Math]::Max(1,[int]$footer.ClientSize.Width);$gap=8;$right=22
        $cancelX=[int]$footerWidth-[int]$right-[int]$cancelBtn.Width;$cancelBtn.Location=[Drawing.Point]::new($cancelX,25)
        $customX=[int]$cancelBtn.Left-[int]$gap-[int]$customBtn.Width;$customBtn.Location=[Drawing.Point]::new($customX,25)
        $defaultX=[int]$customBtn.Left-[int]$gap-[int]$defaultBtn.Width;$defaultBtn.Location=[Drawing.Point]::new($defaultX,25)
    }.GetNewClosure()
    $dialog.Add_Resize($layoutInstallDialog)
    $dialog.Controls.AddRange(@($body,$footer,$header))
    &$layoutInstallDialog
    $dialog.AcceptButton=$defaultBtn;$dialog.CancelButton=$cancelBtn
    $dragState=@{Active=$false;Start=[Drawing.Point]::Empty;Origin=[Drawing.Point]::Empty}
    $beginDrag={param($sender,$eventArgs)if($eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){$dragState.Active=$true;$dragState.Start=[Windows.Forms.Cursor]::Position;$dragState.Origin=$dialog.Location}}.GetNewClosure()
    $moveDrag={param($sender,$eventArgs)if($dragState.Active){$current=[Windows.Forms.Cursor]::Position;$dialog.Location=New-Object Drawing.Point($dragState.Origin.X+($current.X-$dragState.Start.X),$dragState.Origin.Y+($current.Y-$dragState.Start.Y))}}.GetNewClosure()
    $endDrag={param($sender,$eventArgs)$dragState.Active=$false}.GetNewClosure()
    foreach($dragControl in @($header,$heading,$subHeading)){$dragControl.Add_MouseDown($beginDrag);$dragControl.Add_MouseMove($moveDrag);$dragControl.Add_MouseUp($endDrag)}
    $dialog.Add_KeyDown({param($sender,$eventArgs)if($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Escape){$sender.Tag='cancelled';$sender.DialogResult=[Windows.Forms.DialogResult]::Cancel;$sender.Close()}}.GetNewClosure())
    $dialog.Add_Shown({[void]$defaultBtn.Focus()}.GetNewClosure())
    $customBtn.Add_Click({
        Write-CocoStorageDiagnostic 'location.prompt.custom-dialog.open' @{experienceId=$expId;instanceId=$instanceId;defaultRoot=$instanceRoot}
        $fbd = New-Object Windows.Forms.FolderBrowserDialog
        $fbd.Description = ("Selecciona la carpeta donde quieres instalar {0}:" -f $Experience.name)
        $fbd.ShowNewFolderButton = $true
        if ($fbd.ShowDialog($dialog) -eq [Windows.Forms.DialogResult]::OK) {
            if (-not [string]::IsNullOrWhiteSpace($fbd.SelectedPath)) {
                $chosenRoot = Join-Path $fbd.SelectedPath $instanceId
                try{
                    $fullChosen=[IO.Path]::GetFullPath($chosenRoot)
                    Write-CocoStorageDiagnostic 'location.prompt.custom-selected' @{experienceId=$expId;instanceId=$instanceId;parentPath=$fbd.SelectedPath;chosenRoot=$fullChosen}
                    $rootPath=[IO.Path]::GetPathRoot($fullChosen)
                    if($fullChosen.TrimEnd('\') -eq $rootPath.TrimEnd('\')){throw 'No puedes seleccionar la raiz de la unidad.'}
                    if(Test-CocoExperienceLocationConflict $instanceId $fullChosen $StorePath){throw 'Esa carpeta ya esta asignada a otra experiencia.'}
                    if((Get-CocoExperienceDiskUsage $fullChosen).Installed){throw 'La carpeta final ya contiene archivos. Elige otra ubicacion o usa CAMBIAR CARPETA para mover una instalacion existente.'}
                    $dialog.Tag=$fullChosen
                    $dialog.DialogResult = [Windows.Forms.DialogResult]::OK
                    $dialog.Close()
                }catch{
                    Write-CocoStorageDiagnostic 'location.prompt.custom-rejected' @{experienceId=$expId;instanceId=$instanceId;parentPath=$fbd.SelectedPath;chosenRoot=$chosenRoot;error=$_.Exception.Message}
                    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Carpeta no valida',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
                }
            }else{Write-CocoStorageDiagnostic 'location.prompt.custom-empty' @{experienceId=$expId;instanceId=$instanceId}}
        }else{Write-CocoStorageDiagnostic 'location.prompt.custom-cancelled' @{experienceId=$expId;instanceId=$instanceId}}
    })
    
    $result=$dialog.ShowDialog($script:CocoForm)
    $choice=[string]$dialog.Tag
    $dialog.Dispose()
    Write-CocoStorageDiagnostic 'location.prompt.closed' @{experienceId=$expId;instanceId=$instanceId;dialogResult=$result;choice=$choice}
    if($result-ne[Windows.Forms.DialogResult]::OK){Write-CocoStorageDiagnostic 'location.prompt.cancelled' @{experienceId=$expId;instanceId=$instanceId};return [pscustomobject]@{Confirmed=$false;Cancelled=$true;Choice='cancelled';Root=$instanceRoot}}
    if($choice-eq'default'){Write-CocoStorageDiagnostic 'location.prompt.default-selected' @{experienceId=$expId;instanceId=$instanceId;root=$instanceRoot};return [pscustomobject]@{Confirmed=$true;Cancelled=$false;Choice='default';Root=$instanceRoot}}
    if([string]::IsNullOrWhiteSpace($choice)){Write-CocoStorageDiagnostic 'location.prompt.invalid-result' @{experienceId=$expId;instanceId=$instanceId;dialogResult=$result};throw 'La ventana de ubicacion termino sin una seleccion valida.'}
    Set-CocoExperienceInstanceRoot $instanceId $choice $StorePath
    Write-CocoStorageDiagnostic 'location.prompt.custom-confirmed' @{experienceId=$expId;instanceId=$instanceId;root=$choice;storePath=$StorePath}
    [pscustomobject]@{Confirmed=$true;Cancelled=$false;Choice='custom';Root=$choice}
}

function Get-CocoFileSha256([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
    $sha=[Security.Cryptography.SHA256]::Create()
    $stream=[IO.File]::OpenRead($Path)
    try{
        [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
    }finally{
        $stream.Dispose()
        $sha.Dispose()
    }
}
function Get-Sha256([string]$Path){ Get-CocoFileSha256 $Path }

function Test-CocoDirectoryCopyComplete([string]$Source,[string]$Destination){
    $sourceFull=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationFull=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $sourceFiles=@(Get-ChildItem -LiteralPath $sourceFull -Recurse -File -Force -ErrorAction Stop)
    $destinationFiles=@(Get-ChildItem -LiteralPath $destinationFull -Recurse -File -Force -ErrorAction Stop)
    if($sourceFiles.Count-ne$destinationFiles.Count){throw 'La copia de la instancia no contiene la misma cantidad de archivos.'}
    foreach($sourceFile in $sourceFiles){
        $relative=$sourceFile.FullName.Substring($sourceFull.Length).TrimStart('\')
        $destinationFile=Join-Path $destinationFull $relative
        if(-not(Test-Path -LiteralPath $destinationFile -PathType Leaf)){throw "Falta el archivo copiado '$relative'."}
        $destinationInfo=Get-Item -LiteralPath $destinationFile -Force
        if($sourceFile.Length-ne$destinationInfo.Length){throw "El tamano de '$relative' no coincide despues de copiar."}
        $sourceHash=Get-CocoFileSha256 $sourceFile.FullName
        $destinationHash=Get-CocoFileSha256 $destinationFile
        if($sourceHash-ne$destinationHash){throw "El hash de '$relative' no coincide despues de copiar."}
    }
    return $true
}

function Move-CocoInstalledExperience([string]$InstanceId,[string]$CurrentRoot,[string]$NewRoot,[string]$ExperiencesRoot,[string]$StorePath=''){
    if([string]::IsNullOrWhiteSpace($InstanceId)-or[string]::IsNullOrWhiteSpace($CurrentRoot)-or[string]::IsNullOrWhiteSpace($NewRoot)){throw 'Faltan datos para cambiar la carpeta de la instancia.'}
    $currentFull=[IO.Path]::GetFullPath($CurrentRoot).TrimEnd('\')
    $newFull=[IO.Path]::GetFullPath($NewRoot).TrimEnd('\')
    Write-CocoStorageDiagnostic 'move.start' @{instanceId=$InstanceId;currentRoot=$currentFull;newRoot=$newFull;experiencesRoot=$ExperiencesRoot;storePath=$StorePath}
    $rootPath=[IO.Path]::GetPathRoot($newFull)
    if($newFull-eq$rootPath.TrimEnd('\')){Write-CocoStorageDiagnostic 'move.rejected.root' @{instanceId=$InstanceId;newRoot=$newFull};throw 'No puedes seleccionar la raiz de la unidad.'}
    if(-not(Test-CocoPathWithin $currentFull $ExperiencesRoot)){
        $knownLocations=Get-CocoInstanceCustomLocations $StorePath
        $known=$false
        foreach($property in $knownLocations.PSObject.Properties){
            if([string]$property.Value-and[IO.Path]::GetFullPath([string]$property.Value).TrimEnd('\').Equals($currentFull,[StringComparison]::OrdinalIgnoreCase)){$known=$true;break}
        }
        if(-not$known){Write-CocoStorageDiagnostic 'move.rejected.unknown-current' @{instanceId=$InstanceId;currentRoot=$currentFull;experiencesRoot=$ExperiencesRoot};throw 'La instalacion actual no pertenece a la raiz de experiencias ni a una ubicacion personalizada conocida.'}
    }
    if($currentFull.Equals($newFull,[StringComparison]::OrdinalIgnoreCase)){Write-CocoStorageDiagnostic 'move.same-path' @{instanceId=$InstanceId;root=$newFull};return [pscustomobject]@{Moved=$false;Root=$newFull;Reason='same-path'}}
    if(Test-CocoPathWithin $newFull $currentFull-or Test-CocoPathWithin $currentFull $newFull){Write-CocoStorageDiagnostic 'move.rejected.nested-path' @{instanceId=$InstanceId;currentRoot=$currentFull;newRoot=$newFull};throw 'La nueva carpeta no puede estar dentro o contener la instalacion actual.'}
    if(Test-CocoExperienceLocationConflict $InstanceId $newFull $StorePath){Write-CocoStorageDiagnostic 'move.rejected.conflict' @{instanceId=$InstanceId;newRoot=$newFull;storePath=$StorePath};throw 'La nueva carpeta ya esta asignada a otra experiencia.'}
    $running=Test-CocoManagedGameRunning $currentFull
    Write-CocoStorageDiagnostic 'move.preflight' @{instanceId=$InstanceId;currentRoot=$currentFull;newRoot=$newFull;running=$running}
    if($running){Write-CocoStorageDiagnostic 'move.rejected.running' @{instanceId=$InstanceId;currentRoot=$currentFull};throw 'La experiencia esta abierta. Cierrala antes de cambiarla de carpeta.'}
    $currentExists=Test-Path -LiteralPath $currentFull -PathType Container
    $newExists=Test-Path -LiteralPath $newFull
    if($newExists){Write-CocoStorageDiagnostic 'move.rejected.destination-exists' @{instanceId=$InstanceId;newRoot=$newFull};throw "La nueva carpeta ya existe: $newFull. Elige una carpeta vacia que aun no use otra experiencia."}
    New-Item -ItemType Directory -Path (Split-Path $newFull -Parent) -Force|Out-Null
    if(-not$currentExists){
        Set-CocoExperienceInstanceRoot $InstanceId $newFull $StorePath
        Write-CocoStorageDiagnostic 'move.location-only' @{instanceId=$InstanceId;newRoot=$newFull}
        return [pscustomobject]@{Moved=$false;Root=$newFull;Reason='location-only'}
    }

    $movedMode=''
    try{
        $sameVolume=[IO.Path]::GetPathRoot($currentFull).Equals([IO.Path]::GetPathRoot($newFull),[StringComparison]::OrdinalIgnoreCase)
        if($sameVolume){
            Move-Item -LiteralPath $currentFull -Destination $newFull -Force -ErrorAction Stop
            $movedMode='same-volume'
            if(-not(Test-Path -LiteralPath $newFull -PathType Container)){throw 'La instalacion no aparecio en la nueva carpeta despues de moverla.'}
        }else{
            Copy-Item -LiteralPath $currentFull -Destination $newFull -Recurse -Force -ErrorAction Stop|Out-Null
            [void](Test-CocoDirectoryCopyComplete $currentFull $newFull)
            Remove-Item -LiteralPath $currentFull -Recurse -Force -ErrorAction Stop
            $movedMode='cross-volume'
        }
        Set-CocoExperienceInstanceRoot $InstanceId $newFull $StorePath
        Write-CocoLog "Instalacion '$InstanceId' movida a: $newFull"
        Write-CocoStorageDiagnostic 'move.complete' @{instanceId=$InstanceId;currentRoot=$currentFull;newRoot=$newFull;mode=$movedMode}
        return [pscustomobject]@{Moved=$true;Root=$newFull;Reason='moved'}
    }catch{
        $failure=$_.Exception.Message
        Write-CocoStorageDiagnostic 'move.error' @{instanceId=$InstanceId;currentRoot=$currentFull;newRoot=$newFull;mode=$movedMode;error=$failure}
        try{
            if($movedMode-eq'same-volume'-and(Test-Path -LiteralPath $newFull -PathType Container)-and-not(Test-Path -LiteralPath $currentFull -PathType Container)){
                Move-Item -LiteralPath $newFull -Destination $currentFull -Force -ErrorAction Stop
            }elseif($movedMode-eq'cross-volume'-and(Test-Path -LiteralPath $newFull -PathType Container)-and-not(Test-Path -LiteralPath $currentFull -PathType Container)){
                Copy-Item -LiteralPath $newFull -Destination $currentFull -Recurse -Force -ErrorAction Stop|Out-Null
                [void](Test-CocoDirectoryCopyComplete $newFull $currentFull)
                Remove-Item -LiteralPath $newFull -Recurse -Force -ErrorAction Stop
            }elseif((Test-Path -LiteralPath $newFull -PathType Container)-and-not(Test-Path -LiteralPath $currentFull -PathType Container)){
                Remove-Item -LiteralPath $newFull -Recurse -Force -ErrorAction SilentlyContinue
            }elseif((Test-Path -LiteralPath $newFull -PathType Container)-and(Test-Path -LiteralPath $currentFull -PathType Container)){
                Remove-Item -LiteralPath $newFull -Recurse -Force -ErrorAction SilentlyContinue
            }
        }catch{Write-CocoLog "No se pudo revertir completamente el cambio de carpeta de '$InstanceId': $($_.Exception.Message)";Write-CocoStorageDiagnostic 'move.rollback-error' @{instanceId=$InstanceId;currentRoot=$currentFull;newRoot=$newFull;error=$_.Exception.Message}}
        throw "No se pudo mover la instalacion: $failure"
    }
}

function Get-CocoLauncherInstanceLocationsPath($Paths){
    if($Paths -is [hashtable] -and $Paths.ContainsKey('InstanceLocationsPath')){return [string]$Paths['InstanceLocationsPath']}
    if($Paths-and$Paths.InstanceLocationsPath){return [string]$Paths.InstanceLocationsPath}
    return ''
}

function Set-CocoExperienceCardsEnabled($DynamicPanel,[bool]$Enabled){
    if(-not$DynamicPanel-or$DynamicPanel.IsDisposed){return}
    foreach($control in @($DynamicPanel.Controls)){
        if($control-is[Windows.Forms.Button]){$control.Enabled=$Enabled}
        if($control.Controls.Count-gt0){Set-CocoExperienceCardsEnabled $control $Enabled}
    }
}

function Get-CocoExperienceCardControls($Control){
    if(-not$Control-or$Control.IsDisposed){return}
    foreach($child in @($Control.Controls)){
        if($child-is[Windows.Forms.Panel]-and[string]$child.Name-eq'CocoExperienceCard'){$child}
        if($child.Controls.Count-gt0){Get-CocoExperienceCardControls $child}
    }
}

function Invoke-CocoExperienceStorageInstallUi($Info){
    if(-not$Info-or$script:CocoStorageInstallInProgress){return}
    $script:CocoStorageInstallInProgress=$true
    $script:CocoInstallingExperienceId=[string]$Info.ExperienceId
    $script:CocoInstallingExperienceName=[string]$Info.Name
    Write-CocoStorageDiagnostic 'install.ui.start' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;name=$Info.Name;role=$Info.Role;currentRoot=$Info.CurrentRoot;experiencesRoot=$Info.ExperiencesRoot;locationPath=(Get-CocoLauncherInstanceLocationsPath $Info.Paths)}
    try{
        Set-CocoLauncherStep 4 'INICIANDO INSTALACION' ("Preparando instalacion de {0}..."-f$Info.Name) 5
        if($Info.DynamicPanel-and-not$Info.DynamicPanel.IsDisposed){
            Update-CocoExperienceCardsUi $Info.DynamicPanel $Info.Catalog $Info.Paths $Info.Role
        }
        if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
        $locationPath=Get-CocoLauncherInstanceLocationsPath $Info.Paths
        $dummy=[pscustomobject]@{mode='offline';username='CocoPrepare';uuid=''}
        [void](Invoke-CocoManagedExperienceLaunch $Info.Catalog $Info.ExperienceId $dummy $Info.Role $Info.Paths.CatalogRoot $Info.Paths.CacheRoot $Info.Paths.ExperiencesRoot -Dry -InstanceLocationsPath $locationPath)
        Write-CocoStorageDiagnostic 'install.ui.complete' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;role=$Info.Role;locationPath=$locationPath}
        Set-CocoLauncherIdleState ("'{0}' se instalo correctamente. Ya puedes jugar."-f $Info.Name) 100
    }catch{
        Write-CocoStorageDiagnostic 'install.ui.error' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;role=$Info.Role;error=$_.Exception.Message;detail=($_|Out-String)}
        if([string]$_.Exception.Message -match 'fue cancelada'){return}
        Set-CocoLauncherIdleState 'No se pudo completar la instalacion.' 0
        if($script:CocoForm-and-not$script:CocoForm.IsDisposed){
            [Windows.Forms.MessageBox]::Show(("No se pudo instalar '{0}': {1}"-f$Info.Name,$_.Exception.Message),'Error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        }
    }finally{
        $script:CocoStorageInstallInProgress=$false
        $script:CocoInstallingExperienceId=''
        $script:CocoInstallingExperienceName=''
        if($Info.DynamicPanel-and-not$Info.DynamicPanel.IsDisposed){
            Update-CocoExperienceCardsUi $Info.DynamicPanel $Info.Catalog $Info.Paths $Info.Role
        }
        if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
    }
}

function Invoke-CocoExperienceChangeLocationUi($Info){
    if(-not$Info-or$Info.IsRunning-or$script:CocoStorageInstallInProgress){return}
    Write-CocoStorageDiagnostic 'move.ui.start' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;name=$Info.Name;role=$Info.Role;currentRoot=$Info.CurrentRoot;installed=$Info.Usage.Installed;running=$Info.IsRunning}
    $dialog=New-Object Windows.Forms.FolderBrowserDialog
    try{
        $dialog.Description=("Selecciona la carpeta donde quieres instalar {0}:"-f$Info.Name)
        $dialog.ShowNewFolderButton=$true
        $dialogResult=$dialog.ShowDialog($script:CocoForm)
        Write-CocoStorageDiagnostic 'move.ui.folder-dialog' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;dialogResult=$dialogResult;selectedPath=$dialog.SelectedPath}
        if($dialogResult-ne[Windows.Forms.DialogResult]::OK){Write-CocoStorageDiagnostic 'move.ui.cancelled' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId};return}
        $selected=[string]$dialog.SelectedPath
        if([string]::IsNullOrWhiteSpace($selected)){Write-CocoStorageDiagnostic 'move.ui.empty-selection' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId};return}
        $newRoot=Join-Path $selected $Info.InstanceId
        if($Info.Usage.Installed){
            $moveConfirm=[Windows.Forms.MessageBox]::Show(("Se encontraron archivos de '{0}' en:`r`n{1}`r`n`r`nPara cambiar la carpeta debes mover la instalacion a:`r`n{2}`r`n`r`nMover ahora?"-f$Info.Name,$Info.CurrentRoot,$newRoot),'Mover instalacion',[Windows.Forms.MessageBoxButtons]::YesNoCancel,[Windows.Forms.MessageBoxIcon]::Question)
            Write-CocoStorageDiagnostic 'move.ui.confirmation' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;confirmation=$moveConfirm;newRoot=$newRoot}
            if($moveConfirm-ne[Windows.Forms.DialogResult]::Yes){Write-CocoStorageDiagnostic 'move.ui.confirmation-denied' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId};return}
        }
        try{
            [void](Move-CocoInstalledExperience $Info.InstanceId $Info.CurrentRoot $newRoot $Info.ExperiencesRoot (Get-CocoLauncherInstanceLocationsPath $Info.Paths))
            Write-CocoStorageDiagnostic 'move.ui.complete' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;newRoot=$newRoot}
        }catch{
            Write-CocoStorageDiagnostic 'move.ui.error' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;newRoot=$newRoot;error=$_.Exception.Message;detail=($_|Out-String)}
            [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Error al mover',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
            return
        }
        Update-CocoExperienceCardsUi $Info.DynamicPanel $Info.Catalog $Info.Paths $Info.Role
    }finally{$dialog.Dispose()}
}

function Invoke-CocoExperienceFreeSpaceUi($Info){
    if(-not$Info-or-not$Info.Usage.Installed-or$Info.IsRunning-or$script:CocoStorageInstallInProgress){return}
    Write-CocoStorageDiagnostic 'delete.ui.start' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;name=$Info.Name;role=$Info.Role;instanceRoot=$Info.InstanceRoot;usage=$Info.Usage.Label;running=$Info.IsRunning}
    $confirm=[Windows.Forms.MessageBox]::Show(("Esto eliminara la instalacion de '{0}' ({1}).`r`n`r`nUbicacion: {2}`r`n`r`nLos mundos, playerdata, estadisticas y avances se respaldaran antes de liberar el espacio.`r`n`r`nContinuar?"-f$Info.Name,$Info.Usage.Label,$Info.InstanceRoot),'Liberar espacio',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
    Write-CocoStorageDiagnostic 'delete.ui.confirmation' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;confirmation=$confirm}
    if($confirm-ne[Windows.Forms.DialogResult]::Yes){Write-CocoStorageDiagnostic 'delete.ui.cancelled' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId};return}
    try{
        $backupRoot=if($Info.Paths.ExperienceBackupRoot){[string]$Info.Paths.ExperienceBackupRoot}elseif($Info.Paths.CacheRoot){Join-Path ([string]$Info.Paths.CacheRoot) 'backups\experiences'}else{''}
        $result=Remove-CocoInstalledExperience $Info.InstanceRoot $Info.ExperiencesRoot $Info.InstanceId (Get-CocoLauncherInstanceLocationsPath $Info.Paths) $backupRoot
        if($result.Removed){
            Write-CocoStorageDiagnostic 'delete.ui.complete' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;instanceRoot=$Info.InstanceRoot;backupRoot=$result.BackupRoot;freedLabel=$Info.Usage.Label}
            Update-CocoExperienceCardsUi $Info.DynamicPanel $Info.Catalog $Info.Paths $Info.Role
            $backupText=if($result.BackupRoot){"`r`nRespaldo: $($result.BackupRoot)"}else{''}
            [Windows.Forms.MessageBox]::Show(("'{0}' fue eliminado correctamente. Se libero {1}.{2}"-f$Info.Name,$Info.Usage.Label,$backupText),'Espacio liberado',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        }
    }catch{
        Write-CocoStorageDiagnostic 'delete.ui.error' @{experienceId=$Info.ExperienceId;instanceId=$Info.InstanceId;instanceRoot=$Info.InstanceRoot;error=$_.Exception.Message;detail=($_|Out-String)}
        [Windows.Forms.MessageBox]::Show(("No se pudo eliminar '{0}': {1}"-f$Info.Name,$_.Exception.Message),'Error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
    }
}

function Test-CocoMediaExperience($Experience){
    return [bool]($Experience -and [string]$Experience.runtime.type -eq 'media' -and
        [string]$Experience.content.type -in @('episodic-video','movie'))
}

function Test-CocoMovieExperience($Experience){
    return [bool]($Experience -and [string]$Experience.runtime.type -eq 'media' -and
        [string]$Experience.content.type -eq 'movie')
}

function Get-CocoMediaItems($Experience){
    if(-not(Test-CocoMediaExperience $Experience)){return @()}
    if([string]$Experience.content.type -eq 'movie'){
        if($Experience.content.movie){return @($Experience.content.movie)}
        if($Experience.content.episodes){return @($Experience.content.episodes)}
        return @()
    }
    return @($Experience.content.episodes)
}

function Get-CocoUserDownloadsRoot{
    $userProfile=[Environment]::GetFolderPath('UserProfile')
    if([string]::IsNullOrWhiteSpace($userProfile)){$userProfile=$env:USERPROFILE}
    if([string]::IsNullOrWhiteSpace($userProfile)){throw 'No se pudo resolver la carpeta del usuario para las descargas.'}
    [IO.Path]::GetFullPath((Join-Path $userProfile 'Downloads'))
}

function Get-CocoMediaDownloadRoot($Experience){
    if(-not(Test-CocoMediaExperience $Experience)){throw 'La experiencia no es contenido multimedia Coco.'}
    $folder=[string]$Experience.content.downloadFolderName
    if([string]::IsNullOrWhiteSpace($folder)-or-not(Test-CocoSafeRelativePath $folder)-or$folder.Contains('/')-or$folder.Contains('\')){
        throw "La carpeta de descargas de '$($Experience.id)' no es segura."
    }
    $downloads=Get-CocoUserDownloadsRoot
    $root=[IO.Path]::GetFullPath((Join-Path $downloads $folder))
    if(-not(Test-CocoPathWithin $root $downloads)){throw 'La carpeta de contenido debe permanecer dentro de Downloads.'}
    $root
}

function Get-CocoMediaEpisodePath($Experience,$Episode){
    $fileName=[string]$Episode.fileName
    if([string]::IsNullOrWhiteSpace($fileName)-or-not(Test-CocoSafeRelativePath $fileName)-or
       [IO.Path]::GetFileName($fileName)-ne$fileName){
        throw "El nombre del archivo multimedia '$($Episode.id)' no es seguro."
    }
    Join-Path (Get-CocoMediaDownloadRoot $Experience) $fileName
}

function Get-CocoMediaStatePath($Experience){
    Join-Path (Get-CocoMediaDownloadRoot $Experience) '.coco-media-state.json'
}

function Read-CocoMediaState($Experience){
    $path=Get-CocoMediaStatePath $Experience
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{
        Write-CocoLog "MEDIA [$([string]$Experience.name)]: estado de media ilegible; se ignorara sin tocar videos: $($_.Exception.Message)"
        return $null
    }
}

function Get-CocoMediaEpisodeLocalStatus($Experience,$Episode){
    $path=Get-CocoMediaEpisodePath $Experience $Episode
    $partial="$path.partial"
    $expectedSize=[int64]$Episode.size
    $state=Read-CocoMediaState $Experience
    $record=$null
    if($state-and$state.episodes){$record=@($state.episodes|Where-Object{[string]$_.id-eq[string]$Episode.id}|Select-Object -First 1)[0]}
    $result=[ordered]@{
        Status='missing';Path=$path;PartialPath=$partial;Bytes=[int64]0;PartialBytes=[int64]0;ExpectedSize=$expectedSize
        LastWriteUtc='';StateRecord=$record
    }
    if(Test-Path -LiteralPath $path -PathType Leaf){
        $item=Get-Item -LiteralPath $path -Force
        $result.Bytes=[int64]$item.Length
        $result.LastWriteUtc=$item.LastWriteTimeUtc.ToString('o')
        if($item.Length-ne$expectedSize){$result.Status='mismatch'}
        elseif($record-and[string]$record.sha256-eq([string]$Episode.sha256).ToLowerInvariant()-and
               [int64]$record.size-eq$expectedSize-and[string]$record.lastWriteUtc-eq[string]$result.LastWriteUtc){$result.Status='verified'}
        else{$result.Status='present'}
    }
    if(Test-Path -LiteralPath $partial -PathType Leaf){$result.PartialBytes=[int64](Get-Item -LiteralPath $partial -Force).Length;if($result.Status-eq'missing'){$result.Status='partial'}}
    [pscustomobject]$result
}

function Get-CocoMediaExperienceStatus($Experience){
    $episodes=@(Get-CocoMediaItems $Experience)
    $states=@($episodes|ForEach-Object{Get-CocoMediaEpisodeLocalStatus $Experience $_})
    $isMovie=Test-CocoMovieExperience $Experience
    [pscustomobject]@{
        Root=Get-CocoMediaDownloadRoot $Experience
        Total=$episodes.Count
        Verified=@($states|Where-Object Status-eq'verified').Count
        Present=@($states|Where-Object Status-eq'present').Count
        Partial=@($states|Where-Object Status-eq'partial').Count
        Bytes=[int64](($states|Measure-Object -Property Bytes -Sum).Sum)
        States=$states
        IsMovie=$isMovie
    }
}

function Write-CocoMediaState($Experience,$Episode,[string]$LastWriteUtc=''){
    $root=Get-CocoMediaDownloadRoot $Experience
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $statePath=Join-Path $root '.coco-media-state.json'
    $existing=Read-CocoMediaState $Experience
    $records=@();$previous=$null
    if($existing-and$existing.episodes){$previous=@($existing.episodes|Where-Object{[string]$_.id-eq[string]$Episode.id}|Select-Object -First 1)[0];$records=@($existing.episodes|Where-Object{[string]$_.id-ne[string]$Episode.id})}
    if([string]::IsNullOrWhiteSpace($LastWriteUtc)-and(Test-Path -LiteralPath (Get-CocoMediaEpisodePath $Experience $Episode) -PathType Leaf)){
        $LastWriteUtc=(Get-Item -LiteralPath (Get-CocoMediaEpisodePath $Experience $Episode) -Force).LastWriteTimeUtc.ToString('o')
    }
    $newRecord=[ordered]@{
        id=[string]$Episode.id;fileName=[string]$Episode.fileName;size=[int64]$Episode.size
        sha256=([string]$Episode.sha256).ToLowerInvariant();lastWriteUtc=$LastWriteUtc;verifiedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    foreach($name in 'positionSeconds','durationSeconds','playbackUpdatedAtUtc','completed'){
        if($previous-and$previous.PSObject.Properties.Name-contains$name){$newRecord[$name]=$previous.$name}
    }
    $records+=,[pscustomobject]$newRecord
    $payload=[ordered]@{schemaVersion=1;updatedAtUtc=[DateTime]::UtcNow.ToString('o');episodes=$records}
    $temporary="$statePath.tmp-$PID"
    try{
        [IO.File]::WriteAllText($temporary,($payload|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $statePath -Force
    }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}

function Get-CocoMediaPlaybackState($Experience,$Episode){
    $state=Read-CocoMediaState $Experience;$record=$null
    if($state-and$state.episodes){$record=@($state.episodes|Where-Object{[string]$_.id-eq[string]$Episode.id}|Select-Object -First 1)[0]}
    [pscustomobject]@{
        PositionSeconds=if($record-and$record.PSObject.Properties.Name-contains'positionSeconds'){[double]$record.positionSeconds}else{0.0}
        DurationSeconds=if($record-and$record.PSObject.Properties.Name-contains'durationSeconds'){[double]$record.durationSeconds}else{0.0}
        UpdatedAtUtc=if($record-and$record.PSObject.Properties.Name-contains'playbackUpdatedAtUtc'){[string]$record.playbackUpdatedAtUtc}else{''}
        Completed=if($record-and$record.PSObject.Properties.Name-contains'completed'){[bool]$record.completed}else{$false}
    }
}

function Write-CocoMediaPlaybackState($Experience,$Episode,[double]$PositionSeconds,[double]$DurationSeconds,[bool]$Completed=$false){
    $root=Get-CocoMediaDownloadRoot $Experience;New-Item -ItemType Directory -Path $root -Force|Out-Null
    $statePath=Join-Path $root '.coco-media-state.json';$existing=Read-CocoMediaState $Experience;$records=@()
    if($existing-and$existing.episodes){$records=@($existing.episodes)}
    $record=@($records|Where-Object{[string]$_.id-eq[string]$Episode.id}|Select-Object -First 1)[0]
    if(-not$record){
        $record=[pscustomobject]@{id=[string]$Episode.id;fileName=[string]$Episode.fileName;size=[int64]$Episode.size;sha256=([string]$Episode.sha256).ToLowerInvariant();lastWriteUtc='';verifiedAtUtc=''}
        $records+=,$record
    }
    if(-not($record.PSObject.Properties.Name-contains'positionSeconds')){$record|Add-Member NoteProperty positionSeconds 0.0}
    if(-not($record.PSObject.Properties.Name-contains'durationSeconds')){$record|Add-Member NoteProperty durationSeconds 0.0}
    if(-not($record.PSObject.Properties.Name-contains'playbackUpdatedAtUtc')){$record|Add-Member NoteProperty playbackUpdatedAtUtc ''}
    if(-not($record.PSObject.Properties.Name-contains'completed')){$record|Add-Member NoteProperty completed $false}
    $record.positionSeconds=[Math]::Max(0.0,$PositionSeconds);$record.durationSeconds=[Math]::Max(0.0,$DurationSeconds);$record.playbackUpdatedAtUtc=[DateTime]::UtcNow.ToString('o');$record.completed=[bool]$Completed
    $payload=[ordered]@{schemaVersion=1;updatedAtUtc=[DateTime]::UtcNow.ToString('o');episodes=$records};$temporary="$statePath.tmp-$PID"
    try{[IO.File]::WriteAllText($temporary,($payload|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));Move-Item -LiteralPath $temporary -Destination $statePath -Force}finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}

function Invoke-CocoMediaPumpUi{
    if($script:CocoMediaDialog-and$script:CocoMediaDialog.IsDisposed){$script:CocoMediaCancelRequested=$true}
    try{[Windows.Forms.Application]::DoEvents()}catch{}
    if($script:CocoMediaCancelRequested){throw 'La operacion de Heart Signal fue cancelada.'}
}

function Set-CocoMediaUiStatus([string]$Text,[int]$Percent=0){
    $Percent=[Math]::Max(0,[Math]::Min(100,$Percent))
    if($script:CocoMediaProgressBar-and-not$script:CocoMediaProgressBar.IsDisposed){
        if($script:CocoMediaProgressBar -is [Windows.Forms.ProgressBar]){$script:CocoMediaProgressBar.Value=$Percent}
        else{$script:CocoMediaProgressBar.Tag=$Percent;$script:CocoMediaProgressBar.Invalidate()}
    }
    if($script:CocoMediaStatusLabel-and-not$script:CocoMediaStatusLabel.IsDisposed){$script:CocoMediaStatusLabel.Text=$Text}
    Invoke-CocoMediaPumpUi
}

function Format-CocoMediaBytes([int64]$Bytes){
    if($Bytes-ge1GB){'{0:N2} GB'-f($Bytes/1GB)}elseif($Bytes-ge1MB){'{0:N0} MB'-f($Bytes/1MB)}elseif($Bytes-ge1KB){'{0:N0} KB'-f($Bytes/1KB)}else{'{0} B'-f$Bytes}
}

function Format-CocoMediaTime([double]$Seconds){
    if([double]::IsNaN($Seconds)-or[double]::IsInfinity($Seconds)){$Seconds=0}
    $span=[TimeSpan]::FromSeconds([Math]::Max(0,$Seconds))
    if($span.TotalHours-ge1){$span.ToString('h\:mm\:ss')}else{$span.ToString('mm\:ss')}
}

function Get-CocoMediaFileSha256([string]$Path,[string]$Title='Verificando archivo',[int]$ProgressStart=0,[int]$ProgressEnd=100){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "No existe el archivo de media: $Path"}
    $item=Get-Item -LiteralPath $Path -Force;$total=[int64]$item.Length;$readTotal=[int64]0
    $sha=[Security.Cryptography.SHA256]::Create();$stream=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $buffer=New-Object byte[] (4MB);$lastUi=[DateTime]::MinValue
        while(($read=$stream.Read($buffer,0,$buffer.Length))-gt0){
            [void]$sha.TransformBlock($buffer,0,$read,$buffer,0);$readTotal+=$read
            $now=[DateTime]::UtcNow
            if(($now-$lastUi).TotalMilliseconds-ge200-or$readTotal-eq$total){
                $lastUi=$now;$pct=if($total-gt0){$ProgressStart+[int](($ProgressEnd-$ProgressStart)*$readTotal/$total)}else{$ProgressEnd}
                Set-CocoMediaUiStatus ("{0}: {1} / {2}"-f$Title,(Format-CocoMediaBytes $readTotal),(Format-CocoMediaBytes $total)) $pct
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
    }finally{if($stream){$stream.Dispose()};$sha.Dispose()}
}

function Wait-CocoMediaRetry([int]$Seconds){
    $until=[DateTime]::UtcNow.AddSeconds($Seconds)
    while([DateTime]::UtcNow-lt$until){Invoke-CocoMediaPumpUi;Start-Sleep -Milliseconds 250}
}

function Invoke-CocoMediaHttpDownload($Experience,$Episode,[string]$Destination){
    $url=[string]$Episode.sourceUrl
    if($url-notmatch'^https://'){throw "El episodio '$($Episode.id)' aun no tiene un asset HTTPS publicado."}
    $parent=Split-Path $Destination -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $partial="$Destination.partial";$expectedSize=[int64]$Episode.size;$expectedHash=([string]$Episode.sha256).ToLowerInvariant()
    for($attempt=1;$attempt-le4;$attempt++){
        $resumeBytes=if(Test-Path -LiteralPath $partial -PathType Leaf){[int64](Get-Item -LiteralPath $partial -Force).Length}else{[int64]0}
        if($resumeBytes-gt$expectedSize){Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue;$resumeBytes=0}
        $request=$null;$response=$null;$input=$null;$output=$null;$responseStatus=0;$hashMismatch=$false
        try{
            $request=[Net.HttpWebRequest]::Create($url);$request.UserAgent='CocoLauncher/HeartSignal';$request.Timeout=30000;$request.ReadWriteTimeout=30000
            if($resumeBytes-gt0){$request.AddRange($resumeBytes)}
            $response=$request.GetResponse();$responseStatus=[int]$response.StatusCode
            $resumed=$resumeBytes-gt0-and$response.StatusCode-eq[Net.HttpStatusCode]::PartialContent
            if($resumeBytes-gt0-and-not$resumed){Write-CocoLog "HEART SIGNAL: el asset no acepto el rango; se reinicia el parcial."}
            $total=[int64]$response.ContentLength
            if($resumed){$total+=$resumeBytes}else{$resumeBytes=0}
            if($total-le0){$total=$expectedSize}
            $input=$response.GetResponseStream()
            $output=if($resumed){[IO.File]::Open($partial,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)}else{[IO.File]::Create($partial)}
            $received=$resumeBytes;$watch=[Diagnostics.Stopwatch]::StartNew();$lastUi=[DateTime]::MinValue
            Write-CocoLog "HEART SIGNAL: descarga intento=$attempt; reanudada=$resumed; bytesIniciales=$resumeBytes; destino=$Destination"
            $buffer=New-Object byte[] (4MB)
            while(($read=$input.Read($buffer,0,$buffer.Length))-gt0){
                Invoke-CocoMediaPumpUi; $output.Write($buffer,0,$read);$received+=$read
                $now=[DateTime]::UtcNow
                if(($now-$lastUi).TotalMilliseconds-ge200-or$received-eq$total){
                    $lastUi=$now;$pct=if($expectedSize-gt0){[int](75*$received/$expectedSize)}else{50}
                    $speed=if($watch.Elapsed.TotalSeconds-gt0){$received/$watch.Elapsed.TotalSeconds}else{0}
                    $eta=if($speed-gt0){[TimeSpan]::FromSeconds([Math]::Max(0,($expectedSize-$received)/$speed))}else{[TimeSpan]::Zero}
                    Set-CocoMediaUiStatus ("Descargando: {0} / {1} | {2:N1} MB/s | faltan ~{3}"-f(Format-CocoMediaBytes $received),(Format-CocoMediaBytes $expectedSize),($speed/1MB),(Format-CocoMediaTime $eta.TotalSeconds)) $pct
                }
            }
            if($received-ne$expectedSize){throw "La descarga termino incompleta: $received de $expectedSize bytes."}
            $actual=Get-CocoMediaFileSha256 $partial 'Verificando SHA-256' 76 96
            if($actual-ne$expectedHash){$hashMismatch=$true;throw "El episodio '$($Episode.id)' no coincide con el SHA-256 publicado."}
            if(Test-Path -LiteralPath $Destination -PathType Leaf){
                $preserved="$Destination.coco-replaced-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Move-Item -LiteralPath $Destination -Destination $preserved -Force
                Write-CocoLog "HEART SIGNAL: archivo anterior preservado en $preserved"
            }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Write-CocoMediaState $Experience $Episode
            Set-CocoMediaUiStatus 'Descarga y verificacion completadas.' 100
            return $Destination
        }catch{
            if($script:CocoMediaCancelRequested){throw 'La operacion de Heart Signal fue cancelada.'}
            if($hashMismatch-or$responseStatus-eq416){Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue}
            if($attempt-eq4){throw}
            Write-CocoLog "HEART SIGNAL: fallo de descarga intento=${attempt}: $($_.Exception.Message)"
            Set-CocoMediaUiStatus ("Reintentando descarga (intento {0}/4); se conserva el parcial."-f($attempt+1)) 75
            Wait-CocoMediaRetry ([int][Math]::Pow(2,$attempt-1))
        }finally{if($output){$output.Dispose()};if($input){$input.Dispose()};if($response){$response.Dispose()}}
    }
}

function Test-CocoMediaEpisodeFile($Experience,$Episode,[switch]$RecordVerifiedState){
    $status=Get-CocoMediaEpisodeLocalStatus $Experience $Episode
    if(-not(Test-Path -LiteralPath $status.Path -PathType Leaf)){return [pscustomobject]@{Exists=$false;Matches=$false;Path=$status.Path;Status=$status.Status;ActualHash='';ExpectedHash=[string]$Episode.sha256}}
    if([int64]$status.Bytes-ne[int64]$Episode.size){return [pscustomobject]@{Exists=$true;Matches=$false;Path=$status.Path;Status='mismatch';ActualHash='';ExpectedHash=[string]$Episode.sha256}}
    $actual=Get-CocoMediaFileSha256 $status.Path 'Verificando episodio' 5 95
    $matches=[string]::Equals($actual,([string]$Episode.sha256).ToLowerInvariant(),[StringComparison]::OrdinalIgnoreCase)
    if($matches-and$RecordVerifiedState){Write-CocoMediaState $Experience $Episode (Get-Item -LiteralPath $status.Path -Force).LastWriteTimeUtc.ToString('o')}
    [pscustomobject]@{Exists=$true;Matches=$matches;Path=$status.Path;Status=if($matches){'verified'}else{'mismatch'};ActualHash=$actual;ExpectedHash=([string]$Episode.sha256).ToLowerInvariant()}
}

function Get-CocoMediaContentType([string]$FileName){
    switch([IO.Path]::GetExtension($FileName).ToLowerInvariant()){
        '.mp4' {'video/mp4';break}
        '.m4v' {'video/mp4';break}
        '.mkv' {'video/x-matroska';break}
        '.webm' {'video/webm';break}
        default {'application/octet-stream'}
    }
}

if(-not('CocoMediaHttpProxyServer' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Collections.Concurrent;

public sealed class CocoMediaHttpProxyServer : IDisposable
{
    private readonly TcpListener listener;
    private readonly string upstreamUrl;
    private readonly string routeToken;
    private readonly string mimeType;
    private readonly string mediaExtension;
    private readonly CancellationTokenSource cts = new CancellationTokenSource();
    private readonly ConcurrentDictionary<int, IDisposable> activeRequests = new ConcurrentDictionary<int, IDisposable>();
    private int requestIdCounter = 0;
    private bool disposed = false;

    public int Port { get; private set; }
    public string Url { get; private set; }
    public string RemoteUrl { get { return upstreamUrl; } }
    public string Token { get { return routeToken; } }

    public CocoMediaHttpProxyServer(string upstreamUrl, string fileName)
    {
        if (string.IsNullOrEmpty(upstreamUrl) || !upstreamUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("El streaming remoto de media debe usar HTTPS.", "upstreamUrl");

        this.upstreamUrl = upstreamUrl;
        this.routeToken = Guid.NewGuid().ToString("N");

        string ext = Path.GetExtension(fileName ?? "").ToLowerInvariant();
        if (!Regex.IsMatch(ext, @"^\.(mp4|m4v|mkv|webm)$"))
            ext = ".bin";
        this.mediaExtension = ext;

        switch (ext)
        {
            case ".mp4": case ".m4v": this.mimeType = "video/mp4"; break;
            case ".mkv": this.mimeType = "video/x-matroska"; break;
            case ".webm": this.mimeType = "video/webm"; break;
            default: this.mimeType = "application/octet-stream"; break;
        }

        ServicePointManager.DefaultConnectionLimit = Math.Max(ServicePointManager.DefaultConnectionLimit, 64);
        this.listener = new TcpListener(IPAddress.Loopback, 0);
        this.listener.Start();
        this.Port = ((IPEndPoint)this.listener.LocalEndpoint).Port;
        this.Url = string.Format("http://127.0.0.1:{0}/coco-media/{1}/media{2}", this.Port, this.routeToken, this.mediaExtension);

        ThreadPool.QueueUserWorkItem(AcceptLoop);
    }

    private void AcceptLoop(object state)
    {
        while (!disposed && !cts.IsCancellationRequested)
        {
            try
            {
                TcpClient client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(ClientWorker, client);
            }
            catch
            {
                if (disposed) break;
            }
        }
    }

    private void ClientWorker(object state)
    {
        TcpClient client = (TcpClient)state;
        int reqId = Interlocked.Increment(ref requestIdCounter);
        HttpWebResponse upstreamResponse = null;
        NetworkStream clientStream = null;

        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 30000;
            client.SendTimeout = 30000;
            clientStream = client.GetStream();

            StreamReader reader = new StreamReader(clientStream, Encoding.ASCII, false, 8192, true);
            string requestLine = reader.ReadLine();
            if (string.IsNullOrEmpty(requestLine)) return;

            string[] parts = requestLine.Split(' ');
            if (parts.Length < 2) { SendError(clientStream, 400, "Bad Request", "Solicitud HTTP invalida."); return; }

            string method = parts[0].ToUpperInvariant();
            string requestPath = parts[1];

            string rangeHeader = null;
            string line;
            while (!string.IsNullOrEmpty(line = reader.ReadLine()))
            {
                int colon = line.IndexOf(':');
                if (colon > 0)
                {
                    string headerName = line.Substring(0, colon).Trim();
                    string headerVal = line.Substring(colon + 1).Trim();
                    if (string.Equals(headerName, "Range", StringComparison.OrdinalIgnoreCase))
                    {
                        rangeHeader = headerVal;
                    }
                }
            }

            string expectedPath = string.Format("/coco-media/{0}/media{1}", routeToken, mediaExtension);
            if (!string.Equals(requestPath, expectedPath, StringComparison.OrdinalIgnoreCase))
            {
                SendError(clientStream, 404, "Not Found", "Ruta de media no encontrada.");
                return;
            }

            if (method != "GET" && method != "HEAD")
            {
                SendError(clientStream, 405, "Method Not Allowed", "Solo se admite GET o HEAD.");
                return;
            }

            bool hasRange = false;
            long rangeStart = 0;
            long rangeEnd = -1;

            if (!string.IsNullOrEmpty(rangeHeader))
            {
                Match m = Regex.Match(rangeHeader, @"^bytes=(\d+)-(\d*)$");
                if (m.Success)
                {
                    hasRange = true;
                    rangeStart = long.Parse(m.Groups[1].Value);
                    if (!string.IsNullOrEmpty(m.Groups[2].Value))
                    {
                        rangeEnd = long.Parse(m.Groups[2].Value);
                    }
                }
                else
                {
                    SendError(clientStream, 416, "Range Not Satisfiable", "Solo se admite un rango HTTP simple.");
                    return;
                }
            }

            HttpWebRequest upstreamRequest = (HttpWebRequest)WebRequest.Create(upstreamUrl);
            upstreamRequest.Method = method;
            upstreamRequest.UserAgent = "CocoLauncher/HeartSignal";
            upstreamRequest.AllowAutoRedirect = true;
            upstreamRequest.KeepAlive = false;
            upstreamRequest.Timeout = 30000;
            upstreamRequest.ReadWriteTimeout = 30000;

            if (hasRange)
            {
                if (rangeEnd >= rangeStart) upstreamRequest.AddRange(rangeStart, rangeEnd);
                else upstreamRequest.AddRange(rangeStart);
            }

            try
            {
                upstreamResponse = (HttpWebResponse)upstreamRequest.GetResponse();
            }
            catch (WebException wex)
            {
                HttpWebResponse remoteResp = wex.Response as HttpWebResponse;
                if (remoteResp != null)
                {
                    SendError(clientStream, (int)remoteResp.StatusCode, remoteResp.StatusDescription, "El asset remoto rechazo la solicitud.");
                    remoteResp.Dispose();
                    return;
                }
                SendError(clientStream, 502, "Bad Gateway", "No se pudo conectar con el asset remoto.");
                return;
            }

            activeRequests[reqId] = upstreamResponse;

            int upstreamStatus = (int)upstreamResponse.StatusCode;
            if (hasRange && upstreamStatus != 206)
            {
                SendError(clientStream, 502, "Bad Gateway", string.Format("El asset remoto no devolvio contenido parcial (HTTP {0}).", upstreamStatus));
                return;
            }

            long length = upstreamResponse.ContentLength;
            if (length < 0)
            {
                SendError(clientStream, 502, "Bad Gateway", "El asset remoto no informo Content-Length.");
                return;
            }

            string statusLine = (upstreamStatus == 206) ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK";
            StringBuilder respHeaders = new StringBuilder();
            respHeaders.Append(statusLine).Append("\r\n");
            respHeaders.Append("Content-Type: ").Append(mimeType).Append("\r\n");
            respHeaders.Append("Accept-Ranges: bytes\r\n");
            respHeaders.Append("Cache-Control: no-store\r\n");
            respHeaders.Append("Connection: close\r\n");
            respHeaders.Append("Content-Length: ").Append(length).Append("\r\n");

            string contentRange = upstreamResponse.Headers["Content-Range"];
            if (!string.IsNullOrEmpty(contentRange))
            {
                respHeaders.Append("Content-Range: ").Append(contentRange).Append("\r\n");
            }
            respHeaders.Append("\r\n");

            byte[] headerBytes = Encoding.ASCII.GetBytes(respHeaders.ToString());
            clientStream.Write(headerBytes, 0, headerBytes.Length);

            if (method == "HEAD") return;

            using (Stream upStream = upstreamResponse.GetResponseStream())
            {
                byte[] buffer = new byte[65536];
                int read;
                while (!disposed && !cts.IsCancellationRequested && (read = upStream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    clientStream.Write(buffer, 0, read);
                }
            }
        }
        catch
        {
            // Client closed connection or seek occurred
        }
        finally
        {
            IDisposable disp;
            activeRequests.TryRemove(reqId, out disp);
            if (upstreamResponse != null) try { upstreamResponse.Dispose(); } catch { }
            if (clientStream != null) try { clientStream.Dispose(); } catch { }
            if (client != null) try { client.Close(); } catch { }
        }
    }

    private static void SendError(Stream stream, int code, string reason, string message)
    {
        try
        {
            byte[] body = Encoding.UTF8.GetBytes(message ?? "");
            string header = string.Format(
                "HTTP/1.1 {0} {1}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {2}\r\n\r\n",
                code, reason, body.Length);
            byte[] hBytes = Encoding.ASCII.GetBytes(header);
            stream.Write(hBytes, 0, hBytes.Length);
            if (body.Length > 0) stream.Write(body, 0, body.Length);
        }
        catch { }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        cts.Cancel();
        try { listener.Stop(); } catch { }
        foreach (var kvp in activeRequests)
        {
            try { kvp.Value.Dispose(); } catch { }
        }
        activeRequests.Clear();
    }
}
'@
}

function Start-CocoMediaHttpProxy([string]$RemoteUrl,[string]$FileName){
    if($RemoteUrl-notmatch'^https://'){throw 'El streaming remoto de media debe usar HTTPS.'}
    $extension=[IO.Path]::GetExtension($FileName).ToLowerInvariant()
    if($extension-notmatch'^\.(mp4|m4v|mkv|webm)$'){$extension='.bin'}
    $server=[CocoMediaHttpProxyServer]::new($RemoteUrl,$FileName)
    [pscustomobject]@{Server=$server;Job=$null;Port=$server.Port;Token=$server.Token;Url=$server.Url;RemoteUrl=$server.RemoteUrl}
}

function Stop-CocoMediaHttpProxy($Proxy){
    if(-not$Proxy){return}
    if($Proxy.Server){try{$Proxy.Server.Dispose()}catch{}}
    if($Proxy.Job){
        try{Stop-Job -Job $Proxy.Job -ErrorAction SilentlyContinue}catch{}
        try{Remove-Job -Job $Proxy.Job -Force -ErrorAction SilentlyContinue}catch{}
    }
}

function Set-CocoMediaButtonStyle($Button,[Drawing.Color]$BackColor,[Drawing.Color]$ForeColor,[Drawing.Color]$HoverColor){
    if(-not$Button){return}
    if($HoverColor.IsEmpty){$HoverColor=[Drawing.Color]::FromArgb([Math]::Min(255,$BackColor.R+18),[Math]::Min(255,$BackColor.G+18),[Math]::Min(255,$BackColor.B+18))}
    $Button.FlatStyle=[Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize=0
    $Button.FlatAppearance.MouseOverBackColor=$HoverColor
    $Button.FlatAppearance.MouseDownBackColor=[Drawing.Color]::FromArgb([Math]::Max(0,$BackColor.R-12),[Math]::Max(0,$BackColor.G-12),[Math]::Max(0,$BackColor.B-12))
    $Button.UseVisualStyleBackColor=$false
    $Button.BackColor=$BackColor
    $Button.ForeColor=$ForeColor
    $Button.Cursor=[Windows.Forms.Cursors]::Hand
    $Button.Margin=New-Object Windows.Forms.Padding(0)
    $Button.Padding=New-Object Windows.Forms.Padding(0)
    $Button.Font=New-Object Drawing.Font('Segoe UI Semibold',9)
    $Button.UseCompatibleTextRendering=$true
}

function Invoke-CocoMediaPlayerUi($Experience,$Episode,[string]$Source=''){
    if([string]::IsNullOrWhiteSpace($Source)){$Source=[string]$Episode.streamUrl}
    if([string]::IsNullOrWhiteSpace($Source)){throw 'No existe una fuente de reproduccion para este episodio.'}
    if($Source-notmatch'^(https://|[a-zA-Z]:[\\/])'){throw 'La fuente de reproduccion no usa HTTPS ni una ruta local valida.'}
    $formatTimeCommand=(Get-Command Format-CocoMediaTime -ErrorAction Stop).ScriptBlock
    $writePlaybackCommand=(Get-Command Write-CocoMediaPlaybackState -ErrorAction Stop).ScriptBlock
    $logCommand=(Get-Command Write-CocoLog -ErrorAction SilentlyContinue).ScriptBlock
    try{
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName WindowsBase
        Add-Type -AssemblyName WindowsFormsIntegration
    }catch{throw "Windows no pudo cargar el reproductor integrado: $($_.Exception.Message)"}
    $mediaExperienceName=if([string]::IsNullOrWhiteSpace([string]$Experience.name)){'COCO VIDEO'}else{[string]$Experience.name}
    $isMovie=Test-CocoMovieExperience $Experience
    $form=New-Object Windows.Forms.Form;$form.Text=if($isMovie){[string]$Episode.title}else{("{0} - {1}"-f$mediaExperienceName,[string]$Episode.title)};$form.StartPosition='CenterParent';$form.FormBorderStyle='None';$form.MinimizeBox=$false;$form.MaximizeBox=$false;$form.KeyPreview=$true;$form.BackColor=[Drawing.Color]::FromArgb(53,35,67);$form.Padding=New-Object Windows.Forms.Padding(1);$form.ClientSize=New-Object Drawing.Size(1000,650);$form.MinimumSize=New-Object Drawing.Size(640,420)
    $chrome=New-Object Windows.Forms.Panel;$chrome.Name='CocoMediaHeader';$chrome.Dock='Top';$chrome.Height=46;$chrome.BackColor=[Drawing.Color]::FromArgb(27,19,38)
    $accent=New-Object Windows.Forms.Panel;$accent.Name='CocoMediaHeaderAccent';$accent.Dock='Left';$accent.Width=4;$accent.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $titleLabel=New-Object Windows.Forms.Label;$titleLabel.Name='CocoMediaTitle';$titleLabel.Text=$mediaExperienceName.ToUpperInvariant();$titleLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',11);$titleLabel.ForeColor=[Drawing.Color]::White;$titleLabel.AutoEllipsis=$true
    $subtitleLabel=New-Object Windows.Forms.Label;$subtitleLabel.Name='CocoMediaSubtitle';$subtitleLabel.Text=if($isMovie){[string]$Episode.title}else{("Episodio {0}"-f[string]$Episode.title)};$subtitleLabel.Font=New-Object Drawing.Font('Segoe UI',8);$subtitleLabel.ForeColor=[Drawing.Color]::FromArgb(177,162,193);$subtitleLabel.AutoEllipsis=$true
    $statusLabel=New-Object Windows.Forms.Label;$statusLabel.Name='CocoMediaStatus';$statusLabel.Text='Cargando video...';$statusLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',8);$statusLabel.ForeColor=[Drawing.Color]::FromArgb(168,236,168);$statusLabel.TextAlign='MiddleRight';$statusLabel.AutoEllipsis=$true
    $minimize=New-Object Windows.Forms.Button;$minimize.Name='CocoMediaMinimizeButton';$minimize.Text='-';$minimize.AccessibleName='Minimizar';$minimize.Font=New-Object Drawing.Font('Segoe UI',12);Set-CocoMediaButtonStyle $minimize ([Drawing.Color]::FromArgb(27,19,38)) ([Drawing.Color]::FromArgb(218,210,229)) ([Drawing.Color]::FromArgb(53,35,67))
    $close=New-Object Windows.Forms.Button;$close.Name='CocoMediaCloseButton';$close.Text='X';$close.AccessibleName='Cerrar';$close.Font=New-Object Drawing.Font('Segoe UI Semibold',10);Set-CocoMediaButtonStyle $close ([Drawing.Color]::FromArgb(27,19,38)) ([Drawing.Color]::FromArgb(218,210,229)) ([Drawing.Color]::FromArgb(150,48,70))
    $chrome.Controls.AddRange(@($accent,$titleLabel,$subtitleLabel,$minimize,$close))
    $videoHost=New-Object Windows.Forms.Integration.ElementHost;$videoHost.Name='CocoMediaVideoHost';$videoHost.Dock='Fill';$videoHost.BackColor=[Drawing.Color]::Black
    $media=New-Object System.Windows.Controls.MediaElement;$media.LoadedBehavior='Manual';$media.UnloadedBehavior='Manual';$media.Stretch='Uniform';$media.Volume=1.0;$media.ScrubbingEnabled=$true;$media.Focusable=$true
    $videoHost.Child=$media
    $controls=New-Object Windows.Forms.Panel;$controls.Name='CocoMediaControlPanel';$controls.Dock='Bottom';$controls.Height=68;$controls.BackColor=[Drawing.Color]::FromArgb(27,19,38)
    $controlLine=New-Object Windows.Forms.Panel;$controlLine.Name='CocoMediaControlLine';$controlLine.Dock='Top';$controlLine.Height=1;$controlLine.BackColor=[Drawing.Color]::FromArgb(72,52,91)
    $play=New-Object Windows.Forms.Button;$play.Name='CocoMediaPlayButton';$play.Text='PAUSAR';$play.AccessibleName='Pausar o reproducir';$play.Size=New-Object Drawing.Size(112,36);Set-CocoMediaButtonStyle $play ([Drawing.Color]::FromArgb(177,92,255)) ([Drawing.Color]::White) ([Drawing.Color]::FromArgb(196,121,255))
    $position=New-Object Windows.Forms.Label;$position.Name='CocoMediaPosition';$position.Text='00:00 / --:--';$position.TextAlign='MiddleCenter';$position.Font=New-Object Drawing.Font('Segoe UI Semibold',8.5);$position.BackColor=[Drawing.Color]::FromArgb(38,27,52);$position.ForeColor=[Drawing.Color]::FromArgb(235,228,241)
    $seek=New-Object Windows.Forms.Panel;$seek.Name='CocoMediaSeekBar';$seek.TabStop=$true;$seek.Cursor=[Windows.Forms.Cursors]::Hand;$seek.BackColor=[Drawing.Color]::FromArgb(27,19,38);$seek.AccessibleName='Posicion del video';$seek.AccessibleRole=[Windows.Forms.AccessibleRole]::Slider
    $volumeLabel=New-Object Windows.Forms.Label;$volumeLabel.Name='CocoMediaVolumeLabel';$volumeLabel.Text='VOL';$volumeLabel.TextAlign='MiddleCenter';$volumeLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',7.5);$volumeLabel.ForeColor=[Drawing.Color]::FromArgb(177,162,193)
    $volume=New-Object Windows.Forms.Panel;$volume.Name='CocoMediaVolumeBar';$volume.TabStop=$true;$volume.Cursor=[Windows.Forms.Cursors]::Hand;$volume.BackColor=[Drawing.Color]::FromArgb(27,19,38);$volume.AccessibleName='Volumen';$volume.AccessibleRole=[Windows.Forms.AccessibleRole]::Slider
    $fullscreen=New-Object Windows.Forms.Button;$fullscreen.Name='CocoMediaFullscreenButton';$fullscreen.Text='PANTALLA COMPLETA';$fullscreen.AccessibleName='Pantalla completa';$fullscreen.Font=New-Object Drawing.Font('Segoe UI Semibold',8);$fullscreen.TextAlign='MiddleCenter';$fullscreen.Size=New-Object Drawing.Size(174,36);Set-CocoMediaButtonStyle $fullscreen ([Drawing.Color]::FromArgb(38,27,52)) ([Drawing.Color]::FromArgb(235,228,241)) ([Drawing.Color]::FromArgb(67,46,88))
    $toolTip=New-Object Windows.Forms.ToolTip;$toolTip.AutoPopDelay=4000;$toolTip.InitialDelay=400;$toolTip.ReshowDelay=100
    $toolTip.SetToolTip($play,'Pausar / reproducir (Espacio / K)');$toolTip.SetToolTip($fullscreen,'Pantalla completa (F11 / Esc)');$toolTip.SetToolTip($seek,'Busca una posicion (Flechas Izq/Der, J/L: +-10s, 0-9: saltar %)');$toolTip.SetToolTip($volume,'Volumen (Flechas Arriba/Abajo, rueda del raton, M: silenciar)')
    $statusLabel.TextAlign='MiddleLeft';$statusLabel.BackColor=[Drawing.Color]::FromArgb(38,27,52);$statusLabel.Padding=New-Object Windows.Forms.Padding(10,0,6,0)
    $controls.Controls.AddRange(@($controlLine,$play,$statusLabel,$position,$seek,$volumeLabel,$volume,$fullscreen));$form.Controls.Add($videoHost);$form.Controls.Add($controls);$form.Controls.Add($chrome)
    $savedPlayback=Get-CocoMediaPlaybackState $Experience $Episode
    $state=[pscustomobject]@{Duration=0.0;Seeking=$false;SeekPreviewSeconds=0.0;Volume=1.0;PreviousVolume=1.0;Fullscreen=$false;Started=$false;MediaReady=$false;Completed=[bool]$savedPlayback.Completed;ResumeSeconds=[double]$savedPlayback.PositionSeconds;ResumeApplied=$false;LastSavedUtc=[DateTime]::MinValue;ClosingSaved=$false;LastFullscreenToggleUtc=[DateTime]::MinValue;PreviousFormBorderStyle=$form.FormBorderStyle;PreviousWindowState=$form.WindowState;PreviousBounds=$form.Bounds;PreviousPadding=$form.Padding;PreviousTopMost=$form.TopMost;CursorHidden=$false;LastMouseMoveUtc=[DateTime]::UtcNow}
    $formatTime={param([double]$Seconds)&$formatTimeCommand $Seconds}.GetNewClosure()
    $layoutChrome={
        $width=[Math]::Max(1,[int]$chrome.ClientSize.Width)
        $titleWidth=[Math]::Max(220,$width-110);$titleLabel.Location=New-Object Drawing.Point(22,4);$titleLabel.Size=New-Object Drawing.Size($titleWidth,20)
        $subtitleLabel.Location=New-Object Drawing.Point(22,25);$subtitleLabel.Size=New-Object Drawing.Size($titleWidth,17)
        $minimize.Size=New-Object Drawing.Size(34,30);$minimize.Location=New-Object Drawing.Point([Math]::Max(0,$width-84),6)
        $close.Size=New-Object Drawing.Size(34,30);$close.Location=New-Object Drawing.Point([Math]::Max(0,$width-44),6)
    }.GetNewClosure()
    $layoutPlayer={
        $width=[Math]::Max(1,[int]$controls.ClientSize.Width);$height=[Math]::Max(1,[int]$controls.ClientSize.Height)
        $margin=18;$gap=8;$rowHeight=30;$rowY=[Math]::Max(22,$height-$rowHeight-10)
        $playWidth=106;$statusWidth=118;$positionWidth=106;$volumeLabelWidth=30;$volumeWidth=70;$fullscreenWidth=174
        $fixed=$playWidth+$statusWidth+$positionWidth+$volumeLabelWidth+$volumeWidth+$fullscreenWidth
        $singleRow=($width-($margin*2)-$fixed-($gap*6)-100-ge0)
        if($singleRow){
            $seekWidth=[Math]::Max(100,$width-($margin*2)-$fixed-($gap*6));$x=$margin
            $play.Location=New-Object Drawing.Point($x,$rowY);$play.Size=New-Object Drawing.Size($playWidth,$rowHeight);$x+=$playWidth+$gap
            $statusLabel.Location=New-Object Drawing.Point($x,($rowY+2));$statusLabel.Size=New-Object Drawing.Size($statusWidth,26);$x+=$statusWidth+$gap
            $position.Location=New-Object Drawing.Point($x,($rowY+2));$position.Size=New-Object Drawing.Size($positionWidth,26);$x+=$positionWidth+$gap
            $seek.Location=New-Object Drawing.Point($x,($rowY+2));$seek.Size=New-Object Drawing.Size($seekWidth,26);$x+=$seekWidth+$gap
            $volumeLabel.Location=New-Object Drawing.Point($x,($rowY+2));$volumeLabel.Size=New-Object Drawing.Size($volumeLabelWidth,26);$x+=$volumeLabelWidth+$gap
            $volume.Location=New-Object Drawing.Point($x,$rowY);$volume.Size=New-Object Drawing.Size($volumeWidth,$rowHeight);$x+=$volumeWidth+$gap
            $fullscreen.Location=New-Object Drawing.Point($x,$rowY);$fullscreen.Size=New-Object Drawing.Size($fullscreenWidth,$rowHeight)
        }else{
            $topY=8;$bottomY=[Math]::Max(42,$height-$rowHeight-8);$lowerFixed=$volumeLabelWidth+$volumeWidth+$fullscreenWidth;$lowerSeekWidth=[Math]::Max(100,$width-($margin*2)-$lowerFixed-($gap*3));$x=$margin
            $play.Location=New-Object Drawing.Point($x,$topY);$play.Size=New-Object Drawing.Size($playWidth,$rowHeight);$x+=$playWidth+$gap
            $statusLabel.Location=New-Object Drawing.Point($x,($topY+2));$statusLabel.Size=New-Object Drawing.Size($statusWidth,26);$x+=$statusWidth+$gap
            $position.Location=New-Object Drawing.Point($x,($topY+2));$position.Size=New-Object Drawing.Size($positionWidth,26)
            $x=$margin;$seek.Location=New-Object Drawing.Point($x,($bottomY+2));$seek.Size=New-Object Drawing.Size($lowerSeekWidth,26);$x+=$lowerSeekWidth+$gap
            $volumeLabel.Location=New-Object Drawing.Point($x,($bottomY+2));$volumeLabel.Size=New-Object Drawing.Size($volumeLabelWidth,26);$x+=$volumeLabelWidth+$gap
            $volume.Location=New-Object Drawing.Point($x,$bottomY);$volume.Size=New-Object Drawing.Size($volumeWidth,$rowHeight);$x+=$volumeWidth+$gap
            $fullscreen.Location=New-Object Drawing.Point($x,$bottomY);$fullscreen.Size=New-Object Drawing.Size($fullscreenWidth,$rowHeight)
        }
    }.GetNewClosure()
    $chrome.Add_Resize($layoutChrome)
    $controls.Add_Resize($layoutPlayer)
    &$layoutChrome
    &$layoutPlayer
    $savePlayback={
        param([bool]$Force=$false)
        try{
            $now=[DateTime]::UtcNow
            if(-not$Force-and($now-$state.LastSavedUtc).TotalSeconds-lt2){return}
            $current=[Math]::Max(0.0,[double]$media.Position.TotalSeconds)
            if($state.Duration-le0-and$current-le0){return}
            &$writePlaybackCommand $Experience $Episode $current $state.Duration $state.Completed
            $state.LastSavedUtc=$now
        }catch{
            try{if($logCommand){&$logCommand "HEART SIGNAL: no se pudo guardar la posicion de '$($Episode.id)': $($_.Exception.Message)"}}catch{}
        }
    }.GetNewClosure()
    $applyResume={
        if($state.ResumeApplied-or$state.Duration-le0){return}
        $state.ResumeApplied=$true
        if($state.Completed){$state.ResumeSeconds=0.0;$state.Completed=$false;return}
        if($state.ResumeSeconds-gt5-and$state.ResumeSeconds-lt($state.Duration-15)){
            try{$media.Position=[TimeSpan]::FromSeconds([Math]::Min($state.ResumeSeconds,$state.Duration-1));$statusLabel.Text=("Continuando desde {0}"-f(&$formatTime $media.Position.TotalSeconds))}catch{}
        }else{$state.ResumeSeconds=0.0}
    }.GetNewClosure()
    $setSeekFromX={
        param([int]$X)
        if($state.Duration-le0){return}
        $usable=[Math]::Max(1,$seek.ClientSize.Width-8);$ratio=[Math]::Max(0.0,[Math]::Min(1.0,($X-4)/[double]$usable));$state.SeekPreviewSeconds=$state.Duration*$ratio;$seek.Invalidate()
    }.GetNewClosure()
    $seek.Add_Paint(({
        param($sender,$eventArgs)
        $graphics=$eventArgs.Graphics;$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $left=6;$right=[Math]::Max($left+1,$sender.ClientSize.Width-6);$center=[int]($sender.ClientSize.Height/2);$trackColor=[Drawing.Color]::FromArgb(64,49,78);$fillColor=[Drawing.Color]::FromArgb(177,92,255)
        $trackPen=New-Object Drawing.Pen($trackColor,6);$graphics.DrawLine($trackPen,$left,$center,$right,$center);$trackPen.Dispose()
        $seconds=if($state.Seeking){$state.SeekPreviewSeconds}else{[double]$media.Position.TotalSeconds};$ratio=if($state.Duration-gt0){[Math]::Max(0.0,[Math]::Min(1.0,$seconds/$state.Duration))}else{0.0};$thumbX=[int]($left+($right-$left)*$ratio)
        $fillPen=New-Object Drawing.Pen($fillColor,6);if($thumbX-gt$left){$graphics.DrawLine($fillPen,$left,$center,$thumbX,$center)};$fillPen.Dispose()
        $thumbBrush=New-Object Drawing.SolidBrush($fillColor);$graphics.FillEllipse($thumbBrush,$thumbX-6,$center-6,12,12);$thumbBrush.Dispose()
    }.GetNewClosure()))
    $seek.Add_MouseDown(({
        param($sender,$eventArgs)
        if($eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){$state.Seeking=$true;$sender.Focus();&$setSeekFromX $eventArgs.X}
    }.GetNewClosure()))
    $seek.Add_MouseMove(({
        param($sender,$eventArgs)
        if($state.Seeking){&$setSeekFromX $eventArgs.X}
    }.GetNewClosure()))
    $seek.Add_MouseUp(({
        param($sender,$eventArgs)
        if($state.Seeking-and$eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){if($state.Duration-gt0){$media.Position=[TimeSpan]::FromSeconds($state.SeekPreviewSeconds);$state.Completed=$false};&$savePlayback $true;$state.Seeking=$false;$sender.Invalidate()}
    }.GetNewClosure()))
    $seek.Add_KeyDown(({
        param($sender,$eventArgs)
        if($state.Duration-gt0-and$eventArgs.KeyCode-in @([Windows.Forms.Keys]::Left,[Windows.Forms.Keys]::Right)){$delta=if($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Left){-5.0}else{5.0};$state.SeekPreviewSeconds=[Math]::Max(0.0,[Math]::Min($state.Duration-1,$media.Position.TotalSeconds+$delta));$media.Position=[TimeSpan]::FromSeconds($state.SeekPreviewSeconds);$state.Completed=$false;&$savePlayback $true;$sender.Invalidate();$eventArgs.Handled=$true}
    }.GetNewClosure()))
    $adjustVolume = {
        param([double]$Delta)
        $state.Volume = [Math]::Max(0.0, [Math]::Min(1.0, $state.Volume + $Delta))
        if ($state.Volume -gt 0) { $state.PreviousVolume = $state.Volume }
        $media.Volume = $state.Volume
        $volume.Invalidate()
    }.GetNewClosure()
    $toggleMute = {
        if ($state.Volume -gt 0) {
            $state.PreviousVolume = $state.Volume
            $state.Volume = 0.0
        } else {
            $restore = if ($state.PreviousVolume -gt 0) { $state.PreviousVolume } else { 0.5 }
            $state.Volume = $restore
        }
        $media.Volume = $state.Volume
        $volume.Invalidate()
    }.GetNewClosure()
    $setVolumeFromX={
        param([int]$X)
        $usable=[Math]::Max(1,$volume.ClientSize.Width-8);$state.Volume=[Math]::Max(0.0,[Math]::Min(1.0,($X-4)/[double]$usable));if($state.Volume -gt 0){$state.PreviousVolume=$state.Volume};$media.Volume=$state.Volume;$volume.Invalidate()
    }.GetNewClosure()
    $volume.Add_Paint(({
        param($sender,$eventArgs)
        $graphics=$eventArgs.Graphics;$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$left=5;$right=[Math]::Max($left+1,$sender.ClientSize.Width-5);$center=[int]($sender.ClientSize.Height/2);$trackColor=[Drawing.Color]::FromArgb(64,49,78);$fillColor=[Drawing.Color]::FromArgb(177,92,255)
        $trackPen=New-Object Drawing.Pen($trackColor,5);$graphics.DrawLine($trackPen,$left,$center,$right,$center);$trackPen.Dispose();$thumbX=[int]($left+($right-$left)*$state.Volume);$fillPen=New-Object Drawing.Pen($fillColor,5);if($thumbX-gt$left){$graphics.DrawLine($fillPen,$left,$center,$thumbX,$center)};$fillPen.Dispose();$thumbBrush=New-Object Drawing.SolidBrush($fillColor);$graphics.FillEllipse($thumbBrush,$thumbX-5,$center-5,10,10);$thumbBrush.Dispose()
    }.GetNewClosure()))
    $volume.Add_MouseDown(({
        param($sender,$eventArgs)
        if($eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){$sender.Focus();&$setVolumeFromX $eventArgs.X}
    }.GetNewClosure()))
    $volume.Add_MouseMove(({
        param($sender,$eventArgs)
        if($eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){&$setVolumeFromX $eventArgs.X}
    }.GetNewClosure()))
    $volume.Add_MouseWheel(({
        param($sender,$eventArgs)
        $delta=if($eventArgs.Delta-gt 0){0.05}else{-0.05}
        &$adjustVolume $delta
    }.GetNewClosure()))
    $volume.Add_KeyDown(({
        param($sender,$eventArgs)
        if($eventArgs.KeyCode-in @([Windows.Forms.Keys]::Left,[Windows.Forms.Keys]::Down,[Windows.Forms.Keys]::OemMinus,[Windows.Forms.Keys]::Subtract)){&$adjustVolume -0.05;$eventArgs.Handled=$true}
        elseif($eventArgs.KeyCode-in @([Windows.Forms.Keys]::Right,[Windows.Forms.Keys]::Up,[Windows.Forms.Keys]::Oemplus,[Windows.Forms.Keys]::Add)){&$adjustVolume 0.05;$eventArgs.Handled=$true}
        elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::M){&$toggleMute;$eventArgs.Handled=$true}
    }.GetNewClosure()))
    $videoHost.Add_MouseWheel(({
        param($sender,$eventArgs)
        $delta=if($eventArgs.Delta-gt 0){0.05}else{-0.05}
        &$adjustVolume $delta
    }.GetNewClosure()))
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=250
    $startTimer=New-Object Windows.Forms.Timer;$startTimer.Interval=250
    $startTimer.Add_Tick(({
        if($state.Started){$startTimer.Stop()}else{try{$media.Play()}catch{}}
    }.GetNewClosure()))
    $timer.Add_Tick(({
        try{
            $currentSeconds=[Math]::Max(0.0,[double]$media.Position.TotalSeconds)
            if($media.NaturalDuration.HasTimeSpan){$state.Duration=[Math]::Max(0.0,[double]$media.NaturalDuration.TimeSpan.TotalSeconds);&$applyResume}
            if(-not$state.Seeking){$state.SeekPreviewSeconds=$currentSeconds}
            $position.Text=if($state.Duration-gt0){("{0} / {1}"-f(&$formatTime $currentSeconds),(&$formatTime $state.Duration))}else{("{0} / --:--"-f(&$formatTime $currentSeconds))}
            $seek.Invalidate()
            if($state.Started){&$savePlayback $false}
            if($media.DownloadProgress-lt1-and-not$state.Started){$statusLabel.Text=("Buffer {0}%"-f[int]($media.DownloadProgress*100))}elseif($state.Started-and$statusLabel.Text-like'Buffer*'){$statusLabel.Text='Reproduciendo'}
            if($state.Fullscreen){
                $idleSeconds=([DateTime]::UtcNow-$state.LastMouseMoveUtc).TotalSeconds
                if($idleSeconds-ge2.5-and-not$state.CursorHidden){
                    [Windows.Forms.Cursor]::Hide()
                    $state.CursorHidden=$true
                }
            }elseif($state.CursorHidden){
                [Windows.Forms.Cursor]::Show()
                $state.CursorHidden=$false
            }
        }catch{}
    }.GetNewClosure()))
    $showCursorOnMove={
        $state.LastMouseMoveUtc=[DateTime]::UtcNow
        if($state.CursorHidden){
            [Windows.Forms.Cursor]::Show()
            $state.CursorHidden=$false
        }
    }.GetNewClosure()
    $form.Add_MouseMove(({param($s,$e)&$showCursorOnMove}.GetNewClosure()))
    $videoHost.Add_MouseMove(({param($s,$e)&$showCursorOnMove}.GetNewClosure()))
    $controls.Add_MouseMove(({param($s,$e)&$showCursorOnMove}.GetNewClosure()))
    $media.Add_MouseMove(({param($s,$e)&$showCursorOnMove}.GetNewClosure()))
    $media.Add_MediaOpened(({
        param($sender,$eventArgs)
        try{$state.MediaReady=$true;$play.Enabled=$true;if($media.NaturalDuration.HasTimeSpan){$state.Duration=$media.NaturalDuration.TimeSpan.TotalSeconds;&$applyResume}}catch{}
        try{$media.Play();$state.Started=$true;if($statusLabel.Text-notlike'Continuando*'){$statusLabel.Text='Reproduciendo'};$play.Text='PAUSAR'}catch{$state.Started=$false;$statusLabel.Text='Preparando reproduccion...'}
    }.GetNewClosure()))
    $media.Add_MediaEnded(({
        param($sender,$eventArgs)
        $state.Started=$false;$state.Completed=$true;$statusLabel.Text='Finalizado';$play.Text='REPETIR';&$savePlayback $true
    }.GetNewClosure()))
    $media.Add_MediaFailed(({
        param($sender,$eventArgs)
        $state.Started=$false;$state.MediaReady=$false;$play.Enabled=$true;$play.Text='REINTENTAR';$statusLabel.Text='No compatible';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(255,139,151);$message=try{[string]$eventArgs.ErrorException.Message}catch{'El sistema no pudo decodificar este video.'};try{if($logCommand){&$logCommand "${mediaExperienceName}: MediaElement fallo: $message"}}catch{}
    }.GetNewClosure()))
    $play.Enabled=$false
    $play.Add_Click(({
        try{
            if(-not$state.MediaReady){$statusLabel.Text='Preparando reproduccion...';return}
            if($play.Text-eq'REPETIR'){$media.Position=[TimeSpan]::Zero;$state.Completed=$false;$media.Play();$state.Started=$true;$play.Text='PAUSAR';$statusLabel.Text='Reproduciendo'}elseif($state.Started){$media.Pause();$state.Started=$false;$play.Text='REPRODUCIR';$statusLabel.Text='Pausado'}else{$state.Completed=$false;$media.Play();$state.Started=$true;$play.Text='PAUSAR';$statusLabel.Text='Reproduciendo'};&$savePlayback $true
        }catch{
            $detail=[string]$_.Exception.Message
            try{Write-CocoLog "${mediaExperienceName}: control del reproductor fallo: $detail"}catch{}
            $statusLabel.Text='No se pudo controlar el video.'
        }
    }.GetNewClosure()))
    $minimize.Add_Click(({
        $form.WindowState=[Windows.Forms.FormWindowState]::Minimized
    }.GetNewClosure()))
    $close.Add_Click(({
        $form.Close()
    }.GetNewClosure()))
    $dragState=[pscustomobject]@{Active=$false;Start=[Drawing.Point]::new(0,0);FormLocation=$form.Location}
    $beginDrag={
        param($sender,$eventArgs)
        if($eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){$dragState.Active=$true;$dragState.Start=[Windows.Forms.Cursor]::Position;$dragState.FormLocation=$form.Location}
    }.GetNewClosure()
    $moveDrag={
        param($sender,$eventArgs)
        if($dragState.Active){$cursor=[Windows.Forms.Cursor]::Position;$dx=$cursor.X-$dragState.Start.X;$dy=$cursor.Y-$dragState.Start.Y;$form.Location=[Drawing.Point]::new($dragState.FormLocation.X+$dx,$dragState.FormLocation.Y+$dy)}
    }.GetNewClosure()
    $endDrag={$dragState.Active=$false}.GetNewClosure()
    foreach($dragControl in @($chrome,$accent,$titleLabel,$subtitleLabel)){$dragControl.Add_MouseDown($beginDrag);$dragControl.Add_MouseMove($moveDrag);$dragControl.Add_MouseUp($endDrag)}
    $toggleFullscreen={
        # ElementHost y MediaElement pueden recibir el mismo doble clic/tecla.
        # Ignorar el segundo evento de la misma transicion evita entrar y salir
        # de pantalla completa en el mismo gesto.
        # NO tocar ShowInTaskbar aquí: en un form visible fuerza RecreateHandle,
        # destruye el ElementHost/MediaElement en plena reproducción y el
        # fullscreen parpadea y se cae. El botón de la barra se conserva tal cual.
        $now=[DateTime]::UtcNow
        if(($now-$state.LastFullscreenToggleUtc).TotalMilliseconds-lt500){return}
        $state.LastFullscreenToggleUtc=$now
        $entering=-not$state.Fullscreen
        try{
            $form.SuspendLayout()
            if($entering){
                $state.PreviousFormBorderStyle=$form.FormBorderStyle;$state.PreviousWindowState=$form.WindowState;$state.PreviousBounds=$form.Bounds;$state.PreviousPadding=$form.Padding;$state.PreviousTopMost=$form.TopMost
                $screen=[Windows.Forms.Screen]::FromControl($form)
                $form.WindowState=[Windows.Forms.FormWindowState]::Normal
                $form.FormBorderStyle='None';$form.Padding=New-Object Windows.Forms.Padding(0);$form.TopMost=$true;$form.Bounds=$screen.Bounds
                $state.Fullscreen=$true;$fullscreen.Text='SALIR DE PANTALLA COMPLETA';$toolTip.SetToolTip($fullscreen,'Salir de pantalla completa (Esc)')
            }else{
                $restoreWindowState=$state.PreviousWindowState
                $form.WindowState=[Windows.Forms.FormWindowState]::Normal
                $form.FormBorderStyle=$state.PreviousFormBorderStyle
                $form.Padding=$state.PreviousPadding
                $form.TopMost=$state.PreviousTopMost
                $form.Bounds=$state.PreviousBounds
                if($restoreWindowState-eq[Windows.Forms.FormWindowState]::Maximized){$form.WindowState=$restoreWindowState}
                $state.Fullscreen=$false;$fullscreen.Text='PANTALLA COMPLETA';$toolTip.SetToolTip($fullscreen,'Pantalla completa (F11)')
                if($state.CursorHidden){
                    [Windows.Forms.Cursor]::Show()
                    $state.CursorHidden=$false
                }
            }
            $chrome.Visible=(-not$state.Fullscreen);$controls.Visible=(-not$state.Fullscreen);&$layoutChrome;&$layoutPlayer
        }catch{
            try{if($logCommand){&$logCommand "${mediaExperienceName}: cambio de pantalla completa fallo: $($_.Exception.Message)"}}catch{}
        }finally{
            try{$form.ResumeLayout($true);$form.PerformLayout();$form.Refresh();$form.Activate();if($state.Fullscreen){$videoHost.Focus();$media.Focus()}}catch{}
        }
    }.GetNewClosure()
    $fullscreen.Add_Click(({
        &$toggleFullscreen
    }.GetNewClosure()))
    $form.Tag=[pscustomobject]@{ToggleFullscreen=$toggleFullscreen}
    $videoHost.Add_DoubleClick(({
        &$toggleFullscreen
    }.GetNewClosure()))
    $media.Add_MouseLeftButtonDown(({
        param($sender,$eventArgs)
        if($eventArgs.ClickCount-ge2){&$toggleFullscreen;$eventArgs.Handled=$true}
    }.GetNewClosure()))
    $media.Add_MouseWheel(({
        param($sender,$eventArgs)
        $delta=if($eventArgs.Delta-gt 0){0.05}else{-0.05}
        &$adjustVolume $delta;$eventArgs.Handled=$true
    }.GetNewClosure()))
    $media.Add_KeyDown(({
        param($sender,$eventArgs)
        if($eventArgs.Key-in @([Windows.Input.Key]::Escape,[Windows.Input.Key]::F11)){
            &$toggleFullscreen;$eventArgs.Handled=$true
        }elseif($eventArgs.Key-in @([Windows.Input.Key]::Space,[Windows.Input.Key]::K)){
            $play.PerformClick();$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::M){
            &$toggleMute;$eventArgs.Handled=$true
        }elseif($eventArgs.Key-in @([Windows.Input.Key]::Up,[Windows.Input.Key]::OemPlus,[Windows.Input.Key]::Add)){
            &$adjustVolume 0.05;$eventArgs.Handled=$true
        }elseif($eventArgs.Key-in @([Windows.Input.Key]::Down,[Windows.Input.Key]::OemMinus,[Windows.Input.Key]::Subtract)){
            &$adjustVolume -0.05;$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::Left -and $state.Duration-gt 0){
            $newPos=[Math]::Max(0.0,$media.Position.TotalSeconds-5.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::Right -and $state.Duration-gt 0){
            $newPos=[Math]::Min([Math]::Max(0.0,$state.Duration-1.0),$media.Position.TotalSeconds+5.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::J -and $state.Duration-gt 0){
            $newPos=[Math]::Max(0.0,$media.Position.TotalSeconds-10.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::L -and $state.Duration-gt 0){
            $newPos=[Math]::Min([Math]::Max(0.0,$state.Duration-1.0),$media.Position.TotalSeconds+10.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::Home -and $state.Duration-gt 0){
            $media.Position=[TimeSpan]::Zero
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($eventArgs.Key-eq[Windows.Input.Key]::End -and $state.Duration-gt 0){
            $media.Position=[TimeSpan]::FromSeconds([Math]::Max(0.0,$state.Duration-1.0))
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($state.Duration-gt 0 -and ($eventArgs.Key -ge [Windows.Input.Key]::D0 -and $eventArgs.Key -le [Windows.Input.Key]::D9)){
            $num=[int]$eventArgs.Key - [int][Windows.Input.Key]::D0
            $media.Position=[TimeSpan]::FromSeconds([Math]::Min($state.Duration*($num*0.10),$state.Duration-1.0))
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }elseif($state.Duration-gt 0 -and ($eventArgs.Key -ge [Windows.Input.Key]::NumPad0 -and $eventArgs.Key -le [Windows.Input.Key]::NumPad9)){
            $num=[int]$eventArgs.Key - [int][Windows.Input.Key]::NumPad0
            $media.Position=[TimeSpan]::FromSeconds([Math]::Min($state.Duration*($num*0.10),$state.Duration-1.0))
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true
        }
    }.GetNewClosure()))
    $form.Add_KeyDown(({
        param($sender,$eventArgs)
        if($eventArgs.KeyCode-in @([Windows.Forms.Keys]::Space,[Windows.Forms.Keys]::K)){$play.PerformClick();$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true}
        elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::F11-or($state.Fullscreen-and$eventArgs.KeyCode-eq[Windows.Forms.Keys]::Escape)){
            &$toggleFullscreen;$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::M){
            &$toggleMute;$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-in @([Windows.Forms.Keys]::Up,[Windows.Forms.Keys]::Oemplus,[Windows.Forms.Keys]::Add)){
            &$adjustVolume 0.05;$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-in @([Windows.Forms.Keys]::Down,[Windows.Forms.Keys]::OemMinus,[Windows.Forms.Keys]::Subtract)){
            &$adjustVolume -0.05;$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Left -and $state.Duration-gt 0){
            $newPos=[Math]::Max(0.0,$media.Position.TotalSeconds-5.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Right -and $state.Duration-gt 0){
            $newPos=[Math]::Min([Math]::Max(0.0,$state.Duration-1.0),$media.Position.TotalSeconds+5.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::J -and $state.Duration-gt 0){
            $newPos=[Math]::Max(0.0,$media.Position.TotalSeconds-10.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::L -and $state.Duration-gt 0){
            $newPos=[Math]::Min([Math]::Max(0.0,$state.Duration-1.0),$media.Position.TotalSeconds+10.0)
            $media.Position=[TimeSpan]::FromSeconds($newPos)
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Home -and $state.Duration-gt 0){
            $media.Position=[TimeSpan]::Zero
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::End -and $state.Duration-gt 0){
            $media.Position=[TimeSpan]::FromSeconds([Math]::Max(0.0,$state.Duration-1.0))
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($state.Duration-gt 0 -and ($eventArgs.KeyCode -ge [Windows.Forms.Keys]::D0 -and $eventArgs.KeyCode -le [Windows.Forms.Keys]::D9)){
            $num=[int]$eventArgs.KeyCode - [int][Windows.Forms.Keys]::D0
            $media.Position=[TimeSpan]::FromSeconds([Math]::Min($state.Duration*($num*0.10),$state.Duration-1.0))
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }elseif($state.Duration-gt 0 -and ($eventArgs.KeyCode -ge [Windows.Forms.Keys]::NumPad0 -and $eventArgs.KeyCode -le [Windows.Forms.Keys]::NumPad9)){
            $num=[int]$eventArgs.KeyCode - [int][Windows.Forms.Keys]::NumPad0
            $media.Position=[TimeSpan]::FromSeconds([Math]::Min($state.Duration*($num*0.10),$state.Duration-1.0))
            $state.Completed=$false;try{&$savePlayback $true}catch{};$eventArgs.Handled=$true;$eventArgs.SuppressKeyPress=$true
        }
    }.GetNewClosure()))
    $form.Add_FormClosing(({
        param($sender,$eventArgs)
        if($state.CursorHidden){try{[Windows.Forms.Cursor]::Show()}catch{}}
        try{&$savePlayback $true;$state.ClosingSaved=$true;$timer.Stop();$startTimer.Stop();$media.Stop()}catch{}
    }.GetNewClosure()))
    $proxy=$null
    try{
        if($Source-match'^https://'){
            $statusLabel.Text='Preparando streaming...'
            $proxy=Start-CocoMediaHttpProxy $Source ([string]$Episode.fileName)
            $mediaSource=[string]$proxy.Url
        }else{$mediaSource=$Source}
        $uri=if($mediaSource-match'^[a-zA-Z]:[\\/]'){[Uri]::new([IO.Path]::GetFullPath($mediaSource))}else{[Uri]::new($mediaSource)}
        $form.Add_Shown(({
            try{$media.Source=$uri;$timer.Start();$startTimer.Start()}
            catch{$statusLabel.Text='No se pudo cargar el video.';$statusLabel.ForeColor=[Drawing.Color]::FromArgb(255,139,151);try{if($logCommand){&$logCommand "HEART SIGNAL: no se pudo cargar el video: $($_.Exception.Message)"}}catch{}}
        }.GetNewClosure()))
        if($script:CocoForm-and-not$script:CocoForm.IsDisposed){[void]$form.ShowDialog($script:CocoForm)}else{[void]$form.ShowDialog()}
    }finally{
        try{if(-not$state.ClosingSaved){&$savePlayback $true};$timer.Stop();$startTimer.Stop();$media.Stop()}catch{}
        try{$timer.Dispose()}catch{}
        try{$startTimer.Dispose()}catch{}
        try{$form.Dispose()}catch{}
        if($proxy){Stop-CocoMediaHttpProxy $proxy}
    }
}

function Invoke-CocoMediaEpisodePlayback($Experience,$Episode){
    $status=Get-CocoMediaEpisodeLocalStatus $Experience $Episode
    if($status.Status-ne'verified'){
        $check=Test-CocoMediaEpisodeFile $Experience $Episode -RecordVerifiedState
        if(-not$check.Matches){throw "El archivo local no coincide con el SHA-256 esperado para '$($Episode.fileName)'. Descargalo de nuevo cuando exista un asset publicado."}
    }
    Invoke-CocoMediaPlayerUi $Experience $Episode $status.Path
    $status.Path
}

function Get-CocoMediaEpisodeStatusText($Status,$Episode,$Experience=$null){
    if([string]$Episode.streamUrl-match'^https://'){
        $text='Streaming directo'
    }else{
        $text=switch([string]$Status.Status){
            'verified'{'Disponible en este PC'}
            'present'{'Archivo local detectado; se verificara al reproducir'}
            'partial'{'Descarga parcial'}
            'mismatch'{"No coincide con el hash esperado; se puede reemplazar"}
            default{
                if([string]::IsNullOrWhiteSpace([string]$Episode.sourceUrl)){'Asset pendiente de publicar'}
                else{'No descargado'}
            }
        }
    }
    if($Experience){$playback=Get-CocoMediaPlaybackState $Experience $Episode;if($playback-and-not$playback.Completed-and$playback.PositionSeconds-gt5){$text="$text | Continua en $(Format-CocoMediaTime $playback.PositionSeconds)"}}
    $text
}

function Update-CocoMediaEpisodeRowUi($RowInfo){
    if(-not$RowInfo-or$RowInfo.Button.IsDisposed){return}
    $status=Get-CocoMediaEpisodeLocalStatus $RowInfo.Experience $RowInfo.Episode
    $RowInfo.Status=$status
    if(-not$RowInfo.StatusLabel.IsDisposed){$RowInfo.StatusLabel.Text=Get-CocoMediaEpisodeStatusText $status $RowInfo.Episode $RowInfo.Experience}
    $canAct=$true;$buttonText='DESCARGAR';$streaming=[string]$RowInfo.Episode.streamUrl-match'^https://'
    if($streaming){
        $buttonText='VER EN COCO'
    }else{
        switch([string]$status.Status){
            'verified'{$buttonText='REPRODUCIR'}
            'present'{$buttonText='VERIFICAR / REPRODUCIR'}
            'partial'{$buttonText='REANUDAR'}
            'mismatch'{$buttonText=if([string]$RowInfo.Episode.sourceUrl){'DESCARGAR DE NUEVO'}else{'ASSET PENDIENTE'}}
            default{if([string]::IsNullOrWhiteSpace([string]$RowInfo.Episode.sourceUrl)){$buttonText='ASSET PENDIENTE';$canAct=$false}}
        }
    }
    $RowInfo.Button.Text=$buttonText;$RowInfo.Button.Enabled=$canAct
}

function Invoke-CocoMediaEpisodeAction($RowInfo){
    if(-not$RowInfo-or-not$RowInfo.Button.Enabled-or$script:CocoMediaDownloadInProgress){return}
    $script:CocoMediaDownloadInProgress=$true;$script:CocoMediaCancelRequested=$false;$script:CocoMediaDialog=$RowInfo.Dialog
    $script:CocoMediaCurrentExperience=$RowInfo.Experience
    $isMovie=Test-CocoMovieExperience $RowInfo.Experience
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){
        $mediaRoot=try{Get-CocoMediaDownloadRoot $RowInfo.Experience}catch{''}
        Set-CocoDiagnosticContext @{
            component='media';mode=if([string]$RowInfo.Episode.streamUrl-match'^https://'){'stream'}else{'local'}
            experienceId=[string]$RowInfo.Experience.id;episodeId=[string]$RowInfo.Episode.id
            mediaFile=[string]$RowInfo.Episode.fileName;instanceRoot=$mediaRoot
            stage=if($isMovie){'Abriendo pelicula'}else{'Abriendo episodio'}
        }
    }
    if($RowInfo.Dialog-and$RowInfo.Dialog.Tag-and$RowInfo.Dialog.Tag.Buttons){
        foreach($button in @($RowInfo.Dialog.Tag.Buttons)){if($button-and-not$button.IsDisposed){$button.Enabled=$false}}
    }
    try{
        $status=Get-CocoMediaEpisodeLocalStatus $RowInfo.Experience $RowInfo.Episode
        if([string]$RowInfo.Episode.streamUrl-match'^https://'){
            Set-CocoMediaUiStatus 'Conectando con el streaming...' 5
            try{
                Invoke-CocoMediaPlayerUi $RowInfo.Experience $RowInfo.Episode ([string]$RowInfo.Episode.streamUrl)
            }catch{
                if($status.Status-eq'verified'){
                    try{Write-CocoLog "MEDIA [$([string]$RowInfo.Experience.name)]: streaming fallo, usando copia local verificada ($($_.Exception.Message))"}catch{}
                    Set-CocoMediaUiStatus 'Streaming no disponible, abriendo copia local...' 90
                    [void](Invoke-CocoMediaEpisodePlayback $RowInfo.Experience $RowInfo.Episode)
                }else{throw}
            }
        }elseif($status.Status-eq'verified'){
            Set-CocoMediaUiStatus 'Abriendo el reproductor integrado...' 100
            [void](Invoke-CocoMediaEpisodePlayback $RowInfo.Experience $RowInfo.Episode)
        }elseif($status.Status-eq'present'){
            $check=Test-CocoMediaEpisodeFile $RowInfo.Experience $RowInfo.Episode -RecordVerifiedState
            if($check.Matches){[void](Invoke-CocoMediaEpisodePlayback $RowInfo.Experience $RowInfo.Episode)}
            elseif([string]$RowInfo.Episode.sourceUrl-notmatch'^https://'){throw "El archivo existe, pero no coincide y el asset remoto aun no esta publicado."}
            else{[void](Invoke-CocoMediaHttpDownload $RowInfo.Experience $RowInfo.Episode $status.Path);[void](Invoke-CocoMediaEpisodePlayback $RowInfo.Experience $RowInfo.Episode)}
        }elseif([string]$RowInfo.Episode.sourceUrl-notmatch'^https://'){
            throw $(if($isMovie){'Esta pelicula aun no tiene un asset publicado. La prueba local solo puede reproducir un archivo ya presente en Downloads.'}else{'Este episodio aun no tiene un asset publicado. La prueba local solo puede reproducir un archivo ya presente en Downloads.'})
        }else{
            [void](Invoke-CocoMediaHttpDownload $RowInfo.Experience $RowInfo.Episode $status.Path);[void](Invoke-CocoMediaEpisodePlayback $RowInfo.Experience $RowInfo.Episode)
        }
    }catch{
        if([string]$_.Exception.Message-notmatch'cancelada'){
            try{Write-CocoLog "MEDIA [$([string]$RowInfo.Experience.name)]: accion fallida: $($_.Exception.Message)"}catch{}
            $failureDetail=if(Get-Command Get-CocoLauncherFailureDetail -ErrorAction SilentlyContinue){Get-CocoLauncherFailureDetail $_}else{[string]$_.Exception.Message}
            [Windows.Forms.MessageBox]::Show($failureDetail,[string]$RowInfo.Experience.name,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
        }
    }finally{
        $script:CocoMediaDownloadInProgress=$false;$script:CocoMediaCancelRequested=$false;$script:CocoMediaDialog=$null;$script:CocoMediaCurrentExperience=$null
        if($RowInfo.Dialog-and-not$RowInfo.Dialog.IsDisposed){
            if($RowInfo.Dialog.Tag-and$RowInfo.Dialog.Tag.Buttons){
                foreach($button in @($RowInfo.Dialog.Tag.Buttons)){if($button-and-not$button.IsDisposed){$button.Enabled=$true}}
            }
            Update-CocoMediaEpisodeRowUi $RowInfo
            Set-CocoMediaUiStatus $(if($isMovie){'Selecciona la pelicula para reproducirla.'}else{'Selecciona un episodio para descargarlo o reproducirlo.'}) 0
        }
        if(Get-Command Set-CocoLauncherIdleState -ErrorAction SilentlyContinue){try{Set-CocoLauncherIdleState 'Elige una experiencia para instalarla, alojar una partida o reproducir contenido.' 100}catch{}}
    }
}

function Invoke-CocoMediaMovieAction($Experience){
    if(-not(Test-CocoMediaExperience $Experience)){return}
    $items=@(Get-CocoMediaItems $Experience)
    if(-not$items.Count){throw "La pelicula '$($Experience.name)' no tiene archivo de video configurado."}
    $movieItem=$items[0]
    $fakeButton=New-Object Windows.Forms.Button;$fakeButton.Enabled=$true
    $rowInfo=[pscustomobject]@{
        Experience=$Experience
        Episode=$movieItem
        Dialog=$null
        Button=$fakeButton
        StatusLabel=(New-Object Windows.Forms.Label)
        Status=$null
    }
    Invoke-CocoMediaEpisodeAction $rowInfo
}

function Invoke-CocoMediaOpenFolderUi($Experience){
    $root=Get-CocoMediaDownloadRoot $Experience;New-Item -ItemType Directory -Path $root -Force|Out-Null
    Start-Process -FilePath explorer.exe -ArgumentList @($root)
}

function Invoke-CocoMediaEpisodeUi($Experience){
    if(-not(Test-CocoMediaExperience $Experience)){return}
    $script:CocoMediaInteraction=$true
    $episodeActionInfo=@(Get-Command Invoke-CocoMediaEpisodeAction -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0]
    $episodeActionCommand=[System.Management.Automation.ScriptBlock]$episodeActionInfo.ScriptBlock
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form
    $dialog.Name='CocoMediaEpisodeSelector';$dialog.Text=[string]$Experience.name;$dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='None';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.KeyPreview=$true;$dialog.ShowInTaskbar=$false;$dialog.BackColor=[Drawing.Color]::FromArgb(27,19,38);$dialog.Padding=New-Object Windows.Forms.Padding(1);$dialog.ClientSize=New-Object Drawing.Size(760,380);$dialog.MinimumSize=New-Object Drawing.Size(660,340)
    $dialog.Add_Paint({param($sender,$eventArgs)$pen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(84,59,106),1);try{$eventArgs.Graphics.DrawRectangle($pen,0,0,$sender.ClientSize.Width-1,$sender.ClientSize.Height-1)}finally{$pen.Dispose()}}.GetNewClosure())

    $header=New-Object Windows.Forms.Panel;$header.Name='CocoMediaSelectorHeader';$header.Dock='Top';$header.Height=82;$header.BackColor=[Drawing.Color]::FromArgb(27,19,38)
    $accent=New-Object Windows.Forms.Panel;$accent.Dock='Left';$accent.Width=5;$accent.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $heading=New-Object Windows.Forms.Label;$heading.Name='CocoMediaSelectorTitle';$heading.Text='HEART SIGNAL';$heading.Font=New-Object Drawing.Font('Segoe UI Semibold',14);$heading.ForeColor=[Drawing.Color]::White;$heading.AutoEllipsis=$true
    $badge=New-Object Windows.Forms.Label;$badge.Name='CocoMediaSelectorBadge';$badge.Text='STREAMING DIRECTO';$badge.TextAlign='MiddleCenter';$badge.Font=New-Object Drawing.Font('Segoe UI Semibold',7.5);$badge.ForeColor=[Drawing.Color]::FromArgb(183,239,194);$badge.BackColor=[Drawing.Color]::FromArgb(39,57,48)
    $closeButton=New-Object Windows.Forms.Button;$closeButton.Name='CocoMediaSelectorCloseButton';$closeButton.Text='X';$closeButton.AccessibleName='Cerrar selector';$closeButton.Font=New-Object Drawing.Font('Segoe UI Semibold',9);Set-CocoMediaButtonStyle $closeButton ([Drawing.Color]::FromArgb(27,19,38)) ([Drawing.Color]::FromArgb(218,210,229)) ([Drawing.Color]::FromArgb(150,48,70))
    $header.Controls.AddRange(@($accent,$heading,$badge,$closeButton))

    $body=New-Object Windows.Forms.Panel;$body.Name='CocoMediaSelectorBody';$body.Dock='Fill';$body.BackColor=[Drawing.Color]::FromArgb(22,13,34);$body.Padding=New-Object Windows.Forms.Padding(20,8,20,8)
    $list=New-Object Windows.Forms.Panel;$list.Name='CocoMediaEpisodeList';$list.Dock='Fill';$list.AutoScroll=$true;$list.BackColor=[Drawing.Color]::FromArgb(22,13,34);$list.Padding=New-Object Windows.Forms.Padding(0);Set-CocoControlDoubleBuffered $list
    $list.HorizontalScroll.Enabled=$false;$list.HorizontalScroll.Visible=$false
    $body.Controls.Add($list)

    $footer=New-Object Windows.Forms.Panel;$footer.Name='CocoMediaSelectorFooter';$footer.Dock='Bottom';$footer.Height=58;$footer.BackColor=[Drawing.Color]::FromArgb(27,19,38)
    $footerLine=New-Object Windows.Forms.Panel;$footerLine.Name='CocoMediaSelectorFooterLine';$footerLine.Dock='Top';$footerLine.Height=1;$footerLine.BackColor=[Drawing.Color]::FromArgb(72,52,91)
    $statusLabel=New-Object Windows.Forms.Label;$statusLabel.Name='CocoMediaSelectorStatus';$statusLabel.Text='';$statusLabel.Visible=$false
    $progress=New-Object Windows.Forms.Panel;$progress.Name='CocoMediaProgressBar';$progress.BackColor=[Drawing.Color]::FromArgb(55,40,70);$progress.Tag=0;$progress.Height=6
    $progress.Add_Paint(({
        param($sender,$eventArgs)
        $width=[Math]::Max(0,[int](($sender.ClientSize.Width-2)*([int]$sender.Tag/100.0)))
        $brush=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(177,92,255));try{if($width-gt0){$eventArgs.Graphics.FillRectangle($brush,1,1,$width,([Math]::Max(1,$sender.ClientSize.Height-2)))}}finally{$brush.Dispose()}
    }.GetNewClosure()))
    $cancelButton=New-Object Windows.Forms.Button;$cancelButton.Name='CocoMediaCancelButton';$cancelButton.Text='CANCELAR';$cancelButton.Size=New-Object Drawing.Size(110,34);Set-CocoMediaButtonStyle $cancelButton ([Drawing.Color]::FromArgb(58,36,81)) ([Drawing.Color]::FromArgb(218,210,229)) ([Drawing.Color]::FromArgb(105,52,75))
    $footer.Controls.AddRange(@($footerLine,$progress,$cancelButton))
    $dialog.Controls.AddRange(@($body,$footer,$header))

    $layoutSelector={
        $width=[Math]::Max(1,[int]$dialog.ClientSize.Width);$footerWidth=[Math]::Max(1,[int]$footer.ClientSize.Width);$headerWidth=[Math]::Max(1,[int]$header.ClientSize.Width)
        $heading.Location=New-Object Drawing.Point(25,17);$heading.Size=New-Object Drawing.Size([Math]::Max(260,$headerWidth-245),24)
        $badge.Size=New-Object Drawing.Size(142,25);$badge.Location=New-Object Drawing.Point([Math]::Max(260,$headerWidth-198),19)
        $closeButton.Size=New-Object Drawing.Size(34,34);$closeButton.Location=New-Object Drawing.Point([Math]::Max(0,$headerWidth-48),15)
        $progress.Location=New-Object Drawing.Point(20,26);$progress.Size=New-Object Drawing.Size([Math]::Max(180,$footerWidth-170),6)
        $cancelButton.Location=New-Object Drawing.Point([Math]::Max(0,$footerWidth-130),12)
    }.GetNewClosure()
    $dialog.Add_Resize($layoutSelector);&$layoutSelector

    $dragState=[pscustomobject]@{Active=$false;Start=[Drawing.Point]::Empty;FormLocation=[Drawing.Point]::Empty}
    $beginDrag={param($sender,$eventArgs)if($eventArgs.Button-eq[Windows.Forms.MouseButtons]::Left){$dragState.Active=$true;$dragState.Start=[Windows.Forms.Cursor]::Position;$dragState.FormLocation=$dialog.Location}}.GetNewClosure()
    $moveDrag={param($sender,$eventArgs)if($dragState.Active){$cursor=[Windows.Forms.Cursor]::Position;$dialog.Location=New-Object Drawing.Point($dragState.FormLocation.X+($cursor.X-$dragState.Start.X),$dragState.FormLocation.Y+($cursor.Y-$dragState.Start.Y))}}.GetNewClosure()
    $endDrag={$dragState.Active=$false}.GetNewClosure()
    foreach($dragControl in @($header,$accent,$heading,$badge)){$dragControl.Add_MouseDown($beginDrag);$dragControl.Add_MouseMove($moveDrag);$dragControl.Add_MouseUp($endDrag)}
    $closeButton.Add_Click({$dialog.Close()}.GetNewClosure())
    $cancelButton.Add_Click(({
        if($script:CocoMediaDownloadInProgress){$script:CocoMediaCancelRequested=$true;$statusLabel.Text='Cancelando...'}else{$dialog.DialogResult=[Windows.Forms.DialogResult]::Cancel;$dialog.Close()}
    }.GetNewClosure()))
    $dialog.Add_KeyDown(({
        param($sender,$eventArgs)
        if($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Escape-and-not$script:CocoMediaDownloadInProgress){$dialog.Close();$eventArgs.Handled=$true}
    }.GetNewClosure()))

    $dialog.Tag=[pscustomobject]@{Buttons=(New-Object Collections.ArrayList);Progress=$progress;StatusLabel=$statusLabel}
    $rowY=8
    foreach($episode in @($Experience.content.episodes)){
        $rowWidth=[Math]::Max(520,[int]$list.ClientSize.Width-6)
        $row=New-Object Windows.Forms.Panel;$row.Name='CocoMediaEpisodeRow';$row.Location=New-Object Drawing.Point(0,$rowY);$row.Size=New-Object Drawing.Size($rowWidth,76);$row.BackColor=[Drawing.Color]::FromArgb(43,27,67);$row.Padding=New-Object Windows.Forms.Padding(1);Set-CocoControlDoubleBuffered $row
        $rowAccent=New-Object Windows.Forms.Panel;$rowAccent.Dock='Left';$rowAccent.Width=4;$rowAccent.BackColor=[Drawing.Color]::FromArgb(177,92,255)
        $title=New-Object Windows.Forms.Label;$title.Text=[string]$episode.title;$title.Font=New-Object Drawing.Font('Segoe UI Semibold',9.5);$title.ForeColor=[Drawing.Color]::White;$title.AutoEllipsis=$true
        $file=New-Object Windows.Forms.Label;$file.Text=[string]$episode.fileName;$file.Font=New-Object Drawing.Font('Segoe UI',7.5);$file.ForeColor=[Drawing.Color]::FromArgb(224,190,255);$file.AutoEllipsis=$true
        $rowStatus=New-Object Windows.Forms.Label;$rowStatus.Font=New-Object Drawing.Font('Segoe UI',7.5);$rowStatus.ForeColor=[Drawing.Color]::FromArgb(183,239,194);$rowStatus.AutoEllipsis=$true
        $button=New-Object Windows.Forms.Button;$button.Size=New-Object Drawing.Size(190,34);Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(103,55,143)) ([Drawing.Color]::White) ([Drawing.Color]::FromArgb(132,77,176))
        $layoutRow={
            $rowWidth=[Math]::Max(1,[int]$row.ClientSize.Width);$textWidth=[Math]::Max(220,$rowWidth-222)
            $title.Location=New-Object Drawing.Point(17,7);$title.Size=New-Object Drawing.Size($textWidth,20);$file.Location=New-Object Drawing.Point(17,29);$file.Size=New-Object Drawing.Size($textWidth,17);$rowStatus.Location=New-Object Drawing.Point(17,51);$rowStatus.Size=New-Object Drawing.Size($textWidth,16);$button.Location=New-Object Drawing.Point([Math]::Max(0,$rowWidth-202),21)
        }.GetNewClosure()
        $row.Add_Resize($layoutRow);&$layoutRow
        $rowInfo=[pscustomobject]@{Experience=$Experience;Episode=$episode;Dialog=$dialog;Button=$button;StatusLabel=$rowStatus;Status=$null}
        $button.Tag=$rowInfo;$button.Add_Click({param($sender,$eventArgs)$null=&$episodeActionCommand $sender.Tag}.GetNewClosure())
        $row.Controls.AddRange(@($rowAccent,$title,$file,$rowStatus,$button));$list.Controls.Add($row);[void]$dialog.Tag.Buttons.Add($button);Update-CocoMediaEpisodeRowUi $rowInfo;$rowY+=84
    }
    $list.Add_Resize(({
        $targetWidth=[Math]::Max(520,[int]$list.ClientSize.Width-6)
        try{$list.HorizontalScroll.Enabled=$false;$list.HorizontalScroll.Visible=$false}catch{}
        foreach($episodeRow in @($list.Controls|Where-Object Name -eq 'CocoMediaEpisodeRow')){if($episodeRow.Width-ne$targetWidth){$episodeRow.Width=$targetWidth}}
    }.GetNewClosure()))
    try{Register-CocoNativeScrollWheel $list $list}catch{}
    $dialog.Add_FormClosing(({
        param($sender,$eventArgs)
        if($script:CocoMediaDownloadInProgress){$eventArgs.Cancel=$true;$script:CocoMediaCancelRequested=$true;$statusLabel.Text='Cancelando...'}
    }.GetNewClosure()))
    $script:CocoMediaDialog=$dialog;$script:CocoMediaProgressBar=$progress;$script:CocoMediaStatusLabel=$statusLabel
    try{[void]$dialog.ShowDialog($script:CocoForm)}finally{$script:CocoMediaDialog=$null;$script:CocoMediaProgressBar=$null;$script:CocoMediaStatusLabel=$null;$dialog.Dispose();try{$statusLabel.Dispose()}catch{}}
}

function Update-CocoExperienceCardsUi($DynamicPanel,$Catalog,$Paths,[string]$Role='client'){
    if(-not$DynamicPanel-or$DynamicPanel.IsDisposed-or-not$Catalog){return}
    $mediaEpisodeUiCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoMediaEpisodeUi -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $mediaMovieUiCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoMediaMovieAction -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $mediaOpenFolderUiCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoMediaOpenFolderUi -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $experienceChangeLocationUiCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoExperienceChangeLocationUi -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $experienceStorageInstallUiCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoExperienceStorageInstallUi -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $experienceFreeSpaceUiCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoExperienceFreeSpaceUi -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $expRoot=if($Paths-is[hashtable]){[string]$Paths['ExperiencesRoot']}elseif($Paths-and$Paths.ExperiencesRoot){[string]$Paths.ExperiencesRoot}else{[string]$Paths}
    $locationPath=Get-CocoLauncherInstanceLocationsPath $Paths
    $isInstallingAny=[bool]$script:CocoStorageInstallInProgress
    $installingExpId=if($script:CocoInstallingExperienceId){[string]$script:CocoInstallingExperienceId}else{''}
    $installingExpName=if($script:CocoInstallingExperienceName){[string]$script:CocoInstallingExperienceName}else{'otro juego'}
    $managedExperiences=@($Catalog.experiences|Where-Object{ $_.managementMode-eq'managed'-and($_.launch.workflow-eq'coco-managed'-or$_.launch.workflow-eq'coco-standalone'-or$_.launch.workflow-eq'coco-media') })
    if($managedExperiences.Count-eq0){return}
    Write-CocoStorageDiagnostic 'cards.refresh' @{role=$Role;experienceCount=$managedExperiences.Count;experiencesRoot=$expRoot;locationPath=$locationPath;panelSize=$DynamicPanel.Size;installing=$isInstallingAny;installingExpId=$installingExpId}
    Set-CocoExperienceCardsScrollBehavior $DynamicPanel
    if($script:CocoExperienceCardsToolTip){try{$script:CocoExperienceCardsToolTip.Dispose()}catch{}}
    $script:CocoExperienceCardsToolTip=New-Object Windows.Forms.ToolTip
    $DynamicPanel.SuspendLayout()
    try{
        try{
            $DynamicPanel.AutoScrollPosition=[Drawing.Point]::new(0,0)
            $DynamicPanel.VerticalScroll.Value=0
            $DynamicPanel.HorizontalScroll.Value=0
        }catch{}
        $DynamicPanel.AutoScroll=$false;$DynamicPanel.AutoScrollMinSize=[Drawing.Size]::new(0,0)
        foreach($oldControl in @($DynamicPanel.Controls)){
            try{$DynamicPanel.Controls.Remove($oldControl);$oldControl.Dispose()}catch{}
        }
        $DynamicPanel.AutoScroll=$false;$DynamicPanel.HorizontalScroll.Visible=$false;$DynamicPanel.HorizontalScroll.Enabled=$false
        $cardsContent=New-Object Windows.Forms.Panel;$cardsContent.Name='CocoExperienceCardsContent';$cardsContent.Location=[Drawing.Point]::new(0,0);$cardsContent.Size=[Drawing.Size]::new(1,1);$cardsContent.BackColor=[Drawing.Color]::FromArgb(22,13,34);$cardsContent.TabStop=$false;Set-CocoControlDoubleBuffered $cardsContent
        $storageHeader=New-Object Windows.Forms.Label
        $storageHeader.Text=if($Role-eq'host'){'EXPERIENCIAS Y GESTION DE INSTANCIAS'}else{'EXPERIENCIAS DISPONIBLES'}
        $storageHeader.Font=New-Object Drawing.Font('Segoe UI Semibold',(Get-CocoLauncherUiFontSize 9 7));$storageHeader.ForeColor=[Drawing.Color]::FromArgb(224,190,255);$storageHeader.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 0),(Get-CocoLauncherUiMetric 0));$storageHeader.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 810),(Get-CocoLauncherUiMetric 20));$storageHeader.AutoEllipsis=$true
        $cardsContent.Controls.Add($storageHeader)
        $columns=2;$gap=Get-CocoLauncherUiMetric 10;$availableWidth=[Math]::Max((Get-CocoLauncherUiMetric 500),$DynamicPanel.ClientSize.Width-(Get-CocoLauncherUiMetric 18));$cardWidth=[Math]::Max((Get-CocoLauncherUiMetric 240),[Math]::Floor(($availableWidth-$gap)/$columns));$cardHeight=[int]$cardWidth;$gradientHeight=Get-CocoLauncherUiMetric 110;$actionPadding=Get-CocoLauncherUiMetric 8;$actionGap=Get-CocoLauncherUiMetric 6;$actionHeight=Get-CocoLauncherUiMetric 28
        $cardIndex=0
        foreach($exp in $managedExperiences){
            $rowIndex=[int][Math]::Floor($cardIndex/$columns);$columnIndex=$cardIndex%$columns;$cardX=[int]($columnIndex*($cardWidth+$gap));$cardTop=[int]((Get-CocoLauncherUiMetric 22)+$rowIndex*($cardHeight+$gap))
            $card=New-Object Windows.Forms.Panel;$card.Name='CocoExperienceCard';$card.Location=New-Object Drawing.Point($cardX,$cardTop);$card.Size=New-Object Drawing.Size($cardWidth,$cardHeight);$card.BackColor=[Drawing.Color]::FromArgb(30,20,42);$card.BorderStyle=[Windows.Forms.BorderStyle]::None;Set-CocoControlDoubleBuffered $card
            $imageBox=New-Object Windows.Forms.PictureBox;$imageBox.Name='CocoExperienceImage';$imageBox.Location=New-Object Drawing.Point(0,0);$imageBox.Size=New-Object Drawing.Size($cardWidth,$cardHeight);$imageBox.SizeMode=[Windows.Forms.PictureBoxSizeMode]::Normal;$imageBox.BackColor=[Drawing.Color]::FromArgb(30,20,42);$imageBox.BorderStyle=[Windows.Forms.BorderStyle]::None;$imageBox.TabStop=$false;Set-CocoControlDoubleBuffered $imageBox;Set-CocoPictureBoxCoverImage $imageBox (Get-CocoExperienceImagePath $exp) $cardWidth $cardHeight
            $gradient=New-Object Windows.Forms.Panel;$gradient.Name='CocoExperienceGradient';$gradient.Dock='Bottom';$gradient.Height=$gradientHeight;$gradient.BackColor=[Drawing.Color]::FromArgb(30,20,42);$gradient.Padding=New-Object Windows.Forms.Padding(0);Set-CocoControlDoubleBuffered $gradient
            $gradient.Add_Paint(({
                param($sender,$eventArgs)
                $w=[Math]::Max(1,$sender.ClientSize.Width);$h=[Math]::Max(1,$sender.ClientSize.Height)
                $graphics=$eventArgs.Graphics
                $cover=try{$imageBox.Image}catch{$null}
                if($cover){
                    $srcY=[Math]::Max(0,[int]$cover.Height-$h)
                    $srcH=[Math]::Max(1,[Math]::Min([int]$cover.Height-$srcY,$h))
                    $srcW=[Math]::Max(1,[Math]::Min([int]$cover.Width,$w))
                    try{$graphics.DrawImage($cover,(New-Object Drawing.Rectangle(0,0,$w,$h)),(New-Object Drawing.Rectangle(0,$srcY,$srcW,$srcH)),[Drawing.GraphicsUnit]::Pixel)}catch{}
                }else{
                    try{$graphics.Clear([Drawing.Color]::FromArgb(30,20,42))}catch{}
                }
                $rectangle=New-Object Drawing.Rectangle(0,0,$w,$h)
                $brush=[Drawing.Drawing2D.LinearGradientBrush]::new($rectangle,[Drawing.Color]::FromArgb(72,0,0,0),[Drawing.Color]::FromArgb(255,0,0,0),[Drawing.Drawing2D.LinearGradientMode]::Vertical)
                try{$graphics.FillRectangle($brush,$rectangle)}finally{$brush.Dispose()}
            }.GetNewClosure()))
            $imageBox.Controls.Add($gradient);$gradient.BringToFront()
            $nameLabel=New-Object Windows.Forms.Label;$nameLabel.Text=Format-CocoExperienceCardTitle ([string]$exp.name);$nameLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',(Get-CocoLauncherUiFontSize 12 8));$nameLabel.ForeColor=[Drawing.Color]::White;$nameLabel.BackColor=[Drawing.Color]::Transparent;$nameLabel.Location=New-Object Drawing.Point($actionPadding,(Get-CocoLauncherUiMetric 4));$nameLabel.Size=New-Object Drawing.Size(($cardWidth-(2*$actionPadding)),(Get-CocoLauncherUiMetric 40));$nameLabel.AutoEllipsis=$false;$nameLabel.AutoSize=$false;$nameLabel.UseCompatibleTextRendering=$true;$nameLabel.TextAlign=[Drawing.ContentAlignment]::BottomLeft;Set-CocoControlDoubleBuffered $nameLabel
            $detailLabel=New-Object Windows.Forms.Label;$detailLabel.Font=New-Object Drawing.Font('Segoe UI Semibold',(Get-CocoLauncherUiFontSize 8.5 6));$detailLabel.ForeColor=[Drawing.Color]::FromArgb(224,190,255);$detailLabel.BackColor=[Drawing.Color]::Transparent;$detailLabel.Location=New-Object Drawing.Point($actionPadding,(Get-CocoLauncherUiMetric 46));$detailLabel.Size=New-Object Drawing.Size(($cardWidth-(2*$actionPadding)),(Get-CocoLauncherUiMetric 18));$detailLabel.AutoEllipsis=$true;$detailLabel.AutoSize=$false;Set-CocoControlDoubleBuffered $detailLabel
            $buttonSpecs=@();$cardInfo=$null
            $isMedia=Test-CocoMediaExperience $exp
            $isThisInstalling=($isInstallingAny -and -not $isMedia -and [string]$exp.id -eq $installingExpId)
            $isOtherGameInstalling=($isInstallingAny -and -not $isMedia -and -not $isThisInstalling)
            if($isMedia){
                $isMovie=Test-CocoMovieExperience $exp
                $mediaItems=@(Get-CocoMediaItems $exp)
                $mediaStatus=Get-CocoMediaExperienceStatus $exp;$mediaRoot=[string]$mediaStatus.Root
                $streamAvailable=@($mediaItems|Where-Object{[string]$_.streamUrl-match'^https://'}).Count-gt0
                if($isMovie){
                    $detailLabel.Text=if($mediaStatus.Verified-gt0){'LISTA PARA VER'}elseif($streamAvailable){'STREAMING DIRECTO'}else{'NO DISPONIBLE'}
                    $detailLabel.ForeColor=if($streamAvailable-or$mediaStatus.Verified-gt0){[Drawing.Color]::FromArgb(183,239,194)}else{[Drawing.Color]::FromArgb(180,170,195)}
                    $cardInfo=[pscustomobject]@{InstanceId=[string]$exp.instanceId;ExperienceId=[string]$exp.id;Experience=$exp;Name=[string]$exp.name;InstanceRoot=$mediaRoot;CurrentRoot=$mediaRoot;ExperiencesRoot=$expRoot;Usage=[pscustomobject]@{Installed=($mediaStatus.Verified-gt0);Bytes=$mediaStatus.Bytes;Label=if($mediaStatus.Verified-gt0){'Pelicula lista'}else{'Streaming'}};IsRunning=$false;IsMedia=$true;IsMovie=$true;MediaRoot=$mediaRoot;DynamicPanel=$DynamicPanel;Catalog=$Catalog;Paths=$Paths;Role=$Role}
                    $buttonSpecs=@([pscustomobject]@{Text='VER PELICULA';Kind='movie'})
                }else{
                    $detailLabel.Text=if($streamAvailable-or$mediaStatus.Verified-gt0){'LISTO PARA VER'}else{'NO DISPONIBLE'}
                    $detailLabel.ForeColor=if($streamAvailable-or$mediaStatus.Verified-gt0){[Drawing.Color]::FromArgb(183,239,194)}else{[Drawing.Color]::FromArgb(180,170,195)}
                    $cardInfo=[pscustomobject]@{InstanceId=[string]$exp.instanceId;ExperienceId=[string]$exp.id;Experience=$exp;Name=[string]$exp.name;InstanceRoot=$mediaRoot;CurrentRoot=$mediaRoot;ExperiencesRoot=$expRoot;Usage=[pscustomobject]@{Installed=($mediaStatus.Verified-gt0);Bytes=$mediaStatus.Bytes;Label=('{0}/{1} partes'-f$mediaStatus.Verified,$mediaStatus.Total)};IsRunning=$false;IsMedia=$true;IsMovie=$false;MediaRoot=$mediaRoot;DynamicPanel=$DynamicPanel;Catalog=$Catalog;Paths=$Paths;Role=$Role}
                    $buttonSpecs=@([pscustomobject]@{Text='EPISODIOS';Kind='episode'})
                }
            }else{
                $instanceId=[string]$exp.instanceId;if(-not$instanceId){$instanceId=[string]$exp.id};$instanceRoot=Get-CocoExperienceInstanceRoot $exp $expRoot $locationPath;$usage=Get-CocoExperienceDiskUsage $instanceRoot;$isRunning=Test-CocoManagedGameRunning $instanceRoot;Write-CocoStorageDiagnostic 'card.state' @{role=$Role;experienceId=$exp.id;instanceId=$instanceId;root=$instanceRoot;installed=$usage.Installed;usage=$usage.Label;running=$isRunning}
                $compactPath=Get-CocoCompactPath $instanceRoot
                if($isThisInstalling){
                    $detailLabel.Text='INSTALANDO ARCHIVOS...'
                    $detailLabel.ForeColor=[Drawing.Color]::FromArgb(255,215,0)
                    $cardInfo=[pscustomobject]@{InstanceId=$instanceId;ExperienceId=[string]$exp.id;Experience=$exp;Name=[string]$exp.name;InstanceRoot=$instanceRoot;CurrentRoot=$instanceRoot;ExperiencesRoot=$expRoot;Usage=$usage;IsRunning=$false;IsInstalling=$true;DynamicPanel=$DynamicPanel;Catalog=$Catalog;Paths=$Paths;Role=$Role}
                    $buttonSpecs=@([pscustomobject]@{Text='INSTALANDO...';Kind='installing'})
                }elseif($isOtherGameInstalling){
                    if($isRunning){
                        $detailLabel.Text="EN EJECUCION • $($usage.Label)"
                        $detailLabel.ForeColor=[Drawing.Color]::FromArgb(255,215,0)
                    }elseif($usage.Installed){
                        $detailLabel.Text="INSTALADO • $($usage.Label) • $compactPath"
                        $detailLabel.ForeColor=[Drawing.Color]::FromArgb(150,140,160)
                    }else{
                        $detailLabel.Text='NO INSTALADO'
                        $detailLabel.ForeColor=[Drawing.Color]::FromArgb(130,120,140)
                    }
                    $cardInfo=[pscustomobject]@{InstanceId=$instanceId;ExperienceId=[string]$exp.id;Experience=$exp;Name=[string]$exp.name;InstanceRoot=$instanceRoot;CurrentRoot=$instanceRoot;ExperiencesRoot=$expRoot;Usage=$usage;IsRunning=$isRunning;IsInstalling=$false;DynamicPanel=$DynamicPanel;Catalog=$Catalog;Paths=$Paths;Role=$Role}
                    if($Role-eq'host'){
                        if($usage.Installed){
                            $buttonSpecs=@(
                                [pscustomobject]@{Text='ABRIR';Kind='host'},
                                [pscustomobject]@{Text='CARPETA';Kind='folder'},
                                [pscustomobject]@{Text='BORRAR';Kind='delete'}
                            )
                        }else{
                            $buttonSpecs=@([pscustomobject]@{Text='INSTALAR';Kind='install'})
                        }
                    }else{
                        if($usage.Installed){
                            $buttonSpecs=@(
                                [pscustomobject]@{Text='JUGAR';Kind='play'},
                                [pscustomobject]@{Text='CARPETA';Kind='install'},
                                [pscustomobject]@{Text='BORRAR';Kind='delete'}
                            )
                        }else{
                            $buttonSpecs=@([pscustomobject]@{Text='INSTALAR';Kind='install'})
                        }
                    }
                }else{
                    if($isRunning){
                        $detailLabel.Text="EN EJECUCION • $($usage.Label)"
                        $detailLabel.ForeColor=[Drawing.Color]::FromArgb(255,215,0)
                    }elseif($usage.Installed){
                        $detailLabel.Text="INSTALADO • $($usage.Label) • $compactPath"
                        $detailLabel.ForeColor=[Drawing.Color]::FromArgb(183,239,194)
                    }else{
                        $detailLabel.Text='NO INSTALADO'
                        $detailLabel.ForeColor=[Drawing.Color]::FromArgb(180,170,195)
                    }
                    $cardInfo=[pscustomobject]@{InstanceId=$instanceId;ExperienceId=[string]$exp.id;Experience=$exp;Name=[string]$exp.name;InstanceRoot=$instanceRoot;CurrentRoot=$instanceRoot;ExperiencesRoot=$expRoot;Usage=$usage;IsRunning=$isRunning;IsInstalling=$false;DynamicPanel=$DynamicPanel;Catalog=$Catalog;Paths=$Paths;Role=$Role}
                    if($Role-eq'host'){
                        if($usage.Installed){
                            $buttonSpecs=@(
                                [pscustomobject]@{Text=if($isRunning){'EN EJECUCION'}else{'ABRIR'};Kind='host'},
                                [pscustomobject]@{Text='CARPETA';Kind='folder'},
                                [pscustomobject]@{Text='BORRAR';Kind='delete'}
                            )
                        }else{
                            $buttonSpecs=@([pscustomobject]@{Text='INSTALAR';Kind='install'})
                        }
                    }else{
                        if($usage.Installed){
                            $liveHostExp=if($global:CocoLauncherLiveHostSession){[string]$global:CocoLauncherLiveHostSession.Experience.id}else{''}
                            $isHostPlayingThis=$liveHostExp-and$liveHostExp-eq[string]$exp.id
                            $playText=if($isRunning){'EN EJECUCION'}elseif($isHostPlayingThis){'UNIRSE'}else{'JUGAR'}
                            $playKind=if($isHostPlayingThis){'join'}else{'play'}
                            $buttonSpecs=@(
                                [pscustomobject]@{Text=$playText;Kind=$playKind},
                                [pscustomobject]@{Text='CARPETA';Kind='install'},
                                [pscustomobject]@{Text='BORRAR';Kind='delete'}
                            )
                        }else{
                            $buttonSpecs=@([pscustomobject]@{Text='INSTALAR';Kind='install'})
                        }
                    }
                }
            }
            $card.Controls.Add($imageBox);$gradient.Controls.Add($nameLabel);$gradient.Controls.Add($detailLabel)
            $cardTip="$([string]$exp.name)`r`n$([string]$exp.description)"
            if($isMedia){
                if($isInstallingAny){
                    $cardTip+="`r`n`r`n(Contenido multimedia disponible para reproducir mientras se instala un juego en segundo plano)."
                }
            }elseif($isThisInstalling){
                $cardTip+="`r`n`r`nEstado: Instalando archivos...`r`nRuta destino: $($cardInfo.InstanceRoot)`r`n(Puedes ver series o peliculas mientras se completa la instalacion)."
            }elseif($isOtherGameInstalling){
                $cardTip+="`r`n`r`nEstado: Bloqueado temporalmente`r`nInstalacion en curso: espera a que termine de instalar '$installingExpName' para abrir o instalar este juego.`r`n(Puedes ver series o peliculas mientras tanto)."
            }elseif($cardInfo.Usage.Installed){
                $cardTip+="`r`n`r`nEstado: Instalado ($($cardInfo.Usage.Label))`r`nRuta: $($cardInfo.InstanceRoot)"
            }else{
                $cardTip+="`r`n`r`nEstado: No instalado`r`nRuta destino: $($cardInfo.InstanceRoot)"
            }
            $script:CocoExperienceCardsToolTip.SetToolTip($card,$cardTip)
            $script:CocoExperienceCardsToolTip.SetToolTip($nameLabel,$cardTip)
            $script:CocoExperienceCardsToolTip.SetToolTip($detailLabel,$cardTip)
            $script:CocoExperienceCardsToolTip.SetToolTip($imageBox,$cardTip)
            if($cardInfo.IsMedia){
                $mediaAction=if($cardInfo.IsMovie){ {param($sender,$eventArgs)$info=$sender.Tag;if($info-and$info.IsMedia){& $mediaMovieUiCommand $info.Experience}}.GetNewClosure() }
                             else{ {param($sender,$eventArgs)$info=$sender.Tag;if($info-and$info.IsMedia){& $mediaEpisodeUiCommand $info.Experience}}.GetNewClosure() }
                foreach($control in @($card,$imageBox,$gradient,$nameLabel,$detailLabel)){
                    $control.Tag=$cardInfo;$control.Cursor=[Windows.Forms.Cursors]::Hand
                    $control.Add_Click($mediaAction)
                }
            }else{
                foreach($control in @($card,$imageBox,$gradient,$nameLabel,$detailLabel)){
                    $control.Tag=$cardInfo
                    if(-not$isInstallingAny-and-not$cardInfo.IsRunning-and[string]$cardInfo.Role-eq'client'){
                        $control.Cursor=[Windows.Forms.Cursors]::Hand
                        $control.Add_Click({
                            param($sender,$eventArgs)
                            if($script:CocoStorageInstallInProgress){return}
                            $info=$sender.Tag
                            if(-not$info-or$info.IsRunning){return}
                            if($info.Usage.Installed){
                                $liveHostExp=if($global:CocoLauncherLiveHostSession){[string]$global:CocoLauncherLiveHostSession.Experience.id}else{''}
                                if($liveHostExp-and$liveHostExp-eq[string]$info.ExperienceId){
                                    $script:CocoLauncherClientJoinRequested=[string]$info.ExperienceId
                                    $global:CocoLauncherClientJoinRequested=[string]$info.ExperienceId
                                }else{
                                    $script:CocoLauncherClientRequestedExperience=[string]$info.ExperienceId
                                    $global:CocoLauncherClientRequestedExperience=[string]$info.ExperienceId
                                }
                            }else{
                                &$experienceStorageInstallUiCommand $info
                            }
                        })
                    }else{
                        $control.Cursor=[Windows.Forms.Cursors]::Default
                    }
                }
            }
            $actionAreaWidth=[Math]::Max((Get-CocoLauncherUiMetric 140),$cardWidth-(2*$actionPadding));$buttonCount=$buttonSpecs.Count;$usableButtonWidth=[Math]::Max((Get-CocoLauncherUiMetric 100),$actionAreaWidth-([Math]::Max(0,$buttonCount-1)*$actionGap));$maxPerButton=[int][Math]::Floor($usableButtonWidth/[Math]::Max(1,$buttonCount));$buttonWidth=if($buttonCount-eq1){[int][Math]::Min($usableButtonWidth,(Get-CocoLauncherUiMetric 140))}else{$maxPerButton};$buttonGroupWidth=($buttonCount*$buttonWidth)+([Math]::Max(0,$buttonCount-1)*$actionGap);$buttonX=$cardWidth-$actionPadding-$buttonGroupWidth;$buttonY=$gradientHeight-$actionHeight-(Get-CocoLauncherUiMetric 6);$buttonIndex=0
            foreach($spec in $buttonSpecs){
                $button=New-Object Windows.Forms.Button;$button.Text=[string]$spec.Text;$button.Size=New-Object Drawing.Size($buttonWidth,$actionHeight);$button.Location=New-Object Drawing.Point($buttonX,$buttonY);$button.Tag=$cardInfo;$button.TabStop=$false;$button.UseCompatibleTextRendering=$false
                if($spec.Kind-eq'installing'){
                    $button.Enabled=$false
                    Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(65,45,25)) ([Drawing.Color]::FromArgb(255,215,0))
                    $button.Cursor=[Windows.Forms.Cursors]::Default
                }
                elseif($isOtherGameInstalling){
                    $button.Enabled=$false
                    Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(44,36,50)) ([Drawing.Color]::FromArgb(140,130,150))
                    $button.Cursor=[Windows.Forms.Cursors]::Default
                }
                elseif($spec.Kind-eq'delete'){
                    $enabled=[bool]($cardInfo.Usage.Installed-and-not$cardInfo.IsRunning);$button.Enabled=$enabled
                    if($enabled){Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(140,40,55)) ([Drawing.Color]::White)}
                    else{Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(60,50,60)) ([Drawing.Color]::FromArgb(150,150,150))}
                }
                elseif($spec.Kind-eq'host'-and$cardInfo.IsRunning){
                    $button.Enabled=$false;Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(60,50,60)) ([Drawing.Color]::FromArgb(150,150,150))
                }
                elseif($spec.Kind-eq'play'){
                    if($cardInfo.IsRunning){$button.Enabled=$false;Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(60,50,60)) ([Drawing.Color]::FromArgb(150,150,150))}
                    else{Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(75,45,115)) ([Drawing.Color]::White)}
                }
                elseif($spec.Kind-eq'join'){
                    Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(40,110,65)) ([Drawing.Color]::White)
                }
                elseif($spec.Kind-eq'folder'){
                    Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(75,45,105)) ([Drawing.Color]::FromArgb(224,190,255))
                }
                else{
                    Set-CocoFlatButtonStyle $button ([Drawing.Color]::FromArgb(83,47,117)) ([Drawing.Color]::White)
                }
                $buttonFontSize=if($buttonCount-ge3){(Get-CocoLauncherUiFontSize 8.5 6.5)}else{(Get-CocoLauncherUiFontSize 9 7)}
                $button.Font=New-Object Drawing.Font('Segoe UI Semibold',$buttonFontSize)
                $button.UseCompatibleTextRendering=$false
                if($script:CocoExperienceCardsToolTip){
                    $tipText=if($spec.Kind-eq'installing'){
                        "Instalando $($exp.name)... Puedes ver series o peliculas mientras se completa la instalacion."
                    }elseif($isOtherGameInstalling){
                        "Instalacion en curso: espera a que termine de instalar '$installingExpName' para abrir o instalar este juego.`r`n(Puedes ver series o peliculas mientras tanto)."
                    }else{
                        switch($spec.Kind){
                            'host'{if($cardInfo.IsRunning){'La partida ya esta en ejecucion.'}else{'Abrir y alojar partida para tus amigos.'}}
                            'play'{if($cardInfo.IsRunning){'La partida ya esta en ejecucion.'}else{'Iniciar la experiencia localmente.'}}
                            'join'{'Unirse a la partida que tiene abierta el host.'}
                            'install'{if($cardInfo.Usage.Installed){"Mover instalacion:`r`n$($cardInfo.InstanceRoot)"}else{"Descargar e instalar en:`r`n$($cardInfo.InstanceRoot)"}}
                            'folder'{if($cardInfo.IsMedia){'Abrir carpeta de descargas en el Explorador.'}else{"Ubicacion:`r`n$($cardInfo.InstanceRoot)`r`nClick para mover a otra carpeta."}}
                            'delete'{"Desinstalar y liberar $($cardInfo.Usage.Label) en disco."}
                            'movie'{'Reproducir pelicula.'}
                            'episode'{'Ver episodios disponibles.'}
                            default{[string]$spec.Text}
                        }
                    }
                    $script:CocoExperienceCardsToolTip.SetToolTip($button,$tipText)
                }
                if($spec.Kind-eq'movie'){$button.Add_Click({param($sender,$eventArgs)& $mediaMovieUiCommand $sender.Tag.Experience}.GetNewClosure())}
                elseif($spec.Kind-eq'episode'){$button.Add_Click({param($sender,$eventArgs)& $mediaEpisodeUiCommand $sender.Tag.Experience}.GetNewClosure())}
                elseif($spec.Kind-eq'folder'){$button.Add_Click({param($sender,$eventArgs)if($script:CocoStorageInstallInProgress){return};if($sender.Tag.IsMedia){&$mediaOpenFolderUiCommand $sender.Tag.Experience}else{&$experienceChangeLocationUiCommand $sender.Tag}}.GetNewClosure())}
                elseif($spec.Kind-eq'host'){$button.Tag=[string]$exp.id;$button.Add_Click({param($sender,$eventArgs)if($script:CocoStorageInstallInProgress){return};$script:CocoLauncherSelectedExperience=[string]$sender.Tag;$global:CocoLauncherSelectedExperience=[string]$sender.Tag})}
                elseif($spec.Kind-eq'play'){$button.Add_Click({param($sender,$eventArgs)if($script:CocoStorageInstallInProgress){return};if($sender.Tag.Usage.Installed-and-not$sender.Tag.IsRunning){$script:CocoLauncherClientRequestedExperience=[string]$sender.Tag.ExperienceId;$global:CocoLauncherClientRequestedExperience=[string]$sender.Tag.ExperienceId}})}
                elseif($spec.Kind-eq'join'){$button.Add_Click({param($sender,$eventArgs)if($script:CocoStorageInstallInProgress){return};if($sender.Tag.Usage.Installed-and-not$sender.Tag.IsRunning){$script:CocoLauncherClientJoinRequested=[string]$sender.Tag.ExperienceId;$global:CocoLauncherClientJoinRequested=[string]$sender.Tag.ExperienceId}})}
                elseif($spec.Kind-eq'install'){$button.Add_Click({param($sender,$eventArgs)if($script:CocoStorageInstallInProgress){return};if($sender.Tag.Usage.Installed){&$experienceChangeLocationUiCommand $sender.Tag}else{&$experienceStorageInstallUiCommand $sender.Tag}}.GetNewClosure())}
                elseif($spec.Kind-eq'delete'){$button.Add_Click({param($sender,$eventArgs)if($script:CocoStorageInstallInProgress){return};&$experienceFreeSpaceUiCommand $sender.Tag}.GetNewClosure())}
                $gradient.Controls.Add($button);$buttonIndex++;$buttonX+=$buttonWidth+$actionGap
            }
            $cardsContent.Controls.Add($card);$cardIndex++
        }
            $hostExperiences=$managedExperiences;$logicalRows=[int][Math]::Ceiling($hostExperiences.Count/2.0);$gridContentHeight=[int](Get-CocoLauncherUiMetric 22)+($logicalRows*$cardHeight)+([Math]::Max(0,$logicalRows-1)*$gap)+(Get-CocoLauncherUiMetric 8);
            $cardsContent.Size=[Drawing.Size]::new([Math]::Max(1,[int]$DynamicPanel.ClientSize.Width),[Math]::Max(1,[int]$gridContentHeight));
            $cardsContent.Location=[Drawing.Point]::new(0,0)
            $DynamicPanel.Controls.Add($cardsContent);
            $cardsContent.Location=[Drawing.Point]::new(0,0)
            $DynamicPanel.AutoScrollMinSize=[Drawing.Size]::new((Get-CocoLauncherUiMetric 0),[Math]::Max($gridContentHeight,(Get-CocoLauncherUiMetric ($hostExperiences.Count*70+22))));
            $DynamicPanel.AutoScroll=$false
    }finally{$DynamicPanel.ResumeLayout($true)}
    try{
        $DynamicPanel.AutoScrollPosition=[Drawing.Point]::new(0,0)
        $DynamicPanel.PerformLayout();
        Set-CocoExperienceCardsScrollContent $DynamicPanel $gridContentHeight;
        $DynamicPanel.Invalidate()
    }catch{}
    Register-CocoExperienceScrollWheel $DynamicPanel $DynamicPanel
    Set-CocoExperienceCardsNativeScrollStyle $DynamicPanel
    Update-CocoExperienceCardsScrollBar $DynamicPanel
}

function Update-CocoExperienceStorageManagerUi($DynamicPanel, $Catalog, $Paths, [int]$OffsetY = 0) {
    Update-CocoExperienceCardsUi $DynamicPanel $Catalog $Paths 'client'
}

function Set-CocoLauncherStep(
    [ValidateRange(1,10)][int]$Step,
    [string]$Title,
    [string]$Detail,
    [int]$Progress,
    [hashtable]$Context
){
    $Progress = [Math]::Max(0, [Math]::Min(100, $Progress))
    if($Context-and(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue)){Set-CocoDiagnosticContext $Context}
    if(Get-Command Set-CocoState -ErrorAction SilentlyContinue){Set-CocoState ("ETAPA {0}/10 | {1}"-f$Step,$Title) $Detail $Progress}
}

function Set-CocoLauncherIdleState([string]$Detail='Elige una experiencia para instalarla, alojar una partida o reproducir contenido.',[int]$Progress=100){
    if(Get-Command Set-CocoState -ErrorAction SilentlyContinue){Set-CocoState 'COCO LAUNCHER LISTO' $Detail $Progress}
}

function Request-CocoLauncherClose{
    try{
        $form=$script:CocoForm
        if(-not$form-or$form.IsDisposed){return}
        $script:CocoAllowClose=$true
        try{
            if($form.Tag-and$form.Tag.PSObject.Properties.Name-contains'AllowClose'){$form.Tag.AllowClose=$true}
        }catch{}
        $form.Close()
    }catch{
        try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Close()}}catch{}
    }
}

function Test-CocoSafeRelativePath([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)-or$Path.Contains(':')){return $false}
    $normalized=$Path-replace'\\','/'
    if($normalized.StartsWith('/')-or$normalized.EndsWith('/')){return $false}
    foreach($segment in $normalized.Split('/')){
        if([string]::IsNullOrWhiteSpace($segment)-or$segment-in@('.','..')){return $false}
    }
    return $true
}

function Test-CocoManagedGameRunning([string]$InstanceRoot, [string]$ExecutableName=''){
    if([string]::IsNullOrWhiteSpace($InstanceRoot)){return $false}
    # Las instancias no instaladas son la mayoría: sin carpeta no hay juego
    # vivo y se evita una consulta WMI por tarjeta en cada refresh.
    try{if(-not(Test-Path -LiteralPath $InstanceRoot -PathType Container)){return $false}}catch{return $false}
    $full=[IO.Path]::GetFullPath($InstanceRoot)
    try{
        # El refresh de tarjetas llamaba a WMI una vez por experiencia (N
        # consultas seguidas en el hilo UI = congelamiento). Se cachea el
        # snapshot unos segundos y cada tarjeta filtra en memoria.
        $now=[DateTime]::UtcNow
        $cacheValid=$false
        try{
            $cacheValid=($script:CocoProcessSnapshotAt-and$script:CocoProcessSnapshot-and(($now-$script:CocoProcessSnapshotAt).TotalSeconds-lt3))
        }catch{$cacheValid=$false}
        if($cacheValid){$all=@($script:CocoProcessSnapshot)}
        else{
            $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
            try{$script:CocoProcessSnapshot=$all;$script:CocoProcessSnapshotAt=$now}catch{}
        }
        $matches=@($all|Where-Object{
            if([string]::IsNullOrWhiteSpace($_.CommandLine)-and[string]::IsNullOrWhiteSpace($_.ExecutablePath)){return $false}
            $inLine=-not[string]::IsNullOrWhiteSpace($_.CommandLine)-and$_.CommandLine.IndexOf($full,[StringComparison]::OrdinalIgnoreCase)-ge0
            $inPath=-not[string]::IsNullOrWhiteSpace($_.ExecutablePath)-and$_.ExecutablePath.IndexOf($full,[StringComparison]::OrdinalIgnoreCase)-ge0
            if(-not($inLine-or$inPath)){return $false}
            if(-not[string]::IsNullOrWhiteSpace($ExecutableName)){return $_.Name-eq$ExecutableName}
            return $true
        })
        return $matches.Count-gt0
    }catch{return $false}
}

function Get-CocoLauncherIdentityHint([string]$MinecraftRoot){
    $unknown=[pscustomobject]@{Mode='unknown';Confidence='none';Username='';Source='none';Reason='No hay evidencia local suficiente.'}
    if([string]::IsNullOrWhiteSpace($MinecraftRoot)-or-not(Test-Path -LiteralPath $MinecraftRoot -PathType Container)){return $unknown}

    $tlauncherProfiles=Join-Path $MinecraftRoot 'TlauncherProfiles.json'
    if(Test-Path -LiteralPath $tlauncherProfiles -PathType Leaf){
        try{
            $profile=Get-Content -LiteralPath $tlauncherProfiles -Raw|ConvertFrom-Json
            $accounts=if($profile.accounts){@($profile.accounts.PSObject.Properties)}else{@()}
            $selected=[string]$profile.selectedAccount
            if([string]::IsNullOrWhiteSpace($selected)){$selected=[string]$profile.selectedAccountUUID}
            if([string]::IsNullOrWhiteSpace($selected)){$selected=[string]$profile.freeAccountUUID}
            $property=$null
            if(-not[string]::IsNullOrWhiteSpace($selected)){$property=$profile.accounts.PSObject.Properties[$selected]}
            if(-not$property-and$accounts.Count-eq1){$property=$accounts[0]}
            if($property){
                $account=$property.Value
                $type=([string]$account.type).Trim().ToLowerInvariant()
                $username=([string]$account.displayName).Trim()
                if([string]::IsNullOrWhiteSpace($username)){$username=([string]$account.username).Trim()}
                if([string]::IsNullOrWhiteSpace($username)){$username=([string]$account.userID).Trim()}
                if(Test-CocoMinecraftUsername $username){
                    return [pscustomobject]@{
                        Mode='offline';Confidence='high';Username=$username;Source='tlauncher-profile'
                        Reason="Coco reutilizara el nombre seleccionado en TLauncher sin abrirlo ni copiar sus credenciales."
                    }
                }
                return [pscustomobject]@{Mode='unknown';Confidence='none';Username='';Source='tlauncher-profile';Reason="TLauncher no expone un nombre Minecraft valido para reutilizar."}
            }
            if($accounts.Count-gt1){return [pscustomobject]@{Mode='unknown';Confidence='none';Username='';Source='tlauncher-profile';Reason='TLauncher contiene varias cuentas y ninguna seleccion inequivoca.'}}
        }catch{
            return [pscustomobject]@{Mode='unknown';Confidence='none';Username='';Source='tlauncher-profile';Reason='El perfil TLauncher no pudo analizarse de forma segura.'}
        }
    }

    $officialAccounts=Join-Path $MinecraftRoot 'launcher_accounts.json'
    if(Test-Path -LiteralPath $officialAccounts -PathType Leaf){
        try{
            $profile=Get-Content -LiteralPath $officialAccounts -Raw|ConvertFrom-Json
            $accounts=if($profile.accounts){@($profile.accounts.PSObject.Properties)}else{@()}
            $active=[string]$profile.activeAccountLocalId
            $property=if($active){$profile.accounts.PSObject.Properties[$active]}else{$null}
            if(-not$property-and$accounts.Count-eq1){$property=$accounts[0]}
            if($property){
                $username=[string]$property.Value.minecraftProfile.name
                if(Test-CocoMinecraftUsername $username){
                    return [pscustomobject]@{
                        Mode='offline';Confidence='high';Username=$username;Source='official-launcher-account'
                        Reason='Coco reutilizara el nombre visible del Launcher oficial como identidad local.'
                    }
                }
            }
        }catch{}
    }

    $legacyProfiles=Join-Path $MinecraftRoot 'launcher_profiles.json'
    if(Test-Path -LiteralPath $legacyProfiles -PathType Leaf){
        try{
            $profile=Get-Content -LiteralPath $legacyProfiles -Raw|ConvertFrom-Json
            $names=@($profile.authenticationDatabase.PSObject.Properties|ForEach-Object{
                [string]$_.Value.profiles.PSObject.Properties.Value.displayName
            }|Where-Object{Test-CocoMinecraftUsername $_}|Select-Object -Unique)
            if($names.Count-eq1){
                return [pscustomobject]@{
                    Mode='offline';Confidence='medium';Username=$names[0];Source='official-launcher-profile'
                    Reason='Coco encontro un unico nombre historico valido del Launcher oficial.'
                }
            }
        }catch{}
    }

    foreach($officialProfile in 'launcher_profiles_microsoft_store.json','launcher_profiles.json'){
        if(Test-Path -LiteralPath (Join-Path $MinecraftRoot $officialProfile) -PathType Leaf){
            return [pscustomobject]@{
                Mode='unknown';Confidence='none';Username='';Source='official-launcher-present'
                Reason='El Launcher oficial esta instalado, pero no expone de forma segura el nombre del jugador.'
            }
        }
    }
    return $unknown
}

function Test-CocoMinecraftUsername([string]$Username){
    if([string]::IsNullOrWhiteSpace($Username)){return $false}
    $clean=[regex]::Replace($Username,'[^A-Za-z0-9_]','')
    return $clean.Length -ge 3 -and $clean.Length -le 16
}

function Read-CocoLauncherIdentityState([string]$Path){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{$state=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "El estado de identidad Coco no es JSON valido: $($_.Exception.Message)"}
    if([int]$state.schemaVersion-ne1){throw 'El estado de identidad Coco usa un schemaVersion no soportado.'}
    # "microsoft" sólo se acepta para migrar estados creados por 0.5.50-0.5.57.
    # Los lanzamientos nuevos usan exclusivamente identidad local/offline.
    if($state.mode-notin@('microsoft','offline')){throw 'El estado de identidad Coco tiene un modo invalido.'}
    if($state.mode-eq'offline'-and -not(Test-CocoMinecraftUsername ([string]$state.username))){throw 'La identidad local guardada no tiene un nombre Minecraft valido.'}
    if(-not[string]::IsNullOrWhiteSpace([string]$state.uuid)-and[string]$state.uuid-notmatch'^[a-fA-F0-9-]{32,36}$'){throw 'La identidad Microsoft guardada tiene un UUID invalido.'}
    [pscustomobject]@{
        schemaVersion=1
        mode=[string]$state.mode
        username=[string]$state.username
        uuid=[string]$state.uuid
        decisionSource=[string]$state.decisionSource
        configuredAtUtc=[string]$state.configuredAtUtc
    }
}

function Save-CocoLauncherIdentityState(
    [string]$Path,
    [ValidateSet('offline')][string]$Mode,
    [string]$Username='',
    [string]$Uuid='',
    [string]$DecisionSource='user'
){
    if(-not(Test-CocoMinecraftUsername $Username)){throw 'El nombre local debe tener entre 3 y 16 caracteres y usar solo letras, numeros o guion bajo.'}
    if(-not[string]::IsNullOrWhiteSpace($Uuid)){throw 'La identidad local de Coco no acepta un UUID externo.'}
    $parent=Split-Path $Path -Parent
    if([string]::IsNullOrWhiteSpace($parent)){throw 'El estado de identidad requiere una ruta con directorio.'}
    New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $payload=[ordered]@{
        schemaVersion=1
        mode=$Mode
        username=$Username
        uuid=$Uuid
        decisionSource=$DecisionSource
        configuredAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    $temporary="$Path.new-$PID-$([guid]::NewGuid().ToString('N'))"
    try{
        [IO.File]::WriteAllText($temporary,($payload|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    Read-CocoLauncherIdentityState $Path
}

function Resolve-CocoLauncherIdentity([string]$StatePath,[string]$MinecraftRoot){
    $saved=Read-CocoLauncherIdentityState $StatePath
    if($saved-and$saved.mode-eq'offline'){
        return [pscustomobject]@{Status='configured';RequiresChoice=$false;WasAutomatic=$false;Identity=$saved;Hint=$null}
    }
    if($saved-and$saved.mode-eq'microsoft'-and(Test-CocoMinecraftUsername ([string]$saved.username))){
        $identity=Save-CocoLauncherIdentityState $StatePath offline ([string]$saved.username) '' 'migrated-from-microsoft'
        return [pscustomobject]@{Status='configured';RequiresChoice=$false;WasAutomatic=$true;Identity=$identity;Hint=$null}
    }
    $hint=Get-CocoLauncherIdentityHint $MinecraftRoot
    if($hint.Confidence-in@('high','medium')-and(Test-CocoMinecraftUsername ([string]$hint.Username))){
        $identity=Save-CocoLauncherIdentityState $StatePath offline ([string]$hint.Username) '' ([string]$hint.Source)
        return [pscustomobject]@{Status='configured';RequiresChoice=$false;WasAutomatic=$true;Identity=$identity;Hint=$hint}
    }
    [pscustomobject]@{Status='choice-required';RequiresChoice=$true;WasAutomatic=$false;Identity=$null;Hint=$hint}
}

function Test-CocoSkinPng([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Selecciona un archivo PNG.'}
    $item=Get-Item -LiteralPath $Path
    if($item.Length-lt67-or$item.Length-gt1048576){throw 'La skin debe ser un PNG de hasta 1 MB.'}
    $bytes=[IO.File]::ReadAllBytes($Path)
    $signature=[byte[]](137,80,78,71,13,10,26,10)
    for($i=0;$i-lt$signature.Length;$i++){if($bytes[$i]-ne$signature[$i]){throw 'El archivo elegido no es un PNG valido.'}}
    Add-Type -AssemblyName System.Drawing
    $stream=[IO.MemoryStream]::new($bytes,$false)
    $image=$null
    try{
        $image=[Drawing.Image]::FromStream($stream,$true,$true)
        if($image.RawFormat.Guid-ne[Drawing.Imaging.ImageFormat]::Png.Guid){throw 'El archivo elegido no es un PNG valido.'}
        if($image.Width-ne64-or$image.Height-notin@(32,64)){throw 'La skin debe medir exactamente 64x64 o 64x32 pixeles.'}
        [pscustomobject]@{
            Path=$item.FullName;Width=$image.Width;Height=$image.Height;Size=[int64]$item.Length
            Sha256=Get-CocoFileSha256 $item.FullName
        }
    }finally{if($image){$image.Dispose()};$stream.Dispose()}
}

function Import-CocoUserSkin([string]$SourcePath,[string]$Username,[string]$SkinRoot,[string]$StatePath){
    if(-not(Test-CocoMinecraftUsername $Username)){throw 'Configura un nombre de jugador valido antes de elegir la skin.'}
    $validated=Test-CocoSkinPng $SourcePath
    New-Item -ItemType Directory -Path $SkinRoot,(Split-Path $StatePath -Parent) -Force|Out-Null
    $destination=Join-Path $SkinRoot "$Username.png"
    $temporary="$destination.new-$PID"
    [IO.File]::WriteAllBytes($temporary,[IO.File]::ReadAllBytes($validated.Path))
    Move-Item -LiteralPath $temporary -Destination $destination -Force
    $state=[ordered]@{
        schemaVersion=1;username=$Username;sha256=$validated.Sha256;pendingUpload=$true
        selectedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    $stateTemporary="$StatePath.new-$PID"
    [IO.File]::WriteAllText($stateTemporary,($state|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $stateTemporary -Destination $StatePath -Force
    [pscustomobject]@{Path=$destination;Username=$Username;Sha256=$validated.Sha256;PendingUpload=$true}
}

function New-CocoSkinHeadPreview([string]$Path,[int]$Size=64){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    [void](Test-CocoSkinPng $Path)
    Add-Type -AssemblyName System.Drawing
    $bytes=[IO.File]::ReadAllBytes($Path);$stream=[IO.MemoryStream]::new($bytes,$false);$source=$null
    try{
        $source=[Drawing.Bitmap]::new($stream)
        $preview=[Drawing.Bitmap]::new($Size,$Size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics=[Drawing.Graphics]::FromImage($preview)
        try{
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::Half
            $destination=[Drawing.Rectangle]::new(0,0,$Size,$Size)
            $graphics.DrawImage($source,$destination,[Drawing.Rectangle]::new(8,8,8,8),[Drawing.GraphicsUnit]::Pixel)
            if($source.Height-ge64){$graphics.DrawImage($source,$destination,[Drawing.Rectangle]::new(40,8,8,8),[Drawing.GraphicsUnit]::Pixel)}
        }finally{$graphics.Dispose()}
        return $preview
    }finally{if($source){$source.Dispose()};$stream.Dispose()}
}

function Install-CocoSkinRegistry([string]$SkinRoot,[string]$InstanceRoot){
    if(-not(Test-Path -LiteralPath $SkinRoot -PathType Container)){return 0}
    $destinationRoot=Join-Path $InstanceRoot 'CustomSkinLoader\LocalSkin\skins'
    New-Item -ItemType Directory -Path $destinationRoot -Force|Out-Null
    $count=0
    foreach($skin in Get-ChildItem -LiteralPath $SkinRoot -File -Filter '*.png'){
        $username=[IO.Path]::GetFileNameWithoutExtension($skin.Name)
        if(-not(Test-CocoMinecraftUsername $username)){continue}
        [void](Test-CocoSkinPng $skin.FullName)
        Copy-Item -LiteralPath $skin.FullName -Destination (Join-Path $destinationRoot $skin.Name) -Force
        $count++
    }
    $count
}

function Initialize-CocoSkinRegistry($GlobalPolicies,[string]$EngineRoot,[string]$SkinRoot){
    New-Item -ItemType Directory -Path $SkinRoot -Force|Out-Null
    foreach($skin in @($GlobalPolicies.customSkinLoader.localSkins)){
        $username=[string]$skin.username
        if(-not(Test-CocoMinecraftUsername $username)){throw 'La politica global contiene un nombre de skin invalido.'}
        $source=Join-Path $EngineRoot (([string]$skin.embeddedPath)-replace'/','\')
        $bytes=$null
        if(Test-Path -LiteralPath $source -PathType Leaf){$bytes=[IO.File]::ReadAllBytes($source)}
        else{
            $developmentSource=Join-Path (Split-Path $EngineRoot -Parent) "launcher\assets\skins\$username.png.base64"
            if(Test-Path -LiteralPath $developmentSource -PathType Leaf){$bytes=[Convert]::FromBase64String(([IO.File]::ReadAllText($developmentSource)).Trim())}
        }
        if(-not$bytes){throw "Falta la skin global de $username."}
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        if($hash-ne([string]$skin.sha256).ToLowerInvariant()){throw "La skin global de $username no coincide con su hash."}
        $destination=Join-Path $SkinRoot "$username.png"
        if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){[IO.File]::WriteAllBytes($destination,$bytes)}
    }
}

function Get-CocoPortableMcVersionSpec($Experience){
    $runtime=$Experience.runtime
    if(-not$runtime){throw 'La experiencia no declara runtime.'}
    $game=[string]$runtime.minecraftVersion
    $loader=[string]$runtime.loader
    $loaderVersion=[string]$runtime.loaderVersion
    if([string]::IsNullOrWhiteSpace($game)-or[string]::IsNullOrWhiteSpace($loaderVersion)){throw 'La experiencia no fija las versiones de Minecraft y loader.'}
    switch($loader){
        'fabric'{return "fabric:$game`:$loaderVersion"}
        'forge'{
            # PortableMC espera la version completa del instalador Forge
            # (por ejemplo 1.20.1-47.4.10), aunque los manifests CurseForge
            # separan gameVersion de modLoader.version.
            $fullLoader=if($loaderVersion.StartsWith($game+'-',[StringComparison]::OrdinalIgnoreCase)){$loaderVersion}else{"$game-$loaderVersion"}
            return "forge::$fullLoader"
        }
        'neoforge'{return "neoforge::$loaderVersion"}
        default{throw "PortableMC no soporta el loader Coco '$loader'."}
    }
}

function New-CocoPortableMcStartArguments(
    $Experience,
    $Identity,
    [string]$MainDir,
    [string]$InstanceDir,
    [string]$MicrosoftDatabase,
    [switch]$Dry
){
    if(-not$Experience-or-not$Identity){throw 'Faltan experiencia o identidad para construir el lanzamiento.'}
    foreach($path in $MainDir,$InstanceDir,$MicrosoftDatabase){if([string]::IsNullOrWhiteSpace($path)){throw 'Las rutas de PortableMC no pueden estar vacias.'}}
    $arguments=[Collections.Generic.List[string]]::new()
    foreach($value in '--main-dir',$MainDir,'--msa-db-file',$MicrosoftDatabase,'--output','machine','start',(Get-CocoPortableMcVersionSpec $Experience),'--mc-dir',$InstanceDir,'--bin-dir',(Join-Path $InstanceDir 'bin'),'--jvm-policy','mojang-then-system'){$arguments.Add([string]$value)}
    if($Dry){$arguments.Add('--dry')}
    if($Identity.mode-eq'offline'){
        if(-not(Test-CocoMinecraftUsername ([string]$Identity.username))){throw 'La identidad local no tiene un nombre Minecraft valido.'}
        $arguments.Add('--username');$arguments.Add([string]$Identity.username)
    }else{throw 'Coco Launcher usa exclusivamente identidad local para sus partidas privadas.'}
    if($Experience.launch.memory){
        $minimum=[int]$Experience.launch.memory.minimumMb;$recommended=[int]$Experience.launch.memory.recommendedMb
        $fraction=[double]$Experience.launch.memory.maximumPhysicalFraction
        $physicalMb=0
        try{$physicalMb=[int]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory/1MB)}catch{}
        $heap=if($physicalMb-gt0){[Math]::Min($recommended,[Math]::Floor($physicalMb*$fraction))}else{[Math]::Min($recommended,4096)}
        $heap=[Math]::Max($minimum,[int]$heap)
        $arguments.Add(("--jvm-arg=-Xms1024m,-Xmx{0}m"-f$heap))
    }
    if($Experience.launch.jvmArgs){
        foreach($jvmArg in @($Experience.launch.jvmArgs)){
            if(-not[string]::IsNullOrWhiteSpace([string]$jvmArg)){
                $arguments.Add(("--jvm-arg={0}"-f[string]$jvmArg))
            }
        }
    }
    if($Experience.runtimePolicies-and[string]$Experience.runtimePolicies.essentialLoaderUpdates-eq'disabled'){
        # La propiedad desactiva el update fuera del lock; los dos auto-answer
        # cubren loaders antiguos que ya hubieran dejado una version pendiente.
        $arguments.Add('--jvm-arg=-Dessential.autoUpdate=false,-Dessential.stage1.autoUpdate=false,-Dessential.stage2.autoUpdate=false')
    }
    if(-not$Dry-and[bool]$Experience.launch.autoJoin){
        $endpointHost=[string]$Experience.hosting.host
        $port=[int]$Experience.hosting.port
        if([string]::IsNullOrWhiteSpace($endpointHost)-or$port-lt1-or$port-gt65535){throw 'La experiencia no declara un endpoint de autoingreso valido.'}
        $arguments.Add('--join-server');$arguments.Add($endpointHost);$arguments.Add('--join-server-port');$arguments.Add([string]$port)
    }
    $arguments.ToArray()
}

function ConvertTo-CocoWindowsProcessArgument([AllowEmptyString()][string]$Value){
    if($null-eq$Value-or$Value.Length-eq0){return '""'}
    if($Value-notmatch'[\s"]'){return $Value}
    $builder=[Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes=0
    foreach($character in $Value.ToCharArray()){
        if($character-eq'\'){$slashes++;continue}
        if($character-eq'"'){
            [void]$builder.Append(('\'*(($slashes*2)+1)))
            [void]$builder.Append('"')
            $slashes=0
            continue
        }
        if($slashes){[void]$builder.Append(('\'*$slashes));$slashes=0}
        [void]$builder.Append($character)
    }
    if($slashes){[void]$builder.Append(('\'*($slashes*2)))}
    [void]$builder.Append('"')
    $builder.ToString()
}

function Invoke-CocoPortableMcCommand(
    [string]$Executable,
    [string[]]$Arguments,
    [int]$TimeoutSeconds=120,
    [string]$ActivityTitle='',
    [string]$ActivityDetail='',
    [ValidateRange(0,100)][int]$ProgressStart=78,
    [ValidateRange(0,100)][int]$ProgressEnd=88
){
    if(-not(Test-Path -LiteralPath $Executable -PathType Leaf)){throw "No existe PortableMC: $Executable"}
    $tempLog = Join-Path $env:TEMP ("coco-portablemc-prep-$PID-$([guid]::NewGuid().ToString('N')).log")
    $process = Start-CocoPortableMcGame $Executable $Arguments $tempLog
    try{
        $watch=[Diagnostics.Stopwatch]::StartNew();$lastUiSecond=-1
        while(-not$process.HasExited){
            if($TimeoutSeconds-gt0-and$watch.Elapsed.TotalSeconds-ge$TimeoutSeconds){
                try{$process.Kill()}catch{}
                throw "PortableMC excedio el timeout de $TimeoutSeconds segundos."
            }
            $second=[int]$watch.Elapsed.TotalSeconds
            if($ActivityTitle-and$second-ne$lastUiSecond){
                $lastUiSecond=$second
                $lastLine = if(Test-Path -LiteralPath $tempLog){
                    try{
                        $lines = @(Get-Content -LiteralPath $tempLog -Tail 5 -ErrorAction SilentlyContinue|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
                        if($lines.Count){ [string]$lines[-1] }else{ 'Verificando Java 17, Forge y assets oficiales de Mojang...' }
                    }catch{ 'Verificando Java 17, Forge y assets oficiales de Mojang...' }
                }else{ 'Verificando Java 17, Forge y assets oficiales de Mojang...' }
                if($lastLine.Length -gt 75){ $lastLine = $lastLine.Substring(0, 72) + '...' }
                $fraction=if($TimeoutSeconds-gt0){[Math]::Min(.92,$watch.Elapsed.TotalSeconds/$TimeoutSeconds)}else{0}
                $progress=$ProgressStart+[int](($ProgressEnd-$ProgressStart)*$fraction)
                if(Get-Command Set-CocoState -ErrorAction SilentlyContinue){
                    Set-CocoState $ActivityTitle ("{0}`r`nTiempo transcurrido {1:mm\:ss} | {2}" -f $ActivityDetail, $watch.Elapsed, $lastLine) $progress
                }
            }
            if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
            Start-Sleep -Milliseconds 250
        }
        $process.WaitForExit()
        $outText = if(Test-Path -LiteralPath $tempLog){ try{ Get-Content -LiteralPath $tempLog -Raw }catch{ '' } }else{ '' }
        [pscustomobject]@{ExitCode=$process.ExitCode;Stdout=$outText;Stderr='';Arguments=@($Arguments)}
    }finally{
        if($process){$process.Dispose()}
        if(Test-Path -LiteralPath $tempLog){ Remove-Item -LiteralPath $tempLog -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertFrom-CocoPortableMcMachineValue([string]$Value){
    if($null-eq$Value){return ''}
    # PortableMC define exclusivamente estas dos secuencias de escape en salida machine.
    return $Value.Replace('\t',"`t").Replace('\n',"`n")
}

function Start-CocoPortableMcGame([string]$Executable,[string[]]$Arguments,[string]$LogPath){
    if(-not(Test-Path -LiteralPath $Executable -PathType Leaf)){throw "No existe PortableMC: $Executable"}
    $parent=Split-Path $LogPath -Parent;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    if(-not('CocoPortableMcLogPump' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public sealed class CocoPortableMcLogPump
{
    private readonly string path;
    private readonly object sync = new object();
    public DataReceivedEventHandler DataHandler { get; private set; }

    public CocoPortableMcLogPump(string path)
    {
        this.path = path;
        this.DataHandler = new DataReceivedEventHandler(HandleData);
    }

    private void HandleData(object sender, DataReceivedEventArgs eventArgs)
    {
        if (eventArgs.Data == null) return;
        lock (sync)
        {
            File.AppendAllText(path, eventArgs.Data + Environment.NewLine, new UTF8Encoding(false));
        }
    }
}
'@
    }
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[IO.Path]::GetFullPath($Executable)
    $start.Arguments=(@($Arguments|ForEach-Object{ConvertTo-CocoWindowsProcessArgument ([string]$_)})-join' ')
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$process.EnableRaisingEvents=$true
    $pump=[CocoPortableMcLogPump]::new([IO.Path]::GetFullPath($LogPath))
    $process.add_OutputDataReceived($pump.DataHandler);$process.add_ErrorDataReceived($pump.DataHandler)
    if(-not$process.Start()){throw 'Windows no inicio PortableMC.'}
    $process.BeginOutputReadLine();$process.BeginErrorReadLine()
    # El handler es C# puro: los callbacks asincronos no intentan ejecutar un
    # ScriptBlock PowerShell desde un hilo que carece de runspace.
    $process|Add-Member -NotePropertyName CocoLogPump -NotePropertyValue $pump
    $process
}

function Wait-CocoPortableMcGame($Process,[switch]$PumpUi,[switch]$Dispose){
    if(-not$Process){throw 'No existe un proceso PortableMC que supervisar.'}
    try{
        while(-not$Process.HasExited){
            if($PumpUi-and('System.Windows.Forms.Application'-as[type])){[Windows.Forms.Application]::DoEvents()}
            Start-Sleep -Milliseconds 250
        }
        # La segunda espera permite que los lectores asincronos terminen de
        # vaciar stdout/stderr antes de consultar el codigo o cerrar Coco.
        $Process.WaitForExit()
        return [int]$Process.ExitCode
    }finally{
        if($Dispose){$Process.Dispose()}
    }
}

function Wait-CocoManagedMinecraftWindow([string]$InstanceRoot,$PortableProcess,[int]$TimeoutSeconds=90){
    if([string]::IsNullOrWhiteSpace($InstanceRoot)){return $null}
    # Los tests de ciclo de vida usan un proceso señuelo que no es PortableMC.
    # En produccion esta guarda tambien evita atribuir a Minecraft un helper
    # externo devuelto por una integracion futura.
    try{if(([string]$PortableProcess.ProcessName)-notmatch'(?i)portablemc'){return $null}}catch{return $null}
    $watch=[Diagnostics.Stopwatch]::StartNew();$full=[IO.Path]::GetFullPath($InstanceRoot);$lastSecond=-1
    while($watch.Elapsed.TotalSeconds-lt$TimeoutSeconds){
        if($PortableProcess.HasExited){
            $PortableProcess.WaitForExit()
            throw "PortableMC termino antes de abrir Minecraft (codigo $($PortableProcess.ExitCode))."
        }
        try{
            $java=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop|Where-Object{
                $_.CommandLine-and$_.CommandLine.IndexOf($full,[StringComparison]::OrdinalIgnoreCase)-ge0
            }|Select-Object -First 1)[0]
            if($java){return $java}
        }catch{}
        $second=[int]$watch.Elapsed.TotalSeconds
        if($second-ne$lastSecond){
            $lastSecond=$second
            Set-CocoLauncherStep 8 'ABRIENDO MINECRAFT' ("Windows esta iniciando Java y la ventana del juego | {0:mm\:ss}"-f$watch.Elapsed) (89+[int](5*[Math]::Min(.95,$watch.Elapsed.TotalSeconds/$TimeoutSeconds)))
        }
        [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 400
    }
    throw "Minecraft no aparecio despues de $TimeoutSeconds segundos."
}

function Invoke-CocoPortableMcPreparation(
    [string]$Executable,
    [string[]]$Arguments,
    [string]$ExperienceId,
    [ValidateRange(1,6)][int]$MaximumAttempts=4
){
    $dryArguments=@($Arguments)
    if($dryArguments-notcontains'--dry'){$dryArguments+=,'--dry'}
    $lastDetail=''
    for($attempt=1;$attempt-le$MaximumAttempts;$attempt++){
        $result=Invoke-CocoPortableMcCommand $Executable $dryArguments 900 'ETAPA 6/10 | PREPARANDO MINECRAFT' ("{0} | intento {1}/{2}"-f$ExperienceId,$attempt,$MaximumAttempts) 78 88
        if($result.ExitCode-eq0){return $result}
        $lines=@((([string]$result.Stderr)+"`n"+([string]$result.Stdout))-split"`r?`n"|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
        $lastDetail=(@($lines|Select-Object -Last 25)-join' | ')
        if($attempt-lt$MaximumAttempts){
            if(Get-Command Set-CocoState -ErrorAction SilentlyContinue){
                Set-CocoLauncherStep 6 'REINTENTANDO PREPARAR MINECRAFT' ("Intento {0}/{1}; se reutilizan todas las descargas verificadas."-f($attempt+1),$MaximumAttempts) 82
            }
            $sleepUntil=[DateTime]::UtcNow.AddSeconds([Math]::Pow(2,$attempt-1))
            while([DateTime]::UtcNow -lt $sleepUntil){
                if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
                Start-Sleep -Milliseconds 100
            }
        }
    }
    throw "PortableMC no pudo preparar '$ExperienceId' despues de $MaximumAttempts intentos: $lastDetail"
}

function Get-CocoHostPreferencesPath {
    $root=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'
    Join-Path $root 'host-preferences.json'
}

function Read-CocoHostPreferences {
    $path=Get-CocoHostPreferencesPath
    if(Test-Path -LiteralPath $path -PathType Leaf){
        try{return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{}
    }
    return [pscustomobject]@{forceJoin=$true}
}

function Save-CocoHostPreferences([bool]$ForceJoin){
    $path=Get-CocoHostPreferencesPath
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force -ErrorAction SilentlyContinue|Out-Null
    [ordered]@{forceJoin=$ForceJoin;updatedAt=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
}

function Publish-CocoSessionAnnouncement(
    $Catalog,
    [string]$ExperienceId,
    [ValidateSet('preparing','ready','stopping')][string]$State,
    [string]$SessionId,
    [string]$Path,
    [int]$TtlSeconds=30,
    [bool]$ForceJoin=$true
){
    if($SessionId-notmatch'^[a-fA-F0-9-]{32,36}$'){throw 'El sessionId Coco no es valido.'}
    $experience=@($Catalog.experiences|Where-Object id -eq $ExperienceId|Select-Object -First 1)[0]
    if(-not$experience){throw "La experiencia '$ExperienceId' no existe en el catalogo."}
    if($experience.managementMode-ne'managed'-or($experience.launch.workflow-ne'coco-managed'-and$experience.launch.workflow-ne'coco-standalone')){throw "La experiencia '$ExperienceId' usa su launcher externo y no puede anunciarse como sesion Coco Launcher."}
    $maximum=[int]$Catalog.sessionDiscovery.maximumTtlSeconds
    if($TtlSeconds-lt5-or$TtlSeconds-gt$maximum){throw 'El TTL solicitado para la sesion Coco es invalido.'}
    $now=[DateTime]::UtcNow
    $payload=[ordered]@{
        schemaVersion=1;sessionId=$SessionId;state=$State;experienceId=[string]$experience.id
        packVersion=[string]$experience.pack.version;host=[string]$experience.hosting.host;port=[int]$experience.hosting.port
        forceJoin=$ForceJoin
        issuedAtUtc=$now.ToString('o');expiresAtUtc=$now.AddSeconds($TtlSeconds).ToString('o')
    }
    $parent=Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $temporary="$Path.new-$PID-$([guid]::NewGuid().ToString('N'))"
    try{
        [IO.File]::WriteAllText($temporary,($payload|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    [pscustomobject]$payload
}

function Test-CocoSessionAnnouncement($Catalog,$Announcement){
    if(-not$Announcement-or[int]$Announcement.schemaVersion-ne1){throw 'La respuesta de sesion Coco usa un schemaVersion invalido.'}
    if($Announcement.state-eq'offline'){return [pscustomobject]@{State='offline';Experience=$null;Announcement=$Announcement}}
    if($Announcement.state-notin@('preparing','ready','stopping')){throw 'La respuesta de sesion Coco contiene un estado invalido.'}
    if([string]$Announcement.sessionId-notmatch'^[a-fA-F0-9-]{32,36}$'){throw 'La respuesta de sesion Coco contiene un sessionId invalido.'}
    $experience=@($Catalog.experiences|Where-Object id -eq([string]$Announcement.experienceId)|Select-Object -First 1)[0]
    if(-not$experience){throw 'La sesion anuncia una experiencia que no existe en el catalogo firmado.'}
    if($experience.managementMode-ne'managed'-or($experience.launch.workflow-ne'coco-managed'-and$experience.launch.workflow-ne'coco-standalone')){throw 'La sesion intento anunciar una experiencia reservada al launcher externo.'}
    if([string]$Announcement.packVersion-ne[string]$experience.pack.version){throw 'La sesion y el catalogo no coinciden en packVersion.'}
    if([string]$Announcement.host-ne[string]$experience.hosting.host-or[int]$Announcement.port-ne[int]$experience.hosting.port){throw 'La sesion intento cambiar el endpoint fijado de la experiencia.'}
    try{$issued=[DateTime]::Parse([string]$Announcement.issuedAtUtc).ToUniversalTime();$expires=[DateTime]::Parse([string]$Announcement.expiresAtUtc).ToUniversalTime()}catch{throw 'La sesion contiene fechas invalidas.'}
    $now=[DateTime]::UtcNow
    if($expires-le$now){throw 'La sesion Coco expiro.'}
    if($issued-gt$now.AddSeconds(30)){throw 'La sesion Coco viene del futuro.'}
    if(($expires-$issued).TotalSeconds-gt([int]$Catalog.sessionDiscovery.maximumTtlSeconds+1)){throw 'La sesion Coco excede el TTL permitido.'}
    [pscustomobject]@{State=[string]$Announcement.state;Experience=$experience;Announcement=$Announcement}
}

function Get-CocoSessionAnnouncement($Catalog){
    $discovery=$Catalog.sessionDiscovery
    $client=[Net.Sockets.TcpClient]::new()
    try{
        $connect=$client.BeginConnect([string]$discovery.host,[int]$discovery.port,$null,$null)
        $timeout=[int]$discovery.connectTimeoutMs
        $sw=[Diagnostics.Stopwatch]::StartNew()
        while(-not$connect.AsyncWaitHandle.WaitOne(25)){
            if($sw.ElapsedMilliseconds-ge$timeout){return [pscustomobject]@{State='offline';Experience=$null;Reason='unreachable'}}
            if($script:CocoForm-and-not$script:CocoForm.IsDisposed){
                try{[Windows.Forms.Application]::DoEvents()}catch{}
            }
        }
        $client.EndConnect($connect)
        $stream=$client.GetStream()
        $stream.ReadTimeout=[Math]::Max(1000,[int]$discovery.connectTimeoutMs)
        $request=[Text.Encoding]::ASCII.GetBytes("COCO-SESSION 1`n")
        $stream.Write($request,0,$request.Length)
        $header=[Text.StringBuilder]::new()
        while($header.Length-lt64){
            $value=$stream.ReadByte()
            if($value-lt0){throw 'El servicio Coco cerro la respuesta antes del encabezado.'}
            if($value-eq10){break}
            if($value-ne13){[void]$header.Append([char]$value)}
        }
        if($header.ToString()-notmatch'^COCO-SESSION 1 ([0-9]{1,5})$'){throw 'El servicio Coco devolvio un encabezado invalido.'}
        $length=[int]$Matches[1]
        if($length-lt2-or$length-gt[int]$discovery.maximumResponseBytes){throw 'El servicio Coco devolvio un tamano invalido.'}
        $bytes=New-Object byte[] $length
        $offset=0
        while($offset-lt$length){$read=$stream.Read($bytes,$offset,$length-$offset);if($read-le0){throw 'La respuesta Coco termino incompleta.'};$offset+=$read}
        try{$announcement=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json}catch{throw 'El servicio Coco no devolvio JSON valido.'}
        Test-CocoSessionAnnouncement $Catalog $announcement
    }catch{
        [pscustomobject]@{State='offline';Experience=$null;Reason=$_.Exception.Message}
    }finally{$client.Dispose()}
}

function Get-CocoClientSessionAction($Session){
    if(-not$Session-or$Session.State-eq'offline'){return [pscustomobject]@{Action='wait';Message='No hay ninguna partida Coco online';Experience=$null}}
    $forceJoin=if($Session.Announcement-and$Session.Announcement.PSObject.Properties.Name-contains'forceJoin'){$Session.Announcement.forceJoin-ne$false}else{$true}
    switch([string]$Session.State){
        'preparing'{
            $act=if($forceJoin){'prepare'}else{'optional-prepare'}
            return [pscustomobject]@{Action=$act;Message=("El host esta preparando {0}"-f$Session.Experience.name);Experience=$Session.Experience;ForceJoin=$forceJoin}
        }
        'ready'{
            $act=if($forceJoin){'launch'}else{'optional-ready'}
            return [pscustomobject]@{Action=$act;Message=("El host esta jugando a {0}"-f$Session.Experience.name);Experience=$Session.Experience;ForceJoin=$forceJoin}
        }
        'stopping'{return [pscustomobject]@{Action='wait';Message='La partida Coco esta terminando';Experience=$Session.Experience;ForceJoin=$forceJoin}}
        default{throw 'El cliente recibio un estado de sesion no soportado.'}
    }
}

function Start-CocoSessionService(
    [string]$ServiceScript,
    [string]$StatePath,
    [string]$LogPath,
    [int64]$ParentPid=$PID,
    [string]$SkinRoot=''
){
    if(-not(Test-Path -LiteralPath $ServiceScript -PathType Leaf)){throw 'Falta CocoSessionService.ps1 en el engine.'}
    if(Test-CocoSkinServiceEndpoint '10.77.37.1' 25564 500){
        if(Get-Command Write-CocoLog -ErrorAction SilentlyContinue){Write-CocoLog 'Servicio Coco existente reutilizado en 10.77.37.1:25564.'}
        return $null
    }
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ServiceScript,'-BindAddress','10.77.37.1','-Port','25564','-StatePath',$StatePath,'-ParentPid',[string]$ParentPid,'-LogPath',$LogPath)
    if($SkinRoot){$arguments+=@('-SkinRoot',$SkinRoot)}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Command powershell.exe -ErrorAction Stop).Source
    $start.Arguments=(@($arguments|ForEach-Object{ConvertTo-CocoWindowsProcessArgument ([string]$_)})-join' ')
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $process=[Diagnostics.Process]::Start($start)
    if(-not$process){throw 'Windows no inicio el servicio de sesion Coco.'}
    $deadline=(Get-Date).AddSeconds(5)
    try{
        do{
            if($process.HasExited){throw "El servicio de sesion Coco termino antes de escuchar (codigo $($process.ExitCode)). El puerto 25564 puede estar ocupado."}
            if(Test-CocoTcpEndpoint '10.77.37.1' 25564 250){
                if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
                Start-Sleep -Milliseconds 150
                if($process.HasExited){throw "El servicio de sesion Coco no pudo conservar el puerto 25564 (codigo $($process.ExitCode))."}
                return $process
            }
            if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
            Start-Sleep -Milliseconds 100
        }while((Get-Date)-lt$deadline)
        throw 'El servicio de sesion Coco no comenzo a escuchar en 10.77.37.1:25564 dentro de 5 segundos.'
    }catch{
        if(-not$process.HasExited){try{$process.Kill()}catch{}}
        $process.Dispose()
        throw
    }
}

function Invoke-CocoLauncherNetworkSerialized(
    [scriptblock]$Operation,
    [int]$TimeoutMilliseconds=120000,
    [string]$NetworkMutexName='Local\CocoMinecraftUpdaterNetwork',
    [string]$LegacyMutexName='Local\CocoMinecraftUpdater'
){
    if(-not$Operation){throw 'Falta la operacion de red Coco.'}
    $networkMutex=$null;$legacyMutex=$null;$networkAcquired=$false;$legacyAcquired=$false
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $enter={param($Mutex)
        try{return $Mutex.WaitOne(250)}catch [Threading.AbandonedMutexException]{return $true}
    }
    try{
        $networkMutex=[Threading.Mutex]::new($false,$NetworkMutexName)
        while(-not($networkAcquired=&$enter $networkMutex)){
            if($watch.ElapsedMilliseconds-ge$TimeoutMilliseconds){throw 'La comprobacion de red anterior no termino. Vuelve a intentarlo.'}
            if($script:CocoForm-and-not$script:CocoForm.IsDisposed){Set-CocoState 'Preparando red Coco' 'Esperando la comprobacion de red anterior...' 4;[Windows.Forms.Application]::DoEvents()}
        }
        $legacyMutex=[Threading.Mutex]::new($false,$LegacyMutexName)
        while(-not($legacyAcquired=&$enter $legacyMutex)){
            if($watch.ElapsedMilliseconds-ge$TimeoutMilliseconds){throw 'La comprobacion de red de una version anterior no termino. Vuelve a intentarlo.'}
            if($script:CocoForm-and-not$script:CocoForm.IsDisposed){Set-CocoState 'Preparando red Coco' 'Esperando compatibilidad con Coco anterior...' 4;[Windows.Forms.Application]::DoEvents()}
        }
        & $Operation
    }finally{
        if($legacyMutex){if($legacyAcquired){$legacyMutex.ReleaseMutex()|Out-Null};$legacyMutex.Dispose()}
        if($networkMutex){if($networkAcquired){$networkMutex.ReleaseMutex()|Out-Null};$networkMutex.Dispose()}
    }
}

function Read-CocoLauncherCatalog([string]$Path){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "No existe el catalogo Coco: $Path"}
    try{$catalog=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "El catalogo Coco no es JSON valido: $($_.Exception.Message)"}
    if([int]$catalog.schemaVersion-ne1){throw 'El catalogo Coco usa un schemaVersion no soportado.'}
    if([string]::IsNullOrWhiteSpace([string]$catalog.catalogVersion)){throw 'El catalogo Coco no declara catalogVersion.'}
    if([string]$catalog.releaseStatus-notin@('development','approved')){throw 'El catalogo Coco no declara un releaseStatus valido.'}
    if(-not$catalog.sessionPolicy){throw 'El catalogo Coco no declara la politica de sesiones.'}
    if([int]$catalog.sessionPolicy.maximumConcurrentSessions-ne1){throw 'Coco requiere exactamente una sesion activa como maximo.'}
    if([string]$catalog.sessionPolicy.clientSelection-ne'automatic'){throw 'La seleccion de experiencia del cliente debe ser automatica.'}
    if([string]$catalog.sessionPolicy.offlineBehavior-ne'show-no-session'){throw 'El comportamiento sin sesion del cliente no es compatible.'}
    if(-not$catalog.sessionDiscovery-or$catalog.sessionDiscovery.protocol-ne'coco-session-v1'){throw 'El catalogo no declara el protocolo de descubrimiento Coco.'}
    if([string]$catalog.sessionDiscovery.host-ne'10.77.37.1'-or[int]$catalog.sessionDiscovery.port-ne25564){throw 'El endpoint de descubrimiento Coco es inesperado.'}
    if([int]$catalog.sessionDiscovery.connectTimeoutMs-lt250-or[int]$catalog.sessionDiscovery.connectTimeoutMs-gt5000){throw 'El timeout de descubrimiento Coco es invalido.'}
    if([int]$catalog.sessionDiscovery.maximumResponseBytes-lt1024-or[int]$catalog.sessionDiscovery.maximumResponseBytes-gt32768){throw 'El limite de respuesta de descubrimiento Coco es invalido.'}
    if([int]$catalog.sessionDiscovery.maximumTtlSeconds-lt10-or[int]$catalog.sessionDiscovery.maximumTtlSeconds-gt300){throw 'El TTL de descubrimiento Coco es invalido.'}
    if(-not$catalog.backend-or$catalog.backend.id-ne'portablemc'){throw 'El catalogo Coco no declara el backend PortableMC esperado.'}
    if([string]$catalog.backend.version-notmatch'^\d+\.\d+\.\d+$'){throw 'La version del backend no es semantica.'}
    if([string]$catalog.backend.commit-notmatch'^[a-f0-9]{7,40}$'){throw 'El commit del backend no es valido.'}
    if([string]$catalog.backend.url-notmatch'^https://github\.com/theorzr/portablemc/releases/download/v'){throw 'El backend debe descargarse desde un release oficial de PortableMC.'}
    if([string]$catalog.backend.sha256-notmatch'^[a-fA-F0-9]{64}$'){throw 'El backend no tiene un SHA-256 valido.'}
    if([int64]$catalog.backend.size-le0){throw 'El backend no tiene un tamano valido.'}
    if(-not (Test-CocoSafeRelativePath ([string]$catalog.backend.executable))){throw 'La ruta del ejecutable backend no es segura.'}
    if([string]$catalog.backend.executableSha256-notmatch'^[a-fA-F0-9]{64}$'){throw 'El ejecutable backend no tiene un SHA-256 valido.'}
    if([int64]$catalog.backend.executableSize-le0){throw 'El ejecutable backend no tiene un tamano valido.'}
    if([string]::IsNullOrWhiteSpace([string]$catalog.backend.versionOutputPattern)){throw 'El backend no declara como validar su version y commit.'}
    try{[void][regex]::new([string]$catalog.backend.versionOutputPattern)}catch{throw 'El patron de version del backend no es una expresion regular valida.'}
    if([string]$catalog.backend.signatureUrl-notmatch'^https://github\.com/theorzr/portablemc/releases/download/v.+\.sig$'){throw 'La firma separada del backend no usa el release oficial.'}
    if([string]$catalog.backend.signatureSha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$catalog.backend.signatureSize-le0){throw 'La firma separada del backend no esta fijada por hash y tamano.'}
    if([string]$catalog.backend.pgpFingerprint-notmatch'^[a-fA-F0-9]{40}$'){throw 'La huella PGP del backend no es valida.'}
    if(-not$catalog.globalPolicies-or[string]$catalog.globalPolicies.essential.mode-ne'exclude'){
        throw 'El catalogo debe excluir Essential globalmente.'
    }
    $skinPolicy=$catalog.globalPolicies.customSkinLoader
    if(-not$skinPolicy-or[string]$skinPolicy.mode-ne'required'){throw 'El catalogo debe exigir CustomSkinLoader globalmente.'}
    foreach($variant in @($skinPolicy.variants)){
        if(-not(Test-CocoSafeRelativePath ([string]$variant.path))-or[string]$variant.path-notmatch'(?i)^mods/CustomSkinLoader_.+\.jar$'){
            throw 'Una variante global de CustomSkinLoader usa una ruta invalida.'
        }
        if([string]$variant.sourceUrl-notmatch'^https://'-or[string]$variant.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$variant.size-le0){
            throw 'Una variante global de CustomSkinLoader no esta fijada por origen, hash y tamano.'
        }
        if(-not@($variant.minecraftVersions).Count){throw 'Una variante global de CustomSkinLoader no declara versiones de Minecraft.'}
    }
    foreach($skin in @($skinPolicy.localSkins)){
        if(-not(Test-CocoMinecraftUsername ([string]$skin.username))-or
            -not(Test-CocoSafeRelativePath ([string]$skin.embeddedPath))-or
            [string]$skin.embeddedPath-notmatch'^assets/skins/.+\.png$'-or
            [string]$skin.sha256-notmatch'^[a-fA-F0-9]{64}$'){
            throw 'Una skin local global no declara usuario, ruta o hash validos.'
        }
    }
    $experiences=@($catalog.experiences)
    if(-not$experiences.Count){throw 'El catalogo Coco no contiene experiencias.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($experience in $experiences){
        $id=[string]$experience.id
        if($id-notmatch'^[a-z0-9][a-z0-9-]{1,47}$'){throw "ID de experiencia invalido: '$id'."}
        if(-not$ids.Add($id)){throw "ID de experiencia duplicado: '$id'."}
        if([string]::IsNullOrWhiteSpace([string]$experience.name)){throw "La experiencia '$id' no tiene nombre."}
        if([string]$experience.instanceId-notmatch'^[a-z0-9][a-z0-9-]{1,47}$'){throw "instanceId invalido para '$id'."}
        if($experience.managementMode-notin@('legacy-current','managed')){throw "managementMode invalido para '$id'."}
        if(-not$experience.runtime){throw "Runtime incompleto para '$id'."}
        $isMedia=[string]$experience.runtime.type-eq'media'
        if($isMedia){
            if($experience.managementMode-ne'managed'-or-not$experience.launch-or[string]$experience.launch.workflow-ne'coco-media' -or
               [string]::IsNullOrWhiteSpace([string]$experience.launch.serverName)){
                throw "La experiencia media '$id' debe declarar workflow coco-media y serverName."
            }
            if(-not$experience.content-or[string]$experience.content.type-notin@('episodic-video','movie')){
                throw "El contenido de '$id' debe declarar type 'episodic-video' o 'movie'."
            }
            $downloadFolder=[string]$experience.content.downloadFolderName
            if([string]::IsNullOrWhiteSpace($downloadFolder)-or-not(Test-CocoSafeRelativePath $downloadFolder)-or
               $downloadFolder.Contains('/')-or$downloadFolder.Contains('\')){
                throw "La carpeta de descargas de '$id' no es segura."
            }
            $itemIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $itemFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $mediaItems=@(Get-CocoMediaItems $experience)
            if(-not$mediaItems.Count){throw "La experiencia media '$id' no contiene elementos multimedia."}
            foreach($item in $mediaItems){
                $itemId=[string]$item.id;$fileName=[string]$item.fileName;$sourceUrl=[string]$item.sourceUrl;$streamUrl=[string]$item.streamUrl
                if($itemId-notmatch'^[a-z0-9][a-z0-9-]{1,47}$'-or-not$itemIds.Add($itemId)-or
                   [string]::IsNullOrWhiteSpace([string]$item.title)-or
                   [string]::IsNullOrWhiteSpace($fileName)-or-not(Test-CocoSafeRelativePath $fileName)-or
                   [IO.Path]::GetFileName($fileName)-ne$fileName-or-not$itemFiles.Add($fileName)-or
                   [IO.Path]::GetExtension($fileName).ToLowerInvariant()-notin@('.mkv','.mp4','.webm','.mov','.avi') -or
                   [string]$item.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$item.size-le0){
                    throw "Elemento media invalido en '$id': '$itemId'."
                }
                if($sourceUrl-and$sourceUrl-notmatch'^https://'){throw "El asset de '$itemId' no usa HTTPS."}
                if($streamUrl-and$streamUrl-notmatch'^https://'){throw "El stream de '$itemId' no usa HTTPS."}
                if($catalog.releaseStatus-eq'approved'-and(($sourceUrl-match'(?i)^https://(?:github\.com/|[^/]+\.githubusercontent\.com/)')-or($streamUrl-match'(?i)^https://(?:github\.com/|[^/]+\.githubusercontent\.com/)')) -and[int64]$item.size-ge2147483648){
                    throw "El elemento '$itemId' supera el limite de 2 GiB de GitHub Free; reduce el archivo o dividelo antes de publicarlo."
                }
                if($catalog.releaseStatus-eq'approved'-and-not($sourceUrl-or$streamUrl)){throw "El elemento '$itemId' no tiene asset HTTPS publicado."}
            }
        }elseif([string]$experience.runtime.type-eq'standalone'){
            if(-not(Test-CocoSafeRelativePath ([string]$experience.runtime.executable))){throw "Ejecutable standalone invalido para '$id'."}
        }else{
            if([string]::IsNullOrWhiteSpace([string]$experience.runtime.minecraftVersion)){throw "Runtime incompleto para '$id'."}
            if($experience.runtime.loader-notin@('fabric','forge','neoforge')){throw "Loader invalido para '$id'."}
            if([int]$experience.runtime.javaMajor-notin@(8,17,21,25)){throw "Java no soportado para '$id'."}
        }
        if($experience.runtimePolicies-and$experience.runtimePolicies.essentialLoaderUpdates-and[string]$experience.runtimePolicies.essentialLoaderUpdates-ne'disabled'){
            throw "Politica Essential Loader invalida para '$id'."
        }
        if($experience.runtimePolicies-and$experience.runtimePolicies.defenderExclusion-and[string]$experience.runtimePolicies.defenderExclusion-ne'required'){
            throw "Politica de exclusion de Defender invalida para '$id'."
        }
        if($experience.runtimePolicies-and$experience.runtimePolicies.onlineFixAppId-and[string]$experience.runtimePolicies.onlineFixAppId-notmatch'^\d{1,10}$'){
            throw "Identificador OnlineFix invalido para '$id'."
        }
        if(-not$isMedia){
        if(-not$experience.hosting-or$experience.hosting.mode-notin@('lan','dedicated','either','p2p')){throw "Modo de hosting invalido para '$id'."}
        if($experience.hosting.mode-ne'p2p'){
            $port=[int]$experience.hosting.port
            if($port-lt1-or$port-gt65535){throw "Puerto invalido para '$id'."}
        }
        if(-not$experience.launch-or[string]::IsNullOrWhiteSpace([string]$experience.launch.serverName)){throw "Lanzamiento incompleto para '$id'."}
        $expectedWorkflow=if($experience.managementMode-eq'managed'){
            if([string]$experience.runtime.type-eq'standalone'-or[string]$experience.launch.workflow-eq'coco-standalone'){'coco-standalone'}else{'coco-managed'}
        }else{'external-launcher'}
        if([string]$experience.launch.workflow-ne$expectedWorkflow){throw "Workflow de lanzamiento invalido para '$id'."}
        if($experience.managementMode-eq'legacy-current'-and[bool]$experience.launch.autoJoin){throw "Coco original no puede autoarrancarse desde Coco Launcher."}
        if($experience.launch.minimumFreeBytes-and[int64]$experience.launch.minimumFreeBytes-lt1073741824){throw "minimumFreeBytes invalido para '$id'."}
        if($experience.launch.memory){
            $minimum=[int]$experience.launch.memory.minimumMb;$recommended=[int]$experience.launch.memory.recommendedMb;$fraction=[double]$experience.launch.memory.maximumPhysicalFraction
            if($minimum-lt1024-or$recommended-lt$minimum-or$recommended-gt32768-or$fraction-lt0.25-or$fraction-gt0.75){throw "Politica de memoria invalida para '$id'."}
        }
        if($experience.managementMode-eq'managed'){
            if([string]$experience.launch.workflow-eq'coco-standalone'){
                $archives = @(if($experience.pack.archives){$experience.pack.archives}else{$experience.pack})
                if($archives.Count-le0){throw "Standalone pack vacio para '$id'."}
                foreach($item in $archives){
                    if([string]$item.sha256-notmatch'^[a-fA-F0-9]{64}$'){throw "pack.sha256 invalido para '$id'."}
                    if([int64]$item.size-le0){throw "pack.size invalido para '$id'."}
                    if([string]$item.archiveUrl-notmatch'^(https://|file://)'){throw "archiveUrl invalido para '$id'."}
                }
                $requiredPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach($requiredFile in @($experience.runtime.requiredFiles)){
                    $requiredPath=([string]$requiredFile.path)-replace'\\','/'
                    $archiveSha=([string]$requiredFile.archiveSha256).ToLowerInvariant()
                    if(-not(Test-CocoSafeRelativePath $requiredPath)-or-not$requiredPaths.Add($requiredPath)-or
                       [string]$requiredFile.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$requiredFile.size-le0-or
                       $archiveSha-notmatch'^[a-f0-9]{64}$'-or@($archives|Where-Object{([string]$_.sha256).ToLowerInvariant()-eq$archiveSha}).Count-ne1){
                        throw "Archivo requerido standalone invalido para '$id': '$requiredPath'."
                    }
                }
                if(@($experience.runtime.requiredFiles).Count-and-not@($experience.runtime.requiredFiles|Where-Object{
                    $requiredExecutablePath=([string]$_.path)-replace'\\','/'
                    $declaredExecutablePath=([string]$experience.runtime.executable)-replace'\\','/'
                    [string]::Equals($requiredExecutablePath,$declaredExecutablePath,[StringComparison]::OrdinalIgnoreCase)
                }).Count){
                    throw "Los archivos requeridos standalone de '$id' no incluyen su ejecutable."
                }
            }else{
                $lanAdapter=if($experience.hosting.adapter){[string]$experience.hosting.adapter}else{'mcwifipnp'}
                if($lanAdapter-notin@('mcwifipnp','lan-server-properties-v1')){throw "Adaptador LAN invalido para '$id'."}
                if($lanAdapter-eq'lan-server-properties-v1'-and[string]$experience.runtime.minecraftVersion-ne'1.12.2'){
                    throw "El adaptador LAN legado solo se admite para Minecraft 1.12.2 en '$id'."
                }
                $skinVariants=@($skinPolicy.variants|Where-Object{[string]$experience.runtime.minecraftVersion-in@($_.minecraftVersions)})
                if($skinVariants.Count-ne1){
                    throw "La experiencia '$id' necesita exactamente una variante compatible de CustomSkinLoader."
                }
                if(-not(Test-CocoSafeRelativePath ([string]$experience.pack.lockPath))){throw "lockPath invalido para '$id'."}
                if($experience.pack.redistribution-ne'origin-only'){throw "La experiencia '$id' no declara distribucion desde origen."}
            }
            if($experience.pack.excludedPaths){
                foreach($excludedPath in @($experience.pack.excludedPaths)){
                    if([string]::IsNullOrWhiteSpace([string]$excludedPath)-or-not(Test-CocoSafeRelativePath ([string]$excludedPath))-or-not([string]$excludedPath).StartsWith('mods/',[StringComparison]::OrdinalIgnoreCase)){
                        throw "Exclusion de pack invalida para '$id': '$excludedPath'."
                    }
                }
            }
            $managedPreferencePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if($experience.preferences.managedFiles){
                foreach($managedFile in @($experience.preferences.managedFiles)){
                    $managedPath=([string]$managedFile.path)-replace'\\','/'
                    $writeMode=if($managedFile.writeMode){[string]$managedFile.writeMode}else{'replace'}
                    if(-not(Test-CocoSafeRelativePath $managedPath)-or
                        $managedPath-notmatch'^(?i)(config|shaderpacks)/'-or
                        -not$managedPreferencePaths.Add($managedPath)-or
                        $writeMode-notin@('replace','initialize') -or
                        $managedFile.PSObject.Properties.Name-notcontains'content'-or
                        ([string]$managedFile.content).Length-gt1048576){
                        throw "Archivo de preferencias administradas invalido para '$id': '$managedPath'."
                    }
                }
            }
            $managedTomlKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if($experience.preferences.tomlValues){
                foreach($tomlValue in @($experience.preferences.tomlValues)){
                    $tomlPath=([string]$tomlValue.path)-replace'\\','/'
                    $tomlSection=[string]$tomlValue.section
                    $tomlKey=[string]$tomlValue.key
                    $tomlIdentity="$tomlPath|$tomlSection|$tomlKey"
                    if(-not(Test-CocoSafeRelativePath $tomlPath)-or
                        $tomlPath-notmatch'^(?i)config/.+\.toml$'-or
                        $tomlSection-notmatch'^[A-Za-z0-9_.-]+$'-or
                        $tomlKey-notmatch'^[A-Za-z0-9_.-]+$'-or
                        -not$managedTomlKeys.Add($tomlIdentity)-or
                        $tomlValue.PSObject.Properties.Name-notcontains'value'-or
                        $null-eq$tomlValue.value-or
                        $tomlValue.value-isnot[string]-and$tomlValue.value-isnot[bool]-and$tomlValue.value-isnot[ValueType]){
                        throw "Valor TOML administrado invalido para '$id': '$tomlIdentity'."
                    }
                }
            }
        if($experience.worldTemplate){
                if(-not(Test-CocoSafeRelativePath ([string]$experience.worldTemplate.lockPath))){throw "worldTemplate.lockPath invalido para '$id'."}
                if([string]$experience.worldTemplate.installRole-ne'host'){throw "El mundo de '$id' debe instalarse exclusivamente en el host."}
                if([string]$experience.worldTemplate.firstRunPolicy-ne'create-once-preserve-forever'){throw "Politica de mundo invalida para '$id'."}
            }
        }
        }
        foreach($file in @($experience.files)){
            if(-not (Test-CocoSafeRelativePath ([string]$file.path))){throw "Ruta administrada insegura en '$id': '$($file.path)'."}
            if([string]$file.sha256-notmatch'^[a-fA-F0-9]{64}$'){throw "SHA-256 invalido en '$id': '$($file.path)'."}
            if([int64]$file.size-lt0){throw "Tamano invalido en '$id': '$($file.path)'."}
            if($file.policy-notin@('replace','merge','preserve','migrate')){throw "Politica invalida en '$id': '$($file.path)'."}
            if($file.role-and$file.role-notin@('all','client','host')){throw "Rol de archivo invalido en '$id': '$($file.path)'."}
            $fileFirstParty=[string]$file.sourceUrl-match'^https://github\.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v\d+\.\d+\.\d+/[^/?#]+$'
            if(-not$fileFirstParty-and[string]$file.sourceUrl-notmatch'^https://cdn\.modrinth\.com/data/'){throw "Origen de archivo no permitido en '$id': '$($file.path)'."}
        }
    }
    return $catalog
}

function Read-CocoExperienceLock([string]$Path,$Experience){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "No existe el lock de experiencia: $Path"}
    try{$lock=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "El lock de experiencia no es JSON valido: $($_.Exception.Message)"}
    if([int]$lock.schemaVersion-ne1-or$lock.source.provider-ne'curseforge'-or$lock.source.redistribution-ne'origin-only'){throw 'El lock de experiencia usa un origen o schema no soportado.'}
    if([string]$lock.runtime.minecraftVersion-ne[string]$Experience.runtime.minecraftVersion-or[string]$lock.runtime.loader-ne[string]$Experience.runtime.loader-or[string]$lock.runtime.loaderVersion-ne[string]$Experience.runtime.loaderVersion){throw 'El runtime del lock no coincide con el catalogo.'}
    $packMode=if($lock.pack.mode){[string]$lock.pack.mode}else{'curseforge-archive'}
    if($packMode-notin@('curseforge-archive','assets-only')){throw "Modo de pack no soportado: '$packMode'."}
    if($packMode-eq'curseforge-archive' -and (-not$lock.pack.archive-or[string]$lock.pack.archive.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$lock.pack.archive.size-le0)){throw 'El archivo fuente del pack no esta fijado.'}
    if($packMode-eq'assets-only' -and $lock.pack.archive){throw 'Un pack assets-only no puede declarar un archivo fuente de pack.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($asset in @($lock.assets)){
        $firstPartySource=[string]$asset.sourceUrl-match'^https://github\.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v\d+\.\d+\.\d+/[^/?#]+$'
        if(([int64]$asset.projectId-le0-or[int64]$asset.fileId-le0)-and-not$firstPartySource-and[string]$asset.sourceUrl-notmatch'^https://cdn\.modrinth\.com/'){throw 'El lock contiene un asset CurseForge sin IDs validos.'}
        $allowedRoot=@('mods/','tacz/','resourcepacks/','shaderpacks/')|Where-Object{([string]$asset.path).StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1
        if(-not(Test-CocoSafeRelativePath ([string]$asset.path))-or-not$allowedRoot){throw "Ruta de asset invalida en lock: '$($asset.path)'."}
        if(-not$paths.Add([string]$asset.path)){throw "Ruta duplicada en lock: '$($asset.path)'."}
        if([string]$asset.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$asset.size-le0){throw "Asset no fijado correctamente: '$($asset.path)'."}
        if(-not$firstPartySource-and[string]$asset.sourceUrl-notmatch'^https://(www\.curseforge\.com/api/v1/mods/[0-9]+/files/[0-9]+/download|cdn\.modrinth\.com/data/|optifine\.net/download)'){throw "Origen de asset invalido: '$($asset.sourceUrl)'."}
    }
    $lock
}

function Read-CocoWorldTemplateLock([string]$Path,$Experience){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "No existe el lock de mundo: $Path"}
    try{$lock=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "El lock de mundo no es JSON valido: $($_.Exception.Message)"}
    if([int]$lock.schemaVersion-ne1-or$lock.status-notin@('development','approved')){throw 'El lock de mundo usa un schema o estado no soportado.'}
    if($lock.source.provider-ne'curseforge'-or$lock.source.redistribution-ne'origin-only'-or$lock.source.license-ne'All Rights Reserved'){throw 'La procedencia/licencia del mundo no esta fijada.'}
    if([int64]$lock.source.projectId-le0-or[int64]$lock.source.fileId-le0){throw 'El lock de mundo no contiene IDs CurseForge validos.'}
    $expectedUrl="https://www.curseforge.com/api/v1/mods/$($lock.source.projectId)/files/$($lock.source.fileId)/download"
    if([string]$lock.source.sourceUrl-ne$expectedUrl){throw 'El mundo no se descarga desde su archivo CurseForge fijado.'}
    if([string]$lock.source.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$lock.source.size-le0){throw 'El archivo de mundo no tiene hash o tamano valido.'}
    if((-not(Test-CocoSafeRelativePath ([string]$lock.source.archiveRoot)))-or([string]$lock.source.archiveRoot-match'[/\\]')){throw 'La raiz del archivo de mundo no es segura.'}
    if([int]$lock.source.dataVersion-le0-or[string]::IsNullOrWhiteSpace([string]$lock.source.minecraftVersion)){throw 'La version fuente del mundo no esta fijada.'}
    if($lock.conversion.engine-ne'amulet-core'-or[string]$lock.conversion.engineVersion-notmatch'^\d+\.\d+\.\d+$'){throw 'El conversor de mundo no esta fijado.'}
    if([string]$lock.conversion.targetMinecraftVersion-ne[string]$Experience.runtime.minecraftVersion-or[int]$lock.conversion.targetDataVersion-le0){throw 'La version destino del mundo no coincide con la experiencia.'}
    if(-not[bool]$lock.conversion.requiresTargetBaseWorld){throw 'La conversion debe exigir un mundo base real de la version destino.'}
    foreach($rule in @($lock.conversion.blockReplacements)){
        if(-not$rule.matchBaseName-and-not$rule.matchBaseNameRegex){throw 'Una sustitucion de mundo no declara el bloque origen.'}
        if(-not$rule.replacementUniversalBaseName-and-not$rule.replacementNativeName-and-not$rule.replaceProperties){throw 'Una sustitucion de mundo no declara el bloque destino.'}
        if($rule.replacementNativeName-and[string]$rule.replacementNativeName-notmatch'^[a-z0-9_.-]+:[a-z0-9_./-]+$'){throw 'Una sustitucion de mundo contiene un bloque nativo invalido.'}
    }
    if([string]$lock.world.folderName-notmatch'^[^\\/:*?"<>|]{1,80}$'-or[string]::IsNullOrWhiteSpace([string]$lock.world.levelName)){throw 'El nombre del mundo convertido no es seguro.'}
    if(-not$lock.world.spawn-or[int]$lock.world.spawn.y-lt-64-or[int]$lock.world.spawn.y-gt319){throw 'El spawn del mundo convertido no es valido.'}
    foreach($landmark in @($lock.world.requiredLandmarks)){
        if([string]$landmark.id-notmatch'^[a-z0-9][a-z0-9-]{1,47}$'-or@($landmark.bounds).Count-ne6){throw 'El lock contiene un landmark invalido.'}
        $bounds=@($landmark.bounds|ForEach-Object{[int]$_})
        if($bounds[0]-gt$bounds[3]-or$bounds[1]-gt$bounds[4]-or$bounds[2]-gt$bounds[5]){throw 'Los limites de un landmark estan invertidos.'}
    }
    $lock
}

function Get-CocoLockedAssetCachePath([string]$CacheRoot,$Asset){
    $extension=[IO.Path]::GetExtension([string]$Asset.name)
    if($extension-notin@('.jar','.zip')){$extension='.bin'}
    Join-Path (Join-Path $CacheRoot 'objects') (([string]$Asset.sha256).ToLowerInvariant()+$extension)
}

function Get-CocoLockedAsset([string]$CacheRoot,$Asset,$ProgressContext){
    if([string]$Asset.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$Asset.size-le0){throw 'El asset no tiene hash o tamano valido.'}
    if($ProgressContext){
        $ProgressContext.Index=[int]$ProgressContext.Index+1
        $itemPrefix="Archivo $($ProgressContext.Index)/$($ProgressContext.Count) | $([string]$Asset.name)"
        $range=[Math]::Max(1,[int]$ProgressContext.ProgressEnd-[int]$ProgressContext.ProgressStart)
        $rawStart=[int]$ProgressContext.ProgressStart+[int]($range*[int64]$ProgressContext.CompletedBytes/[Math]::Max(1,[int64]$ProgressContext.TotalBytes))
        $itemStart=[Math]::Max(0,[Math]::Min(100,$rawStart))
    }
    $destination=Get-CocoLockedAssetCachePath $CacheRoot $Asset
    if((Test-Path -LiteralPath $destination -PathType Leaf)-and(Get-Item -LiteralPath $destination).Length-eq[int64]$Asset.size-and(Get-CocoFileSha256 $destination)-eq([string]$Asset.sha256).ToLowerInvariant()){
        if($ProgressContext){
            $ProgressContext.CompletedBytes=[int64]$ProgressContext.CompletedBytes+[int64]$Asset.size
            Set-CocoLauncherStep ([int]$ProgressContext.Step) ([string]$ProgressContext.Title) "$itemPrefix`r`nVerificado y reutilizado desde la cache local." $itemStart
        }
        return $destination
    }
    $url=[string]$Asset.sourceUrl
    if($url-notmatch'^https://(www\.curseforge\.com/api/v1/mods/[0-9]+/files/[0-9]+/download|cdn\.modrinth\.com/data/|github\.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v\d+\.\d+\.\d+/[^/?#]+)'){throw "Origen de asset Coco no permitido: '$url'."}
    $parent=Split-Path $destination -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $temporary=Join-Path $parent ("download-$PID-$([guid]::NewGuid().ToString('N')).tmp")
    try{
        if(Get-Command Download-VerifiedFile -ErrorAction SilentlyContinue){
            if($ProgressContext){
                Download-VerifiedFile $url $temporary ([string]$Asset.sha256) ([int64]$ProgressContext.CompletedBytes) ([int64]$ProgressContext.TotalBytes) ("ETAPA {0}/10 | {1}"-f$ProgressContext.Step,$ProgressContext.Title) $itemPrefix ([int]$ProgressContext.ProgressStart) ([int]$ProgressContext.ProgressEnd)
            }else{Download-VerifiedFile $url $temporary ([string]$Asset.sha256)}
        }else{
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $temporary
        }
        if((Get-Item -LiteralPath $temporary).Length-ne[int64]$Asset.size){throw "El asset '$($Asset.name)' no coincide con el tamano fijado."}
        if((Get-CocoFileSha256 $temporary)-ne([string]$Asset.sha256).ToLowerInvariant()){throw "El asset '$($Asset.name)' no coincide con el SHA-256 fijado."}
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    if($ProgressContext){
        $ProgressContext.CompletedBytes=[int64]$ProgressContext.CompletedBytes+[int64]$Asset.size
        $complete=[int]$ProgressContext.ProgressStart+[int](([int]$ProgressContext.ProgressEnd-[int]$ProgressContext.ProgressStart)*[int64]$ProgressContext.CompletedBytes/[Math]::Max(1,[int64]$ProgressContext.TotalBytes))
        Set-CocoLauncherStep ([int]$ProgressContext.Step) ([string]$ProgressContext.Title) "$itemPrefix`r`nDescarga y SHA-256 verificados." $complete
    }
    $destination
}

function Get-CocoLockedAssetsParallel($CacheRoot, $Assets, $ProgressContext) {
    $missing = [Collections.Generic.List[object]]::new()
    $cachedResults = @{}
    foreach ($asset in @($Assets)) {
        if(-not$asset){continue}
        $dest = Get-CocoLockedAssetCachePath $CacheRoot $asset
        if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Get-Item -LiteralPath $dest).Length -eq [int64]$asset.size) {
            $cachedResults[([string]$asset.sha256).ToLowerInvariant()] = $dest
            if ($ProgressContext) {
                $ProgressContext.CompletedBytes = [int64]$ProgressContext.CompletedBytes + [int64]$asset.size
            }
        } else {
            [void]$missing.Add($asset)
        }
    }
    
    if ($missing.Count -gt 0) {
        $maxWorkers = [Math]::Min(8, [Math]::Max(2, $missing.Count))
        $pool = [runspacefactory]::CreateRunspacePool(1, $maxWorkers)
        $pool.Open()
        $tasks = [Collections.Generic.List[object]]::new()
        
        $workerScript = {
            param($CacheRoot, $Asset)
            $sha = [string]$Asset.sha256
            $extension = [IO.Path]::GetExtension([string]$Asset.name)
            if ($extension -notin @('.jar','.zip')) { $extension = '.bin' }
            $dest = Join-Path (Join-Path $CacheRoot 'objects') ($sha.ToLowerInvariant() + $extension)
            $parent = Split-Path $dest -Parent
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
            $temp = Join-Path $parent ("download-$PID-$([guid]::NewGuid().ToString('N')).tmp")
            $maxRetries = 2
            $lastError = $null
            for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
                try {
                    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
                    $web = [System.Net.WebClient]::new()
                    try {
                        $web.Headers.Add("User-Agent", "CocoMinecraftUpdater/1.0")
                        $web.DownloadFile([string]$Asset.sourceUrl, $temp)
                    } finally {
                        $web.Dispose()
                    }

                    $fileInfo = [System.IO.FileInfo]::new($temp)
                    if ($fileInfo.Length -ne [int64]$Asset.size) { throw "Tamano invalido: $($Asset.name)" }

                    $shaAlg = [System.Security.Cryptography.SHA256]::Create()
                    $stream = [System.IO.File]::OpenRead($temp)
                    $hashBytes = $shaAlg.ComputeHash($stream)
                    $stream.Dispose(); $shaAlg.Dispose()
                    $shaStr = ([BitConverter]::ToString($hashBytes) -replace '-','').ToLowerInvariant()
                    if ($shaStr -ne $sha.ToLowerInvariant()) { throw "Hash invalido: $($Asset.name)" }

                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
                    [System.IO.File]::Move($temp, $dest)
                    return [pscustomobject]@{ sha256 = $sha.ToLowerInvariant(); path = $dest; size = [int64]$Asset.size; name = [string]$Asset.name }
                } catch {
                    $lastError = $_
                    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
                    if ($attempt -lt $maxRetries) {
                        [System.Threading.Thread]::Sleep(350 * ($attempt + 1))
                    }
                }
            }
            throw $lastError
        }
        
        foreach ($mAsset in $missing) {
            $ps = [powershell]::Create().AddScript($workerScript).AddArgument($CacheRoot).AddArgument($mAsset)
            $ps.RunspacePool = $pool
            [void]$tasks.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Asset = $mAsset })
        }
        
        $pendingTasks = [Collections.Generic.List[object]]::new($tasks)
        while ($pendingTasks.Count -gt 0) {
            $completedIndex = -1
            for ($i = 0; $i -lt $pendingTasks.Count; $i++) {
                if ($pendingTasks[$i].Handle.IsCompleted) {
                    $completedIndex = $i
                    break
                }
            }
            if ($completedIndex -ge 0) {
                $task = $pendingTasks[$completedIndex]
                $pendingTasks.RemoveAt($completedIndex)
                try {
                    $res = $task.PS.EndInvoke($task.Handle)
                    if ($res -and $res.Count) {
                        $item = $res[0]
                        $cachedResults[[string]$item.sha256] = [string]$item.path
                        if ($ProgressContext) {
                            $ProgressContext.CompletedBytes = [int64]$ProgressContext.CompletedBytes + [int64]$item.size
                            $ProgressContext.Index = [int]$ProgressContext.Index + 1
                            $pct = [int]($ProgressContext.ProgressStart + ($ProgressContext.ProgressEnd - $ProgressContext.ProgressStart) * [int64]$ProgressContext.CompletedBytes / [Math]::Max(1, [int64]$ProgressContext.TotalBytes))
                            Set-CocoLauncherStep ([int]$ProgressContext.Step) ([string]$ProgressContext.Title) ("Descargando en paralelo ($($ProgressContext.Index)/$($ProgressContext.Count)): $($task.Asset.name)") $pct
                        }
                    }
                } catch {
                    $single = Get-CocoLockedAsset $CacheRoot $task.Asset $ProgressContext
                    $cachedResults[([string]$task.Asset.sha256).ToLowerInvariant()] = $single
                } finally {
                    $task.PS.Dispose()
                }
            } else {
                if ('System.Windows.Forms.Application' -as [type]) { [Windows.Forms.Application]::DoEvents() }
                [System.Threading.Thread]::Sleep(30)
            }
        }
        $pool.Close(); $pool.Dispose()
    }
    
    return $cachedResults
}

function Expand-CocoCurseForgeOverrides([string]$Archive,[string]$OverridesRoot,[string]$Destination){
    if(-not(Test-CocoSafeRelativePath $OverridesRoot)){throw 'La raiz de overrides no es segura.'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        $prefix=($OverridesRoot-replace'\\','/').TrimEnd('/')+'/'
        foreach($entry in $zip.Entries){
            $name=([string]$entry.FullName)-replace'\\','/'
            if(-not$name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)-or$name.EndsWith('/')){continue}
            $relative=$name.Substring($prefix.Length)
            if(-not(Test-CocoSafeRelativePath $relative)){throw "Override inseguro: '$name'."}
            if($relative.StartsWith('saves/',[StringComparison]::OrdinalIgnoreCase)-or$relative-match'(?i)(^|/)(playerdata|DistantHorizons)(/|$)'){throw "El pack intento administrar datos persistentes prohibidos: '$relative'."}
            $target=Join-Path $Destination ($relative-replace'/','\')
            $parent=Split-Path $target -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
            $input=$entry.Open();$output=[IO.File]::Open($target,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()}
        }
    }finally{$zip.Dispose()}
}

function Get-CocoCustomSkinLoaderVariant($GlobalPolicies,$Experience){
    if(-not$GlobalPolicies-or[string]$GlobalPolicies.customSkinLoader.mode-ne'required'){throw 'Falta la politica global de CustomSkinLoader.'}
    $matches=@($GlobalPolicies.customSkinLoader.variants|Where-Object{
        [string]$Experience.runtime.minecraftVersion-in@($_.minecraftVersions)
    })
    if($matches.Count-ne1){throw "No existe una variante unica de CustomSkinLoader para Minecraft $($Experience.runtime.minecraftVersion)."}
    return $matches[0]
}

function Test-CocoSkinServiceEndpoint([string]$Address='10.77.37.1',[int]$Port=25564,[int]$TimeoutMilliseconds=500){
    $client=[Net.Sockets.TcpClient]::new()
    try{
        $connect=$client.BeginConnect($Address,$Port,$null,$null)
        if(-not$connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)){return $false}
        $client.EndConnect($connect)
        $stream=$client.GetStream();$stream.ReadTimeout=$TimeoutMilliseconds;$stream.WriteTimeout=$TimeoutMilliseconds
        $request=[Text.Encoding]::ASCII.GetBytes("COCO-SKINS 1 MANIFEST`n")
        $stream.Write($request,0,$request.Length);$stream.Flush()
        $line=[Text.StringBuilder]::new()
        while($line.Length-lt128){$value=$stream.ReadByte();if($value-lt0){break};if($value-eq10){break};if($value-ne13){[void]$line.Append([char]$value)}}
        return $line.ToString()-match'^COCO-SKINS 1 OK [0-9]+$'
    }catch{return $false}finally{$client.Dispose()}
}

function Invoke-CocoSkinWireRequest($Catalog,[string]$Command,[byte[]]$Body=[byte[]]@()){
    $discovery=$Catalog.sessionDiscovery
    $client=[Net.Sockets.TcpClient]::new()
    try{
        $connect=$client.BeginConnect([string]$discovery.host,[int]$discovery.port,$null,$null)
        if(-not$connect.AsyncWaitHandle.WaitOne([int]$discovery.connectTimeoutMs)){throw 'El registro de skins no respondio.'}
        $client.EndConnect($connect)
        $stream=$client.GetStream();$stream.ReadTimeout=5000;$stream.WriteTimeout=5000
        $header=[Text.Encoding]::ASCII.GetBytes("$Command`n")
        $stream.Write($header,0,$header.Length)
        if($Body-and$Body.Length){$stream.Write($Body,0,$Body.Length)}
        $stream.Flush()
        $line=[Text.StringBuilder]::new()
        while($line.Length-lt128){$value=$stream.ReadByte();if($value-lt0){break};if($value-eq10){break};if($value-ne13){[void]$line.Append([char]$value)}}
        $parts=@($line.ToString()-split' ')
        if($parts.Count-ne4-or$parts[0]-ne'COCO-SKINS'-or$parts[1]-ne'1'){throw 'Respuesta invalida del registro de skins.'}
        $length=0;if(-not[int]::TryParse($parts[3],[ref]$length)-or$length-lt0-or$length-gt1048576){throw 'Tamano invalido del registro de skins.'}
        if($parts[2]-ne'OK'){throw "El registro de skins rechazo la operacion: $($parts[2])."}
        $response=New-Object byte[] $length;$offset=0
        while($offset-lt$length){$read=$stream.Read($response,$offset,$length-$offset);if($read-le0){throw 'Respuesta de skin incompleta.'};$offset+=$read}
        $response
    }finally{$client.Dispose()}
}

function Sync-CocoSkinRegistry($Catalog,$Paths,$Identity){
    $result=[ordered]@{Online=$false;Uploaded=$false;Downloaded=0;Pending=$false;Error=''}
    try{
        $selection=try{if(Test-Path -LiteralPath $Paths.SkinStatePath){Get-Content -LiteralPath $Paths.SkinStatePath -Raw|ConvertFrom-Json}else{$null}}catch{$null}
        if($selection-and[bool]$selection.pendingUpload-and$Identity-and[string]$selection.username-eq[string]$Identity.username){
            $own=Join-Path $Paths.SkinRoot "$($Identity.username).png"
            $validated=Test-CocoSkinPng $own
            $command="COCO-SKINS 1 PUT $($Identity.username) $($validated.Size) $($validated.Sha256)"
            [void](Invoke-CocoSkinWireRequest $Catalog $command ([IO.File]::ReadAllBytes($own)))
            $selection.pendingUpload=$false
            $selection|Add-Member -NotePropertyName syncedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            [IO.File]::WriteAllText($Paths.SkinStatePath,($selection|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
            $result.Uploaded=$true
        }
        $manifestBytes=Invoke-CocoSkinWireRequest $Catalog 'COCO-SKINS 1 MANIFEST'
        $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes)|ConvertFrom-Json
        if([int]$manifest.schemaVersion-ne1-or@($manifest.profiles).Count-gt64){throw 'Manifiesto de skins invalido.'}
        New-Item -ItemType Directory -Path $Paths.SkinRoot -Force|Out-Null
        foreach($profile in @($manifest.profiles)){
            $username=[string]$profile.username;$hash=([string]$profile.sha256).ToLowerInvariant();$size=[int64]$profile.size
            if(-not(Test-CocoMinecraftUsername $username)-or$hash-notmatch'^[a-f0-9]{64}$'-or$size-lt67-or$size-gt1048576){throw 'Entrada de skin remota invalida.'}
            $destination=Join-Path $Paths.SkinRoot "$username.png"
            if((Test-Path -LiteralPath $destination -PathType Leaf)-and(Get-Item -LiteralPath $destination).Length-eq$size-and(Get-CocoFileSha256 $destination)-eq$hash){continue}
            $bytes=Invoke-CocoSkinWireRequest $Catalog "COCO-SKINS 1 GET $username"
            $temporary="$destination.new-$PID";[IO.File]::WriteAllBytes($temporary,$bytes)
            $validated=Test-CocoSkinPng $temporary
            if($validated.Sha256-ne$hash-or$validated.Size-ne$size){Remove-Item -LiteralPath $temporary -Force;throw "La skin remota de $username no coincide con el manifiesto."}
            Move-Item -LiteralPath $temporary -Destination $destination -Force
            $result.Downloaded++
        }
        $result.Online=$true
    }catch{
        $result.Error=$_.Exception.Message
        $selection=try{if(Test-Path -LiteralPath $Paths.SkinStatePath){Get-Content -LiteralPath $Paths.SkinStatePath -Raw|ConvertFrom-Json}else{$null}}catch{$null}
        $result.Pending=[bool]($selection-and$selection.pendingUpload)
        if(Get-Command Write-CocoLog -ErrorAction SilentlyContinue){Write-CocoLog "Sincronizacion de skins pendiente: $($result.Error)"}
    }
    [pscustomobject]$result
}

function Sync-CocoOriginalSkinRegistry($Catalog,$Paths,[string]$LegacyMinecraftRoot,[string]$Role,[int64]$MinecraftProcessId=0){
    Initialize-CocoSkinRegistry $Catalog.globalPolicies $script:CocoEngineRoot $Paths.SkinRoot
    $service=$null
    if($Role-eq'host'-and$MinecraftProcessId-gt0){
        try{
            $service=Start-CocoSessionService (Join-Path $script:CocoEngineRoot 'CocoSessionService.ps1') `
                $Paths.SessionStatePath $Paths.SessionLogPath $MinecraftProcessId $Paths.SkinRoot
            if($service){$service.Dispose()}
        }catch{
            if(Get-Command Write-CocoLog -ErrorAction SilentlyContinue){Write-CocoLog "El registro de skins del mundo original no pudo iniciarse: $($_.Exception.Message)"}
        }
    }
    $identity=try{Read-CocoLauncherIdentityState $Paths.IdentityPath}catch{$null}
    $sync=Sync-CocoSkinRegistry $Catalog $Paths $identity
    [void](Install-CocoSkinRegistry $Paths.SkinRoot $LegacyMinecraftRoot)
    [pscustomobject]@{
        Online=[bool]$sync.Online
        Uploaded=[bool]$sync.Uploaded
        Downloaded=[int]$sync.Downloaded
        Pending=[bool]$sync.Pending
        Error=[string]$sync.Error
    }
}

function Remove-CocoEssentialArtifacts([string]$InstanceRoot){
    if([string]::IsNullOrWhiteSpace($InstanceRoot)-or-not[IO.Path]::IsPathRooted($InstanceRoot)){throw 'La raiz de instancia para excluir Essential no es valida.'}
    $removed=0
    $mods=Join-Path $InstanceRoot 'mods'
    foreach($jar in @(Get-ChildItem -LiteralPath $mods -File -ErrorAction SilentlyContinue|Where-Object{$_.Name-match'(?i)^(?!ftb-)essential.*\.jar$'})){
        if(-not(Test-CocoPathWithin $jar.FullName $InstanceRoot)){throw 'Essential intento escapar de la instancia.'}
        Remove-Item -LiteralPath $jar.FullName -Force
        $removed++
    }
    $essentialRoot=Join-Path $InstanceRoot 'essential'
    if(Test-Path -LiteralPath $essentialRoot -PathType Container){
        if(-not(Test-CocoPathWithin $essentialRoot $InstanceRoot)){throw 'La carpeta Essential escapa de la instancia.'}
        Remove-Item -LiteralPath $essentialRoot -Recurse -Force
        $removed++
    }
    return $removed
}

function Set-CocoGlobalSkinAssets($GlobalPolicies,$Experience,[string]$InstanceRoot,[string]$EngineRoot){
    $variant=Get-CocoCustomSkinLoaderVariant $GlobalPolicies $Experience
    $selectedJar=Join-Path $InstanceRoot (([string]$variant.path)-replace'/','\')
    if(-not(Test-Path -LiteralPath $selectedJar -PathType Leaf)-or
        (Get-CocoFileSha256 $selectedJar)-ne[string]$variant.sha256){
        throw "CustomSkinLoader no quedo instalado correctamente para Minecraft $($Experience.runtime.minecraftVersion)."
    }
    foreach($jar in @(Get-ChildItem -LiteralPath (Join-Path $InstanceRoot 'mods') -File -Filter 'CustomSkinLoader_*.jar' -ErrorAction SilentlyContinue)){
        if(-not[string]::Equals($jar.FullName,$selectedJar,[StringComparison]::OrdinalIgnoreCase)){
            if(-not(Test-CocoPathWithin $jar.FullName $InstanceRoot)){throw 'CustomSkinLoader intento escapar de la instancia.'}
            Remove-Item -LiteralPath $jar.FullName -Force
        }
    }
    foreach($skin in @($GlobalPolicies.customSkinLoader.localSkins)){
        $embedded=Join-Path $EngineRoot (([string]$skin.embeddedPath)-replace'/','\')
        if(-not(Test-Path -LiteralPath $embedded -PathType Leaf)-or
            (Get-CocoFileSha256 $embedded)-ne[string]$skin.sha256){
            throw "La skin global de '$($skin.username)' falta o no coincide con el engine."
        }
        $destination=Join-Path $InstanceRoot ("CustomSkinLoader\LocalSkin\skins\{0}.png"-f[string]$skin.username)
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
        if((Test-Path -LiteralPath $destination -PathType Leaf)-and
            (Get-CocoFileSha256 $destination)-eq[string]$skin.sha256){continue}
        $temporary="$destination.new-$PID"
        Copy-Item -LiteralPath $embedded -Destination $temporary -Force
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    }
}

function Ensure-CocoSteamRunning([switch]$Quiet){
    Write-CocoLog "Verificando ejecucion de Steam..."
    $running=@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
    if($running.Count-gt0){
        Write-CocoLog "Steam ya se encuentra en ejecucion (PID: $($running[0].Id))."
        return $true
    }

    if(-not$Quiet){
        Set-CocoLauncherStep 4 'VERIFICANDO STEAM' 'Buscando Steam para habilitar la red multijugador P2P en segundo plano...' 31
    }
    $steamExe=''

    # 1. HKCR URI handler
    try{
        $cmd=(Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\steam\Shell\Open\Command' -ErrorAction Stop).'(default)'
        if($cmd -match '^"([^"]+)"'){
            $cand=$matches[1]
            if(Test-Path -LiteralPath $cand -PathType Leaf){$steamExe=$cand}
        }
    }catch{}

    # 2. Registry HKCU
    if([string]::IsNullOrWhiteSpace($steamExe)){
        try{
            $regVal=Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
            if($regVal-and$regVal.SteamExe-and(Test-Path -LiteralPath $regVal.SteamExe -PathType Leaf)){
                $steamExe=[string]$regVal.SteamExe
            }elseif($regVal-and$regVal.SteamPath-and(Test-Path -LiteralPath (Join-Path $regVal.SteamPath 'steam.exe') -PathType Leaf)){
                $steamExe=Join-Path $regVal.SteamPath 'steam.exe'
            }
        }catch{}
    }

    # 3. Registry HKLM WOW6432Node & 64-bit
    if([string]::IsNullOrWhiteSpace($steamExe)){
        foreach($regKey in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam'){
            try{
                $regVal=Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue
                if($regVal-and$regVal.InstallPath-and(Test-Path -LiteralPath (Join-Path $regVal.InstallPath 'steam.exe') -PathType Leaf)){
                    $steamExe=Join-Path $regVal.InstallPath 'steam.exe'
                    break
                }
            }catch{}
        }
    }

    # 4. Known disk locations across all available fixed drives
    if([string]::IsNullOrWhiteSpace($steamExe)){
        $candidateSubPaths=@(
            'Program Files (x86)\Steam\steam.exe',
            'Program Files\Steam\steam.exe',
            'Steam\steam.exe',
            'Games\Steam\steam.exe',
            'Juegos\Steam\steam.exe'
        )
        $drives=@([IO.DriveInfo]::GetDrives()|Where-Object{$_.DriveType-eq'Fixed'}|Select-Object -ExpandProperty Name)
        foreach($drive in $drives){
            foreach($sub in $candidateSubPaths){
                $candidate=Join-Path $drive $sub
                if(Test-Path -LiteralPath $candidate -PathType Leaf){
                    $steamExe=$candidate
                    break
                }
            }
            if(-not[string]::IsNullOrWhiteSpace($steamExe)){break}
        }
    }

    if([string]::IsNullOrWhiteSpace($steamExe)){
        Write-CocoLog "Aviso: No se encontro Steam en el registro ni en rutas habituales. Continuando ejecucion standalone por si no requiere Steam o el usuario lo inicia por separado."
        return $false
    }

    Write-CocoLog "Iniciando Steam minimizado a la bandeja desde '$steamExe'..."
    if(-not$Quiet){
        Set-CocoLauncherStep 4 'INICIANDO STEAM' 'Steam se iniciara minimizado en la bandeja del sistema (0 friccion)...' 33
    }

    try{
        Start-Process -FilePath $steamExe -ArgumentList '-silent' -ErrorAction Stop
    }catch{
        Write-CocoLog "No se pudo ejecutar Steam desde '$steamExe': $($_.Exception.Message). Continuando ejecucion standalone."
        return $false
    }

    $started=$false
    for($i=0; $i-lt30; $i++){
        Start-Sleep -Milliseconds 500
        if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
        $running=@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
        if($running.Count-gt0){
            $started=$true
            break
        }
    }

    if(-not$started){
        Write-CocoLog "Steam fue iniciado pero tardo mas de 15s en registrar su proceso; continuando."
    }else{
        Write-CocoLog "Steam iniciado con exito minimizado en la bandeja. Esperando estabilizacion de IPC..."
        for($j=0; $j-lt5; $j++){
            Start-Sleep -Milliseconds 500
            if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
        }
    }
    return $true
}

function Test-CocoStandaloneMutableExtraPath([string]$RelativePath){
    $normalized=([string]$RelativePath)-replace'\\','/'
    return $normalized-match'(?i)^BepInEx/config/'
}

function Install-CocoStandaloneExperienceFiles($Experience,[string]$InstanceRoot,[string]$CacheRoot,[object[]]$Files,[object[]]$PreviousManifest=@()){
    $filesDir=Join-Path $CacheRoot 'downloads\standalone-files'
    New-Item -ItemType Directory -Path $filesDir -Force|Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $workRoot=Join-Path $CacheRoot ("downloads\standalone-files-stage\$($Experience.id)-$([guid]::NewGuid().ToString('N'))")
    $stageRoot=Join-Path $workRoot 'files'
    $backupRoot=Join-Path $workRoot 'backup'
    New-Item -ItemType Directory -Path $stageRoot,$backupRoot -Force|Out-Null
    $staged=[Collections.Generic.List[object]]::new()
    $manifest=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try{
        foreach($file in @($Files)){
            $sha=([string]$file.sha256).ToLowerInvariant()
            $cached=Join-Path $filesDir $sha
            $cacheValid=$false
            if(Test-Path -LiteralPath $cached -PathType Leaf){
                $cachedInfo=Get-Item -LiteralPath $cached -Force
                $cacheValid=([int64]$file.size-le0-or$cachedInfo.Length-eq[int64]$file.size)-and
                    (Get-CocoFileSha256 $cached)-eq$sha
                if(-not$cacheValid){Remove-Item -LiteralPath $cached -Force}
            }
            if(-not$cacheValid){
                $sourceUrl=[string]$file.sourceUrl
                Write-CocoLog "Descargando archivo adicional de '$($Experience.id)': $sourceUrl -> $cached"
                $temporary="$cached.downloading-$PID"
                try{
                    if(Test-Path -LiteralPath $sourceUrl){
                        Copy-Item -LiteralPath $sourceUrl -Destination $temporary -Force
                    }elseif(Get-Command Download-VerifiedFile -ErrorAction SilentlyContinue){
                        Download-VerifiedFile $sourceUrl $temporary $sha
                    }else{
                        $webClient=New-Object System.Net.WebClient
                        try{$webClient.DownloadFile([Uri]$sourceUrl,$temporary)}finally{$webClient.Dispose()}
                    }
                    $temporaryInfo=Get-Item -LiteralPath $temporary -Force
                    if(([int64]$file.size-gt0-and$temporaryInfo.Length-ne[int64]$file.size)-or
                       (Get-CocoFileSha256 $temporary)-ne$sha){
                        throw "El archivo adicional '$($file.path)' de '$($Experience.id)' no coincide con su tamano o SHA-256 esperado."
                    }
                    Move-Item -LiteralPath $temporary -Destination $cached -Force
                }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
            }
            $relative=([string]$file.path)-replace'\\','/'
            if(-not(Test-CocoSafeRelativePath $relative)){throw "Ruta administrada insegura en '$($Experience.id)': '$($file.path)'."}
            if([IO.Path]::GetExtension($relative)-ieq'.zip'){
                $zip=[IO.Compression.ZipFile]::OpenRead($cached)
                try{
                    foreach($entry in @($zip.Entries|Where-Object{-not$_.FullName.EndsWith('/')-and-not$_.FullName.EndsWith('\')})){
                        $entryRelative=([string]$entry.FullName)-replace'\\','/'
                        if(-not(Test-CocoSafeRelativePath $entryRelative)){throw "Ruta insegura dentro del paquete '$relative': '$entryRelative'."}
                        if(-not$seen.Add($entryRelative)){throw "Ruta duplicada dentro de archivos adicionales de '$($Experience.id)': '$entryRelative'."}
                        $stagedPath=Join-Path $stageRoot ($entryRelative-replace'/','\')
                        New-Item -ItemType Directory -Path (Split-Path $stagedPath -Parent) -Force|Out-Null
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$stagedPath,$true)
                        $stagedInfo=Get-Item -LiteralPath $stagedPath -Force
                        $record=[pscustomobject]@{path=$entryRelative;sha256=(Get-CocoFileSha256 $stagedPath);size=[int64]$stagedInfo.Length;mutable=(Test-CocoStandaloneMutableExtraPath $entryRelative);stagedPath=$stagedPath}
                        $staged.Add($record)
                        if(-not$record.mutable){$manifest.Add([pscustomobject]@{path=$record.path;sha256=$record.sha256;size=$record.size})}
                    }
                }finally{$zip.Dispose()}
            }else{
                if(-not$seen.Add($relative)){throw "Ruta duplicada dentro de archivos adicionales de '$($Experience.id)': '$relative'."}
                $stagedPath=Join-Path $stageRoot ($relative-replace'/','\')
                New-Item -ItemType Directory -Path (Split-Path $stagedPath -Parent) -Force|Out-Null
                Copy-Item -LiteralPath $cached -Destination $stagedPath -Force
                $stagedInfo=Get-Item -LiteralPath $stagedPath -Force
                $record=[pscustomobject]@{path=$relative;sha256=$sha;size=[int64]$stagedInfo.Length;mutable=(Test-CocoStandaloneMutableExtraPath $relative);stagedPath=$stagedPath}
                $staged.Add($record)
                if(-not$record.mutable){$manifest.Add([pscustomobject]@{path=$record.path;sha256=$record.sha256;size=$record.size})}
            }
        }

        $newPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($item in $manifest){[void]$newPaths.Add([string]$item.path)}
        $journal=[Collections.Generic.List[object]]::new()
        try{
            foreach($old in @($PreviousManifest)){
                $oldRelative=([string]$old.path)-replace'\\','/'
                if(-not(Test-CocoSafeRelativePath $oldRelative)-or$newPaths.Contains($oldRelative)){continue}
                $destination=Join-Path $InstanceRoot ($oldRelative-replace'/','\')
                if(Test-Path -LiteralPath $destination -PathType Leaf){
                    $backup=Join-Path $backupRoot ($oldRelative-replace'/','\')
                    New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force|Out-Null
                    Move-Item -LiteralPath $destination -Destination $backup -Force
                    $journal.Add([pscustomobject]@{Destination=$destination;Backup=$backup;NewInstalled=$false})
                }
            }
            foreach($item in $staged){
                $destination=Join-Path $InstanceRoot (([string]$item.path)-replace'/','\')
                if($item.mutable-and(Test-Path -LiteralPath $destination -PathType Leaf)){
                    Write-CocoLog "Configuracion standalone preservada: $($item.path)"
                    continue
                }
                if((Test-Path -LiteralPath $destination -PathType Leaf)-and
                   (Get-Item -LiteralPath $destination -Force).Length-eq[int64]$item.size-and
                   (Get-CocoFileSha256 $destination)-eq[string]$item.sha256){continue}
                if(Test-Path -LiteralPath $destination -PathType Container){throw "Una carpeta impide instalar el archivo standalone '$($item.path)'."}
                $backup=$null
                if(Test-Path -LiteralPath $destination -PathType Leaf){
                    $backup=Join-Path $backupRoot (([string]$item.path)-replace'/','\')
                    New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force|Out-Null
                    Move-Item -LiteralPath $destination -Destination $backup -Force
                }
                New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
                Copy-Item -LiteralPath $item.stagedPath -Destination $destination -Force
                $journal.Add([pscustomobject]@{Destination=$destination;Backup=$backup;NewInstalled=$true})
            }
        }catch{
            $original=$_
            $rollback=@($journal.ToArray());[array]::Reverse($rollback)
            foreach($entry in $rollback){
                if($entry.NewInstalled-and(Test-Path -LiteralPath $entry.Destination -PathType Leaf)){Remove-Item -LiteralPath $entry.Destination -Force -ErrorAction SilentlyContinue}
                if($entry.Backup-and(Test-Path -LiteralPath $entry.Backup -PathType Leaf)){New-Item -ItemType Directory -Path (Split-Path $entry.Destination -Parent) -Force|Out-Null;Move-Item -LiteralPath $entry.Backup -Destination $entry.Destination -Force}
            }
            throw $original
        }
        Write-CocoLog "Archivos adicionales de '$($Experience.id)' aplicados transaccionalmente en '$InstanceRoot'."
        return @($manifest.ToArray())
    }finally{Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

function Test-CocoStandaloneExtraManifest([string]$InstanceRoot,[object[]]$Manifest){
    if($null-eq$Manifest){return $false}
    try{
        foreach($item in $Manifest){
            $relative=([string]$item.path)-replace'\\','/'
            if(-not(Test-CocoSafeRelativePath $relative)){return $false}
            $target=Join-Path $InstanceRoot ($relative-replace'/','\')
            if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
            $targetInfo=Get-Item -LiteralPath $target -Force
            if([int64]$targetInfo.Length-ne[int64]$item.size){return $false}
            $actual=(Get-CocoFileSha256 $target)
            if($actual-ne([string]$item.sha256).ToLowerInvariant()){return $false}
        }
        return $true
    }catch{
        Write-CocoLog "No se pudo validar el manifiesto de archivos adicionales: $($_.Exception.Message)"
        return $false
    }
}

function Install-CocoStandaloneExperience($Experience, [string]$ExperiencesRoot, [string]$CacheRoot, [string]$InstanceLocationsPath='',[ValidateSet('client','host')][string]$Role='client'){
    if($Experience.managementMode-ne'managed'){throw 'La experiencia no esta marcada como administrada.'}
    $instanceRoot=Get-CocoExperienceInstanceRoot $Experience $ExperiencesRoot $InstanceLocationsPath
    $fullInstance=[IO.Path]::GetFullPath($instanceRoot)
    $rootPath=[IO.Path]::GetPathRoot($fullInstance)
    if($fullInstance.TrimEnd('\')-eq$rootPath.TrimEnd('\')){throw 'No se puede instalar en un directorio raiz del sistema.'}
    if(-not(Test-CocoPathWithin $instanceRoot $ExperiencesRoot)){
        $locations=Get-CocoInstanceCustomLocations $InstanceLocationsPath
        $isCustom=$false
        if($locations){
            foreach($prop in $locations.PSObject.Properties){
                if([string]$prop.Value-and[IO.Path]::GetFullPath([string]$prop.Value).Equals($fullInstance,[StringComparison]::OrdinalIgnoreCase)){
                    $isCustom=$true;break
                }
            }
        }
        if(-not$isCustom){throw 'La raiz de instancia escapa del directorio de experiencias.'}
    }
    $execName=[string]$Experience.runtime.executable
    if(Test-CocoManagedGameRunning $instanceRoot $execName){
        throw "La instancia '$($Experience.name)' ya esta abierta. Cierrala antes de verificar sus archivos."
    }
    if([int64]$Experience.launch.minimumFreeBytes-gt0){
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($instanceRoot)))
        if($drive.AvailableFreeSpace-lt[int64]$Experience.launch.minimumFreeBytes){
            throw ("No hay espacio suficiente para {0}. Libera al menos {1:N1} GB en {2}."-f$Experience.name,([int64]$Experience.launch.minimumFreeBytes/1GB),$drive.Name)
        }
    }
    $statePath=Join-Path $instanceRoot '.coco\standalone-state.json'
    try { [void](Ensure-CocoDefenderExclusion $Experience $instanceRoot) } catch {}
    try { [void](Ensure-CocoSteamRunning -Quiet) } catch {}
    $archiveItems = @(if($Experience.pack.archives){$Experience.pack.archives}else{$Experience.pack})
    $expectedSha = [string]$Experience.pack.sha256
    if(-not$expectedSha -and $archiveItems.Count-gt0){
        $expectedSha = [string]$archiveItems[0].sha256
    }
    $expectedSha = $expectedSha.ToLowerInvariant()
    $expectedSize = if([int64]$Experience.pack.size-gt0){[int64]$Experience.pack.size}else{
        $sum=0;foreach($item in $archiveItems){$sum+=[int64]$item.size};$sum
    }
    $expectedExtrasArray=@($Experience.files|Where-Object{[string]$_.role-in@('all',$Role)})
    $expectedExtrasSha=if($expectedExtrasArray.Count-gt0){($expectedExtrasArray|ForEach-Object{([string]$_.sha256).ToLowerInvariant()}|Sort-Object)-join';'}else{'none'}

    Write-CocoLog "Comprobando instalacion standalone de '$($Experience.id)': Hash esperado=$expectedSha, Tamano=$expectedSize bytes, Extras=$expectedExtrasSha"

    $execPath=Join-Path $instanceRoot ($execName -replace '/','\')
    $existingState=$null
    if(Test-Path -LiteralPath $statePath){
        try{
            $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        }catch{
            Write-CocoLog "No se pudo leer el estado anterior de la instancia standalone: $($_.Exception.Message)"
        }
    }
    $previousExtraManifest=if($existingState-and$existingState.PSObject.Properties['extraFiles']){@($existingState.extraFiles)}else{@()}
    $extraManifest=@($previousExtraManifest)
    $extraManifestValid=$false
    $extraStateCurrent=$false
    if($existingState-and[int]$existingState.schemaVersion-ge2-and$existingState.PSObject.Properties['extraFiles']){
        $extraManifestValid=Test-CocoStandaloneExtraManifest $instanceRoot $extraManifest
        $extraStateCurrent=$extraManifestValid-and[string]$existingState.filesSha-eq$expectedExtrasSha-and[string]$existingState.role-eq$Role
    }
    if($existingState-and[string]$existingState.sha256-eq$expectedSha-and(Test-Path -LiteralPath $execPath)-and$extraStateCurrent){
        Ensure-CocoOnlineFixSuppression $instanceRoot $Experience
        return [pscustomobject]@{InstanceRoot=$instanceRoot;Updated=$false}
    }
    $archivesUpToDate=$false
    if($existingState-and[string]$existingState.sha256-eq$expectedSha-and(Test-Path -LiteralPath $execPath)){$archivesUpToDate=$true}

    if(-not $archivesUpToDate){
    Set-CocoLauncherStep 4 'DESCARGANDO JUEGO STANDALONE' ("{0} | {1:N1} MB totales"-f $Experience.name, ($expectedSize / 1MB)) 30
    $downloadsDir=Join-Path $CacheRoot 'downloads\standalone-packs'
    New-Item -ItemType Directory -Path $downloadsDir -Force|Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $instanceRoot -Force|Out-Null

    $partIndex = 0
    foreach($packItem in $archiveItems){
        $partIndex++
        $itemSha = [string]$packItem.sha256
        $itemSize = [int64]$packItem.size
        $archive = Join-Path $downloadsDir ("$itemSha.zip")
        $archiveValid = $false

        if(Test-Path -LiteralPath $archive){
            Set-CocoLauncherStep 4 'VERIFICANDO HASH DEL ARCHIVO DESCARGADO' ("Calculando SHA-256 parte {0}/{1} ({2:N1} MB)..."-f $partIndex, $archiveItems.Count, ((Get-Item -LiteralPath $archive).Length / 1MB)) 32
            $actualSha=Get-CocoFileSha256 $archive
            if($actualSha-eq$itemSha){
                $archiveValid=$true
                Write-CocoLog "Archivo en cache verificado con exito: $archive"
            }else{
                Write-CocoLog "Hash en cache no coincide (Encontrado: $actualSha, Esperado: $itemSha). Eliminando archivo corrupto."
                Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            }
        }

        if(-not$archiveValid){
            $sourceUrl=[string]$packItem.archiveUrl
            if([string]::IsNullOrWhiteSpace($sourceUrl)-and$packItem.manifestUrl){
                $sourceUrl=[string]$packItem.manifestUrl
            }
            Write-CocoLog "Iniciando descarga/copia de paquete standalone desde: $sourceUrl -> $archive"

            if(Test-Path -LiteralPath $sourceUrl){
                Write-CocoLog "Copiando paquete standalone desde origen local: $sourceUrl"
                Copy-Item -LiteralPath $sourceUrl -Destination $archive -Force
            }else{
                $curlSuccess = $false
                if(Get-Command curl.exe -ErrorAction SilentlyContinue){
                    try{
                        Write-CocoLog "Iniciando descarga a alta velocidad con curl.exe: $sourceUrl -> $archive"
                        Set-CocoLauncherStep 4 'DESCARGANDO PAQUETE STANDALONE' ("Parte {0}/{1}: Conectando descarga a alta velocidad... | {2}"-f $partIndex, $archiveItems.Count, $Experience.name) (30 + [int]((($partIndex - 1)/$archiveItems.Count)*35))
                        $partialArchive="$archive.partial"
                        if(Test-Path -LiteralPath $partialArchive -PathType Leaf){
                            $partialSize=[int64](Get-Item -LiteralPath $partialArchive).Length
                            if($partialSize -eq [int64]$itemSize){
                                $partialHash=Get-CocoFileSha256 $partialArchive
                                if($partialHash -eq $itemSha){
                                    Move-Item -LiteralPath $partialArchive -Destination $archive -Force
                                    $curlSuccess=$true
                                    Write-CocoLog "Parcial completo verificado y reutilizado sin solicitar rango: $partialArchive"
                                }else{
                                    Remove-Item -LiteralPath $partialArchive -Force -ErrorAction SilentlyContinue
                                    Write-CocoLog "Parcial completo con hash incorrecto; se descarta antes de reanudar: $partialArchive"
                                }
                            }elseif($partialSize -gt [int64]$itemSize){
                                Remove-Item -LiteralPath $partialArchive -Force -ErrorAction SilentlyContinue
                                Write-CocoLog "Parcial mayor que el tamano esperado; se descarta antes de reanudar: $partialSize bytes > $itemSize bytes"
                            }
                        }
                        if(-not$curlSuccess){
                            $proc = Start-Process -FilePath "curl.exe" -ArgumentList @("-L", "-s", "--retry", "3", "--continue-at", "-", "-o", $partialArchive, $sourceUrl) -PassThru -NoNewWindow
                            $lastUi = [DateTime]::MinValue
                            while(-not $proc.HasExited){
                                if(Test-Path -LiteralPath $partialArchive){
                                    $now = [DateTime]::UtcNow
                                    if(($now - $lastUi).TotalMilliseconds -ge 150){
                                        $lastUi = $now
                                        $curBytes = (Get-Item -LiteralPath $partialArchive).Length
                                        $curMb = $curBytes / 1MB
                                        $totalMb = if($itemSize -gt 0){$itemSize / 1MB}else{1}
                                        $pct = [Math]::Min(99, [int](($curBytes / [Math]::Max(1, $itemSize)) * 100))
                                        Set-CocoLauncherStep 4 'DESCARGANDO PAQUETE STANDALONE' ("Parte {0}/{1}: {2:N1} MB / {3:N1} MB ({4}%) | {5}"-f $partIndex, $archiveItems.Count, $curMb, $totalMb, $pct, $Experience.name) (30 + [int]($pct * 0.35))
                                    }
                                }
                                if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
                                Start-Sleep -Milliseconds 100
                            }
                            if(Test-Path -LiteralPath $partialArchive -PathType Leaf){
                                $partialSize=[int64](Get-Item -LiteralPath $partialArchive).Length
                                if($partialSize -eq [int64]$itemSize){
                                    $partialHash=Get-CocoFileSha256 $partialArchive
                                    if($partialHash -eq $itemSha){
                                        Move-Item -LiteralPath $partialArchive -Destination $archive -Force
                                        $curlSuccess=$true
                                        Write-CocoLog "curl.exe dejo el parcial completo y verificado: $partialArchive"
                                    }else{
                                        Remove-Item -LiteralPath $partialArchive -Force -ErrorAction SilentlyContinue
                                        Write-CocoLog "curl.exe dejo un parcial completo con hash incorrecto; se descarta para descarga limpia."
                                    }
                                }elseif($partialSize -gt [int64]$itemSize){
                                    Remove-Item -LiteralPath $partialArchive -Force -ErrorAction SilentlyContinue
                                    Write-CocoLog "curl.exe dejo un parcial mayor que el tamano esperado; se descarta."
                                }
                            }
                            if(-not$curlSuccess-and$proc.ExitCode-ne0){
                                Write-CocoLog "curl.exe finalizo con codigo $($proc.ExitCode). Se conserva el parcial valido para reanudar con fallback..."
                            }
                        }
                    }catch{
                        Write-CocoLog "Fallo descarga con curl.exe: $($_.Exception.Message). Se conserva el parcial para reanudar con fallback..."
                    }
                }
                if(-not$curlSuccess){
                    if(Get-Command Download-VerifiedFile -ErrorAction SilentlyContinue){
                        Download-VerifiedFile $sourceUrl $archive $itemSha
                    }else{
                        $webClient=New-Object System.Net.WebClient
                        try{
                            $lastStepReport=[DateTime]::MinValue
                            $webClient.add_DownloadProgressChanged({
                                param($sender, $e)
                                if((Get-Date)-gt$lastStepReport.AddMilliseconds(200)){
                                    $pct=$e.ProgressPercentage
                                    $receivedMb=$e.BytesReceived / 1MB
                                    $totalMb=$e.TotalBytesToReceive / 1MB
                                    if($totalMb-le0){$totalMb=$itemSize / 1MB}
                                    Set-CocoLauncherStep 4 'DESCARGANDO PAQUETE STANDALONE' ("Parte {0}/{1}: {2:N1} MB / {3:N1} MB ({4}%) | {5}"-f $partIndex, $archiveItems.Count, $receivedMb, $totalMb, $pct, $Experience.name) (30 + [int]($pct * 0.35))
                                    $lastStepReport=Get-Date
                                }
                            })
                            $asyncTask=$webClient.DownloadFileTaskAsync([Uri]$sourceUrl, $archive)
                            while(-not$asyncTask.IsCompleted){
                                if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()};Start-Sleep -Milliseconds 50
                            }
                            if($asyncTask.IsFaulted){
                                throw $asyncTask.Exception.InnerException
                            }
                        }finally{
                            $webClient.Dispose()
                        }
                    }
                }
            }

            Set-CocoLauncherStep 4 'VERIFICANDO INTEGRIDAD DEL PAQUETE' ("Comprobando hash SHA-256 parte {0}/{1}..."-f $partIndex, $archiveItems.Count) 62
            $downloadedSha=Get-CocoFileSha256 $archive
            if($downloadedSha-ne$itemSha){
                throw "El paquete descargado de '$($Experience.name)' (parte $partIndex) no coincide con el SHA-256 esperado (Obtenido: $downloadedSha, Esperado: $itemSha)."
            }
            Write-CocoLog "Descarga de paquete standalone parte $partIndex completada y verificada: SHA256=$downloadedSha"
        }

        Set-CocoLauncherStep 5 'DESCOMPRIMIENDO JUEGO STANDALONE' ("Extrayendo parte {0}/{1} de {2}..." -f $partIndex, $archiveItems.Count, $Experience.name) 65
        Write-CocoLog "Extrayendo paquete standalone '$archive' en '$instanceRoot'..."

        $validationZip=[IO.Compression.ZipFile]::OpenRead($archive)
        try{
            $archivePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($candidateEntry in @($validationZip.Entries|Where-Object{-not$_.FullName.EndsWith('/')-and-not$_.FullName.EndsWith('\')-and-not[string]::IsNullOrEmpty($_.Name)})){
                $candidatePath=($candidateEntry.FullName-replace'\\','/').TrimStart('/')
                $candidateTarget=Join-Path $instanceRoot ($candidatePath-replace'/','\')
                if(-not(Test-CocoSafeRelativePath $candidatePath)-or
                   -not(Test-CocoPathWithin $candidateTarget $instanceRoot)-or-not$archivePaths.Add($candidatePath)){
                    throw "El paquete standalone contiene una ruta insegura o duplicada: '$($candidateEntry.FullName)'."
                }
            }
        }finally{$validationZip.Dispose()}

        if(-not (Test-Path -LiteralPath $instanceRoot)){
            New-Item -ItemType Directory -Path $instanceRoot -Force | Out-Null
            Write-CocoLog "Creado directorio de la experiencia: '$instanceRoot'"
        }

        $extractedSuccessfully = $false
        try{
            $zip=[IO.Compression.ZipFile]::OpenRead($archive)
            try{
                $entries=@($zip.Entries|Where-Object{-not$_.FullName.EndsWith('/')-and-not$_.FullName.EndsWith('\')-and-not[string]::IsNullOrEmpty($_.Name)})
                $totalEntries=[Math]::Max(1, $entries.Count)
                $extractedCount=0
                foreach($entry in $entries){
                    $extractedCount++
                    $normEntryPath = ($entry.FullName -replace '\\','/').TrimStart('/')
                    $targetPath=Join-Path $instanceRoot ($normEntryPath -replace '/','\')
                    $targetDir=Split-Path $targetPath -Parent
                    if(-not(Test-Path -LiteralPath $targetDir)){
                        New-Item -ItemType Directory -Path $targetDir -Force|Out-Null
                    }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
                    if($extractedCount%25-eq0 -or $extractedCount-eq$totalEntries){
                        $pct=[int](($extractedCount / $totalEntries) * 30)
                        Set-CocoLauncherStep 5 'DESCOMPRIMIENDO JUEGO STANDALONE' ("Parte {0}/{1}: {2}/{3} archivos extraidos ({4}%) | {5}" -f $partIndex, $archiveItems.Count, $extractedCount, $totalEntries, [int](($extractedCount/$totalEntries)*100), $Experience.name) (65 + $pct)
                        [Windows.Forms.Application]::DoEvents()
                    }
                }
                $extractedSuccessfully = $true
                Write-CocoLog "Extraccion con .NET ZipFile completada exitosamente: $totalEntries archivos extraidos."
            }finally{
                $zip.Dispose()
            }
        }catch{
            Write-CocoLog "Extraccion con .NET ZipFile aviso ($($_.Exception.Message)). Probando fallback con tar.exe / Expand-Archive..."
        }

        if(-not $extractedSuccessfully){
            $tarPath = Join-Path $env:SystemRoot "System32\tar.exe"
            if((Test-Path -LiteralPath $tarPath) -or (Get-Command tar.exe -ErrorAction SilentlyContinue)){
                Set-CocoLauncherStep 5 'DESCOMPRIMIENDO JUEGO STANDALONE' ("Extrayendo parte {0}/{1} con tar.exe..." -f $partIndex, $archiveItems.Count) 75
                Write-CocoLog "Ejecutando tar.exe -xf '$archive' -C '$instanceRoot'..."
                $proc = Start-Process -FilePath "tar.exe" -ArgumentList @('-xf', $archive, '-C', $instanceRoot) -WindowStyle Hidden -Wait -PassThru
                Write-CocoLog "tar.exe finalizo con codigo $($proc.ExitCode)."
                if($proc.ExitCode -ne 0){
                    Write-CocoLog "tar.exe devolvio codigo $($proc.ExitCode). Ejecutando Expand-Archive como salvaguarda..."
                    Set-CocoLauncherStep 5 'DESCOMPRIMIENDO JUEGO STANDALONE' ("Extrayendo parte {0}/{1} con Expand-Archive..." -f $partIndex, $archiveItems.Count) 80
                    Expand-Archive -LiteralPath $archive -DestinationPath $instanceRoot -Force
                }
                $filesExtracted = (Get-ChildItem -Path $instanceRoot -Recurse -File -ErrorAction SilentlyContinue).Count
                Write-CocoLog "Extraccion de parte $partIndex completada: $filesExtracted archivos presentes en '$instanceRoot'."
            }else{
                Set-CocoLauncherStep 5 'DESCOMPRIMIENDO JUEGO STANDALONE' ("Extrayendo parte {0}/{1} con Expand-Archive..." -f $partIndex, $archiveItems.Count) 75
                Write-CocoLog "Ejecutando Expand-Archive -LiteralPath '$archive' -DestinationPath '$instanceRoot'..."
                Expand-Archive -LiteralPath $archive -DestinationPath $instanceRoot -Force
                $filesExtracted = (Get-ChildItem -Path $instanceRoot -Recurse -File -ErrorAction SilentlyContinue).Count
                Write-CocoLog "Extraccion de parte $partIndex completada con Expand-Archive: $filesExtracted archivos en total."
            }
        }
    }

    $splitParts = @(Get-ChildItem -Path $instanceRoot -Recurse -Filter '*.part1' -ErrorAction SilentlyContinue) + @(Get-ChildItem -Path $instanceRoot -Recurse -Filter '*.001' -ErrorAction SilentlyContinue)
    foreach($p1 in $splitParts){
        $ext = [System.IO.Path]::GetExtension($p1.Name)
        $baseName = $p1.Name.Substring(0, $p1.Name.Length - $ext.Length)
        $targetFile = Join-Path $p1.DirectoryName $baseName
        $parts = Get-ChildItem -Path $p1.DirectoryName -Filter "$baseName.*" | Where-Object { $_.Name -match "^$([regex]::Escape($baseName))\.(part\d+|\d{3})$" } | Sort-Object Name
        if($parts.Count -gt 1){
            Write-CocoLog "Reensamblando archivo dividido '$baseName' ($($parts.Count) partes)..."
            $outFs = [System.IO.File]::Create($targetFile)
            try{
                foreach($pt in $parts){
                    $inFs = [System.IO.File]::OpenRead($pt.FullName)
                    try{ $inFs.CopyTo($outFs) }finally{ $inFs.Dispose() }
                }
            }finally{ $outFs.Dispose() }
            $parts | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
            Write-CocoLog "Archivo '$baseName' reensamblado con exito en '$targetFile'."
        }
    }

$metaDir=Join-Path $instanceRoot '.coco'
    New-Item -ItemType Directory -Path $metaDir -Force|Out-Null
    }
    $extrasChanged=-not$extraStateCurrent
    if($extrasChanged){$extraManifest=@(Install-CocoStandaloneExperienceFiles $Experience $instanceRoot $CacheRoot $expectedExtrasArray $previousExtraManifest)}
    $stateObj=[ordered]@{
        schemaVersion=2
        experienceId=[string]$Experience.id
        sha256=$expectedSha
        size=$expectedSize
        version=[string]$Experience.pack.version
        role=$Role
        filesSha=$expectedExtrasSha
        extraFiles=@($extraManifest)
        installedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    Ensure-CocoOnlineFixSuppression $instanceRoot $Experience
    [IO.File]::WriteAllText($statePath,($stateObj|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    Write-CocoLog "Instalacion standalone de '$($Experience.id)' completada en '$instanceRoot'."
    return [pscustomobject]@{InstanceRoot=$instanceRoot;Updated=$true}
}

function Ensure-CocoOnlineFixSuppression([string]$InstanceRoot, $Experience){
    if([string]::IsNullOrWhiteSpace($InstanceRoot)-or-not(Test-Path -LiteralPath $InstanceRoot -PathType Container)){return}
    try{
        # 1. Eliminar cualquier acceso directo OnlineFix.url y mods BepInEx obsoletos
        Get-ChildItem -Path $InstanceRoot -Recurse -Filter 'OnlineFix.url' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        
        $expId = if($Experience){[string]$Experience.id}else{''}
        $appId = if($Experience-and$Experience.runtimePolicies){[string]$Experience.runtimePolicies.onlineFixAppId}else{''}
        $hasFiles = if($Experience-and$Experience.files){$Experience.files.Count -gt 0}else{$false}
        
        if($expId -eq 'peak' -and -not $hasFiles){
            $bepDir = Join-Path $InstanceRoot 'BepInEx'
            if(Test-Path -LiteralPath $bepDir){
                Remove-Item -LiteralPath $bepDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-CocoLog "Carpeta BepInEx obsoleta eliminada de '$InstanceRoot' para asegurar modo vanilla."
            }
            $doorstopCfg = Join-Path $InstanceRoot 'doorstop_config.ini'
            if(Test-Path -LiteralPath $doorstopCfg){
                Remove-Item -LiteralPath $doorstopCfg -Force -ErrorAction SilentlyContinue
            }
        }
        
        $hash0 = ''
        $hash1337 = ''
        $realAppId = ''
        $fakeAppId = '480'
        if($expId -eq 'peak' -or $appId -eq '3527290'){
            $realAppId = '3527290'
            $hash0 = 'a2a18f7cea500770e045b9ba73bbeb0536dec8922b2e659142f735e6a1b86f7757ac62c67ff201281c315f98b059e0070cba544408096e8c59778bf0aa2ac71a'
            $hash1337 = '6a0abff57ea8e4f9d65a9353e53406bcec81504ebfdea187d3f848d6de03530b3c2a61dafeea1cc228c5a5bc868cc098ddadaada657267d1a0010205e6cc3fb6'
        }elseif($expId -eq 'shift-at-midnight' -or $appId -eq '3722330'){
            $realAppId = '3722330'
            $hash0 = 'b4353c02359f2a29161f863d31d525227f958c269c51a920a5a6c14c37dbd0f0d9a0ede86cf0a35fa608ecccdfa1cbcc712d762d1cc62f3a64d74506c056a476'
            $hash1337 = '8f2db6b3b69a8abd76ac5aa9885d65ce44a423bd8d5632a1ba82e0a40019dc5ed5ca6f49e0f60ccf76902076b98fb4b09529d3b87b3aa4b859bfa3acc6d8e9bb'
        }elseif($expId -eq 'machine-party' -or $appId -eq '4108000'){
            $realAppId = '4108000'
            $hash0 = 'cb74c9a4f7c61735639239ffcb2cb8bc2f2b57d993fab02975edbb8588272d4aa0938c71c8eb3a63efe4078c7e284bfb503e5737d7fd5f7b919bf32f3100565c'
            $hash1337 = '0a77dde31976897b0f06f688ac3bf77271c84e48f1d944786134421039aec534f157422ff955db36798c2d6ced12523777b19ec6d611f6153db12faf8bc3673a'
        }elseif($expId -eq 'content-warning' -or $appId -eq '2881650'){
            $realAppId = '2881650'
            $hash0 = '57016c9e2f55a2e4f25ace876241ef2e0dd1019ac7eba8b95e86e7ed0929930bd5ada56589f64bbe6e5b0b2e621b3cebbedcf556e53a857f1b4b71dd0fe48fdc'
            $hash1337 = '9ca4f82237e56178f0cd917ddce7a94ceba67562393830c4cbd94067d3e2993e39fb69696fffdc05924d9b5dea02b19be48fd178486c9f08afa7da08ebdb27bc'
        }elseif($expId -eq 'scam-line' -or $appId -eq '2794590'){
            $realAppId = '2794590'
            $hash0 = 'ead2731f14749bb9cd96163c64b1dc7e53b54bee4859d309028a7fec9dbfb4e9d7663b8a12ebff95c95c2bfefa0f76549e7ab62e3c9b9901120641f2de6cfbb0'
            $hash1337 = '9774dfe661a728c4273738b90501fe2e1e5b7eaaa85483bc51611ff4451bf40a2161156bc6f3e30a4e402405c9940380cca7433379887b3cc3f4caae5558e7b9'
        }elseif($expId -eq 'lockdown-protocol' -or $appId -eq '2780980'){
            $realAppId = '2780980'
            $hash0 = '35863f50c0211bda0710caba012f6f8e12c5c60ef82858aa5b9701b926ddf466a97e8c8db9851fbcb73d1bfa0f8737025a695464c0cbc79018e1d0e974ffcd47'
            $hash1337 = '6290f76ea6dd1ff491826962246b27a0f95941c1d62069274aa067c4641a24f3b87597edbf57f2ac8f692c7563c9178ac888881b53870728901a832ae6ff82d9'
        }elseif($expId -eq 'big-walk' -or $appId -eq '1478500' -or $appId -eq '2670630'){
            $realAppId = '1478500'
            $hash0 = '6348b4cad0694d061f859f5b9f3fbb6cc90ac5113ebcc30c0f5078943334ae06a4866f97cc3e67ef543421b5f9523bfb3c90eafddf0627ad177ceabe8473c2da'
            $hash1337 = '3d20da45882aaf132163f28befa5b3a36522039776000a375947f30a885293d9e83cffc48624bc7f3c2636840153ad98a44fe2794064a2e4ee7ad325e8635ebb'
        }elseif($expId -eq 'cooking-simulator-2' -or $appId -eq '2455360'){
            $realAppId = '2455360'
            $hash0 = 'b827003fe85ecf063ff7b3f2da1646239e394da4e244f4ff42c93b3a8c4f18238dd98fb5a1080d6050ad1c0c653db9ce23eba5272cc62f426239d0954b589fad'
            $hash1337 = '0668f8b2eb4d826f4478152a3696647fc87cd6ff53df6c860cb626c917e1b2fe90e801355c055eef936b6a159a781926d7c147031668f8ef74273fefa3477263'
        }elseif($expId -eq 'repo' -or $appId -eq '3241660'){
            $realAppId = '3241660'
            $hash0 = '7daf7245f816aca908330f027527253c49244e8945ed89be097da9eb110e6c88da5331f2eddd307084af4a6c39f613e51d58541028f20ecf6ea3fd84f7cb0b5d'
            $hash1337 = '1c28dc43813c5af932d38b7b46cdd79dcb294c1afe05a984f18ca0bf1e1abf81f4a72886cc6e99e0319361680cc45936c5c19e32259c49058c0acf95fc40fb44'
        }elseif($expId -eq 'how-to-fish' -or $appId -eq '4001890'){
            $realAppId = '4001890'
            $hash0 = '58117ec53dd4075dec9b9d0c2e1cfd942c856c0d89c4a1491998eec52a4ca39619e3fecf0bd47fe3c1e389f3bca67dcc6f639704ecd040f66f8e812596acaf93'
            $hash1337 = 'b0418265dcf6d7ef61587b9e10fc7b3870ed81828c9639f085964144572770a1a33d8dd6c9951396003acbad154fdac6477603fa1dccbc716ea5df818405f206'
        }elseif($appId){
            $realAppId = $appId
            $hash0 = 'b4353c02359f2a29161f863d31d525227f958c269c51a920a5a6c14c37dbd0f0d9a0ede86cf0a35fa608ecccdfa1cbcc712d762d1cc62f3a64d74506c056a476'
            $hash1337 = '8f2db6b3b69a8abd76ac5aa9885d65ce44a423bd8d5632a1ba82e0a40019dc5ed5ca6f49e0f60ccf76902076b98fb4b09529d3b87b3aa4b859bfa3acc6d8e9bb'
        }
        $rootIni = Join-Path $InstanceRoot 'OnlineFix.ini'
        $rootIniNeedsWrite = $true
        if(Test-Path -LiteralPath $rootIni -PathType Leaf){
            try{
                $rootRaw = [IO.File]::ReadAllText($rootIni)
                if($rootRaw -match '(?i)RealAppId\s*=\s*\d+'){
                    $rootIniNeedsWrite = $false
                }
            }catch{$rootIniNeedsWrite = $true}
        }
        if($rootIniNeedsWrite -and $realAppId){
            $photon = if($expId -eq 'repo' -or $appId -eq '3241660'){'true'}else{'false'}
            $defaultIni = "[Main]`r`nRealAppId=$realAppId`r`nFakeAppId=$fakeAppId`r`n`r`n#Language=english`r`nBuildId=0`r`nInstallDir=`r`nUnlockAllDLC=false`r`n`r`n`r`n[Misc]`r`nExtraProtection=false`r`nPhotonIntegration=$photon`r`nEmulateTicket=false`r`n`r`n`r`n[Interfaces]`r`nApps=true`r`nUser=true`r`nUtils=true`r`nStorage=true`r`nUserStats=true`r`nFriends=true`r`nUGC=true`r`nInventory=true`r`nAppTicket=true`r`n`r`n`r`n[Hashes]`r`n0=$hash0`r`n1337=$hash1337`r`n"
            [IO.File]::WriteAllText($rootIni, $defaultIni, [System.Text.Encoding]::ASCII)
            Write-CocoLog "OnlineFix.ini restaurado y verificado en '$rootIni'"
        }
        
        # 3. Suprimir popup de creditos inyectando el hash exacto en OnlineFix.ini
        $onlineFixIniFiles = @(Get-ChildItem -Path $InstanceRoot -Recurse -Filter 'OnlineFix.ini' -ErrorAction SilentlyContinue)
        foreach($iniFile in $onlineFixIniFiles){
            try{
                $content = [IO.File]::ReadAllText($iniFile.FullName)
                $content = $content.TrimStart([char]0xFEFF, [char]0xEF, [char]0xBB, [char]0xBF)
                $targetHash0 = $hash0
                $targetHash1337 = $hash1337
                if($content -match '(?i)RealAppId\s*=\s*3527290'){
                    $targetHash0 = 'a2a18f7cea500770e045b9ba73bbeb0536dec8922b2e659142f735e6a1b86f7757ac62c67ff201281c315f98b059e0070cba544408096e8c59778bf0aa2ac71a'
                    $targetHash1337 = '6a0abff57ea8e4f9d65a9353e53406bcec81504ebfdea187d3f848d6de03530b3c2a61dafeea1cc228c5a5bc868cc098ddadaada657267d1a0010205e6cc3fb6'
                }elseif($content -match '(?i)RealAppId\s*=\s*3722330'){
                    $targetHash0 = 'b4353c02359f2a29161f863d31d525227f958c269c51a920a5a6c14c37dbd0f0d9a0ede86cf0a35fa608ecccdfa1cbcc712d762d1cc62f3a64d74506c056a476'
                    $targetHash1337 = '8f2db6b3b69a8abd76ac5aa9885d65ce44a423bd8d5632a1ba82e0a40019dc5ed5ca6f49e0f60ccf76902076b98fb4b09529d3b87b3aa4b859bfa3acc6d8e9bb'
                }elseif($content -match '(?i)RealAppId\s*=\s*4108000'){
                    $targetHash0 = 'cb74c9a4f7c61735639239ffcb2cb8bc2f2b57d993fab02975edbb8588272d4aa0938c71c8eb3a63efe4078c7e284bfb503e5737d7fd5f7b919bf32f3100565c'
                    $targetHash1337 = '0a77dde31976897b0f06f688ac3bf77271c84e48f1d944786134421039aec534f157422ff955db36798c2d6ced12523777b19ec6d611f6153db12faf8bc3673a'
                }elseif($content -match '(?i)RealAppId\s*=\s*2881650'){
                    $targetHash0 = '57016c9e2f55a2e4f25ace876241ef2e0dd1019ac7eba8b95e86e7ed0929930bd5ada56589f64bbe6e5b0b2e621b3cebbedcf556e53a857f1b4b71dd0fe48fdc'
                    $targetHash1337 = '9ca4f82237e56178f0cd917ddce7a94ceba67562393830c4cbd94067d3e2993e39fb69696fffdc05924d9b5dea02b19be48fd178486c9f08afa7da08ebdb27bc'
                }elseif($content -match '(?i)RealAppId\s*=\s*2794590'){
                    $targetHash0 = 'ead2731f14749bb9cd96163c64b1dc7e53b54bee4859d309028a7fec9dbfb4e9d7663b8a12ebff95c95c2bfefa0f76549e7ab62e3c9b9901120641f2de6cfbb0'
                    $targetHash1337 = '9774dfe661a728c4273738b90501fe2e1e5b7eaaa85483bc51611ff4451bf40a2161156bc6f3e30a4e402405c9940380cca7433379887b3cc3f4caae5558e7b9'
                }elseif($content -match '(?i)RealAppId\s*=\s*2780980'){
                    $targetHash0 = '35863f50c0211bda0710caba012f6f8e12c5c60ef82858aa5b9701b926ddf466a97e8c8db9851fbcb73d1bfa0f8737025a695464c0cbc79018e1d0e974ffcd47'
                    $targetHash1337 = '6290f76ea6dd1ff491826962246b27a0f95941c1d62069274aa067c4641a24f3b87597edbf57f2ac8f692c7563c9178ac888881b53870728901a832ae6ff82d9'
                }elseif($content -match '(?i)RealAppId\s*=\s*1478500' -or $content -match '(?i)RealAppId\s*=\s*2670630'){
                    $targetHash0 = '6348b4cad0694d061f859f5b9f3fbb6cc90ac5113ebcc30c0f5078943334ae06a4866f97cc3e67ef543421b5f9523bfb3c90eafddf0627ad177ceabe8473c2da'
                    $targetHash1337 = '3d20da45882aaf132163f28befa5b3a36522039776000a375947f30a885293d9e83cffc48624bc7f3c2636840153ad98a44fe2794064a2e4ee7ad325e8635ebb'
                }elseif($content -match '(?i)RealAppId\s*=\s*2455360'){
                    $targetHash0 = 'b827003fe85ecf063ff7b3f2da1646239e394da4e244f4ff42c93b3a8c4f18238dd98fb5a1080d6050ad1c0c653db9ce23eba5272cc62f426239d0954b589fad'
                    $targetHash1337 = '0668f8b2eb4d826f4478152a3696647fc87cd6ff53df6c860cb626c917e1b2fe90e801355c055eef936b6a159a781926d7c147031668f8ef74273fefa3477263'
                }elseif($content -match '(?i)RealAppId\s*=\s*3241660'){
                    $targetHash0 = '7daf7245f816aca908330f027527253c49244e8945ed89be097da9eb110e6c88da5331f2eddd307084af4a6c39f613e51d58541028f20ecf6ea3fd84f7cb0b5d'
                    $targetHash1337 = '1c28dc43813c5af932d38b7b46cdd79dcb294c1afe05a984f18ca0bf1e1abf81f4a72886cc6e99e0319361680cc45936c5c19e32259c49058c0acf95fc40fb44'
                }elseif($content -match '(?i)RealAppId\s*=\s*4001890'){
                    $targetHash0 = '58117ec53dd4075dec9b9d0c2e1cfd942c856c0d89c4a1491998eec52a4ca39619e3fecf0bd47fe3c1e389f3bca67dcc6f639704ecd040f66f8e812596acaf93'
                    $targetHash1337 = 'b0418265dcf6d7ef61587b9e10fc7b3870ed81828c9639f085964144572770a1a33d8dd6c9951396003acbad154fdac6477603fa1dccbc716ea5df818405f206'
                }elseif(-not $targetHash1337){
                    if($content -match '(?i)1337\s*=\s*([a-f0-9]{128})'){
                        $targetHash1337 = $matches[1]
                    }
                }
                if($targetHash1337){
                    if($content -match '\[Hashes\]'){
                        $content = [regex]::Replace($content, '(?s)\[Hashes\].*$', "[Hashes]`r`n0=$targetHash0`r`n1337=$targetHash1337`r`n")
                    }else{
                        $content = $content.TrimEnd() + "`r`n`r`n[Hashes]`r`n0=$targetHash0`r`n1337=$targetHash1337`r`n"
                    }
                    [IO.File]::WriteAllText($iniFile.FullName, $content, [System.Text.Encoding]::ASCII)
                }
            }catch{
                Write-CocoLog "No se pudo actualizar OnlineFix.ini en '$($iniFile.FullName)': $($_.Exception.Message)"
            }
        }
        
        # 4. Inicializar directorio publico de stats/logros
        $extractedAppIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if($appId){ [void]$extractedAppIds.Add($appId) }
        if($realAppId){ [void]$extractedAppIds.Add($realAppId) }
        foreach($iniFile in $onlineFixIniFiles){
            try{
                $iniTxt = [IO.File]::ReadAllText($iniFile.FullName)
                if($iniTxt -match '(?i)RealAppId\s*=\s*(\d+)'){
                    [void]$extractedAppIds.Add($matches[1])
                }
            }catch{}
        }
        foreach($currAppId in $extractedAppIds){
            try{
                $publicOf = Join-Path $env:PUBLIC 'Documents\OnlineFix'
                $onlineFixStats = Join-Path $publicOf "$currAppId\Stats"
                $onlineFixSaves = Join-Path $publicOf "$currAppId\Saves"
                if(-not(Test-Path -LiteralPath $onlineFixStats)){New-Item -ItemType Directory -Path $onlineFixStats -Force -ErrorAction SilentlyContinue | Out-Null}
                if(-not(Test-Path -LiteralPath $onlineFixSaves)){New-Item -ItemType Directory -Path $onlineFixSaves -Force -ErrorAction SilentlyContinue | Out-Null}
                $statsFile = Join-Path $onlineFixStats 'Stats.ini'
                if(-not(Test-Path -LiteralPath $statsFile)){[IO.File]::WriteAllText($statsFile, "[Stats]`r`nLoadedCosmeticsPreviously=1`r`n", [System.Text.Encoding]::ASCII)}
                $achFile = Join-Path $onlineFixStats 'Achievements.ini'
                if(-not(Test-Path -LiteralPath $achFile)){[IO.File]::WriteAllText($achFile, '', [System.Text.Encoding]::ASCII)}
            }catch{
                Write-CocoLog "No se pudo inicializar estado de OnlineFix en Public: $($_.Exception.Message)"
            }
        }
    }catch{
        Write-CocoLog "Error en Ensure-CocoOnlineFixSuppression: $($_.Exception.Message)"
    }
}

function Test-CocoStandaloneRequiredFile([string]$InstanceRoot,$RequiredFile){
    try{
        $relative=([string]$RequiredFile.path)-replace'/','\'
        $target=Join-Path $InstanceRoot $relative
        if(-not(Test-CocoPathWithin $target $InstanceRoot)-or-not(Test-Path -LiteralPath $target -PathType Leaf)){return $false}
        $item=Get-Item -LiteralPath $target -Force
        if($item.Length-ne[int64]$RequiredFile.size){return $false}
        return (Get-CocoFileSha256 $target)-eq([string]$RequiredFile.sha256).ToLowerInvariant()
    }catch{return $false}
}

function Get-CocoStandaloneRepairArchive($Experience,$ArchiveItem,[string]$CacheRoot){
    $archiveSha=([string]$ArchiveItem.sha256).ToLowerInvariant()
    $archiveSize=[int64]$ArchiveItem.size
    $downloadsDir=Join-Path $CacheRoot 'downloads\standalone-packs'
    New-Item -ItemType Directory -Path $downloadsDir -Force|Out-Null
    $archive=Join-Path $downloadsDir "$archiveSha.zip"
    if(Test-Path -LiteralPath $archive -PathType Leaf){
        $cached=Get-Item -LiteralPath $archive -Force
        if($cached.Length-eq$archiveSize-and(Get-CocoFileSha256 $archive)-eq$archiveSha){return $archive}
        Remove-Item -LiteralPath $archive -Force
    }

    $source=[string]$ArchiveItem.archiveUrl
    if([string]::IsNullOrWhiteSpace($source)-and$ArchiveItem.manifestUrl){$source=[string]$ArchiveItem.manifestUrl}
    if([string]::IsNullOrWhiteSpace($source)){throw "El archivo base de '$($Experience.name)' no declara un origen de reparacion."}
    $partial="$archive.repair.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    try{
        Write-CocoLog "Recuperando archivo base desde el paquete fijado $archiveSha..."
        if(Test-Path -LiteralPath $source -PathType Leaf){
            Copy-Item -LiteralPath $source -Destination $partial -Force
        }elseif(Get-Command curl.exe -ErrorAction SilentlyContinue){
            $download=Start-Process -FilePath 'curl.exe' -ArgumentList @('-L','--fail','--retry','3','--silent','--show-error','-o',$partial,$source) -NoNewWindow -Wait -PassThru
            if($download.ExitCode-ne0){throw "curl.exe devolvio codigo $($download.ExitCode)."}
        }else{
            $client=New-Object Net.WebClient
            try{$client.DownloadFile([Uri]$source,$partial)}finally{$client.Dispose()}
        }
        if(-not(Test-Path -LiteralPath $partial -PathType Leaf)-or(Get-Item -LiteralPath $partial -Force).Length-ne$archiveSize){
            throw 'El paquete de reparacion no tiene el tamano esperado.'
        }
        $actual=Get-CocoFileSha256 $partial
        if($actual-ne$archiveSha){throw "El paquete de reparacion no coincide con su SHA-256 fijado (obtenido $actual)."}
        Move-Item -LiteralPath $partial -Destination $archive -Force
        return $archive
    }finally{
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
}

function Repair-CocoStandaloneRequiredFiles($Experience,[string]$InstanceRoot,[string]$CacheRoot){
    $required=@($Experience.runtime.requiredFiles)
    if(-not$required.Count){return @()}
    $invalid=@($required|Where-Object{-not(Test-CocoStandaloneRequiredFile $InstanceRoot $_)})
    if(-not$invalid.Count){return @($required|ForEach-Object{[pscustomobject]@{path=[string]$_.path;status='ok'}})}

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archives=@(if($Experience.pack.archives){$Experience.pack.archives}else{$Experience.pack})
    foreach($group in @($invalid|Group-Object{([string]$_.archiveSha256).ToLowerInvariant()})){
        $archiveItem=@($archives|Where-Object{([string]$_.sha256).ToLowerInvariant()-eq[string]$group.Name})
        if($archiveItem.Count-ne1){throw "No existe un paquete unico para reparar '$($group.Name)'."}
        $archive=Get-CocoStandaloneRepairArchive $Experience $archiveItem[0] $CacheRoot
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try{
            foreach($requiredFile in @($group.Group)){
                $entryName=([string]$requiredFile.path)-replace'\\','/'
                $entries=@($zip.Entries|Where-Object{[string]::Equals(($_.FullName-replace'\\','/'),$entryName,[StringComparison]::OrdinalIgnoreCase)})
                if($entries.Count-ne1-or$entries[0].FullName.EndsWith('/')){throw "El paquete fijado no contiene exactamente '$entryName'."}
                $target=Join-Path $InstanceRoot ($entryName-replace'/','\')
                if(-not(Test-CocoPathWithin $target $InstanceRoot)){throw "La reparacion intento escapar de la instancia: '$entryName'."}
                $staging="$target.coco-repair-$([guid]::NewGuid().ToString('N'))"
                $backup="$target.coco-repair-backup-$([guid]::NewGuid().ToString('N'))"
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null
                try{
                    $stagingItem = $null
                    $stagingHash = $null
                    $extracted = $false
                    for($extractAttempt = 1; $extractAttempt -le 2; $extractAttempt++){
                        try{
                            if(Test-Path -LiteralPath $staging){ Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
                            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],$staging,$true)
                            $stagingItem = Get-Item -LiteralPath $staging -Force
                            $stagingHash = (Get-CocoFileSha256 $staging)
                            $extracted = $true
                            break
                        }catch{
                            if($extractAttempt -eq 1 -and $_.Exception.Message -match '(?i)virus|potencialmente no deseado|operation did not complete|blocked|denied|acceso denegado'){
                                Write-CocoLog "Windows Defender o permisos bloquearon '$staging'. Intentando aplicar exclusion de emergencia..."
                                [void](Ensure-CocoDefenderExclusion $Experience $InstanceRoot)
                                Start-Sleep -Milliseconds 600
                            }else{
                                throw "Windows Defender o el sistema bloqueo la biblioteca '$entryName' en '$InstanceRoot': $($_.Exception.Message)"
                            }
                        }
                    }
                    if(-not$extracted -or -not$stagingItem){
                        throw "No se pudo extraer '$entryName' en '$InstanceRoot'."
                    }
                    if($stagingItem.Length-ne[int64]$requiredFile.size-or $stagingHash-ne([string]$requiredFile.sha256).ToLowerInvariant()){
                        throw "El archivo extraido '$entryName' no coincide con su contrato."
                    }
                    if(Test-Path -LiteralPath $target -PathType Leaf){Move-Item -LiteralPath $target -Destination $backup -Force}
                    Move-Item -LiteralPath $staging -Destination $target -Force
                    if(-not(Test-CocoStandaloneRequiredFile $InstanceRoot $requiredFile)){throw "La reparacion final de '$entryName' no se pudo verificar."}
                    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                    Write-CocoLog "Archivo base standalone reparado y verificado: $entryName"
                }catch{
                    Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
                    if(Test-Path -LiteralPath $backup -PathType Leaf){
                        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                        Move-Item -LiteralPath $backup -Destination $target -Force
                    }
                    throw
                }finally{Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}
            }
        }finally{$zip.Dispose()}
    }
    $remaining=@($required|Where-Object{-not(Test-CocoStandaloneRequiredFile $InstanceRoot $_)})
    if($remaining.Count){throw "La instalacion de '$($Experience.name)' conserva archivos base ausentes o corruptos: $((@($remaining.path)-join', '))."}
    return @($required|ForEach-Object{[pscustomobject]@{path=[string]$_.path;status='ok'}})
}

function Ensure-CocoDefenderExclusion($Experience,[string]$InstanceRoot){
    if([string]$Experience.runtimePolicies.defenderExclusion-notin@('required','optional')){return 'not-required'}
    $full=[IO.Path]::GetFullPath($InstanceRoot).TrimEnd('\')
    $getPreference=Get-Command Get-MpPreference -ErrorAction SilentlyContinue
    $addPreference=Get-Command Add-MpPreference -ErrorAction SilentlyContinue
    if(-not$getPreference-or-not$addPreference){Write-CocoLog 'Windows Defender no expone cmdlets de exclusion en este equipo.';return 'unavailable'}
    $isPresent={
        try{
            $exclusions=@((Get-MpPreference -ErrorAction Stop).ExclusionPath|Where-Object{[string]$_}|ForEach-Object{[IO.Path]::GetFullPath([string]$_).TrimEnd('\')})
            foreach($ex in $exclusions){
                if($full.Equals($ex,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($ex + '\',[StringComparison]::OrdinalIgnoreCase)){
                    return $true
                }
            }
            return $false
        }catch{return $false}
    }
    if(& $isPresent){return 'present'}

    $parent=Split-Path $full -Parent
    $pathsToAdd=[Collections.Generic.List[string]]::new()
    [void]$pathsToAdd.Add($full)
    if($parent -and (Split-Path $full -Leaf) -ne 'CocoMinecraft'){
        [void]$pathsToAdd.Add($parent)
    }
    $appDataCoco=[IO.Path]::GetFullPath((Join-Path $env:APPDATA 'CocoMinecraft')).TrimEnd('\')
    $localCoco=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater')).TrimEnd('\')
    [void]$pathsToAdd.Add($appDataCoco)
    [void]$pathsToAdd.Add($localCoco)

    # Incluir todas las ubicaciones personalizadas previas que el usuario o sus amigos hayan configurado
    $locationsFile=if($StorePath){$StorePath}else{
        $localAppData=[Environment]::GetFolderPath('LocalApplicationData')
        if(-not$localAppData){$localAppData=$env:LOCALAPPDATA}
        Join-Path $localAppData 'CocoMinecraftUpdater\instance-locations.json'
    }
    if(Test-Path -LiteralPath $locationsFile -PathType Leaf){
        try{
            $locContent=Get-Content -LiteralPath $locationsFile -Raw -ErrorAction SilentlyContinue
            if($locContent){
                $locObj=$locContent|ConvertFrom-Json
                if($locObj){
                    foreach($prop in $locObj.PSObject.Properties){
                        $val=[string]$prop.Value
                        if(-not[string]::IsNullOrWhiteSpace($val)){
                            $cFull=[IO.Path]::GetFullPath($val).TrimEnd('\')
                            [void]$pathsToAdd.Add($cFull)
                            $cParent=Split-Path $cFull -Parent
                            if($cParent -and (Split-Path $cFull -Leaf) -ne 'CocoMinecraft'){
                                [void]$pathsToAdd.Add($cParent)
                            }
                        }
                    }
                }
            }
        }catch{}
    }
    $uniquePaths=@($pathsToAdd|Select-Object -Unique)

    try{
        foreach($p in $uniquePaths){Add-MpPreference -ExclusionPath $p -ErrorAction Stop}
    }catch{
        try{
            if(Get-Command Set-CocoLauncherStep -ErrorAction SilentlyContinue){
                Set-CocoLauncherStep 4 'AUTORIZACIÓN DE WINDOWS' 'Pulsa "Sí" en la confirmación de Windows para autorizar la protección de carpetas...' 50
            }elseif(Get-Command Set-CocoState -ErrorAction SilentlyContinue){
                Set-CocoState 'AUTORIZACIÓN DE WINDOWS' 'Pulsa "Sí" en la confirmación de Windows para autorizar la protección de carpetas...' 50
            }
            if($script:CocoForm -and -not$script:CocoForm.IsDisposed){
                $script:CocoForm.TopMost=$false
                [Windows.Forms.Application]::DoEvents()
            }
        }catch{}

        try{
            $cmdParts=@($uniquePaths|ForEach-Object{"Add-MpPreference -ExclusionPath '$($_.Replace('''',''''''))' -ErrorAction SilentlyContinue"})
            $command=$cmdParts -join ';'
            $elevated=Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$command) -WindowStyle Hidden -PassThru -ErrorAction Stop
            if($elevated){
                try{
                    $deadline=[DateTime]::UtcNow.AddSeconds(45)
                    while(-not$elevated.HasExited -and [DateTime]::UtcNow -lt $deadline){
                        if('System.Windows.Forms.Application'-as[type]){[Windows.Forms.Application]::DoEvents()}
                        Start-Sleep -Milliseconds 100
                    }
                    if(-not$elevated.HasExited){
                        try{$elevated.Kill()}catch{}
                        Write-CocoLog 'El proceso de exclusion de Defender tardo mas de 45s; continuando sin bloquear.'
                    }elseif($elevated.ExitCode-ne0){
                        Write-CocoLog "El proceso de exclusion devolvio codigo $($elevated.ExitCode)."
                    }
                }finally{
                    $elevated.Dispose()
                }
            }
        }catch{
            Write-CocoLog "No se pudo elevar para agregar exclusion de Defender o el usuario cancelo la operacion: $($_.Exception.Message)"
        }
    }
    if(& $isPresent){
        Write-CocoLog "Exclusion de Windows Defender confirmada para '$full'."
        try{
            if(Get-Command Set-CocoLauncherStep -ErrorAction SilentlyContinue){
                Set-CocoLauncherStep 4 'PROTECCIÓN ACTIVADA' 'Carpetas de juego protegidas en Windows Defender.' 52
            }
        }catch{}
        return 'present'
    }
    try{
        if(Get-Command Set-CocoLauncherStep -ErrorAction SilentlyContinue){
            Set-CocoLauncherStep 4 'PREPARANDO JUEGO' 'Continuando preparacion de la experiencia...' 52
        }
    }catch{}
    Write-CocoLog "Exclusion de Defender no activa para '$full'; continuando lanzamiento..."
    return 'skipped'
}

function Install-CocoManagedExperience(
    $Experience,
    $Lock,
    [string]$ExperiencesRoot,
    [string]$CacheRoot,
    [ValidateSet('client','host')][string]$Role='client',
    $GlobalPolicies,
    [string]$InstanceLocationsPath=''
){
    $instanceRoot=Get-CocoExperienceInstanceRoot $Experience $ExperiencesRoot $InstanceLocationsPath
    $fullInstance=[IO.Path]::GetFullPath($instanceRoot)
    $rootPath=[IO.Path]::GetPathRoot($fullInstance)
    if($fullInstance.TrimEnd('\')-eq$rootPath.TrimEnd('\')){throw 'No se puede instalar en un directorio raiz del sistema.'}
    if(-not(Test-CocoPathWithin $instanceRoot $ExperiencesRoot)){
        $locations=Get-CocoInstanceCustomLocations $InstanceLocationsPath
        $isCustom=$false
        if($locations){
            foreach($prop in $locations.PSObject.Properties){
                if([string]$prop.Value-and[IO.Path]::GetFullPath([string]$prop.Value).Equals($fullInstance,[StringComparison]::OrdinalIgnoreCase)){
                    $isCustom=$true;break
                }
            }
        }
        if(-not$isCustom){throw 'La raiz de instancia escapa del directorio de experiencias.'}
    }
    if(Test-CocoManagedGameRunning $instanceRoot){throw "La instancia '$($Experience.name)' ya esta abierta. Cierrala antes de verificar sus archivos."}
    [void](Remove-CocoStaleExperienceStages $instanceRoot)
    if([int64]$Experience.launch.minimumFreeBytes-gt0){
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($instanceRoot)))
        if($drive.AvailableFreeSpace-lt[int64]$Experience.launch.minimumFreeBytes){
            throw ("No hay espacio suficiente para {0}. Libera al menos {1:N1} GB en {2}."-f$Experience.name,([int64]$Experience.launch.minimumFreeBytes/1GB),$drive.Name)
        }
    }
    $stage="$instanceRoot.coco-stage-$([guid]::NewGuid().ToString('N'))"
    $stageFiles=Join-Path $stage 'files';New-Item -ItemType Directory -Path $stageFiles -Force|Out-Null
    $desired=[Collections.Generic.List[object]]::new()
    $desiredPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $excludedPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($excludedPath in @($Experience.pack.excludedPaths)){
        if([string]::IsNullOrWhiteSpace([string]$excludedPath)){continue}
        $normalizedExcludedPath=([string]$excludedPath)-replace'\\','/'
        [void]$excludedPaths.Add($normalizedExcludedPath)
    }
    try{
        # Contrato reutilizable para cualquier experiencia: el lock fija todos
        # los bytes y el rol decide el subconjunto. Cualquier exclusion debe
        # declararse en excludedPaths dentro de la entrada de esa experiencia.
        $globalAssets=@(Get-CocoCustomSkinLoaderVariant $GlobalPolicies $Experience)
        $rawRoleAssets=@(@($Lock.assets)+@($Experience.files)+$globalAssets|Where-Object{
            (-not$_.role-or$_.role-in@('all',$Role))-and
            -not$excludedPaths.Contains(([string]$_.path-replace'\\','/'))-and
            ([string]$_.path-notmatch'(?i)^(mods/(?!ftb-).*essential.*\.jar|essential/.*)$')
        })
        $roleAssets=[Collections.Generic.List[object]]::new()
        $seenRolePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($asset in $rawRoleAssets){
            $normPath=([string]$asset.path)-replace'\\','/'
            if($asset-and$normPath-and$seenRolePaths.Add($normPath)){[void]$roleAssets.Add($asset)}
        }
        $downloadAssets=@()
        if($Lock.pack.archive){$downloadAssets=@($Lock.pack.archive)}
        $downloadAssets+=@($roleAssets)
        $totalBytes=[int64](@($downloadAssets|Measure-Object -Property size -Sum).Sum)
        $experienceLabel=if(-not[string]::IsNullOrWhiteSpace([string]$Experience.name)){[string]$Experience.name}else{[string]$Experience.id}
        $progress=@{Index=0;Count=$downloadAssets.Count;CompletedBytes=[int64]0;TotalBytes=$totalBytes;ProgressStart=30;ProgressEnd=68;Step=4;Title="DESCARGANDO $($experienceLabel.ToUpperInvariant())"}
        if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{role=$Role;experienceId=[string]$Experience.id;packVersion=[string]$Experience.pack.version;instanceRoot=$instanceRoot}}
        Set-CocoLauncherStep 4 'VERIFICANDO ARCHIVOS DEL PACK' ("{0} archivos fijados | {1:N1} MB totales | rol {2}"-f$downloadAssets.Count,($totalBytes/1MB),$Role) 30
        [void](Get-CocoLockedAssetsParallel $CacheRoot $downloadAssets $progress)
        if($Lock.pack.archive){
            $packArchive=Get-CocoLockedAsset $CacheRoot $Lock.pack.archive $null
            Expand-CocoCurseForgeOverrides $packArchive ([string]$Lock.pack.overridesRoot) $stageFiles
        }
        foreach($file in @(Get-ChildItem -LiteralPath $stageFiles -Recurse -File)){
            $relative=($file.FullName.Substring($stageFiles.Length).TrimStart('\','/'))-replace'\\','/'
            if($excludedPaths.Contains($relative)-or$relative-match'(?i)^(mods/(?!ftb-).*essential.*\.jar|essential/.*)$'){
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
            $policy=if($relative-eq'options.txt'){'preserve'}else{'replace'}
            $desired.Add([pscustomobject]@{path=$relative;sha256=(Get-CocoFileSha256 $file.FullName);size=[int64]$file.Length;policy=$policy})
            [void]$desiredPaths.Add($relative)
        }
        [void](Get-CocoLockedAssetsParallel $CacheRoot $roleAssets $null)
        foreach($asset in $roleAssets){
            $relative=[string]$asset.path
            if(-not(Test-CocoSafeRelativePath $relative)-or-not$desiredPaths.Add($relative)){throw "Ruta administrada duplicada o insegura: '$relative'."}
            $cached=Get-CocoLockedAsset $CacheRoot $asset $null
            $staged=Join-Path $stageFiles ($relative-replace'/','\');$parent=Split-Path $staged -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
            Copy-Item -LiteralPath $cached -Destination $staged
            $desired.Add([pscustomobject]@{path=$relative;sha256=([string]$asset.sha256).ToLowerInvariant();size=[int64]$asset.size;policy=if($asset.policy){[string]$asset.policy}else{'replace'}})
        }

        $statePath=Join-Path $instanceRoot '.coco\managed-state.json'
        $previous=if(Test-Path -LiteralPath $statePath){try{@((Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json).files)}catch{@()}}else{@()}
        $backupRoot=Join-Path $CacheRoot ("backups\experiences\$($Experience.id)\"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
        $failedRoot=Join-Path $backupRoot 'failed-new-files'
        $journal=[Collections.Generic.List[object]]::new()
        New-Item -ItemType Directory -Path $instanceRoot -Force|Out-Null
        try{
            $removedCandidates=@($previous|Where-Object{(Test-CocoSafeRelativePath ([string]$_.path))-and-not$desiredPaths.Contains([string]$_.path)})
            $installTotal=[Math]::Max(1,$removedCandidates.Count+$desired.Count)
            $installIndex=0
            Set-CocoLauncherStep 5 'INSTALANDO LA INSTANCIA AISLADA' ("0/{0} archivos | mundos y datos de jugador quedan fuera del area administrada"-f$installTotal) 69
            foreach($old in $previous){
                $relative=[string]$old.path
                if(-not(Test-CocoSafeRelativePath $relative)-or$desiredPaths.Contains($relative)){continue}
                $installIndex++
                $destination=Join-Path $instanceRoot ($relative-replace'/','\')
                if(Test-Path -LiteralPath $destination -PathType Leaf){
                    $backup=Join-Path $backupRoot ($relative-replace'/','\');New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force|Out-Null
                    Move-Item -LiteralPath $destination -Destination $backup
                    $journal.Add([pscustomobject]@{Destination=$destination;Backup=$backup;NewInstalled=$false})
                }
                if($installIndex%10-eq0-or$installIndex-eq$installTotal){Set-CocoLauncherStep 5 'INSTALANDO LA INSTANCIA AISLADA' ("{0}/{1} | retirando archivo administrado anterior: {2}"-f$installIndex,$installTotal,$relative) (69+[int](9*$installIndex/$installTotal))}
            }
            foreach($file in $desired){
                $installIndex++
                $relative=[string]$file.path;$destination=Join-Path $instanceRoot ($relative-replace'/','\');$staged=Join-Path $stageFiles ($relative-replace'/','\')
                $outcome='instalado'
                if($file.policy-eq'preserve'-and(Test-Path -LiteralPath $destination -PathType Leaf)){
                    $outcome='preservado'
                    if($installIndex%10-eq0-or$installIndex-eq$installTotal){Set-CocoLauncherStep 5 'INSTALANDO LA INSTANCIA AISLADA' ("{0}/{1} | {2}: {3}"-f$installIndex,$installTotal,$outcome,$relative) (69+[int](9*$installIndex/$installTotal))}
                    continue
                }
                if((Test-Path -LiteralPath $destination -PathType Leaf)-and(Get-Item -LiteralPath $destination -Force).Length-eq[int64]$file.size-and(Get-CocoFileSha256 $destination)-eq[string]$file.sha256){
                    $outcome='ya verificado'
                    if($installIndex%10-eq0-or$installIndex-eq$installTotal){Set-CocoLauncherStep 5 'INSTALANDO LA INSTANCIA AISLADA' ("{0}/{1} | {2}: {3}"-f$installIndex,$installTotal,$outcome,$relative) (69+[int](9*$installIndex/$installTotal))}
                    continue
                }
                $backup=$null
                if(Test-Path -LiteralPath $destination -PathType Leaf){$backup=Join-Path $backupRoot ($relative-replace'/','\');New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force|Out-Null;Move-Item -LiteralPath $destination -Destination $backup}
                New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
                Move-Item -LiteralPath $staged -Destination $destination
                $journal.Add([pscustomobject]@{Destination=$destination;Backup=$backup;NewInstalled=$true})
                if($installIndex%10-eq0-or$installIndex-eq$installTotal){Set-CocoLauncherStep 5 'INSTALANDO LA INSTANCIA AISLADA' ("{0}/{1} | {2}: {3}"-f$installIndex,$installTotal,$outcome,$relative) (69+[int](9*$installIndex/$installTotal))}
            }
            $stateParent=Split-Path $statePath -Parent;New-Item -ItemType Directory -Path $stateParent -Force|Out-Null
            $state=[ordered]@{schemaVersion=1;experienceId=[string]$Experience.id;packVersion=[string]$Experience.pack.version;installedAtUtc=[DateTime]::UtcNow.ToString('o');files=@($desired)}
            $temporary="$statePath.new-$PID";[IO.File]::WriteAllText($temporary,($state|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($false)));Move-Item -LiteralPath $temporary -Destination $statePath -Force
            # El backup existe sólo durante la transacción para permitir rollback.
            # Al confirmar el nuevo estado se elimina: las experiencias conservan
            # una sola instalación y no acumulan copias históricas.
            if(Test-Path -LiteralPath $backupRoot -PathType Container){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
            Set-CocoLauncherStep 5 'INSTANCIA VERIFICADA' ("{0} archivos administrados | version {1}"-f$desired.Count,$Experience.pack.version) 78
        }catch{
            $originalError=$_
            if(Get-Command Write-CocoTimelineEvent -ErrorAction SilentlyContinue){Write-CocoTimelineEvent 'ROLLBACK DE INSTANCIA' 'Restaurando automaticamente los archivos anteriores.' $script:CocoCurrentProgress 'rollback'}
            $rollbackEntries=@($journal.ToArray())
            [array]::Reverse($rollbackEntries)
            $rollbackFailure=$null
            try{
                foreach($entry in $rollbackEntries){
                    if($entry.NewInstalled-and(Test-Path -LiteralPath $entry.Destination -PathType Leaf)){$failed=Join-Path $failedRoot ([IO.Path]::GetFileName($entry.Destination));New-Item -ItemType Directory -Path (Split-Path $failed -Parent) -Force|Out-Null;Move-Item -LiteralPath $entry.Destination -Destination $failed -Force -ErrorAction SilentlyContinue}
                    if($entry.Backup-and(Test-Path -LiteralPath $entry.Backup -PathType Leaf)){New-Item -ItemType Directory -Path (Split-Path $entry.Destination -Parent) -Force|Out-Null;Move-Item -LiteralPath $entry.Backup -Destination $entry.Destination -Force}
                }
            }catch{$rollbackFailure=$_}
            if(-not$rollbackFailure-and(Test-Path -LiteralPath $backupRoot -PathType Container)){
                Remove-Item -LiteralPath $backupRoot -Recurse -Force
            }
            if($rollbackFailure){throw "Fallo original: $($originalError.Exception.Message) | Rollback incompleto: $($rollbackFailure.Exception.Message) | Respaldo: $backupRoot"}
            throw $originalError
        }
        [pscustomobject]@{InstanceRoot=$instanceRoot;StatePath=$statePath;Files=$desired.Count;BackupRoot=''}
    }finally{if((Test-Path -LiteralPath $stage)-and(Test-CocoExperienceStagePath $stage $instanceRoot)){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}}
}

function Set-CocoManagedRuntimePolicies($Experience,[string]$InstanceRoot){
    if(-not$Experience.runtimePolicies-or[string]$Experience.runtimePolicies.essentialLoaderUpdates-ne'disabled'){return $false}
    if([string]::IsNullOrWhiteSpace($InstanceRoot)-or-not[IO.Path]::IsPathRooted($InstanceRoot)){throw 'La raiz de politicas administradas no es valida.'}
    $essentialRoot=Join-Path $InstanceRoot 'essential'
    $paths=[Collections.Generic.List[string]]::new()
    $paths.Add((Join-Path $essentialRoot 'essential-loader.properties'))
    $stage1Root=Join-Path $essentialRoot 'loader\stage1'
    if(Test-Path -LiteralPath $stage1Root -PathType Container){
        foreach($file in Get-ChildItem -LiteralPath $stage1Root -Recurse -File -Filter '*.properties'){
            if($file.Name-like'stage2*.properties'){$paths.Add($file.FullName)}
        }
    }
    $changed=$false
    foreach($path in $paths){
        if(-not(Test-CocoPathWithin $path $essentialRoot)){throw 'Una politica Essential intento escapar de la instancia.'}
        $parent=Split-Path $path -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
        $kept=[Collections.Generic.List[string]]::new()
        if(Test-Path -LiteralPath $path -PathType Leaf){
            foreach($line in Get-Content -LiteralPath $path){
                if($line-notmatch'^\uFEFF?\s*(autoUpdate|pendingUpdateVersion|pendingUpdateResolution)\s*[:=]'-and$line-ne'# Administrado por Coco Launcher: el pack fija su version de Essential.'){$kept.Add([string]$line)}
            }
        }
        while($kept.Count-and[string]::IsNullOrWhiteSpace($kept[$kept.Count-1])){$kept.RemoveAt($kept.Count-1)}
        $kept.Add('# Administrado por Coco Launcher: el pack fija su version de Essential.')
        $kept.Add('autoUpdate=false')
        $content=($kept.ToArray()-join"`r`n")+"`r`n"
        $current=if(Test-Path -LiteralPath $path -PathType Leaf){Get-Content -LiteralPath $path -Raw}else{''}
        if($current-eq$content){continue}
        $temporary="$path.new-$PID"
        [IO.File]::WriteAllText($temporary,$content,(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $path -Force
        $changed=$true
    }
    return $changed
}

<#
Implementación histórica de preferencias anterior al catálogo declarativo.
Se conserva temporalmente como referencia de migración, pero no se compila.
function Set-CocoManagedInstancePreferencesLegacy($Experience, [string]$InstanceRoot){
    if([string]::IsNullOrWhiteSpace($InstanceRoot) -or -not (Test-Path -LiteralPath $InstanceRoot)){return}
    
    # 1. Force standard vanilla Minecraft controls (Sprint = Left Control, Sneak/Crouch = Left Shift) and FOV 95 by default
    foreach($optsFile in @((Join-Path $InstanceRoot 'options.txt'), (Join-Path $InstanceRoot 'config\defaultoptions\options.txt'), (Join-Path $InstanceRoot 'config\defaultoptions\keybindings.txt'))){
        if(Test-Path -LiteralPath $optsFile -PathType Leaf){
            $content = Get-Content -LiteralPath $optsFile -Raw
            $content = $content -replace '(?m)^key_key\.sprint:.*$', 'key_key.sprint:key.keyboard.left.control'
            $content = $content -replace '(?m)^key_key\.sneak:.*$', 'key_key.sneak:key.keyboard.left.shift'
            if($content -match '(?m)^fov:'){
                $content = $content -replace '(?m)^fov:.*$', 'fov:0.625'
            }else{
                $content = $content + "`r`nfov:0.625"
            }
            [IO.File]::WriteAllText($optsFile, $content, (New-Object Text.UTF8Encoding($false)))
        }
    }
    
    # 2. Force Potato / Lightweight Shaderpack by default if Oculus/Iris or OptiFine is present
    $oculusPath = Join-Path $InstanceRoot 'config\oculus.properties'
    $potatoShaderName = 'DREAD REBORN SHADERS - 6 - Potato.zip'
    $shaderPackPath = Join-Path $InstanceRoot "shaderpacks\$potatoShaderName"
    if(Test-Path -LiteralPath $shaderPackPath -PathType Leaf){
        $oculusParent = Split-Path $oculusPath -Parent
        if(-not (Test-Path -LiteralPath $oculusParent)){ New-Item -ItemType Directory -Path $oculusParent -Force | Out-Null }
        $oculusText = "colorSpace=SRGB`r`ndisableUpdateMessage=false`r`nenableDebugOptions=false`r`nmaxShadowRenderDistance=4`r`nshaderPack=$potatoShaderName`r`nenableShaders=true`r`n"
        [IO.File]::WriteAllText($oculusPath, $oculusText, (New-Object Text.UTF8Encoding($false)))
    }
    $makeupShaderName = 'MakeUp-UltraFast-9.5c.zip'
    if(Test-Path -LiteralPath (Join-Path $InstanceRoot "shaderpacks\$makeupShaderName") -PathType Leaf){
        $optsShadersPath = Join-Path $InstanceRoot 'optionsshaders.txt'
        [IO.File]::WriteAllText($optsShadersPath, "shaderPack=$makeupShaderName`r`n", (New-Object Text.UTF8Encoding($false)))
        
        $makeupTxtPath = Join-Path $InstanceRoot "shaderpacks\MakeUp-UltraFast-9.5c.zip.txt"
        $makeupTxt = "EMISSIVE_TEXTURES=true`r`nEMISSIVE_REC=1`r`nEMISSIVE_SPEC=1`r`nDYNAMIC_LIGHTS=true`r`n"
        [IO.File]::WriteAllText($makeupTxtPath, $makeupTxt, (New-Object Text.UTF8Encoding($false)))
        
        $bslTxtPath = Join-Path $InstanceRoot "shaderpacks\BSL_v10.1.3.zip.txt"
        $bslTxt = "EMISSIVE_TEXTURES=true`r`nDESATURATION=true`r`n"
        [IO.File]::WriteAllText($bslTxtPath, $bslTxt, (New-Object Text.UTF8Encoding($false)))
    }

    # 3. Force Proximity Voice Chat (Simple Voice Chat & Plasmo Voice) defaults + bypass wizard
    $voiceDir = Join-Path $InstanceRoot 'config\voicechat'
    if(-not (Test-Path -LiteralPath $voiceDir)){ New-Item -ItemType Directory -Path $voiceDir -Force | Out-Null }
    $voicePropsPath = Join-Path $voiceDir 'voicechat-client.properties'
    if(-not (Test-Path -LiteralPath $voicePropsPath -PathType Leaf)){
        $voiceProps = "recording_device=`r`nspeaker_device=`r`nvoice_activation_type=VOICE`r`nvoice_activation_threshold=-50.0`r`nnoise_suppression=true`r`ndenoiser=RNNNOISE`r`nmicrophone_amplification=1.0`r`nonboarding_finished=true
show_wizard=false`r`nwizard_completed=true`r`ncompleted_wizard=true`r`n"
        [IO.File]::WriteAllText($voicePropsPath, $voiceProps, (New-Object Text.UTF8Encoding($false)))
    }
    
    $plasmoDir = Join-Path $InstanceRoot 'config\plasmo_voice'
    if(-not (Test-Path -LiteralPath $plasmoDir)){ New-Item -ItemType Directory -Path $plasmoDir -Force | Out-Null }
    $plasmoPath = Join-Path $plasmoDir 'client.toml'
    if(-not (Test-Path -LiteralPath $plasmoPath -PathType Leaf)){
        $plasmoToml = "[general]`r`nshow_wizard = false`r`nwizard_completed = true`r`n`r`n[audio]`r`ninput_device = """"`r`noutput_device = """"`r`nactivation_type = ""VOICE""`r`nnoise_suppression = true`r`nauto_gain_control = true`r`n"
        [IO.File]::WriteAllText($plasmoPath, $plasmoToml, (New-Object Text.UTF8Encoding($false)))
    }

    # 4. Historical custom skin import was removed. Skins now come only from
    # the engine registry and the user-selected profile under LocalAppData.
    if(Test-Path -LiteralPath $sourceSkin -PathType Leaf){
        $cslDir = Join-Path $InstanceRoot 'CustomSkinLoader'
        $cslSkinsDir = Join-Path $cslDir 'skins'
        if(-not (Test-Path -LiteralPath $cslSkinsDir)){ New-Item -ItemType Directory -Path $cslSkinsDir -Force | Out-Null }
        Copy-Item -LiteralPath $sourceSkin -Destination (Join-Path $cslSkinsDir 'smolbird.png') -Force
        
        $extraListJson = "{" + "`r`n" +
                         '  "enable": true,' + "`r`n" +
                         '  "extra": [' + "`r`n" +
                         '    {' + "`r`n" +
                         '      "name": "smolbird",' + "`r`n" +
                         '      "skin": "CustomSkinLoader/skins/smolbird.png",' + "`r`n" +
                         '      "model": "default"' + "`r`n" +
                         '    }' + "`r`n" +
                         '  ]' + "`r`n" +
                         '}' + "`r`n"
        [IO.File]::WriteAllText((Join-Path $cslDir 'ExtraList.json'), $extraListJson, (New-Object Text.UTF8Encoding($false)))
    }

    # 5. Clean up any non-universal or obsolete CustomSkinLoader jars
    $modsDir = Join-Path $InstanceRoot 'mods'
    if(Test-Path -LiteralPath $modsDir -PathType Container){
        foreach($oldCsl in Get-ChildItem -LiteralPath $modsDir -Filter 'CustomSkinLoader_*.jar'){
            if($oldCsl.Name -ne 'CustomSkinLoader_Universal-15.0.1.jar'){
                Remove-Item -LiteralPath $oldCsl.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 6. Enable Tissou's Zombie Pack resource pack + OptiFine emissive textures by default
    $optsPath = Join-Path $InstanceRoot 'options.txt'
    if(Test-Path -LiteralPath $optsPath -PathType Leaf){
        $optsText = Get-Content -LiteralPath $optsPath -Raw
        $optsText = $optsText -replace '(?m)^resourcePacks:.*$', 'resourcePacks:["Tissous Zombie Pack 1.12.2 - 2.6.zip"]'
        [IO.File]::WriteAllText($optsPath, $optsText, (New-Object Text.UTF8Encoding($false)))
    }
    $ofPath = Join-Path $InstanceRoot 'optionsof.txt'
    $ofText = "ofShowGlErrors:false`r`nofEmissiveTextures:true`r`nofRandomEntities:true`r`nofCustomFonts:true`r`nofCustomColors:true`r`nofCustomItems:true`r`nofCustomSky:true`r`nofConnectedTextures:2`r`nofDynamicLights:3`r`nofCustomEntityModels:true`r`nofCustomGuis:true`r`nofFastRender:false`r`n"
    [IO.File]::WriteAllText($ofPath, $ofText, (New-Object Text.UTF8Encoding($false)))
}
#>

function Get-CocoManagedInstanceModIds([string]$InstanceRoot){
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $mods=Join-Path $InstanceRoot 'mods'
    if(-not(Test-Path -LiteralPath $mods -PathType Container)){return @()}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach($jar in @(Get-ChildItem -LiteralPath $mods -File -Filter '*.jar' -ErrorAction SilentlyContinue)){
        $archive=$null
        try{
            $archive=[IO.Compression.ZipFile]::OpenRead($jar.FullName)
            foreach($jsonPath in 'fabric.mod.json','quilt.mod.json'){
                $entry=$archive.GetEntry($jsonPath)
                if(-not$entry){continue}
                $reader=[IO.StreamReader]::new($entry.Open())
                try{$metadata=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
                $id=if($jsonPath-eq'fabric.mod.json'){[string]$metadata.id}else{[string]$metadata.quilt_loader.id}
                if($id-match'^[a-zA-Z0-9_.-]{1,128}$'){[void]$ids.Add($id)}
            }
            foreach($tomlPath in 'META-INF/mods.toml','META-INF/neoforge.mods.toml'){
                $entry=$archive.GetEntry($tomlPath)
                if(-not$entry){continue}
                $reader=[IO.StreamReader]::new($entry.Open())
                try{$toml=$reader.ReadToEnd()}finally{$reader.Dispose()}
                foreach($match in [regex]::Matches($toml,'(?m)^\s*modId\s*=\s*["'']([a-zA-Z0-9_.-]{1,128})["'']')){
                    [void]$ids.Add([string]$match.Groups[1].Value)
                }
            }
        }catch{
            if(Get-Command Write-CocoLog -ErrorAction SilentlyContinue){Write-CocoLog "No se pudo leer metadata de '$($jar.Name)': $($_.Exception.Message)"}
        }finally{if($archive){$archive.Dispose()}}
    }
    @($ids|Sort-Object)
}

function Set-CocoJavaProperties([string]$Path,[Collections.IDictionary]$Values){
    if(-not$Values-or-not$Values.Count){return $false}
    $lines=[Collections.Generic.List[string]]::new()
    if(Test-Path -LiteralPath $Path -PathType Leaf){
        foreach($line in @(Get-Content -LiteralPath $Path)){[void]$lines.Add([string]$line)}
    }
    $changed=$false
    foreach($key in $Values.Keys){
        if([string]$key-notmatch'^[a-zA-Z0-9_.-]+$'){throw "Clave de propiedades insegura: $key"}
        $desired="$key=$([string]$Values[$key])";$found=$false
        for($i=0;$i-lt$lines.Count;$i++){
            if($lines[$i]-match("^\s*"+[regex]::Escape([string]$key)+"\s*=")){
                $found=$true
                if($lines[$i]-cne$desired){$lines[$i]=$desired;$changed=$true}
                break
            }
        }
        if(-not$found){$lines.Add($desired);$changed=$true}
    }
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){$changed=$true}
    if($changed){
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force|Out-Null
        $temporary="$Path.coco-$PID-$([guid]::NewGuid().ToString('N')).tmp"
        try{
            [IO.File]::WriteAllText($temporary,(($lines-join"`r`n").TrimEnd()+"`r`n"),(New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $temporary -Destination $Path -Force
        }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    }
    $changed
}

function Set-CocoVoiceChatDefaults([string]$InstanceRoot){
    $modIds=@(Get-CocoManagedInstanceModIds $InstanceRoot)
    if($modIds-notcontains'voicechat'){return [pscustomobject]@{Detected=$false;Adapter='';Changed=$false}}
    $path=Join-Path $InstanceRoot 'config\voicechat\voicechat-client.properties'
    $changed=Set-CocoJavaProperties $path ([ordered]@{
        config_version='1'
        onboarding_finished='true'
        microphone=''
        speaker=''
        microphone_activation_type='VOICE'
        voice_activity_detection='true'
        voice_activation_threshold='-50.0'
        microphone_gain='0.0'
        automatic_gain_control='true'
        denoiser='true'
        muted='false'
        disabled='false'
        run_local_server='true'
        use_natives='true'
    })
    if(Get-Command Write-CocoLog -ErrorAction SilentlyContinue){Write-CocoLog "Simple Voice Chat configurado. Path='$path' Changed=$changed Devices=default Activation=VOICE AGC=true Denoiser=true Muted=false"}
    [pscustomobject]@{Detected=$true;Adapter='simple-voice-chat';Changed=[bool]$changed;Path=$path}
}

function Set-CocoManagedInstancePreferences($Experience,[string]$InstanceRoot){
    if(-not$Experience-or[string]::IsNullOrWhiteSpace($InstanceRoot)-or-not(Test-Path -LiteralPath $InstanceRoot)){return}
    [void](Set-CocoVoiceChatDefaults $InstanceRoot)
    $preferences=$Experience.preferences
    if(-not$preferences){return}

    $keybindings=[ordered]@{}
    if($preferences.keybindings){
        foreach($property in @($preferences.keybindings.PSObject.Properties)){
            $key=[string]$property.Name
            $value=[string]$property.Value
            if($key-notmatch'^key_[a-zA-Z0-9_.-]+$'){throw "Clave de atajo insegura para '$($Experience.id)': '$key'."}
            if($value-notmatch'^key\.(keyboard|mouse)\.[a-zA-Z0-9_.-]+(?::[a-zA-Z0-9_.-]+)*$'){
                throw "Valor de atajo inseguro para '$($Experience.id)': '$value'."
            }
            $keybindings[$key]=$value
        }
    }

    if($preferences.managedFiles){
        foreach($managedFile in @($preferences.managedFiles)){
            $relative=([string]$managedFile.path)-replace'/','\'
            $destination=Join-Path $InstanceRoot $relative
            if(-not(Test-CocoPathWithin $destination $InstanceRoot)){throw "Una preferencia intento escapar de '$($Experience.id)'."}
            $writeMode=if($managedFile.writeMode){[string]$managedFile.writeMode}else{'replace'}
            if($writeMode-eq'initialize'-and(Test-Path -LiteralPath $destination -PathType Leaf)){continue}
            New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
            $content=[string]$managedFile.content
            $current=if(Test-Path -LiteralPath $destination -PathType Leaf){[IO.File]::ReadAllText($destination)}else{$null}
            if($current-cne$content){
                $temporary="$destination.coco-$PID-$([guid]::NewGuid().ToString('N')).tmp"
                try{
                    [IO.File]::WriteAllText($temporary,$content,(New-Object Text.UTF8Encoding($false)))
                    Move-Item -LiteralPath $temporary -Destination $destination -Force
                }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
            }
        }
    }

    if($preferences.tomlValues){
        foreach($tomlGroup in @($preferences.tomlValues|Group-Object path)){
            $relative=([string]$tomlGroup.Name)-replace'/','\'
            $destination=Join-Path $InstanceRoot $relative
            if(-not(Test-CocoPathWithin $destination $InstanceRoot)){
                throw "Una preferencia TOML intento escapar de '$($Experience.id)': '$relative'."
            }
            if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){
                New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
                $sections=[Collections.Generic.List[string]]::new()
                foreach($sectionGroup in @($tomlGroup.Group|Group-Object section)){
                    $sections.Add("[$([string]$sectionGroup.Name)]")
                    foreach($tomlValue in @($sectionGroup.Group)){
                        $value=$tomlValue.value
                        $encoded=if($value-is[bool]){([string]$value).ToLowerInvariant()}elseif($value-is[string]){
                            '"'+(([string]$value)-replace'\\','\\'-replace'"','\"')+'"'
                        }else{[Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture)}
                        $sections.Add("$([string]$tomlValue.key) = $encoded")
                    }
                    $sections.Add('')
                }
                [IO.File]::WriteAllText($destination,(($sections-join"`r`n").TrimEnd()+"`r`n"),(New-Object Text.UTF8Encoding($false)))
            }
            $content=[IO.File]::ReadAllText($destination)
            foreach($tomlValue in @($tomlGroup.Group)){
                $section=[string]$tomlValue.section
                $key=[string]$tomlValue.key
                $value=$tomlValue.value
                $encoded=if($value-is[bool]){([string]$value).ToLowerInvariant()}elseif($value-is[string]){
                    '"'+(([string]$value)-replace'\\','\\'-replace'"','\"')+'"'
                }else{[Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture)}

                $sectionMatch=[regex]::Match($content,("(?m)^\s*\[{0}\]\s*\r?$"-f[regex]::Escape($section)))
                if(-not$sectionMatch.Success){
                    $content=$content.TrimEnd()+"`r`n`r`n[$section]`r`n$key = $encoded`r`n"
                    continue
                }
                $bodyStart=$sectionMatch.Index+$sectionMatch.Length
                $nextSection=(New-Object regex '(?m)^\s*\[').Match($content,$bodyStart)
                $bodyLength=if($nextSection.Success){$nextSection.Index-$bodyStart}else{$content.Length-$bodyStart}
                $body=$content.Substring($bodyStart,$bodyLength)
                $keyMatch=[regex]::Match($body,("(?m)^(\s*{0}\s*=\s*).*$"-f[regex]::Escape($key)))
                if(-not$keyMatch.Success){
                    $content=$content.Insert($bodyStart,"`r`n$key = $encoded")
                    continue
                }
                $replacement=$keyMatch.Groups[1].Value+$encoded
                $absoluteIndex=$bodyStart+$keyMatch.Index
                $content=$content.Remove($absoluteIndex,$keyMatch.Length).Insert($absoluteIndex,$replacement)
            }
            [IO.File]::WriteAllText($destination,$content,(New-Object Text.UTF8Encoding($false)))
        }
    }

    if([bool]$preferences.standardControls-or$null-ne$preferences.fov-or$preferences.language-or$keybindings.Count-gt0){
        foreach($optsFile in @(
            (Join-Path $InstanceRoot 'options.txt'),
            (Join-Path $InstanceRoot 'config\defaultoptions\options.txt'),
            (Join-Path $InstanceRoot 'config\defaultoptions\keybindings.txt')
        )){
            if(-not(Test-Path -LiteralPath $optsFile -PathType Leaf)){continue}
            $content=Get-Content -LiteralPath $optsFile -Raw
            if([bool]$preferences.standardControls){
                $content=$content-replace'(?m)^key_key\.sprint:.*$','key_key.sprint:key.keyboard.left.control'
                $content=$content-replace'(?m)^key_key\.sneak:.*$','key_key.sneak:key.keyboard.left.shift'
            }
            if($null-ne$preferences.fov){
                $fov=[string]([double]$preferences.fov).ToString([Globalization.CultureInfo]::InvariantCulture)
                if($content-match'(?m)^fov:'){$content=$content-replace'(?m)^fov:.*$',("fov:$fov")}
                else{$content=$content.TrimEnd()+"`r`nfov:$fov`r`n"}
            }
            if($preferences.language){
                $lang=[string]$preferences.language
                if($content-match'(?m)^lang:'){$content=$content-replace'(?m)^lang:.*$',("lang:$lang")}
                else{$content=$content.TrimEnd()+"`r`nlang:$lang`r`n"}
            }
            foreach($key in $keybindings.Keys){
                $replacement="${key}:$($keybindings[$key])"
                $pattern='(?m)^'+[regex]::Escape([string]$key)+':.*$'
                if($content-match$pattern){$content=[regex]::Replace($content,$pattern,$replacement)}
                else{$content=$content.TrimEnd()+"`r`n$replacement`r`n"}
            }
            [IO.File]::WriteAllText($optsFile,$content,(New-Object Text.UTF8Encoding($false)))
        }
    }

    if($preferences.shader){
        $pack=[string]$preferences.shader.pack
        if(-not(Test-CocoSafeRelativePath $pack)-or$pack.Contains('/')){throw "El shader configurado para '$($Experience.id)' no es un nombre seguro."}
        if(Test-Path -LiteralPath (Join-Path $InstanceRoot "shaderpacks\$pack") -PathType Leaf){
            switch([string]$preferences.shader.provider){
                'oculus'{
                    $path=Join-Path $InstanceRoot 'config\oculus.properties'
                    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force|Out-Null
                    $text="colorSpace=SRGB`r`ndisableUpdateMessage=true`r`nenableDebugOptions=false`r`nmaxShadowRenderDistance=4`r`nshaderPack=$pack`r`nenableShaders=true`r`n"
                    [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
                }
                'iris'{
                    [void](Set-CocoJavaProperties (Join-Path $InstanceRoot 'config\iris.properties') ([ordered]@{
                        shaderPack=$pack
                        enableShaders='true'
                    }))
                }
                'optifine'{
                    [IO.File]::WriteAllText((Join-Path $InstanceRoot 'optionsshaders.txt'),"shaderPack=$pack`r`n",(New-Object Text.UTF8Encoding($false)))
                }
                default{throw "Proveedor de shader no soportado para '$($Experience.id)'."}
            }
            if($preferences.shader.companionFiles){
                foreach($property in @($preferences.shader.companionFiles.PSObject.Properties)){
                    $name=[string]$property.Name
                    if(-not(Test-CocoSafeRelativePath $name)-or$name.Contains('/')){throw "Archivo auxiliar de shader inseguro para '$($Experience.id)'."}
                    $destination=Join-Path $InstanceRoot "shaderpacks\$name"
                    [IO.File]::WriteAllText($destination,[string]$property.Value,(New-Object Text.UTF8Encoding($false)))
                }
            }
        }
    }

    if($preferences.resourcePack){
        $pack=[string]$preferences.resourcePack
        if(-not(Test-CocoSafeRelativePath $pack)-or$pack.Contains('/')){throw "El resource pack configurado para '$($Experience.id)' no es un nombre seguro."}
        if(Test-Path -LiteralPath (Join-Path $InstanceRoot "resourcepacks\$pack") -PathType Leaf){
            $optsPath=Join-Path $InstanceRoot 'options.txt'
            if(Test-Path -LiteralPath $optsPath -PathType Leaf){
                $optsText=Get-Content -LiteralPath $optsPath -Raw
                $escaped=$pack.Replace('\','\\').Replace('"','\"')
                if($optsText-match'(?m)^resourcePacks:'){$optsText=$optsText-replace'(?m)^resourcePacks:.*$',("resourcePacks:[""$escaped""]")}
                else{$optsText=$optsText.TrimEnd()+"`r`nresourcePacks:[""$escaped""]`r`n"}
                [IO.File]::WriteAllText($optsPath,$optsText,(New-Object Text.UTF8Encoding($false)))
            }
        }
    }

    if([bool]$preferences.optifineEmissive){
        $ofText="ofShowGlErrors:false`r`nofEmissiveTextures:true`r`nofRandomEntities:true`r`nofCustomFonts:true`r`nofCustomColors:true`r`nofCustomItems:true`r`nofCustomSky:true`r`nofConnectedTextures:2`r`nofDynamicLights:3`r`nofCustomEntityModels:true`r`nofCustomGuis:true`r`nofFastRender:false`r`n"
        [IO.File]::WriteAllText((Join-Path $InstanceRoot 'optionsof.txt'),$ofText,(New-Object Text.UTF8Encoding($false)))
    }
}

function Invoke-CocoManagedExperienceLaunch(
    $Catalog,
    [string]$ExperienceId,
    $Identity,
    [ValidateSet('client','host')][string]$Role,
    [string]$CatalogRoot,
    [string]$CacheRoot,
    [string]$ExperiencesRoot,
    [switch]$Dry,
    [switch]$DisableAutoJoin,
    [switch]$SkipLocationPrompt,
    [string]$InstanceLocationsPath=''
){
    $experience=@($Catalog.experiences|Where-Object id -eq $ExperienceId|Select-Object -First 1)[0]
    if(-not$experience-or$experience.managementMode-ne'managed'){throw "La experiencia administrada '$ExperienceId' no existe."}
    Write-CocoStorageDiagnostic 'install.start' @{experienceId=$ExperienceId;instanceId=$experience.instanceId;name=$experience.name;role=$Role;dry=$Dry;skipLocationPrompt=$SkipLocationPrompt;experiencesRoot=$ExperiencesRoot;cacheRoot=$CacheRoot;locationPath=$InstanceLocationsPath}
    $location=if($SkipLocationPrompt){
        [pscustomobject]@{Confirmed=$true;Cancelled=$false;Choice='headless-default';Root=(Get-CocoExperienceInstanceRoot $experience $ExperiencesRoot $InstanceLocationsPath)}
    }else{
        Prompt-CocoExperienceLocationChoice $experience $ExperiencesRoot $InstanceLocationsPath
    }
    Write-CocoStorageDiagnostic 'install.location-result' @{experienceId=$ExperienceId;instanceId=$experience.instanceId;choice=$location.Choice;confirmed=$location.Confirmed;cancelled=$location.Cancelled;root=$location.Root;role=$Role}
    if(-not$location.Confirmed){Write-CocoStorageDiagnostic 'install.cancelled' @{experienceId=$ExperienceId;instanceId=$experience.instanceId;choice=$location.Choice};throw "La instalacion de '$($experience.name)' fue cancelada."}
    $dummyInstaller=$global:CocoUiDevDummyInstaller
    if(-not$dummyInstaller){$dummyInstaller=$script:CocoUiDevDummyInstaller}
    if($Dry-and$dummyInstaller){
        $testPaths=[pscustomobject]@{ExperiencesRoot=$ExperiencesRoot;CacheRoot=$CacheRoot;InstanceLocationsPath=$InstanceLocationsPath}
        $testInstallation=& $dummyInstaller $experience ([string]$location.Root) $testPaths
        if(-not$testInstallation){$testInstallation=[pscustomobject]@{InstanceRoot=[string]$location.Root;Updated=$true}}
        Write-CocoStorageDiagnostic 'install.dry-complete' @{experienceId=$ExperienceId;instanceId=$experience.instanceId;root=$location.Root;role=$Role}
        return [pscustomobject]@{Status='prepared';Experience=$experience;Installation=$testInstallation;TestDummy=$true}
    }

    if([string]$experience.launch.workflow-eq'coco-standalone'-or[string]$experience.runtime.type-eq'standalone'){
        $installed=Install-CocoStandaloneExperience $experience $ExperiencesRoot $CacheRoot $InstanceLocationsPath $Role
        $defenderStatus = if(-not $Dry){ Ensure-CocoDefenderExclusion $experience $installed.InstanceRoot } else { 'skipped-dry' }
        if($experience.hosting.host -and [string]$experience.hosting.mode -ne 'p2p'){
            $hostIp=[string]$experience.hosting.host
            [IO.File]::WriteAllText((Join-Path $installed.InstanceRoot 'ip.txt'),$hostIp,(New-Object Text.UTF8Encoding($false)))
            Get-ChildItem -Path $installed.InstanceRoot -Recurse -Filter 'steam_api64.dll' -ErrorAction SilentlyContinue|Where-Object{$_.DirectoryName -notmatch '(?i)[\\/]Plugins([\\/]|$)'}|ForEach-Object{
                $targetIpFile=Join-Path $_.DirectoryName 'ip.txt'
                [IO.File]::WriteAllText($targetIpFile,$hostIp,(New-Object Text.UTF8Encoding($false)))
            }
        }else{
            Get-ChildItem -Path $installed.InstanceRoot -Recurse -Filter 'ip.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Ensure-CocoOnlineFixSuppression $installed.InstanceRoot $experience
        $requiredStatus=@(Repair-CocoStandaloneRequiredFiles $experience $installed.InstanceRoot $CacheRoot)
        if($Dry){
            return [pscustomobject]@{Status='prepared';Experience=$experience;Installation=$installed}
        }

        $diagLog = Join-Path $installed.InstanceRoot 'logs\standalone-diagnostics.log'
        New-Item -ItemType Directory -Path (Split-Path $diagLog -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
        $diagLines = [System.Collections.Generic.List[string]]::new()
        $diagLines.Add("=== COCO STANDALONE DIAGNOSTIC LOG ===")
        $diagLines.Add("Timestamp: $((Get-Date).ToString('o'))")
        $diagLines.Add("InstanceRoot: $($installed.InstanceRoot)")
        foreach($requiredItem in $requiredStatus){$diagLines.Add("REQUIRED FILE: $($requiredItem.path) = $($requiredItem.status)")}
        $diagLines.Add("DEFENDER EXCLUSION: $defenderStatus")
        $steamProc = @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
        $diagLines.Add("Steam running: $(if ($steamProc) { 'True (PID ' + $steamProc[0].Id + ')' } else { 'False' })")
        
        [System.IO.File]::WriteAllText($diagLog, ($diagLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-CocoLog "Diagnostico standalone guardado en '$diagLog'."

        [void](Ensure-CocoSteamRunning)
        $log=Join-Path $CacheRoot ("logs\launcher-$ExperienceId-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
        $execPath=Join-Path $installed.InstanceRoot (([string]$experience.runtime.executable)-replace'/','\')
        if(-not(Test-Path -LiteralPath $execPath)){
            throw "No se encontro el ejecutable '$execPath' tras la instalacion standalone."
        }
        Write-CocoLog "Iniciando proceso standalone '$execPath' en '$($installed.InstanceRoot)'"
        $launchArgs = @()
        if($experience.launch -and $experience.launch.arguments){
            $launchArgs = @($experience.launch.arguments)
        }elseif($experience.runtime -and $experience.runtime.arguments){
            $launchArgs = @($experience.runtime.arguments)
        }
        Prepare-CocoStandalonePopupGate $experience
        $process = if($launchArgs.Count -gt 0){
            Write-CocoLog "Argumentos standalone: $($launchArgs -join ' ')"
            Start-Process -FilePath $execPath -ArgumentList $launchArgs -WorkingDirectory $installed.InstanceRoot -PassThru
        }else{
            Start-Process -FilePath $execPath -WorkingDirectory $installed.InstanceRoot -PassThru
        }
        Start-CocoStandalonePopupGate $process $experience
        return [pscustomobject]@{Status='launched';Experience=$experience;Installation=$installed;Process=$process;LogPath=$log}
    }

    $lockPath=Join-Path $CatalogRoot (([string]$experience.pack.lockPath)-replace'^launcher/',''-replace'/','\')
    $lock=Read-CocoExperienceLock $lockPath $experience
    $backend=Install-CocoLauncherBackend $Catalog $CacheRoot
    $installed=Install-CocoManagedExperience $experience $lock $ExperiencesRoot $CacheRoot $Role $Catalog.globalPolicies $InstanceLocationsPath
    [void](Remove-CocoEssentialArtifacts $installed.InstanceRoot)
    Set-CocoGlobalSkinAssets $Catalog.globalPolicies $experience $installed.InstanceRoot $script:CocoEngineRoot
    [void](Install-CocoSkinRegistry (Join-Path $CacheRoot 'launcher\skins\profiles') $installed.InstanceRoot)
    [void](Set-CocoManagedInstancePreferences $experience $installed.InstanceRoot)
    if(Get-Command Write-CocoManagedServerList -ErrorAction SilentlyContinue){[void](Write-CocoManagedServerList $installed.InstanceRoot $experience)}
    $mainDir=Join-Path $CacheRoot 'launcher\shared'
    $accountDb=Join-Path $CacheRoot 'launcher\accounts\portablemc_msa.json'
    New-Item -ItemType Directory -Path (Split-Path $accountDb -Parent),$mainDir -Force|Out-Null
    $launchExperience=$experience
    if($DisableAutoJoin){
        $launchExperience=(($experience|ConvertTo-Json -Depth 12)|ConvertFrom-Json)
        $launchExperience.launch.autoJoin=$false
    }
    $arguments=New-CocoPortableMcStartArguments $launchExperience $Identity $mainDir $installed.InstanceRoot $accountDb -Dry:$Dry
    if($Dry){
        $result=Invoke-CocoPortableMcPreparation $backend $arguments $ExperienceId
        return [pscustomobject]@{Status='prepared';Experience=$experience;Installation=$installed;Backend=$backend;Result=$result}
    }
    # La primera ejecucion puede requerir miles de assets Mojang/Forge. Se
    # preparan con reintentos reanudables antes de abrir la ventana del juego,
    # de modo que una conexion cerrada no convierta el primer uso en un fallo.
    [void](Invoke-CocoPortableMcPreparation $backend $arguments $ExperienceId)
    # Reaplicar justo antes del proceso recoge una skin elegida mientras se
    # descargaban el runtime o los assets.
    [void](Install-CocoSkinRegistry (Join-Path $CacheRoot 'launcher\skins\profiles') $installed.InstanceRoot)
    $log=Join-Path $CacheRoot ("logs\launcher-$ExperienceId-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    $process=Start-CocoPortableMcGame $backend $arguments $log
    [pscustomobject]@{Status='launched';Experience=$experience;Installation=$installed;Backend=$backend;Process=$process;LogPath=$log}
}

function Test-CocoLauncherBackendInstallation($Backend,[string]$RuntimeRoot){
    if(-not$Backend-or[string]::IsNullOrWhiteSpace($RuntimeRoot)){return $false}
    $executable=Join-Path $RuntimeRoot ([string]$Backend.executable)
    if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){return $false}
    try{
        $item=Get-Item -LiteralPath $executable
        if([int64]$item.Length-ne[int64]$Backend.executableSize){return $false}
        $hash=(Get-CocoFileSha256 $executable)
        if($hash-ne([string]$Backend.executableSha256).ToLowerInvariant()){return $false}
        $output=& $executable --version 2>&1|Out-String
        if($LASTEXITCODE-ne0){return $false}
        return $output-match[string]$Backend.versionOutputPattern
    }catch{return $false}
}

function Expand-CocoLauncherBackendArchive([string]$Archive,[string]$Destination){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        foreach($entry in $zip.Entries){
            if($entry.FullName.EndsWith('/')){continue}
            if(-not (Test-CocoSafeRelativePath ([string]$entry.FullName))){throw "El backend contiene una ruta insegura: '$($entry.FullName)'."}
        }
    }finally{$zip.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive,$Destination)
}

function Install-CocoLauncherBackend($Catalog,[string]$CacheRoot,[string]$ArchivePath=''){
    $backend=$Catalog.backend
    $runtimeParent=Join-Path $CacheRoot 'launcher\runtime\portablemc'
    $runtimeRoot=Join-Path $runtimeParent ([string]$backend.version)
    if(Test-CocoLauncherBackendInstallation $backend $runtimeRoot){return (Join-Path $runtimeRoot ([string]$backend.executable))}
    New-Item -ItemType Directory -Path $runtimeParent -Force|Out-Null
    $archive=$ArchivePath
    if([string]::IsNullOrWhiteSpace($archive)){
        if(-not(Get-Command Download-VerifiedFile -ErrorAction SilentlyContinue)){throw 'El engine no expone la descarga verificada requerida por Coco Launcher.'}
        $backendDownloads=Join-Path $CacheRoot 'downloads\launcher-backends'
        New-Item -ItemType Directory -Path $backendDownloads -Force|Out-Null
        $archive=Join-Path $backendDownloads ("$($backend.sha256).zip")
        if(-not((Test-Path -LiteralPath $archive)-and(Get-Sha256 $archive)-eq([string]$backend.sha256).ToLowerInvariant())){
            Download-VerifiedFile ([string]$backend.url) $archive ([string]$backend.sha256)
        }
    }
    if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){throw 'No existe el archivo del backend Coco Launcher.'}
    if((Get-Item -LiteralPath $archive).Length-ne[int64]$backend.size){throw 'El archivo del backend no coincide con el tamano fijado.'}
    if((Get-CocoFileSha256 $archive)-ne([string]$backend.sha256).ToLowerInvariant()){
        throw 'El archivo del backend no coincide con el SHA-256 fijado.'
    }
    $stage=Join-Path $runtimeParent ("$($backend.version).new-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $stage -Force|Out-Null
    try{
        Expand-CocoLauncherBackendArchive $archive $stage
        if(-not(Test-CocoLauncherBackendInstallation $backend $stage)){throw 'El hash, tamano, version o commit del backend Coco Launcher no coincide con el catalogo.'}
        $notice=@"
Coco Launcher usa PortableMC como programa separado y sin modificar.
Version: $($backend.version)
Commit: $($backend.commit)
Licencia: $($backend.license)
Fuente: $($backend.source)
Archivo oficial: $($backend.url)
SHA-256 del archivo: $($backend.sha256)
SHA-256 del ejecutable: $($backend.executableSha256)
Firma separada publicada: $($backend.signatureUrl)
SHA-256 de la firma separada: $($backend.signatureSha256)
Huella PGP publicada: $($backend.pgpFingerprint)
"@
        [IO.File]::WriteAllText((Join-Path $stage 'COCO-BACKEND-NOTICE.txt'),$notice,(New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $runtimeRoot){
            $backupRoot=Join-Path $CacheRoot 'backups\launcher-runtimes'
            New-Item -ItemType Directory -Path $backupRoot -Force|Out-Null
            $backup=Join-Path $backupRoot ("portablemc-$($backend.version)-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $runtimeRoot -Destination $backup
        }
        Move-Item -LiteralPath $stage -Destination $runtimeRoot
        if(-not(Test-CocoLauncherBackendInstallation $backend $runtimeRoot)){throw 'El backend dejo de ser valido despues de instalarse.'}
        return (Join-Path $runtimeRoot ([string]$backend.executable))
    }finally{
        if((Test-Path -LiteralPath $stage)-and(Test-CocoPathWithin $stage $runtimeParent)){
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CocoLauncherAllowedLegacyRoots{
    @(
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )|Where-Object{$_-and(Test-Path -LiteralPath $_)}|Select-Object -Unique
}

function Test-CocoLegacyLauncherCandidate(
    [string]$Source,
    [string]$Canonical,
    [string[]]$AllowedRoots=(Get-CocoLauncherAllowedLegacyRoots),
    [string]$ProductNameOverride=''
){
    if([string]::IsNullOrWhiteSpace($Source)-or-not(Test-Path -LiteralPath $Source -PathType Leaf)){return $false}
    if([IO.Path]::GetExtension($Source)-ine'.exe'){return $false}
    try{
        $sourceFull=[IO.Path]::GetFullPath($Source)
        $canonicalFull=[IO.Path]::GetFullPath($Canonical)
        if([string]::Equals($sourceFull,$canonicalFull,[StringComparison]::OrdinalIgnoreCase)){return $false}
    }catch{return $false}
    if(-not@($AllowedRoots|Where-Object{Test-CocoPathWithin $Source $_}).Count){return $false}
    $name=[IO.Path]::GetFileName($Source)
    if($name-notmatch'(?i)^Coco(?:[ ._-]*Minecraft)?[ ._-]*(?:Updater|Launcher)(?:[ ._()\-]*\d+[ ._()\-]*)*\.exe$'){return $false}
    $product=$ProductNameOverride
    if([string]::IsNullOrWhiteSpace($product)){
        try{
            $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($Source)
            $product=if($info.ProductName){[string]$info.ProductName}else{[string]$info.FileDescription}
        }catch{return $false}
    }
    return $product-in@('Coco Minecraft Updater','Coco Launcher')
}

function Install-CocoLauncherShortcut([string]$CanonicalExe,[string]$DesktopPath=([Environment]::GetFolderPath('Desktop'))){
    if(-not(Test-Path -LiteralPath $CanonicalExe -PathType Leaf)){throw "No existe el EXE canonico para el acceso directo: $CanonicalExe"}
    if([string]::IsNullOrWhiteSpace($DesktopPath)){throw 'Windows no devolvio una ruta de Escritorio.'}
    New-Item -ItemType Directory -Path $DesktopPath -Force|Out-Null
    $shortcutPath=Join-Path $DesktopPath 'Coco Launcher.lnk'
    $temporary="$shortcutPath.coco-$PID.tmp.lnk"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    $shell=$null;$shortcut=$null
    try{
        $shell=New-Object -ComObject WScript.Shell
        $shortcut=$shell.CreateShortcut($temporary)
        $shortcut.TargetPath=[IO.Path]::GetFullPath($CanonicalExe)
        $shortcut.WorkingDirectory=Split-Path ([IO.Path]::GetFullPath($CanonicalExe)) -Parent
        $shortcut.IconLocation=([IO.Path]::GetFullPath($CanonicalExe))+',0'
        $shortcut.Description='Abrir Coco Launcher'
        $shortcut.Save()
        if(-not(Test-Path -LiteralPath $temporary)){throw 'Windows no creo el acceso directo temporal.'}
        Move-Item -LiteralPath $temporary -Destination $shortcutPath -Force
        return $shortcutPath
    }finally{
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        foreach($item in @($shortcut,$shell)){
            if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}
        }
    }
}

function New-CocoLegacyLauncherArchiveHelper(
    [string]$Source,
    [string]$Canonical,
    [string]$CacheRoot,
    [int64]$WaitPid,
    [switch]$Start
){
    $sessionRoot=Join-Path $CacheRoot 'session'
    $backupRoot=Join-Path $CacheRoot 'backups\legacy-launchers'
    New-Item -ItemType Directory -Path $sessionRoot,$backupRoot -Force|Out-Null
    $sourceHash=(Get-CocoFileSha256 $Source)
    $helper=Join-Path $sessionRoot "Archive-CocoLegacyLauncher-$PID-$([guid]::NewGuid().ToString('N')).ps1"
    $helperText=@'
param([int64]$WaitPid,[string]$Source,[string]$Canonical,[string]$BackupRoot,[string]$ExpectedHash)
$ErrorActionPreference='Stop'
if($WaitPid-gt0){Wait-Process -Id $WaitPid -ErrorAction SilentlyContinue}
try{
    if(-not(Test-Path -LiteralPath $Source -PathType Leaf)){exit 0}
    if([string]::Equals([IO.Path]::GetFullPath($Source),[IO.Path]::GetFullPath($Canonical),[StringComparison]::OrdinalIgnoreCase)){exit 2}
    $actual=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actual-ne$ExpectedHash){exit 3}
    New-Item -ItemType Directory -Path $BackupRoot -Force|Out-Null
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $base=[IO.Path]::GetFileNameWithoutExtension($Source)-replace'[^A-Za-z0-9._ -]','_'
    $destination=Join-Path $BackupRoot ("$stamp-$base-$($ExpectedHash.Substring(0,8)).exe")
    $suffix=0
    while(Test-Path -LiteralPath $destination){$suffix++;$destination=Join-Path $BackupRoot ("$stamp-$base-$($ExpectedHash.Substring(0,8))-$suffix.exe")}
    Move-Item -LiteralPath $Source -Destination $destination
    exit 0
}catch{exit 1}
finally{Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue}
'@
    [IO.File]::WriteAllText($helper,$helperText,(New-Object Text.UTF8Encoding($true)))
    if($Start){
        $quotedHelper='"'+($helper-replace'"','\"')+'"'
        $quotedSource='"'+($Source-replace'"','\"')+'"'
        $quotedCanonical='"'+($Canonical-replace'"','\"')+'"'
        $quotedBackup='"'+($backupRoot-replace'"','\"')+'"'
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedHelper,
            '-WaitPid',$WaitPid,'-Source',$quotedSource,'-Canonical',$quotedCanonical,
            '-BackupRoot',$quotedBackup,'-ExpectedHash',$sourceHash
        )
    }
    [pscustomobject]@{HelperPath=$helper;BackupRoot=$backupRoot;ExpectedHash=$sourceHash}
}

function Initialize-CocoLauncherMigration([string]$CanonicalExe,[bool]$ArchiveInvokedCopy=$true){
    if([string]::IsNullOrWhiteSpace($CanonicalExe)-or-not(Test-Path -LiteralPath $CanonicalExe -PathType Leaf)){return}
    try{
        $shortcut=Install-CocoLauncherShortcut $CanonicalExe
        Write-CocoLog "Acceso directo Coco Launcher listo en '$shortcut'."
    }catch{Write-CocoLog "No se pudo crear el acceso directo Coco Launcher: $($_.Exception.Message)"}
    if(-not$ArchiveInvokedCopy){return}
    $source=try{[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName}catch{$null}
    if(-not(Test-CocoLegacyLauncherCandidate $source $CanonicalExe)){return}
    try{
        $cacheRoot=Split-Path $CanonicalExe -Parent
        $scheduled=New-CocoLegacyLauncherArchiveHelper $source $CanonicalExe $cacheRoot $PID -Start
        Write-CocoLog "Copia antigua '$source' programada para respaldo en '$($scheduled.BackupRoot)'."
    }catch{Write-CocoLog "No se pudo programar el respaldo del EXE antiguo '$source': $($_.Exception.Message)"}
}

function Get-CocoLauncherPaths([string]$EngineRoot=$script:CocoEngineRoot,[string]$TestRoot=''){
    $localAppData=[Environment]::GetFolderPath('LocalApplicationData')
    if(-not$localAppData){$localAppData=$env:LOCALAPPDATA}
    $applicationData=[Environment]::GetFolderPath('ApplicationData')
    if(-not$applicationData){$applicationData=$env:APPDATA}
    $cacheRoot=Join-Path $localAppData 'CocoMinecraftUpdater'
    $experiencesRoot=Join-Path $applicationData 'CocoMinecraft\experiences'
    $instanceLocationsPath=Join-Path $localAppData 'CocoMinecraftUpdater\instance-locations.json'
    if(-not[string]::IsNullOrWhiteSpace($TestRoot)){
        # Este override existe exclusivamente para la prueba física local. Se
        # acepta sólo la raíz desechable conocida dentro de TEMP, evitando que
        # un comando de soporte redirija por error el launcher hacia .minecraft
        # o hacia otra carpeta arbitraria del usuario.
        $resolved=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
        $tempDir=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
        if(-not $resolved.StartsWith($tempDir,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path $resolved -Leaf).StartsWith('coco-',[StringComparison]::OrdinalIgnoreCase)){
             throw "LauncherTestRoot solo admite carpetas de prueba desechables en TEMP."
        }
        $cacheRoot=Join-Path $resolved 'cache'
        $experiencesRoot=Join-Path $resolved 'experiences'
        $instanceLocationsPath=Join-Path $cacheRoot 'instance-locations.json'
    }
    [pscustomobject]@{
        CacheRoot=$cacheRoot
        CatalogRoot=Join-Path $EngineRoot 'launcher'
        CatalogPath=Join-Path $EngineRoot 'launcher\catalog.json'
        IdentityPath=Join-Path $cacheRoot 'launcher\identity.json'
        SkinRoot=Join-Path $cacheRoot 'launcher\skins\profiles'
        SkinStatePath=Join-Path $cacheRoot 'launcher\skins\selection.json'
        AccountDb=Join-Path $cacheRoot 'launcher\accounts\portablemc_msa.json'
        MainDir=Join-Path $cacheRoot 'launcher\shared'
        SessionStatePath=Join-Path $cacheRoot 'launcher\session\active.json'
        SessionLogPath=Join-Path $cacheRoot 'logs\launcher-session-service.log'
        InstanceLocationsPath=$instanceLocationsPath
        ExperienceBackupRoot=Join-Path $cacheRoot 'backups\experiences'
        ExperiencesRoot=$experiencesRoot
        IsTest=-not[string]::IsNullOrWhiteSpace($TestRoot)
        TestRoot=$TestRoot
    }
}

function Get-CocoLauncherRole([string]$LegacyMinecraftRoot){
    if($global:CocoUiDevRoleOverride){return [string]$global:CocoUiDevRoleOverride}
    if($script:CocoUiDevRoleOverride){return [string]$script:CocoUiDevRoleOverride}
    if(Test-Path -LiteralPath (Join-Path $LegacyMinecraftRoot 'config\coco-host.json') -PathType Leaf){return 'host'}
    return 'client'
}

function Sync-CocoLegacyInstanceForLauncher([string]$LegacyMinecraftRoot,$Manifest){
    if(-not(Get-Command Test-GameDirectory -ErrorAction SilentlyContinue)-or-not(Test-GameDirectory $LegacyMinecraftRoot)){return [pscustomobject]@{Present=$false;Updated=$false;Role='client'}}
    $role=Get-Role $LegacyMinecraftRoot $Manifest
    if(Test-CurrentVersion $LegacyMinecraftRoot $Manifest $role){return [pscustomobject]@{Present=$true;Updated=$false;Role=$role}}
    if(Test-MinecraftRunning $LegacyMinecraftRoot){throw 'Cierra Minecraft antes de que Coco Launcher sincronice la instalacion original.'}
    Set-CocoState 'Actualizando Coco original' 'Sincronizando la instalacion heredada antes de mostrar partidas...' 10
    [void](Disable-TLauncherSkinCape $LegacyMinecraftRoot $Manifest)
    $package=@($Manifest.packages|Where-Object role -eq $role|Select-Object -First 1)[0]
    if(-not$package){$package=@($Manifest.packages|Where-Object role -eq 'client'|Select-Object -First 1)[0]}
    if(-not$package){throw "No existe paquete publicado para el rol $role."}
    $stage=Stage-Package $package $Manifest $LegacyMinecraftRoot
    Install-StagedPackage $LegacyMinecraftRoot $stage $package $Manifest
    if(-not(Test-CurrentVersion $LegacyMinecraftRoot $Manifest $role)){throw 'Coco original no quedo verificado despues de sincronizarse.'}
    [pscustomobject]@{Present=$true;Updated=$true;Role=$role}
}

function Test-CocoTcpEndpoint([string]$Address,[int]$Port,[int]$TimeoutMilliseconds=350){
    $client=[Net.Sockets.TcpClient]::new()
    try{
        $connect=$client.BeginConnect($Address,$Port,$null,$null)
        if(-not$connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)){return $false}
        $client.EndConnect($connect)
        return $true
    }catch{return $false}finally{$client.Dispose()}
}

function Set-CocoManagedLanWorldConfigurations([string]$InstanceRoot,$Experience){
    if(-not$Experience-or$Experience.managementMode-ne'managed'){return 0}
    if([string]$Experience.hosting.adapter-eq'lan-server-properties-v1'){return 0}
    $saves=Join-Path $InstanceRoot 'saves'
    if(-not(Test-Path -LiteralPath $saves -PathType Container)){return 0}
    $written=0
    foreach($world in @(Get-ChildItem -LiteralPath $saves -Directory -ErrorAction SilentlyContinue)){
        # Una carpeta sin level.dat/session.lock todavia no es un mundo valido.
        if(-not(Test-Path -LiteralPath (Join-Path $world.FullName 'level.dat') -PathType Leaf)-and-not(Test-Path -LiteralPath (Join-Path $world.FullName 'session.lock') -PathType Leaf)){continue}
        $path=Join-Path $world.FullName 'mcwifipnp.json'
        # MCWiFiPnP 1.19.2/1.20.1 deserializa con Gson directamente sobre
        # estos nombres de campos Java. Las variantes kebab-case no son alias:
        # Gson las ignora silenciosamente y deja OnlineMode=true.
        $payload=[ordered]@{
            port=[int]$Experience.hosting.port
            maxPlayers=8
            GameMode='survival'
            motd=("Coco - {0}"-f[string]$Experience.name)
            AllPlayersCheats=$false
            Whitelist=$false
            UseUPnP=$false
            AllowCommands=$true
            OnlineMode=$false
            EnableUUIDFixer=$true
            ForceOfflinePlayers=@()
            PvP=$true
            CopyToClipboard=$false
        }
        $json=$payload|ConvertTo-Json
        $current=if(Test-Path -LiteralPath $path -PathType Leaf){try{Get-Content -LiteralPath $path -Raw}catch{''}}else{''}
        $matches=$false
        if($current){
            try{
                $parsed=$current|ConvertFrom-Json
                $matches=[int]$parsed.port-eq[int]$Experience.hosting.port-and
                    -not[bool]$parsed.OnlineMode-and[bool]$parsed.EnableUUIDFixer-and-not[bool]$parsed.UseUPnP
            }catch{}
        }
        if($matches){continue}
        $temporary="$path.coco-$PID.tmp"
        [IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $path -Force
        $written++
    }
    return $written
}

function Test-CocoManagedLanWorldConfigurations([string]$InstanceRoot,$Experience){
    if(-not$Experience-or$Experience.managementMode-ne'managed'){return $false}
    if([string]$Experience.hosting.adapter-eq'lan-server-properties-v1'){
        $adapter=Join-Path $InstanceRoot 'mods\lanserverproperties-1.0.jar'
        return (Test-Path -LiteralPath $adapter -PathType Leaf)-and
            (Get-Item -LiteralPath $adapter).Length-eq7742-and
            (Get-CocoFileSha256 $adapter)-eq'15577c28814cda5ce0d6c0e9039a093a6227e2c9ec3716dae9c840ec0a99e263'
    }
    $saves=Join-Path $InstanceRoot 'saves'
    if(-not(Test-Path -LiteralPath $saves -PathType Container)){return $false}
    $worlds=@(Get-ChildItem -LiteralPath $saves -Directory -ErrorAction SilentlyContinue|Where-Object{
        (Test-Path -LiteralPath (Join-Path $_.FullName 'level.dat') -PathType Leaf)-or
        (Test-Path -LiteralPath (Join-Path $_.FullName 'session.lock') -PathType Leaf)
    })
    if(-not$worlds.Count){return $false}
    foreach($world in $worlds){
        $path=Join-Path $world.FullName 'mcwifipnp.json'
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}
        try{$cfg=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{return $false}
        if([int]$cfg.port-ne[int]$Experience.hosting.port-or[bool]$cfg.OnlineMode-or
            -not[bool]$cfg.EnableUUIDFixer-or[bool]$cfg.UseUPnP){return $false}
        foreach($required in 'maxPlayers','GameMode','AllPlayersCheats','Whitelist','AllowCommands','ForceOfflinePlayers','PvP','CopyToClipboard'){
            if($cfg.PSObject.Properties.Name-notcontains$required){return $false}
        }
    }
    return $true
}

function Write-CocoManagedServerList([string]$InstanceRoot,$Experience){
    if(-not$Experience-or$Experience.managementMode-ne'managed'){return $false}
    $path=Join-Path $InstanceRoot 'servers.dat'
    # La lista pertenece al jugador una vez creada. Coco solo aporta el valor
    # inicial y nunca reemplaza una lista ya editada por el usuario.
    if(Test-Path -LiteralPath $path -PathType Leaf){return $false}
    $name=[string]$Experience.launch.serverName
    $endpoint=("{0}:{1}"-f[string]$Experience.hosting.host,[int]$Experience.hosting.port)
    if([string]::IsNullOrWhiteSpace($name)-or$endpoint-notmatch'^10\.77\.37\.1:[0-9]{1,5}$'){throw 'No se puede crear servers.dat con un endpoint invalido.'}
    $temporary="$path.coco-$PID.tmp"
    $memory=[IO.MemoryStream]::new();$writer=$null
    try{
        # servers.dat moderno usa NBT sin compresion (igual que el archivo que
        # guarda Minecraft 1.20.1). Un GZip valido como contenedor seguia siendo
        # rechazado por ServerList con EOFException.
        $writer=[IO.BinaryWriter]::new($memory,(New-Object Text.UTF8Encoding($false)),$true)
        $writeInt16={param([int]$value)$writer.Write([byte](($value-shr8)-band255));$writer.Write([byte]($value-band255))}
        $writeInt32={param([int]$value)foreach($shift in 24,16,8,0){$writer.Write([byte](($value-shr$shift)-band255))}}
        $writeString={param([string]$value)$bytes=[Text.Encoding]::UTF8.GetBytes($value);if($bytes.Length-gt65535){throw 'String NBT demasiado largo.'};&$writeInt16 $bytes.Length;$writer.Write($bytes)}
        $writer.Write([byte]10);&$writeString ''                         # root compound
        $writer.Write([byte]9);&$writeString 'servers';$writer.Write([byte]10);&$writeInt32 1
        $writer.Write([byte]8);&$writeString 'name';&$writeString $name
        $writer.Write([byte]8);&$writeString 'ip';&$writeString $endpoint
        $writer.Write([byte]1);&$writeString 'hidden';$writer.Write([byte]0)
        $writer.Write([byte]0)                                          # server compound end
        $writer.Write([byte]0)                                          # root compound end
        $writer.Flush();$writer.Dispose();$writer=$null
        New-Item -ItemType Directory -Path $InstanceRoot -Force|Out-Null
        [IO.File]::WriteAllBytes($temporary,$memory.ToArray())
        Move-Item -LiteralPath $temporary -Destination $path
        return $true
    }finally{
        if($writer){$writer.Dispose()};$memory.Dispose()
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CocoLegacyExperienceLaunch($Catalog,$Experience,$Identity,[string]$LegacyMinecraftRoot,[string]$CacheRoot,[switch]$DisableAutoJoin){
    if(-not(Test-Path -LiteralPath $LegacyMinecraftRoot -PathType Container)){throw 'No existe la instancia Coco original.'}
    $backend=Install-CocoLauncherBackend $Catalog $CacheRoot
    $mainDir=Join-Path $CacheRoot 'launcher\shared'
    $accountDb=Join-Path $CacheRoot 'launcher\accounts\portablemc_msa.json'
    New-Item -ItemType Directory -Path (Split-Path $accountDb -Parent),$mainDir -Force|Out-Null
    $launchExperience=$Experience
    if($DisableAutoJoin){$launchExperience=(($Experience|ConvertTo-Json -Depth 12)|ConvertFrom-Json);$launchExperience.launch.autoJoin=$false}
    $arguments=New-CocoPortableMcStartArguments $launchExperience $Identity $mainDir $LegacyMinecraftRoot $accountDb
    $log=Join-Path $CacheRoot ("logs\launcher-$($Experience.id)-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    $process=Start-CocoPortableMcGame $backend $arguments $log
    [pscustomobject]@{Status='launched';Experience=$Experience;InstanceRoot=$LegacyMinecraftRoot;Backend=$backend;Process=$process;LogPath=$log}
}

<#
Flujo histórico 0.5.50-0.5.57, conservado temporalmente como referencia de
migración. Está comentado y no se compila: Coco ya no ofrece login Microsoft
ni formularios Windows separados para identidad.
function Show-CocoIdentityModeDialog($Hint){
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='Identidad de Minecraft';$dialog.Size=New-Object Drawing.Size(520,250)
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.TopMost=$true
    $label=New-Object Windows.Forms.Label;$label.Location=New-Object Drawing.Point(25,22);$label.Size=New-Object Drawing.Size(455,92)
    $label.Text="Coco no encontro evidencia suficiente en este computador.`r`n`r`nMicrosoft verifica una licencia de Minecraft. Identidad local sirve solamente para servidores Coco offline."
    $microsoft=New-Object Windows.Forms.Button;$microsoft.Text='Continuar con Microsoft';$microsoft.Location=New-Object Drawing.Point(25,140);$microsoft.Size=New-Object Drawing.Size(210,38);$microsoft.Add_Click({$dialog.Tag='microsoft';$dialog.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Close()})
    $offline=New-Object Windows.Forms.Button;$offline.Text='Usar identidad local';$offline.Location=New-Object Drawing.Point(260,140);$offline.Size=New-Object Drawing.Size(210,38);$offline.Add_Click({$dialog.Tag='offline';$dialog.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Close()})
    $dialog.Controls.AddRange(@($label,$microsoft,$offline));$result=$dialog.ShowDialog($script:CocoForm);$choice=[string]$dialog.Tag;$dialog.Dispose()
    if($result-ne[Windows.Forms.DialogResult]::OK-or$choice-notin@('microsoft','offline')){throw 'La configuracion de identidad fue cancelada.'}
    $choice
}

function Show-CocoUsernameDialog([string]$Suggested=''){
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='Nombre local de Minecraft';$dialog.Size=New-Object Drawing.Size(430,205)
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.TopMost=$true
    $label=New-Object Windows.Forms.Label;$label.Location=New-Object Drawing.Point(22,20);$label.Size=New-Object Drawing.Size(370,45);$label.Text='Este nombre determina tu inventario y avances. Debe permanecer siempre igual.'
    $initialText=if(Test-CocoMinecraftUsername $Suggested){$Suggested}else{''}
    $txtUsername=New-Object Windows.Forms.TextBox;$txtUsername.Location=New-Object Drawing.Point(25,76);$txtUsername.Size=New-Object Drawing.Size(365,25);$txtUsername.Text=$initialText;$txtUsername.MaxLength=16
    $ok=New-Object Windows.Forms.Button;$ok.Text='Guardar';$ok.Location=New-Object Drawing.Point(235,118);$ok.Size=New-Object Drawing.Size(155,34)
    $ok.Add_Click({
        $rawVal=[string]$txtUsername.Text
        $cleanVal=[regex]::Replace($rawVal,'[^A-Za-z0-9_]','')
        if(Test-CocoMinecraftUsername $cleanVal){
            $dialog.Tag=$cleanVal
            $dialog.DialogResult=[Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }else{
            [Windows.Forms.MessageBox]::Show('Usa entre 3 y 16 letras, numeros o guion bajo.','Nombre invalido')|Out-Null
        }
    })
    $txtUsername.Add_KeyDown({
        param($s,$e)
        if($e.KeyCode -eq [Windows.Forms.Keys]::Enter){
            $e.SuppressKeyPress=$true
            $ok.PerformClick()
        }
    })
    $dialog.Controls.AddRange(@($label,$txtUsername,$ok));$result=$dialog.ShowDialog($script:CocoForm);$name=[string]$dialog.Tag;$dialog.Dispose()
    if($result-ne[Windows.Forms.DialogResult]::OK-or-not(Test-CocoMinecraftUsername $name)){throw 'La configuracion del nombre local fue cancelada.'}
    $name
}

function Select-CocoMicrosoftSessionDialog([object[]]$Sessions){
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='Cuenta Microsoft';$dialog.Size=New-Object Drawing.Size(430,210)
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.TopMost=$true
    $label=New-Object Windows.Forms.Label;$label.Text='Elige la cuenta de Minecraft para Coco:';$label.Location=New-Object Drawing.Point(22,22);$label.Size=New-Object Drawing.Size(370,25)
    $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';$combo.Location=New-Object Drawing.Point(25,58);$combo.Size=New-Object Drawing.Size(365,28)
    foreach($session in $Sessions){[void]$combo.Items.Add([string]$session.Username)};if($combo.Items.Count){$combo.SelectedIndex=0}
    $ok=New-Object Windows.Forms.Button;$ok.Text='Usar esta cuenta';$ok.Location=New-Object Drawing.Point(235,108);$ok.Size=New-Object Drawing.Size(155,34);$ok.Add_Click({if($combo.SelectedIndex-ge0){$dialog.Tag=$combo.SelectedIndex;$dialog.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Close()}})
    $dialog.Controls.AddRange(@($label,$combo,$ok));$result=$dialog.ShowDialog($script:CocoForm);$index=if($null-ne$dialog.Tag){[int]$dialog.Tag}else{-1};$dialog.Dispose()
    if($result-ne[Windows.Forms.DialogResult]::OK-or$index-lt0){throw 'La seleccion de cuenta Microsoft fue cancelada.'}
    $Sessions[$index]
}

function Resolve-CocoLauncherIdentityUi($Catalog,[string]$LegacyMinecraftRoot,$Paths,[int]$PromptStage=3,[int]$PromptProgress=24){
    $state=Read-CocoLauncherIdentityState $Paths.IdentityPath
    if($state.mode-eq'offline'){return $state}
    Set-CocoState 'Verificando cuenta Microsoft' 'Buscando una sesion Coco ya autorizada...' 20
    $backend=Install-CocoLauncherBackend $Catalog $Paths.CacheRoot
    New-Item -ItemType Directory -Path (Split-Path $Paths.AccountDb -Parent),$Paths.MainDir -Force|Out-Null
    $sessions=@(Get-CocoPortableMcAuthSessions $backend $Paths.MainDir $Paths.AccountDb)
    $completion=Complete-CocoMicrosoftIdentityFromSessions $Paths.IdentityPath $sessions
    if($completion.Status-eq'configured'){return $completion.Identity}
    if($completion.Status-eq'account-choice-required'){
        $selected=Select-CocoMicrosoftSessionDialog $completion.Sessions
        return Save-CocoLauncherIdentityState $Paths.IdentityPath microsoft $selected.Username $selected.Uuid 'portablemc-account-choice'
    }
    Set-CocoState 'Inicia sesion con Microsoft' 'Abriendo el navegador oficial para autenticar con Microsoft...' 24
    $authLog=Join-Path $Paths.CacheRoot ("logs\launcher-auth-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
    $auth=Start-CocoPortableMcGame $backend @('--main-dir',$Paths.MainDir,'--msa-db-file',$Paths.AccountDb,'--output','human','auth','login') $authLog
    $authFailure=''
    $browserOpened=$false
    try{
        while(-not$auth.HasExited){
            [Windows.Forms.Application]::DoEvents()
            if(-not$browserOpened -and (Test-Path -LiteralPath $authLog)){
                $logText=Get-Content -LiteralPath $authLog -Raw -ErrorAction SilentlyContinue
                if($logText -and $logText -match 'https?://\S+'){
                    $url=$matches[0].TrimEnd('.', ',', ')', '"', "'")
                    try{Start-Process $url; $browserOpened=$true}catch{}
                }
                if($logText -and $logText -match 'code\s+([A-Z0-9]{6,12})'){
                    $code=$matches[1]
                    Set-CocoState 'Inicia sesion con Microsoft' ("Ingresa el codigo {0} en tu navegador ({1})" -f $code, $url) 24
                }
            }
            Start-Sleep -Milliseconds 150
        }
        if($auth.ExitCode-ne0){$authFailure=if(Test-Path $authLog){(Get-Content $authLog -Tail 25)-join' '}else{'Microsoft no completo el login.'}}
    }finally{$auth.Dispose()}
    if($authFailure){
        $fallback=[Windows.Forms.MessageBox]::Show("Microsoft no completo el acceso o la cuenta no posee Minecraft Java.`r`n`r`n¿Quieres elegir explicitamente una identidad local para los servidores Coco?",'Cuenta Microsoft',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning)
        if($fallback-eq[Windows.Forms.DialogResult]::Yes){return Save-CocoLauncherIdentityState $Paths.IdentityPath offline (Show-CocoUsernameDialog ([string]$state.username)) '' 'explicit-fallback-after-microsoft'}
        throw "Microsoft no completo el login. $authFailure"
    }
    $sessions=@(Get-CocoPortableMcAuthSessions $backend $Paths.MainDir $Paths.AccountDb)
    $completion=Complete-CocoMicrosoftIdentityFromSessions $Paths.IdentityPath $sessions
    if($completion.Status-eq'configured'){return $completion.Identity}
    if($completion.Sessions.Count){$selected=Select-CocoMicrosoftSessionDialog $completion.Sessions;return Save-CocoLauncherIdentityState $Paths.IdentityPath microsoft $selected.Username $selected.Uuid 'portablemc-account-choice'}
    throw 'Microsoft termino el flujo, pero no entrego una cuenta que posea Minecraft Java.'
}
#>

function Set-CocoFlatButtonStyle($Button,[Drawing.Color]$BackColor,[Drawing.Color]$ForeColor){
    $Button.FlatStyle=[Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize=0
    $Button.BackColor=$BackColor
    $Button.ForeColor=$ForeColor
    $Button.Cursor=[Windows.Forms.Cursors]::Hand
    $scale=if($script:CocoUiScale){[double]$script:CocoUiScale}else{1.0}
    $fontSize=[single][Math]::Max(7,[Math]::Round(9*$scale,1))
    $Button.Font=New-Object Drawing.Font('Segoe UI Semibold',$fontSize)
    $Button.UseCompatibleTextRendering=$false
}

function Get-CocoLauncherUiMetric([double]$Value){
    $scale=if($script:CocoUiScale){[double]$script:CocoUiScale}else{1.0}
    return [int][Math]::Round($Value*$scale)
}

function Get-CocoLauncherUiFontSize([double]$Value,[double]$Minimum=6){
    $scale=if($script:CocoUiScale){[double]$script:CocoUiScale}else{1.0}
    return [single][Math]::Max($Minimum,[Math]::Round($Value*$scale,1))
}

function Set-CocoControlDoubleBuffered($Control){
    if(-not$Control){return}
    try{
        $flags=[Reflection.BindingFlags]::Instance-bor[Reflection.BindingFlags]::NonPublic-bor[Reflection.BindingFlags]::FlattenHierarchy
        $property=$Control.GetType().GetProperty('DoubleBuffered',$flags)
        if($property-and$property.CanWrite){$property.SetValue($Control,$true,$null)}
    }catch{}
}

function Get-CocoExperienceImagePath($Experience){
    $engineRoot=[string]$script:CocoEngineRoot
    if([string]::IsNullOrWhiteSpace($engineRoot)){return ''}
    $configured=if($Experience-and$Experience.ui){[string]$Experience.ui.imagePath}else{''}
    if(-not[string]::IsNullOrWhiteSpace($configured)-and(Test-CocoSafeRelativePath $configured)){
        $candidate=Join-Path $engineRoot ($configured-replace'/','\')
        if(Test-Path -LiteralPath $candidate -PathType Leaf){return $candidate}
    }
    $fallback=Join-Path $engineRoot 'assets\fullbody.png'
    if(Test-Path -LiteralPath $fallback -PathType Leaf){return $fallback}
    return ''
}

function Set-CocoPictureBoxImage($Picture,[string]$Path){
    if($Picture-and-not$Picture.IsDisposed){
        try{
            if($Picture.Image){$old=$Picture.Image;$Picture.Image=$null;$old.Dispose()}
            if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){return}
            $bytes=[IO.File]::ReadAllBytes($Path);$stream=$null;$source=$null
            try{
                $stream=[IO.MemoryStream]::new($bytes,$false)
                $source=[Drawing.Image]::FromStream($stream,$true,$true)
                [void]($Picture.Image=[Drawing.Bitmap]::new($source))
            }finally{
                if($source){$source.Dispose()}
                if($stream){$stream.Dispose()}
            }
        }catch{}
    }
}

function Set-CocoPictureBoxCoverImage($Picture,[string]$Path,[int]$TargetWidth,[int]$TargetHeight){
    if($Picture-and-not$Picture.IsDisposed){
        try{
            if($Picture.Image){$old=$Picture.Image;$Picture.Image=$null;$old.Dispose()}
            if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){return}
            $width=[Math]::Max(1,$TargetWidth);$height=[Math]::Max(1,$TargetHeight)
            if(-not $script:CocoCoverImageCache){$script:CocoCoverImageCache=@{}}
            $cacheKey="$Path|$width|$height"
            $cached=$script:CocoCoverImageCache[$cacheKey]
            if($cached){
                try{
                    $Picture.SizeMode=[Windows.Forms.PictureBoxSizeMode]::Normal
                    $Picture.Image=New-Object Drawing.Bitmap $cached
                    return
                }catch{$script:CocoCoverImageCache.Remove($cacheKey)}
            }
            $bytes=[IO.File]::ReadAllBytes($Path);$stream=$null;$source=$null;$bitmap=$null;$graphics=$null
            try{
                $stream=[IO.MemoryStream]::new($bytes,$false)
                $source=[Drawing.Image]::FromStream($stream,$true,$true)
                $bitmap=New-Object Drawing.Bitmap($width,$height)
                $graphics=[Drawing.Graphics]::FromImage($bitmap)
                $graphics.Clear([Drawing.Color]::FromArgb(30,20,42))
                $sourceWidth=[Math]::Max(1,[int]$source.Width);$sourceHeight=[Math]::Max(1,[int]$source.Height)
                $scale=[Math]::Max($width/[double]$sourceWidth,$height/[double]$sourceHeight)
                $drawWidth=[int][Math]::Ceiling($sourceWidth*$scale);$drawHeight=[int][Math]::Ceiling($sourceHeight*$scale)
                $drawX=[int](($width-$drawWidth)/2);$drawY=[int](($height-$drawHeight)/2)
                $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.CompositingQuality=[Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.DrawImage($source,(New-Object Drawing.Rectangle($drawX,$drawY,$drawWidth,$drawHeight)),(New-Object Drawing.Rectangle(0,0,$sourceWidth,$sourceHeight)),[Drawing.GraphicsUnit]::Pixel)
                $script:CocoCoverImageCache[$cacheKey]=$bitmap
                $Picture.SizeMode=[Windows.Forms.PictureBoxSizeMode]::Normal
                $Picture.Image=New-Object Drawing.Bitmap $bitmap
                $bitmap=$null
            }finally{
                if($graphics){$graphics.Dispose()}
                if($bitmap){$bitmap.Dispose()}
                if($source){$source.Dispose()}
                if($stream){$stream.Dispose()}
            }
        }catch{}
    }
}

function Format-CocoExperienceCardTitle([string]$Text,[int]$MaximumLineLength=27){
    if([string]::IsNullOrWhiteSpace($Text)){return ''}
    $words=$Text.Trim()-split'\s+'
    $lines=New-Object Collections.Generic.List[string]
    $current=''
    foreach($word in $words){
        $candidate=if([string]::IsNullOrWhiteSpace($current)){$word}else{"$current $word"}
        if($candidate.Length-le$MaximumLineLength-or[string]::IsNullOrWhiteSpace($current)){$current=$candidate;continue}
        [void]$lines.Add($current);$current=$word
        if($lines.Count-eq2){break}
    }
    if($lines.Count-lt2-and-not[string]::IsNullOrWhiteSpace($current)){[void]$lines.Add($current)}
    $consumed=($lines|ForEach-Object{$_})-join' '
    if($consumed.Length-lt$Text.Trim().Length-and$lines.Count-ge2){$lines[1]="$($lines[1])..."}
    return ($lines|Select-Object -First 2)-join"`r`n"
}

# V4 del scroll de experiencias. El viewport usa exclusivamente el
# AutoScroll nativo de WinForms y su única barra nativa (sin thumb superpuesto).
# La rueda reenvía cada notch al mismo VerticalScroll.Value nativo en un set
# directo e inmediato, igual que la barra: sin animaciones ni deslizamientos.
function Set-CocoExperienceCardsNativeScrollStyle($DynamicPanel){
    if(-not$DynamicPanel-or$DynamicPanel.IsDisposed){return}
    try{
        Set-CocoControlDoubleBuffered $DynamicPanel
        try{$DynamicPanel.BackColor=[Drawing.Color]::FromArgb(22,13,34)}catch{}
    }catch{}
}

function Get-CocoExperienceCardsNativeMaximum($DynamicPanel,[int]$FallbackMaximum=0){
    $nativeMaximum=0
    try{
        $nativeMaximum=[Math]::Max(0,[int]$DynamicPanel.VerticalScroll.Maximum-[int]$DynamicPanel.VerticalScroll.LargeChange+1)
    }catch{}
    if($nativeMaximum-le0){$nativeMaximum=[Math]::Max(0,$FallbackMaximum)}
    $nativeMaximum
}

function Get-CocoExperienceCardsScrollState($DynamicPanel,[bool]$Create=$true){
    if(-not$DynamicPanel-or$DynamicPanel.IsDisposed){return $null}
    $state=$null
    if($DynamicPanel.PSObject.Properties.Name-contains'CocoExperienceScrollState'){$state=$DynamicPanel.CocoExperienceScrollState}
    if(-not$state-and$Create){
        $state=[pscustomobject]@{
            ModelVersion=4;DynamicPanel=$DynamicPanel;Offset=0;PendingOffset=0;TargetOffset=0
            ContentHeight=0;ViewHeight=0;Maximum=0;Items=@();LastWheelAt=0
            Thumb=[Drawing.Rectangle]::new(0,0,0,0);ScrollBar=$null;ApplyTimer=$null
            WheelCarry=0.0
            Drag=[pscustomobject]@{Active=$false;StartScreenY=0;StartValue=0;Travel=1;PendingValue=0}
        }
        $DynamicPanel|Add-Member -MemberType NoteProperty -Name CocoExperienceScrollState -Value $state -Force|Out-Null
    }
    if(-not$state){return $null}
    # Conserva compatibilidad con estados creados por versiones anteriores.
    foreach($property in 'ModelVersion','DynamicPanel','PendingOffset','TargetOffset','LastWheelAt','Thumb','ScrollBar','ApplyTimer','WheelCarry','Drag'){
        if($state.PSObject.Properties.Name-notcontains$property){
            $value=switch($property){
                'ModelVersion'{4};'DynamicPanel'{$DynamicPanel};'PendingOffset'{[int]$state.Offset}
                'TargetOffset'{[int]$state.Offset};'LastWheelAt'{0};'Thumb'{[Drawing.Rectangle]::new(0,0,0,0)}
                'ScrollBar'{$null};'ApplyTimer'{$null}
                'WheelCarry'{0.0}
                'Drag'{[pscustomobject]@{Active=$false;StartScreenY=0;StartValue=0;Travel=1;PendingValue=0}}
            }
            $state|Add-Member NoteProperty $property $value -Force
        }
    }
    $state.ModelVersion=4
    $state.DynamicPanel=$DynamicPanel
    foreach($property in 'Active','StartScreenY','StartValue','Travel','PendingValue'){
        if($state.Drag.PSObject.Properties.Name-notcontains$property){
            $default=if($property-eq'Travel'){1}else{0}
            $state.Drag|Add-Member NoteProperty $property $default -Force
        }
    }
    $state
}

function Get-CocoExperienceCardsScrollMetrics($DynamicPanel){
    $state=Get-CocoExperienceCardsScrollState $DynamicPanel
    if(-not$state){return [pscustomobject]@{ContentHeight=1;ViewHeight=1;Maximum=0;Value=0}}
    $contentHeight=[Math]::Max(1,[int]$state.ContentHeight)
    $viewHeight=[Math]::Max(1,[int]$DynamicPanel.ClientSize.Height)
    $fallbackMaximum=[Math]::Max(0,$contentHeight-$viewHeight)
    $maximum=Get-CocoExperienceCardsNativeMaximum $DynamicPanel $fallbackMaximum
    $value=0
    try{$value=[Math]::Max(0,[Math]::Min($maximum,[int]$DynamicPanel.VerticalScroll.Value))}catch{$value=[Math]::Max(0,[Math]::Min($maximum,[int]$state.Offset))}
    $state.ViewHeight=$viewHeight;$state.Maximum=$maximum;$state.Offset=$value
    $state.PendingOffset=[Math]::Max(0,[Math]::Min($maximum,[int]$state.PendingOffset))
    $state.TargetOffset=[Math]::Max(0,[Math]::Min($maximum,[int]$state.TargetOffset))
    [pscustomobject]@{ContentHeight=$contentHeight;ViewHeight=$viewHeight;Maximum=$maximum;Value=$value}
}

function Update-CocoExperienceCardsScrollBar($DynamicPanel){
    if(-not$DynamicPanel-or$DynamicPanel.IsDisposed){return}
    # Limpia cualquier overlay viejo que haya quedado en una instancia
    # reutilizada; el scroll nuevo no crea controles hermanos.
    if($DynamicPanel.Parent){
        foreach($legacyBar in @($DynamicPanel.Parent.Controls|Where-Object{$_.Name-eq'CocoLauncherScrollBar'})){
            try{$DynamicPanel.Parent.Controls.Remove($legacyBar);$legacyBar.Dispose()}catch{}
        }
    }
    $state=Get-CocoExperienceCardsScrollState $DynamicPanel
    if(-not$state){return}
    try{
        $metrics=Get-CocoExperienceCardsScrollMetrics $DynamicPanel
        $state.Offset=[int]$metrics.Value;$state.PendingOffset=[int]$metrics.Value;$state.TargetOffset=[int]$metrics.Value
        $state.ScrollBar=$null;$state.Thumb=[Drawing.Rectangle]::new(0,0,0,0)
    }catch{}
}

function Set-CocoExperienceCardsScrollOffset($DynamicPanel,[int]$Offset,[bool]$SyncTarget=$true,[bool]$ForcePaint=$false){
    $state=Get-CocoExperienceCardsScrollState $DynamicPanel
    if(-not$state-or$DynamicPanel.IsDisposed){return}
    try{
        if(-not$DynamicPanel.AutoScroll){$DynamicPanel.AutoScroll=$true}
        $DynamicPanel.PerformLayout()
    }catch{}
    $metrics=Get-CocoExperienceCardsScrollMetrics $DynamicPanel
    $clamped=[Math]::Max(0,[Math]::Min([int]$metrics.Maximum,[int]$Offset))
    $current=try{[int]$DynamicPanel.VerticalScroll.Value}catch{[int]$state.Offset}
    if($clamped-eq$current){
        $state.Offset=$clamped
        if($SyncTarget){$state.PendingOffset=$clamped;$state.TargetOffset=$clamped}
        if($clamped-eq 0){
            $surface=@($state.Items|Where-Object{$_.Control-and-not$_.Control.IsDisposed}|Select-Object -First 1)[0]
            if($surface-and$surface.Control-and$surface.Control.Top-ne 0){
                try{
                    $DynamicPanel.AutoScroll=$false
                    $surface.Control.Location=[Drawing.Point]::new(0,0)
                    $DynamicPanel.AutoScroll=$true
                    $DynamicPanel.AutoScrollPosition=[Drawing.Point]::new(0,0)
                }catch{}
            }
        }
        return
    }
    try{
        $DynamicPanel.AutoScrollPosition=[Drawing.Point]::new(0,$clamped)
        $DynamicPanel.VerticalScroll.Value=$clamped
    }catch{
        try{$DynamicPanel.VerticalScroll.Value=$clamped}catch{}
    }
    try{$DynamicPanel.PerformLayout()}catch{}
    $actual=try{[int]$DynamicPanel.VerticalScroll.Value}catch{[int]$clamped}
    if($clamped-eq 0 -and $actual-ne 0){
        try{
            $DynamicPanel.AutoScroll=$false
            $DynamicPanel.VerticalScroll.Value=0
            $surface=@($state.Items|Where-Object{$_.Control-and-not$_.Control.IsDisposed}|Select-Object -First 1)[0]
            if($surface-and$surface.Control){$surface.Control.Location=[Drawing.Point]::new(0,0)}
            $DynamicPanel.AutoScroll=$true
            $DynamicPanel.AutoScrollPosition=[Drawing.Point]::new(0,0)
            $actual=0
        }catch{}
    }
    $state.Offset=[Math]::Max(0,[Math]::Min([int]$metrics.Maximum,$actual))
    try{
        $DynamicPanel.Invalidate($true)
        $DynamicPanel.Update()
    }catch{}
}

function Queue-CocoExperienceCardsScrollOffset($DynamicPanel,[int]$Offset){
    Set-CocoExperienceCardsScrollOffset $DynamicPanel $Offset $true $false
}

function Start-CocoExperienceCardsScrollAnimation($DynamicPanel){
    $state=Get-CocoExperienceCardsScrollState $DynamicPanel
    if($state){Set-CocoExperienceCardsScrollOffset $DynamicPanel ([int]$state.TargetOffset) $true $false}
}

function Set-CocoExperienceCardsScrollContent($DynamicPanel,[int]$ContentHeight){
    $state=Get-CocoExperienceCardsScrollState $DynamicPanel
    if(-not$state){return}
    $state.ContentHeight=[Math]::Max(1,[int]$ContentHeight);$state.ViewHeight=[Math]::Max(1,[int]$DynamicPanel.ClientSize.Height)
    $state.Maximum=[Math]::Max(0,[int]$state.ContentHeight-[int]$state.ViewHeight);$state.Offset=0;$state.PendingOffset=0;$state.TargetOffset=0;$state.Drag.Active=$false
    $state.WheelCarry=0.0
    $state.Items=@()
    foreach($control in @($DynamicPanel.Controls)){$state.Items+=,[pscustomobject]@{Control=$control;X=[int]$control.Left;Y=[int]$control.Top}}
    try{
        $DynamicPanel.AutoScroll=$false
        $DynamicPanel.VerticalScroll.Value=0
        $DynamicPanel.HorizontalScroll.Value=0
        $surface=@($state.Items|Where-Object{$_.Control-and-not$_.Control.IsDisposed}|Select-Object -First 1)[0]
        if($surface-and$surface.Control){
            $surface.Control.Width=[Math]::Max(1,[int]$DynamicPanel.ClientSize.Width)
            $surface.Control.Location=[Drawing.Point]::new(0,0)
        }
        $DynamicPanel.AutoScrollMinSize=[Drawing.Size]::new(0,[int]$state.ContentHeight)
        $DynamicPanel.AutoScroll=$true
        $DynamicPanel.AutoScrollPosition=[Drawing.Point]::new(0,0)
        $DynamicPanel.HorizontalScroll.Enabled=$false;$DynamicPanel.HorizontalScroll.Visible=$false
        $DynamicPanel.PerformLayout()
    }catch{}
    Set-CocoExperienceCardsScrollOffset $DynamicPanel 0 $true $false
}

function Register-CocoExperienceScrollWheel($Control,$DynamicPanel){
    if(-not$Control-or$Control.IsDisposed-or-not$DynamicPanel-or$DynamicPanel.IsDisposed){return}
    # Puente de rueda DIRECTO (sin animación): cada notch mueve el mismo
    # VerticalScroll.Value nativo que usa la barra, en un solo set inmediato.
    # La propagación nativa sola solo responde si el foco está dentro del
    # viewport; PictureBox/Button/Label la consumen antes, por eso se reenvía.
    # La raíz usa marcador propio (NoteProperty) para no pisar el marcador de
    # Resize que vive en AccessibleName; duplicarlo re-registraba handlers.
    $isRoot=$Control -eq $DynamicPanel
    $bound=$false
    if($isRoot){try{$bound=[bool]$Control.PSObject.Properties['CocoExperienceWheelBoundV4']-and[bool]$Control.CocoExperienceWheelBoundV4}catch{$bound=$false}}
    else{$bound=([string]$Control.AccessibleName-eq'CocoLauncherNativeWheelBoundV4')}
    if(-not$bound){
        if($isRoot){try{$Control|Add-Member -MemberType NoteProperty -Name CocoExperienceWheelBoundV4 -Value $true -Force|Out-Null}catch{}}
        else{$Control.AccessibleName='CocoLauncherNativeWheelBoundV4'}
        # Los closures de eventos corren en un session-state aislado: las
        # funciones del engine NO se resuelven por nombre ahí dentro (muerte
        # silenciosa con la rueda marcada como manejada = rueda muerta). Se
        # capturan los ScriptBlocks por valor, patrón probado en los botones.
        $getStateCommand=(Get-Command Get-CocoExperienceCardsScrollState -CommandType Function -ErrorAction Stop).ScriptBlock
        $getMetricsCommand=(Get-Command Get-CocoExperienceCardsScrollMetrics -CommandType Function -ErrorAction Stop).ScriptBlock
        $setOffsetCommand=(Get-Command Set-CocoExperienceCardsScrollOffset -CommandType Function -ErrorAction Stop).ScriptBlock
        $Control.Add_MouseWheel(({
            param($sender,$eventArgs)
            try{
                # Marcar manejado ANTES de mover: si lo nativo también se mueve
                # en el mismo mensaje el salto se duplica y se pega.
                try{if($eventArgs.PSObject.Properties.Name-contains'Handled'){$eventArgs.Handled=$true}}catch{}
                $s=&$getStateCommand $DynamicPanel $false
                $delta=[int]$eventArgs.Delta
                if(-not$s-or$delta-eq0-or$DynamicPanel.IsDisposed){return}
                $m=&$getMetricsCommand $DynamicPanel
                if([int]$m.Maximum-le0){return}
                $lines=try{[int][Windows.Forms.SystemInformation]::MouseWheelScrollLines}catch{3}
                if($lines-le0){$lines=3}
                $unit=[Math]::Max(24.0,([double]$DynamicPanel.ClientSize.Height/12.0*([double]$lines/3.0)))
                # Acumular fracciones: las ruedas de alta resolución mandan
                # deltas pequeños que sueltos se perderían.
                $s.WheelCarry+=[double]$delta
                $move=[int][Math]::Truncate($s.WheelCarry/120.0*$unit)
                if($move-eq0){return}
                $s.WheelCarry-=[double]$move*120.0/$unit
                $live=[int]$m.Value
                $next=[Math]::Max(0,[Math]::Min([int]$m.Maximum,($live-$move)))
                if($next-eq$live){$s.WheelCarry=0.0;return}
                &$setOffsetCommand $DynamicPanel $next
            }catch{}
        }.GetNewClosure()))
    }
    foreach($child in @($Control.Controls)){Register-CocoExperienceScrollWheel $child $DynamicPanel}
}

function Register-CocoNativeScrollWheel($Control,$Viewport){
    # Viewports con AutoScroll nativo ya procesan la rueda a través de DefWindowProc.
}

function Set-CocoExperienceCardsScrollBehavior($DynamicPanel){
    if(-not$DynamicPanel-or$DynamicPanel.IsDisposed){return}
    $DynamicPanel.AccessibleDescription='CocoLauncherNativeScrollViewportV4'
    $DynamicPanel.AutoScroll=$true
    $DynamicPanel.HorizontalScroll.Enabled=$false
    $DynamicPanel.HorizontalScroll.Visible=$false
    # Activa el doble búfer del viewport sin tocar HWND de scroll.
    try{Set-CocoExperienceCardsNativeScrollStyle $DynamicPanel}catch{}
    $state=Get-CocoExperienceCardsScrollState $DynamicPanel
    $state.ScrollBar=$null;$state.ApplyTimer=$null
    if($DynamicPanel.Parent){
        foreach($legacyBar in @($DynamicPanel.Parent.Controls|Where-Object{$_.Name-eq'CocoLauncherScrollBar'})){
            try{$DynamicPanel.Parent.Controls.Remove($legacyBar);$legacyBar.Dispose()}catch{}
        }
    }
    if([string]$DynamicPanel.AccessibleName-ne'CocoLauncherNativeResizeBoundV4'){
        $DynamicPanel.AccessibleName='CocoLauncherNativeResizeBoundV4'
        # Captura por valor: el closure no resuelve funciones por nombre.
        $updateBarCommand=(Get-Command Update-CocoExperienceCardsScrollBar -CommandType Function -ErrorAction Stop).ScriptBlock
        $DynamicPanel.Add_Resize(({
            param($sender,$eventArgs)
            try{$sender.AutoScroll=$true;$sender.HorizontalScroll.Enabled=$false;$sender.HorizontalScroll.Visible=$false;$sender.PerformLayout();&$updateBarCommand $sender}catch{}
        }.GetNewClosure()))
    }
    Update-CocoExperienceCardsScrollBar $DynamicPanel
}

function Set-CocoLauncherUiLayout {
    if(-not$script:CocoForm-or-not$script:CocoPanel){return}
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $targetScreen=try{[Windows.Forms.Screen]::FromControl($script:CocoForm)}catch{[Windows.Forms.Screen]::PrimaryScreen}
    if(-not$targetScreen){$targetScreen=[Windows.Forms.Screen]::PrimaryScreen}
    $work=$targetScreen.WorkingArea
    # El launcher reserva mas ancho para una grilla de dos columnas. La escala
    # baja de forma proporcional en pantallas pequenas para que nunca recorte
    # el contenido ni obligue a usar scroll horizontal.
    $scale=[Math]::Min(1.0,[Math]::Min($work.Width/1440.0,$work.Height/900.0))
    $script:CocoUiScale=$scale
    $metric={param([double]$value)[int][Math]::Round($value*$scale)}
    $form=$script:CocoForm;$panel=$script:CocoPanel
    $form.SuspendLayout();$panel.SuspendLayout()
    try{
        $formWidth=(&$metric 1440)
        $formHeight=(&$metric 900)
        $form.StartPosition=[Windows.Forms.FormStartPosition]::Manual
        $form.Size=New-Object Drawing.Size($formWidth,$formHeight)
        $formX=[int]($work.Left+[Math]::Max(0,($work.Width-$formWidth)/2))
        $formY=[int]($work.Top+[Math]::Max(0,($work.Height-$formHeight)/2))
        $form.Location=New-Object Drawing.Point($formX,$formY)
        $panelWidth=(&$metric 900)
        $panelHeight=(&$metric 870)
        $art=@($form.Controls|Where-Object{$_-is[Windows.Forms.PictureBox]-and$_.Parent-eq$form}|Select-Object -First 1)[0]
        $artWidth=if($art){(&$metric 460)}else{0}
        $artHeight=if($art){(&$metric 880)}else{0}
        $gap=if($art){(&$metric 25)}else{0}
        $totalVisibleWidth=$panelWidth+$gap+$artWidth
        $contentLeftMargin=[Math]::Max(10,[int](($formWidth-$totalVisibleWidth)/2))
        $panel.Location=New-Object Drawing.Point($contentLeftMargin,(&$metric 25))
        $panel.Size=New-Object Drawing.Size($panelWidth,$panelHeight)
        if($script:CocoAccent){$script:CocoAccent.Location=New-Object Drawing.Point(0,0);$script:CocoAccent.Size=New-Object Drawing.Size((&$metric 9),$panel.ClientSize.Height)}
        if($script:CocoTitle){$script:CocoTitle.Location=New-Object Drawing.Point((&$metric 43),(&$metric 32));$script:CocoTitle.Size=New-Object Drawing.Size((&$metric 680),(&$metric 34))}
        if($script:CocoDetail){$script:CocoDetail.Location=New-Object Drawing.Point((&$metric 46),(&$metric 76));$script:CocoDetail.Size=New-Object Drawing.Size((&$metric 840),(&$metric 44))}
        if($script:CocoTrack){$script:CocoTrack.Location=New-Object Drawing.Point((&$metric 46),(&$metric 128));$script:CocoTrack.Size=New-Object Drawing.Size((&$metric 840),(&$metric 20))}
        if($script:CocoProgress){$script:CocoProgress.Location=New-Object Drawing.Point(0,0);$script:CocoProgress.Height=(&$metric 20)}
        if($script:CocoBrand){$script:CocoBrand.Location=New-Object Drawing.Point((&$metric 46),(&$metric 153));$script:CocoBrand.Size=New-Object Drawing.Size((&$metric 840),(&$metric 20))}
        if($art){$art.Location=New-Object Drawing.Point(($contentLeftMargin+$panelWidth+$gap),(&$metric 5));$art.Size=New-Object Drawing.Size($artWidth,$artHeight)}
        foreach($control in @($panel.Controls)){
            if($control.Tag-eq'CocoLauncherDynamic'){
                $control.Location=New-Object Drawing.Point((&$metric 46),(&$metric 190));$control.Size=New-Object Drawing.Size((&$metric 840),(&$metric 660))
            }
        }
        if($script:CocoSkinTile-and-not$script:CocoSkinTile.IsDisposed){
            $script:CocoSkinTile.Location=New-Object Drawing.Point((&$metric 500),(&$metric 34));$script:CocoSkinTile.Size=New-Object Drawing.Size((&$metric 315),(&$metric 92))
        }
        if($script:CocoHostForceButton-and-not$script:CocoHostForceButton.IsDisposed){
            $script:CocoHostForceButton.Size=New-Object Drawing.Size((&$metric 170),(&$metric 28))
            $script:CocoHostForceButton.Location=New-Object Drawing.Point((&$metric 564),(&$metric 2))
        }
        if($script:CocoIdentityButton-and-not$script:CocoIdentityButton.IsDisposed){
            $script:CocoIdentityButton.Size=New-Object Drawing.Size((&$metric 74),(&$metric 28));$script:CocoIdentityButton.Location=New-Object Drawing.Point((&$metric 742),(&$metric 2))
        }
        if($script:CocoLauncherMinimizeButton-and-not$script:CocoLauncherMinimizeButton.IsDisposed){
            $script:CocoLauncherMinimizeButton.Size=New-Object Drawing.Size((&$metric 34),(&$metric 28))
            $script:CocoLauncherMinimizeButton.Location=New-Object Drawing.Point((&$metric 820),(&$metric 2))
        }
        if($script:CocoLauncherCloseButton-and-not$script:CocoLauncherCloseButton.IsDisposed){
            $script:CocoLauncherCloseButton.Size=New-Object Drawing.Size((&$metric 34),(&$metric 28))
            $script:CocoLauncherCloseButton.Location=New-Object Drawing.Point((&$metric 858),(&$metric 2))
        }
    }finally{$panel.ResumeLayout();$form.ResumeLayout();$form.Refresh();[Windows.Forms.Application]::DoEvents()}
    $script:CocoLauncherLayout=[pscustomobject]@{Scale=$scale;PanelWidth=900;PanelHeight=870;DynamicTop=190;DynamicWidth=840;DynamicHeight=660;IdentityTop=-1;FooterTop=-1}
}

function Set-CocoSkinTilePreview($Picture,$Label,[string]$SkinRoot,[string]$Username,[bool]$Pending=$false){
    if($Picture.Image){$old=$Picture.Image;$Picture.Image=$null;$old.Dispose()}
    $path=if(Test-CocoMinecraftUsername $Username){Join-Path $SkinRoot "$Username.png"}else{''}
    if($path-and(Test-Path -LiteralPath $path -PathType Leaf)){
        $Picture.Image=New-CocoSkinHeadPreview $path ([Math]::Max(1,[Math]::Min([int]$Picture.Width,[int]$Picture.Height)))
        $Label.Text=if($Pending){"SE SINCRONIZARA AL JUGAR`r`nCLIC O ARRASTRA PARA CAMBIAR"}else{"CLIC O ARRASTRA UN PNG`r`nPARA CAMBIARLA"}
    }else{$Label.Text="CLIC O ARRASTRA UN PNG`r`nPARA ELEGIRLA"}
}

function Show-CocoUsernamePanel([string]$Suggested='',[switch]$AllowCancel){
    if(-not$script:CocoForm-or-not$script:CocoPanel){throw 'La interfaz Coco no esta disponible para configurar el jugador.'}
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $initial=if(Test-CocoMinecraftUsername $Suggested){$Suggested}else{''}
    $overlay=New-Object Windows.Forms.Panel
    $overlay.Name='CocoUsernamePanel';$overlay.Location=New-Object Drawing.Point(28,292);$overlay.Size=New-Object Drawing.Size(584,150)
    $overlay.BackColor=[Drawing.Color]::FromArgb(36,22,57)
    $edge=New-Object Windows.Forms.Panel;$edge.Location=New-Object Drawing.Point(0,0);$edge.Size=New-Object Drawing.Size(5,150);$edge.BackColor=[Drawing.Color]::FromArgb(177,92,255)
    $heading=New-Object Windows.Forms.Label;$heading.Text='TU NOMBRE EN COCO';$heading.Location=New-Object Drawing.Point(22,14);$heading.Size=New-Object Drawing.Size(535,25)
    $heading.Font=New-Object Drawing.Font('Segoe UI Semibold',12);$heading.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $nameBox=New-Object Windows.Forms.TextBox;$nameBox.Location=New-Object Drawing.Point(24,52);$nameBox.Size=New-Object Drawing.Size(300,27)
    $nameBox.Text=$initial;$nameBox.MaxLength=16;$nameBox.Font=New-Object Drawing.Font('Segoe UI',11);$nameBox.BorderStyle='FixedSingle'
    $validation=New-Object Windows.Forms.Label;$validation.Location=New-Object Drawing.Point(24,84);$validation.Size=New-Object Drawing.Size(310,28)
    $validation.Font=New-Object Drawing.Font('Segoe UI',8.5);$validation.ForeColor=[Drawing.Color]::FromArgb(255,139,151)
    $save=New-Object Windows.Forms.Button;$save.Text='GUARDAR JUGADOR';$save.Location=New-Object Drawing.Point(367,50);$save.Size=New-Object Drawing.Size(188,38)
    Set-CocoFlatButtonStyle $save ([Drawing.Color]::FromArgb(177,92,255)) ([Drawing.Color]::White)
    $cancel=$null
    if($AllowCancel){
        $cancel=New-Object Windows.Forms.Button;$cancel.Text='CANCELAR';$cancel.Location=New-Object Drawing.Point(367,93);$cancel.Size=New-Object Drawing.Size(188,27)
        Set-CocoFlatButtonStyle $cancel ([Drawing.Color]::FromArgb(58,36,81)) ([Drawing.Color]::FromArgb(218,210,229))
    }
    $script:CocoUsernameChoice=''
    $script:CocoUsernameCancelled=$false
    $validate={
        $candidate=([string]$nameBox.Text).Trim()
        $valid=Test-CocoMinecraftUsername $candidate
        $save.Enabled=$valid
        $validation.Text=if($valid){'Nombre valido.'}else{'Usa 3-16 letras, numeros o guion bajo.'}
        $validation.ForeColor=if($valid){[Drawing.Color]::FromArgb(78,214,132)}else{[Drawing.Color]::FromArgb(255,139,151)}
    }
    $nameBox.Add_TextChanged($validate)
    $save.Add_Click({
        $candidate=([string]$nameBox.Text).Trim()
        if(Test-CocoMinecraftUsername $candidate){$script:CocoUsernameChoice=$candidate}
    })
    if($cancel){$cancel.Add_Click({$script:CocoUsernameCancelled=$true})}
    $nameBox.Add_KeyDown({
        param($sender,$eventArgs)
        if($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Enter-and$save.Enabled){$eventArgs.SuppressKeyPress=$true;$save.PerformClick()}
        elseif($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Escape-and$AllowCancel){$eventArgs.SuppressKeyPress=$true;$script:CocoUsernameCancelled=$true}
    })
    $controls=@($edge,$heading,$nameBox,$validation,$save)
    if($cancel){$controls+=$cancel}
    $overlay.Controls.AddRange($controls)
    $previousAccept=$script:CocoForm.AcceptButton
    try{
        $script:CocoPanel.Controls.Add($overlay);$overlay.BringToFront();$script:CocoForm.AcceptButton=$save
        & $validate
        $script:CocoForm.BringToFront();$script:CocoForm.Activate();[void]$nameBox.Focus();$nameBox.SelectAll()
        while(-not$script:CocoForm.IsDisposed-and[string]::IsNullOrWhiteSpace($script:CocoUsernameChoice)-and-not$script:CocoUsernameCancelled){
            [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50
        }
    }finally{
        if(-not$script:CocoForm.IsDisposed){$script:CocoForm.AcceptButton=$previousAccept}
        if(-not$overlay.IsDisposed){$script:CocoPanel.Controls.Remove($overlay);$overlay.Dispose()}
    }
    if($script:CocoUsernameCancelled-or-not(Test-CocoMinecraftUsername $script:CocoUsernameChoice)){throw 'La configuracion del jugador fue cancelada.'}
    return $script:CocoUsernameChoice
}

# Redefinicion intencional del flujo antiguo: desde esta version Coco no ofrece
# autenticacion Microsoft. Todos usan una identidad local estable en la red
# privada, incluso si poseen una licencia oficial.
function Resolve-CocoLauncherIdentityUi($Catalog,[string]$LegacyMinecraftRoot,$Paths,[int]$PromptStage=3,[int]$PromptProgress=24){
    # 1. Si ya existe una identidad valida guardada en disco, reutilizarla de inmediato sin bloquear
    $current=try{Read-CocoLauncherIdentityState $Paths.IdentityPath}catch{$null}
    if($current -and (Test-CocoMinecraftUsername ([string]$current.username))){
        if($script:CocoIdentityTextBox-and-not$script:CocoIdentityTextBox.IsDisposed){
            $script:CocoIdentityTextBox.Text=[string]$current.username
        }
        if($script:CocoIdentityButton-and-not$script:CocoIdentityButton.IsDisposed){
            $script:CocoIdentityButton.Text='JUGADOR'
            $script:CocoIdentityButton.AccessibleDescription="Jugador: $($current.username)"
        }
        return $current
    }

    # 2. Si el usuario ya escribio un nombre valido en la caja de texto, guardarlo y usarlo
    $candidate=''
    if($script:CocoIdentityTextBox-and-not$script:CocoIdentityTextBox.IsDisposed){
        $candidate=([string]$script:CocoIdentityTextBox.Text).Trim()
    }
    if(Test-CocoMinecraftUsername $candidate){
        $identity=Save-CocoLauncherIdentityState $Paths.IdentityPath offline $candidate '' 'launcher-textbox'
        if($script:CocoIdentityButton-and-not$script:CocoIdentityButton.IsDisposed){
            $script:CocoIdentityButton.Text='JUGADOR'
            $script:CocoIdentityButton.AccessibleDescription="Jugador: $candidate"
        }
        return $identity
    }

    # 3. Si no hay nombre aun, auto-resolver sin bloquear ni interrumpir al usuario
    $resolved=try{Resolve-CocoLauncherIdentity $Paths.IdentityPath $LegacyMinecraftRoot}catch{$null}
    if($resolved-and$resolved.Status-eq'configured'-and$resolved.Identity){
        if($script:CocoIdentityTextBox-and-not$script:CocoIdentityTextBox.IsDisposed){
            $script:CocoIdentityTextBox.Text=[string]$resolved.Identity.username
        }
        if($script:CocoIdentityButton-and-not$script:CocoIdentityButton.IsDisposed){
            $script:CocoIdentityButton.Text='JUGADOR'
            $script:CocoIdentityButton.AccessibleDescription="Jugador: $($resolved.Identity.username)"
        }
        return $resolved.Identity
    }

    $suggested=if($resolved-and$resolved.Hint){[string]$resolved.Hint.Username}else{''}
    if(-not(Test-CocoMinecraftUsername $suggested)){
        $rawUser=[regex]::Replace(([string]$env:USERNAME),'[^a-zA-Z0-9_]','')
        if($rawUser.Length-gt16){$rawUser=$rawUser.Substring(0,16)}
        if($rawUser.Length-lt3){$rawUser="Player_$PID"}
        if($rawUser.Length-gt16){$rawUser=$rawUser.Substring(0,16)}
        $suggested=if(Test-CocoMinecraftUsername $rawUser){$rawUser}else{("Coco_"+(Get-Random -Minimum 1000 -Maximum 9999))}
    }

    $identity=Save-CocoLauncherIdentityState $Paths.IdentityPath offline $suggested '' 'auto-resolved'
    Write-CocoLog "Identidad auto-resuelta sin bloqueo: $suggested"
    if($script:CocoIdentityTextBox-and-not$script:CocoIdentityTextBox.IsDisposed){
        $script:CocoIdentityTextBox.Text=$suggested
    }
    if($script:CocoIdentityButton-and-not$script:CocoIdentityButton.IsDisposed){
        $script:CocoIdentityButton.Text='JUGADOR'
        $script:CocoIdentityButton.AccessibleDescription="Jugador: $suggested"
    }
    return $identity
}

function Invoke-CocoLauncherIdentityButton($IdentityCard,$IdentityText){
    try{
        if(-not$IdentityCard-or$IdentityCard.IsDisposed){return}
        if($IdentityCard.Visible){$IdentityCard.Visible=$false;return}
        $IdentityCard.Visible=$true;$IdentityCard.BringToFront()
        try{
            $form=$IdentityCard.FindForm()
            if($form-and-not$form.IsDisposed){$form.Activate()}
        }catch{}
        if($IdentityText-and-not$IdentityText.IsDisposed){[void]$IdentityText.Focus();$IdentityText.SelectAll()}
    }catch{
        try{Write-CocoLog "No se pudo abrir el popup de identidad: $($_.Exception.Message)"}catch{}
    }
}

function Start-CocoLauncherExperience($Catalog,$Experience,$Identity,[string]$Role,$Paths,[string]$LegacyMinecraftRoot,[switch]$DisableAutoJoin){
    if($Experience.managementMode-ne'managed'-or($Experience.launch.workflow-ne'coco-managed'-and$Experience.launch.workflow-ne'coco-standalone')){
        throw 'Coco original se abre con el launcher habitual de cada jugador, no con Coco Launcher.'
    }
    Invoke-CocoManagedExperienceLaunch $Catalog $Experience.id $Identity $Role $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -DisableAutoJoin:$DisableAutoJoin -InstanceLocationsPath:(Get-CocoLauncherInstanceLocationsPath $Paths)
}

function Get-CocoLauncherFailureDetail($ErrorRecord){
    $message=if($ErrorRecord.Exception){[string]$ErrorRecord.Exception.Message}else{[string]$ErrorRecord}
    if(Get-Command Get-CocoFailureClassification -ErrorAction SilentlyContinue){
        $classification=Get-CocoFailureClassification $message
        $message+="`nCodigo: $($classification.Code) | $($classification.Action)"
    }
    if(Get-Command Write-CocoEngineDiagnostic -ErrorAction SilentlyContinue){
        try{
            $diagnostic=Write-CocoEngineDiagnostic $ErrorRecord
            if($diagnostic){$message+="`nEnvia por Discord: $([IO.Path]::GetFileName([string]$diagnostic))"}
        }catch{}
    }
    $message
}

function Invoke-CocoLauncherClientSession($Catalog,$Session,$Paths,[string]$LegacyMinecraftRoot,[hashtable]$PreparedSessions){
    $action=Get-CocoClientSessionAction $Session
    if($action.Experience-and(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue)){
        Set-CocoDiagnosticContext @{role='client';experienceId=[string]$action.Experience.id;packVersion=[string]$action.Experience.pack.version;instanceRoot=(Get-CocoExperienceInstanceRoot $action.Experience $Paths.ExperiencesRoot (Get-CocoLauncherInstanceLocationsPath $Paths))}
    }
    if($action.Action-eq'prepare'){
        $sessionId=[string]$Session.Announcement.sessionId
        if(-not$PreparedSessions.ContainsKey($sessionId)-and$action.Experience.managementMode-eq'managed'){
            Set-CocoLauncherStep 3 'PARTIDA DETECTADA' ("{0} se esta preparando en el host; Coco adelantara toda la instalacion local."-f$action.Experience.name) 25
            $dummy=[pscustomobject]@{mode='offline';username='CocoPrepare';uuid=''}
            [void](Invoke-CocoManagedExperienceLaunch $Catalog $action.Experience.id $dummy client $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -Dry -InstanceLocationsPath:(Get-CocoLauncherInstanceLocationsPath $Paths))
            $PreparedSessions[$sessionId]=$true
        }
        return $null
    }
    if($action.Action-ne'launch'){return $null}
    $sessionId=[string]$Session.Announcement.sessionId
    if($action.Experience.managementMode-eq'managed'-and-not$PreparedSessions.ContainsKey($sessionId)){
        Set-CocoLauncherStep 3 'PARTIDA LISTA' ("Verificando {0} antes de abrir Minecraft..."-f$action.Experience.name) 27
        $dummy=[pscustomobject]@{mode='offline';username='CocoPrepare';uuid=''}
        [void](Invoke-CocoManagedExperienceLaunch $Catalog $action.Experience.id $dummy client $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -Dry -InstanceLocationsPath:(Get-CocoLauncherInstanceLocationsPath $Paths))
        $PreparedSessions[$sessionId]=$true
    }
    $fresh=Get-CocoSessionAnnouncement $Catalog
    if($fresh.State-ne'ready'-or[string]$fresh.Announcement.sessionId-ne$sessionId){return $null}
    $isStandalone=[string]$action.Experience.launch.workflow-eq'coco-standalone'-or[string]$action.Experience.runtime.type-eq'standalone'
    $identity=Resolve-CocoLauncherIdentityUi $Catalog $LegacyMinecraftRoot $Paths 7 88
    if($isStandalone){$identity=[pscustomobject]@{mode='offline';username='CocoPlayer';uuid=''}}
    $fresh=Get-CocoSessionAnnouncement $Catalog
    if($fresh.State-ne'ready'-or[string]$fresh.Announcement.sessionId-ne$sessionId){return $null}
    if(-not$isStandalone){
        $skinSync=Sync-CocoSkinRegistry $Catalog $Paths $identity
        $instanceRoot=Get-CocoExperienceInstanceRoot $action.Experience $Paths.ExperiencesRoot (Get-CocoLauncherInstanceLocationsPath $Paths)
        [void](Install-CocoSkinRegistry $Paths.SkinRoot $instanceRoot)
        [void](Install-CocoSkinRegistry $Paths.SkinRoot $LegacyMinecraftRoot)
        if($script:CocoSkinTile){Set-CocoSkinTilePreview $script:CocoSkinPicture $script:CocoSkinLabel $Paths.SkinRoot ([string]$identity.username) ([bool]$skinSync.Pending)}
    }
    if($script:CocoIdentityTextBox){$script:CocoIdentityTextBox.Enabled=$false}
    if($script:CocoSkinTile){$script:CocoSkinTile.Enabled=$false}
    Set-CocoLauncherStep 7 'JUGADOR LISTO' ("Entraras como {0}"-f$identity.username) 89
    Set-CocoLauncherStep 8 'ABRIENDO JUEGO' ("{0} se iniciara para conectarse a la partida."-f$action.Experience.name) 90
    Start-CocoLauncherExperience $Catalog $action.Experience $identity client $Paths $LegacyMinecraftRoot
}

function Invoke-CocoLauncherHostSession($Catalog,$Experience,$Paths,[string]$LegacyMinecraftRoot){
    if(-not$Experience-or$Experience.managementMode-ne'managed'-or($Experience.launch.workflow-ne'coco-managed'-and$Experience.launch.workflow-ne'coco-standalone')){throw 'El host solo puede alojar experiencias administradas desde Coco Launcher.'}
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{role='host';experienceId=[string]$Experience.id;packVersion=[string]$Experience.pack.version;instanceRoot=(Get-CocoExperienceInstanceRoot $Experience $Paths.ExperiencesRoot (Get-CocoLauncherInstanceLocationsPath $Paths))}}
    Set-CocoLauncherStep 3 'PREPARANDO LA PARTIDA DEL HOST' ("Experiencia seleccionada: {0}"-f$Experience.name) 25
    if($Experience.launch.workflow-eq'coco-managed'-and(Test-CocoTcpEndpoint ([string]$Experience.hosting.host) ([int]$Experience.hosting.port) 350)){
        throw 'El puerto Coco 25565 ya esta ocupado. Cierra la partida anterior antes de iniciar otra.'
    }
    $sessionId=[guid]::NewGuid().ToString()
    $forceJoin=if($script:CocoHostForceJoin-ne$null){[bool]$script:CocoHostForceJoin}else{$true}
    [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id preparing $sessionId $Paths.SessionStatePath 30 $forceJoin)
    $service=$null;$launch=$null
    try{
        $service=Start-CocoSessionService (Join-Path $script:CocoEngineRoot 'CocoSessionService.ps1') $Paths.SessionStatePath $Paths.SessionLogPath $PID $Paths.SkinRoot
        Set-CocoLauncherStep 4 'VERIFICANDO EL PACK DEL HOST' ("Instalando {0} en una instancia aislada..."-f$Experience.name) 30
        $dummy=[pscustomobject]@{mode='offline';username='CocoPrepare';uuid=''}
        [void](Invoke-CocoManagedExperienceLaunch $Catalog $Experience.id $dummy host $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -Dry -DisableAutoJoin -InstanceLocationsPath:(Get-CocoLauncherInstanceLocationsPath $Paths))
        $isStandalone=[string]$Experience.launch.workflow-eq'coco-standalone'-or[string]$Experience.runtime.type-eq'standalone'
        $identity=if(-not$isStandalone){
            Resolve-CocoLauncherIdentityUi $Catalog $LegacyMinecraftRoot $Paths 7 88
        }else{
            [pscustomobject]@{mode='offline';username='CocoPlayer';uuid=''}
        }
        if(-not$isStandalone){
            $hostSkinSync=Sync-CocoSkinRegistry $Catalog $Paths $identity
            if($script:CocoSkinTile){Set-CocoSkinTilePreview $script:CocoSkinPicture $script:CocoSkinLabel $Paths.SkinRoot ([string]$identity.username) ([bool]$hostSkinSync.Pending)}
        }
        $launch=Start-CocoLauncherExperience $Catalog $Experience $identity host $Paths $LegacyMinecraftRoot -DisableAutoJoin
        $instanceRoot=if($launch.Installation){[string]$launch.Installation.InstanceRoot}elseif($launch.InstanceRoot){[string]$launch.InstanceRoot}else{$LegacyMinecraftRoot}
        if($Experience.managementMode-eq'managed'-and$Experience.launch.workflow-eq'coco-managed'){[void](Set-CocoManagedLanWorldConfigurations $instanceRoot $Experience)}
        if($Experience.launch.workflow-eq'coco-standalone'){
            Write-CocoLog "Proceso standalone iniciado (PID: $($launch.Process.Id)). Supervisando ejecucion..."
            Set-CocoLauncherStep 9 'JUEGO STANDALONE ABIERTO' ("{0} esta ejecutandose. Tus amigos podran entrar al detectar tu sesion."-f$Experience.name) 95
            try{$script:CocoForm.TopMost=$false}catch{}
            $ready=$true;$lastPublish=[DateTime]::MinValue
            while(-not$launch.Process.HasExited){
                [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
                if((Get-Date)-gt$lastPublish.AddSeconds(8)){
                    [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id 'ready' $sessionId $Paths.SessionStatePath 30 $forceJoin)
                    $lastPublish=Get-Date
                    $statusMsg=if($forceJoin){"{0} esta lista; tus amigos entraran automaticamente."-f$Experience.name}else{"{0} esta lista; tus amigos podran unirse desde su launcher."-f$Experience.name}
                    Set-CocoLauncherStep 10 'PARTIDA ONLINE' $statusMsg 100
                }
            }
            Stop-CocoStandalonePopupGate
            Write-CocoLog "Proceso standalone (PID: $($launch.Process.Id)) ha finalizado con codigo de salida $($launch.Process.ExitCode)."
        }else{
            [void](Wait-CocoManagedMinecraftWindow $instanceRoot $launch.Process 90)
            $lanInstruction=if([string]$Experience.hosting.adapter-eq'lan-server-properties-v1'){
                'Entra o crea el mundo, pulsa Abrir en LAN, deja el puerto en 25565 y cambia Online Mode a OFF antes de iniciar.'
            }else{'Entra o crea el mundo. Coco configurara el modo local y luego puedes pulsar Abrir en LAN.'}
            Set-CocoLauncherStep 9 'MINECRAFT ABIERTO' $lanInstruction 95
            try{$script:CocoForm.TopMost=$false}catch{}
            $ready=$false;$lastPublish=[DateTime]::MinValue
            $lanConfiguredBeforeOpen=Test-CocoManagedLanWorldConfigurations $instanceRoot $Experience
            $unsafeLanObserved=$false
            while(-not$launch.Process.HasExited){
                [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
                if($Experience.managementMode-eq'managed'){[void](Set-CocoManagedLanWorldConfigurations $instanceRoot $Experience)}
                $configurationReady=Test-CocoManagedLanWorldConfigurations $instanceRoot $Experience
                $portOpen=Test-CocoTcpEndpoint ([string]$Experience.hosting.host) ([int]$Experience.hosting.port) 250
                if(-not$portOpen-and$configurationReady){$lanConfiguredBeforeOpen=$true}
                if(-not$ready-and$portOpen-and$lanConfiguredBeforeOpen){$ready=$true}
                elseif(-not$ready-and$portOpen-and-not$lanConfiguredBeforeOpen-and-not$unsafeLanObserved){
                    $unsafeLanObserved=$true
                    Set-CocoLauncherStep 9 'REABRE LA PARTIDA LAN' 'La LAN se abrio antes de cargar el modo local. Cierra la LAN, espera la confirmacion de Coco y vuelve a abrirla.' 95
                }
                if((Get-Date)-gt$lastPublish.AddSeconds(8)){
                    [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id $(if($ready){'ready'}else{'preparing'}) $sessionId $Paths.SessionStatePath 30 $forceJoin)
                    $lastPublish=Get-Date
                    if($ready){
                        $statusMsg=if($forceJoin){"{0} esta lista; tus amigos entraran automaticamente."-f$Experience.name}else{"{0} esta lista; tus amigos podran unirse desde su launcher."-f$Experience.name}
                        Set-CocoLauncherStep 10 'PARTIDA ONLINE' $statusMsg 100
                    }
                }
            }
        }
        [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id stopping $sessionId $Paths.SessionStatePath 10)
    }finally{
        if($launch-and$launch.Process-and$launch.Process.HasExited){$launch.Process.Dispose()}
        if($service-and-not$service.HasExited){
            $service.Kill()
            [void]$service.WaitForExit(5000)
        }
        if($service){$service.Dispose()}
        Remove-Item -LiteralPath $Paths.SessionStatePath -Force -ErrorAction SilentlyContinue
        if($script:CocoIdentityTextBox){$script:CocoIdentityTextBox.Enabled=$true}
        if($script:CocoSkinTile){$script:CocoSkinTile.Enabled=$true}
    }
}

function Start-CocoLauncherUi($Manifest,[string]$LegacyMinecraftRoot,[string]$LauncherTestRoot='',[ValidateSet('','client','host')][string]$RoleOverride=''){
    if(-not(Get-Command Show-CocoWindow -ErrorAction SilentlyContinue)){throw 'El engine no contiene la UI base requerida por Coco Launcher.'}
    $paths=Get-CocoLauncherPaths $script:CocoEngineRoot $LauncherTestRoot
    $script:CocoInstanceLocationsPath=[string]$paths.InstanceLocationsPath
    $catalog=Read-CocoLauncherCatalog $paths.CatalogPath
    if($paths.IsTest){New-Item -ItemType Directory -Path $paths.SkinRoot -Force|Out-Null}
    else{Initialize-CocoSkinRegistry $catalog.globalPolicies $script:CocoEngineRoot $paths.SkinRoot}
    $original=@($catalog.experiences|Where-Object id -eq 'coco-original'|Select-Object -First 1)[0]
    if(-not$original-or[string]$original.pack.version-ne[string]$Manifest.version){throw 'El catalogo Coco Launcher no coincide con la version publicada del engine.'}
    $script:CocoLauncherMinimizeButton=$null
    $script:CocoLauncherCloseButton=$null
    $script:CocoIdentityButton=$null
    $script:CocoIdentityOpenAction=$null
    Show-CocoWindow
    $script:CocoForm.Text='Coco Launcher';$script:CocoBrand.Text='COCO LAUNCHER  |  EXPERIENCIAS DISPONIBLES'
    try {
        $script:CocoForm.Add_Activated({
            try {
                if ($script:CocoForm.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
                    $script:CocoForm.WindowState = [Windows.Forms.FormWindowState]::Normal
                    $script:CocoForm.BringToFront()
                }
            } catch {}
        })
    } catch {}
    if(-not$script:CocoTrayIcon){
        $tray=New-Object Windows.Forms.NotifyIcon
        $tray.Text='Coco Launcher'
        $trayIconPath=Join-Path $script:CocoEngineRoot 'assets\reynaico.ico'
        if(Test-Path $trayIconPath){try{$tray.Icon=New-Object Drawing.Icon($trayIconPath)}catch{}}
        $restoreFromTray={
            try{
                if($script:CocoForm-and-not$script:CocoForm.IsDisposed){
                    $script:CocoForm.WindowState=[Windows.Forms.FormWindowState]::Normal
                    $script:CocoForm.Show()
                    $script:CocoForm.BringToFront()
                    $script:CocoForm.Activate()
                }
            }catch{}
        }
        $tray.Add_Click($restoreFromTray)
        $tray.Add_DoubleClick($restoreFromTray)
        $tray.Visible=$true
        $script:CocoTrayIcon=$tray
        $script:CocoForm.Add_FormClosed({
            try{
                if($script:CocoTrayIcon){
                    $script:CocoTrayIcon.Visible=$false
                    $script:CocoTrayIcon.Dispose()
                    $script:CocoTrayIcon=$null
                }
                if($script:CocoCoverImageCache){
                    foreach($img in @($script:CocoCoverImageCache.Values)){try{$img.Dispose()}catch{}}
                    $script:CocoCoverImageCache.Clear()
                }
            }catch{}
        })
    }
    Set-CocoLauncherUiLayout
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{component='launcher';mode='launcher';role='detecting';stage='start'}}
    $runLabel=if(-not[string]::IsNullOrWhiteSpace([string]$script:CocoRunId)){([string]$script:CocoRunId).Substring(0,[Math]::Min(8,([string]$script:CocoRunId).Length))}else{'test/local'}
    $script:CocoDefenderPlayWindowOwned=$false
    if(-not$paths.IsTest-and(Get-Command Invoke-CocoDefenderPlayWindowStart -ErrorAction SilentlyContinue)){
        try{$script:CocoDefenderPlayWindowOwned=[bool](Invoke-CocoDefenderPlayWindowStart)}catch{Write-CocoLog "DEFENDER: inicio de sesion sin toggle ($($_.Exception.Message))"}
    }
    try{
    Set-CocoLauncherStep 1 'INICIANDO COCO LAUNCHER' ("Engine {0} | ejecucion {1}"-f$Manifest.version,$runLabel) 13
    $role=if([string]::IsNullOrWhiteSpace($RoleOverride)){Get-CocoLauncherRole $LegacyMinecraftRoot}else{$RoleOverride}
    if($script:CocoBrand){$script:CocoBrand.Text=if($role-eq'host'){'COCO LAUNCHER  |  MODO HOST'}else{'COCO LAUNCHER  |  EXPERIENCIAS DISPONIBLES'}}
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{role=$role}}
    Set-CocoLauncherStep 2 'PREPARANDO LA RED PRIVADA' 'Verificando ZeroTier, adaptador, autorizacion y rutas Coco...' 16
    $oldMinecraftPid=$script:MinecraftPid;$script:MinecraftPid=$PID
    try{
        if($Manifest.network-and-not$paths.IsTest){
            try {
                [void](Invoke-CocoLauncherNetworkSerialized {Ensure-CocoNetwork $LegacyMinecraftRoot $role $Manifest})
            } catch {
                Write-CocoLog "ADVERTENCIA: Red ZeroTier no lista al inicio ($($_.Exception.Message))"
            }
        }
    }finally{$script:MinecraftPid=$oldMinecraftPid}
    $dynamic=New-Object Windows.Forms.Panel;$dynamic.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 46),(Get-CocoLauncherUiMetric 190));$dynamic.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 840),(Get-CocoLauncherUiMetric 570));$dynamic.AutoScroll=$true;$dynamic.Tag='CocoLauncherDynamic';$script:CocoPanel.Controls.Add($dynamic);Set-CocoExperienceCardsScrollBehavior $dynamic
    $identityResolution=try{Resolve-CocoLauncherIdentity $paths.IdentityPath $LegacyMinecraftRoot}catch{$null}
    $savedIdentity=if($identityResolution-and$identityResolution.Status-eq'configured'){$identityResolution.Identity}else{try{Read-CocoLauncherIdentityState $paths.IdentityPath}catch{$null}}
    $identityCard=New-Object Windows.Forms.Panel;$identityCard.Name='CocoIdentityPopup';$identityCard.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 500),(Get-CocoLauncherUiMetric 34));$identityCard.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 315),(Get-CocoLauncherUiMetric 92))
    $identityCard.BackColor=[Drawing.Color]::FromArgb(36,22,57);$identityCard.BorderStyle=[Windows.Forms.BorderStyle]::FixedSingle;$identityCard.AllowDrop=$true;$identityCard.Visible=$false;Set-CocoControlDoubleBuffered $identityCard
    $skinPicture=New-Object Windows.Forms.PictureBox;$skinPicture.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 6),(Get-CocoLauncherUiMetric 6));$skinPicture.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 64),(Get-CocoLauncherUiMetric 64))
    $skinPicture.SizeMode='Zoom';$skinPicture.BackColor=[Drawing.Color]::FromArgb(36,22,57);$skinPicture.Cursor=[Windows.Forms.Cursors]::Hand;$skinPicture.AllowDrop=$true
    $identityHeading=New-Object Windows.Forms.Label;$identityHeading.Text='TU IDENTIDAD COCO';$identityHeading.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 76),(Get-CocoLauncherUiMetric 4));$identityHeading.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 198),(Get-CocoLauncherUiMetric 18))
    $identityHeading.Font=New-Object Drawing.Font('Segoe UI Semibold',(Get-CocoLauncherUiFontSize 8.5 7));$identityHeading.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $identityText=New-Object Windows.Forms.TextBox;$identityText.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 76),(Get-CocoLauncherUiMetric 24));$identityText.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 233),(Get-CocoLauncherUiMetric 25))
    $identityText.MaxLength=16;$identityText.Font=New-Object Drawing.Font('Segoe UI',(Get-CocoLauncherUiFontSize 10 7));$identityText.BorderStyle='FixedSingle'
    $identityText.Text=if($savedIdentity){[string]$savedIdentity.username}else{''}
    $identityStatus=New-Object Windows.Forms.Label;$identityStatus.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 76),(Get-CocoLauncherUiMetric 51));$identityStatus.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 233),(Get-CocoLauncherUiMetric 24))
    $identityStatus.Font=New-Object Drawing.Font('Segoe UI',(Get-CocoLauncherUiFontSize 7.5 6))
    $identityClose=New-Object Windows.Forms.Button;$identityClose.Name='CocoIdentityCloseButton';$identityClose.Text='X';$identityClose.AccessibleName='Cerrar identidad';$identityClose.Location=New-Object Drawing.Point((Get-CocoLauncherUiMetric 282),(Get-CocoLauncherUiMetric 3));$identityClose.Size=New-Object Drawing.Size((Get-CocoLauncherUiMetric 26),(Get-CocoLauncherUiMetric 22));$identityClose.TabStop=$false;Set-CocoFlatButtonStyle $identityClose ([Drawing.Color]::FromArgb(36,22,57)) ([Drawing.Color]::FromArgb(218,210,229));$identityClose.Add_Click({$identityCard.Visible=$false}.GetNewClosure())
    $identityCard.Controls.AddRange(@($skinPicture,$identityHeading,$identityText,$identityStatus,$identityClose));$script:CocoPanel.Controls.Add($identityCard)
    $skinTile=$identityCard
    $skinLabel=$identityStatus
    $script:CocoSkinTile=$identityCard;$script:CocoSkinPicture=$skinPicture;$script:CocoSkinLabel=$skinLabel
    $script:CocoIdentityButton=$null;$script:CocoIdentityTextBox=$identityText;$script:CocoIdentityStatus=$identityStatus
    $script:CocoIdentityConfirmedName=if($savedIdentity){[string]$savedIdentity.username}else{''}
    $skinState=try{if(Test-Path -LiteralPath $paths.SkinStatePath){Get-Content -LiteralPath $paths.SkinStatePath -Raw|ConvertFrom-Json}else{$null}}catch{$null}
    $skinUsername=if($savedIdentity){[string]$savedIdentity.username}else{''}
    Set-CocoSkinTilePreview $skinPicture $skinLabel $paths.SkinRoot $skinUsername ([bool]($skinState-and$skinState.pendingUpload))
    $validateIdentity={
        $candidate=([string]$identityText.Text).Trim()
        $valid=Test-CocoMinecraftUsername $candidate
        $confirmed=$valid-and$candidate-eq[string]$script:CocoIdentityConfirmedName
        $identityStatus.Text=if($confirmed){'Nombre valido.'}elseif($valid){'Pulsa Enter para confirmar.'}else{'3-16 letras, numeros o _.'}
        $identityStatus.ForeColor=if($confirmed){[Drawing.Color]::FromArgb(78,214,132)}elseif($valid){[Drawing.Color]::FromArgb(224,190,255)}else{[Drawing.Color]::FromArgb(255,139,151)}
        $valid
    }
    $saveIdentity={
        $candidate=([string]$identityText.Text).Trim()
        if(-not(Test-CocoMinecraftUsername $candidate)){[void](&$validateIdentity);return $null}
        $current=try{Read-CocoLauncherIdentityState $paths.IdentityPath}catch{$null}
        if(-not$current-or[string]$current.username-ne$candidate){
            $current=Save-CocoLauncherIdentityState $paths.IdentityPath offline $candidate '' 'launcher-identity-popup'
            Write-CocoLog "Identidad local guardada desde el popup del launcher: $candidate"
        }
        $script:CocoIdentityConfirmedName=$candidate
        $identityStatus.Text='Nombre valido.';$identityStatus.ForeColor=[Drawing.Color]::FromArgb(78,214,132)
        $pendingState=try{if(Test-Path -LiteralPath $paths.SkinStatePath){Get-Content -LiteralPath $paths.SkinStatePath -Raw|ConvertFrom-Json}else{$null}}catch{$null}
        Set-CocoSkinTilePreview $skinPicture $skinLabel $paths.SkinRoot $candidate ([bool]($pendingState-and$pendingState.username-eq$candidate-and$pendingState.pendingUpload))
        if($script:CocoIdentityButton-and-not$script:CocoIdentityButton.IsDisposed){$script:CocoIdentityButton.Text='JUGADOR';$script:CocoIdentityButton.AccessibleDescription="Jugador: $candidate"}
        $identityCard.Visible=$false
        $current
    }
    $identityText.Add_TextChanged({[void](&$validateIdentity)}.GetNewClosure())
    $identityText.Add_Leave({[void](&$saveIdentity)}.GetNewClosure())
    $identityText.Add_KeyDown({param($sender,$eventArgs)
        if($eventArgs.KeyCode-eq[Windows.Forms.Keys]::Enter){$eventArgs.SuppressKeyPress=$true;[void](&$saveIdentity)}
    }.GetNewClosure())
    [void](&$validateIdentity)
    $applySkin={
        param([string]$SelectedPath)
        try{
            $current=&$saveIdentity
            if(-not$current){[void]$identityText.Focus();throw 'Escribe primero un nombre valido en la misma tarjeta.'}
            $imported=Import-CocoUserSkin $SelectedPath ([string]$current.username) $paths.SkinRoot $paths.SkinStatePath
            [void](Install-CocoSkinRegistry $paths.SkinRoot $LegacyMinecraftRoot)
            if(Test-Path -LiteralPath $paths.ExperiencesRoot -PathType Container){
                foreach($folder in Get-ChildItem -LiteralPath $paths.ExperiencesRoot -Directory){[void](Install-CocoSkinRegistry $paths.SkinRoot $folder.FullName)}
            }
            $skinSync=Sync-CocoSkinRegistry $catalog $paths $current
            [void](Install-CocoSkinRegistry $paths.SkinRoot $LegacyMinecraftRoot)
            if(Test-Path -LiteralPath $paths.ExperiencesRoot -PathType Container){
                foreach($folder in Get-ChildItem -LiteralPath $paths.ExperiencesRoot -Directory){[void](Install-CocoSkinRegistry $paths.SkinRoot $folder.FullName)}
            }
            $skinLabel.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
            Set-CocoSkinTilePreview $skinPicture $skinLabel $paths.SkinRoot ([string]$current.username) ([bool]$skinSync.Pending)
        }catch{
            $skinLabel.ForeColor=[Drawing.Color]::FromArgb(255,139,151)
            $skinLabel.Text="NO SE PUDO USAR`r`n$($_.Exception.Message)"
        }
    }
    $chooseSkin={
        $dialog=New-Object Windows.Forms.OpenFileDialog
        try{
            $dialog.Title='Elige tu skin de Minecraft';$dialog.Filter='Skin de Minecraft (*.png)|*.png';$dialog.Multiselect=$false;$dialog.CheckFileExists=$true
            if($dialog.ShowDialog($script:CocoForm)-eq[Windows.Forms.DialogResult]::OK){&$applySkin $dialog.FileName}
        }finally{$dialog.Dispose()}
    }
    $dragEnter={
        param($sender,$eventArgs)
        $files=if($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)){@($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))}else{@()}
        $eventArgs.Effect=if($files.Count-eq1-and[IO.Path]::GetExtension([string]$files[0])-eq'.png'){[Windows.Forms.DragDropEffects]::Copy}else{[Windows.Forms.DragDropEffects]::None}
    }
    $dragDrop={
        param($sender,$eventArgs)
        $files=@($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        if($files.Count-eq1){&$applySkin ([string]$files[0])}
    }
    foreach($control in @($identityCard,$skinPicture,$identityHeading,$identityStatus)){
        $control.Add_Click($chooseSkin.GetNewClosure());$control.Add_DragEnter($dragEnter.GetNewClosure());$control.Add_DragDrop($dragDrop.GetNewClosure())
    }
    $showIdentity={
        if(-not$identityCard-or$identityCard.IsDisposed){return}
        $identityCard.Visible=$true
        $identityCard.BringToFront()
        try{
            $form=$identityCard.FindForm()
            if($form-and-not$form.IsDisposed){$form.Activate()}
        }catch{}
        try{
            if($identityText-and-not$identityText.IsDisposed){[void]$identityText.Focus();$identityText.SelectAll()}
        }catch{}
    }
    $script:CocoIdentityOpenAction=$showIdentity
    $identityToggleCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Invoke-CocoLauncherIdentityButton -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $identityButton=New-Object Windows.Forms.Button;$identityButton.Name='CocoLauncherIdentityButton';$identityButton.Text='JUGADOR';$identityButton.AccessibleName='Abrir identidad';$identityButton.AccessibleDescription=if($savedIdentity){"Jugador: $($savedIdentity.username)"}else{'Configurar jugador'};$identityButton.TabStop=$false
    Set-CocoFlatButtonStyle $identityButton ([Drawing.Color]::FromArgb(22,13,37)) ([Drawing.Color]::FromArgb(224,190,255));$identityButton.Font=New-Object Drawing.Font('Segoe UI Semibold',(Get-CocoLauncherUiFontSize 7.5 6));$identityButton.Add_Click({&$identityToggleCommand $identityCard $identityText}.GetNewClosure())
    $script:CocoIdentityButton=$identityButton;$script:CocoPanel.Controls.Add($identityButton)
    # La identidad no es necesaria para ver contenido multimedia. El popup se
    # abre solo al pulsar JUGADOR o cuando una experiencia Minecraft realmente
    # necesita que el jugador confirme su nombre.
    $identityCard.Visible=$false
    $minimize=New-Object Windows.Forms.Button;$minimize.Name='CocoLauncherMinimizeButton';$minimize.Text='';$minimize.AccessibleName='Minimizar';$minimize.TabStop=$false
    Set-CocoFlatButtonStyle $minimize ([Drawing.Color]::FromArgb(22,13,37)) ([Drawing.Color]::FromArgb(218,210,229))
    $minimize.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(58,36,81);$minimize.FlatAppearance.MouseDownBackColor=[Drawing.Color]::FromArgb(42,27,58)
    $minimize.Add_Paint({param($sender,$eventArgs)$pen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(218,210,229),1.5);$eventArgs.Graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$y=[int]($sender.ClientSize.Height/2)+3;$eventArgs.Graphics.DrawLine($pen,11,$y,$sender.ClientSize.Width-11,$y);$pen.Dispose()}.GetNewClosure())
    $minimize.Add_Click({try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.WindowState=[Windows.Forms.FormWindowState]::Minimized}}catch{}}.GetNewClosure())
    $script:CocoLauncherMinimizeButton=$minimize;$script:CocoPanel.Controls.Add($minimize)
    $close=New-Object Windows.Forms.Button;$close.Name='CocoLauncherCloseButton';$close.Text='';$close.AccessibleName='Cerrar';$close.TabStop=$false
    Set-CocoFlatButtonStyle $close ([Drawing.Color]::FromArgb(22,13,37)) ([Drawing.Color]::FromArgb(218,210,229))
    $close.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(150,48,70);$close.FlatAppearance.MouseDownBackColor=[Drawing.Color]::FromArgb(105,35,52)
    $close.Add_Paint({param($sender,$eventArgs)$pen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(218,210,229),1.5);$eventArgs.Graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$inset=11;$eventArgs.Graphics.DrawLine($pen,$inset,$inset,$sender.ClientSize.Width-$inset,$sender.ClientSize.Height-$inset);$eventArgs.Graphics.DrawLine($pen,$sender.ClientSize.Width-$inset,$inset,$inset,$sender.ClientSize.Height-$inset);$pen.Dispose()}.GetNewClosure())
    $launcherCloseCommand=[System.Management.Automation.ScriptBlock](@(Get-Command Request-CocoLauncherClose -CommandType Function -ErrorAction Stop|Select-Object -First 1)[0].ScriptBlock)
    $close.Add_Click({&$launcherCloseCommand}.GetNewClosure());$script:CocoLauncherCloseButton=$close;$script:CocoPanel.Controls.Add($close)
    if($role-eq'host'){
        $hostPrefs=Read-CocoHostPreferences
        $script:CocoHostForceJoin=if($hostPrefs.PSObject.Properties.Name-contains'forceJoin'){[bool]$hostPrefs.forceJoin}else{$true}
        $hostForceButton=New-Object Windows.Forms.Button
        $hostForceButton.Name='CocoHostForceButton'
        $hostForceButton.TabStop=$false
        $hostForceButton.Font=New-Object Drawing.Font('Segoe UI Semibold',(Get-CocoLauncherUiFontSize 7.5 6))
        $savePrefsCommand=try{[System.Management.Automation.ScriptBlock](@(Get-Command Save-CocoHostPreferences -CommandType Function -ErrorAction SilentlyContinue|Select-Object -First 1)[0].ScriptBlock)}catch{$null}
        $updateForceButtonUi={
            try{
                if($script:CocoHostForceJoin){
                    $hostForceButton.Text='FORZAR CLIENTES: SI'
                    $hostForceButton.AccessibleDescription='Los clientes entraran automaticamente cuando abras una partida.'
                    Set-CocoFlatButtonStyle $hostForceButton ([Drawing.Color]::FromArgb(45,28,68)) ([Drawing.Color]::FromArgb(183,239,194))
                }else{
                    $hostForceButton.Text='FORZAR CLIENTES: NO'
                    $hostForceButton.AccessibleDescription='Los clientes veran la partida pero podran unirse o jugar solos.'
                    Set-CocoFlatButtonStyle $hostForceButton ([Drawing.Color]::FromArgb(35,22,48)) ([Drawing.Color]::FromArgb(200,180,215))
                }
            }catch{}
        }
        & $updateForceButtonUi
        $hostForceButton.Add_Click({
            param($sender,$eventArgs)
            try{
                $script:CocoHostForceJoin=-not$script:CocoHostForceJoin
                & $updateForceButtonUi
                if($savePrefsCommand){
                    & $savePrefsCommand $script:CocoHostForceJoin
                }else{
                    Save-CocoHostPreferences $script:CocoHostForceJoin
                }
            }catch{
                Write-CocoLog "Error al guardar preferencia de forzar clientes: $($_.Exception.Message)"
            }
        })
        $script:CocoHostForceButton=$hostForceButton
        $script:CocoPanel.Controls.Add($hostForceButton)
    }
    Set-CocoLauncherUiLayout
    $script:CocoMediaInteraction=$false
    $managedExperiences=@($catalog.experiences|Where-Object{$_.managementMode-eq'managed'})
    $mediaExperiences=@($managedExperiences|Where-Object{Test-CocoMediaExperience $_})
    if($role-eq'host'){
        $script:CocoLauncherSelectedExperience=''
        Update-CocoExperienceCardsUi $dynamic $catalog $paths 'host'
        while(-not$script:CocoForm.IsDisposed){
            Set-CocoLauncherStep 3 'ELIGE QUE ALOJAR' 'Solo el host elige. Tus amigos recibiran automaticamente esta unica partida.' 24
            $script:CocoLauncherSelectedExperience=''
            while(-not$script:CocoForm.IsDisposed-and[string]::IsNullOrWhiteSpace($script:CocoLauncherSelectedExperience)){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            if($script:CocoForm.IsDisposed){break}
            $experience=@($catalog.experiences|Where-Object id -eq $script:CocoLauncherSelectedExperience|Select-Object -First 1)[0]
            Set-CocoExperienceCardsEnabled $dynamic $false
            $close.Enabled=$false
            try{
                Invoke-CocoLauncherHostSession $catalog $experience $paths $LegacyMinecraftRoot
                Set-CocoState 'Partida terminada' 'La partida se cerro. Ya puedes iniciar otra experiencia.' 15
            }catch{
                Write-CocoLog "ERROR Launcher host: $($_|Out-String)"
                Set-CocoState 'NO SE PUDO INICIAR LA PARTIDA' (Get-CocoLauncherFailureDetail $_) 0 $true 'failure'
            }
            Update-CocoExperienceCardsUi $dynamic $catalog $paths 'host'
            $close.Enabled=$true
        }
    }else{
        Update-CocoExperienceCardsUi $dynamic $catalog $paths 'client'
        $prepared=@{};$launched=$false;$session=$null;$clientFailureCount=0
        for($attempt=0;$attempt-lt2;$attempt++){
            $session=Get-CocoSessionAnnouncement $catalog
            if($session.State-ne'offline'){break}
            Set-CocoLauncherStep 3 'BUSCANDO PARTIDA COCO' 'Consultando la sesion administrada activa...' 22
            $until=(Get-Date).AddSeconds(1);while((Get-Date)-lt$until-and-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
        }
        if($script:CocoForm.IsDisposed){return}
        if($script:CocoMediaInteraction){
            Set-CocoLauncherIdleState 'El reproductor esta abierto. Puedes seguir usando el launcher cuando cierres el video.' 100
            while(-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            return
        }

        $action=Get-CocoClientSessionAction $session
        $mustForceJoin=$session-and$session.State-eq'ready'-and($session.Announcement.forceJoin-ne$false)

        if(-not$mustForceJoin){
            if($session-and$session.State-eq'ready'-and$session.Experience){
                $global:CocoLauncherLiveHostSession=$session
                Set-CocoLauncherIdleState ("{0} esta alojando {1}. Puedes unirte desde su tarjeta o jugar por tu cuenta."-f'El host',$session.Experience.name) 100
            }else{
                $global:CocoLauncherLiveHostSession=$null
                Set-CocoLauncherIdleState 'Selecciona una experiencia para instalarla, jugar o reproducir contenido.' 100
            }
            Update-CocoExperienceCardsUi $dynamic $catalog $paths 'client'

            $lastHostPoll=[DateTime]::MinValue
            while(-not$script:CocoForm.IsDisposed){
                [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100

                if((Get-Date)-gt$lastHostPoll.AddSeconds(4)){
                    $lastHostPoll=Get-Date
                    $polled=Get-CocoSessionAnnouncement $catalog
                    if($polled-and$polled.State-eq'ready'-and($polled.Announcement.forceJoin-ne$false)){
                        $session=$polled
                        $mustForceJoin=$true
                        break
                    }
                    $prevHostId=if($global:CocoLauncherLiveHostSession){[string]$global:CocoLauncherLiveHostSession.Experience.id}else{''}
                    $newHostId=if($polled-and$polled.State-eq'ready'-and$polled.Experience){[string]$polled.Experience.id}else{''}
                    if($prevHostId-ne$newHostId){
                        $global:CocoLauncherLiveHostSession=if($polled-and$polled.State-eq'ready'){$polled}else{$null}
                        if($global:CocoLauncherLiveHostSession){
                            Set-CocoLauncherIdleState ("{0} esta alojando {1}. Puedes unirte desde su tarjeta o jugar por tu cuenta."-f'El host',$polled.Experience.name) 100
                        }else{
                            Set-CocoLauncherIdleState 'Selecciona una experiencia para instalarla, jugar o reproducir contenido.' 100
                        }
                        Update-CocoExperienceCardsUi $dynamic $catalog $paths 'client'
                    }
                }

                if($script:CocoLauncherClientJoinRequested){
                    $joinExpId=[string]$script:CocoLauncherClientJoinRequested
                    $script:CocoLauncherClientJoinRequested=''
                    $fresh=Get-CocoSessionAnnouncement $catalog
                    if($fresh-and$fresh.State-eq'ready'-and[string]$fresh.Experience.id-eq$joinExpId){
                        $session=$fresh
                        $mustForceJoin=$true
                        break
                    }else{
                        Set-CocoLauncherIdleState 'La partida del host ya no esta disponible.' 100
                        $global:CocoLauncherLiveHostSession=$null
                        Update-CocoExperienceCardsUi $dynamic $catalog $paths 'client'
                    }
                }

                if($script:CocoLauncherClientRequestedExperience){
                    $playExpId=[string]$script:CocoLauncherClientRequestedExperience
                    $script:CocoLauncherClientRequestedExperience=''
                    $targetExp=@($catalog.experiences|Where-Object id -eq $playExpId|Select-Object -First 1)[0]
                    if($targetExp){
                        Set-CocoExperienceCardsEnabled $dynamic $false
                        $close.Enabled=$false
                        try{
                            $isStandalone=[string]$targetExp.launch.workflow-eq'coco-standalone'-or[string]$targetExp.runtime.type-eq'standalone'
                            $identity=if(-not$isStandalone){
                                Resolve-CocoLauncherIdentityUi $catalog $LegacyMinecraftRoot $paths 7 88
                            }else{
                                [pscustomobject]@{mode='offline';username='CocoPlayer';uuid=''}
                            }
                            if(-not$isStandalone){
                                $clientSkinSync=Sync-CocoSkinRegistry $catalog $paths $identity
                                if($script:CocoSkinTile){Set-CocoSkinTilePreview $script:CocoSkinPicture $script:CocoSkinLabel $paths.SkinRoot ([string]$identity.username) ([bool]$clientSkinSync.Pending)}
                            }
                            Set-CocoLauncherStep 8 'ABRIENDO EXPERIENCIA' ("Iniciando {0} en modo independiente..."-f$targetExp.name) 90
                            $launch=Start-CocoLauncherExperience $catalog $targetExp $identity client $paths $LegacyMinecraftRoot -DisableAutoJoin
                            if($isStandalone){
                                if(-not$launch-or-not$launch.Process){throw "No se pudo iniciar el proceso ejecutable de '$($targetExp.name)'."}
                                Set-CocoLauncherStep 9 'JUEGO STANDALONE ABIERTO' ("{0} esta ejecutandose."-f$targetExp.name) 96
                                try{
                                    try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Hide()}}catch{}
                                    while(-not$launch.Process.HasExited){
                                        [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
                                    }
                                }finally{
                                    Stop-CocoStandalonePopupGate
                                    try{$exitCode=$launch.Process.ExitCode}catch{$exitCode=0}
                                    try{if($launch.Process){$launch.Process.Dispose()}}catch{}
                                    try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Show();$script:CocoForm.Activate()}}catch{}
                                }
                            }else{
                                $instanceRoot=if($launch.Installation){[string]$launch.Installation.InstanceRoot}else{''}
                                [void](Wait-CocoManagedMinecraftWindow $instanceRoot $launch.Process 90)
                                Set-CocoLauncherStep 9 'MINECRAFT ABIERTO' 'Partida local iniciada.' 96
                                try{
                                    try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Hide()}}catch{}
                                    $exitCode=Wait-CocoPortableMcGame $launch.Process -PumpUi -Dispose
                                }finally{
                                    try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Show();$script:CocoForm.Activate()}}catch{}
                                }
                            }
                            Set-CocoLauncherIdleState 'Partida terminada. Puedes iniciar otra experiencia.' 100
                        }catch{
                            Write-CocoLog "ERROR Launcher client play: $($_|Out-String)"
                            Set-CocoState 'NO SE PUDO INICIAR LA PARTIDA' (Get-CocoLauncherFailureDetail $_) 0 $true 'failure'
                        }finally{
                            Set-CocoExperienceCardsEnabled $dynamic $true
                            Update-CocoExperienceCardsUi $dynamic $catalog $paths 'client'
                            $close.Enabled=$true
                        }
                    }
                }
            }
        }

        while($mustForceJoin-and-not$launched-and-not$script:CocoForm.IsDisposed){
            try{
                $action=Get-CocoClientSessionAction $session
                if($action.Action-eq'wait'){Set-CocoLauncherStep 3 ([string]$action.Message).ToUpperInvariant() 'Coco seguira buscando mientras esta ventana permanezca abierta.' 24}
                else{
                    Set-CocoLauncherStep 3 ([string]$action.Message).ToUpperInvariant() 'La unica experiencia online se selecciono automaticamente.' 25
                    $identityText.Enabled=$true;$close.Enabled=$false
                    $launch=Invoke-CocoLauncherClientSession $catalog $session $paths $LegacyMinecraftRoot $prepared
                    if(-not$launch){$identityText.Enabled=$true;$skinTile.Enabled=$true;$close.Enabled=$true}
                    else{
                        $launched=$true
                        if([string]$launch.Experience.launch.workflow-eq'coco-standalone'){
                            Set-CocoLauncherStep 9 'JUEGO STANDALONE ABIERTO' ("{0} se inicio automaticamente."-f$launch.Experience.name) 96
                            try{
                                try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Hide()}}catch{}
                                while(-not$launch.Process.HasExited){
                                    [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
                                }
                            }finally{
                                Stop-CocoStandalonePopupGate
                                try{$exitCode=$launch.Process.ExitCode}catch{$exitCode=0}
                                try{if($launch.Process){$launch.Process.Dispose()}}catch{}
                                try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){$script:CocoForm.Show();$script:CocoForm.Activate()}}catch{}
                            }
                            if($exitCode-ne0){
                                throw "El juego standalone '$($launch.Experience.name)' termino con codigo de error $exitCode."
                            }
                            $script:CocoAllowClose=$true;$script:CocoForm.Close();break
                        }else{
                            $instanceRoot=if($launch.Installation){[string]$launch.Installation.InstanceRoot}else{''}
                            [void](Wait-CocoManagedMinecraftWindow $instanceRoot $launch.Process 90)
                            Set-CocoLauncherStep 9 'CONECTANDO AUTOMATICAMENTE' 'La ventana de Minecraft ya esta abierta; Quick Play entrara al servidor sin elegirlo en menus.' 96
                            $script:CocoForm.Hide()
                            $exitCode=Wait-CocoPortableMcGame $launch.Process -PumpUi -Dispose
                            if($exitCode-ne0){
                                $script:CocoForm.Show();$script:CocoForm.Activate()
                                throw "Minecraft no pudo iniciarse o termino con codigo $exitCode. Revisa $($launch.LogPath)."
                            }
                            $script:CocoAllowClose=$true;$script:CocoForm.Close();break
                        }
                    }
                }
            }catch{
                if(-not$script:CocoForm.IsDisposed){$identityText.Enabled=$true;$skinTile.Enabled=$true;$close.Enabled=$true}
                $clientFailureCount++
                $failureText=Get-CocoLauncherFailureDetail $_
                $integrityFailure=([string]$_.Exception.Message)-match'(?i)416|range not satisfiable|sha-?256|integridad|no coincide|archivo descargado|paquete descargado|pack-inte?rity'
                $terminalFailure=$integrityFailure-or$clientFailureCount-ge3
                Write-CocoLog "ERROR Launcher client (attempt=$clientFailureCount; terminal=$terminalFailure; integrity=$integrityFailure): $($_|Out-String)"
                if($terminalFailure){
                    $launched=$true
                    $message=if($integrityFailure){'La descarga verificada no coincide con el paquete publicado.'}else{'Coco no pudo completar la preparacion despues de varios intentos.'}
                    $detail="$message`r`nCierra y vuelve a abrir Coco Launcher para reintentar.`r`n$failureText"
                    Set-CocoState $message $detail 0 $true 'failure'
                }else{Set-CocoState 'COCO DETECTO UN PROBLEMA' $failureText 0 $true 'failure'}
            }
            $until=(Get-Date).AddSeconds(3);while((Get-Date)-lt$until-and-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            if(-not$script:CocoForm.IsDisposed){
                $session=Get-CocoSessionAnnouncement $catalog
                $mustForceJoin=$session-and$session.State-eq'ready'-and($session.Announcement.forceJoin-ne$false)
            }
        }
    }
    if(-not$script:CocoForm.IsDisposed){while(-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}}
    }finally{
        if($script:CocoDefenderPlayWindowOwned){
            try{[void](Invoke-CocoDefenderPlayWindowEnd)}catch{Write-CocoLog "DEFENDER: restauracion fallo ($($_.Exception.Message))"}
            $script:CocoDefenderPlayWindowOwned=$false
        }
    }
}
