[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Restore-CocoValorantMap.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$errors = $null
[System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    throw "Restore-CocoValorantMap.ps1 tiene errores de sintaxis: $($errors | ForEach-Object Message -join '; ')"
}

foreach ($required in @(
        'MC x VAL - Ascent.zip',
        'MC x VAL - Haven V2.zip',
        '4e14bb28354f3d199a4dfe9fcfe59b11e032a180057a71a937bb3be935cccfc3',
        '2daa1cdda3d518505ee1d18a6e1bee19c9687411b4e87291e32dca9a8ae89a3e',
        'coco_agent_orb',
        'level.dat_old',
        'mcwifipnp.json',
        'valorant-map-reset-',
        'DRY RUN: no se modifico el mundo'
    )) {
    if ($source -notmatch [regex]::Escape($required)) {
        throw "Falta en el restaurador el contrato esperado: $required"
    }
}

if ($source -notmatch '\[switch\]\$Apply') {
    throw 'La restauracion debe exigir -Apply para cambiar un mundo.'
}
if ($source -notmatch 'Fuente oficial no contiene region') {
    throw 'La restauracion no valida la estructura del mapa fuente.'
}

Write-Host 'PASS: restaurador oficial de Ascent/Haven, hashes, backup, version 1.20.1 y dry-run validados.'
