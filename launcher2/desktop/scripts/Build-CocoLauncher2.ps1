<#
  Builds the Coco 2 Windows installer and puts one shareable EXE in launcher2/dist.
  No Git push, release upload, user-game mutation, or legacy Coco scripts.
#>
[CmdletBinding()]
param([switch]$SkipDependencyInstall,[switch]$FinalizeExisting)

$ErrorActionPreference='Stop'

# A Tauri Release can compile hundreds of Rust crates. On 16 GiB Windows
# hosts, unbounded Cargo parallelism can kill LLVM with an out-of-memory
# error *after* all source tests pass. A serial build is slower but retains
# correct artifacts and leaves other users' applications running.
function Get-SafeCargoJobs([UInt64]$totalMemoryBytes,[int]$logicalCores){
    if($logicalCores -lt 1 -or $totalMemoryBytes -le 12GB){return 1}
    # With dependencies already compiled, only Coco's own crate builds: two at once fits in 16 GB.
    if($totalMemoryBytes -le 24GB){return [Math]::Min(2,$logicalCores)}
    if($totalMemoryBytes -le 48GB){return [Math]::Min(2,$logicalCores)}
    return [Math]::Min(4,$logicalCores)
}

if(-not $env:CARGO_BUILD_JOBS){
    try {
        $machine=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $memoryBytes=[UInt64]$machine.TotalPhysicalMemory
        $logicalCores=[int]$machine.NumberOfLogicalProcessors
    }catch{
        $memoryBytes=[UInt64]0
        $logicalCores=1
    }
    $env:CARGO_BUILD_JOBS=[string](Get-SafeCargoJobs $memoryBytes $logicalCores)
    Write-Host "Cargo Release: $env:CARGO_BUILD_JOBS compilador(es) simultáneo(s) según RAM física" 
}elseif($env:CARGO_BUILD_JOBS -notmatch '^[1-9][0-9]{0,2}$' -or [int]$env:CARGO_BUILD_JOBS -gt 128){
    throw 'CARGO_BUILD_JOBS inválido: debe ser un entero positivo entre 1 y 128'
}

$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# dist/ is intentionally gitignored, so it does not exist in a clean clone.
$distribution=Join-Path (Resolve-Path (Join-Path $root '..')).Path 'dist'
$config=(Get-Content -LiteralPath (Join-Path $root 'src-tauri\tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$publicPath=Join-Path $env:LOCALAPPDATA 'CocoLauncher2\signing\public-key.pub'
if(-not (Test-Path -LiteralPath $publicPath -PathType Leaf)){
    throw 'Falta la clave de firma del host. Inicializa una vez con Configure-Coco2Updater.ps1.'
}
$public=(Get-Content -LiteralPath $publicPath -Encoding UTF8 -Raw).Trim()
if($public -cne [string]$config.plugins.updater.pubkey){throw 'La clave pública del proyecto no coincide con la clave del host. No firmar.'}
$releaseExe=Join-Path $root 'src-tauri\target\release\coco-launcher-2.exe'
$running=@(Get-CimInstance Win32_Process -Filter "name='coco-launcher-2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -ieq $releaseExe })
# Windows locks a running EXE against writing but not against renaming: the open window
# keeps working and the new build takes the original name.
if($running.Count -and (Test-Path -LiteralPath $releaseExe)){
    $aside="coco-launcher-2.running-$(Get-Date -Format 'yyyyMMddHHmmss').exe"
    Rename-Item -LiteralPath $releaseExe -NewName $aside
    $lockedDep=Join-Path (Split-Path $releaseExe) 'deps\coco-launcher-2.exe'
    if(Test-Path -LiteralPath $lockedDep){Rename-Item -LiteralPath $lockedDep -NewName $aside}
}

# No signing secret must exist while running npm, tests, Vite or Cargo.
if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY','Process'))) {
    throw 'No compilar con la clave de firma en el entorno. Ejecuta Build-CocoLauncher2.ps1 sin ella.'
}

function Invoke-Checked([string]$Program,[string[]]$Arguments){
    # PowerShell 5.1 wraps stderr output from a native tool in an error record;
    # Tauri's informational `--no-sign` warning is not an exit failure.
    # Inspect the actual native exit code instead of treating stderr as fatal.
    $priorPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $Program @Arguments
        $nativeExit=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$priorPreference
    }
    if($nativeExit -ne 0){throw "$Program falló con código $nativeExit"}
}

$previousTemp=$env:TEMP
$previousTmp=$env:TMP
# Own one workspace per invocation, including all child tests and signing QA.
# Never sweep the user's shared TEMP or another invocation's workspace.
$buildTempParent=if(Test-Path -LiteralPath 'D:\' -PathType Container){'D:\CocoWork\build-temp'}else{$previousTemp}
New-Item -ItemType Directory -Path $buildTempParent -Force | Out-Null
$buildTempParent=(Resolve-Path -LiteralPath $buildTempParent).Path
$buildTemp=Join-Path $buildTempParent ('coco2-build-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildTemp -ErrorAction Stop | Out-Null
$env:TEMP=$buildTemp
$env:TMP=$buildTemp
$createdPlayerLink=$false
Push-Location $root
try {
    $playerRuntime=& (Join-Path $PSScriptRoot 'Get-Coco2PlayerRuntime.ps1')
    if(-not $playerRuntime -or -not(Test-Path -LiteralPath (Join-Path $playerRuntime 'libvlc.dll'))){throw 'Falta motor de vídeo verificado'}
    # Tauri 2's resource normalizer discards Windows drive prefixes. A local
    # directory junction gives it relative paths without copying the runtime
    # into the source tree. Only the pointer is removed; never recurse into it.
    $playerLink=Join-Path $root 'src-tauri\resources\.player-runtime'
    if(Test-Path -LiteralPath $playerLink){
        $existingLink=Get-Item -LiteralPath $playerLink -Force
        if(-not($existingLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [string]$existingLink.Target -cne [string]$playerRuntime){throw 'Ruta de runtime existente inesperada; no reemplazar'}
    }else{
        New-Item -ItemType Junction -Path $playerLink -Target $playerRuntime -ErrorAction Stop | Out-Null
        $createdPlayerLink=$true
    }
    $resourceMap=@{}
    foreach($resource in $config.bundle.resources){$resourceMap[$resource]=$resource}
    $runtimeManifest=Get-Content -LiteralPath (Join-Path $root 'src-tauri\resources\vlc-runtime-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($entry in $runtimeManifest.files){$resourceMap['resources/.player-runtime/'+$entry.path]='player/'+$entry.path}
    $playerConfig=Join-Path $buildTemp 'player-bundle.json'
    [IO.File]::WriteAllText($playerConfig,(@{bundle=@{resources=$resourceMap}} | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    # A fresh developer checkout needs no manual prerequisite step. Verify or
    # fetch the exact signed ZeroTier MSI BEFORE compiling, with no signing key.
    & (Join-Path $PSScriptRoot 'Get-Coco2ZeroTierMsi.ps1')
    if(-not $?){throw 'No se pudo verificar el MSI oficial de ZeroTier'}
    if(-not $FinalizeExisting){
        if(-not $SkipDependencyInstall){Invoke-Checked 'npm.cmd' @('ci','--no-audit','--no-fund')}
        # The previous public Setup intentionally retains its older version.
        # Defer only tests of the installer until a signed candidate exists.
        $artifactTests=@('installed-nsis-v6.test.mjs','installed-release-synthetic-v6.test.mjs')
        $sourceTests=@(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.test.mjs' -File |
            Where-Object {$artifactTests -notcontains $_.Name} | Sort-Object Name)
        if($sourceTests.Count -lt 10){throw 'Preflight tests missing: refusing release build'}
        $testArgs=@('--test')+@($sourceTests | ForEach-Object {$_.FullName})
        Invoke-Checked 'node.exe' $testArgs
        Invoke-Checked 'npm.cmd' @('run','tauri','build','--','--bundles','nsis','--no-sign','--config',$playerConfig)
    }else{
        # Recovery ONLY after Tauri produced a complete NSIS binary before a
        # non-product post-build failure. Never rebuild Rust or trust an old
        # installer from a different version when finalizing this exact build.
        $compiled=Get-Item -LiteralPath $releaseExe -ErrorAction Stop
        if($compiled.Length -lt 5MB -or $compiled.VersionInfo.ProductVersion -cne [string]$config.version){
            throw 'El ejecutable Release existente no coincide con la versión de proyecto'
        }
        Write-Host "Finalizando NSIS existente $($config.version) sin recompilar Rust" 
    }
    $nsis=Join-Path $root 'src-tauri\target\release\bundle\nsis'
    $candidates=@(Get-ChildItem -LiteralPath $nsis -Filter '*-setup.exe' -File -ErrorAction Stop | Where-Object {$_.Name -like "*$($config.version)_x64-setup.exe"})
    if($candidates.Count -ne 1){throw "Se esperaba un único setup NSIS, encontrados $($candidates.Count)"}
    $source=$candidates[0]
    if($source.Length -lt 5MB){throw 'El instalador parece estar incompleto'}
    if($FinalizeExisting -and $source.LastWriteTime -lt $compiled.LastWriteTime.AddMinutes(-5)){
        throw 'El Setup existente es anterior al ejecutable Release; no firmar artefactos mezclados'
    }
    $signatureSource=$source.FullName+'.sig'
    # A prior signed build may have left a sidecar for an older EXE. It is a
    # generated artifact, so remove it before signing THIS exact binary.
    if(Test-Path -LiteralPath $signatureSource -PathType Leaf){Remove-Item -LiteralPath $signatureSource -Force}
    $signingScript=Join-Path $PSScriptRoot 'Configure-Coco2Updater.ps1'
    $signOnly=Join-Path $PSScriptRoot 'Sign-Coco2Bundle.ps1'
    & $signingScript -RunBuild -BuildScript $signOnly
    if(-not $? -or -not (Test-Path -LiteralPath $signatureSource -PathType Leaf)){throw 'No se generó firma Tauri del Setup'}
    if(-not (Test-Path -LiteralPath $distribution -PathType Container)){
        New-Item -ItemType Directory -Path $distribution -ErrorAction Stop | Out-Null
    }
    $destination=Join-Path $distribution 'CocoLauncher2-Setup.exe'
    # Keep the last verified public Setup untouched until a NEW immutable
    # candidate passes the complete signature and signed-feed verification.
    $hash=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
    # Assemble the exact versioned Tauri installer, signature and feed that
    # GitHub releases expect. Each distinct binary gets its own immutable
    # candidate directory; no published or previous candidate is replaced.
    $candidateName=('{0}-{1}' -f [string]$config.version,$hash.Substring(0,12))
    $candidateDir=Join-Path $distribution (Join-Path 'publish-ready' $candidateName)
    # GitHub turns spaces in asset names into dots, so the NSIS name would never
    # match its own download URL. Every version lives in the fixed coco2-channel
    # release under a plain name; Coco 1's Latest release is never touched.
    $releaseAssetName="CocoLauncher2_$($config.version)_x64-setup.exe"
    $candidateExe=Join-Path $candidateDir $releaseAssetName
    $candidateSig=$candidateExe+'.sig'
    $candidateFeed=Join-Path $candidateDir 'latest.json'
    if(Test-Path -LiteralPath $candidateDir){
        if(!(Test-Path -LiteralPath $candidateExe) -or !(Test-Path -LiteralPath $candidateSig) -or !(Test-Path -LiteralPath $candidateFeed)){
            throw 'Candidato anterior incompleto: no sobrescribir. Revisa la carpeta de publicación.'
        }
        # A recovery can generate a different valid signature for identical
        # bytes. Keep the immutable candidate and verify its original signed
        # feed below; never replace it with the freshly generated sidecar.
        if((Get-FileHash -LiteralPath $candidateExe -Algorithm SHA256).Hash -cne $hash -or
           (-not $FinalizeExisting -and (Get-FileHash -LiteralPath $candidateSig -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $signatureSource -Algorithm SHA256).Hash)){
            throw 'Candidato anterior no coincide con el build. No sobrescribir.'
        }
    }else{
        New-Item -ItemType Directory -Path $candidateDir -Force | Out-Null
        Copy-Item -LiteralPath $source.FullName -Destination $candidateExe
        Copy-Item -LiteralPath $signatureSource -Destination $candidateSig
        $downloadUrl="https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/coco2-channel/$releaseAssetName"
        & (Join-Path $PSScriptRoot 'New-Coco2UpdateFeed.ps1') -InstallerPath $candidateExe -Version ([string]$config.version) -DownloadUrl $downloadUrl -OutputPath $candidateFeed -ExpectedSha256 $hash | Out-Null
        if(-not $?){throw 'No se pudo crear latest.json de publicación'}
    }
    # Verify the Ed25519 Minisign signature over the exact installer bytes,
    # its signed trusted comment and the immutable latest.json feed, not just
    # that files exist or have matching names/sizes.
    Invoke-Checked 'node.exe' @((Join-Path $PSScriptRoot 'Verify-Coco2SignedSetup.mjs'),$candidateExe)
    if($FinalizeExisting){
        # The post-promotion test also verifies the NSIS intermediate next to
        # the feed. Use the already verified immutable signature for both.
        Copy-Item -LiteralPath $candidateSig -Destination $signatureSource -Force
    }
    # Extract and verify the newly built PE/NSIS/ZeroTier payload in TEMP,
    # including version and integrity, BEFORE touching public Setup. The
    # test never runs the installer, games, services or the user's registry.
    $env:COCO2_QA_SETUP_CANDIDATE=$candidateExe
    try {
        Invoke-Checked 'node.exe' @('--test',(Join-Path $root 'tests\installed-release-synthetic-v6.test.mjs'))
    } finally {
        Remove-Item Env:COCO2_QA_SETUP_CANDIDATE -ErrorAction SilentlyContinue
    }
    # Promote on the same volume using File.Replace (atomic per file). A
    # failed promotion or verification restores the previous complete pair.
    # Only exact self-generated staging/backup paths are ever deleted.
    $id=[Guid]::NewGuid().ToString('N')
    $stage=Join-Path $distribution ('.CocoLauncher2-stage-'+$id+'.exe')
    $stageSig=$stage+'.sig'
    $backup=Join-Path $distribution ('.CocoLauncher2-previous-'+$id+'.exe')
    $backupSig=$backup+'.sig'
    # File.Replace requires a real backup path on Windows PowerShell 5.1 even
    # when replacing during rollback. Never pass $null here: it can raise
    # ArgumentException and strand a half-promoted release pair.
    $rejected=Join-Path $distribution ('.CocoLauncher2-rejected-'+$id+'.exe')
    $rejectedSig=$rejected+'.sig'
    $hadSetup=Test-Path -LiteralPath $destination -PathType Leaf
    $hadSig=Test-Path -LiteralPath ($destination+'.sig') -PathType Leaf
    if($hadSetup -ne $hadSig){throw 'Instalador anterior incompleto; preservar sin sobrescribir'}
    $previousHash=if($hadSetup){(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}else{''}
    $previousSigHash=if($hadSig){(Get-FileHash -LiteralPath ($destination+'.sig') -Algorithm SHA256).Hash}else{''}
    foreach($target in @($destination,($destination+'.sig'))){
        if(Test-Path -LiteralPath $target){
            if((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){
                throw 'Instalador destino es un enlace/reparse: no reemplazar'
            }
        }
    }
    $promoted=$false
    $rolledBack=$false
    try {
        Copy-Item -LiteralPath $candidateExe -Destination $stage -ErrorAction Stop
        Copy-Item -LiteralPath $candidateSig -Destination $stageSig -ErrorAction Stop
        if((Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash -cne $hash -or
           (Get-FileHash -LiteralPath $stageSig -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $candidateSig -Algorithm SHA256).Hash){
            throw 'El candidato cambió mientras se preparaba la promoción'
        }
        if($hadSetup){
            [IO.File]::Replace($stage,$destination,$backup,$true)
            [IO.File]::Replace($stageSig,($destination+'.sig'),$backupSig,$true)
        }else{
            [IO.File]::Move($stage,$destination)
            [IO.File]::Move($stageSig,($destination+'.sig'))
        }
        Invoke-Checked 'node.exe' @((Join-Path $PSScriptRoot 'Verify-Coco2SignedSetup.mjs'))
        # Verify the promoted exact pair and guarded associations too; failed
        # post-promotion QA is handled by the existing atomic rollback below.
        Invoke-Checked 'node.exe' @('--test',(Join-Path $root 'tests\installed-nsis-v6.test.mjs'))
        $promoted=$true
    }catch{
        if($hadSetup){
            if(Test-Path -LiteralPath $backup -PathType Leaf){
                if(Test-Path -LiteralPath $destination -PathType Leaf){[IO.File]::Replace($backup,$destination,$rejected,$true)}
                else{[IO.File]::Move($backup,$destination)}
            }
            if(Test-Path -LiteralPath $backupSig -PathType Leaf){
                if(Test-Path -LiteralPath ($destination+'.sig') -PathType Leaf){[IO.File]::Replace($backupSig,($destination+'.sig'),$rejectedSig,$true)}
                else{[IO.File]::Move($backupSig,($destination+'.sig'))}
            }
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $previousHash -or
               (Get-FileHash -LiteralPath ($destination+'.sig') -Algorithm SHA256).Hash -cne $previousSigHash){
                throw 'Rollback: no se restauró el par instalador/firma original; conservar los respaldos para recuperación manual'
            }
        }else{
            foreach($target in @($destination,($destination+'.sig'))){
                if(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
            }
        }
        $rolledBack=$true
        throw
    }finally{
        foreach($tmp in @($stage,$stageSig)){
            if(Test-Path -LiteralPath $tmp -PathType Leaf){Remove-Item -LiteralPath $tmp -Force}
        }
        if($promoted -or $rolledBack){
            foreach($tmp in @($backup,$backupSig,$rejected,$rejectedSig)){
                if(Test-Path -LiteralPath $tmp -PathType Leaf){Remove-Item -LiteralPath $tmp -Force}
            }
        }
    }
    # Reclaim only the exact intermediate installer/signature from THIS build,
    # and only after byte-for-byte SHA verification against the promoted pair
    # AND immutable candidate. Do not delete older versions by filename alone:
    # those could be the last recovery copy of a distinct, legitimate release.
    $intermediates=@($source.FullName,$signatureSource)
    $promotedPair=@($destination,($destination+'.sig'))
    $candidatePair=@($candidateExe,$candidateSig)
    $oldNsis=@()
    for($i=0;$i -lt $intermediates.Count;$i++){
        $intermediate=Get-Item -LiteralPath $intermediates[$i] -ErrorAction Stop
        $public=Get-Item -LiteralPath $promotedPair[$i] -ErrorAction Stop
        $retained=Get-Item -LiteralPath $candidatePair[$i] -ErrorAction Stop
        foreach($check in @($intermediate,$public,$retained)){
            if($check.Attributes -band [IO.FileAttributes]::ReparsePoint){
                throw 'No eliminar copias NSIS: se detectó un enlace/reparse'
            }
        }
        $sameLength=$intermediate.Length -eq $public.Length -and $intermediate.Length -eq $retained.Length
        $sameHash=(Get-FileHash -LiteralPath $intermediate.FullName -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath $public.FullName -Algorithm SHA256).Hash -and
            (Get-FileHash -LiteralPath $intermediate.FullName -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath $retained.FullName -Algorithm SHA256).Hash
        if(-not $sameLength -or -not $sameHash){throw 'No eliminar copias NSIS: no son idénticas al candidato firmado'}
        $oldNsis+=@($intermediate)
    }
    $cleanedBytes=0L
    foreach($old in $oldNsis){
        $cleanedBytes+=$old.Length
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
    }
    if($oldNsis.Count){Write-Host "Duplicados NSIS verificados retirados: $($oldNsis.Count) ($([Math]::Round($cleanedBytes/1MB,1)) MiB)."}
    Write-Host "Setup listo: $destination" -ForegroundColor Magenta
    Write-Host ('Tamaño: {0:N2} MiB' -f ((Get-Item -LiteralPath $destination).Length/1MB))
    Write-Host "Verificación interna: $hash"
    Write-Host 'Firma de actualización generada junto al instalador.'
    Write-Host "Release candidato (SIN subir): $candidateDir"
    Write-Host 'Para tus amigos, comparte solo CocoLauncher2-Setup.exe.'
    Write-Host 'Para instalación sin ventanas de asistente: CocoLauncher2-Setup.exe /S'
} finally {
    Pop-Location
    if($createdPlayerLink){
        try {
            $link=Get-Item -LiteralPath $playerLink -Force -ErrorAction SilentlyContinue
            if($link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [string]$link.Target -ceq [string]$playerRuntime){
                # RemoveDirectory on a junction removes only the link, not its target.
                [IO.Directory]::Delete($playerLink)
            }
        } catch {
            Write-Warning "No se pudo retirar el enlace temporal $playerLink : $_"
        }
    }
    $env:TEMP=$previousTemp
    $env:TMP=$previousTmp
    try {
        $resolvedBuildTemp=(Resolve-Path -LiteralPath $buildTemp -ErrorAction Stop).Path
        if($resolvedBuildTemp -cne $buildTemp -or
            (Split-Path $resolvedBuildTemp -Parent) -cne $buildTempParent -or
            (Split-Path $resolvedBuildTemp -Leaf) -notmatch '^coco2-build-[a-f0-9]{32}$'){
            throw 'Ruta temporal inesperada; no borrar'
        }
        if((Get-Item -LiteralPath $resolvedBuildTemp).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Temporal enlazado; no borrar'}
        if(@(Get-ChildItem -LiteralPath $resolvedBuildTemp -Recurse -Force -Attributes ReparsePoint -ErrorAction Stop).Count){throw 'Enlaces dentro del temporal; no borrar'}
        Remove-Item -LiteralPath $resolvedBuildTemp -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "No se pudo limpiar el workspace propio $buildTemp : $_"
    }
}
