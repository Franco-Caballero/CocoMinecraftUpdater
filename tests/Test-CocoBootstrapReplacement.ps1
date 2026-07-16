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
        $name=[IO.Path]::GetFileNameWithoutExtension($relative)
        $case=Join-Path $testRoot $name
        New-Item -ItemType Directory -Path $case -Force|Out-Null
        $helper=Join-Path $case 'helper.ps1'
        $source=Join-Path $case 'source.exe'
        $destination=Join-Path $case 'destination.exe'
        $log=Join-Path $case 'replacement.log'
        [IO.File]::WriteAllText($helper,(Get-HelperTemplate (Join-Path $root $relative)),(New-Object Text.UTF8Encoding($true)))
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
    }
    'PASS: ambos helpers reemplazan el EXE realmente en Windows PowerShell 5.1 con backup valido.'
}finally{
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
