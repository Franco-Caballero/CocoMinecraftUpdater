$r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/tags/v0.5.72' -UseBasicParsing
Write-Host "Tag:" $r.tag_name "Draft:" $r.draft
foreach ($a in $r.assets) {
    Write-Host "  Asset Name:" $a.name "Size:" $a.size "Download URL:" $a.browser_download_url
}
