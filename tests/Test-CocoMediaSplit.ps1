[CmdletBinding()]
param(
    [string]$Part1Path=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\heart signal\Heart Signal - S05E01 - Parte 1.mp4'),
    [string]$Part2Path=(Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\heart signal\Heart Signal - S05E01 - Parte 2.mp4')
)

$ErrorActionPreference='Stop'
$expected=@(
    [pscustomobject]@{Path=$Part1Path;Size=[int64]1837932680;Sha256='fd9f418b00b06a56159d7e07d90cb953c3c5f94c9f7ceb32b2a899acb88b21a4'},
    [pscustomobject]@{Path=$Part2Path;Size=[int64]1829237387;Sha256='714412a27a5429373e278ed4c1180e229721cc3b4afe212e436aa45496abdc1a'}
)
foreach($part in $expected){
    if(-not(Test-Path -LiteralPath $part.Path -PathType Leaf)){throw "No existe la parte: $($part.Path)"}
    $item=Get-Item -LiteralPath $part.Path -Force
    if([int64]$item.Length-ne$part.Size){throw "Tamano incorrecto en '$($item.Name)': $($item.Length) != $($part.Size)"}
    $hash=(Get-FileHash -LiteralPath $part.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if($hash-ne$part.Sha256){throw "SHA-256 incorrecto en '$($item.Name)': $hash != $($part.Sha256)"}
    $stream=[IO.File]::OpenRead($part.Path);$header=New-Object byte[] 8
    try{$read=$stream.Read($header,0,$header.Length)}finally{$stream.Dispose()}
    if($read-ne8-or([Text.Encoding]::ASCII.GetString($header,4,4))-ne'ftyp'){throw "'$($item.Name)' no tiene un encabezado MP4 valido."}
}
[pscustomobject]@{Parts=$expected.Count;Sizes=@($expected|ForEach-Object{$_.Size});Sha256=@($expected|ForEach-Object{$_.Sha256})}|ConvertTo-Json -Compress
'PASS: las dos partes son MP4 independientes, reproducibles y menores de 2 GiB.'
