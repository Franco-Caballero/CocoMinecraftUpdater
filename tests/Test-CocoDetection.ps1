$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$enginePath=Join-Path $root 'engine\CocoUpdater.ps1'
$engineText=[IO.File]::ReadAllText($enginePath)
$temp=Join-Path $env:TEMP ('coco-detection-'+[guid]::NewGuid())
$originalAppData=$env:APPDATA;$originalLocalAppData=$env:LOCALAPPDATA;$originalUserProfile=$env:USERPROFILE
$javaProcess=$null
try{
    New-Item -ItemType Directory -Path $temp|Out-Null
    $profile=Join-Path $temp 'profile';$appData=Join-Path $profile 'AppData\Roaming';$localAppData=Join-Path $profile 'AppData\Local'
    $oldRoot=Join-Path $profile 'OldMinecraft';$correctRoot=Join-Path $profile 'CocoMinecraft'
    foreach($path in $appData,$localAppData,(Join-Path $profile 'Desktop'),(Join-Path $profile 'Documents'),(Join-Path $profile 'Downloads'),(Join-Path $oldRoot 'mods'),(Join-Path $oldRoot 'versions\fabric-loader-0.16.0-1.21.5'),(Join-Path $oldRoot 'config'),(Join-Path $correctRoot 'mods'),(Join-Path $correctRoot 'versions\fabric-loader-0.19.3-26.1.2')){New-Item -ItemType Directory -Path $path -Force|Out-Null}
    [pscustomobject]@{packId='coco-test';version='0.0.1';role='client'}|ConvertTo-Json|Set-Content (Join-Path $oldRoot 'config\coco-updater-state.json') -Encoding UTF8
    $stateRoot=Join-Path $localAppData 'CocoMinecraftUpdater';New-Item -ItemType Directory -Path $stateRoot|Out-Null
    [pscustomobject]@{path=$oldRoot;packId='coco-test'}|ConvertTo-Json|Set-Content (Join-Path $stateRoot 'target.json') -Encoding UTF8
    $manifestPath=Join-Path $temp 'manifest.json'
    [ordered]@{
        schemaVersion=2;packId='coco-test';version='0.0.1'
        packages=@([ordered]@{role='client';mods=@([ordered]@{name='dummy.jar';sha256=('0'*64)})})
        detector=[ordered]@{minecraftVersion='26.1.2';markerPath='config/coco-updater-state.json';groupTokens=@();knownE4mcDomains=@();modRules=@()}
    }|ConvertTo-Json -Depth 8|Set-Content $manifestPath -Encoding UTF8

    $source=Join-Path $temp 'CocoDetectionSleeper.java'
    [IO.File]::WriteAllText($source,'public class CocoDetectionSleeper { public static void main(String[] args) throws Exception { Thread.sleep(60000); } }',(New-Object Text.UTF8Encoding($false)))
    $minecraftJavaBin=Join-Path $originalAppData '.minecraft\runtime\java-runtime-epsilon\windows\java-runtime-epsilon\bin'
    $javac=Join-Path $minecraftJavaBin 'javac.exe';$java=Join-Path $minecraftJavaBin 'java.exe'
    if(-not(Test-Path -LiteralPath $javac)-or-not(Test-Path -LiteralPath $java)){
        $javac=(Get-Command javac -ErrorAction Stop).Source;$java=(Get-Command java -ErrorAction Stop).Source
    }
    & $javac $source
    if($LASTEXITCODE){throw 'No se pudo compilar el proceso Java de deteccion.'}
    $javaProcess=Start-Process $java -ArgumentList @('-cp',('"'+$temp+'"'),'CocoDetectionSleeper','--version','fabric-loader-0.19.3-26.1.2','--gameDir',('"'+$correctRoot+'"'),'--assetsDir',('"'+(Join-Path $correctRoot 'assets')+'"')) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500

    $env:APPDATA=$appData;$env:LOCALAPPDATA=$localAppData;$env:USERPROFILE=$profile
    $stdout=Join-Path $temp 'detect.out';$stderr=Join-Path $temp 'detect.err'
    $process=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$enginePath+'"'),'-ManifestPath',('"'+$manifestPath+'"'),'-Silent','-DetectOnly') -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -Wait -WindowStyle Hidden
    if($process.ExitCode-ne0){throw "DetectOnly fallo: $((Get-Content $stderr -Raw -ErrorAction SilentlyContinue))"}
    $result=Get-Content $stdout -Raw|ConvertFrom-Json
    if(-not[string]::Equals([string]$result.selected.Root,$correctRoot,[StringComparison]::OrdinalIgnoreCase)){throw "La instalacion persistida antigua vencio al Fabric 26.1.2 abierto: $($result.selected.Root)"}

    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($enginePath,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'El engine no se pudo analizar para probar TLauncher.'}
    $functionAst=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Disable-TLauncherSkinCape'},$true)
    if(-not$functionAst){throw 'Falta Disable-TLauncherSkinCape.'}
    . ([scriptblock]::Create($functionAst.Extent.Text))
    function Write-CocoLog([string]$Text){}
    $tlDir=Join-Path $correctRoot 'versions\fabric-loader-0.19.3-26.1.2'
    $tlPath=Join-Path $tlDir 'TLauncherAdditional.json'
    [ordered]@{activateSkinCapeForUserVersion=$true;skinVersion=$true;source='test'}|ConvertTo-Json|Set-Content $tlPath -Encoding UTF8
    $manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json
    if((Disable-TLauncherSkinCape $correctRoot $manifest)-ne1){throw 'No se reparo la configuracion TLauncher.'}
    $tl=Get-Content $tlPath -Raw|ConvertFrom-Json
    if($tl.activateSkinCapeForUserVersion-or$tl.skinVersion-or$tl.source-ne'test'){throw 'La reparacion TLauncher no conservo o desactivo los campos correctos.'}
}finally{
    $env:APPDATA=$originalAppData;$env:LOCALAPPDATA=$originalLocalAppData;$env:USERPROFILE=$originalUserProfile
    if($javaProcess-and-not$javaProcess.HasExited){Stop-Process -Id $javaProcess.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
'PASS: Fabric 26.1.2 abierto vence al destino obsoleto y TLSkinCape queda desactivado.'
