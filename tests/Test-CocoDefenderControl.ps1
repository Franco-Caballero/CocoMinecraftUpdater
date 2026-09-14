$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent

foreach($script in @(
    'engine\CocoUpdater.ps1',
    'engine\CocoLauncher.ps1',
    'engine\CocoSessionService.ps1',
    'engine\CocoNetwork.ps1',
    'engine\CocoNetworkElevated.ps1',
    'engine\CocoNetworkAuthorizer.ps1',
    'bootstrap\CocoBootstrapper.ps1',
    'tools\New-CocoEngine.ps1',
    'tools\Publish-CocoRelease.ps1',
    'tools\install.ps1'
)){
    [void][scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root $script)))
}

$legacyModule=Join-Path $root 'engine\CocoDefenderControl.ps1'
if(-not(Test-Path -LiteralPath $legacyModule -PathType Leaf)){throw 'Falta el shim requerido por bootstrappers antiguos.'}
$compatText=[IO.File]::ReadAllText($legacyModule)
if($compatText-notmatch"CocoDefenderControlCompatibility\s*=\s*'exclusions-only'"){throw 'El shim de compatibilidad de Defender no declara el modo exclusions-only.'}

$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
$updaterText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoUpdater.ps1'))
$bootstrapText=[IO.File]::ReadAllText((Join-Path $root 'bootstrap\CocoBootstrapper.ps1'))
$buildText=[IO.File]::ReadAllText((Join-Path $root 'tools\New-CocoEngine.ps1'))
$publishText=[IO.File]::ReadAllText((Join-Path $root 'tools\Publish-CocoRelease.ps1'))
$installerText=[IO.File]::ReadAllText((Join-Path $root 'tools\install.ps1'))

foreach($text in @($launcherText,$updaterText,$compatText)){
    foreach($forbidden in @(
        'Invoke-CocoDefenderPlayWindowStart',
        'Invoke-CocoDefenderPlayWindowEnd',
        'disable-defender.exe',
        'enable-defender.exe',
        'pgkt04/defender-control'
    )){
        if($text.Contains($forbidden)){throw "Defender no debe alternarse ni empaquetar herramientas heredadas: $forbidden"}
    }
}
if($buildText-notmatch'CocoDefenderControl\.ps1'){throw 'El engine debe conservar el shim para bootstrappers antiguos.'}
if($bootstrapText-notmatch'CocoDefenderControl\.ps1'){throw 'El bootstrap debe validar el shim de compatibilidad.'}
if($publishText-notmatch'CocoDefenderControl\.ps1'){throw 'El Publisher debe impedir publicar un engine incompatible con bootstrappers antiguos.'}

if($launcherText-notmatch'function Ensure-CocoDefenderExclusion'){throw 'Falta la gestion persistente de exclusiones de Defender.'}
if($launcherText-notmatch'Add-MpPreference -ExclusionPath'){throw 'El launcher ya no puede agregar exclusiones persistentes.'}
if($launcherText-notmatch'instance-locations\.json'){throw 'El launcher debe conservar compatibilidad con ubicaciones personalizadas antiguas.'}
if($installerText-notmatch'Add-MpPreference -ExclusionPath'){throw 'El instalador debe preparar exclusiones antes de iniciar Coco.'}
if($installerText-notmatch'instance-locations\.json'){throw 'El instalador/rescate debe recuperar ubicaciones personalizadas antiguas en el UAC inicial.'}

foreach($legacyTask in @('CocoDefenderDisable','CocoDefenderEnable')){
    if($updaterText-notmatch[regex]::Escape($legacyTask)){throw "Falta limpieza de la tarea heredada $legacyTask."}
}
if($updaterText-notmatch'Remove-CocoLegacyDefenderControlArtifacts'){throw 'Falta migracion de artefactos heredados de Defender Control.'}
if($updaterText-notmatch'tools\\defender-control'){throw 'Falta limpiar los binarios heredados de Defender Control.'}

'PASS: Defender permanece activo; Coco usa exclusiones persistentes y migra artefactos heredados.'
