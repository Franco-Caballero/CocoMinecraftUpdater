$errorFile = Get-ChildItem "$env:USERPROFILE\Desktop" -Filter "CocoUpdater-error-*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host "Error File: $($errorFile.FullName)"
Get-Content -Path $errorFile.FullName
