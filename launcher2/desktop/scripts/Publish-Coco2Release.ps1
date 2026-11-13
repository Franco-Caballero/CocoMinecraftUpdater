<#
  Publishes one verified Coco 2 candidate (dist/publish-ready/<version>-<sha12>) to the fixed
  GitHub release `coco2-channel`, which every installed Coco 2 reads for updates.
  - Never marks it Latest: Latest and its latest.json belong to Coco 1 and to Minecraft's Bridge.
  - Uploads the versioned Setup and .sig first and latest.json last, so no client is ever told
    about a version whose file is not downloadable yet.
  - Afterwards it downloads what GitHub serves and checks it byte for byte.
  Requires `gh` signed in with write access. Run it only when the host asked to publish.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidatePath,
    [string]$Repository='Franco-Caballero/CocoMinecraftUpdater',
    [string]$Tag='coco2-channel'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

function Invoke-Gh([string[]]$Arguments){
    $output=& gh @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "gh $($Arguments -join ' ') falló: $output"}
    return $output
}

$candidate=(Resolve-Path -LiteralPath $CandidatePath).Path
$feedPath=Join-Path $candidate 'latest.json'
$feed=Get-Content -LiteralPath $feedPath -Raw -Encoding UTF8 | ConvertFrom-Json
$version=[string]$feed.version
if($version -notmatch '^\d+\.\d+\.\d+$'){throw "Versión inválida en latest.json: $version"}
$assetName="CocoLauncher2_$($version)_x64-setup.exe"
$setup=Join-Path $candidate $assetName
$signature="$setup.sig"
foreach($path in $setup,$signature){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Falta $path"}}
$expectedUrl="https://github.com/$Repository/releases/download/$Tag/$assetName"
$item=$feed.platforms.'windows-x86_64'
if([string]$item.url -cne $expectedUrl){throw "latest.json apunta a '$($item.url)', no a '$expectedUrl'."}
if([string]$item.signature -cne (Get-Content -LiteralPath $signature -Raw -Encoding UTF8).Trim()){throw 'latest.json no lleva la firma de este Setup.'}
$sha=(Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
if((Split-Path $candidate -Leaf) -cne "$version-$($sha.Substring(0,12).ToUpperInvariant())"){throw 'La carpeta del candidato no corresponde al SHA del Setup.'}

$exists=$true
try{Invoke-Gh @('release','view',$Tag,'-R',$Repository,'--json','tagName') | Out-Null}catch{$exists=$false}
if(-not$exists){
    Write-Host "Creando el release fijo $Tag (pre-release, nunca Latest)…"
    Invoke-Gh @('release','create',$Tag,'-R',$Repository,'--prerelease','--latest=false','--title','Coco Launcher 2 (canal de actualizaciones)','--notes','Canal fijo que lee Coco Launcher 2. No es el Latest de Coco 1.') | Out-Null
}
$present=@(Invoke-Gh @('release','view',$Tag,'-R',$Repository,'--json','assets','-q','.assets[].name'))
if($present -contains $assetName){
    # A published version is immutable: only accept the exact same bytes.
    $check=Join-Path $env:TEMP "coco2-published-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $check | Out-Null
    try{
        Invoke-Gh @('release','download',$Tag,'-R',$Repository,'-p',$assetName,'-D',$check) | Out-Null
        if((Get-FileHash -LiteralPath (Join-Path $check $assetName) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha){
            throw "$assetName ya está publicado con otros bytes. Sube una versión nueva; nunca reemplaces una publicada."
        }
    }finally{Remove-Item -LiteralPath $check -Recurse -Force -ErrorAction SilentlyContinue}
}else{
    Invoke-Gh @('release','upload',$Tag,'-R',$Repository,$setup,$signature) | Out-Null
}
# A link that never changes, for friends who never had Coco 1: always the newest Setup.
$stableName='CocoLauncher2-Setup.exe'
$stableUrl="https://github.com/$Repository/releases/download/$Tag/$stableName"
$stableDir=Join-Path $env:TEMP "coco2-stable-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stableDir | Out-Null
try{
    Copy-Item -LiteralPath $setup -Destination (Join-Path $stableDir $stableName)
    Invoke-Gh @('release','upload',$Tag,'-R',$Repository,(Join-Path $stableDir $stableName),'--clobber') | Out-Null
}finally{Remove-Item -LiteralPath $stableDir -Recurse -Force -ErrorAction SilentlyContinue}
Invoke-Gh @('release','upload',$Tag,'-R',$Repository,$feedPath,'--clobber') | Out-Null

# What friends will actually download, not what we think we uploaded.
$verify=Join-Path $env:TEMP "coco2-verify-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $verify | Out-Null
try{
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repository/releases/download/$Tag/latest.json" -OutFile (Join-Path $verify 'latest.json')
    $served=Get-Content -LiteralPath (Join-Path $verify 'latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if([string]$served.version -cne $version -or [string]$served.platforms.'windows-x86_64'.url -cne $expectedUrl){throw 'GitHub sirve otro latest.json.'}
    Invoke-WebRequest -UseBasicParsing -Uri $expectedUrl -OutFile (Join-Path $verify $assetName)
    if((Get-FileHash -LiteralPath (Join-Path $verify $assetName) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha){throw 'GitHub sirve otro Setup.'}
    Invoke-WebRequest -UseBasicParsing -Uri $stableUrl -OutFile (Join-Path $verify $stableName)
    if((Get-FileHash -LiteralPath (Join-Path $verify $stableName) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sha){throw 'El enlace fijo sirve otro Setup.'}
}finally{Remove-Item -LiteralPath $verify -Recurse -Force -ErrorAction SilentlyContinue}
$latest=Invoke-Gh @('release','view','-R',$Repository,'--json','tagName','-q','.tagName')
if([string]$latest -ceq $Tag){throw "ATENCIÓN: $Tag quedó como Latest; eso rompe a Coco 1. Marca de nuevo el release de Coco 1 como Latest."}
# The signed catalog channel only carries games newer than what this Setup ships: record it.
# Built and published together, so the manifests on disk are the ones inside this Setup.
$manifests=Join-Path $PSScriptRoot '..\src-tauri\resources\install-manifests.json'
if((Get-Item -LiteralPath $manifests).LastWriteTimeUtc -gt (Get-Item -LiteralPath $setup).LastWriteTimeUtc){
    Write-Warning 'install-manifests.json cambió después de compilar este Setup: channel-baseline.json no se actualiza. Revísalo antes de publicar el catálogo.'
}else{
    $games=[ordered]@{}
    # PowerShell 5.1 emits a JSON array as ONE object: enumerate it before sorting.
    $list=@(Get-Content -LiteralPath $manifests -Raw -Encoding UTF8 | ConvertFrom-Json)
    foreach($m in @($list | ForEach-Object {$_} | Sort-Object id)){$games[[string]$m.id]=[string]$m.version}
    $baseline=[ordered]@{note='Games and versions shipped inside the last published Coco 2 Setup. Publish-Coco2Release.ps1 rewrites it; Publish-Coco2Catalog.mjs sends everything newer through the signed channel.';setupVersion=$version;games=$games}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '..\channel-baseline.json'),(($baseline|ConvertTo-Json -Depth 4)+"`n"),(New-Object Text.UTF8Encoding($false)))
}
# Older candidates are already on GitHub; keeping their local copies only takes space.
$candidateDir=(Get-Item -LiteralPath $setup).Directory
foreach($old in @(Get-ChildItem -LiteralPath $candidateDir.Parent.FullName -Directory | Where-Object { $_.FullName -ne $candidateDir.FullName -and $_.Name -match '^\d+\.\d+\.\d+-[0-9A-F]{12}$' })){
    Remove-Item -LiteralPath $old.FullName -Recurse -Force
}
[pscustomobject]@{version=$version;url=$expectedUrl;shareLink=$stableUrl;sha256=$sha;size=(Get-Item -LiteralPath $setup).Length;latestRelease=[string]$latest} | ConvertTo-Json
