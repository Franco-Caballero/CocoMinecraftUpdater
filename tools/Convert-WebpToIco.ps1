[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore
$source=New-Object Windows.Media.Imaging.BitmapImage
$source.BeginInit();$source.UriSource=[Uri](Resolve-Path $InputPath).Path;$source.CacheOption='OnLoad';$source.EndInit()
$sizes=@(16,24,32,48,64,128,256)
$payloads=@()
foreach($size in $sizes){
    $scaleX=([double]$size)/([double]$source.PixelWidth);$scaleY=([double]$size)/([double]$source.PixelHeight)
    $transform=New-Object Windows.Media.ScaleTransform($scaleX,$scaleY)
    $scaled=New-Object Windows.Media.Imaging.TransformedBitmap($source,$transform)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($scaled))
    $memory=New-Object IO.MemoryStream;$encoder.Save($memory);$payloads+=,$memory.ToArray();$memory.Dispose()
}
$stream=[IO.File]::Create($OutputPath);$writer=New-Object IO.BinaryWriter($stream)
try{
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$sizes.Count)
    $offset=6+16*$sizes.Count
    for($i=0;$i-lt$sizes.Count;$i++){
        $dimension=if($sizes[$i]-eq256){0}else{$sizes[$i]}
        $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$payloads[$i].Length);$writer.Write([uint32]$offset)
        $offset+=$payloads[$i].Length
    }
    foreach($payload in $payloads){$writer.Write($payload)}
}finally{$writer.Dispose();$stream.Dispose()}
