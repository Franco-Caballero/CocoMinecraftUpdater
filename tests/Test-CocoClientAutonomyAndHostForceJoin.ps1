$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $root 'engine\CocoNetwork.ps1')
. (Join-Path $root 'engine\CocoLauncher.ps1')

$catalog = Get-Content -LiteralPath (Join-Path $root 'launcher\catalog.template.json') -Raw | ConvertFrom-Json

# 1. Test Host Preferences persistence
$testPrefsPath = Join-Path $env:TEMP coco-host-prefs-452cda2626a64486b5a6d746fc1bc7e2.json
function Get-CocoHostPreferencesPath { $testPrefsPath }
try {
    Save-CocoHostPreferences $false
    $read = Read-CocoHostPreferences
    if ($read.forceJoin -ne $false) { throw 'FAIL: Read-CocoHostPreferences no devolvio forceJoin = false' }
    Save-CocoHostPreferences $true
    $read = Read-CocoHostPreferences
    if ($read.forceJoin -ne $true) { throw 'FAIL: Read-CocoHostPreferences no devolvio forceJoin = true' }
} finally {
    Remove-Item -LiteralPath $testPrefsPath -Force -ErrorAction SilentlyContinue
}

# 2. Test Announcement with forceJoin = false
$stateTemp = Join-Path $env:TEMP "coco-announcement-$([guid]::NewGuid().ToString('N')).json"
try {
    $exp = @($catalog.experiences | Where-Object { $_.managementMode -eq 'managed' -and ($_.launch.workflow -eq 'coco-managed' -or $_.launch.workflow -eq 'coco-standalone') } | Select-Object -First 1)[0]
    $ann = Publish-CocoSessionAnnouncement $catalog $exp.id 'ready' ([guid]::NewGuid().ToString()) $stateTemp 30 $false
    if ($ann.forceJoin -ne $false) { throw 'FAIL: Publish-CocoSessionAnnouncement no guardo forceJoin = false' }
    $testResult = Test-CocoSessionAnnouncement $catalog $ann
    if ($testResult.Announcement.forceJoin -ne $false) { throw 'FAIL: Test-CocoSessionAnnouncement perdio forceJoin' }

    # Test Get-CocoClientSessionAction with forceJoin = false
    $action = Get-CocoClientSessionAction $testResult
    if ($action.Action -ne 'optional-ready') { throw FAIL: Se esperaba optional-ready, se obtuvo $($action.Action) }

    # Test with forceJoin = true
    $annTrue = Publish-CocoSessionAnnouncement $catalog $exp.id 'ready' ([guid]::NewGuid().ToString()) $stateTemp 30 $true
    $actionTrue = Get-CocoClientSessionAction (Test-CocoSessionAnnouncement $catalog $annTrue)
    if ($actionTrue.Action -ne 'launch') { throw FAIL: Se esperaba launch, se obtuvo $($actionTrue.Action) }
} finally {
    Remove-Item -LiteralPath $stateTemp -Force -ErrorAction SilentlyContinue
}

# 3. Test ZeroTier client fail-open check
$dummyConfig = [pscustomobject]@{
    networkId = '0000000000000000'
    authorizationTimeoutSeconds = 120
    installer = [pscustomobject]@{ version = '1.14.0' }
    hostAddress = '10.77.37.1'
    minecraftPort = 25565
}
function Get-CocoZeroTierCli { '' }
function Get-CocoZeroTierNetwork { param($cli, $netId) $null }
function Get-CocoZeroTierAdapter { param($net, $netId) $null }
function Get-CocoClientNetworkFromAdapter { param($adapter, $cfg) $null }

$sw = [Diagnostics.Stopwatch]::StartNew()
$netResult = Wait-CocoZeroTierReady $dummyConfig 'client'
$sw.Stop()
if ($netResult.status -ne 'OFFLINE') { throw "FAIL: ZeroTier client debio retornar OFFLINE, devolvio $($netResult.status)" }
if ($sw.Elapsed.TotalSeconds -gt 5) { throw "FAIL: ZeroTier client check tomo mas de 5 segundos ($($sw.Elapsed.TotalSeconds))" }

# 4. Test Client Experience Card Buttons: JUGAR and UNIRSE
$dummyPanel = New-Object Windows.Forms.Panel
$dummyPanel.Size = New-Object Drawing.Size(840, 660)
$paths = [pscustomobject]@{
    CatalogRoot = $root
    CacheRoot = Join-Path $env:TEMP "coco-cache-$([guid]::NewGuid().ToString('N'))"
    ExperiencesRoot = Join-Path $env:TEMP "coco-exp-$([guid]::NewGuid().ToString('N'))"
    SessionStatePath = $stateTemp
}
$testExp = @($catalog.experiences | Where-Object { $_.managementMode -eq 'managed' } | Select-Object -First 1)[0]
$testRoot = Join-Path $paths.ExperiencesRoot $testExp.id
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $testRoot '.coco-installed') -Value 'installed' -Encoding UTF8

function Get-DescendantControls($control){
    $result=@($control.Controls)
    foreach($child in @($control.Controls)){
        if($child.Controls-and$child.Controls.Count-gt0){
            $result+=Get-DescendantControls $child
        }
    }
    $result
}

try {
    $global:CocoLauncherLiveHostSession = $null
    Update-CocoExperienceCardsUi $dummyPanel $catalog $paths 'client'

    $cards = @(Get-DescendantControls $dummyPanel | Where-Object { $_ -is [Windows.Forms.Panel] -and [string]$_.Name -eq 'CocoExperienceCard' })
    $testCard = @($cards | Where-Object { $_.Tag.ExperienceId -eq $testExp.id })[0]
    $buttons = @(Get-DescendantControls $testCard | Where-Object { $_ -is [Windows.Forms.Button] })
    $playBtn = @($buttons | Where-Object { $_.Text -eq 'JUGAR' })[0]
    if (-not $playBtn) { throw 'FAIL: No se encontro el boton JUGAR en la tarjeta instalada del cliente.' }

    $script:CocoLauncherClientRequestedExperience = ''
    $playBtn.PerformClick()
    if ($script:CocoLauncherClientRequestedExperience -ne $testExp.id) { throw "FAIL: Al pulsar JUGAR no se asigno la experiencia $($testExp.id)" }

    # Now mock live host session on this experience
    $global:CocoLauncherLiveHostSession = [pscustomobject]@{
        Experience = $testExp
        State = 'ready'
    }
    Update-CocoExperienceCardsUi $dummyPanel $catalog $paths 'client'
    $cards2 = @(Get-DescendantControls $dummyPanel | Where-Object { $_ -is [Windows.Forms.Panel] -and [string]$_.Name -eq 'CocoExperienceCard' })
    $testCard2 = @($cards2 | Where-Object { $_.Tag.ExperienceId -eq $testExp.id })[0]
    $buttons2 = @(Get-DescendantControls $testCard2 | Where-Object { $_ -is [Windows.Forms.Button] })
    $joinBtn = @($buttons2 | Where-Object { $_.Text -eq 'UNIRSE' })[0]
    if (-not $joinBtn) { throw 'FAIL: No se encontro el boton UNIRSE cuando el host tiene la partida abierta.' }

    $script:CocoLauncherClientJoinRequested = ''
    $joinBtn.PerformClick()
    if ($script:CocoLauncherClientJoinRequested -ne $testExp.id) { throw "FAIL: Al pulsar UNIRSE no se asigno la experiencia $($testExp.id)" }
} finally {
    $global:CocoLauncherLiveHostSession = $null
    Remove-Item -LiteralPath $paths.ExperiencesRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $paths.CacheRoot -Recurse -Force -ErrorAction SilentlyContinue
    $dummyPanel.Dispose()
}

Write-Host 'PASS: Client autonomy, ZeroTier fail-open, card buttons (JUGAR/UNIRSE), and host forceJoin toggle all verified.'
