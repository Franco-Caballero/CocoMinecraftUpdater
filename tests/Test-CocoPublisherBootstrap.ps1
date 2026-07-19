[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$publisher=Join-Path $root 'tools\Publish-CocoRelease.ps1'
$testRoot=Join-Path $env:TEMP "coco-publisher-bootstrap-$([guid]::NewGuid())"

try{
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($publisher,[ref]$tokens,[ref]$errors)
    if($errors){throw ($errors|Out-String)}
    $functionAst=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Install-CocoPublishedBootstrapLocally'},$true)|Select-Object -First 1)
    if(-not$functionAst){throw 'No existe Install-CocoPublishedBootstrapLocally.'}
    if($functionAst.Extent.Text-notmatch'\$destinationVersion-gt\$sourceVersion'){
        throw 'El Publisher podria degradar un bootstrap local de version mayor.'
    }
    Invoke-Expression $functionAst.Extent.Text
    $cacheFunctionAst=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Install-CocoPublishedEngineCacheLocally'},$true)|Select-Object -First 1)
    $archiveFunctionAst=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Archive-StaleCocoBootstrapArtifacts'},$true)|Select-Object -First 1)
    if(-not$cacheFunctionAst-or-not$archiveFunctionAst){throw 'Falta hidratar el cache del engine o archivar helpers obsoletos.'}
    Invoke-Expression $cacheFunctionAst.Extent.Text
    Invoke-Expression $archiveFunctionAst.Extent.Text

    $sourceRoot=Join-Path $testRoot 'source'
    $canonicalRoot=Join-Path $testRoot 'canonical'
    New-Item -ItemType Directory -Path $sourceRoot,$canonicalRoot -Force|Out-Null
    $source=Join-Path $sourceRoot 'CocoUpdater.exe'
    $destination=Join-Path $canonicalRoot 'CocoUpdater.exe'
    [IO.File]::WriteAllText($source,'publisher-bootstrap-new',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($destination,'publisher-bootstrap-old',(New-Object Text.UTF8Encoding($false)))
    $expected=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    Install-CocoPublishedBootstrapLocally $source $expected $canonicalRoot
    if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()-ne$expected){
        throw 'El Publisher no instalo localmente el bootstrap candidato.'
    }
    if(Get-ChildItem $canonicalRoot -Filter '*.coco-old.publisher.*' -File -ErrorAction SilentlyContinue){
        throw 'El Publisher dejo un respaldo temporal despues del reemplazo exitoso.'
    }
    $engineSource=Join-Path $sourceRoot 'engine-content';New-Item -ItemType Directory -Path $engineSource|Out-Null
    'param()'|Set-Content (Join-Path $engineSource 'CocoUpdater.ps1') -Encoding UTF8
    $engineZip=Join-Path $sourceRoot 'coco-engine-9.9.9.zip';Compress-Archive -Path (Join-Path $engineSource '*') -DestinationPath $engineZip
    $engineHash=(Get-FileHash -LiteralPath $engineZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestPath=Join-Path $sourceRoot 'latest.json'
    [ordered]@{version='9.9.9';engine=[ordered]@{version='9.9.9';sha256=$engineHash}}|ConvertTo-Json -Depth 4|Set-Content $manifestPath -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $canonicalRoot 'engine\9.9.8') -Force|Out-Null
    'old'|Set-Content (Join-Path $canonicalRoot 'engine-9.9.8.zip') -Encoding UTF8
    Install-CocoPublishedEngineCacheLocally $manifestPath $engineZip $canonicalRoot
    if((Get-Content (Join-Path $canonicalRoot 'latest.json') -Raw|ConvertFrom-Json).version-ne'9.9.9'-or
       -not(Test-Path (Join-Path $canonicalRoot 'engine\9.9.9\CocoUpdater.ps1'))-or
       (Test-Path (Join-Path $canonicalRoot 'engine\9.9.8'))-or(Test-Path (Join-Path $canonicalRoot 'engine-9.9.8.zip'))){
        throw 'El Publisher no dejo el manifiesto y engine nuevos como unico cache rapido.'
    }
    'stale'|Set-Content (Join-Path $canonicalRoot 'Apply-CocoBootstrapUpdate-123.ps1') -Encoding UTF8
    'old'|Set-Content (Join-Path $canonicalRoot 'CocoUpdater.exe.coco-old.123') -Encoding UTF8
    if((Archive-StaleCocoBootstrapArtifacts '9.9.9' $canonicalRoot)-ne2-or
       (Test-Path (Join-Path $canonicalRoot 'Apply-CocoBootstrapUpdate-123.ps1'))-or
       -not(Test-Path (Join-Path $canonicalRoot 'backups\publisher-stale-artifacts-9.9.9\CocoUpdater.exe.coco-old.123'))){
        throw 'El Publisher no archivo los helpers obsoletos de forma recuperable.'
    }
    $olderCanonical=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\CocoUpdater.exe'
    $newerCandidate=Join-Path $root 'dist\CocoUpdater.exe'
    if((Test-Path -LiteralPath $olderCanonical)-and(Test-Path -LiteralPath $newerCandidate)){
        $olderVersion=try{[version](Get-Item $olderCanonical).VersionInfo.FileVersion}catch{$null}
        $newerVersion=try{[version](Get-Item $newerCandidate).VersionInfo.FileVersion}catch{$null}
        if($olderVersion-and$newerVersion-and$newerVersion-gt$olderVersion){
            Copy-Item -LiteralPath $olderCanonical -Destination $source -Force
            Copy-Item -LiteralPath $newerCandidate -Destination $destination -Force
            $newerHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            $olderHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            Install-CocoPublishedBootstrapLocally $source $olderHash $canonicalRoot
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash-ne$newerHash){
                throw "El Publisher degrado el destino $newerVersion con la fuente $olderVersion."
            }
        }
    }
    'PASS: Publisher instala bootstrap, hidrata engine/manifiesto y archiva helpers antes de publicar.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
