$inst = "$env:APPDATA\CocoMinecraft\experiences\nightfallcraft"
Get-ChildItem (Join-Path $inst 'config') -Recurse -File | Where-Object { $_.Name -match 'epicfight|lockon|modern|incontrol' } | Select-Object FullName
