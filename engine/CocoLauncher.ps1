function Test-CocoPathWithin([string]$Path,[string]$Root){
    if([string]::IsNullOrWhiteSpace($Path)-or[string]::IsNullOrWhiteSpace($Root)){return $false}
    try{
        $resolvedPath=[IO.Path]::GetFullPath($Path).TrimEnd('\')
        $resolvedRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\')
        return $resolvedPath.StartsWith($resolvedRoot+'\',[StringComparison]::OrdinalIgnoreCase)
    }catch{return $false}
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

function Test-CocoSafeRelativePath([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)-or$Path.Contains(':')){return $false}
    $normalized=$Path-replace'\\','/'
    if($normalized.StartsWith('/')-or$normalized.EndsWith('/')){return $false}
    foreach($segment in $normalized.Split('/')){
        if([string]::IsNullOrWhiteSpace($segment)-or$segment-in@('.','..')){return $false}
    }
    return $true
}

function Test-CocoManagedGameRunning([string]$InstanceRoot){
    if([string]::IsNullOrWhiteSpace($InstanceRoot)){return $false}
    $full=[IO.Path]::GetFullPath($InstanceRoot)
    try{
        $matches=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop|Where-Object{
            -not[string]::IsNullOrWhiteSpace($_.CommandLine)-and$_.CommandLine.IndexOf($full,[StringComparison]::OrdinalIgnoreCase)-ge0
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
            $property=$null
            if(-not[string]::IsNullOrWhiteSpace($selected)){$property=$profile.accounts.PSObject.Properties[$selected]}
            if(-not$property-and$accounts.Count-eq1){$property=$accounts[0]}
            if($property){
                $account=$property.Value
                $type=([string]$account.type).Trim().ToLowerInvariant()
                $username=([string]$account.displayName).Trim()
                if([string]::IsNullOrWhiteSpace($username)){$username=([string]$account.username).Trim()}
                if([string]::IsNullOrWhiteSpace($username)){$username=([string]$account.userID).Trim()}
                if($type-in@('free','tlauncher')){
                    return [pscustomobject]@{Mode='offline';Confidence='high';Username=$username;Source='tlauncher-profile';Reason="TLauncher declara una cuenta local de tipo '$type'."}
                }
                if($type-match'^(msa|microsoft|mojang|microsoft_account|mojang_account)$'){
                    return [pscustomobject]@{Mode='microsoft';Confidence='high';Username=$username;Source='tlauncher-profile';Reason="TLauncher declara una cuenta autenticada de tipo '$type'."}
                }
                if($null-ne$account.premiumAccount-and-not[bool]$account.premiumAccount-and-not[string]::IsNullOrWhiteSpace($username)){
                    return [pscustomobject]@{Mode='offline';Confidence='medium';Username=$username;Source='tlauncher-profile';Reason='TLauncher declara premiumAccount=false, pero usa un tipo de cuenta desconocido.'}
                }
                return [pscustomobject]@{Mode='unknown';Confidence='none';Username=$username;Source='tlauncher-profile';Reason="TLauncher usa un tipo de cuenta no reconocido: '$type'."}
            }
            if($accounts.Count-gt1){return [pscustomobject]@{Mode='unknown';Confidence='none';Username='';Source='tlauncher-profile';Reason='TLauncher contiene varias cuentas y ninguna seleccion inequivoca.'}}
        }catch{
            return [pscustomobject]@{Mode='unknown';Confidence='none';Username='';Source='tlauncher-profile';Reason='El perfil TLauncher no pudo analizarse de forma segura.'}
        }
    }

    foreach($officialProfile in 'launcher_profiles_microsoft_store.json','launcher_profiles.json'){
        if(Test-Path -LiteralPath (Join-Path $MinecraftRoot $officialProfile) -PathType Leaf){
            return [pscustomobject]@{Mode='microsoft';Confidence='likely';Username='';Source='official-launcher-profile';Reason='Existe una instalacion del Launcher oficial; la propiedad se confirmara durante Microsoft login.'}
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
    [ValidateSet('microsoft','offline')][string]$Mode,
    [string]$Username='',
    [string]$Uuid='',
    [string]$DecisionSource='user'
){
    if($Mode-eq'offline'-and -not(Test-CocoMinecraftUsername $Username)){throw 'El nombre local debe tener entre 3 y 16 caracteres y usar solo letras, numeros o guion bajo.'}
    if(-not[string]::IsNullOrWhiteSpace($Uuid)-and$Uuid-notmatch'^[a-fA-F0-9-]{32,36}$'){throw 'El UUID Microsoft no es valido.'}
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
    if($saved){
        return [pscustomobject]@{Status='configured';RequiresChoice=$false;WasAutomatic=$false;Identity=$saved;Hint=$null}
    }
    $hint=Get-CocoLauncherIdentityHint $MinecraftRoot
    if($hint.Mode-eq'offline'-and$hint.Confidence-in@('high','medium')-and(Test-CocoMinecraftUsername ([string]$hint.Username))){
        $identity=Save-CocoLauncherIdentityState $StatePath offline ([string]$hint.Username) '' ([string]$hint.Source)
        return [pscustomobject]@{Status='configured';RequiresChoice=$false;WasAutomatic=$true;Identity=$identity;Hint=$hint}
    }
    if($hint.Mode-eq'microsoft'-and$hint.Confidence-in@('high','likely')){
        $identity=Save-CocoLauncherIdentityState $StatePath microsoft ([string]$hint.Username) '' ([string]$hint.Source)
        return [pscustomobject]@{Status='microsoft-login-required';RequiresChoice=$false;WasAutomatic=$true;Identity=$identity;Hint=$hint}
    }
    [pscustomobject]@{Status='choice-required';RequiresChoice=$true;WasAutomatic=$false;Identity=$null;Hint=$hint}
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
    if($Identity.mode-eq'microsoft'){
        $arguments.Add('--auth')
        if(-not[string]::IsNullOrWhiteSpace([string]$Identity.uuid)){$arguments.Add('--uuid');$arguments.Add([string]$Identity.uuid)}
        elseif(Test-CocoMinecraftUsername ([string]$Identity.username)){$arguments.Add('--username');$arguments.Add([string]$Identity.username)}
        else{throw 'La cuenta Microsoft aun no fue vinculada: falta UUID o nombre confirmado por PortableMC.'}
    }elseif($Identity.mode-eq'offline'){
        if(-not(Test-CocoMinecraftUsername ([string]$Identity.username))){throw 'La identidad local no tiene un nombre Minecraft valido.'}
        $arguments.Add('--username');$arguments.Add([string]$Identity.username)
    }else{throw 'El modo de identidad no es compatible.'}
    if($Experience.launch.memory){
        $minimum=[int]$Experience.launch.memory.minimumMb;$recommended=[int]$Experience.launch.memory.recommendedMb
        $fraction=[double]$Experience.launch.memory.maximumPhysicalFraction
        $physicalMb=0
        try{$physicalMb=[int]((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory/1MB)}catch{}
        $heap=if($physicalMb-gt0){[Math]::Min($recommended,[Math]::Floor($physicalMb*$fraction))}else{[Math]::Min($recommended,4096)}
        $heap=[Math]::Max($minimum,[int]$heap)
        $arguments.Add(("--jvm-arg=-Xms1024m,-Xmx{0}m"-f$heap))
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
                    Set-CocoState $ActivityTitle ("{0}`r`n[{1:mm\:ss}] {2}" -f $ActivityDetail, $watch.Elapsed, $lastLine) $progress
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

function Get-CocoPortableMcAuthSessions(
    [string]$Executable,
    [string]$MainDir,
    [string]$MicrosoftDatabase
){
    $result=Invoke-CocoPortableMcCommand $Executable @('--main-dir',$MainDir,'--msa-db-file',$MicrosoftDatabase,'--output','machine','auth','list') 30
    if($result.ExitCode-ne0){throw "PortableMC no pudo leer las cuentas Microsoft: $($result.Stderr.Trim())"}
    $headers=$null
    $sessions=[Collections.Generic.List[object]]::new()
    foreach($line in ($result.Stdout-split"`r?`n")){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $parts=@($line-split"`t"|ForEach-Object{ConvertFrom-CocoPortableMcMachineValue $_})
        if($parts[0]-eq'row'-and-not$headers){$headers=@($parts|Select-Object -Skip 1);continue}
        if($parts[0]-ne'row'-or-not$headers){continue}
        $values=@($parts|Select-Object -Skip 1)
        $record=[ordered]@{}
        for($index=0;$index-lt$headers.Count;$index++){$record[$headers[$index]]=if($index-lt$values.Count){$values[$index]}else{''}}
        if((Test-CocoMinecraftUsername ([string]$record.username))-and[string]$record.uuid-match'^[a-fA-F0-9-]{32,36}$'){
            $sessions.Add([pscustomobject]@{Username=[string]$record.username;Uuid=[string]$record.uuid})
        }
    }
    $sessions.ToArray()
}

function Complete-CocoMicrosoftIdentityFromSessions([string]$StatePath,[object[]]$Sessions){
    $state=Read-CocoLauncherIdentityState $StatePath
    if(-not$state-or$state.mode-ne'microsoft'){throw 'Coco no esta configurado para una identidad Microsoft.'}
    $valid=@($Sessions|Where-Object{(Test-CocoMinecraftUsername ([string]$_.Username))-and([string]$_.Uuid-match'^[a-fA-F0-9-]{32,36}$')})
    $selected=$null
    if($state.uuid){$selected=@($valid|Where-Object Uuid -eq $state.uuid|Select-Object -First 1)[0]}
    if(-not$selected-and$state.username){$selected=@($valid|Where-Object Username -eq $state.username|Select-Object -First 1)[0]}
    if(-not$selected-and$valid.Count-eq1){$selected=$valid[0]}
    if(-not$selected){return [pscustomobject]@{Status=if($valid.Count){'account-choice-required'}else{'login-required'};Identity=$state;Sessions=$valid}}
    $identity=Save-CocoLauncherIdentityState $StatePath microsoft ([string]$selected.Username) ([string]$selected.Uuid) 'portablemc-authenticated'
    [pscustomobject]@{Status='configured';Identity=$identity;Sessions=$valid}
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
            Start-Sleep -Milliseconds 100
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
        [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
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
            Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))
        }
    }
    throw "PortableMC no pudo preparar '$ExperienceId' despues de $MaximumAttempts intentos: $lastDetail"
}

function Publish-CocoSessionAnnouncement(
    $Catalog,
    [string]$ExperienceId,
    [ValidateSet('preparing','ready','stopping')][string]$State,
    [string]$SessionId,
    [string]$Path,
    [int]$TtlSeconds=30
){
    if($SessionId-notmatch'^[a-fA-F0-9-]{32,36}$'){throw 'El sessionId Coco no es valido.'}
    $experience=@($Catalog.experiences|Where-Object id -eq $ExperienceId|Select-Object -First 1)[0]
    if(-not$experience){throw "La experiencia '$ExperienceId' no existe en el catalogo."}
    if($experience.managementMode-ne'managed'-or$experience.launch.workflow-ne'coco-managed'){throw "La experiencia '$ExperienceId' usa su launcher externo y no puede anunciarse como sesion Coco Launcher."}
    $maximum=[int]$Catalog.sessionDiscovery.maximumTtlSeconds
    if($TtlSeconds-lt5-or$TtlSeconds-gt$maximum){throw 'El TTL solicitado para la sesion Coco es invalido.'}
    $now=[DateTime]::UtcNow
    $payload=[ordered]@{
        schemaVersion=1;sessionId=$SessionId;state=$State;experienceId=[string]$experience.id
        packVersion=[string]$experience.pack.version;host=[string]$experience.hosting.host;port=[int]$experience.hosting.port
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
    if($experience.managementMode-ne'managed'-or$experience.launch.workflow-ne'coco-managed'){throw 'La sesion intento anunciar una experiencia reservada al launcher externo.'}
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
        if(-not$connect.AsyncWaitHandle.WaitOne([int]$discovery.connectTimeoutMs)){return [pscustomobject]@{State='offline';Experience=$null;Reason='unreachable'}}
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
    }catch [Net.Sockets.SocketException]{
        [pscustomobject]@{State='offline';Experience=$null;Reason='unreachable'}
    }finally{$client.Dispose()}
}

function Get-CocoClientSessionAction($Session){
    if(-not$Session-or$Session.State-eq'offline'){return [pscustomobject]@{Action='wait';Message='No hay ninguna partida Coco online';Experience=$null}}
    switch([string]$Session.State){
        'preparing'{return [pscustomobject]@{Action='prepare';Message=("El host esta preparando {0}"-f$Session.Experience.name);Experience=$Session.Experience}}
        'ready'{return [pscustomobject]@{Action='launch';Message=("Entrando a {0}"-f$Session.Experience.name);Experience=$Session.Experience}}
        'stopping'{return [pscustomobject]@{Action='wait';Message='La partida Coco esta terminando';Experience=$Session.Experience}}
        default{throw 'El cliente recibio un estado de sesion no soportado.'}
    }
}

function Start-CocoSessionService(
    [string]$ServiceScript,
    [string]$StatePath,
    [string]$LogPath,
    [int64]$ParentPid=$PID
){
    if(-not(Test-Path -LiteralPath $ServiceScript -PathType Leaf)){throw 'Falta CocoSessionService.ps1 en el engine.'}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$ServiceScript,'-BindAddress','10.77.37.1','-Port','25564','-StatePath',$StatePath,'-ParentPid',[string]$ParentPid,'-LogPath',$LogPath)
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
                Start-Sleep -Milliseconds 150
                if($process.HasExited){throw "El servicio de sesion Coco no pudo conservar el puerto 25564 (codigo $($process.ExitCode))."}
                return $process
            }
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
        if(-not$experience.runtime-or[string]::IsNullOrWhiteSpace([string]$experience.runtime.minecraftVersion)){throw "Runtime incompleto para '$id'."}
        if($experience.runtime.loader-notin@('fabric','forge','neoforge')){throw "Loader invalido para '$id'."}
        if([int]$experience.runtime.javaMajor-notin@(8,17,21,25)){throw "Java no soportado para '$id'."}
        if($experience.runtimePolicies-and$experience.runtimePolicies.essentialLoaderUpdates-and[string]$experience.runtimePolicies.essentialLoaderUpdates-ne'disabled'){
            throw "Politica Essential Loader invalida para '$id'."
        }
        if(-not$experience.hosting-or$experience.hosting.mode-notin@('lan','dedicated','either')){throw "Modo de hosting invalido para '$id'."}
        $port=[int]$experience.hosting.port
        if($port-lt1-or$port-gt65535){throw "Puerto invalido para '$id'."}
        if(-not$experience.launch-or[string]::IsNullOrWhiteSpace([string]$experience.launch.serverName)){throw "Lanzamiento incompleto para '$id'."}
        $expectedWorkflow=if($experience.managementMode-eq'managed'){'coco-managed'}else{'external-launcher'}
        if([string]$experience.launch.workflow-ne$expectedWorkflow){throw "Workflow de lanzamiento invalido para '$id'."}
        if($experience.managementMode-eq'legacy-current'-and[bool]$experience.launch.autoJoin){throw "Coco original no puede autoarrancarse desde Coco Launcher."}
        if($experience.launch.minimumFreeBytes-and[int64]$experience.launch.minimumFreeBytes-lt1073741824){throw "minimumFreeBytes invalido para '$id'."}
        if($experience.launch.memory){
            $minimum=[int]$experience.launch.memory.minimumMb;$recommended=[int]$experience.launch.memory.recommendedMb;$fraction=[double]$experience.launch.memory.maximumPhysicalFraction
            if($minimum-lt1024-or$recommended-lt$minimum-or$recommended-gt32768-or$fraction-lt0.25-or$fraction-gt0.75){throw "Politica de memoria invalida para '$id'."}
        }
        if($experience.managementMode-eq'managed'){
            if(-not(Test-CocoSafeRelativePath ([string]$experience.pack.lockPath))){throw "lockPath invalido para '$id'."}
            if($experience.pack.redistribution-ne'origin-only'){throw "La experiencia '$id' no declara distribucion desde origen."}
            if($experience.pack.excludedPaths){
                foreach($excludedPath in @($experience.pack.excludedPaths)){
                    if([string]::IsNullOrWhiteSpace([string]$excludedPath)-or-not(Test-CocoSafeRelativePath ([string]$excludedPath))-or-not([string]$excludedPath).StartsWith('mods/',[StringComparison]::OrdinalIgnoreCase)){
                        throw "Exclusion de pack invalida para '$id': '$excludedPath'."
                    }
                }
            }
            if($experience.worldTemplate){
                if(-not(Test-CocoSafeRelativePath ([string]$experience.worldTemplate.lockPath))){throw "worldTemplate.lockPath invalido para '$id'."}
                if([string]$experience.worldTemplate.installRole-ne'host'){throw "El mundo de '$id' debe instalarse exclusivamente en el host."}
                if([string]$experience.worldTemplate.firstRunPolicy-ne'create-once-preserve-forever'){throw "Politica de mundo invalida para '$id'."}
            }
        }
        foreach($file in @($experience.files)){
            if(-not (Test-CocoSafeRelativePath ([string]$file.path))){throw "Ruta administrada insegura en '$id': '$($file.path)'."}
            if([string]$file.sha256-notmatch'^[a-fA-F0-9]{64}$'){throw "SHA-256 invalido en '$id': '$($file.path)'."}
            if([int64]$file.size-lt0){throw "Tamano invalido en '$id': '$($file.path)'."}
            if($file.policy-notin@('replace','merge','preserve','migrate')){throw "Politica invalida en '$id': '$($file.path)'."}
            if($file.role-and$file.role-notin@('all','client','host')){throw "Rol de archivo invalido en '$id': '$($file.path)'."}
            if([string]$file.sourceUrl-notmatch'^https://cdn\.modrinth\.com/data/'){throw "Origen de archivo no permitido en '$id': '$($file.path)'."}
        }
    }
    return $catalog
}

function Read-CocoExperienceLock([string]$Path,$Experience){
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "No existe el lock de experiencia: $Path"}
    try{$lock=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "El lock de experiencia no es JSON valido: $($_.Exception.Message)"}
    if([int]$lock.schemaVersion-ne1-or$lock.source.provider-ne'curseforge'-or$lock.source.redistribution-ne'origin-only'){throw 'El lock de experiencia usa un origen o schema no soportado.'}
    if([string]$lock.runtime.minecraftVersion-ne[string]$Experience.runtime.minecraftVersion-or[string]$lock.runtime.loader-ne[string]$Experience.runtime.loader-or[string]$lock.runtime.loaderVersion-ne[string]$Experience.runtime.loaderVersion){throw 'El runtime del lock no coincide con el catalogo.'}
    if(-not$lock.pack.archive-or[string]$lock.pack.archive.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$lock.pack.archive.size-le0){throw 'El archivo fuente del pack no esta fijado.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($asset in @($lock.assets)){
        if(([int64]$asset.projectId-le0-or[int64]$asset.fileId-le0)-and[string]$asset.sourceUrl-notmatch'^https://cdn\.modrinth\.com/'){throw 'El lock contiene un asset CurseForge sin IDs validos.'}
        $allowedRoot=@('mods/','resourcepacks/','shaderpacks/')|Where-Object{([string]$asset.path).StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1
        if(-not(Test-CocoSafeRelativePath ([string]$asset.path))-or-not$allowedRoot){throw "Ruta de asset invalida en lock: '$($asset.path)'."}
        if(-not$paths.Add([string]$asset.path)){throw "Ruta duplicada en lock: '$($asset.path)'."}
        if([string]$asset.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$asset.size-le0){throw "Asset no fijado correctamente: '$($asset.path)'."}
        if([string]$asset.sourceUrl-notmatch'^https://(www\.curseforge\.com/api/v1/mods/[0-9]+/files/[0-9]+/download|cdn\.modrinth\.com/data/|optifine\.net/download)'){throw "Origen de asset invalido: '$($asset.sourceUrl)'."}
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

function Get-CocoLockedAsset([string]$CacheRoot,$Asset,[hashtable]$ProgressContext){
    if([string]$Asset.sha256-notmatch'^[a-fA-F0-9]{64}$'-or[int64]$Asset.size-le0){throw 'El asset no tiene hash o tamano valido.'}
    if($ProgressContext){
        $ProgressContext.Index=[int]$ProgressContext.Index+1
        $itemPrefix="Archivo $($ProgressContext.Index)/$($ProgressContext.Count) | $([string]$Asset.name)"
        $range=[Math]::Max(1,[int]$ProgressContext.ProgressEnd-[int]$ProgressContext.ProgressStart)
        $rawStart=[int]$ProgressContext.ProgressStart+[int]($range*[int64]$ProgressContext.CompletedBytes/[Math]::Max(1,[int64]$ProgressContext.TotalBytes))
        $itemStart=[Math]::Max(0,[Math]::Min(100,$rawStart))
    }
    $destination=Get-CocoLockedAssetCachePath $CacheRoot $Asset
    if((Test-Path -LiteralPath $destination -PathType Leaf)-and(Get-Item -LiteralPath $destination).Length-eq[int64]$Asset.size-and(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()-eq([string]$Asset.sha256).ToLowerInvariant()){
        if($ProgressContext){
            $ProgressContext.CompletedBytes=[int64]$ProgressContext.CompletedBytes+[int64]$Asset.size
            Set-CocoLauncherStep ([int]$ProgressContext.Step) ([string]$ProgressContext.Title) "$itemPrefix`r`nVerificado y reutilizado desde la cache local." $itemStart
        }
        return $destination
    }
    $url=[string]$Asset.sourceUrl
    if($url-notmatch'^https://(www\.curseforge\.com/api/v1/mods/[0-9]+/files/[0-9]+/download|cdn\.modrinth\.com/data/)'){throw "Origen de asset Coco no permitido: '$url'."}
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
        if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()-ne([string]$Asset.sha256).ToLowerInvariant()){throw "El asset '$($Asset.name)' no coincide con el SHA-256 fijado."}
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
            try {
                $web = [System.Net.WebClient]::new()
                $web.Headers.Add("User-Agent", "CocoMinecraftUpdater/1.0")
                $web.DownloadFile([string]$Asset.sourceUrl, $temp)
                $web.Dispose()
                
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
            } finally {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
            }
        }
        
        foreach ($mAsset in $missing) {
            $ps = [powershell]::Create().AddScript($workerScript).AddArgument($CacheRoot).AddArgument($mAsset)
            $ps.RunspacePool = $pool
            [void]$tasks.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Asset = $mAsset })
        }
        
        foreach ($task in $tasks) {
            try {
                $res = $task.PS.EndInvoke($task.Handle)
                if ($res -and $res.Count) {
                    $item = $res[0]
                    $cachedResults[[string]$item.sha256] = [string]$item.path
                    if ($ProgressContext) {
                        $ProgressContext.CompletedBytes = [int64]$ProgressContext.CompletedBytes + [int64]$item.size
                        $ProgressContext.Index = [int]$ProgressContext.Index + 1
                        $pct = [int]($ProgressContext.ProgressStart + ($ProgressContext.ProgressEnd - $ProgressContext.ProgressStart) * [int64]$ProgressContext.CompletedBytes / [Math]::Max(1, [int64]$ProgressContext.TotalBytes))
                        Set-CocoLauncherStep ([int]$ProgressContext.Step) ([string]$ProgressContext.Title) ("Descargando en paralelo (hilo $($ProgressContext.Index)/$($ProgressContext.Count)): $($task.Asset.name)") $pct
                    }
                }
            } catch {
                $single = Get-CocoLockedAsset $CacheRoot $task.Asset $ProgressContext
                $cachedResults[([string]$task.Asset.sha256).ToLowerInvariant()] = $single
            } finally {
                $task.PS.Dispose()
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

function Install-CocoManagedExperience(
    $Experience,
    $Lock,
    [string]$ExperiencesRoot,
    [string]$CacheRoot,
    [ValidateSet('client','host')][string]$Role='client'
){
    if($Experience.managementMode-ne'managed'){throw 'La experiencia no esta marcada como administrada.'}
    $instanceRoot=Join-Path $ExperiencesRoot ([string]$Experience.instanceId)
    if(-not(Test-CocoPathWithin $instanceRoot $ExperiencesRoot)){throw 'La raiz de instancia escapa del directorio de experiencias.'}
    if(Test-CocoManagedGameRunning $instanceRoot){throw "La instancia '$($Experience.name)' ya esta abierta. Cierrala antes de verificar sus archivos."}
    if([int64]$Experience.launch.minimumFreeBytes-gt0){
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($ExperiencesRoot)))
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
        # los bytes y el rol decide el subconjunto. excludedPaths neutraliza
        # launchers/updaters integrados por el autor del pack sin codificar un
        # caso especial para Iron Lung.
        $rawRoleAssets=@(@($Lock.assets)+@($Experience.files)|Where-Object{
            (-not$_.role-or$_.role-in@('all',$Role))-and
            -not$excludedPaths.Contains(([string]$_.path-replace'\\','/'))-and
            ([string]$_.path-notmatch'(?i)^(mods/.*essential.*\.jar|essential/.*)$')
        })
        $roleAssets=[Collections.Generic.List[object]]::new()
        $seenRolePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($asset in $rawRoleAssets){
            $normPath=([string]$asset.path)-replace'\\','/'
            if($asset-and$normPath-and$seenRolePaths.Add($normPath)){[void]$roleAssets.Add($asset)}
        }
        $hasCsl=$false
        foreach($a in $roleAssets){if([string]$a.path-match'(?i)CustomSkinLoader'){$hasCsl=$true;break}}
        if(-not$hasCsl){
            [void]$roleAssets.Add([pscustomobject]@{
                name="CustomSkinLoader_Universal-15.0.1.jar"
                path="mods/CustomSkinLoader_Universal-15.0.1.jar"
                sourceUrl="https://cdn.modrinth.com/data/idMHQ4n2/versions/OLaesh5y/CustomSkinLoader_Universal-15.0.1.jar"
                sha256="026d8b38ea93edccd647f60568193e79801a377b7bd4e916dcfc0d5482b767fc"
                size=218215
                role="all"
                policy="replace"
            })
        }
        $downloadAssets=@($Lock.pack.archive)+@($roleAssets)
        $totalBytes=[int64](@($downloadAssets|Measure-Object -Property size -Sum).Sum)
        $experienceLabel=if(-not[string]::IsNullOrWhiteSpace([string]$Experience.name)){[string]$Experience.name}else{[string]$Experience.id}
        $progress=@{Index=0;Count=$downloadAssets.Count;CompletedBytes=[int64]0;TotalBytes=$totalBytes;ProgressStart=30;ProgressEnd=68;Step=4;Title="DESCARGANDO $($experienceLabel.ToUpperInvariant())"}
        if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{role=$Role;experienceId=[string]$Experience.id;packVersion=[string]$Experience.pack.version;instanceRoot=$instanceRoot}}
        Set-CocoLauncherStep 4 'VERIFICANDO ARCHIVOS DEL PACK' ("{0} archivos fijados | {1:N1} MB totales | rol {2}"-f$downloadAssets.Count,($totalBytes/1MB),$Role) 30
        [void](Get-CocoLockedAssetsParallel $CacheRoot $downloadAssets $progress)
        $packArchive=Get-CocoLockedAsset $CacheRoot $Lock.pack.archive $null
        Expand-CocoCurseForgeOverrides $packArchive ([string]$Lock.pack.overridesRoot) $stageFiles
        foreach($file in @(Get-ChildItem -LiteralPath $stageFiles -Recurse -File)){
            $relative=($file.FullName.Substring($stageFiles.Length).TrimStart('\','/'))-replace'\\','/'
            if($relative-match'(?i)^(mods/.*essential.*\.jar|essential/.*)$'){
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
            $policy=if($relative-eq'options.txt'){'preserve'}else{'replace'}
            $desired.Add([pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=[int64]$file.Length;policy=$policy})
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
                if((Test-Path -LiteralPath $destination -PathType Leaf)-and(Get-Item -LiteralPath $destination).Length-eq[int64]$file.size-and(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()-eq[string]$file.sha256){
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
            Set-CocoLauncherStep 5 'INSTANCIA VERIFICADA' ("{0} archivos administrados | version {1}"-f$desired.Count,$Experience.pack.version) 78
        }catch{
            if(Get-Command Write-CocoTimelineEvent -ErrorAction SilentlyContinue){Write-CocoTimelineEvent 'ROLLBACK DE INSTANCIA' 'Restaurando automaticamente los archivos anteriores.' $script:CocoCurrentProgress 'rollback'}
            foreach($entry in @($journal.ToArray())|Select-Object -Reverse){
                if($entry.NewInstalled-and(Test-Path -LiteralPath $entry.Destination -PathType Leaf)){$failed=Join-Path $failedRoot ([IO.Path]::GetFileName($entry.Destination));New-Item -ItemType Directory -Path (Split-Path $failed -Parent) -Force|Out-Null;Move-Item -LiteralPath $entry.Destination -Destination $failed -Force -ErrorAction SilentlyContinue}
                if($entry.Backup-and(Test-Path -LiteralPath $entry.Backup -PathType Leaf)){New-Item -ItemType Directory -Path (Split-Path $entry.Destination -Parent) -Force|Out-Null;Move-Item -LiteralPath $entry.Backup -Destination $entry.Destination -Force}
            }
            throw
        }
        [pscustomobject]@{InstanceRoot=$instanceRoot;StatePath=$statePath;Files=$desired.Count;BackupRoot=if(Test-Path $backupRoot){$backupRoot}else{''}}
    }finally{if((Test-Path -LiteralPath $stage)-and(Test-CocoPathWithin $stage $ExperiencesRoot)){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}}
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

function Set-CocoManagedInstancePreferences($Experience, [string]$InstanceRoot){
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

    # 4. Force Custom Skin Sync for smolbird (and free/premium players)
    $sourceSkin = 'C:\Users\smol\Pictures\skin-negra-ojos-rojos-cigarrillo.png'
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

function Invoke-CocoManagedExperienceLaunch(
    $Catalog,
    [string]$ExperienceId,
    $Identity,
    [ValidateSet('client','host')][string]$Role,
    [string]$CatalogRoot,
    [string]$CacheRoot,
    [string]$ExperiencesRoot,
    [switch]$Dry,
    [switch]$DisableAutoJoin
){
    $experience=@($Catalog.experiences|Where-Object id -eq $ExperienceId|Select-Object -First 1)[0]
    if(-not$experience-or$experience.managementMode-ne'managed'){throw "La experiencia administrada '$ExperienceId' no existe."}
    $lockPath=Join-Path $CatalogRoot (([string]$experience.pack.lockPath)-replace'^launcher/',''-replace'/','\')
    $lock=Read-CocoExperienceLock $lockPath $experience
    $backend=Install-CocoLauncherBackend $Catalog $CacheRoot
    $installed=Install-CocoManagedExperience $experience $lock $ExperiencesRoot $CacheRoot $Role
    [void](Set-CocoManagedRuntimePolicies $experience $installed.InstanceRoot)
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
        $hash=(Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
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
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()-ne([string]$backend.sha256).ToLowerInvariant()){
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
    $sourceHash=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
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
    $cacheRoot=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'
    $experiencesRoot=Join-Path $env:APPDATA 'CocoMinecraft\experiences'
    if(-not[string]::IsNullOrWhiteSpace($TestRoot)){
        # Este override existe exclusivamente para la prueba física local. Se
        # acepta sólo la raíz desechable conocida dentro de TEMP, evitando que
        # un comando de soporte redirija por error el launcher hacia .minecraft
        # o hacia otra carpeta arbitraria del usuario.
        $resolved=[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
        $tempDir=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
        if(-not $resolved.StartsWith($tempDir,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path $resolved -Leaf).StartsWith('coco-',[StringComparison]::OrdinalIgnoreCase)){
            throw "LauncherTestRoot sólo admite carpetas de prueba desechables en TEMP."
        }
        $cacheRoot=Join-Path $resolved 'cache'
        $experiencesRoot=Join-Path $resolved 'experiences'
    }
    [pscustomobject]@{
        CacheRoot=$cacheRoot
        CatalogRoot=Join-Path $EngineRoot 'launcher'
        CatalogPath=Join-Path $EngineRoot 'launcher\catalog.json'
        IdentityPath=Join-Path $cacheRoot 'launcher\identity.json'
        AccountDb=Join-Path $cacheRoot 'launcher\accounts\portablemc_msa.json'
        MainDir=Join-Path $cacheRoot 'launcher\shared'
        SessionStatePath=Join-Path $cacheRoot 'launcher\session\active.json'
        SessionLogPath=Join-Path $cacheRoot 'logs\launcher-session-service.log'
        ExperiencesRoot=$experiencesRoot
        IsTest=-not[string]::IsNullOrWhiteSpace($TestRoot)
        TestRoot=$TestRoot
    }
}

function Get-CocoLauncherRole([string]$LegacyMinecraftRoot){
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
    $saves=Join-Path $InstanceRoot 'saves'
    if(-not(Test-Path -LiteralPath $saves -PathType Container)){return 0}
    $written=0
    foreach($world in @(Get-ChildItem -LiteralPath $saves -Directory -ErrorAction SilentlyContinue)){
        # Una carpeta sin level.dat/session.lock todavia no es un mundo valido.
        if(-not(Test-Path -LiteralPath (Join-Path $world.FullName 'level.dat') -PathType Leaf)-and-not(Test-Path -LiteralPath (Join-Path $world.FullName 'session.lock') -PathType Leaf)){continue}
        $path=Join-Path $world.FullName 'mcwifipnp.json'
        $payload=[ordered]@{
            port=[int]$Experience.hosting.port
            'allow-host-cheat'=$true
            'max-players'=8
            gamemode='survival'
            motd=("Coco - {0}"-f[string]$Experience.name)
            'allow-everyone-cheat'=$false
            'enforce-whitelist'=$false
            'enable-upnp'=$false
            'online-mode'=$false
            'enable-uuid-fixer'=$true
            pvp=$true
            'get-public-ip'=$false
            'remove-player-reporting'=$false
        }
        $json=$payload|ConvertTo-Json
        $current=if(Test-Path -LiteralPath $path -PathType Leaf){try{Get-Content -LiteralPath $path -Raw}catch{''}}else{''}
        $matches=$false
        if($current){
            try{
                $parsed=$current|ConvertFrom-Json
                $matches=[int]$parsed.port-eq[int]$Experience.hosting.port-and-not[bool]$parsed.'online-mode'-and[bool]$parsed.'enable-uuid-fixer'-and-not[bool]$parsed.'enable-upnp'
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
    $input=New-Object Windows.Forms.TextBox;$input.Location=New-Object Drawing.Point(25,76);$input.Size=New-Object Drawing.Size(365,25);$input.Text=$Suggested;$input.MaxLength=16
    $ok=New-Object Windows.Forms.Button;$ok.Text='Guardar';$ok.Location=New-Object Drawing.Point(235,118);$ok.Size=New-Object Drawing.Size(155,34);$ok.Add_Click({$rawVal=[string]$input.Text; $cleanVal=[regex]::Replace($rawVal,'[^A-Za-z0-9_]',''); if(Test-CocoMinecraftUsername $cleanVal){$dialog.Tag=$cleanVal;$dialog.DialogResult=[Windows.Forms.DialogResult]::OK;$dialog.Close()}else{[Windows.Forms.MessageBox]::Show('Usa 3 a 16 letras, numeros o guion bajo.','Nombre invalido')|Out-Null}})
    $dialog.AcceptButton=$ok;$dialog.Controls.AddRange(@($label,$input,$ok));$result=$dialog.ShowDialog($script:CocoForm);$name=[string]$dialog.Tag;$dialog.Dispose()
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

function Resolve-CocoLauncherIdentityUi($Catalog,[string]$LegacyMinecraftRoot,$Paths){
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

function Start-CocoLauncherExperience($Catalog,$Experience,$Identity,[string]$Role,$Paths,[string]$LegacyMinecraftRoot,[switch]$DisableAutoJoin){
    if($Experience.managementMode-ne'managed'-or$Experience.launch.workflow-ne'coco-managed'){
        throw 'Coco original se abre con el launcher habitual de cada jugador, no con Coco Launcher.'
    }
    Invoke-CocoManagedExperienceLaunch $Catalog $Experience.id $Identity $Role $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -DisableAutoJoin:$DisableAutoJoin
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
        Set-CocoDiagnosticContext @{role='client';experienceId=[string]$action.Experience.id;packVersion=[string]$action.Experience.pack.version;instanceRoot=(Join-Path $Paths.ExperiencesRoot ([string]$action.Experience.instanceId))}
    }
    if($action.Action-eq'prepare'){
        $sessionId=[string]$Session.Announcement.sessionId
        if(-not$PreparedSessions.ContainsKey($sessionId)-and$action.Experience.managementMode-eq'managed'){
            Set-CocoLauncherStep 3 'PARTIDA DETECTADA' ("{0} se esta preparando en el host; Coco adelantara toda la instalacion local."-f$action.Experience.name) 25
            $dummy=[pscustomobject]@{mode='offline';username='CocoPrepare';uuid=''}
            [void](Invoke-CocoManagedExperienceLaunch $Catalog $action.Experience.id $dummy client $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -Dry)
            $PreparedSessions[$sessionId]=$true
        }
        return $null
    }
    if($action.Action-ne'launch'){return $null}
    $sessionId=[string]$Session.Announcement.sessionId
    if($action.Experience.managementMode-eq'managed'-and-not$PreparedSessions.ContainsKey($sessionId)){
        Set-CocoLauncherStep 3 'PARTIDA LISTA' ("Verificando {0} antes de abrir Minecraft..."-f$action.Experience.name) 27
        $dummy=[pscustomobject]@{mode='offline';username='CocoPrepare';uuid=''}
        [void](Invoke-CocoManagedExperienceLaunch $Catalog $action.Experience.id $dummy client $Paths.CatalogRoot $Paths.CacheRoot $Paths.ExperiencesRoot -Dry)
        $PreparedSessions[$sessionId]=$true
    }
    $fresh=Get-CocoSessionAnnouncement $Catalog
    if($fresh.State-ne'ready'-or[string]$fresh.Announcement.sessionId-ne$sessionId){return $null}
    $identity=Resolve-CocoLauncherIdentityUi $Catalog $LegacyMinecraftRoot $Paths
    # El primer login Microsoft puede tardar; no se lanza contra una sesion que
    # terminó mientras el jugador autorizaba su cuenta.
    $fresh=Get-CocoSessionAnnouncement $Catalog
    if($fresh.State-ne'ready'-or[string]$fresh.Announcement.sessionId-ne$sessionId){return $null}
    Set-CocoLauncherStep 7 'IDENTIDAD LISTA' ("{0} | {1}"-f$identity.mode,$identity.username) 89
    Set-CocoLauncherStep 8 'ABRIENDO MINECRAFT' ("{0} se conectara automaticamente a {1}:{2}."-f$action.Experience.name,$action.Experience.hosting.host,$action.Experience.hosting.port) 90
    Start-CocoLauncherExperience $Catalog $action.Experience $identity client $Paths $LegacyMinecraftRoot
}

function Invoke-CocoLauncherHostSession($Catalog,$Experience,$Paths,[string]$LegacyMinecraftRoot){
    if(-not$Experience-or$Experience.managementMode-ne'managed'-or$Experience.launch.workflow-ne'coco-managed'){throw 'El host solo puede alojar experiencias administradas desde Coco Launcher.'}
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{role='host';experienceId=[string]$Experience.id;packVersion=[string]$Experience.pack.version;instanceRoot=(Join-Path $Paths.ExperiencesRoot ([string]$Experience.instanceId))}}
    Set-CocoLauncherStep 3 'PREPARANDO LA PARTIDA DEL HOST' ("Experiencia seleccionada: {0}"-f$Experience.name) 25
    $identity=Resolve-CocoLauncherIdentityUi $Catalog $LegacyMinecraftRoot $Paths
    if(Test-CocoTcpEndpoint ([string]$Experience.hosting.host) ([int]$Experience.hosting.port) 350){throw 'El puerto Coco 25565 ya esta ocupado. Cierra la partida anterior antes de iniciar otra.'}
    $sessionId=[guid]::NewGuid().ToString()
    [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id preparing $sessionId $Paths.SessionStatePath 30)
    $service=$null;$launch=$null
    try{
        $service=Start-CocoSessionService (Join-Path $script:CocoEngineRoot 'CocoSessionService.ps1') $Paths.SessionStatePath $Paths.SessionLogPath $PID
        Set-CocoLauncherStep 4 'VERIFICANDO EL PACK DEL HOST' ("Instalando {0} en una instancia aislada..."-f$Experience.name) 30
        $launch=Start-CocoLauncherExperience $Catalog $Experience $identity host $Paths $LegacyMinecraftRoot -DisableAutoJoin
        $instanceRoot=if($launch.Installation){[string]$launch.Installation.InstanceRoot}elseif($launch.InstanceRoot){[string]$launch.InstanceRoot}else{$LegacyMinecraftRoot}
        if($Experience.managementMode-eq'managed'){[void](Set-CocoManagedLanWorldConfigurations $instanceRoot $Experience)}
        [void](Wait-CocoManagedMinecraftWindow $instanceRoot $launch.Process 90)
        Set-CocoLauncherStep 9 'MINECRAFT ABIERTO' 'Entra o crea el mundo y pulsa Abrir en LAN. Coco detectara el puerto y avisara a todos.' 95
        try{$script:CocoForm.TopMost=$false}catch{}
        $ready=$false;$lastPublish=[DateTime]::MinValue
        while(-not$launch.Process.HasExited){
            [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 250
            if($Experience.managementMode-eq'managed'){[void](Set-CocoManagedLanWorldConfigurations $instanceRoot $Experience)}
            if(-not$ready-and(Test-CocoTcpEndpoint ([string]$Experience.hosting.host) ([int]$Experience.hosting.port) 250)){$ready=$true}
            if((Get-Date)-gt$lastPublish.AddSeconds(8)){
                [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id $(if($ready){'ready'}else{'preparing'}) $sessionId $Paths.SessionStatePath 30)
                $lastPublish=Get-Date
                if($ready){Set-CocoLauncherStep 10 'PARTIDA ONLINE' ("{0} esta lista; tus amigos entraran automaticamente."-f$Experience.name) 100}
            }
        }
        [void](Publish-CocoSessionAnnouncement $Catalog $Experience.id stopping $sessionId $Paths.SessionStatePath 10)
    }finally{
        if($launch-and$launch.Process-and$launch.Process.HasExited){$launch.Process.Dispose()}
        if($service-and-not$service.HasExited){$service.Kill()};if($service){$service.Dispose()}
        Remove-Item -LiteralPath $Paths.SessionStatePath -Force -ErrorAction SilentlyContinue
    }
}

function Start-CocoLauncherUi($Manifest,[string]$LegacyMinecraftRoot,[string]$LauncherTestRoot=''){
    if(-not(Get-Command Show-CocoWindow -ErrorAction SilentlyContinue)){throw 'El engine no contiene la UI base requerida por Coco Launcher.'}
    $paths=Get-CocoLauncherPaths $script:CocoEngineRoot $LauncherTestRoot
    $catalog=Read-CocoLauncherCatalog $paths.CatalogPath
    $original=@($catalog.experiences|Where-Object id -eq 'coco-original'|Select-Object -First 1)[0]
    if(-not$original-or[string]$original.pack.version-ne[string]$Manifest.version){throw 'El catalogo Coco Launcher no coincide con la version publicada del engine.'}
    Show-CocoWindow
    $script:CocoForm.Text='Coco Launcher';$script:CocoBrand.Text='COCO LAUNCHER  |  UNA PARTIDA ACTIVA'
    $script:CocoPanel.Height=460
    if($script:CocoAccent){$script:CocoAccent.Height=$script:CocoPanel.Height}
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{component='launcher';mode='launcher';role='detecting';stage='start'}}
    $runLabel=if(-not[string]::IsNullOrWhiteSpace([string]$script:CocoRunId)){([string]$script:CocoRunId).Substring(0,[Math]::Min(8,([string]$script:CocoRunId).Length))}else{'test/local'}
    Set-CocoLauncherStep 1 'INICIANDO COCO LAUNCHER' ("Engine {0} | ejecucion {1}"-f$Manifest.version,$runLabel) 13
    $role=Get-CocoLauncherRole $LegacyMinecraftRoot
    if(Get-Command Set-CocoDiagnosticContext -ErrorAction SilentlyContinue){Set-CocoDiagnosticContext @{role=$role}}
    Set-CocoLauncherStep 2 'PREPARANDO LA RED PRIVADA' 'Verificando ZeroTier, adaptador, autorizacion y rutas Coco...' 16
    $oldMinecraftPid=$script:MinecraftPid;$script:MinecraftPid=$PID
    try{
        if($Manifest.network){
            [void](Invoke-CocoLauncherNetworkSerialized {Ensure-CocoNetwork $LegacyMinecraftRoot $role $Manifest})
        }
    }finally{$script:MinecraftPid=$oldMinecraftPid}
    $dynamic=New-Object Windows.Forms.Panel;$dynamic.Location=New-Object Drawing.Point(46,270);$dynamic.Size=New-Object Drawing.Size(570,110);$dynamic.AutoScroll=$true;$dynamic.Tag='CocoLauncherDynamic';$script:CocoPanel.Controls.Add($dynamic)
    $identityButton=New-Object Windows.Forms.Button;$identityButton.Text='Cambiar identidad';$identityButton.Size=New-Object Drawing.Size(145,34);$identityButton.Location=New-Object Drawing.Point(310,398);$identityButton.Tag=$paths
    $identityButton.Add_Click({param($sender,$eventArgs)
        try{
            $identityPaths=$sender.Tag;$mode=Show-CocoIdentityModeDialog $null
            if($mode-eq'offline'){[void](Save-CocoLauncherIdentityState $identityPaths.IdentityPath offline (Show-CocoUsernameDialog) '' 'user-settings')}
            else{[void](Save-CocoLauncherIdentityState $identityPaths.IdentityPath microsoft '' '' 'user-settings')}
            Set-CocoState 'Identidad actualizada' 'La nueva decision se usara en el proximo lanzamiento.' 15
        }catch{Set-CocoState 'Identidad sin cambios' $_.Exception.Message 15}
    });$script:CocoPanel.Controls.Add($identityButton)
    $close=New-Object Windows.Forms.Button;$close.Text='Cerrar';$close.Size=New-Object Drawing.Size(115,34);$close.Location=New-Object Drawing.Point(465,398);$close.Add_Click({$script:CocoAllowClose=$true;$script:CocoForm.Close()});$script:CocoPanel.Controls.Add($close)
    if($role-eq'host'){
        $script:CocoLauncherSelectedExperience=''
        $index=0
        foreach($experience in @($catalog.experiences|Where-Object{$_.managementMode-eq'managed'-and$_.launch.workflow-eq'coco-managed'})){
            $button=New-Object Windows.Forms.Button;$button.Text=[string]$experience.name;$button.Tag=[string]$experience.id
            # Con New-Object, la coma puede convertir estas dos expresiones en
            # Object[] antes de evaluar la multiplicacion en PowerShell 5.1.
            # El constructor tipado evita el op_Multiply que la prueba visual
            # del host encontro antes de mostrar el primer selector real.
            $button.Size=[Drawing.Size]::new(245,42)
            $button.Location=[Drawing.Point]::new([int](($index%2)*260),[int]([math]::Floor($index/2)*50))
            $button.Add_Click({param($sender,$eventArgs)$script:CocoLauncherSelectedExperience=[string]$sender.Tag});$dynamic.Controls.Add($button);$index++
        }
        while(-not$script:CocoForm.IsDisposed){
            Set-CocoLauncherStep 3 'ELIGE QUE ALOJAR' 'Solo el host elige. Tus amigos recibiran automaticamente esta unica partida.' 24
            $script:CocoLauncherSelectedExperience=''
            while(-not$script:CocoForm.IsDisposed-and[string]::IsNullOrWhiteSpace($script:CocoLauncherSelectedExperience)){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            if($script:CocoForm.IsDisposed){break}
            $experience=@($catalog.experiences|Where-Object id -eq $script:CocoLauncherSelectedExperience|Select-Object -First 1)[0]
            foreach($control in @($dynamic.Controls)+@($identityButton,$close)){if($control-is[Windows.Forms.Button]){$control.Enabled=$false}}
            try{Invoke-CocoLauncherHostSession $catalog $experience $paths $LegacyMinecraftRoot;Set-CocoState 'Partida terminada' 'Minecraft se cerro. Ya puedes iniciar otra experiencia.' 15}
            catch{Write-CocoLog "ERROR Launcher host: $($_|Out-String)";Set-CocoState 'NO SE PUDO INICIAR LA PARTIDA' (Get-CocoLauncherFailureDetail $_) 0 $true 'failure'}
            foreach($control in @($dynamic.Controls)+@($identityButton,$close)){if($control-is[Windows.Forms.Button]){$control.Enabled=$true}}
        }
    }else{
        $prepared=@{};$launched=$false;$session=$null
        for($attempt=0;$attempt-lt3;$attempt++){
            $session=Get-CocoSessionAnnouncement $catalog
            if($session.State-ne'offline'){break}
            if($attempt-lt2){
                Set-CocoLauncherStep 3 'BUSCANDO PARTIDA COCO' 'Consultando la unica sesion administrada activa...' 22
                $until=(Get-Date).AddSeconds(1);while((Get-Date)-lt$until-and-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            }
        }
        if($script:CocoForm.IsDisposed){return}
        if($session.State-eq'offline'){
            Set-CocoLauncherStep 3 'NO HAY EXPERIENCIA ESPECIAL ONLINE' 'Coco actualizara el mundo original, que sigues abriendo con tu launcher habitual.' 25
            $identityButton.Enabled=$false;$close.Enabled=$false
            try{$legacy=Sync-CocoLegacyInstanceForLauncher $LegacyMinecraftRoot $Manifest}finally{$identityButton.Enabled=$true;$close.Enabled=$true}
            if($legacy.Present){
                Set-CocoLauncherStep 10 'COCO ORIGINAL LISTO' $(if($legacy.Updated){'El pack fue actualizado. Ya puedes abrir Minecraft con tu launcher habitual.'}else{'Ya estabas actualizado. Abre Minecraft con tu launcher habitual.'}) 100
            }else{
                Set-CocoLauncherStep 3 'FALTA LA INSTALACION ORIGINAL' 'No se encontro Coco original. Abre esa version una vez con tu launcher habitual y vuelve a ejecutar Coco.' 25
            }
            while(-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            return
        }
        while(-not$script:CocoForm.IsDisposed-and-not$launched){
            try{
                $action=Get-CocoClientSessionAction $session
                if($action.Action-eq'wait'){Set-CocoLauncherStep 3 ([string]$action.Message).ToUpperInvariant() 'Coco seguira buscando mientras esta ventana permanezca abierta.' 24}
                else{
                    Set-CocoLauncherStep 3 ([string]$action.Message).ToUpperInvariant() 'La unica experiencia online se selecciono automaticamente.' 25
                    $identityButton.Enabled=$false;$close.Enabled=$false
                    $launch=Invoke-CocoLauncherClientSession $catalog $session $paths $LegacyMinecraftRoot $prepared
                    if(-not$launch){$identityButton.Enabled=$true;$close.Enabled=$true}
                    else{
                        # PortableMC hereda pipes de Coco para registrar su salida. Coco debe
                        # permanecer vivo hasta que termine Minecraft; cerrar ahora puede
                        # cortar esos pipes y bloquear el arranque en un cliente real.
                        $launched=$true
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
            }catch{
                if(-not$script:CocoForm.IsDisposed){$identityButton.Enabled=$true;$close.Enabled=$true}
                Write-CocoLog "ERROR Launcher client: $($_|Out-String)";Set-CocoState 'COCO DETECTO UN PROBLEMA' (Get-CocoLauncherFailureDetail $_) 0 $true 'failure'
            }
            $until=(Get-Date).AddSeconds(3);while((Get-Date)-lt$until-and-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
            if(-not$script:CocoForm.IsDisposed){$session=Get-CocoSessionAnnouncement $catalog}
        }
    }
    if(-not$script:CocoForm.IsDisposed){while(-not$script:CocoForm.IsDisposed){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}}
}