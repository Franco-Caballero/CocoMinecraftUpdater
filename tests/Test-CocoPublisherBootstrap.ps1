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
    'PASS: Publisher instala y verifica localmente el bootstrap antes de publicar el borrador.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
