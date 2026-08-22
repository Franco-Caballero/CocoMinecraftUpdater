# Interruptor temporal de Windows Defender para las experiencias online-fix.
# Usa Defender Control v2.0 (https://github.com/pgkt04/defender-control, MIT) con binarios fijados.
# La desactivacion vive solo mientras Coco Launcher esta abierto; al cerrarse se restaura.

if(-not(Get-Command Write-CocoLog -ErrorAction SilentlyContinue)){
    function Write-CocoLog([string]$Text){
        if($script:CocoLogPath){
            try{ Add-Content -LiteralPath $script:CocoLogPath -Value ("{0:o} {1}" -f (Get-Date),$Text) -Encoding UTF8 }catch{}
        }
    }
}

$script:CocoDefenderControlRelease=[pscustomobject]@{
    version='v2.0'
    sourceUrl='https://github.com/pgkt04/defender-control'
    license='MIT'
    binaries=@(
        [pscustomobject]@{name='disable-defender.exe';url='https://github.com/pgkt04/defender-control/releases/download/v2.0/disable-defender.exe';size=286720;sha256='897307c0487c3f7376eedf6b3f999559e0aa16855571f30aef4621583f7ff46e'},
        [pscustomobject]@{name='enable-defender.exe';url='https://github.com/pgkt04/defender-control/releases/download/v2.0/enable-defender.exe';size=293376;sha256='123866f5752a876a562fe8fca3b61846aecf3881477d31aedf735e3357184224'}
    )
}

function Get-CocoDefenderToolRoot{
    Join-Path (Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater') 'tools\defender-control'
}

function Get-CocoDefenderBinaryName([bool]$Enabled){
    if($Enabled){'enable-defender.exe'}else{'disable-defender.exe'}
}

function Get-CocoDefenderTaskName([bool]$Enabled){
    if($Enabled){'CocoDefenderEnable'}else{'CocoDefenderDisable'}
}

function Test-CocoDefenderElevated{
    try{
        $principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }catch{return $false}
}

function Test-CocoDefenderBinaryIntact([string]$Path,[pscustomobject]$Binary){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    try{
        if((Get-Item -LiteralPath $Path).Length-ne[int64]$Binary.size){return $false}
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()-eq([string]$Binary.sha256).ToLowerInvariant()
    }catch{return $false}
}

function Ensure-CocoDefenderToolBinaries{
    param(
        [pscustomobject]$Release=$script:CocoDefenderControlRelease,
        [string]$Root=(Get-CocoDefenderToolRoot)
    )
    New-Item -ItemType Directory -Path $Root -Force|Out-Null
    foreach($binary in @($Release.binaries)){
        $path=Join-Path $Root ([string]$binary.name)
        if(Test-CocoDefenderBinaryIntact $path $binary){continue}
        if(-not(Get-Command Download-VerifiedFile -ErrorAction SilentlyContinue)){throw 'El engine no contiene el descargador verificado requerido.'}
        Download-VerifiedFile ([string]$binary.url) $path ([string]$binary.sha256) 0 ([int64]$binary.size) ("Herramientas de juego {0}"-f$Release.version)
        if(-not(Test-CocoDefenderBinaryIntact $path $binary)){
            throw ("El antivirus elimino '{0}' recien descargado. Agrega '{1}' como exclusion de Windows Defender y vuelve a abrir Coco."-f$binary.name,$Root)
        }
    }
    @($Release.binaries|ForEach-Object{Join-Path $Root ([string]$_.name)})
}

function Test-CocoDefenderExclusionPresent([string]$Root){
    try{
        $paths=@(Get-MpPreference -ErrorAction Stop|Select-Object -ExpandProperty ExclusionPath)
        if(-not$paths.Count){return $false}
        return (@($paths)|Where-Object{$_-eq$Root}).Count-gt0
    }catch{return $false}
}

function New-CocoDefenderTaskInline([string]$ExePath,[string]$TaskName){
    $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $TaskName -Action (New-ScheduledTaskAction -Execute $ExePath -Argument '-s') -Principal $principal -Settings $settings -Force|Out-Null
}

function Ensure-CocoDefenderSessionSetup{
    param(
        [pscustomobject]$Release=$script:CocoDefenderControlRelease,
        [string]$Root=(Get-CocoDefenderToolRoot)
    )
    New-Item -ItemType Directory -Path $Root -Force|Out-Null
    $missingBinaries=@($Release.binaries|Where-Object{-not(Test-CocoDefenderBinaryIntact (Join-Path $Root ([string]$_.name)) $_)}).Count-gt0
    $needExclusion=-not(Test-CocoDefenderExclusionPresent $Root)
    $taskDisable=Get-CocoDefenderTaskName $false
    $taskEnable=Get-CocoDefenderTaskName $true
    $needTasks=-not(Test-CocoDefenderTaskExists $taskDisable)-or-not(Test-CocoDefenderTaskExists $taskEnable)
    if(-not$missingBinaries-and-not$needExclusion-and-not$needTasks){return $true}
    if(Test-CocoDefenderElevated){
        if($needExclusion){
            try{Add-MpPreference -ExclusionPath $Root -ErrorAction Stop}catch{Write-CocoLog "DEFENDER: no se pudo agregar la exclusion ($($_.Exception.Message))"}
        }
        foreach($binary in @($Release.binaries)){
            try{
                New-CocoDefenderTaskInline (Join-Path $Root ([string]$binary.name)) (Get-CocoDefenderTaskName (([string]$binary.name)-like'enable*'))
            }catch{Write-CocoLog "DEFENDER: tarea no registrada en sesion elevada ($($_.Exception.Message))"}
        }
        Write-CocoLog 'DEFENDER: exclusion y tareas preparadas sin ventanas adicionales (sesion de administrador).'
        return ((Test-CocoDefenderExclusionPresent $Root)-and(Test-CocoDefenderTaskExists $taskDisable)-and(Test-CocoDefenderTaskExists $taskEnable))
    }
    # Una sola elevacion prepara exclusion y tareas para todas las sesiones futuras;
    # debe ejecutarse ANTES de descargar los binarios para que el antivirus no los elimine.
    if($missingBinaries-or$needExclusion-or$needTasks){
        [void](Register-CocoDefenderTasks -Release $Release -Root $Root)
    }
    return ((Test-CocoDefenderTaskExists $taskDisable)-and(Test-CocoDefenderTaskExists $taskEnable))
}

function Invoke-CocoDefenderBinaryDirect([string]$Path){
    Start-Process -FilePath $Path -ArgumentList '-s' -WindowStyle Hidden -Wait
}

function Invoke-CocoDefenderBinaryElevatedPrompt([string]$Path){
    Start-Process -FilePath $Path -ArgumentList '-s' -Verb RunAs -WindowStyle Hidden -Wait
}

function Test-CocoDefenderTaskExists([string]$TaskName){
    schtasks.exe /Query /TN $TaskName *>$null
    return ($LASTEXITCODE-eq0)
}

function Start-CocoDefenderTask([string]$TaskName){
    schtasks.exe /Run /TN $TaskName *>$null
    return ($LASTEXITCODE-eq0)
}

function Register-CocoDefenderTasks{
    param(
        [pscustomobject]$Release=$script:CocoDefenderControlRelease,
        [string]$Root=(Get-CocoDefenderToolRoot)
    )
    $escape=[scriptblock]::Create('param([string]$Value) $Value-replace"''","''''"')
    $user=& $escape ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $escapedRoot=& $escape $Root
    $text=[Text.StringBuilder]::new('$ErrorActionPreference="Stop"`r`ntry{`r`n')
    foreach($binary in @($Release.binaries)){
        $enabled=(([string]$binary.name)-like'enable*')
        $exe=& $escape (Join-Path $Root ([string]$binary.name))
        $task=& $escape (Get-CocoDefenderTaskName $enabled)
        [void]$text.AppendLine(("Register-ScheduledTask -TaskName '$task' -Action (New-ScheduledTaskAction -Execute '$exe' -Argument '-s') -Principal (New-ScheduledTaskPrincipal -UserId '$user' -LogonType Interactive -RunLevel Highest) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)) -Force|Out-Null"))
    }
    [void]$text.AppendLine("try{Add-MpPreference -ExclusionPath '$escapedRoot' -ErrorAction Stop}catch{}")
    [void]$text.Append('exit 0}catch{exit 1}')
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text.ToString()))
    try{
        $process=Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    }catch{return $false}
    if($process.ExitCode-ne0){return $false}
    foreach($binary in @($Release.binaries)){
        if(-not(Test-CocoDefenderTaskExists (Get-CocoDefenderTaskName (([string]$binary.name)-like'enable*')))){return $false}
    }
    Write-CocoLog 'DEFENDER: tareas programadas registradas para alternar la proteccion sin ventanas de UAC.'
    return $true
}

function Wait-CocoDefenderRealTimeProtection([bool]$ExpectedEnabled,[int]$TimeoutSeconds){
    $deadline=(Get-Date).AddSeconds([Math]::Max(1,$TimeoutSeconds))
    do{
        try{
            $status=Get-MpComputerStatus -ErrorAction Stop
            if([bool]$status.RealTimeProtectionEnabled-eq$ExpectedEnabled){return $true}
        }catch{}
        try{if($script:CocoForm-and-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents()}}catch{}
        Start-Sleep -Milliseconds 600
    }while((Get-Date)-lt$deadline)
    return $false
}

function Set-CocoDefenderProtection{
    param(
        [bool]$Enabled,
        [pscustomobject]$Release=$script:CocoDefenderControlRelease,
        [string]$Root=(Get-CocoDefenderToolRoot)
    )
    [void](Ensure-CocoDefenderSessionSetup -Release $Release -Root $Root)
    [void](Ensure-CocoDefenderToolBinaries -Release $Release -Root $Root)
    $path=Join-Path $Root (Get-CocoDefenderBinaryName $Enabled)
    if(Test-CocoDefenderElevated){Invoke-CocoDefenderBinaryDirect $path;return}
    $task=Get-CocoDefenderTaskName $Enabled
    if((Test-CocoDefenderTaskExists $task)-and(Start-CocoDefenderTask $task)){return}
    if((Register-CocoDefenderTasks -Release $Release -Root $Root)-and(Start-CocoDefenderTask $task)){return}
    Invoke-CocoDefenderBinaryElevatedPrompt $path
}

function Invoke-CocoDefenderPlayWindowStart{
    if($script:CocoDefenderPlayWindowActive){return $true}
    try{
        Set-CocoDefenderProtection $false
        $script:CocoDefenderPlayWindowActive=$true
        $confirmed=Wait-CocoDefenderRealTimeProtection $false 8
        $tamper=Get-CocoDefenderTamperProtection
        Write-CocoLog "DEFENDER: proteccion desactivada para esta sesion Coco (confirmada=$confirmed; proteccionContraAlteraciones=$tamper)."
        if(-not$confirmed){
            Show-CocoDefenderTamperGuidance
        }
        return $true
    }catch{
        Write-CocoLog "DEFENDER: no se pudo desactivar la proteccion ($($_.Exception.Message))."
        return $false
    }
}

function Get-CocoDefenderTamperProtection{
    try{return [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected}catch{return $null}
}

function Show-CocoDefenderTamperGuidance{
    param([string]$MarkerPath=(Join-Path (Get-CocoDefenderToolRoot) 'tamper-guidance.flag'))
    if(Test-Path -LiteralPath $MarkerPath -PathType Leaf){return}
    try{
        Add-Type -AssemblyName System.Windows.Forms
        $message="Coco necesita UN solo paso manual para jugar las experiencias online-fix.`r`n`r`nDesactiva la 'Proteccion contra alteraciones' en Seguridad de Windows:`r`nProteccion contra virus y amenazas > Administrar configuracion > Proteccion contra alteraciones: No.`r`n`r`nWindows prohibe que cualquier programa mueva ese interruptor por ti. Es un paso unico: despues, Coco activa y restaura la proteccion automaticamente cada vez que abres o cierras el launcher."
        $choice=[Windows.Forms.MessageBox]::Show($message,'Coco Launcher - paso unico',[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Information)
        if($choice-eq[Windows.Forms.DialogResult]::OK){
            try{Start-Process 'windowsdefender:'}catch{}
        }
        Set-Content -LiteralPath $MarkerPath -Value (Get-Date).ToString('o') -Encoding UTF8
        Write-CocoLog 'DEFENDER: guia de Proteccion contra alteraciones mostrada una sola vez.'
    }catch{Write-CocoLog "DEFENDER: no se pudo mostrar la guia ($($_.Exception.Message))"}
}

function Invoke-CocoDefenderPlayWindowEnd{
    if(-not$script:CocoDefenderPlayWindowActive){return $false}
    $script:CocoDefenderPlayWindowActive=$false
    try{
        Set-CocoDefenderProtection $true
        $confirmed=Wait-CocoDefenderRealTimeProtection $true 12
        Write-CocoLog "DEFENDER: proteccion restaurada tras cerrar Coco (confirmada=$confirmed)."
        return $true
    }catch{
        Write-CocoLog "DEFENDER: no se pudo restaurar automaticamente ($($_.Exception.Message)). Ejecuta '$(Join-Path (Get-CocoDefenderToolRoot) 'enable-defender.exe')' como administrador."
        return $false
    }
}
