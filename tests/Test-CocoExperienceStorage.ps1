<#
.SYNOPSIS
Pruebas automatizadas para Get-CocoExperienceDiskUsage y Remove-CocoInstalledExperience.
#>
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$enginePath=Join-Path $PSScriptRoot '..\engine\CocoLauncher.ps1'
if(-not(Test-Path $enginePath)){throw "No se encontro el engine: $enginePath"}

# Proveer stubs para dependencias del engine que no estan disponibles fuera del runtime completo.
if(-not(Get-Command Write-CocoLog -ErrorAction SilentlyContinue)){
    function global:Write-CocoLog([string]$Text){}
}
if(-not(Get-Command Set-CocoState -ErrorAction SilentlyContinue)){
    function global:Set-CocoState{}
}
if(-not(Get-Command Show-CocoWindow -ErrorAction SilentlyContinue)){
    function global:Show-CocoWindow{}
}
if(-not(Get-Command Test-CocoManagedGameRunning -ErrorAction SilentlyContinue)){
    function global:Test-CocoManagedGameRunning([string]$InstanceRoot){return $false}
}

Add-Type -AssemblyName System.Drawing

. $enginePath

$tmpRoot=Join-Path ([IO.Path]::GetTempPath()) "coco-storage-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmpRoot -Force|Out-Null
$experiencesRoot=Join-Path $tmpRoot 'experiences'
New-Item -ItemType Directory -Path $experiencesRoot -Force|Out-Null

try{
    # --- Test 1: Disk usage of non-existent directory ---
    $usage=Get-CocoExperienceDiskUsage (Join-Path $experiencesRoot 'nonexistent')
    if($usage.Installed){throw 'FAIL: Non-existent directory should not be marked as installed.'}
    if($usage.Bytes-ne0){throw 'FAIL: Non-existent directory should have 0 bytes.'}
    if($usage.Label-ne'No instalado'){throw "FAIL: Expected 'No instalado', got '$($usage.Label)'."}

    # --- Test 2: Disk usage of an installed experience ---
    $testInstance=Join-Path $experiencesRoot 'test-experience'
    New-Item -ItemType Directory -Path $testInstance -Force|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $testInstance 'game.exe'),(New-Object byte[] (2*1024*1024)))
    [IO.File]::WriteAllBytes((Join-Path $testInstance 'data.pak'),(New-Object byte[] (500*1024)))
    $usage=Get-CocoExperienceDiskUsage $testInstance
    if(-not$usage.Installed){throw 'FAIL: Existing directory should be marked as installed.'}
    if($usage.Bytes-lt(2*1024*1024)){throw "FAIL: Expected at least 2 MB, got $($usage.Bytes) bytes."}
    if($usage.Label-notmatch 'MB'){throw "FAIL: Expected MB label, got '$($usage.Label)'."}

    # --- Test 3: Disk usage with GB-sized content ---
    $gbInstance=Join-Path $experiencesRoot 'gb-test'
    New-Item -ItemType Directory -Path $gbInstance -Force|Out-Null
    # Create a sparse-ish 1.1 GB file using a stream
    $fs=[IO.File]::Create((Join-Path $gbInstance 'big.bin'))
    $fs.SetLength([int64](1.1*1GB));$fs.Close()
    $usage=Get-CocoExperienceDiskUsage $gbInstance
    if($usage.Label-notmatch 'GB'){throw "FAIL: Expected GB label for 1.1 GB file, got '$($usage.Label)'."}

    # --- Test 4: Remove non-existent experience returns not-installed ---
    $result=Remove-CocoInstalledExperience (Join-Path $experiencesRoot 'nonexistent') $experiencesRoot
    if($result.Removed){throw 'FAIL: Removing non-existent experience should return Removed=$false.'}
    if($result.Reason-ne'not-installed'){throw "FAIL: Expected reason 'not-installed', got '$($result.Reason)'."}

    # --- Test 5: Remove installed experience deletes directory ---
    $removeTarget=Join-Path $experiencesRoot 'to-delete'
    New-Item -ItemType Directory -Path $removeTarget -Force|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $removeTarget 'mod.jar'),(New-Object byte[] 1024))
    $result=Remove-CocoInstalledExperience $removeTarget $experiencesRoot
    if(-not$result.Removed){throw 'FAIL: Remove should return Removed=$true.'}
    if(Test-Path -LiteralPath $removeTarget){throw 'FAIL: Experience directory should have been deleted.'}

    # --- Test 6: Remove experience outside experiences root throws ---
    $outsidePath=Join-Path $tmpRoot 'outside-experience'
    New-Item -ItemType Directory -Path $outsidePath -Force|Out-Null
    $threw=$false
    try{Remove-CocoInstalledExperience $outsidePath $experiencesRoot}catch{$threw=$true}
    if(-not$threw){throw 'FAIL: Removing experience outside root should throw.'}

    # --- Test 7: Remove running experience throws ---
    $runningTarget=Join-Path $experiencesRoot 'running-game'
    New-Item -ItemType Directory -Path $runningTarget -Force|Out-Null
    function global:Test-CocoManagedGameRunning([string]$InstanceRoot){return $InstanceRoot-eq$runningTarget}
    $threw=$false
    try{Remove-CocoInstalledExperience $runningTarget $experiencesRoot}catch{$threw=$true}
    if(-not$threw){throw 'FAIL: Removing a running experience should throw.'}
    # Restore stub
    function global:Test-CocoManagedGameRunning([string]$InstanceRoot){return $false}

    Write-Host 'PASS: Get-CocoExperienceDiskUsage y Remove-CocoInstalledExperience validados.'
}finally{
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
