[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][int64]$ProjectId,
    [Parameter(Mandatory=$true)][int64]$FileId,
    [Parameter(Mandatory=$true)][string]$SourcePage,
    [Parameter(Mandatory=$true)][string]$SourceLicense,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$CacheRoot=(Join-Path $env:TEMP 'coco-curseforge-import-cache')
)

$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
if($ProjectId-le0-or$FileId-le0){throw 'ProjectId y FileId deben ser positivos.'}
if($SourcePage-notmatch'^https://www\.curseforge\.com/minecraft/'){throw 'La pagina fuente no pertenece a CurseForge Minecraft.'}

function Test-SafeRelativePath([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)-or$Path.Contains(':')){return $false}
    $normalized=$Path-replace'\\','/'
    if($normalized.StartsWith('/')-or$normalized.EndsWith('/')){return $false}
    foreach($part in $normalized.Split('/')){if([string]::IsNullOrWhiteSpace($part)-or$part-in@('.','..')){return $false}}
    return $true
}

function Get-CurseForgeDownloadEndpoint([int64]$ModProjectId,[int64]$ModFileId){
    "https://www.curseforge.com/api/v1/mods/$ModProjectId/files/$ModFileId/download"
}

function Resolve-CurseForgeDownload([int64]$ModProjectId,[int64]$ModFileId){
    $endpoint=Get-CurseForgeDownloadEndpoint $ModProjectId $ModFileId
    $location=$null
    try{
        $response=Invoke-WebRequest -UseBasicParsing -Uri $endpoint -Method Head -MaximumRedirection 0 -ErrorAction Stop
        $location=[string]$response.Headers.Location
    }catch{
        if($_.Exception.Response){$location=[string]$_.Exception.Response.Headers['Location']}
        if([string]::IsNullOrWhiteSpace($location)){throw "CurseForge no resolvio $ModProjectId/$ModFileId`: $($_.Exception.Message)"}
    }
    $uri=[Uri]$location
    if($uri.Scheme-ne'https'-or$uri.Host-notmatch'(^|\.)forgecdn\.net$'){throw "CurseForge redirigio $ModProjectId/$ModFileId a un host no permitido: $($uri.Host)"}
    $name=[Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
    if([string]::IsNullOrWhiteSpace($name)-or$name-ne[IO.Path]::GetFileName($name)-or$name-notmatch'(?i)\.(jar|zip)$'){throw "Nombre de asset CurseForge no permitido: '$name'."}
    [pscustomobject]@{Endpoint=$endpoint;ResolvedUrl=$location;Name=$name}
}

function Get-OfficialAsset([int64]$ModProjectId,[int64]$ModFileId,[string]$Role='all',[string]$DestinationFolder='mods',[string]$ProjectPage=''){
    $resolved=Resolve-CurseForgeDownload $ModProjectId $ModFileId
    $directory=Join-Path $CacheRoot "$ModProjectId\$ModFileId"
    New-Item -ItemType Directory -Path $directory -Force|Out-Null
    $destination=Join-Path $directory $resolved.Name
    if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){
        $temporary=Join-Path $directory ("download-$PID-$([guid]::NewGuid().ToString('N')).tmp")
        try{Invoke-WebRequest -UseBasicParsing -Uri $resolved.Endpoint -OutFile $temporary;Move-Item -LiteralPath $temporary -Destination $destination -Force}
        finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    }
    $bytes=[IO.File]::ReadAllBytes($destination)
    if($bytes.Length-lt4-or$bytes[0]-ne0x50-or$bytes[1]-ne0x4b){throw "El asset $ModProjectId/$ModFileId no es ZIP/JAR."}
    [ordered]@{
        projectId=$ModProjectId;fileId=$ModFileId;name=$resolved.Name;path="$DestinationFolder/$($resolved.Name)";role=$Role;projectPage=$ProjectPage
        sourceUrl=$resolved.Endpoint;size=[int64]$bytes.Length
        sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

New-Item -ItemType Directory -Path $CacheRoot -Force|Out-Null
$pack=Get-OfficialAsset $ProjectId $FileId 'source-pack'
$packPath=Join-Path (Join-Path $CacheRoot "$ProjectId\$FileId") $pack.name
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($packPath)
try{
    foreach($entry in $archive.Entries){
        $candidate=([string]$entry.FullName).TrimEnd('/')
        if($candidate-and-not(Test-SafeRelativePath $candidate)){throw "El pack contiene una ruta insegura: '$($entry.FullName)'."}
    }
    $manifestEntry=$archive.GetEntry('manifest.json')
    if(-not$manifestEntry){throw 'El pack CurseForge no contiene manifest.json.'}
    $reader=[IO.StreamReader]::new($manifestEntry.Open())
    try{$manifestText=$reader.ReadToEnd()}finally{$reader.Dispose()}
    $manifest=$manifestText|ConvertFrom-Json
    if($manifest.manifestType-ne'minecraftModpack'-or[int]$manifest.manifestVersion-ne1){throw 'Formato de manifiesto CurseForge no soportado.'}
    if([string]$manifest.minecraft.version-notmatch'^[0-9A-Za-z._-]+$'){throw 'Version Minecraft invalida en el pack.'}
    $primary=@($manifest.minecraft.modLoaders|Where-Object primary|Select-Object -First 1)[0]
    if(-not$primary-or[string]$primary.id-notmatch'^(forge|fabric|neoforge)-(.+)$'){throw 'Loader primario del pack no soportado.'}
    $loader=$Matches[1];$loaderVersion=$Matches[2]
    $overrides=[string]$manifest.overrides
    if(-not(Test-SafeRelativePath $overrides)){throw 'La raiz overrides del pack no es segura.'}
    $modlistEntry=$archive.GetEntry('modlist.html')
    if(-not$modlistEntry){throw 'El pack CurseForge no contiene modlist.html para clasificar sus assets.'}
    $reader=[IO.StreamReader]::new($modlistEntry.Open())
    try{$modlistText=$reader.ReadToEnd()}finally{$reader.Dispose()}
    $projectLinks=@([regex]::Matches($modlistText,'(?i)<a\s+href="(https://www\.curseforge\.com/minecraft/(?:mc-mods|texture-packs|shaders)/[^"]+)"')|ForEach-Object{$_.Groups[1].Value})
    if($projectLinks.Count-ne@($manifest.files).Count){throw "modlist.html contiene $($projectLinks.Count) links para $(@($manifest.files).Count) assets."}
}finally{$archive.Dispose()}

$assets=[Collections.Generic.List[object]]::new()
$names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$index=0
foreach($entry in @($manifest.files)){
    $index++
    if([int64]$entry.projectID-le0-or[int64]$entry.fileID-le0){throw "Dependencia CurseForge no soportada en la posicion $index."}
    Write-Progress -Activity "Importando $($manifest.name)" -Status "$index / $(@($manifest.files).Count)" -PercentComplete ([int](100*$index/@($manifest.files).Count))
    $projectPage=[string]$projectLinks[$index-1]
    $destinationFolder=if($projectPage-match'/minecraft/texture-packs/'){'resourcepacks'}elseif($projectPage-match'/minecraft/shaders/'){'shaderpacks'}else{'mods'}
    $asset=Get-OfficialAsset ([int64]$entry.projectID) ([int64]$entry.fileID) all $destinationFolder $projectPage
    $asset.manifestRequired=[bool]$entry.required
    if(-not$names.Add([string]$asset.name)){throw "Dos proyectos del pack producen el mismo nombre: '$($asset.name)'."}
    $assets.Add([pscustomobject]$asset)
}
Write-Progress -Activity "Importando $($manifest.name)" -Completed

$lock=[ordered]@{
    schemaVersion=1
    generatedAtUtc=[DateTime]::UtcNow.ToString('o')
    source=[ordered]@{provider='curseforge';projectId=$ProjectId;fileId=$FileId;page=$SourcePage;license=$SourceLicense;redistribution='origin-only'}
    pack=[ordered]@{name=[string]$manifest.name;version=[string]$manifest.version;archive=$pack;overridesRoot=$overrides}
    runtime=[ordered]@{minecraftVersion=[string]$manifest.minecraft.version;loader=$loader;loaderVersion=$loaderVersion}
    assets=@($assets)
}
$outputParent=Split-Path $OutputPath -Parent
New-Item -ItemType Directory -Path $outputParent -Force|Out-Null
[IO.File]::WriteAllText($OutputPath,($lock|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{OutputPath=$OutputPath;Pack=$lock.pack.name;Version=$lock.pack.version;Minecraft=$lock.runtime.minecraftVersion;Loader="$loader $loaderVersion";Assets=$assets.Count;TotalBytes=[int64](($assets|Measure-Object size -Sum).Sum)}
