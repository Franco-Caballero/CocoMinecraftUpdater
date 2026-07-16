[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $env:TEMP "coco-bootstrap-replacement-$([guid]::NewGuid())"

function Get-HelperTemplate([string]$Path){
    $text=[IO.File]::ReadAllText($Path)
    $match=[regex]::Match($text,"(?s)\`$helperText=@'\r?\n(?<body>.*?)\r?\n'@")
    if(-not$match.Success){throw "No se encontro el helper diferido en $Path."}
    $match.Groups['body'].Value
}

try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    foreach($relative in @('bootstrap\CocoBootstrapper.ps1','engine\CocoUpdater.ps1')){
        $template=Get-HelperTemplate (Join-Path $root $relative)
        if($template-notmatch'\$destinationVersion-gt\$sourceVersion'){
            throw "${relative}: un helper antiguo podria degradar un EXE mas nuevo."
        }
        $name=[IO.Path]::GetFileNameWithoutExtension($relative)
        $case=Join-Path $testRoot $name
        New-Item -ItemType Directory -Path $case -Force|Out-Null
        $helper=Join-Path $case 'helper.ps1'
        $source=Join-Path $case 'source.exe'
        $destination=Join-Path $case 'destination.exe'
        $log=Join-Path $case 'replacement.log'
        [IO.File]::WriteAllText($helper,$template,(New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText($source,'new-bootstrap',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($destination,'old-bootstrap',(New-Object Text.UTF8Encoding($false)))
        $expected=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -WaitPid 2147483647 -Source $source -Destination $destination -ExpectedHash $expected -LogPath $log
        if($LASTEXITCODE-ne0){throw "${relative}: helper termino con codigo $LASTEXITCODE."}
        if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()-ne$expected){
            throw "${relative}: el destino no recibio el bootstrap verificado."
        }
        if(Test-Path -LiteralPath $source){throw "${relative}: el archivo fuente no fue consumido."}
        if(Get-ChildItem $case -Filter '*.coco-old.*' -File -ErrorAction SilentlyContinue){
            throw "${relative}: quedo un respaldo temporal despues del reemplazo exitoso."
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
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -WaitPid 2147483647 -Source $source -Destination $destination -ExpectedHash $olderHash -LogPath $log
                if($LASTEXITCODE-ne0){throw "${relative}: helper anti-downgrade termino con codigo $LASTEXITCODE."}
                if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash-ne$newerHash){
                    throw "${relative}: un reemplazo pendiente $olderVersion degrado el destino $newerVersion."
                }
            }
        }
    }
    'PASS: helpers reemplazan con backup valido y nunca degradan un EXE de version mayor.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
