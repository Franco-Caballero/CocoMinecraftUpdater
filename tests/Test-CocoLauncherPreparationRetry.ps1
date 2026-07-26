$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcherText=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'))
. ([ScriptBlock]::Create($launcherText))

$testRoot=Join-Path $env:TEMP ('coco-launcher-preparation-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    $fake=Join-Path $testRoot 'fake-portablemc.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class FakePreparation {
    public static int Main(string[] args) {
        string marker=Environment.GetEnvironmentVariable("COCO_PREPARATION_RETRY_MARKER");
        if (!File.Exists(marker)) { File.WriteAllText(marker,"first failed"); Console.Error.WriteLine("transient network failure"); return 7; }
        Console.WriteLine("prepared"); return 0;
    }
}
'@ -OutputType ConsoleApplication -OutputAssembly $fake
    $env:COCO_PREPARATION_RETRY_MARKER=Join-Path $testRoot 'attempt.marker'
    $result=Invoke-CocoPortableMcPreparation $fake @('start','forge::1.20.1-47.4.10') test-pack 3
    if($result.ExitCode-ne0-or$result.Arguments-notcontains'--dry'){throw 'La preparacion no reintento en modo seco.'}
    'PASS: la preparacion reanuda tras un fallo transitorio y conserva --dry.'
}finally{
    Remove-Item Env:COCO_PREPARATION_RETRY_MARKER -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
