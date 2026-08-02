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
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=10' -Headers $headers
foreach ($rel in $releases) {
    Write-Host ("ID: {0} | Tag: {1} | Name: {2} | Draft: {3}" -f $rel.id, $rel.tag_name, $rel.name, $rel.draft)
}
