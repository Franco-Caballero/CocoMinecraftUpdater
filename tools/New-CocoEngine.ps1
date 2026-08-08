[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Version,
    [Parameter(Mandatory = $true)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$stage = Join-Path $env:TEMP "coco-engine-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'engine\CocoUpdater.ps1') -Destination (Join-Path $stage 'CocoUpdater.ps1') -Force
foreach($helper in 'CocoNetwork.ps1','CocoNetworkElevated.ps1','CocoNetworkAuthorizer.ps1','CocoLauncher.ps1','CocoSessionService.ps1'){
    Copy-Item -LiteralPath (Join-Path $projectRoot "engine\$helper") -Destination (Join-Path $stage $helper) -Force
}
$launcherStage=Join-Path $stage 'launcher';New-Item -ItemType Directory -Path (Join-Path $launcherStage 'experiences') -Force|Out-Null
$catalog=Get-Content -LiteralPath (Join-Path $projectRoot 'launcher\catalog.template.json') -Raw|ConvertFrom-Json
$original=@($catalog.experiences|Where-Object id -eq 'coco-original'|Select-Object -First 1)[0]
if(-not$original){throw 'El catalogo launcher no contiene Coco original.'}
$original.pack.version=$Version
[IO.File]::WriteAllText((Join-Path $launcherStage 'catalog.json'),($catalog|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
foreach($experience in @($catalog.experiences|Where-Object managementMode -eq 'managed')){
    $lockPaths=@()
    if($experience.pack -and [string]$experience.pack.lockPath){$lockPaths+=([string]$experience.pack.lockPath)}
    if($experience.worldTemplate -and [string]$experience.worldTemplate.lockPath){$lockPaths+=([string]$experience.worldTemplate.lockPath)}
    foreach($declaredPath in $lockPaths){
        if([string]::IsNullOrWhiteSpace($declaredPath)){continue}
        $lockPath=$declaredPath-replace'\\','/'
        if($lockPath-notmatch'^launcher/experiences/[a-z0-9][a-z0-9.-]{1,95}\.lock\.json$'){throw "lockPath inseguro para '$($experience.id)': $lockPath"}
        $source=Join-Path $projectRoot ($lockPath-replace'/','\')
        $destination=Join-Path $stage ($lockPath-replace'/','\')
        if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Falta el lock de '$($experience.id)': $source"}
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}
$assets=Join-Path $stage 'assets'
New-Item -ItemType Directory -Path $assets -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'fullbody.png') -Destination (Join-Path $assets 'fullbody.png') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'reynaico.ico') -Destination (Join-Path $assets 'reynaico.ico') -Force
$skinSource=Join-Path $projectRoot 'launcher\assets\skins\smolbird.png.base64'
$skinDestination=Join-Path $assets 'skins\smolbird.png'
New-Item -ItemType Directory -Path (Split-Path $skinDestination -Parent) -Force|Out-Null
$skinBase64=([IO.File]::ReadAllText($skinSource)).Trim()
[IO.File]::WriteAllBytes($skinDestination,[Convert]::FromBase64String($skinBase64))
$skinPolicy=@($catalog.globalPolicies.customSkinLoader.localSkins|Where-Object username -eq 'smolbird'|Select-Object -First 1)[0]
if(-not$skinPolicy-or(Get-FileHash -LiteralPath $skinDestination -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$skinPolicy.sha256){
    throw 'La skin global de smolbird no coincide con el hash declarado.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zip = Join-Path $OutputDirectory "coco-engine-$Version.zip"
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item -LiteralPath $stage -Recurse -Force
[pscustomobject]@{ version = $Version; path = $zip; sha256 = $hash; size = (Get-Item $zip).Length } | ConvertTo-Json
