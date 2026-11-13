[CmdletBinding()]
param(
    [string]$PublicKeyFile = '',
    [ValidatePattern('^10\.77\.37\.1$')][string]$AllowedHostIp = '10.77.37.1',
    [switch]$ValidateOnly,
    [switch]$CheckTarget
)

$ErrorActionPreference='Stop'
$targetZeroTierNode='5a84d2bb9e'
$cocoNetwork='58997fc5f3c0c001'
$targetZeroTierIp='10.77.37.116'
# Defensa ante una clave publica accidentalmente reemplazada en el paquete.
# No es un secreto: solo se autoriza esta clave ed25519 en el equipo propio.
$expectedHostPublicKey='AAAAC3NzaC1lZDI1NTE5AAAAIHtqmR7JDWwQi1eZLgq0H0OtaPiTudXBGtAdp3KeZR43'

function Test-CocoRemoteAccessTarget {
    $candidates=@(
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
        'C:\Program Files\ZeroTier\One\zerotier-cli.exe'
    )
    $cli=@($candidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)
    if(-not$cli.Count){return $false}
    try{
        $info=(& $cli[0] info 2>&1|Out-String)
        if($LASTEXITCODE-ne0-or$info-notmatch ('(?i)\b'+$targetZeroTierNode+'\b')){return $false}
        $networks=(& $cli[0] listnetworks 2>&1|Out-String)
        if($LASTEXITCODE-ne0-or$networks-notmatch ('(?i)\b'+$cocoNetwork+'\b')){return $false}
        return $true
    }catch{return $false}
}

function Read-CocoRemotePublicKey([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Selecciona un archivo de clave publica SSH valido (.pub).'
    }
    $file=Get-Item -LiteralPath $Path
    if($file.Length-lt70-or$file.Length-gt4096) {
        throw 'El tamano de la clave publica SSH es inesperado.'
    }
    $content=[IO.File]::ReadAllText($file.FullName).Trim()
    if($content-notmatch '^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]+)?$') {
        throw 'Solo se admiten claves publicas ssh-ed25519 de una linea.'
    }
    $blob=try{[Convert]::FromBase64String($Matches[1])}catch{throw 'El contenido de la clave SSH no es Base64 valido.'}
    # Formato wire SSH: longitud y nombre del algoritmo, luego longitud y clave (32 bytes).
    if($blob.Length-ne51-or
       $blob[0]-ne0-or$blob[1]-ne0-or$blob[2]-ne0-or$blob[3]-ne11-or
       [Text.Encoding]::ASCII.GetString($blob,4,11)-ne'ssh-ed25519'-or
       $blob[15]-ne0-or$blob[16]-ne0-or$blob[17]-ne0-or$blob[18]-ne32) {
        throw 'La clave no es una clave publica ed25519 valida.'
    }
    return $content
}

function Get-CocoRemoteKeyAppend([string]$ExistingText,[string]$PublicKey) {
    # El archivo authorized_keys puede acabar sin salto de linea.
    # Add-Content no garantiza insertar el separador delante de otra clave.
    $lines=@($ExistingText -split '\r\n|\n|\r')
    if($lines -contains $PublicKey){return ''}
    $prefix=if($ExistingText.Length-gt0-and$ExistingText[-1]-notin@([char]10,[char]13)){"`r`n"}else{''}
    return ($prefix+$PublicKey+"`r`n")
}

if($CheckTarget){
    if(Test-CocoRemoteAccessTarget){exit 0}
    exit 7
}

if($ValidateOnly){
    if(-not$PublicKeyFile){throw 'Falta archivo de prueba de clave publica.'}
    $key=Read-CocoRemotePublicKey $PublicKeyFile
    Write-Output 'Clave publica SSH ed25519 valida.'
    return
}

# Solo el nodo personal designado puede habilitar este acceso. Este mismo
# control se repite en la consola elevada, independiente de la UI.
if(-not(Test-CocoRemoteAccessTarget)){
    throw 'Esta funcion solo puede habilitarse en el nodo ZeroTier nazorepulgadora.'
}
if($PublicKeyFile){throw 'El instalador utiliza exclusivamente la clave del host ya incorporada.'}
$key=Read-CocoRemotePublicKey (Join-Path $PSScriptRoot 'CocoRemoteAccessHost.pub')
if(($key.Split(' ')[1])-cne$expectedHostPublicKey){
    throw 'La clave publica incorporada no coincide con la huella fijada para el host.'
}

if(-not([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Activa el acceso SSH con permisos de administrador en este equipo.'
}

if(-not(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $targetZeroTierIp -ErrorAction SilentlyContinue)){
    throw 'ZeroTier no tiene asignada la IP esperada 10.77.37.116. No se habilitara SSH sin una direccion verificada.'
}
if(-not(Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)){
    throw 'La administracion de Windows Firewall no esta disponible.'
}

Write-Host 'COCO - CONFIGURACION VOLUNTARIA DE SSH' -ForegroundColor Cyan
Write-Host 'Esto autoriza acceso administrativo a este Windows mediante la clave SSH elegida.'
Write-Host "El instalador restringira su regla SSH al host $AllowedHostIp y la IP local $targetZeroTierIp."
Write-Host 'Otras reglas preexistentes de firewall pueden conceder acceso adicional y deben auditarse.'
$confirm=Read-Host 'Escribe ACTIVAR para instalar y habilitar el servidor SSH'
if($confirm-cne'ACTIVAR'){
    Write-Host 'Cancelado; SSH no se configuro.'
    exit 3
}

$logDirectory=Join-Path $env:ProgramData 'CocoMinecraftUpdater\logs'
New-Item -ItemType Directory -Path $logDirectory -Force|Out-Null
$logFile=Join-Path $logDirectory 'ssh-setup.log'
$stage='WindowsCapability'
try{
Add-Content -LiteralPath $logFile -Encoding utf8 -Value ("{0:o} Inicio de configuracion SSH local autorizada." -f (Get-Date))

$capabilityName='OpenSSH.Server~~~~0.0.1.0'
$capability=Get-WindowsCapability -Online -Name $capabilityName
if(-not$capability){throw 'Windows no devolvio el estado del componente OpenSSH Server.'}
if($capability.State-notin@('Installed','NotPresent')){
    throw "Estado no compatible del componente OpenSSH Server: $($capability.State). Revisa las caracteristicas opcionales y reinicios pendientes."
}
if($capability.State-ne'Installed'){
    Write-Host 'Instalando el componente oficial OpenSSH Server de Windows...'
    $added=Add-WindowsCapability -Online -Name $capabilityName
    if($added.RestartNeeded){
        throw 'Windows requiere reiniciar para completar la instalacion de OpenSSH Server.'
    }
    $verifiedCapability=Get-WindowsCapability -Online -Name $capabilityName
    if(-not$verifiedCapability-or$verifiedCapability.State-ne'Installed'){
        throw 'Windows no confirmo que OpenSSH Server quedara instalado.'
    }
}

$stage='AuthorizedKeysAndAcl'
$authorizedFile=Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$authorizedDir=Split-Path -Parent $authorizedFile
New-Item -ItemType Directory -Path $authorizedDir -Force|Out-Null
if(-not(Test-Path -LiteralPath $authorizedFile -PathType Leaf)){
    [IO.File]::WriteAllText($authorizedFile,'',[Text.Encoding]::ASCII)
}
# En Windows, sshd exige una DACL de administradores estricta.
# Eliminar ACE explicitas heredadas o previas, no solo desactivar herencia.
$adminSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$systemSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$acl=Get-Acl -LiteralPath $authorizedFile
$acl.SetAccessRuleProtection($true,$false)
foreach($entry in @($acl.Access)){
    [void]$acl.RemoveAccessRuleSpecific($entry)
}
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $adminSid,[Security.AccessControl.FileSystemRights]::FullControl,
    [Security.AccessControl.AccessControlType]::Allow
))
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $systemSid,[Security.AccessControl.FileSystemRights]::FullControl,
    [Security.AccessControl.AccessControlType]::Allow
))
Set-Acl -LiteralPath $authorizedFile -AclObject $acl
$verifiedAcl=Get-Acl -LiteralPath $authorizedFile
$actual=@($verifiedAcl.Access)
if(-not$verifiedAcl.AreAccessRulesProtected-or$actual.Count-ne2){
    throw 'La ACL del archivo de claves no quedo restringida a dos identidades.'
}
$allowedSids=@($adminSid.Value,$systemSid.Value)
foreach($entry in $actual){
    $sid=$entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if($sid-notin$allowedSids-or
       $entry.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow-or
       $entry.FileSystemRights-band[Security.AccessControl.FileSystemRights]::FullControl-ne[Security.AccessControl.FileSystemRights]::FullControl){
        throw 'Windows conservo un permiso de acceso inesperado en administrators_authorized_keys.'
    }
}
$currentKeys=[IO.File]::ReadAllText($authorizedFile)
$append=Get-CocoRemoteKeyAppend $currentKeys $key
if($append){
    [IO.File]::AppendAllText($authorizedFile,$append,[Text.Encoding]::ASCII)
}
if(@(Get-Content -LiteralPath $authorizedFile | Where-Object{$_ -ceq$key}).Count-ne1){
    throw 'La clave publica autorizada no figura exactamente una vez en el archivo.'
}

$stage='WindowsFirewall'
$firewallRule='OpenSSH-Server-In-TCP'
if(Get-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue){
    Set-NetFirewallRule -Name $firewallRule -Enabled True -Action Allow -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $AllowedHostIp -LocalAddress $targetZeroTierIp
}else{
    New-NetFirewallRule -Name $firewallRule -DisplayName 'OpenSSH Server (host Coco)' -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -LocalAddress $targetZeroTierIp -RemoteAddress $AllowedHostIp -Action Allow|Out-Null
}
$rule=Get-NetFirewallRule -Name $firewallRule -ErrorAction Stop
$ruleAddr=$rule|Get-NetFirewallAddressFilter
$rulePort=$rule|Get-NetFirewallPortFilter
if($rule.Enabled-ne'True'-or
   @($ruleAddr.LocalAddress)-notcontains$targetZeroTierIp-or
   @($ruleAddr.RemoteAddress)-notcontains$AllowedHostIp-or
   [string]$rulePort.Protocol-ne'TCP'-or
   @($rulePort.LocalPort)-notcontains'22'){
    throw 'La regla del firewall SSH no conserva las restricciones ZeroTier previstas.'
}

$stage='SshdService'
Set-Service -Name sshd -StartupType Automatic
$service=Get-Service -Name sshd -ErrorAction Stop
if($service.Status-ne'Running'){Start-Service -Name sshd}
if((Get-Service -Name sshd).Status-ne'Running'){
    throw 'El servicio de OpenSSH no quedo en estado Running.'
}
$listener=$null
$sshdProcess=(Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction Stop)
if(-not$sshdProcess-or[int]$sshdProcess.ProcessId-le0){
    throw 'El servicio sshd no tiene un proceso Windows asociado.'
}
for($attempt=0;$attempt-lt10;$attempt++){
    $listener=@(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue |
        Where-Object{$_.LocalAddress -in @($targetZeroTierIp,'0.0.0.0','::') -and
            $_.OwningProcess -eq [int]$sshdProcess.ProcessId})
    if($listener.Count){break}
    Start-Sleep -Milliseconds 500
}
if(-not$listener.Count){
    throw 'El servicio sshd figura activo, pero no se observa un listener en TCP 22.'
}

$stage='Success'
Add-Content -LiteralPath $logFile -Encoding utf8 -Value ("{0:o} SSH configurado, ACL/servicio/listener verificados. Host esperado $AllowedHostIp." -f (Get-Date))
}catch{
    $detail=[string]$_.Exception.Message
    try{Add-Content -LiteralPath $logFile -Encoding utf8 -Value ("{0:o} ERROR [$stage] $detail" -f (Get-Date))}catch{}
    throw "La instalacion SSH no se completo durante [$stage]: $detail"
}

Write-Host ''
Write-Host 'SERVICIO SSH INICIADO Y VERIFICADO LOCALMENTE' -ForegroundColor Green
Write-Host "Usuario administrador actual: $env:USERNAME"
Write-Host "Regla de firewall del instalador: $AllowedHostIp hacia ${targetZeroTierIp}:22"
Write-Host 'IMPORTANTE: verifica que no existan otras reglas de firewall que permitan SSH.'
Write-Host 'PENDIENTE: comprobar desde el host una conexion real con clave SSH y SFTP.'
Write-Host 'El servicio SSH seguira funcionando cuando cierres Coco Launcher.'
Write-Host "Diagnostico: $logFile"
Write-Host 'Para revocarlo, retira la clave de C:\ProgramData\ssh\administrators_authorized_keys.'
Read-Host 'Pulsa Enter para cerrar'
