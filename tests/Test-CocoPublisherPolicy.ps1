[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PublishedVersion
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$publisher=Join-Path $root 'tools\Publish-CocoRelease.ps1'
$testRoot=Join-Path $env:TEMP "coco-publisher-policy-$([guid]::NewGuid())"
$mods=Join-Path $testRoot 'mods'
New-Item -ItemType Directory -Path $mods -Force|Out-Null

try{
    $publisherText=[IO.File]::ReadAllText($publisher)
    if($publisherText-match'AllowModRemoval'-or$publisherText-match'desaparecerian mods ya publicados'){
        throw 'El Publisher aun exige una bandera oculta para reflejar eliminaciones de la fuente viva.'
    }

    $ErrorActionPreference='Continue'
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -Version $PublishedVersion -MinecraftRoot $testRoot 2>&1|Out-String
    $publisherExitCode=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($publisherExitCode-eq0-or$output-notmatch'Version invalida:'){
        throw "El Publisher no rechazo reutilizar la version publica. Salida: $output"
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $blockedJar=Join-Path $mods 'forbidden-tsa.jar'
    $archive=[IO.Compression.ZipFile]::Open($blockedJar,[IO.Compression.ZipArchiveMode]::Create)
    try{
        $entry=$archive.CreateEntry('fabric.mod.json')
        $writer=[IO.StreamWriter]::new($entry.Open(),[Text.Encoding]::UTF8)
        try{$writer.Write('{"schemaVersion":1,"id":"tsa-decorations","version":"9.9.9","name":"Forbidden TSA"}')}finally{$writer.Dispose()}
    }finally{$archive.Dispose()}

    $ErrorActionPreference='Continue'
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -Version $PublishedVersion -MinecraftRoot $testRoot 2>&1|Out-String
    $publisherExitCode=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($publisherExitCode-eq0-or$output-notmatch'Fabric ID prohibido tsa-decorations'){
        throw "El Publisher no rechazo tsa-decorations en la fuente viva. Salida: $output"
    }

    'PASS: la carpeta mods es autoritativa; version monotona y IDs bloqueados siguen protegidos.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
