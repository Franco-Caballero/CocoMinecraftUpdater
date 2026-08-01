$r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/tags/v0.5.67' -UseBasicParsing
Write-Host "TagName:" $r.tag_name "Draft:" $r.draft "ID:" $r.id
