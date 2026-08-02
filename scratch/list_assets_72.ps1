$credentialRequest = "protocol=https`nhost=github.com`n`n"
$credentialLines = @($credentialRequest | git credential fill)
$credential = @{}
foreach ($line in $credentialLines) {
    if ($line -match '^([^=]+)=(.*)$') { $credential[$matches[1]] = $matches[2] }
}
$headers = @{
    Authorization = "Bearer $($credential.password)"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/363665816' -Headers $headers
Write-Host "Tag:" $r.tag_name "Draft:" $r.draft
foreach ($a in $r.assets) {
    Write-Host "  Asset Name:" $a.name "Size:" $a.size "Download URL:" $a.browser_download_url
}
