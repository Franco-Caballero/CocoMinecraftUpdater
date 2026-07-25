[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$testRoot=Join-Path $env:TEMP "coco-launcher-identity-$([guid]::NewGuid())"

try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    $freeRoot=Join-Path $testRoot 'free'
    New-Item -ItemType Directory -Path $freeRoot|Out-Null
    @'
{"accounts":{"free-id":{"displayName":"AmigoFree","type":"tlauncher","premiumAccount":false,"accessToken":"SECRET-MUST-NOT-LEAK"}}}
'@|Set-Content -LiteralPath (Join-Path $freeRoot 'TlauncherProfiles.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $freeRoot
    if($hint.Mode-ne'offline'-or$hint.Username-ne'AmigoFree'-or$hint.Confidence-ne'high'){throw 'No se reconocio la identidad TLauncher offline.'}
    if(($hint|ConvertTo-Json)-match'SECRET-MUST-NOT-LEAK'){throw 'La pista de identidad filtro un token TLauncher.'}

    $premiumRoot=Join-Path $testRoot 'premium'
    New-Item -ItemType Directory -Path $premiumRoot|Out-Null
    @'
{"selectedAccount":"msa-id","accounts":{"msa-id":{"displayName":"AmigoPremium","type":"microsoft_account","accessToken":"ANOTHER-SECRET"}}}
'@|Set-Content -LiteralPath (Join-Path $premiumRoot 'TlauncherProfiles.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $premiumRoot
    if($hint.Mode-ne'microsoft'-or$hint.Username-ne'AmigoPremium'-or$hint.Confidence-ne'high'){throw 'No se reconocio la identidad Microsoft declarada por TLauncher.'}
    if(($hint|ConvertTo-Json)-match'ANOTHER-SECRET'){throw 'La pista Microsoft filtro un token TLauncher.'}

    $officialRoot=Join-Path $testRoot 'official'
    New-Item -ItemType Directory -Path $officialRoot|Out-Null
    '{}'|Set-Content -LiteralPath (Join-Path $officialRoot 'launcher_profiles_microsoft_store.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $officialRoot
    if($hint.Mode-ne'microsoft'-or$hint.Confidence-ne'likely'){throw 'No se reconocio el Launcher oficial como pista Microsoft.'}

    $ambiguousRoot=Join-Path $testRoot 'ambiguous'
    New-Item -ItemType Directory -Path $ambiguousRoot|Out-Null
    '{"accounts":{"one":{"displayName":"A","type":"free"},"two":{"displayName":"B","type":"microsoft_account"}}}'|Set-Content -LiteralPath (Join-Path $ambiguousRoot 'TlauncherProfiles.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $ambiguousRoot
    if($hint.Mode-ne'unknown'){throw 'Se adivino una identidad TLauncher realmente ambigua.'}

    $freeState=Join-Path $testRoot 'state-free\identity.json'
    $resolved=Resolve-CocoLauncherIdentity $freeState $freeRoot
    if(-not$resolved.WasAutomatic-or$resolved.RequiresChoice-or$resolved.Identity.mode-ne'offline'-or$resolved.Identity.username-ne'AmigoFree'){
        throw 'La identidad local inequívoca no se configuro automaticamente.'
    }
    $stateText=Get-Content -LiteralPath $freeState -Raw
    if($stateText-match'(?i)token|secret'){throw 'El estado Coco contiene un secreto o campo de token.'}
    $resolvedAgain=Resolve-CocoLauncherIdentity $freeState $ambiguousRoot
    if($resolvedAgain.Identity.mode-ne'offline'-or$resolvedAgain.WasAutomatic){throw 'La decision persistida no prevalece sobre pistas posteriores.'}

    $premiumState=Join-Path $testRoot 'state-premium\identity.json'
    $resolved=Resolve-CocoLauncherIdentity $premiumState $officialRoot
    if($resolved.Status-ne'microsoft-login-required'-or$resolved.RequiresChoice){throw 'La presencia oficial no enruto automaticamente a Microsoft login.'}
    $completed=Complete-CocoMicrosoftIdentityFromSessions $premiumState @([pscustomobject]@{Username='PremiumGuy';Uuid='12345678-1234-1234-1234-123456789abc'})
    if($completed.Status-ne'configured'-or$completed.Identity.username-ne'PremiumGuy'-or$completed.Identity.uuid-ne'12345678-1234-1234-1234-123456789abc'){throw 'La sesion autenticada no completo la identidad Microsoft.'}

    $multiState=Join-Path $testRoot 'state-multi\identity.json'
    [void](Save-CocoLauncherIdentityState $multiState microsoft '' '' user)
    $multi=Complete-CocoMicrosoftIdentityFromSessions $multiState @([pscustomobject]@{Username='PlayerOne';Uuid='11111111-1111-1111-1111-111111111111'},[pscustomobject]@{Username='PlayerTwo';Uuid='22222222-2222-2222-2222-222222222222'})
    if($multi.Status-ne'account-choice-required'){throw 'Coco adivino entre dos cuentas Microsoft distintas.'}

    $choiceState=Join-Path $testRoot 'state-choice\identity.json'
    $resolved=Resolve-CocoLauncherIdentity $choiceState $ambiguousRoot
    if(-not$resolved.RequiresChoice-or$resolved.Status-ne'choice-required'-or(Test-Path $choiceState)){throw 'La ambigüedad no quedo como unica pregunta excepcional.'}

    'PASS: deteccion, decision automatica, persistencia y ambigüedad sin copiar tokens validadas.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
