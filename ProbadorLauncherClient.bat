@echo off
title Coco Launcher - Prueba de Cliente
cd /d "%~dp0"
echo Ejecutando probador cliente desde: %~f0
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -Command "& '.\tools\Invoke-CocoLauncherUiDev.ps1' -Role client -CreateDummyInstances"
