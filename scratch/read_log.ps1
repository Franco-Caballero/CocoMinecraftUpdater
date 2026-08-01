$log = Get-ChildItem "$env:LOCALAPPDATA\CocoMinecraftUpdater\logs" -Filter "updater-*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host "Log file: $($log.FullName)"
Get-Content -Path $log.FullName
