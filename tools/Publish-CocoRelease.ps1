[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$MinecraftRoot="$env:APPDATA\.minecraft",
    [string]$Repository='Franco-Caballero/CocoMinecraftUpdater',
    [string]$KnownE4mcDomainsCsv='',
    [int64]$PublisherPid=0,
    [switch]$AllowModRemoval
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$root=Split-Path $PSScriptRoot -Parent
Set-Location $root
[Environment]::CurrentDirectory=$root
$releaseDir=Join-Path $root 'release'
$distDir=Join-Path $root 'dist'
$KnownE4mcDomains=@($KnownE4mcDomainsCsv-split','|Where-Object{$_})
Write-Output "Contexto: Repository=$Repository MinecraftRoot=$MinecraftRoot Domains=$($KnownE4mcDomains.Count)"

function Get-PublishedFabricModId($Mod,[string]$JarDirectory){
    if($Mod.fabricId){return [string]$Mod.fabricId}
    $jar=Join-Path $JarDirectory "mod-$($Mod.sha256).jar"
    if(-not(Test-Path -LiteralPath $jar)){return $null}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($jar)
    try{
        $entry=$archive.GetEntry('fabric.mod.json');if(-not$entry){return $null}
        $reader=[IO.StreamReader]::new($entry.Open(),[Text.Encoding]::UTF8)
        try{return [string](($reader.ReadToEnd()|ConvertFrom-Json).id)}finally{$reader.Dispose()}
    }finally{$archive.Dispose()}
}

$previousHostModIds=@()
$previousManifestPath=Join-Path $releaseDir 'latest.json'
if(Test-Path -LiteralPath $previousManifestPath){
    $previousManifest=Get-Content -LiteralPath $previousManifestPath -Raw|ConvertFrom-Json
    $previousHostPackage=@($previousManifest.packages|Where-Object role -eq host|Select-Object -First 1)
    $previousHostModIds=@($previousHostPackage.mods|ForEach-Object{Get-PublishedFabricModId $_ (Join-Path $releaseDir 'jars')}|Where-Object{$_-and$_-ne'coco_session_bridge'}|Select-Object -Unique)
}

function Replace-Text([string]$Path,[string]$Pattern,[string]$Replacement){
    $full=Join-Path $root $Path;$text=[IO.File]::ReadAllText($full)
    if(-not[regex]::IsMatch($text,$Pattern)){throw "No se encontro el campo de version en $Path"}
    $updated=[regex]::Replace($text,$Pattern,$Replacement)
    [IO.File]::WriteAllText($full,$updated,(New-Object Text.UTF8Encoding($false)))
}

Replace-Text 'fabric-mod\gradle.properties' '(?m)^mod_version=.*$' "mod_version=$Version"
Replace-Text 'fabric-mod\src\main\java\cl\coco\minecraft\CocoProtocol.java' 'PACK_VERSION = "[^"]+"' "PACK_VERSION = `"$Version`""
Replace-Text '.github\workflows\build-bootstrapper.yml' "-Version '\d+\.\d+\.\d+\.0'" "-Version '$Version.0'"

$javaCandidates=[Collections.Generic.List[string]]::new()
$javaCandidates.Add((Join-Path $MinecraftRoot 'runtime\java-runtime-epsilon\windows\java-runtime-epsilon\bin\java.exe'))
Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction SilentlyContinue|ForEach-Object{if($_.ExecutablePath){$javaCandidates.Add($_.ExecutablePath)}}
$pathJava=Get-Command java.exe -ErrorAction SilentlyContinue;if($pathJava){$javaCandidates.Add($pathJava.Source)}
$javaExe=$null
foreach($candidate in @($javaCandidates|Select-Object -Unique)){
    if(-not(Test-Path $candidate)){continue}
    $javaInfo=New-Object Diagnostics.ProcessStartInfo
    $javaInfo.FileName=$candidate;$javaInfo.Arguments='-version';$javaInfo.UseShellExecute=$false
    $javaInfo.CreateNoWindow=$true;$javaInfo.RedirectStandardError=$true;$javaInfo.RedirectStandardOutput=$true
    $javaProcess=New-Object Diagnostics.Process;$javaProcess.StartInfo=$javaInfo
    [void]$javaProcess.Start();$versionLine=$javaProcess.StandardError.ReadToEnd()+$javaProcess.StandardOutput.ReadToEnd();$javaProcess.WaitForExit();$javaProcess.Dispose()
    if($versionLine-match'"25(?:\.|\")'){$javaExe=$candidate;break}
}
if(-not$javaExe){throw "No se encontro Java 25. MinecraftRoot recibido: $MinecraftRoot"}
$javaHome=Split-Path (Split-Path $javaExe -Parent) -Parent
$env:JAVA_HOME=$javaHome
& .\fabric-mod\gradlew.bat -p fabric-mod clean build
if($LASTEXITCODE){throw 'Fallo la compilacion del Bridge/Gate.'}

.\tools\New-CocoEngine.ps1 -Version $Version -OutputDirectory $releaseDir|Out-Null
$bridge=Join-Path $root "fabric-mod\build\libs\coco-session-bridge-$Version.jar"

if(-not(Get-Module -ListAvailable ps2exe)){Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber}
Import-Module ps2exe
New-Item -ItemType Directory $distDir -Force|Out-Null
$bootstrapTemplate=[IO.File]::ReadAllText((Join-Path $root 'bootstrap\CocoBootstrapper.ps1'))
$fullbodyBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'fullbody.png')))
$generatedBootstrap=Join-Path $env:TEMP 'CocoBootstrapper.generated.ps1'
[IO.File]::WriteAllText($generatedBootstrap,$bootstrapTemplate.Replace('__FULLBODY_BASE64__',$fullbodyBase64),(New-Object Text.UTF8Encoding($true)))
$bootstrapExe=Join-Path $distDir 'CocoUpdater.exe'
Invoke-ps2exe -InputFile $generatedBootstrap -OutputFile $bootstrapExe -Title 'Coco Minecraft Updater' -Product 'Coco Minecraft Updater' -Version "$Version.0" -NoConsole -IconFile (Join-Path $root 'reynaico.ico')
Remove-Item $generatedBootstrap -Force
$publisherNext=Join-Path $root 'dist\CocoPublisher.next.exe'
Remove-Item $publisherNext -Force -ErrorAction SilentlyContinue
Invoke-ps2exe -InputFile publisher\CocoPublisher.ps1 -OutputFile $publisherNext -Title 'Publicar Coco Pack' -Product 'Coco Publisher' -Version "$Version.0" -NoConsole -IconFile reynaico.ico
# ps2exe changes the process-wide .NET working directory to the output folder.
# Restore both notions of the current directory before any relative tool call.
Set-Location $root
[Environment]::CurrentDirectory=$root
if($PublisherPid-gt0){
    $publisherHelper=Join-Path $env:TEMP 'Apply-CocoPublisherUpdate.ps1'
    $publisherHelperText=@'
param([int64]$WaitPid,[string]$Source,[string]$Destination)
Wait-Process -Id $WaitPid -ErrorAction SilentlyContinue
for($i=0;$i-lt40;$i++){try{Move-Item -LiteralPath $Source -Destination $Destination -Force;exit 0}catch{Start-Sleep -Milliseconds 250}}
exit 1
'@
    [IO.File]::WriteAllText($publisherHelper,$publisherHelperText,(New-Object Text.UTF8Encoding($true)))
    $quotedPublisherHelper='"'+($publisherHelper-replace'"','\"')+'"'
    $quotedPublisherNext='"'+($publisherNext-replace'"','\"')+'"'
    $quotedPublisherDestination='"'+((Join-Path $root 'dist\CocoPublisher.exe')-replace'"','\"')+'"'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedPublisherHelper,'-WaitPid',$PublisherPid,'-Source',$quotedPublisherNext,'-Destination',$quotedPublisherDestination)
}else{
    Move-Item $publisherNext (Join-Path $root 'dist\CocoPublisher.exe') -Force
}
.\tools\New-CocoJarRelease.ps1 -MinecraftRoot $MinecraftRoot -Version $Version -GitHubRepository $Repository -ReleaseDirectory $releaseDir -BridgeJar $bridge -BootstrapExe $bootstrapExe -KnownE4mcDomains $KnownE4mcDomains|Write-Host
$candidateManifest=Get-Content (Join-Path $releaseDir 'latest.json') -Raw|ConvertFrom-Json
$candidateHostPackage=@($candidateManifest.packages|Where-Object role -eq host|Select-Object -First 1)
$candidateHostModIds=@($candidateHostPackage.mods.fabricId|Where-Object{$_-and$_-ne'coco_session_bridge'}|Select-Object -Unique)
$removedModIds=@($previousHostModIds|Where-Object{$_-notin$candidateHostModIds})
if($removedModIds.Count-and-not$AllowModRemoval){
    throw "Publicacion bloqueada: desaparecerian mods ya publicados ($($removedModIds -join ', ')). Requiere -AllowModRemoval y confirmacion explicita del usuario."
}
.\tests\Test-CocoRelease.ps1 -Version $Version
.\tests\Test-CocoBridge.ps1
.\tests\Test-CocoEngineRecovery.ps1
.\tests\Test-CocoZeroTier.ps1
.\tests\Test-CocoNetworkEngine.ps1 -MinecraftRoot $MinecraftRoot

git add .
git commit -m "Publish Coco Pack $Version"
if($LASTEXITCODE -and $LASTEXITCODE -ne 1){throw 'Fallo git commit.'}
git push
if($LASTEXITCODE){throw 'Fallo git push.'}

$credentialLines=@('protocol=https','host=github.com','')|git credential fill
$credential=@{};foreach($line in $credentialLines){if($line-match'^([^=]+)=(.*)$'){$credential[$matches[1]]=$matches[2]}}
if(-not$credential.password){throw 'Git Credential Manager no devolvio una credencial de GitHub.'}
$headers=@{Authorization="Bearer $($credential.password)";Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='CocoPublisher'}
function Invoke-WithRetry([scriptblock]$Operation,[string]$Description){
    for($attempt=1;$attempt-le4;$attempt++){
        try{return & $Operation}
        catch{if($attempt-eq4){throw};Write-Progress -Activity "Publicando Coco Pack $Version" -Status "Reintentando $Description ($($attempt+1)/4)";Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))}
    }
}
function Get-ReleaseAssets([int64]$ReleaseId){
    $result=[Collections.Generic.List[object]]::new()
    for($page=1;$page-le20;$page++){
        # Windows PowerShell 5.1 preserves a top-level JSON array as one pipeline
        # object when Invoke-RestMethod is wrapped directly in @(...). Force the
        # response through the pipeline so every release asset is enumerated.
        $response=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$Repository/releases/$ReleaseId/assets?per_page=100&page=$page" -Headers $headers
        $batch=@($response|ForEach-Object{$_})
        foreach($item in $batch){$result.Add($item)}
        if($batch.Count-lt100){break}
    }
    return @($result)
}
function Get-AllReleases {
    $result=[Collections.Generic.List[object]]::new()
    for($page=1;$page-le20;$page++){
        $response=Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page" -Headers $headers
        $batch=@($response|ForEach-Object{$_})
        foreach($item in $batch){$result.Add($item)}
        if($batch.Count-lt100){break}
    }
    return @($result)
}
$allReleases=@(Get-AllReleases)

# Los JARs viven en un release estable por hash. Solo se suben contenidos nuevos.
$assetRelease=@($allReleases|Where-Object tag_name -eq 'mod-assets'|Select-Object -First 1)
if(-not$assetRelease){
    $assetBody=@{tag_name='mod-assets';target_commitish='main';name='Coco Mod Assets';body='Assets inmutables identificados por SHA-256.';draft=$true;prerelease=$true}|ConvertTo-Json
    $assetRelease=Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repository/releases" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $assetBody
}
$jarAssets=@(Get-ChildItem (Join-Path $releaseDir 'jars') -File)
$remoteJarAssets=@(Get-ReleaseAssets $assetRelease.id)
foreach($asset in $jarAssets){
    $uploaded=@($remoteJarAssets|Where-Object name -eq $asset.Name|Select-Object -First 1)
    if($uploaded -and [int64]$uploaded.size -eq [int64]$asset.Length){continue}
    if($uploaded){Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$Repository/releases/assets/$($uploaded.id)" -Headers $headers|Out-Null}
    $upload="https://uploads.github.com/repos/$Repository/releases/$($assetRelease.id)/assets?name=$([Uri]::EscapeDataString($asset.Name))"
    Invoke-WithRetry {Invoke-RestMethod -Method Post -Uri $upload -Headers $headers -ContentType 'application/octet-stream' -InFile $asset.FullName|Out-Null} $asset.Name
}
$remoteJarAssets=@(Get-ReleaseAssets $assetRelease.id)
foreach($asset in $jarAssets){
    $match=@($remoteJarAssets|Where-Object name -eq $asset.Name|Select-Object -First 1)
    if(-not$match -or [int64]$match.size -ne [int64]$asset.Length){throw "No se publico correctamente el asset $($asset.Name)."}
}
if($assetRelease.draft){
    $assetRelease=Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$Repository/releases/$($assetRelease.id)" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body (@{draft=$false;prerelease=$true}|ConvertTo-Json)
}

$body=@{tag_name="v$Version";target_commitish='main';name="Coco Pack $Version";body='Publicacion automatica incremental por JAR.';draft=$true;prerelease=$false}|ConvertTo-Json
$existing=@($allReleases|Where-Object{$_.tag_name-eq"v$Version"}|Select-Object -First 1)
if($existing){
    if(-not$existing.draft){throw "El release v$Version ya esta publicado."}
    $release=$existing
}else{
    $release=Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repository/releases" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
}
$assets=@(Get-Item (Join-Path $releaseDir "coco-engine-$Version.zip"),(Join-Path $releaseDir 'latest.json'),$bootstrapExe)
$index=0
foreach($asset in $assets){
    $index++;Write-Progress -Activity "Publicando Coco Pack $Version" -Status $asset.Name -PercentComplete (100*$index/$assets.Count)
    $uploaded=@($release.assets|Where-Object name -eq $asset.Name|Select-Object -First 1)
    # Estos nombres son versionados, no content-addressed: en un reintento se reemplazan siempre.
    if($uploaded){Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$Repository/releases/assets/$($uploaded.id)" -Headers $headers|Out-Null}
    $upload="https://uploads.github.com/repos/$Repository/releases/$($release.id)/assets?name=$([Uri]::EscapeDataString($asset.Name))"
    Invoke-WithRetry {Invoke-RestMethod -Method Post -Uri $upload -Headers $headers -ContentType 'application/octet-stream' -InFile $asset.FullName|Out-Null} $asset.Name
}
$remoteAssets=@(Get-ReleaseAssets $release.id)
$missing=[Collections.Generic.List[string]]::new()
foreach($asset in $assets){
    $match=@($remoteAssets|Where-Object name -eq $asset.Name|Select-Object -First 1)
    if(-not$match -or [int64]$match.size -ne [int64]$asset.Length){$missing.Add($asset.Name)}
}
if($missing.Count){throw "No se publicaron correctamente: $($missing -join ', ')"}

# Instala exactamente el mismo paquete en el host antes de hacerlo visible a los clientes.
if(-not(Test-Path (Join-Path $MinecraftRoot 'config\coco-host.json'))){throw 'Falta config\coco-host.json en la instalacion host.'}
$localManifest=Get-Content (Join-Path $releaseDir 'latest.json') -Raw|ConvertFrom-Json
$hostPackage=@($localManifest.packages|Where-Object role -eq host|Select-Object -First 1)
$jarCache=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater\downloads\jars'
New-Item -ItemType Directory -Path $jarCache -Force|Out-Null
foreach($mod in $hostPackage.mods){
    $source=Join-Path (Join-Path $releaseDir 'jars') "mod-$($mod.sha256).jar"
    Copy-Item -LiteralPath $source -Destination (Join-Path $jarCache "$($mod.sha256)-$($mod.name)") -Force
}
$engineScript='"'+((Join-Path $root 'engine\CocoUpdater.ps1')-replace'"','\"')+'"'
$manifestArgument='"'+((Join-Path $releaseDir 'latest.json')-replace'"','\"')+'"'
$gameArgument='"'+($MinecraftRoot-replace'"','\"')+'"'
$install=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$engineScript,'-ManifestPath',$manifestArgument,'-GameDir',$gameArgument,'-Silent') -Wait -PassThru
if($install.ExitCode-ne0){throw 'No se pudo actualizar la instalacion host; el release seguira oculto como borrador.'}

$publishBody=@{draft=$false;prerelease=$false}|ConvertTo-Json
$release=Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$Repository/releases/$($release.id)" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $publishBody
Write-Progress -Activity "Publicando Coco Pack $Version" -Completed
Write-Host "Publicado: $($release.html_url)"
# No heredar un LASTEXITCODE antiguo de git/gradle al proceso que hospeda este
# script. El Publisher usa este codigo como fuente de verdad para su pantalla.
exit 0
