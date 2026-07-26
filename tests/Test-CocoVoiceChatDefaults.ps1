[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $root 'engine\CocoLauncher.ps1'),[Text.Encoding]::UTF8)))
$testRoot=Join-Path $env:TEMP "coco-voice-$([guid]::NewGuid().ToString('N'))"
try{
    $instance=Join-Path $testRoot 'fabric';$mods=Join-Path $instance 'mods'
    New-Item -ItemType Directory -Path $mods -Force|Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $jar=Join-Path $mods 'asset_416089_8280439.jar'
    $stream=[IO.File]::Open($jar,[IO.FileMode]::Create)
    $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        $entry=$archive.CreateEntry('fabric.mod.json')
        $writer=[IO.StreamWriter]::new($entry.Open(),(New-Object Text.UTF8Encoding($false)))
        try{$writer.Write('{"schemaVersion":1,"id":"voicechat","version":"1.20.1-2.6.19","name":"Simple Voice Chat"}')}finally{$writer.Dispose()}
    }finally{$archive.Dispose();$stream.Dispose()}

    $config=Join-Path $instance 'config\voicechat\voicechat-client.properties'
    New-Item -ItemType Directory -Path (Split-Path $config -Parent) -Force|Out-Null
    @'
# Existing values from a completed local wizard
config_version=1
onboarding_finished=false
microphone=OpenAL Soft on Private Microphone
speaker=OpenAL Soft on Private Headset
microphone_activation_type=PTT
automatic_gain_control=false
denoiser=false
muted=true
disabled=true
custom_future_key=preserved
'@|Set-Content -LiteralPath $config -Encoding UTF8

    $result=Set-CocoVoiceChatDefaults $instance
    if(-not$result.Detected-or$result.Adapter-ne'simple-voice-chat'-or-not$result.Changed){throw 'No se detecto Simple Voice Chat por su ID interno dentro de un JAR generico.'}
    $values=@{}
    foreach($line in Get-Content -LiteralPath $config){
        if($line-match'^([^#=]+)=(.*)$'){$values[$matches[1]]=$matches[2]}
    }
    $expected=[ordered]@{
        onboarding_finished='true';microphone='';speaker='';microphone_activation_type='VOICE'
        voice_activity_detection='true';voice_activation_threshold='-50.0';microphone_gain='0.0'
        automatic_gain_control='true';denoiser='true';muted='false';disabled='false'
        run_local_server='true';use_natives='true';custom_future_key='preserved'
    }
    foreach($key in $expected.Keys){
        if(-not$values.ContainsKey($key)-or[string]$values[$key]-cne[string]$expected[$key]){throw "Valor de voz incorrecto: $key='$($values[$key])'."}
    }
    if(Test-Path -LiteralPath (Join-Path $instance 'config\voicechat-client.properties')){throw 'Coco escribio la ruta raiz antigua que Simple Voice Chat no lee.'}
    $second=Set-CocoVoiceChatDefaults $instance
    if($second.Changed){throw 'La configuracion de voz correcta se reescribio sin necesidad.'}

    $plain=Join-Path $testRoot 'without-voice';New-Item -ItemType Directory -Path (Join-Path $plain 'mods') -Force|Out-Null
    $none=Set-CocoVoiceChatDefaults $plain
    if($none.Detected-or(Test-Path -LiteralPath (Join-Path $plain 'config\voicechat\voicechat-client.properties'))){throw 'Coco creo configuracion de voz en una experiencia sin el mod.'}
    $network=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoNetwork.ps1'))
    $elevated=[IO.File]::ReadAllText((Join-Path $root 'engine\CocoNetworkElevated.ps1'))
    $releaseBuilder=[IO.File]::ReadAllText((Join-Path $root 'tools\New-CocoJarRelease.ps1'))
    foreach($text in $network,$elevated,$releaseBuilder){
        if($text-notmatch'25565'-or$text-notmatch'Coco Voice LAN - ZeroTier UDP 25565'){throw 'La red publicada no declara la regla privada de voz UDP 25565 usada por la LAN integrada.'}
    }
    if($elevated-notmatch'(?s)New-NetFirewallRule.*?Protocol UDP.*?voicePort.*?RemoteAddress \$config\.subnet.*?Profile Private'){
        throw 'La regla elevada de voz no queda limitada a UDP, subred Coco y perfil privado.'
    }
    'PASS: Simple Voice Chat se detecta por metadata y queda sin wizard, en dispositivos default, VOICE, AGC, denoiser y microfono activo.'
}finally{
    if(Test-Path -LiteralPath $testRoot){
        [GC]::Collect();[GC]::WaitForPendingFinalizers()
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
