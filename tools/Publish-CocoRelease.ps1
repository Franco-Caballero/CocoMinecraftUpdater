[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$MinecraftRoot="$env:APPDATA\.minecraft",
    [string]$Repository='Franco-Caballero/CocoMinecraftUpdater',
    [string[]]$KnownE4mcDomains=@()
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location $root

function Replace-Text([string]$Path,[string]$Pattern,[string]$Replacement){
    $full=Join-Path $root $Path;$text=[IO.File]::ReadAllText($full)
    if(-not[regex]::IsMatch($text,$Pattern)){throw "No se encontró el campo de versión en $Path"}
    $updated=[regex]::Replace($text,$Pattern,$Replacement)
    [IO.File]::WriteAllText($full,$updated,(New-Object Text.UTF8Encoding($false)))
}

Replace-Text 'fabric-mod\gradle.properties' '(?m)^mod_version=.*$' "mod_version=$Version"
Replace-Text 'fabric-mod\src\main\java\cl\coco\minecraft\CocoProtocol.java' 'PACK_VERSION = "[^"]+"' "PACK_VERSION = `"$Version`""
Replace-Text '.github\workflows\build-bootstrapper.yml' "-Version '\d+\.\d+\.\d+\.0'" "-Version '$Version.0'"
Replace-Text '.github\workflows\build-bootstrapper.yml' 'coco-session-bridge-\d+\.\d+\.\d+\.jar' "coco-session-bridge-$Version.jar"

$javaHome=Join-Path $MinecraftRoot 'runtime\java-runtime-epsilon\windows\java-runtime-epsilon'
if(-not(Test-Path (Join-Path $javaHome 'bin\java.exe'))){throw 'No se encontró Java 25 dentro de la instalación de Minecraft.'}
$env:JAVA_HOME=$javaHome
& .\fabric-mod\gradlew.bat -p fabric-mod clean build
if($LASTEXITCODE){throw 'Falló la compilación del Bridge/Gate.'}

.\tools\New-CocoEngine.ps1 -Version $Version -OutputDirectory release|Out-Null
$bridge="fabric-mod\build\libs\coco-session-bridge-$Version.jar"
.\tools\New-CocoJarRelease.ps1 -MinecraftRoot $MinecraftRoot -Version $Version -GitHubRepository $Repository -ReleaseDirectory release -BridgeJar $bridge -KnownE4mcDomains $KnownE4mcDomains|Write-Host

if(-not(Get-Module -ListAvailable ps2exe)){Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber}
Import-Module ps2exe
New-Item -ItemType Directory dist -Force|Out-Null
Invoke-ps2exe -InputFile bootstrap\CocoBootstrapper.ps1 -OutputFile dist\CocoUpdater.exe -Title 'Coco Minecraft Updater' -Product 'Coco Minecraft Updater' -Version "$Version.0" -NoConsole -IconFile reynaico.ico

git add .
git commit -m "Publish Coco Pack $Version"
if($LASTEXITCODE -and $LASTEXITCODE -ne 1){throw 'Falló git commit.'}
git push
if($LASTEXITCODE){throw 'Falló git push.'}

$credentialLines=@('protocol=https','host=github.com','')|git credential fill
$credential=@{};foreach($line in $credentialLines){if($line-match'^([^=]+)=(.*)$'){$credential[$matches[1]]=$matches[2]}}
if(-not$credential.password){throw 'Git Credential Manager no devolvió una credencial de GitHub.'}
$headers=@{Authorization="Bearer $($credential.password)";Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='CocoPublisher'}
$body=@{tag_name="v$Version";target_commitish='main';name="Coco Pack $Version";body='Publicación automática incremental por JAR.';draft=$false;prerelease=$false}|ConvertTo-Json
$release=Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repository/releases" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
$assets=@(Get-ChildItem release\jars -File)+@(Get-Item "release\coco-engine-$Version.zip",release\latest.json,dist\CocoUpdater.exe)
$index=0
foreach($asset in $assets){
    $index++;Write-Progress -Activity "Publicando Coco Pack $Version" -Status $asset.Name -PercentComplete (100*$index/$assets.Count)
    $upload="https://uploads.github.com/repos/$Repository/releases/$($release.id)/assets?name=$([Uri]::EscapeDataString($asset.Name))"
    Invoke-RestMethod -Method Post -Uri $upload -Headers $headers -ContentType 'application/octet-stream' -InFile $asset.FullName|Out-Null
}
Write-Progress -Activity "Publicando Coco Pack $Version" -Completed
Write-Host "Publicado: $($release.html_url)"
