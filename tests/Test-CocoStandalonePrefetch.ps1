[CmdletBinding()]
param([string]$EnginePath='')

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$engineFile=if([string]::IsNullOrWhiteSpace($EnginePath)){Join-Path $root 'engine\CocoLauncher.ps1'}else{[IO.Path]::GetFullPath($EnginePath)}
. $engineFile
function Test-CocoManagedGameRunning([string]$InstanceRoot,[string]$ExecutableName=''){return $false}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-standalone-prefetch-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $sourceRoot=Join-Path $testRoot 'sources';New-Item -ItemType Directory -Path $sourceRoot -Force|Out-Null
    $archives=[Collections.Generic.List[object]]::new()
    for($i=1;$i-le5;$i++){
        $partRoot=Join-Path $testRoot "part-$i";New-Item -ItemType Directory -Path $partRoot -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $partRoot 'shared.txt'),"part-$i",(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $partRoot "sentinel-$i.txt"),"sentinel-$i",(New-Object Text.UTF8Encoding($false)))
        if($i-eq1){[IO.File]::WriteAllText((Join-Path $partRoot 'game.exe'),'fake-game',(New-Object Text.UTF8Encoding($false)))}
        $zip=Join-Path $sourceRoot "part-$i.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($partRoot,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
        $sha=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        [void]$archives.Add([pscustomobject]@{archiveUrl="https://parallel.invalid/part-$i.zip";sha256=$sha;size=[int64](Get-Item -LiteralPath $zip).Length})
    }

    $script:fakeActive=0
    $script:fakeMaxActive=0
    $script:fakeStarts=[Collections.Generic.List[string]]::new()
    $script:fakeSourceRoot=$sourceRoot
    function curl.exe { throw 'curl.exe no debe invocarse directamente durante esta prueba.' }
    function Start-Process {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][string]$FilePath,
            [object[]]$ArgumentList,
            [switch]$PassThru,
            [switch]$NoNewWindow,
            [object]$WindowStyle,
            [switch]$Wait
        )
        if($FilePath-ne'curl.exe'){
            return Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
        }
        $outIndex=[Array]::IndexOf([object[]]$ArgumentList,[object]'-o')
        if($outIndex-lt0-or$outIndex+1-ge$ArgumentList.Count){throw 'curl simulado no recibio -o.'}
        if([Array]::IndexOf([object[]]$ArgumentList,[object]'--continue-at')-lt0-or[Array]::IndexOf([object[]]$ArgumentList,[object]'-')-lt0){
            throw 'El prefetch standalone perdio la reanudacion --continue-at -.'
        }
        $partial=[string]$ArgumentList[$outIndex+1]
        $url=[string]$ArgumentList[$ArgumentList.Count-1]
        $name=[IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
        $source=Join-Path $script:fakeSourceRoot $name
        if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Fuente simulada ausente: $source"}
        $script:fakeActive++
        if($script:fakeActive-gt3){throw "Se iniciaron mas de 3 descargas simultaneas: $script:fakeActive"}
        $script:fakeMaxActive=[Math]::Max($script:fakeMaxActive,$script:fakeActive)
        [void]$script:fakeStarts.Add($name)
        $process=[pscustomobject]@{ExitCode=0;Done=$false;Source=$source;Partial=$partial}
        $process|Add-Member -MemberType ScriptProperty -Name HasExited -Value {
            if(-not$this.Done){
                $parent=Split-Path $this.Partial -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
                Copy-Item -LiteralPath $this.Source -Destination $this.Partial -Force
                $this.Done=$true
                $script:fakeActive--
            }
            return $true
        }
        $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $process
    }

    $totalSize=[int64](@($archives|Measure-Object -Property size -Sum).Sum)
    $experience=[pscustomobject]@{
        id='standalone-prefetch-test';instanceId='standalone-prefetch-test';name='Prefetch Test';managementMode='managed'
        runtime=[pscustomobject]@{type='standalone';executable='game.exe'}
        launch=[pscustomobject]@{workflow='coco-standalone';minimumFreeBytes=0;autoJoin=$false}
        pack=[pscustomobject]@{version='1.0.0';sha256=[string]$archives[0].sha256;size=$totalSize;archives=@($archives)}
        files=@()
    }
    $experiencesRoot=Join-Path $testRoot 'experiences';$cacheRoot=Join-Path $testRoot 'cache'
    New-Item -ItemType Directory -Path $experiencesRoot,$cacheRoot -Force|Out-Null

    $result=Install-CocoStandaloneExperience $experience $experiencesRoot $cacheRoot
    if(-not$result.Updated){throw 'La instalacion multipart simulada no informo actualizacion.'}
    if($script:fakeMaxActive-ne3){throw "El prefetch no alcanzo exactamente 3 descargas simultaneas (max=$script:fakeMaxActive)."}
    if($script:fakeStarts.Count-ne5){throw "El prefetch no inicio las 5 partes remotas (starts=$($script:fakeStarts.Count))."}
    $instance=Join-Path $experiencesRoot 'standalone-prefetch-test'
    if((Get-Content -LiteralPath (Join-Path $instance 'shared.txt') -Raw)-ne'part-5'){
        throw 'La extraccion multipart no respeto el orden declarado de las partes.'
    }
    for($i=0;$i-lt$archives.Count;$i++){
        $item=$archives[$i]
        $cacheZip=Join-Path $cacheRoot "downloads\standalone-packs\$($item.sha256).zip"
        if(-not(Test-Path -LiteralPath $cacheZip -PathType Leaf)){throw "Falta la parte $($i+1) verificada en cache."}
        if((Get-FileHash -LiteralPath $cacheZip -Algorithm SHA256).Hash.ToLowerInvariant()-ne[string]$item.sha256){throw "Hash de cache incorrecto en parte $($i+1)."}
        if(-not(Test-Path -LiteralPath (Join-Path $instance "sentinel-$($i+1).txt") -PathType Leaf)){throw "No se extrajo la parte $($i+1)."}
    }
    if(-not(Test-Path -LiteralPath (Join-Path $instance '.coco\standalone-state.json') -PathType Leaf)){throw 'La instalacion multipart no escribio su estado final.'}

    'PASS: prefetch standalone acotado a 3 descargas, cache verificada y extraccion ordenada validados.'
}finally{
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item Function:\curl.exe -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
