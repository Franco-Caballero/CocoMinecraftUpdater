$manifest = Invoke-RestMethod -Uri "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json" -UseBasicParsing
Write-Host "Published Version:" $manifest.version
