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
    'PASS: Publisher instala y verifica localmente el bootstrap antes de publicar el borrador.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
