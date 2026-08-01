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
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases?per_page=100' -Headers $headers
$rel67 = @($releases | Where-Object { $_.tag_name -eq 'v0.5.67' -or $_.name -like '*67*' })[0]
if ($rel67) {
    Write-Host "Found v0.5.67 ID:" $rel67.id "Draft:" $rel67.draft
    if ($rel67.draft) {
        $body = @{ draft = $false; prerelease = $false } | ConvertTo-Json
        $pub = Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/$($rel67.id)" -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body
        Write-Host "v0.5.67 is now PUBLIC! URL:" $pub.html_url
    }
} else {
    Write-Host "v0.5.67 release draft not found in list."
}
