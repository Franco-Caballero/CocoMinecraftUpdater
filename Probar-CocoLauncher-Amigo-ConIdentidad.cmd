@echo off
start "" powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0tests\Start-CocoLauncherVisualDemo.ps1" -IdentityState Configured
