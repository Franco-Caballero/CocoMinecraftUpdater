# tools/install.ps1 — Instalador y actualizador oficial de Coco Launcher
[CmdletBinding()]
param(
    [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'),
    [string]$Repository = 'Franco-Caballero/CocoMinecraftUpdater',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "   Instalador Oficial de Coco Launcher   " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# 1. Preparar directorio de destino en LocalAppData
if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

$targetExe = Join-Path $TargetDir 'CocoUpdater.exe'

# 2. Descargar la ultima version de CocoUpdater.exe
$downloadUrl = "https://github.com/$Repository/releases/latest/download/CocoUpdater.exe"
Write-Host "Descargando Coco Launcher desde GitHub..." -ForegroundColor Yellow

$tempDownload = "$targetExe.download-$([guid]::NewGuid().ToString('N')).tmp"
try {
    # Usar .NET WebClient / Invoke-WebRequest para evitar adjuntar Mark-of-the-Web (Zone.Identifier)
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempDownload -UseBasicParsing
    if (-not (Test-Path -LiteralPath $tempDownload) -or (Get-Item -LiteralPath $tempDownload).Length -lt 50000) {
        throw "La descarga no genero un ejecutable valido."
    }

    # Desbloquear archivo temporal para garantizar 0% de advertencias
    Unblock-File -LiteralPath $tempDownload -ErrorAction SilentlyContinue

    # Si CocoUpdater ya se esta ejecutando, cerrar la instancia previa para liberar el archivo
    $runningProcs = Get-Process -Name 'CocoUpdater' -ErrorAction SilentlyContinue
    if ($runningProcs) {
        Write-Host "Coco Launcher ya se encuentra en ejecucion. Cerrando instancia previa para actualizar..." -ForegroundColor Yellow
        $runningProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }

    # Reemplazo atomico del ejecutable con reintentos defensivos
    $moved = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Move-Item -LiteralPath $tempDownload -Destination $targetExe -Force
            $moved = $true
            break
        } catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
    Unblock-File -LiteralPath $targetExe -ErrorAction SilentlyContinue
    Write-Host "Coco Launcher instalado en: $targetExe" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $tempDownload) {
        Remove-Item -LiteralPath $tempDownload -Force -ErrorAction SilentlyContinue
    }
}

# 3. Crear o actualizar acceso directo en el Escritorio
try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop -and (Test-Path -LiteralPath $desktop)) {
        $shortcutPath = Join-Path $desktop 'Coco Launcher.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $targetExe
        $shortcut.WorkingDirectory = $TargetDir
        $shortcut.IconLocation = "$targetExe,0"
        $shortcut.Description = 'Abrir Coco Launcher'
        $shortcut.Save()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        Write-Host "Acceso directo listo en el Escritorio: Coco Launcher" -ForegroundColor Green
    }
} catch {
    Write-Host "Nota: No se pudo crear el acceso directo en el Escritorio ($($_.Exception.Message))" -ForegroundColor Gray
}

# 4. Lanzar la aplicacion directamente
if (-not $NoLaunch) {
    Write-Host "Iniciando Coco Launcher directamente..." -ForegroundColor Cyan
    Start-Process -FilePath $targetExe -WorkingDirectory $TargetDir
    Start-Sleep -Milliseconds 800
}

Write-Host "Listo! Coco Launcher se esta abriendo en tu pantalla." -ForegroundColor Green
