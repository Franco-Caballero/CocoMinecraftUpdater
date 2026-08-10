[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,47}$')][string]$ExperienceId,
    [ValidateSet('Prepare','Launch')][string]$Action='Prepare',
    [ValidateSet('host','client')][string]$Role='host',
    [ValidatePattern('^[A-Za-z0-9_]{3,16}$')][string]$Username='smolbird',
    [switch]$Live,
    [switch]$EnableAutoJoin
)

$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$catalogTemplate=Join-Path $repoRoot 'launcher\catalog.template.json'
$sourceCatalog=Get-Content -LiteralPath $catalogTemplate -Raw|ConvertFrom-Json
$sourceExperience=@($sourceCatalog.experiences|Where-Object id -eq $ExperienceId|Select-Object -First 1)[0]
if(-not$sourceExperience-or$sourceExperience.managementMode-ne'managed'){
    throw "No existe una experiencia administrada '$ExperienceId' en el catalogo."
}
$liveExperiencesRoot=Join-Path $env:APPDATA 'CocoMinecraft\experiences'
$instanceLocationsPath=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\instance-locations.json'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$launcherPath=Join-Path $repoRoot 'engine\CocoLauncher.ps1'
. $launcherPath
$liveInstance=Get-CocoExperienceInstanceRoot $sourceExperience $liveExperiencesRoot $instanceLocationsPath
if(-not$Live-and(Test-Path -LiteralPath $liveInstance)){
    throw "Ya existe una instancia viva en '$liveInstance'. Usa -Live para probarla; Coco no crea una copia temporal paralela."
}

$running=@(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|Where-Object{
    $_.CommandLine-match'(?i)minecraft|fabric|forge'-and$_.CommandLine-notmatch'GradleDaemon'
})
if($running.Count){throw 'Cierra Minecraft antes de preparar o lanzar una experiencia de desarrollo.'}

$devRoot=Join-Path $env:TEMP ("coco-experience-dev-$ExperienceId")
$buildRoot=Join-Path $devRoot ("engine-build-"+[guid]::NewGuid().ToString('N'))
$engineRoot=Join-Path $devRoot ("engine-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildRoot,$engineRoot -Force|Out-Null
$release=Get-Content -LiteralPath (Join-Path $repoRoot 'release\latest.json') -Raw|ConvertFrom-Json
$built=& (Join-Path $repoRoot 'tools\New-CocoEngine.ps1') -Version ([string]$release.version) -OutputDirectory $buildRoot|ConvertFrom-Json
Expand-Archive -LiteralPath $built.path -DestinationPath $engineRoot

$script:CocoEngineRoot=$engineRoot
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $engineRoot 'CocoLauncher.ps1'))))
$catalog=Read-CocoLauncherCatalog (Join-Path $engineRoot 'launcher\catalog.json')
$identity=[pscustomobject]@{mode='offline';username=$Username;uuid=''}
$cacheRoot=if($Live){
    Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'
}else{
    Join-Path $devRoot 'cache'
}
$experiencesRoot=if($Live){
    $liveExperiencesRoot
}else{
    Join-Path $devRoot 'experiences'
}
$instanceLocationsPath=if($Live){
    Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\instance-locations.json'
}else{
    Join-Path $devRoot 'instance-locations.json'
}

$common=@(
    $catalog,
    $ExperienceId,
    $identity,
    $Role,
    (Join-Path $engineRoot 'launcher'),
    $cacheRoot,
    $experiencesRoot
)
if($Action-eq'Prepare'){
    $result=Invoke-CocoManagedExperienceLaunch @common -Dry -DisableAutoJoin -SkipLocationPrompt -InstanceLocationsPath $instanceLocationsPath
    [pscustomobject]@{
        Status=$result.Status
        Experience=$ExperienceId
        Role=$Role
        Target=if($Live){'live'}else{'temporary'}
        Instance=$result.Installation.InstanceRoot
        Files=$result.Installation.Files
        Engine=$engineRoot
    }
    exit 0
}

$result=if($EnableAutoJoin){
    Invoke-CocoManagedExperienceLaunch @common -SkipLocationPrompt -InstanceLocationsPath $instanceLocationsPath
}else{
    Invoke-CocoManagedExperienceLaunch @common -DisableAutoJoin -SkipLocationPrompt -InstanceLocationsPath $instanceLocationsPath
}
[pscustomobject]@{
    Status=$result.Status
    Experience=$ExperienceId
    Role=$Role
    Target=if($Live){'live'}else{'temporary'}
    Instance=$result.Installation.InstanceRoot
    ProcessId=$result.Process.Id
    Log=$result.LogPath
}
Wait-CocoPortableMcGame $result.Process -PumpUi -Dispose
