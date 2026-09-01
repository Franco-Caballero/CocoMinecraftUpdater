[CmdletBinding()]
param(
    [string]$SourceUrl='https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/heart-signal-s05e01-parts-20260901/Heart.Signal.-.S05E01.-.Parte.1.mp4',
    [int64]$ExpectedSize=1837932680
)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine\CocoLauncher.ps1')

$proxy=$null
try{
    $proxy=Start-CocoMediaHttpProxy $SourceUrl 'Heart.Signal.S05E01.Parte1.mp4'
    $head=[Net.HttpWebRequest]::Create($proxy.Url);$head.Method='HEAD';$head.Timeout=30000
    $headResponse=$head.GetResponse()
    try{
        if([int]$headResponse.StatusCode-ne200){throw "HEAD devolvio HTTP $([int]$headResponse.StatusCode)."}
        if([int64]$headResponse.ContentLength-ne$ExpectedSize){throw "HEAD informo $($headResponse.ContentLength) bytes; se esperaban $ExpectedSize."}
        if([string]$headResponse.ContentType-ne'video/mp4'){throw "HEAD informo MIME inesperado: $($headResponse.ContentType)."}
    }finally{$headResponse.Dispose()}

    $range=[Net.HttpWebRequest]::Create($proxy.Url);$range.Method='GET';$range.AddRange(0,1023);$range.Timeout=30000
    $rangeResponse=$range.GetResponse()
    try{
        $bytes=New-Object byte[] 1024;$read=$rangeResponse.GetResponseStream().Read($bytes,0,$bytes.Length)
        if([int]$rangeResponse.StatusCode-ne206){throw "GET con Range devolvio HTTP $([int]$rangeResponse.StatusCode)."}
        if([int64]$rangeResponse.ContentLength-ne1024){throw "El rango devolvio $($rangeResponse.ContentLength) bytes."}
        if([string]$rangeResponse.Headers['Content-Range']-ne"bytes 0-1023/$ExpectedSize"){throw "Content-Range inesperado: $($rangeResponse.Headers['Content-Range'])."}
        if($read-ne1024-or([BitConverter]::ToString($bytes[4..7]))-ne'66-74-79-70'){throw 'El proxy no reenvio el encabezado ftyp esperado.'}
    }finally{$rangeResponse.Dispose()}

    [pscustomobject]@{ProxyUrl=$proxy.Url;HeadStatus=200;RangeStatus=206;RangeBytes=1024;ExpectedSize=$ExpectedSize}|ConvertTo-Json -Compress
    'PASS: el proxy local reenvia HEAD y rangos de GitHub sin crear una copia del asset.'
}finally{
    if($proxy){Stop-CocoMediaHttpProxy $proxy}
}
