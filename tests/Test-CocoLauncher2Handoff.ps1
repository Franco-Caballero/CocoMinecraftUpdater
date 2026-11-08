$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$updaterPath=Join-Path $root 'engine\CocoUpdater.ps1'
$launcherPath=Join-Path $root 'engine\CocoLauncher.ps1'
$source=[IO.File]::ReadAllText($updaterPath,[Text.Encoding]::UTF8)
$launcher=[IO.File]::ReadAllText($launcherPath,[Text.Encoding]::UTF8)
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "FALLO: $Message"}}

$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count-eq0) "CocoUpdater.ps1 no parsea: $($errors|ForEach-Object Message)"

# El Setup fijado debe ser exactamente el publicado en coco2-channel.
$release=[regex]::Match($source,"Version='(?<v>[^']+)'\s+Url='(?<u>[^']+)'\s+Sha256='(?<s>[^']+)'\s+Size=\[int64\](?<n>\d+)")
Assert-True $release.Success 'falta el Setup fijado de Coco Launcher 2'
$version=$release.Groups['v'].Value
Assert-True ($version-match'^\d+\.\d+\.\d+$') 'versión del Setup inválida'
Assert-True ($release.Groups['u'].Value-ceq"https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/coco2-channel/CocoLauncher2_$($version)_x64-setup.exe") 'URL del Setup fuera de coco2-channel'
Assert-True ($release.Groups['s'].Value-cmatch'^[0-9a-f]{64}$') 'SHA-256 del Setup debe ir en minúsculas'
Assert-True ([int64]$release.Groups['n'].Value-gt1MB) 'tamaño del Setup no fijado'

# Las funciones del traspaso se evalúan aisladas, sin red ni accesos reales.
$wanted='Test-CocoLauncher1Target','Test-Coco2Supported'
foreach($function in $ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$wanted-contains$node.Name},$true)){
    . ([ScriptBlock]::Create($function.Extent.Text))
}
foreach($name in 'CocoUpdater.exe','Coco Updater.exe','CocoMinecraftUpdater.exe','Coco Launcher.exe','CocoUpdater (1).exe','cocoupdater-2.exe'){
    Assert-True (Test-CocoLauncher1Target "C:\Users\a\Downloads\$name") "debería retirar el acceso a $name"
}
Assert-True (Test-CocoLauncher1Target 'C:\Users\a\AppData\Local\CocoMinecraftUpdater\CocoUpdater.exe') 'acceso canónico del 1'
foreach($name in 'coco-launcher-2.exe','Coco Launcher 2.exe','CocoLauncher2_0.6.17_x64-setup.exe','steam.exe','Minecraft.exe',''){
    Assert-True (-not(Test-CocoLauncher1Target "C:\Juegos\$name")) "no debe tocar el acceso a '$name'"
}
Assert-True (Test-Coco2Supported) 'este equipo de pruebas es Windows 10/11 x64'

# Solo una apertura manual hace el traspaso; Bridge, red y pruebas siguen igual.
$gate=[regex]::Match($source,'\$manualOpen=(?<g>[\s\S]+?)\n\s+if\(\$manualOpen-and\(Invoke-CocoLauncher2Handoff\)\)\{exit 0\}')
Assert-True $gate.Success 'falta la puerta del traspaso'
foreach($required in '-not$Silent','-not$TestSuppressUi','-not$DetectOnly','-not$NetworkOnly','-not$Preview','IsNullOrWhiteSpace($GameDir)','$MinecraftPid-le0','IsNullOrWhiteSpace($SessionStatePath)','-not$automaticFullCheck'){
    Assert-True ($gate.Groups['g'].Value.Contains($required)) "la puerta debe exigir $required"
}
Assert-True ($source.IndexOf('if($manualOpen-and(Invoke-CocoLauncher2Handoff)){exit 0}')-lt$source.IndexOf('Initialize-CocoLauncherMigration $canonical')) 'el traspaso ocurre antes de recrear accesos del 1'
Assert-True ($source.IndexOf('Ensure-BootstrapUpdate $manifest')-lt$source.IndexOf('if($manualOpen-and(Invoke-CocoLauncher2Handoff))')) 'el bootstrap se mantiene al día antes del traspaso'

# Un fallo nunca deja al amigo sin launcher, y el EXE del 1 no se borra (Minecraft lo usa).
$handoff=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Invoke-CocoLauncher2Handoff'},$true).Extent.Text
Assert-True ($handoff-match'catch\{[\s\S]+return \$false') 'un fallo vuelve al launcher 1'
Assert-True ($handoff.IndexOf('Start-Coco2 $exe')-lt$handoff.IndexOf('Move-CocoLauncher1Shortcuts')) 'los accesos del 1 se retiran solo con el 2 ya abierto'
Assert-True ($handoff.IndexOf('Start-Coco2 $exe')-lt$handoff.IndexOf('Coco2HandoffMarker')) 'el traspaso se marca solo con el 2 ya abierto'
Assert-True (-not($source-match"Remove-Item[^\n]*COCO_BOOTSTRAPPER_EXE")) 'no se borra el EXE canónico del 1'
Assert-True ($source-match"ArgumentList '/S'") 'instalación silenciosa por usuario'
Assert-True (-not($source-match"Verb RunAs[^\n]*Setup|Setup[^\n]*-Verb RunAs")) 'el Setup no pide UAC'
Assert-True ($source-match"downloads\\jars|downloads\\\\jars|Los mods de Minecraft \(downloads\\jars\)") 'documenta que no toca los mods de Minecraft'
Assert-True (-not($source-match"Remove-Item[^\n]*'jars'|Remove-Item[^\n]*backups")) 'no borra mods ni respaldos'

# Tras el traspaso, el Bridge no vuelve a poner el acceso del 1 en el escritorio.
Assert-True ($launcher-match"coco2-handoff\.json'\) -PathType Leaf\)\{return\}") 'Initialize-CocoLauncherMigration respeta el traspaso'
Write-Host "Coco Launcher 2 handoff OK ($version)"
