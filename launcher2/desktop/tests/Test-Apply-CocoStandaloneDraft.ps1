#requires -Version 5.1
# Offline tests in a fresh isolated source tree. Never runs against the live repo.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '../scripts/Apply-CocoStandaloneDraft.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('coco-promotion-test-' + [Guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)

function Check([bool]$ok,[string]$description) { if (!$ok) { throw "FAIL: $description" } }
function Must-Fail([scriptblock]$call,[string]$description) {
    $failed = $false
    try { & $call 2>&1 | Out-Null } catch { $failed = $true }
    Check $failed $description
}
function Write-Json([string]$path,$data) {
    [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $data -Depth 30),$utf8)
}
function Sha([byte[]]$bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Fixture([string]$case) {
    $root = Join-Path $sandbox $case
    foreach($rel in @('launcher/experiences','launcher2/drafts/new-game','assets/experiences')){
        [void][IO.Directory]::CreateDirectory((Join-Path $root $rel))
    }
    $catalog = Join-Path $root 'launcher/catalog.template.json'
    $original = "{`r`n    `"schemaVersion`": 1,`r`n    `"notes`": {`"other`": `"keepé`"},`r`n    `"experiences`": [`r`n        {`"id`": `"existing-game`", `"name`": `"Existing`"}`r`n    ]`r`n}`r`n"
    [IO.File]::WriteAllText($catalog,$original,$utf8)
    $zip = Join-Path $root 'source.zip'
    $bytes = [Text.Encoding]::ASCII.GetBytes('PK synthetic ZIP bytes for offline source-hash assertion')
    [IO.File]::WriteAllBytes($zip,$bytes)
    $sha = Sha $bytes
    $url = 'https://github.com/example/repo/releases/download/v1/game.zip'
    $files = @([ordered]@{path='Game.exe';sha256=('b' * 64);size=100;archiveSha256=$sha})
    $candidate = [ordered]@{
        id = 'new-game'; name = 'New Game'; ui = @{imagePath='assets/experiences/new-game.png'}
        description = 'Standalone trial'
        instanceId='new-game'; managementMode='managed'
        runtime = [ordered]@{ type='standalone'; executable='Game.exe'; requiredFiles=$files }
        pack = [ordered]@{
            packId='standalone-new-game';lockPath='launcher/experiences/new-game.lock.json'
            version='1.0.0';sha256=$sha;size=[long]$bytes.Length
            archives=@(@{archiveUrl=$url;sha256=$sha;size=[long]$bytes.Length})
        }
        hosting=@{mode='p2p'}
        launch=[ordered]@{workflow='coco-standalone'; autoJoin=$false;arguments=@();serverName='Coco - New Game'}
        files=@()
    }
    $draft = Join-Path $root 'launcher2/drafts/new-game'
    Write-Json (Join-Path $draft 'catalog-candidate.json') $candidate
    Write-Json (Join-Path $draft 'source-lock.json') ([ordered]@{
        schemaVersion=1;experienceId='new-game';type='standalone';files=@()
        archive=@{url=$url;sha256=$sha;size=[long]$bytes.Length}
    })
    [IO.File]::WriteAllBytes((Join-Path $draft 'cover.png'),[byte[]](137,80,78,71,13,10,26,10,1,2,3,4,5))
    return [pscustomobject]@{Root=$root;Catalog=$catalog;Draft=$draft;Zip=$zip;Sha=$sha}
}

[void][IO.Directory]::CreateDirectory($sandbox)
try {
    $f=Fixture 'positive'
    $original = [IO.File]::ReadAllBytes($f.Catalog)
    $sourceSha=(Sha $original)
    $dry = & $script -DraftId new-game -RepoRoot $f.Root
    Check (@($dry | Where-Object { $_ -match 'DRY-RUN' }).Count -eq 1) 'default must be a dry run'
    Check ((Sha ([IO.File]::ReadAllBytes($f.Catalog))) -eq $sourceSha) 'dry run changed source catalog'
    Check (!(Test-Path (Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'dry-run wrote lock'
    Check (!(Test-Path (Join-Path $f.Root 'assets/experiences/new-game.png'))) 'dry-run wrote cover'
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply } 'unapproved apply was accepted'
    $apply = & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights -ExpectedCatalogSha256 $sourceSha -SourceZipPath $f.Zip
    Check (@($apply | Where-Object { $_ -match 'APLICADO' }).Count -eq 1) 'successful promotion did not finish'
    $merged=[IO.File]::ReadAllText($f.Catalog,[Text.Encoding]::UTF8)
    $json=ConvertFrom-Json -InputObject $merged
    Check ($json.experiences.Count -eq 2 -and $json.experiences[1].id -eq 'new-game') 'appended catalog invalid'
    Check ($merged.Contains('    "notes": {"other": "keepé"}') -and $merged.Contains("`r`n")) 'unrelated source formatting modified'
    Check ([IO.File]::Exists((Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'source lock missing'
    Check ([IO.File]::Exists((Join-Path $f.Root 'assets/experiences/new-game.png'))) 'asset missing'
    Check ((Sha ([IO.File]::ReadAllBytes((Join-Path $f.Root 'assets/experiences/new-game.png')))) -eq
        (Sha ([IO.File]::ReadAllBytes((Join-Path $f.Draft 'cover.png'))))) 'cover mutated'
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'repeat apply overwrote source'

    $f=Fixture 'multipart'
    $proposalPath=Join-Path $f.Draft 'catalog-candidate.json'
    $lockPath=Join-Path $f.Draft 'source-lock.json'
    $proposal=Get-Content $proposalPath -Raw | ConvertFrom-Json
    $lock=Get-Content $lockPath -Raw | ConvertFrom-Json
    $secondBytes=[Text.Encoding]::ASCII.GetBytes('second independently verified part')
    $secondSha=Sha $secondBytes
    Copy-Item -LiteralPath $f.Zip -Destination (Join-Path $f.Root 'game.zip')
    [IO.File]::WriteAllBytes((Join-Path $f.Root 'part2.zip'),$secondBytes)
    $proposal.pack.archives+=@{archiveUrl='https://github.com/example/repo/releases/download/v1/part2.zip';sha256=$secondSha;size=[long]$secondBytes.Length}
    $proposal.pack.size+=$secondBytes.Length
    $lockedParts=@($proposal.pack.archives | ForEach-Object {@{url=$_.archiveUrl;sha256=$_.sha256;size=$_.size}})
    $lock | Add-Member -NotePropertyName archives -NotePropertyValue $lockedParts
    Write-Json $proposalPath $proposal
    Write-Json $lockPath $lock
    $beforeMultipart=Sha ([IO.File]::ReadAllBytes($f.Catalog))
    $dry=& $script -DraftId new-game -RepoRoot $f.Root -SourceZipDirectory $f.Root
    Check (@($dry | Where-Object {$_ -match 'DRY-RUN'}).Count -eq 1) 'multipart dry-run failed'
    Check ((Sha ([IO.File]::ReadAllBytes($f.Catalog))) -eq $beforeMultipart) 'multipart dry-run wrote catalog'
    [IO.File]::WriteAllText((Join-Path $f.Root 'part2.zip'),'corrupt')
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -SourceZipDirectory $f.Root -Apply -ApproveReviewedLicenseRights } 'corrupt second part accepted'
    Check (!(Test-Path (Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'corrupt second part wrote lock'
    [IO.File]::WriteAllBytes((Join-Path $f.Root 'part2.zip'),$secondBytes)
    $apply=& $script -DraftId new-game -RepoRoot $f.Root -SourceZipDirectory $f.Root -Apply -ApproveReviewedLicenseRights -ExpectedCatalogSha256 $beforeMultipart
    Check (@($apply | Where-Object {$_ -match 'APLICADO'}).Count -eq 1) 'multipart promotion failed'
    $promotedLock=Get-Content (Join-Path $f.Root 'launcher/experiences/new-game.lock.json') -Raw | ConvertFrom-Json
    Check ($promotedLock.archives.Count -eq 2 -and $promotedLock.archives[1].sha256 -eq $secondSha) 'second part not preserved'

    $f=Fixture 'stale'
    $readHash=Sha ([IO.File]::ReadAllBytes($f.Catalog))
    [IO.File]::AppendAllText($f.Catalog,"`r`n ",$utf8)
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights -ExpectedCatalogSha256 $readHash } 'stale source hash accepted'
    Check (!(Test-Path (Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'stale operation wrote lock'

    $f=Fixture 'bad-lock'
    $lockPath=Join-Path $f.Draft 'source-lock.json'
    $lock=Get-Content $lockPath -Raw | ConvertFrom-Json
    $lock.archive.sha256='0'*64
    Write-Json $lockPath $lock
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'mismatched source lock accepted'
    Check (!(Test-Path (Join-Path $f.Root 'assets/experiences/new-game.png'))) 'bad lock created asset'

    $f=Fixture 'bad-path'
    $candidatePath=Join-Path $f.Draft 'catalog-candidate.json'
    $candidate=Get-Content $candidatePath -Raw | ConvertFrom-Json
    $candidate.runtime.requiredFiles[0].path='../escape.dll'
    Write-Json $candidatePath $candidate
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'path traversal accepted'

    $f=Fixture 'bad-cover'
    [IO.File]::WriteAllBytes((Join-Path $f.Draft 'cover.png'),[byte[]](1,2,3,4,5,6,7,8,9,10,11,12))
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'cover spoofing accepted'

    $f=Fixture 'occupied'
    $target=Join-Path $f.Root 'assets/experiences/new-game.png'
    [IO.File]::WriteAllBytes($target,[byte[]](1,2,3,4))
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'existing asset was overwritten'
    Check ((Sha ([IO.File]::ReadAllBytes($target))) -eq (Sha ([byte[]](1,2,3,4)))) 'unrelated asset changed'
    Check (!(Test-Path (Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'occupied target created lock'

    $f=Fixture 'wrong-local-zip'
    [IO.File]::AppendAllText($f.Zip,'extra',$utf8)
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights -SourceZipPath $f.Zip } 'mismatched local ZIP was accepted'

    $f=Fixture 'untrusted-extra-field'
    $candidatePath=Join-Path $f.Draft 'catalog-candidate.json'
    $candidate=Get-Content $candidatePath -Raw | ConvertFrom-Json
    $candidate | Add-Member -NotePropertyName 'runtimePolicies' -NotePropertyValue @{defenderExclusion='required'}
    Write-Json $candidatePath $candidate
    Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'unsafe extra runtime policies accepted'
    Check (!(Test-Path (Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'unknown field created source files'

    $f=Fixture 'locked-catalog-rollback'
    $originalHash=Sha ([IO.File]::ReadAllBytes($f.Catalog))
    $fileLock=New-Object IO.FileStream($f.Catalog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        Must-Fail { & $script -DraftId new-game -RepoRoot $f.Root -Apply -ApproveReviewedLicenseRights } 'catalog locked by unrelated reader was overwritten'
    } finally { $fileLock.Dispose() }
    Check ((Sha ([IO.File]::ReadAllBytes($f.Catalog))) -eq $originalHash) 'locked catalog changed'
    Check (!(Test-Path (Join-Path $f.Root 'launcher/experiences/new-game.lock.json'))) 'lock remained after failed final commit'
    Check (!(Test-Path (Join-Path $f.Root 'assets/experiences/new-game.png'))) 'cover remained after failed final commit'

    Write-Host 'PASS: dry-run, explicit license approval, local SHA, atomic source writes, source formatting, stale CAS, rollback boundaries, path/lock/cover/asset attacks.'
} finally {
    # Only remove our unique isolated test root, NEVER the production checkout.
    if ([IO.Directory]::Exists($sandbox)) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
