[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$testRoot=Join-Path $env:TEMP "coco-launcher-identity-$([guid]::NewGuid())"

try{
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null

    $freeRoot=Join-Path $testRoot 'free';New-Item -ItemType Directory -Path $freeRoot|Out-Null
    '{"selectedAccount":"free-id","accounts":{"free-id":{"displayName":"AmigoFree","type":"tlauncher","premiumAccount":false,"accessToken":"SECRET-MUST-NOT-LEAK"}}}' |
        Set-Content -LiteralPath (Join-Path $freeRoot 'TlauncherProfiles.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $freeRoot
    if($hint.Mode-ne'offline'-or$hint.Username-ne'AmigoFree'-or$hint.Confidence-ne'high'){throw 'No se reconocio la identidad local de TLauncher.'}
    if(($hint|ConvertTo-Json)-match'SECRET-MUST-NOT-LEAK'){throw 'La pista de identidad filtro un token.'}

    $premiumRoot=Join-Path $testRoot 'premium';New-Item -ItemType Directory -Path $premiumRoot|Out-Null
    '{"selectedAccount":"msa-id","accounts":{"msa-id":{"displayName":"AmigoPremium","type":"microsoft_account","accessToken":"ANOTHER-SECRET"}}}' |
        Set-Content -LiteralPath (Join-Path $premiumRoot 'TlauncherProfiles.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $premiumRoot
    if($hint.Mode-ne'offline'-or$hint.Username-ne'AmigoPremium'-or$hint.Confidence-ne'high'){throw 'Una cuenta conocida no se reutilizo como nombre local.'}
    if(($hint|ConvertTo-Json)-match'ANOTHER-SECRET'){throw 'La pista de identidad filtro un token Microsoft.'}

    $officialRoot=Join-Path $testRoot 'official';New-Item -ItemType Directory -Path $officialRoot|Out-Null
    '{}'|Set-Content -LiteralPath (Join-Path $officialRoot 'launcher_profiles_microsoft_store.json') -Encoding UTF8
    $hint=Get-CocoLauncherIdentityHint $officialRoot
    if($hint.Mode-ne'unknown'){throw 'Coco intento inferir una identidad desde un perfil oficial sin nombre seguro.'}

    $ambiguousRoot=Join-Path $testRoot 'ambiguous';New-Item -ItemType Directory -Path $ambiguousRoot|Out-Null
    '{"accounts":{"one":{"displayName":"PlayerOne","type":"free"},"two":{"displayName":"PlayerTwo","type":"microsoft_account"}}}' |
        Set-Content -LiteralPath (Join-Path $ambiguousRoot 'TlauncherProfiles.json') -Encoding UTF8
    if((Get-CocoLauncherIdentityHint $ambiguousRoot).Mode-ne'unknown'){throw 'Coco adivino entre dos nombres distintos.'}

    $statePath=Join-Path $testRoot 'state\identity.json'
    $resolved=Resolve-CocoLauncherIdentity $statePath $freeRoot
    if(-not$resolved.WasAutomatic-or$resolved.RequiresChoice-or$resolved.Identity.mode-ne'offline'-or$resolved.Identity.username-ne'AmigoFree'){
        throw 'El nombre local inequivoco no se configuro automaticamente.'
    }
    $stateText=Get-Content -LiteralPath $statePath -Raw
    if($stateText-match'(?i)token|secret'){throw 'El estado Coco contiene secretos.'}
    if((Resolve-CocoLauncherIdentity $statePath $ambiguousRoot).Identity.username-ne'AmigoFree'){throw 'El nombre persistido no prevalece.'}

    $legacyPath=Join-Path $testRoot 'legacy\identity.json'
    New-Item -ItemType Directory -Path (Split-Path $legacyPath -Parent) -Force|Out-Null
    '{"schemaVersion":1,"mode":"microsoft","username":"ViejoPremium","uuid":"12345678-1234-1234-1234-123456789abc","decisionSource":"legacy"}' |
        Set-Content -LiteralPath $legacyPath -Encoding UTF8
    $migrated=Resolve-CocoLauncherIdentity $legacyPath $officialRoot
    if($migrated.Identity.mode-ne'offline'-or$migrated.Identity.username-ne'ViejoPremium'){throw 'No se migro el nombre Microsoft legado a identidad local.'}
    if((Get-Content $legacyPath -Raw)-match'12345678-1234-1234-1234-123456789abc'){throw 'La migracion conservo un UUID Microsoft innecesario.'}

    $choicePath=Join-Path $testRoot 'choice\identity.json'
    $resolved=Resolve-CocoLauncherIdentity $choicePath $officialRoot
    if(-not$resolved.RequiresChoice-or$resolved.Status-ne'choice-required'-or(Test-Path $choicePath)){throw 'Un nombre desconocido no quedo como unica pregunta excepcional.'}

    $rejected=$false
    try{[void](Save-CocoLauncherIdentityState $choicePath microsoft 'NoDebePasar' '' user)}catch{$rejected=$true}
    if(-not$rejected){throw 'El estado nuevo todavia acepta modo premium.'}

    'PASS: identidad local unica, deteccion segura, migracion y ausencia de tokens validadas.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
