Add-Type -AssemblyName System.IO.Compression.FileSystem

$stage = Join-Path $env:TEMP "test-engine-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$raw = . .\tools\New-CocoEngine.ps1 -Version "0.5.69" -OutputDirectory $stage
$info = $raw | ConvertFrom-Json
$zipFile = $info.path
$extractDir = Join-Path $stage "extracted"
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $extractDir)

function Test-CocoEngineExtraction-Flo([string]$Destination){
    $baseComplete=
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoUpdater.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoLauncher.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetwork.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoSessionService.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetworkElevated.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'CocoNetworkAuthorizer.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'launcher\catalog.json')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'assets\fullbody.png')) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'assets\reynaico.ico'))
    Write-Host "Base complete:" $baseComplete
    if(-not$baseComplete){return $false}
    try{
        $catalog=Get-Content -LiteralPath (Join-Path $Destination 'launcher\catalog.json') -Raw|ConvertFrom-Json
        $managed=@($catalog.experiences|Where-Object managementMode -eq 'managed')
        Write-Host "Managed count:" $managed.Count
        if(-not$managed.Count){return $false}
        foreach($experience in $managed){
            $lockPaths=@([string]$experience.pack.lockPath)
            if($experience.worldTemplate){$lockPaths+=([string]$experience.worldTemplate.lockPath)}
            foreach($declaredPath in $lockPaths){
                $relative=$declaredPath-replace'\\','/'
                $match = $relative -match '^launcher/experiences/[a-z0-9][a-z0-9.-]{1,95}\.lock\.json$'
                $exists = Test-Path -LiteralPath (Join-Path $Destination ($relative-replace'/','\')) -PathType Leaf
                Write-Host "Exp: $($experience.id) | Path: '$relative' | Match: $match | Exists: $exists"
                if(-not$match -or -not$exists){ return $false }
            }
        }
        return $true
    }catch{
        Write-Host "Exception in catalog parse:" $_.Exception.Message
        return $false
    }
}

$res = Test-CocoEngineExtraction-Flo $extractDir
Write-Host "RESULT OF FLO TEST:" $res
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
