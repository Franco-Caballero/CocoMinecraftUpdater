$r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/latest' -UseBasicParsing
Write-Host "Latest Tag:" $r.tag_name "Draft:" $r.draft
