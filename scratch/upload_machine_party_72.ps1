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

$zipPath = "release\Machine-Party.zip"
Write-Host "Uploading Machine-Party.zip (504 MB) to release 363665816 (v0.5.72)..."
$uploadUri = "https://uploads.github.com/repos/Franco-Caballero/CocoMinecraftUpdater/releases/363665816/assets?name=Machine-Party.zip"
Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $headers -ContentType 'application/octet-stream' -InFile $zipPath -TimeoutSec 300
Write-Host "Machine-Party.zip UPLOADED SUCCESSFULLY!"
