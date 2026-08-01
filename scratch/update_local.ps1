$dist = "dist\CocoUpdater.exe"
$local = "$env:LOCALAPPDATA\CocoMinecraftUpdater\CocoUpdater.exe"
Copy-Item -LiteralPath $dist -Destination $local -Force
Write-Host "Copied dist\CocoUpdater.exe (v0.5.67) to $local"
