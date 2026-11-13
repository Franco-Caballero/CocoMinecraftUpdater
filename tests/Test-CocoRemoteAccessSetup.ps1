$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$helper=Join-Path $root 'engine\CocoRemoteAccess.ps1'
$hostKey=Join-Path $root 'engine\CocoRemoteAccessHost.pub'
$launcher=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
$packager=[IO.File]::ReadAllText((Join-Path $root 'tools\New-CocoEngine.ps1'))
$helperAstTokens=$null
$helperAstErrors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$helperAstTokens,[ref]$helperAstErrors)
if(@($helperAstErrors).Count){throw 'El script del instalador SSH contiene errores de sintaxis.'}
$appendFunction=@($helperAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-CocoRemoteKeyAppend'
},$true))
if($appendFunction.Count-ne1){throw 'Falta la funcion pura de insercion idempotente de claves.'}
. ([ScriptBlock]::Create($appendFunction[0].Extent.Text))
$tempRoot=Join-Path $env:TEMP ('coco-remote-access-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null
try{
    $algorithm=[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')
    $wire=[byte[]]::new(51)
    $wire[3]=11
    [Array]::Copy($algorithm,0,$wire,4,11)
    $wire[18]=32
    for($i=19;$i-lt51;$i++){$wire[$i]=[byte]$i}
    $pub=Join-Path $tempRoot 'trusted.pub'
    [IO.File]::WriteAllText($pub,('ssh-ed25519 '+[Convert]::ToBase64String($wire)+' test-key'))
    $result=@(& $helper -PublicKeyFile $pub -ValidateOnly)
    if($result-ne'Clave publica SSH ed25519 valida.') {
        throw 'La validacion SSH de una clave publica ed25519 correcta fallo.'
    }
    if(-not(Test-Path -LiteralPath $hostKey -PathType Leaf)){
        throw 'El engine no contiene la clave publica dedicada al host.'
    }
    $hostKeyValidation=@(& $helper -PublicKeyFile $hostKey -ValidateOnly)
    if($hostKeyValidation-ne'Clave publica SSH ed25519 valida.'){
        throw 'La clave publica real del host no supera la validacion.'
    }
    $hostBase64=([IO.File]::ReadAllText($hostKey).Trim().Split(' '))[1]
    $helperText=[IO.File]::ReadAllText($helper)
    if(-not$helperText.Contains("expectedHostPublicKey='$hostBase64'")){
        throw 'La clave publica incorporada no tiene hash/base64 fijado en el helper.'
    }
    $keyText=[IO.File]::ReadAllText($hostKey).Trim()
    foreach($s in @(
        @{existing='';expected="$keyText`r`n"},
        @{existing='old';expected="`r`n$keyText`r`n"},
        @{existing="old`n";expected="$keyText`r`n"},
        @{existing="old`r`n";expected="$keyText`r`n"},
        @{existing="old`r`n$keyText`r`n";expected=''}
    )){
        $value=Get-CocoRemoteKeyAppend $s.existing $keyText
        if(([string]$value)-cne([string]$s.expected)){throw 'La insercion de la clave falla sin newline, con LF/CRLF o en reejecuciones.'}
    }
    $bad=Join-Path $tempRoot 'invalid.pub'
    foreach($content in @(
        'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB',
        ('ssh-ed25519 '+[Convert]::ToBase64String([byte[]]::new(51))),
        (([IO.File]::ReadAllText($pub)) + [Environment]::NewLine + 'ssh-ed25519 extra')
    )){
        [IO.File]::WriteAllText($bad,$content)
        $rejected=$false
        try{& $helper -PublicKeyFile $bad -ValidateOnly|Out-Null}catch{$rejected=$true}
        if(-not$rejected){throw 'Se acepto una clave publica SSH corrupta o no autorizada.'}
    }
    if(-not$launcher.Contains('if(-not$paths.IsTest-and(Test-CocoRemoteAccessAvailableHere))')-or
       $launcher-notmatch 'CocoRemoteAccessButton'-or
       $launcher-notmatch 'Show-CocoRemoteAccessSetup'-or
       $launcher-notmatch 'Test-CocoRemoteAccessAvailableHere'){
        throw 'Falta la restriccion al equipo autorizado o el boton de configuracion SSH.'
    }
    if($launcher-notmatch "Add_Click\(\{"-or$launcher-notmatch "Start-Process -FilePath 'powershell.exe' -Verb RunAs"){
        throw 'SSH debe habilitarse solo al pulsar un boton y aceptar UAC.'
    }
    if($packager-notmatch "'CocoRemoteAccess.ps1'"){
        throw 'El packager no incluye el helper opcional de SSH.'
    }
    if($packager-notmatch "'CocoRemoteAccessHost.pub'"){
        throw 'El packager no incluye la clave publica fija del host.'
    }
    if(-not$helperText.Contains("targetZeroTierNode='5a84d2bb9e'")-or
       -not$helperText.Contains("cocoNetwork='58997fc5f3c0c001'")-or
       $helperText-notmatch 'Test-CocoRemoteAccessTarget'){
        throw 'El helper SSH no valida el nodo de origen.'
    }
    if($launcher.Contains('OpenFileDialog')){
        # Coco usa dialogos de archivos para skins y partidas, pero SSH no
        # debe pedir seleccionar un archivo: la clave esta incluida.
        $sshFunction=[regex]::Match($launcher,'(?s)function Show-CocoRemoteAccessSetup\s*\{(.*?)\r?\n\}\s*\r?\nfunction Start-CocoLauncherExperience')
        if(-not$sshFunction.Success-or$sshFunction.Value.Contains('OpenFileDialog')){
            throw 'SSH sigue pidiendo seleccionar la clave publica.'
        }
    }
    if(-not$helperText.Contains('Get-NetIPAddress -AddressFamily IPv4 -IPAddress $targetZeroTierIp')-or
       -not$helperText.Contains('Get-NetTCPConnection -State Listen -LocalPort 22')){
        throw 'El instalador carece de comprobacion de IP local o listener SSH.'
    }
    'PASS: nodo restringido, clave fija, idempotencia de authorized_keys, ACL/estado y consentimiento requerido.'
}finally{
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
