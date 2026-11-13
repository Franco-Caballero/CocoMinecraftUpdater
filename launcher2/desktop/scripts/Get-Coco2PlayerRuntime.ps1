[CmdletBinding()]
param([string]$CacheRoot)
$ErrorActionPreference='Stop'
if(-not $CacheRoot){
    $CacheRoot=if(Test-Path -LiteralPath 'D:\' -PathType Container){'D:\CocoWork\tools\vlc-3.0.24'}else{Join-Path $env:LOCALAPPDATA 'CocoLauncher2\build-tools\vlc-3.0.24'}
}
$runtime=Join-Path $CacheRoot 'vlc-3.0.24'
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src-tauri\resources\vlc-runtime-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function Test-Runtime {
    foreach($entry in $manifest.files){
        $file=Join-Path $runtime $entry.path
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){return $false}
        if((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Runtime enlazado; no usar'}
        if((Get-Item -LiteralPath $file).Length -ne $entry.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw "Runtime alterado: $($entry.path)"}
    }
    return $true
}
New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
if(-not(Test-Runtime)){
    $seven=(Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
    if(-not $seven -and (Test-Path -LiteralPath 'C:\Program Files\7-Zip\7z.exe')){$seven='C:\Program Files\7-Zip\7z.exe'}
    if(-not $seven){throw 'Se requiere 7-Zip para preparar el runtime de vídeo'}
    $archive=Join-Path $CacheRoot 'vlc-3.0.24-win64.7z'
    try {
        if(-not(Test-Path -LiteralPath $archive)){
            Invoke-WebRequest -UseBasicParsing -Uri 'https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/vlc-3.0.24-win64.7z' -OutFile $archive
        }
        if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.archiveSha256){throw 'SHA-256 incorrecto del runtime VLC'}
        & $seven x $archive ("-o$CacheRoot") 'vlc-3.0.24\libvlc.dll' 'vlc-3.0.24\libvlccore.dll' 'vlc-3.0.24\plugins\*' 'vlc-3.0.24\COPYING*' -y | Out-Host
        if($LASTEXITCODE -ne 0 -or -not(Test-Runtime)){throw 'No se pudo preparar el motor de vídeo verificado'}
    } finally {
        if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}
    }
}
return (Resolve-Path -LiteralPath $runtime).Path
