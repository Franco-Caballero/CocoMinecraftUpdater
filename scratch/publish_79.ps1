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
$rel79 = @($releases | Where-Object { $_.tag_name -eq 'v0.5.79' -or $_.name -like '*79*' })[0]
if ($rel79) {
    Write-Host "Found v0.5.79 ID:" $rel79.id "Draft:" $rel79.draft
    if ($rel79.draft) {
        $body = @{ draft = $false; prerelease = $false } | ConvertTo-Json
        $pub = Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/$($rel79.id)" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body
        Write-Host "v0.5.79 is now PUBLIC! URL:" $pub.html_url
    } else {
        Write-Host "v0.5.79 is ALREADY PUBLIC!"
    }
} else {
    Write-Host "v0.5.79 release draft not found in list."
}
