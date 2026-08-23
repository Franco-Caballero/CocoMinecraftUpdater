$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$work=Join-Path ([IO.Path]::GetTempPath()) ("coco-popup-gate-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force|Out-Null
try{
    foreach($script in @('engine\CocoUpdater.ps1','engine\CocoLauncher.ps1')){
        [void][scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root $script)))
    }
    . (Join-Path $root 'engine\CocoLauncher.ps1')

    $engineText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
    if($engineText-match'CocoWin32PopupKiller'){throw 'Quedan referencias al eliminador antiguo de ventanas.'}
    if($engineText-notmatch'function Start-CocoStandalonePopupGate'){throw 'Falta el vigilante declarativo de ventanas.'}
    if(@([regex]::Matches($engineText,'Stop-CocoStandalonePopupGate')).Count-lt3){throw 'El vigilante no se detiene en los ciclos host y cliente.'}

    $defaults=Get-CocoPopupGateConfig $null
    if(@($defaults.markers)-notcontains'online-fix'){throw 'Los marcadores por defecto no incluyen online-fix.'}
    if(@($defaults.buttonLabels)-notcontains'jugar'-or@($defaults.buttonLabels)-notcontains'play'){throw 'Las etiquetas por defecto son incompletas.'}
    $override=[pscustomobject]@{preferences=[pscustomobject]@{popupGate=[pscustomobject]@{buttonLabels=@('COMENZAR')}}}
    $custom=Get-CocoPopupGateConfig $override
    if((@($custom.buttonLabels)-join',')-ne'COMENZAR'){throw 'La experiencia no pudo reemplazar las etiquetas de boton.'}
    if(@($custom.markers)-notcontains'online-fix'){throw 'El reemplazo de etiquetas borro los marcadores.'}

    $clickScript=Join-Path $work 'click-window.ps1'
    $clickLines=@(
        'param([string]$Label,[string]$Title=''online-fix.me'')',
        'Add-Type -AssemblyName System.Windows.Forms',
        'Add-Type -AssemblyName System.Drawing',
        '$form=New-Object System.Windows.Forms.Form',
        '$form.Text=$Title',
        '$form.Size=New-Object System.Drawing.Size(420,240)',
        '$button=New-Object System.Windows.Forms.Button',
        '$button.Text=$Label',
        '$button.Dock=''Fill''',
        '$button.Add_Click({$form.Close()})',
        '$form.Controls.Add($button)',
        '[void]$form.ShowDialog()'
    )
    $clickLines|Set-Content -LiteralPath $clickScript -Encoding UTF8

    function Wait-Exit([object]$Process,[int]$Seconds){
        $deadline=(Get-Date).AddSeconds($Seconds)
        while((Get-Date)-lt$deadline){
            if($Process.HasExited){return $true}
            Start-Sleep -Milliseconds 250
        }
        return $false
    }

    # 1) Ventana con boton etiquetado: se oculta al instante y se pulsa solo.
    $labeled=Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$clickScript,'PLAY') -PassThru
    try{
        Start-Sleep -Seconds 3
        if($labeled.HasExited){throw 'La ventana de prueba cerro antes del vigilante.'}
        [void](Start-CocoStandalonePopupGate $labeled $null)
        if(-not(Wait-Exit $labeled 25)){throw 'El vigilante no pulso el boton PLAY de la ventana online-fix.'}
        $desc=[CocoPopupGate]::Describe()
        if($desc-notmatch'oculta\+click'){throw "La ventana no fue ocultada antes de resolverse: $desc"}
        Stop-CocoStandalonePopupGate
    }finally{if(-not$labeled.HasExited){Stop-Process -Id $labeled.Id -Force -ErrorAction SilentlyContinue}}

    # 2) Dialogo nativo con un unico boton: se pulsa aunque el titulo sea neutro.
    $dialog=Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command','Add-Type -AssemblyName System.Windows.Forms;[void][System.Windows.Forms.MessageBox]::Show(''cuerpo'',''TituloNeutro'')') -PassThru
    try{
        Start-Sleep -Seconds 3
        if($dialog.HasExited){throw 'El dialogo de prueba cerro antes del vigilante.'}
        [void](Start-CocoStandalonePopupGate $dialog $null)
        if(-not(Wait-Exit $dialog 25)){throw 'El vigilante no acepto el dialogo nativo de un boton.'}
    }finally{if(-not$dialog.HasExited){Stop-Process -Id $dialog.Id -Force -ErrorAction SilentlyContinue}}

    # 3) Ventana ajena (boton sin etiqueta conocida y sin marcadores): NO debe tocarse.
    $foreign=Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$clickScript,'COMENZAR','MiJuego') -PassThru
    try{
        Start-Sleep -Seconds 3
        [void](Start-CocoStandalonePopupGate $foreign $null)
        if(Wait-Exit $foreign 8){throw 'El vigilante toco una ventana legitima sin marcadores ni etiqueta.'}
        Stop-CocoStandalonePopupGate
    }finally{if(-not$foreign.HasExited){Stop-Process -Id $foreign.Id -Force -ErrorAction SilentlyContinue}}

    # 4) La ventana puede pertenecer a un proceso hijo del PID vigilado.
    $flagPath=Join-Path $work 'hijo.listo'
    $parentScript=Join-Path $work 'parent-window.ps1'
    @(
        'param([string]$Child,[string]$Flag)',
        '$grand=Start-Process powershell -ArgumentList @(''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',$Child,''PLAY'') -PassThru',
        'if($grand.WaitForExit(30000)){Set-Content -LiteralPath $Flag -Value ok}'
    )|Set-Content -LiteralPath $parentScript -Encoding UTF8
    Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
    $tree=Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$parentScript,$clickScript,$flagPath) -PassThru
    try{
        Start-Sleep -Seconds 5
        if($tree.HasExited){throw 'El proceso padre de prueba termino demasiado pronto.'}
        [void](Start-CocoStandalonePopupGate $tree $null)
        $deadline=(Get-Date).AddSeconds(40)
        while((Get-Date)-lt$deadline-and-not(Test-Path -LiteralPath $flagPath)){Start-Sleep -Milliseconds 300}
        if(-not(Test-Path -LiteralPath $flagPath)){throw 'El vigilante ignoro la ventana de un proceso hijo.'}
    }finally{if(-not$tree.HasExited){Stop-Process -Id $tree.Id -Force -ErrorAction SilentlyContinue}}

    'PASS: popup gate universal cubre ventana propia, dialogo nativo, hijo del proceso y respeta ventanas ajenas.'
}finally{
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
