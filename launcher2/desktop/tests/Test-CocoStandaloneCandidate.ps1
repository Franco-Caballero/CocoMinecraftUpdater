#requires -Version 5.1
# Fixtures only: no network, no game install, no publishing.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

$desktop = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script = Join-Path $desktop 'scripts\New-CocoStandaloneCandidate.ps1'
$launcher2 = [IO.Path]::GetFullPath((Join-Path $desktop '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $launcher2 '..'))
$catalog = Join-Path $repo 'launcher\catalog.template.json'
$root = Join-Path ([IO.Path]::GetTempPath()) ('coco-candidate-test-' + [Guid]::NewGuid().ToString('N'))
$ownDrafts = New-Object 'Collections.Generic.List[string]'
function Assert($value, [string]$why) { if (!$value) { throw "FAIL: $why" } }
function Make-Zip([string]$path, [object[]]$items) {
    $file = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $zip = New-Object IO.Compression.ZipArchive($file, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($item in $items) {
                $stream = $zip.CreateEntry($item.Path).Open()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($item.Body)
                    $stream.Write($bytes,0,$bytes.Length)
                } finally { $stream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $file.Dispose() }
}
function Import-Fixture([string]$zip, [string]$id, [string[]]$required = @()) {
    & $script -ZipPath $zip -Id $id -Name 'Test Game' -Version '1.0' -ArchiveUrl 'https://github.com/example/repo/releases/download/v1/TestGame.zip' -CoverPath (Join-Path $root 'image.png') -Executable 'Game.exe' -RequiredPaths $required
}
function Must-Fail([scriptblock]$attempt, [string]$why) {
    $failed = $false
    try { & $attempt 2>&1 | Out-Null } catch { $failed = $true }
    Assert $failed $why
}

[void][IO.Directory]::CreateDirectory($root)
try {
    [IO.File]::WriteAllBytes((Join-Path $root 'image.png'), [byte[]](137,80,78,71,13,10,26,10,0,0,0,0))
    $source = Join-Path $root 'game.zip'
    Make-Zip $source @(
        @{Path='Game.exe';Body='game-content'},
        @{Path='UnityPlayer.dll';Body='unity-content'},
        @{Path='Game_Data/Plugins/x86_64/steam_api64.dll';Body='api-content'},
        @{Path='README.txt';Body='documentation'}
    )
    $originalCatalogHash = (Get-FileHash $catalog -Algorithm SHA256).Hash
    $generatedCatalog = Join-Path $desktop 'src-tauri/resources/catalog.json'
    $generatedMedia = Join-Path $desktop 'src-tauri/resources/media-manifests.json'
    $generatedCatalogHash = (Get-FileHash $generatedCatalog -Algorithm SHA256).Hash
    $generatedMediaHash = (Get-FileHash $generatedMedia -Algorithm SHA256).Hash
    $archiveHash = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $id = 'candidate-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
    $ownDrafts.Add($id)
    Import-Fixture $source $id @('README.txt') | Out-Null
    $draft = Join-Path $launcher2 "drafts/$id"
    Assert (Test-Path -LiteralPath $draft -PathType Container) 'draft missing'
    $candidate = Get-Content (Join-Path $draft 'catalog-candidate.json') -Raw | ConvertFrom-Json
    $lock = Get-Content (Join-Path $draft 'source-lock.json') -Raw | ConvertFrom-Json
    Assert ($candidate.id -ceq $id -and $candidate.runtime.type -eq 'standalone') 'catalog shape'
    Assert ($candidate.runtime.executable -eq 'Game.exe') 'executable name'
    Assert ($candidate.runtime.requiredFiles.Count -eq 4) 'required file detection'
    Assert ($candidate.pack.sha256 -eq $archiveHash) 'streamed ZIP digest'
    Assert ($lock.schemaVersion -eq 1 -and $lock.archive.sha256 -eq $archiveHash) 'source lock'
    # Exact same source-to-native conversion as the launcher build, read-only.
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $js = @'
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
// argv[1] is deliberately a dummy marker: sync-catalog's CLI guard MUST NOT run.
if (process.argv[1] !== 'candidate-validator-no-sync') process.exit(5);
const module = await import(pathToFileURL(process.argv[2]).href);
const entry = JSON.parse(readFileSync(process.argv[3], 'utf8'));
const native = module.toExperience(entry);
const installer = module.toInstallManifest(entry);
if(native.workflow!=='coco-standalone' || native.requiredFiles.length!==4 ||
  native.executable!=='Game.exe' || installer.archives.length!==1 ||
  installer.requiredFiles.length!==4) process.exit(3);
'@
        & $node.Source --input-type=module -e $js 'candidate-validator-no-sync' (Join-Path $desktop 'scripts/sync-catalog.mjs') (Join-Path $draft 'catalog-candidate.json')
        Assert ($LASTEXITCODE -eq 0) 'candidate fails real sync-catalog conversion'
    }
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $exeHash = [BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes('game-content'))).Replace('-','').ToLowerInvariant() }
    finally { $digest.Dispose() }
    Assert (@($candidate.runtime.requiredFiles | Where-Object { $_.path -eq 'Game.exe' -and $_.sha256 -eq $exeHash }).Count -eq 1) 'streamed executable digest'
    Assert ([IO.File]::ReadAllBytes((Join-Path $draft 'cover.png')).Length -eq 12) 'cover copy'
    $existingHash = (Get-FileHash (Join-Path $draft 'catalog-candidate.json') -Algorithm SHA256).Hash
    Must-Fail { Import-Fixture $source $id } 'existing draft overwritten'
    Assert ((Get-FileHash (Join-Path $draft 'catalog-candidate.json') -Algorithm SHA256).Hash -eq $existingHash) 'draft changed on retry'
    $badZip = Join-Path $root 'traversal.zip'
    Make-Zip $badZip @(@{Path='../escape.txt';Body='bad'},@{Path='Game.exe';Body='ok'})
    $badId = 'candidate-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
    Must-Fail { Import-Fixture $badZip $badId } 'ZIP traversal accepted'
    Assert (!(Test-Path (Join-Path $launcher2 "drafts/$badId"))) 'unsafe draft created'
    $duplicateZip = Join-Path $root 'duplicate.zip'
    Make-Zip $duplicateZip @(@{Path='Game.exe';Body='ok'},@{Path='Data/file.dll';Body='a'},@{Path='data/FILE.dll';Body='b'})
    $duplicateId = 'candidate-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
    Must-Fail { Import-Fixture $duplicateZip $duplicateId } 'duplicate path accepted'
    Assert (!(Test-Path (Join-Path $launcher2 "drafts/$duplicateId"))) 'duplicate draft created'
    $parentZip = Join-Path $root 'file-parent.zip'
    Make-Zip $parentZip @(@{Path='Game.exe';Body='ok'},@{Path='Data';Body='file'},@{Path='Data/config.json';Body='child'})
    $parentId = 'candidate-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
    Must-Fail { Import-Fixture $parentZip $parentId } 'file/directory parent conflict accepted'
    Assert (!(Test-Path (Join-Path $launcher2 "drafts/$parentId"))) 'file/parent conflict created draft'
    $missingId = 'candidate-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
    Must-Fail { Import-Fixture $source $missingId @('no.dll') } 'missing required file accepted'
    Must-Fail { Import-Fixture $source 'repo' } 'existing catalog id accepted'
    Assert ((Get-FileHash $catalog -Algorithm SHA256).Hash -eq $originalCatalogHash) 'source catalog modified'
    Assert ((Get-FileHash $generatedCatalog -Algorithm SHA256).Hash -eq $generatedCatalogHash) 'generated catalog unexpectedly rebuilt'
    Assert ((Get-FileHash $generatedMedia -Algorithm SHA256).Hash -eq $generatedMediaHash) 'generated media unexpectedly rebuilt'
    Write-Host 'PASS: draft, streaming SHA, auto-support, explicit required, duplicate/traversal rejection, preserved catalog and immutable draft.'
} finally {
    foreach ($id in $ownDrafts) {
        $own = Join-Path $launcher2 "drafts/$id"
        if ([IO.Directory]::Exists($own)) { Remove-Item -LiteralPath $own -Recurse -Force }
    }
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
