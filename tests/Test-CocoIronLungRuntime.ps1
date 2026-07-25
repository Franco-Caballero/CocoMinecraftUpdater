[CmdletBinding()]
param(
    [string]$ImportCache=(Join-Path $env:TEMP 'coco-curseforge-import-cache'),
    [string]$PortableMcArchive=(Join-Path $env:TEMP 'coco-portablemc-audit-5.0.4\portablemc.zip'),
    [string]$AuditRoot=(Join-Path $env:TEMP 'coco-iron-lung-runtime-audit'),
    [switch]$KeepAuditRoot
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue){
    throw 'La auditoria Iron Lung exige que no exista ningun Java abierto, para no confundirlo con Minecraft real.'
}
if(-not(Test-Path -LiteralPath $ImportCache -PathType Container)){throw "No existe el cache oficial importado: $ImportCache"}
if(-not(Test-Path -LiteralPath $PortableMcArchive -PathType Leaf)){throw "No existe el release PortableMC auditado: $PortableMcArchive"}

$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$catalog=Read-CocoLauncherCatalog (Join-Path $root 'launcher\catalog.template.json')
$experience=@($catalog.experiences|Where-Object id -eq 'iron-lung'|Select-Object -First 1)[0]
$lock=Read-CocoExperienceLock (Join-Path $root 'launcher\experiences\iron-lung.lock.json') $experience

if(Test-Path -LiteralPath $AuditRoot){
    $resolved=[IO.Path]::GetFullPath($AuditRoot)
    $temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'AuditRoot debe permanecer dentro de TEMP.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
$cacheRoot=Join-Path $AuditRoot 'cache'
$objects=Join-Path $cacheRoot 'objects'
New-Item -ItemType Directory -Path $objects -Force|Out-Null

foreach($asset in @($lock.pack.archive)+@($lock.assets)){
    $sourceDirectory=Join-Path $ImportCache ("{0}\{1}"-f[int64]$asset.projectId,[int64]$asset.fileId)
    $source=@(Get-ChildItem -LiteralPath $sourceDirectory -File|Where-Object Length -eq ([int64]$asset.size)|Select-Object -First 1)[0]
    if(-not$source){throw "No se encontro en cache $($asset.projectId)/$($asset.fileId): $($asset.name)"}
    if((Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()-ne([string]$asset.sha256).ToLowerInvariant()){
        throw "El cache importado no coincide para $($asset.name)."
    }
    $destination=Get-CocoLockedAssetCachePath $cacheRoot $asset
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
    # PowerShell 5.1 resuelve de forma incorrecta algunos Target de hardlink que
    # contienen apostrofes/corchetes. La copia queda siempre dentro del stage.
    Copy-Item -LiteralPath $source.FullName -Destination $destination
}

$backendDownload=Join-Path $cacheRoot ("downloads\launcher-backends\$($catalog.backend.sha256).zip")
New-Item -ItemType Directory -Path (Split-Path $backendDownload -Parent) -Force|Out-Null
Copy-Item -LiteralPath $PortableMcArchive -Destination $backendDownload

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Download-VerifiedFile([string]$Url,[string]$Destination,[string]$ExpectedHash){
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    if((Get-Sha256 $Destination)-ne$ExpectedHash.ToLowerInvariant()){throw "Hash inesperado al descargar $Url"}
}

$identity=[pscustomobject]@{mode='offline';username='CocoAudit';uuid=''}
$result=Invoke-CocoManagedExperienceLaunch $catalog iron-lung $identity host (Join-Path $root 'launcher') $cacheRoot (Join-Path $AuditRoot 'experiences') -Dry
$instance=$result.Installation.InstanceRoot
$mods=@(Get-ChildItem -LiteralPath (Join-Path $instance 'mods') -File -Filter '*.jar')
$resourcepacks=@(Get-ChildItem -LiteralPath (Join-Path $instance 'resourcepacks') -File -Filter '*.zip')
$shaderpacks=@(Get-ChildItem -LiteralPath (Join-Path $instance 'shaderpacks') -File -Filter '*.zip')
if($mods.Count-ne69){throw "La instancia host Iron Lung contiene $($mods.Count) mods; se esperaban 68 del pack sin Essential mas MCWiFiPnP."}
if($resourcepacks.Count-ne9-or$shaderpacks.Count-ne1){throw 'La instancia Iron Lung no contiene los resourcepacks/shaderpack esperados (8 assets + 1 override, y 1 shader).'}
if(-not($mods.Name-like'mcwifipnp-1.7.6-1.20.1-forge.jar')){throw 'La instancia host no contiene el control LAN fijado.'}
if($result.Result.ExitCode-ne0-or$result.Result.Arguments-notcontains'--dry'){throw 'PortableMC no completo la preparacion seca Iron Lung.'}
if($result.Result.Arguments-notcontains'forge::1.20.1-47.4.10'){throw 'PortableMC no preparo el Forge exacto de Iron Lung.'}
if(Test-Path -LiteralPath (Join-Path $instance 'saves\coco')){throw 'La auditoria intento copiar el mundo Coco original.'}

"PASS: Iron Lung host aislado con 69 mods (Essential excluido), 9 resourcepacks (8 assets + 1 override), 1 shaderpack y Forge 47.4.10/Java administrado. AuditRoot=$AuditRoot"
if(-not$KeepAuditRoot){
    Remove-Item -LiteralPath $AuditRoot -Recurse -Force
}
