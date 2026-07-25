[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $env:TEMP "coco-launcher-migration-$([guid]::NewGuid())"
$desktop=Join-Path $testRoot 'Desktop'
$downloads=Join-Path $testRoot 'Downloads'
$canonicalRoot=Join-Path $testRoot 'Canonical'
$canonical=Join-Path $canonicalRoot 'CocoUpdater.exe'

try{
    New-Item -ItemType Directory -Path $desktop,$downloads,$canonicalRoot -Force|Out-Null
    [IO.File]::WriteAllText($canonical,'canonical',(New-Object Text.UTF8Encoding($false)))
    $launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
    . ([ScriptBlock]::Create($launcherText))

    $shortcutPath=Install-CocoLauncherShortcut $canonical $desktop
    if(-not(Test-Path -LiteralPath $shortcutPath)){throw 'No se creo Coco Launcher.lnk.'}
    $shell=New-Object -ComObject WScript.Shell
    try{$shortcut=$shell.CreateShortcut($shortcutPath);$target=$shortcut.TargetPath}
    finally{
        foreach($item in @($shortcut,$shell)){if($item){try{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)}catch{}}}
    }
    if(-not[string]::Equals([IO.Path]::GetFullPath($target),[IO.Path]::GetFullPath($canonical),[StringComparison]::OrdinalIgnoreCase)){
        throw "El acceso directo apunta a '$target' y no al EXE canonico."
    }

    $legacy=Join-Path $downloads 'CocoUpdater (7).exe'
    [IO.File]::WriteAllText($legacy,'legacy',(New-Object Text.UTF8Encoding($false)))
    if(-not(Test-CocoLegacyLauncherCandidate $legacy $canonical @($downloads) 'Coco Minecraft Updater')){
        throw 'Una copia Coco valida dentro de Descargas no fue reconocida.'
    }
    if(Test-CocoLegacyLauncherCandidate $canonical $canonical @($canonicalRoot) 'Coco Minecraft Updater'){
        throw 'El EXE canonico fue clasificado como copia antigua.'
    }
    $outside=Join-Path $testRoot 'CocoUpdater.exe'
    [IO.File]::WriteAllText($outside,'outside',(New-Object Text.UTF8Encoding($false)))
    if(Test-CocoLegacyLauncherCandidate $outside $canonical @($downloads) 'Coco Minecraft Updater'){
        throw 'Un EXE fuera de las raices permitidas fue aceptado.'
    }
    $unrelated=Join-Path $downloads 'Factura.exe'
    [IO.File]::WriteAllText($unrelated,'unrelated',(New-Object Text.UTF8Encoding($false)))
    if(Test-CocoLegacyLauncherCandidate $unrelated $canonical @($downloads) 'Coco Minecraft Updater'){
        throw 'Un ejecutable de nombre arbitrario fue aceptado.'
    }

    $scheduled=New-CocoLegacyLauncherArchiveHelper $legacy $canonical $testRoot 0
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scheduled.HelperPath -WaitPid 0 -Source $legacy -Canonical $canonical -BackupRoot $scheduled.BackupRoot -ExpectedHash $scheduled.ExpectedHash
    if(Test-Path -LiteralPath $legacy){throw 'La copia antigua no salio de Descargas.'}
    $archived=@(Get-ChildItem -LiteralPath $scheduled.BackupRoot -File -Filter '*.exe')
    if($archived.Count-ne1-or([IO.File]::ReadAllText($archived[0].FullName))-ne'legacy'){
        throw 'La copia antigua no quedo recuperable en el respaldo esperado.'
    }
    if(-not(Test-Path -LiteralPath $canonical)){throw 'La migracion altero el EXE canonico.'}
    if(Test-Path -LiteralPath $scheduled.HelperPath){throw 'El helper de archivo no se retiro a si mismo.'}

    $bootstrap=[IO.File]::ReadAllText((Join-Path $root 'bootstrap\CocoBootstrapper.ps1'))
    $engine=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
    if($bootstrap-notmatch"CocoLauncher\.ps1"-or$engine-notmatch'Initialize-CocoLauncherMigration'){
        throw 'El bootstrap/engine no incluye o inicializa la migracion del launcher.'
    }
    'PASS: acceso directo canonico y archivo recuperable de copias antiguas validados.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
