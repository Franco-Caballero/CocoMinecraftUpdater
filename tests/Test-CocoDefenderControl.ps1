$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$work=Join-Path ([IO.Path]::GetTempPath()) ("coco-defender-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force|Out-Null
try{
    foreach($script in @('engine\CocoUpdater.ps1','engine\CocoLauncher.ps1','engine\CocoSessionService.ps1','engine\CocoNetwork.ps1','engine\CocoNetworkElevated.ps1','engine\CocoNetworkAuthorizer.ps1','engine\CocoDefenderControl.ps1')){
        [void][scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root $script)))
    }

    . (Join-Path $root 'engine\CocoDefenderControl.ps1')

    if([string]$script:CocoDefenderControlRelease.version-ne'v2.0'){throw 'Version de Defender Control inesperada.'}
    if([string]$script:CocoDefenderControlRelease.sourceUrl-ne'https://github.com/pgkt04/defender-control'){throw 'Fuente oficial de Defender Control incorrecta.'}
    if([string]$script:CocoDefenderControlRelease.license-ne'MIT'){throw 'Licencia de Defender Control no declarada.'}
    $binaries=@($script:CocoDefenderControlRelease.binaries)
    if($binaries.Count-ne2){throw 'Deben fijarse exactamente dos binarios de Defender Control.'}
    foreach($binary in $binaries){
        if([string]$binary.url-notmatch'^https://github\.com/pgkt04/defender-control/releases/download/v2\.0/(disable|enable)-defender\.exe$'){throw "URL no oficial para $($binary.name)."}
        if([string]$binary.sha256-notmatch'^[a-f0-9]{64}$'){throw "SHA-256 invalido para $($binary.name)."}
        if([int64]$binary.size-le0){throw "Tamano invalido para $($binary.name)."}
    }
    $disable=@($binaries|Where-Object name -eq 'disable-defender.exe')[0]
    $enable=@($binaries|Where-Object name -eq 'enable-defender.exe')[0]
    if([int64]$disable.size-ne286720){throw 'Tamano publicado de disable-defender.exe cambio sin revisar el pin.'}
    if([int64]$enable.size-ne293376){throw 'Tamano publicado de enable-defender.exe cambio sin revisar el pin.'}
    if(([string]$disable.sha256)-eq([string]$enable.sha256)){throw 'Los binarios comparten hash; pin corrupto.'}

    if((Get-CocoDefenderBinaryName $false)-ne'disable-defender.exe'-or(Get-CocoDefenderBinaryName $true)-ne'enable-defender.exe'){throw 'Mapeo binario incorrecto.'}
    if((Get-CocoDefenderTaskName $false)-ne'CocoDefenderDisable'-or(Get-CocoDefenderTaskName $true)-ne'CocoDefenderEnable'){throw 'Mapeo de tareas incorrecto.'}
    $realElevated=Test-CocoDefenderElevated
    if($realElevated-isnot[bool]){throw 'Test-CocoDefenderElevated debe devolver booleano.'}

    $updaterText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
    if($updaterText-notmatch'CocoDefenderControl\.ps1'){throw 'El updater no carga el modulo de Defender en memoria.'}

    $bytes=[byte[]]@(0..255)*3
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $localRelease=[pscustomobject]@{
        version='test';sourceUrl='https://example.invalid';license='MIT'
        binaries=@(
            [pscustomobject]@{name='disable-defender.exe';url='https://example.invalid/disable';size=$bytes.Length;sha256=$hash},
            [pscustomobject]@{name='enable-defender.exe';url='https://example.invalid/enable';size=$bytes.Length;sha256=$hash}
        )
    }

    $script:mpExclusions=[Collections.Generic.List[string]]::new()
    function Get-MpPreference{[pscustomobject]@{ExclusionPath=@($script:mpExclusions.ToArray())}}
    function Add-MpPreference{param([string]$ExclusionPath)[void]$script:mpExclusions.Add($ExclusionPath)}
    function Get-MpComputerStatus{[pscustomobject]@{IsTamperProtected=$true}}
    $script:fakeElevated=$false
    $script:simTasks=@{}
    function Test-CocoDefenderElevated{return $script:fakeElevated}
    function Test-CocoDefenderTaskExists([string]$TaskName){[bool]$script:simTasks[$TaskName]}
    $script:events=[Collections.Generic.List[string]]::new()
    function New-CocoDefenderTaskInline([string]$ExePath,[string]$TaskName){[void]$script:events.Add("task:$TaskName")}
    function Register-CocoDefenderTasks{
        param([pscustomobject]$Release,[string]$Root)
        if($script:fakeElevated){throw 'La sesion elevada no debe usar la ruta con UAC.'}
        [void]$script:events.Add('uac-setup')
        [void]$script:mpExclusions.Add($Root)
        foreach($binary in @($Release.binaries)){
            $script:simTasks[(Get-CocoDefenderTaskName (([string]$binary.name)-like'enable*'))]=$true
        }
        return $true
    }
    $script:downloads=0
    function Download-VerifiedFile([string]$Url,[string]$Destination,[string]$ExpectedHash){
        if(-not($script:events.Contains('uac-setup')-or$script:fakeElevated)){throw 'Se intento descargar antes de asegurar exclusion y tareas.'}
        $script:downloads++
        [IO.File]::WriteAllBytes($Destination,$script:bytes)
    }

    $toolRoot=Join-Path $work 'tools\defender-control'
    [void](Ensure-CocoDefenderSessionSetup -Release $localRelease -Root $toolRoot)
    if(-not$script:events.Contains('uac-setup')){throw 'La primera sesion no realizo la preparacion unica.'}
    $paths=Ensure-CocoDefenderToolBinaries -Release $localRelease -Root $toolRoot
    if(@($paths).Count-ne2-or$script:downloads-ne2){throw 'Ensure no descargo los binarios faltantes.'}
    if((Test-CocoDefenderExclusionPresent $toolRoot)-ne$true){throw 'La exclusion de la carpeta de herramientas no quedo registrada.'}

    $eventsBefore=$script:events.Count
    [void](Ensure-CocoDefenderSessionSetup -Release $localRelease -Root $toolRoot)
    if($script:events.Count-ne$eventsBefore-or$script:downloads-ne2){throw 'Una sesion ya preparada volvio a tocar UAC o a descargar.'}

    [IO.File]::WriteAllBytes((Join-Path $toolRoot 'disable-defender.exe'),[byte[]](1,2,3))
    [void](Ensure-CocoDefenderToolBinaries -Release $localRelease -Root $toolRoot)
    if($script:downloads-ne3){throw 'Ensure no reparo un binario corrupto.'}

    $elevatedRoot=Join-Path $work 'tools\defender-control-elevated'
    $script:fakeElevated=$true
    $eventsBefore=$script:events.Count
    [void](Ensure-CocoDefenderSessionSetup -Release $localRelease -Root $elevatedRoot)
    if($script:events.Contains('uac-setup')-and$script:events.Count-gt$eventsBefore-and$script:events.IndexOf('uac-setup')-ge$eventsBefore){throw 'La sesion elevada uso la ruta con UAC.'}
    if(@($script:events|Where-Object{$_-like'task:*'}).Count-ne2){throw 'La sesion elevada no registro las dos tareas.'}
    if(-not(Test-CocoDefenderExclusionPresent $elevatedRoot)){throw 'Falta la exclusion preparada en sesion elevada.'}
    $script:fakeElevated=$false

    $script:setCalls=[Collections.Generic.List[bool]]::new()
    $script:guidanceShown=0
    function Set-CocoDefenderProtection([bool]$Enabled){[void]$script:setCalls.Add($Enabled)}
    function Wait-CocoDefenderRealTimeProtection([bool]$ExpectedEnabled,[int]$TimeoutSeconds){$ExpectedEnabled}
    function Show-CocoDefenderTamperGuidance{param([string]$MarkerPath='')[void]$script:guidanceShown++}
    $script:CocoDefenderPlayWindowActive=$false
    if(Invoke-CocoDefenderPlayWindowEnd){throw 'El cierre restauro sin una sesion previa.'}
    if(-not(Invoke-CocoDefenderPlayWindowStart)){throw 'El inicio de sesion fallo con la herramienta simulada.'}
    if(-not(Invoke-CocoDefenderPlayWindowStart)){throw 'La reentrada del inicio no fue idempotente.'}
    if($script:setCalls.Count-ne1-or$script:setCalls[0]){throw 'El inicio no desactivo la proteccion exactamente una vez.'}
    if($script:guidanceShown-ne1){throw 'La guia del paso unico no aparecio cuando la desactivacion no se confirmo.'}
    if(-not(Invoke-CocoDefenderPlayWindowEnd)){throw 'El cierre no restauro la sesion activa.'}
    if($script:setCalls.Count-ne2-or-not$script:setCalls[1]){throw 'El cierre no reactivo la proteccion.'}
    if(Invoke-CocoDefenderPlayWindowEnd){throw 'El segundo cierre restauro nuevamente.'}
    if($script:guidanceShown-ne1){throw 'La guia se repitio dentro de la misma sesion.'}

    $launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
    foreach($pattern in @(
        'if\(-not\$paths\.IsTest-and\(Get-Command Invoke-CocoDefenderPlayWindowStart',
        '\$script:CocoDefenderPlayWindowOwned=\[bool\]\(Invoke-CocoDefenderPlayWindowStart\)',
        'finally\{\r?\n\s*if\(\$script:CocoDefenderPlayWindowOwned\)',
        'Invoke-CocoDefenderPlayWindowEnd'
    )){
        if($launcherText-notmatch$pattern){throw "El launcher no alterna Defender correctamente: $pattern"}
    }
    $buildText=[IO.File]::ReadAllText((Join-Path $root 'tools\New-CocoEngine.ps1'))
    if($buildText-notmatch"CocoDefenderControl\.ps1"){throw 'El empaquetado del engine no incluye el interruptor de Defender.'}

    'PASS: Defender Control fijado, verificado y alternado por sesion sin friccion.'
}finally{
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
