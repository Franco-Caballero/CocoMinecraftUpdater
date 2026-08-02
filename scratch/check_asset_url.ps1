try {
    $r = Invoke-WebRequest -Uri "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.5.66/Machine-Party.zip" -Method Head -UseBasicParsing
    Write-Host "v0.5.66 asset HTTP Status:" $r.StatusCode
} catch {
    Write-Host "v0.5.66 asset error:" $_.Exception.Message
}

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
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=20' -Headers $headers
foreach ($rel in $releases) {
    Write-Host "Release Tag:" $rel.tag_name "ID:" $rel.id
    foreach ($asset in $rel.assets) {
        if ($asset.name -like "*Machine*") {
            Write-Host "  FOUND ASSET:" $asset.name "in release" $rel.tag_name "DownloadUrl:" $asset.browser_download_url
        }
    }
}
