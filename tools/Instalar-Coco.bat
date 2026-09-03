@echo off
setlocal
title Instalador Coco Launcher
cls
echo =========================================
echo    Instalador Oficial de Coco Launcher   
echo =========================================
echo.
echo Instalando o actualizando Coco Launcher en tu equipo...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13; irm https://raw.githubusercontent.com/Franco-Caballero/CocoMinecraftUpdater/main/tools/install.ps1 | iex"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Ocurrio un inconveniente con el instalador principal.
    echo Intentando metodo de respaldo directo...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $d=Join-Path $env:LOCALAPPDATA 'CocoMinecraftUpdater'; New-Item -ItemType Directory -Path $d -Force|Out-Null; $e=Join-Path $d 'CocoUpdater.exe'; Get-Process -Name 'CocoUpdater' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 600; Invoke-WebRequest -Uri 'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/CocoUpdater.exe' -OutFile $e -UseBasicParsing; Unblock-File $e; Start-Process $e"
)

exit
