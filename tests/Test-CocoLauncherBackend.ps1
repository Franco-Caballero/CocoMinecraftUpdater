[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))
$testRoot=Join-Path $env:TEMP "coco-launcher-backend-$([guid]::NewGuid())"
try{
    $payload=Join-Path $testRoot 'payload'
    New-Item -ItemType Directory -Path $payload -Force|Out-Null
    $fakeLauncher=Join-Path $payload 'portablemc.exe'
    Add-Type -TypeDefinition @'
using System;
public static class FakePortableMc {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--version") {
            Console.WriteLine("portablemc 99.0.0");
            Console.WriteLine("commit: abcdef1 (test)");
            return 0;
        }
        return 2;
    }
}
'@ -OutputType ConsoleApplication -OutputAssembly $fakeLauncher
    $executableHash=(Get-FileHash $fakeLauncher -Algorithm SHA256).Hash.ToLowerInvariant()
    $executableSize=(Get-Item $fakeLauncher).Length
    $archive=Join-Path $testRoot 'backend.zip'
    Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $archive
    $hash=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=[pscustomobject]@{backend=[pscustomobject]@{
        id='portablemc';version='99.0.0';commit='abcdef1';url='https://example.invalid/backend.zip';sha256=$hash;size=(Get-Item $archive).Length
        executable='portablemc.exe';executableSha256=$executableHash;executableSize=$executableSize
        versionOutputPattern='(?ms)^portablemc 99\.0\.0\r?$.*^commit: abcdef1 '
        signatureUrl='https://example.invalid/backend.zip.sig';signatureSha256=('b'*64);signatureSize=1;pgpFingerprint=('a'*40);license='test';source='test'
    }}
    $installed=Install-CocoLauncherBackend $catalog $testRoot $archive
    if(-not(Test-Path -LiteralPath $installed)){throw 'El backend transaccional no quedo instalado.'}
    if(-not(Test-CocoLauncherBackendInstallation $catalog.backend (Split-Path $installed -Parent))){throw 'El backend instalado no pasa hash, tamano, version y commit.'}
    if(-not(Test-Path -LiteralPath (Join-Path (Split-Path $installed -Parent) 'COCO-BACKEND-NOTICE.txt'))){throw 'Falta la atribucion del backend.'}
    $second=Install-CocoLauncherBackend $catalog $testRoot $archive
    if(-not[string]::Equals($installed,$second,[StringComparison]::OrdinalIgnoreCase)){throw 'La instalacion valida no fue reutilizada.'}

    $malicious=Join-Path $testRoot 'malicious'
    New-Item -ItemType Directory -Path $malicious -Force|Out-Null
    $maliciousZip=Join-Path $malicious 'bad.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream=[IO.File]::Open($maliciousZip,[IO.FileMode]::Create)
    try{
        $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try{
            $entry=$zip.CreateEntry('../escape.exe')
            $writer=New-Object IO.StreamWriter($entry.Open())
            try{$writer.Write('bad')}finally{$writer.Dispose()}
        }finally{$zip.Dispose()}
    }finally{$stream.Dispose()}
    $rejected=$false
    try{Expand-CocoLauncherBackendArchive $maliciousZip (Join-Path $malicious 'expanded')}catch{$rejected=$_.Exception.Message-match'insegura'}
    if(-not$rejected){throw 'El ZIP del backend acepto traversal.'}
    'PASS: backend con doble hash, tamano, version/commit, instalacion transaccional y defensa Zip Slip validado.'
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
