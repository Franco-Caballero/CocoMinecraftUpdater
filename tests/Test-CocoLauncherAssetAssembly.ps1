[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$testRoot=Join-Path $env:TEMP "coco-launcher-assets-$([guid]::NewGuid())"
try{
    $experiences=Join-Path $testRoot 'experiences'
    $cache=Join-Path $testRoot 'cache'
    New-Item -ItemType Directory -Path $experiences,$cache -Force|Out-Null

    $makeAsset={
        param([string]$Name,[string]$Path,[byte[]]$Bytes,[string]$Role='all')
        $source=Join-Path $testRoot $Name
        [IO.File]::WriteAllBytes($source,$Bytes)
        $asset=[pscustomobject]@{
            projectId=1;fileId=2;name=$Name;path=$Path;role=$Role
            sourceUrl='https://cdn.modrinth.com/data/test/version/file.jar'
            size=(Get-Item -LiteralPath $source).Length
            sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            policy='replace'
        }
        $cached=Get-CocoLockedAssetCachePath $cache $asset
        New-Item -ItemType Directory -Path (Split-Path $cached -Parent) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $cached
        $asset
    }

    $csl=&$makeAsset 'CustomSkinLoader_Test.jar' 'mods/CustomSkinLoader_Test.jar' ([byte[]](0x50,0x4b,0x03,0x04,1,2,3,4))
    $csl|Add-Member -NotePropertyName minecraftVersions -NotePropertyValue @('1.20.1') -Force
    $csl.sourceUrl='https://example.invalid/CustomSkinLoader_Test.jar'
    $csmain=&$makeAsset 'csmain-1.0.0-beta.1.jar' 'mods/csmain-1.0.0-beta.1.jar' ([byte[]](0x50,0x4b,0x03,0x04,5,6,7,8))
    $gunpack=&$makeAsset 'valorant-gunpack.zip' 'tacz/Valorant_gunpack.zip' ([byte[]](0x50,0x4b,0x03,0x04,9,10,11,12))
    $hostOnly=&$makeAsset 'mcwifipnp.jar' 'mods/mcwifipnp.jar' ([byte[]](0x50,0x4b,0x03,0x04,13,14,15,16)) 'host'
    $globalPolicies=[pscustomobject]@{
        customSkinLoader=[pscustomobject]@{mode='required';variants=@($csl)}
        essential=[pscustomobject]@{mode='exclude'}
    }
    $experience=[pscustomobject]@{
        id='asset-test';instanceId='asset-test';managementMode='managed'
        runtime=[pscustomobject]@{minecraftVersion='1.20.1';loader='forge';loaderVersion='47.4.10'}
        pack=[pscustomobject]@{version='assets-only-1.0'}
        files=@()
    }
    $lock=[pscustomobject]@{
        schemaVersion=1
        source=[pscustomobject]@{provider='curseforge';redistribution='origin-only'}
        runtime=$experience.runtime
        pack=[pscustomobject]@{mode='assets-only'}
        assets=@($csmain,$gunpack,$hostOnly)
    }
    $instance=Join-Path $experiences 'asset-test'
    New-Item -ItemType Directory -Path (Join-Path $instance 'saves\world') -Force|Out-Null
    'world-must-survive'|Set-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Encoding UTF8

    [void](Install-CocoManagedExperience $experience $lock $experiences $cache client $globalPolicies)
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'mods\csmain-1.0.0-beta.1.jar'))){throw 'El modo assets-only no instalo CSmain.'}
    if(-not(Test-Path -LiteralPath (Join-Path $instance 'tacz\Valorant_gunpack.zip'))){throw 'El modo assets-only no instalo assets bajo tacz/.'}
    if(Test-Path -LiteralPath (Join-Path $instance 'mods\mcwifipnp.jar')){throw 'El rol host se instalo en un cliente.'}
    if((Get-Content -LiteralPath (Join-Path $instance 'saves\world\level.dat') -Raw).Trim()-ne'world-must-survive'){throw 'El modo assets-only altero el mundo.'}

    'PASS: instalacion assets-only de CSmain, subcarpeta tacz/, roles y preservacion de mundos validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
