$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root=Split-Path $PSScriptRoot -Parent
if(-not(Test-Path (Join-Path $root 'tools\Publish-CocoRelease.ps1'))){[Windows.Forms.MessageBox]::Show('No se encontro el proyecto CocoMinecraftUpdater.','Coco Publisher');exit 1}

$mutex=New-Object Threading.Mutex($false,'Local\CocoMinecraftPublisher')
if(-not$mutex.WaitOne(0)){exit 0}
try{
    $latestFile=Join-Path $env:TEMP 'coco-publisher-latest.json'
    Invoke-WebRequest -Uri 'https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json' -OutFile $latestFile -UseBasicParsing
    $current=[version](Get-Content $latestFile -Raw|ConvertFrom-Json).version
    $next="$($current.Major).$($current.Minor).$($current.Build+1)"

    $form=New-Object Windows.Forms.Form;$form.Text='Publicar Coco Pack';$form.Size=New-Object Drawing.Size(760,390)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedSingle';$form.MaximizeBox=$false;$form.ControlBox=$false;$form.BackColor=[Drawing.Color]::FromArgb(22,13,37)
    $title=New-Object Windows.Forms.Label;$title.Text="Publicando Coco Pack $next";$title.Location=New-Object Drawing.Point(42,42);$title.Size=New-Object Drawing.Size(670,55)
    $title.Font=New-Object Drawing.Font('Segoe UI Semibold',24);$title.ForeColor=[Drawing.Color]::FromArgb(224,190,255)
    $detail=New-Object Windows.Forms.Label;$detail.Text='Preparando mods, Bridge, updater y GitHub...';$detail.Location=New-Object Drawing.Point(46,112);$detail.Size=New-Object Drawing.Size(650,38)
    $detail.Font=New-Object Drawing.Font('Segoe UI',12);$detail.ForeColor=[Drawing.Color]::White
    $track=New-Object Windows.Forms.Panel;$track.Location=New-Object Drawing.Point(48,180);$track.Size=New-Object Drawing.Size(650,30);$track.BackColor=[Drawing.Color]::FromArgb(58,36,81)
    $fill=New-Object Windows.Forms.Panel;$fill.Size=New-Object Drawing.Size(12,30);$fill.BackColor=[Drawing.Color]::FromArgb(177,92,255);$track.Controls.Add($fill)
    $note=New-Object Windows.Forms.Label;$note.Text='No cierres esta ventana. Se cerrara automaticamente al terminar.';$note.Location=New-Object Drawing.Point(48,245);$note.Size=New-Object Drawing.Size(650,30)
    $note.Font=New-Object Drawing.Font('Segoe UI',10);$note.ForeColor=[Drawing.Color]::FromArgb(177,92,255)
    $form.Controls.AddRange(@($title,$detail,$track,$note));$form.Show();[Windows.Forms.Application]::DoEvents()

    $stdout=Join-Path $env:TEMP 'coco-publisher.out.log';$stderr=Join-Path $env:TEMP 'coco-publisher.err.log'
    Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tools\Publish-CocoRelease.ps1'),'-Version',$next,'-KnownE4mcDomains','overdue-expend.cl.e4mc.link')
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not$process.HasExited){
        $seconds=$watch.Elapsed.TotalSeconds;$progress=[Math]::Min(94,[int](8+86*(1-[Math]::Exp(-$seconds/65))))
        $fill.Width=[Math]::Max(8,[int](6.5*$progress))
        if($seconds-lt15){$detail.Text='Compilando Bridge y preparando archivos...'}elseif($seconds-lt45){$detail.Text='Calculando mods y verificando hashes...'}else{$detail.Text='Subiendo la nueva version a GitHub...'}
        $form.Refresh();[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50;$process.Refresh()
    }
    if($process.ExitCode-ne0){
        $title.Text='No se pudo publicar';$title.ForeColor=[Drawing.Color]::FromArgb(255,120,150)
        $errorText=if(Test-Path $stderr){(Get-Content $stderr -Tail 8)-join' '}else{'Error desconocido.'}
        $detail.Text=$errorText;$note.Text='La ventana permanecera abierta para que puedas leer el error.';$form.ControlBox=$true;$form.Refresh()
        while($form.Visible){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100};exit $process.ExitCode
    }
    $fill.Width=650;$title.Text="Coco Pack $next publicado";$detail.Text='Todo listo. Tus amigos se actualizaran automaticamente.';$note.Text='Puedes cerrar esta ventana o esperar unos segundos.';$form.ControlBox=$true;$form.Refresh()
    $done=[Diagnostics.Stopwatch]::StartNew();while($done.Elapsed.TotalSeconds-lt8-and$form.Visible){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
    $form.Close();exit 0
}finally{if($mutex){$mutex.ReleaseMutex()|Out-Null;$mutex.Dispose()}}
