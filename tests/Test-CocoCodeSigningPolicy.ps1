$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$policy=Get-Content -LiteralPath (Join-Path $root 'CODE_SIGNING_POLICY.md') -Raw
$workflow=Get-Content -LiteralPath (Join-Path $root '.github\workflows\signpath-release.yml') -Raw

foreach($required in @(
    'Free code signing provided by SignPath.io, certificate by SignPath Foundation.',
    'CocoMinecraftUpdater',
    'manually reviewed and approved',
    'multi-factor authentication',
    'SHA-256 and size',
    'SmartScreen-warning-free'
)){
    if($policy -notmatch [regex]::Escape($required)){throw "La politica de firma no contiene: $required"}
}
if($workflow -match '(?im)^\s+release:\s*$' -or $workflow -match 'types:\s*\[published\]'){
    throw 'El workflow no debe ejecutarse sobre releases publicados.'
}
foreach($required in @(
    'workflow_dispatch:',
    'if \(-not \$release\.draft\)',
    'actions/upload-artifact@v7',
    'signpath/github-action-submit-signing-request@v2',
    'archive: false',
    'skip-decompress: true',
    'bootstrap\.sha256',
    'gh release upload',
    'CocoUpdater\.exe'
)){
    if($workflow -notmatch $required){throw "El workflow de firma no contiene: $required"}
}
if($workflow -notmatch '(?i)no se modifica un release publicado'){throw 'Falta la barrera explicita contra modificar releases publicados.'}
'PASS: politica y workflow de firma solo permiten candidatos borrador con hash del EXE firmado.'
