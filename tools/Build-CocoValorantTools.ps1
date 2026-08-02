[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'release\experience-assets')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$modRoot = Join-Path $root 'forge-mod'
$lockPath = Join-Path $root 'launcher\experiences\valorant-craft.lock.json'

if (-not (Test-Path -LiteralPath (Join-Path $modRoot 'gradlew.bat') -PathType Leaf)) {
    throw 'Falta el wrapper Gradle de forge-mod.'
}

function Test-Java17Home {
    param([Parameter(Mandatory = $true)][string]$JdkPath)
    $java = Join-Path $JdkPath 'bin\java.exe'
    if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
        return $false
    }
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $version = (& $java -version 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    return $version -match 'version "17[.]'
}

$javaHomes = New-Object System.Collections.Generic.List[string]
if ($env:JAVA_HOME) { $javaHomes.Add([string]$env:JAVA_HOME) }
$gradleJdks = Join-Path $env:USERPROFILE '.gradle\jdks'
if (Test-Path -LiteralPath $gradleJdks -PathType Container) {
    foreach ($candidate in @(Get-ChildItem -LiteralPath $gradleJdks -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object Name -match '^jdk-17')) {
        $javaHomes.Add($candidate.FullName)
    }
}
$java17Home = @($javaHomes | Select-Object -Unique | Where-Object { Test-Java17Home $_ } | Select-Object -First 1)
if (-not $java17Home) {
    throw 'No se encontro Java 17 para compilar forge-mod. Instala Java 17 o deja un JDK 17 en JAVA_HOME/.gradle/jdks.'
}
$env:JAVA_HOME = [string]$java17Home

Push-Location $modRoot
try {
    & (Join-Path $modRoot 'gradlew.bat') build --no-daemon
    if ($LASTEXITCODE) { throw "Gradle forge-mod termino con codigo $LASTEXITCODE." }
}
finally {
    Pop-Location
}

$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$asset = @($lock.assets | Where-Object path -eq 'mods/coco-valorant-tools-0.1.0.jar') | Select-Object -First 1
if (-not $asset) { throw 'El lock no declara el JAR de Coco VALORANT Tools.' }
$jar = Get-Item -LiteralPath (Join-Path $modRoot 'build\libs\coco-valorant-tools-0.1.0.jar') -ErrorAction Stop
$hash = (Get-FileHash -LiteralPath $jar.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($jar.Length -ne [int64]$asset.size -or $hash -ne ([string]$asset.sha256).ToLowerInvariant()) {
    throw "El JAR compilado no coincide con el lock: size=$($jar.Length), sha256=$hash."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$destination = Join-Path $OutputDirectory $jar.Name
Copy-Item -LiteralPath $jar.FullName -Destination $destination -Force
Write-Host "JAR Coco VALORANT Tools listo: $destination ($hash)" -ForegroundColor Green
