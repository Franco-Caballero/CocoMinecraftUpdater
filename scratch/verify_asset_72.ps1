try {
    $r = Invoke-WebRequest -Uri "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v0.5.72/Machine-Party.zip" -Method Head -UseBasicParsing
    Write-Host "v0.5.72 Machine-Party.zip HTTP Status:" $r.StatusCode
} catch {
    Write-Host "v0.5.72 Machine-Party.zip error:" $_.Exception.Message
}
