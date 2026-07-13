@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap\CocoBootstrapper.ps1" -ChannelPath "%~dp0CocoUpdater.channel.json"
exit /b %errorlevel%
