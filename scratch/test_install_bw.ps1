. .\engine\CocoLauncher.ps1

$catalog = Get-Content -LiteralPath .\launcher\catalog.template.json -Raw | ConvertFrom-Json
$bigWalk = @($catalog.experiences | Where-Object id -eq 'big-walk')[0]

$expRoot = "$env:APPDATA\CocoMinecraft\experiences"
$cacheRoot = "$env:LOCALAPPDATA\CocoMinecraftUpdater"

Write-Host "Testing Install-CocoStandaloneExperience for Big Walk..."
$res = Install-CocoStandaloneExperience $bigWalk $expRoot $cacheRoot

Write-Host "Result InstanceRoot: $($res.InstanceRoot)"
Write-Host "Result Updated: $($res.Updated)"

$execPath = Join-Path $res.InstanceRoot "Big Walk.exe"
Write-Host "ExecPath exists: $(Test-Path -LiteralPath $execPath)"
