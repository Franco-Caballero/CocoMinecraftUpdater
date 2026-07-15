[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engineSource=Join-Path $root 'engine\CocoUpdater.ps1'
$networkSource=Join-Path $root 'engine\CocoNetwork.ps1'
$temp=Join-Path $env:TEMP ('coco-policy-test-'+[guid]::NewGuid().ToString('N'))
$engineRoot=Join-Path $temp 'engine'
$gameRoot=Join-Path $temp 'game'

try{
    New-Item -ItemType Directory -Path $engineRoot,(Join-Path $gameRoot 'mods'),(Join-Path $gameRoot 'versions\fabric-loader-0.19.3-26.1.2') -Force|Out-Null
    Copy-Item -LiteralPath $engineSource -Destination (Join-Path $engineRoot 'CocoUpdater.ps1')
    Copy-Item -LiteralPath $networkSource -Destination (Join-Path $engineRoot 'CocoNetwork.ps1')
    Set-Content -LiteralPath (Join-Path $gameRoot 'mods\fabric-api-test.jar') -Value 'test'

    $manifest=[ordered]@{
        schemaVersion=2
        packId='coco-policy-test'
        version='0.0.0'
        detector=[ordered]@{
            versionId='fabric-loader-0.19.3-26.1.2'
            requiredMods=@('fabric-api')
            tokens=@()
        }
        packages=@(
            [ordered]@{role='client';mods=@([ordered]@{name='fabric-api-test.jar';sha256=('0'*64);size=4;url='https://invalid.example/test.jar'})}
        )
    }
    $manifestPath=Join-Path $temp 'manifest.json'
    $manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $quotedEngineRoot=$engineRoot.Replace("'","''")
    $quotedManifestPath=$manifestPath.Replace("'","''")
    $quotedGameRoot=$gameRoot.Replace("'","''")
    $command=@"
`$ErrorActionPreference='Stop'
`$env:COCO_ENGINE_ROOT='$quotedEngineRoot'
`$source=[IO.File]::ReadAllText((Join-Path '$quotedEngineRoot' 'CocoUpdater.ps1'),[Text.Encoding]::UTF8)
`$block=[ScriptBlock]::Create(`$source)
& `$block -ManifestPath '$quotedManifestPath' -GameDir '$quotedGameRoot' -Silent -DetectOnly
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Restricted','-EncodedCommand',$encoded) -PassThru -Wait -WindowStyle Hidden
    if($process.ExitCode-ne0){throw "El engine fallo bajo ExecutionPolicy Restricted (codigo $($process.ExitCode))."}

    $engineText=[IO.File]::ReadAllText($engineSource)
    if($engineText-match'(?m)^\s*\.\s+\$networkLibrary\s*$'){
        throw 'CocoNetwork.ps1 vuelve a cargarse como archivo y puede ser bloqueado por ExecutionPolicy.'
    }
    if($engineText-notmatch'\[ScriptBlock\]::Create\(\$networkSource\)'){
        throw 'El engine no carga CocoNetwork.ps1 desde memoria.'
    }
    'PASS: engine y biblioteca de red funcionan con ExecutionPolicy Restricted.'
}finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
