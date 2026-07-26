[CmdletBinding()]
param(
    [ValidateSet('Missing','Configured')]
    [string]$IdentityState='Missing',
    [switch]$SmokeTest
)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:UiFonts=@{}
function Get-UiFont([string]$Family,[single]$Size,[Drawing.FontStyle]$Style=[Drawing.FontStyle]::Regular){
    $key="$Family|$Size|$([int]$Style)"
    if(-not$script:UiFonts.ContainsKey($key)){$script:UiFonts[$key]=New-Object Drawing.Font($Family,$Size,$Style)}
    $script:UiFonts[$key]
}
function Set-FittedText($Label,[string]$Text,[single]$Maximum,[single]$Minimum,[Drawing.FontStyle]$Style=[Drawing.FontStyle]::Regular){
    $Label.Text=$Text
    for($size=$Maximum;$size-ge$Minimum;$size-=0.5){
        $font=Get-UiFont 'Segoe UI' $size $Style
        $measured=[Windows.Forms.TextRenderer]::MeasureText($Text,$font,$Label.ClientSize,[Windows.Forms.TextFormatFlags]::WordBreak)
        if($measured.Width-le$Label.ClientSize.Width-and$measured.Height-le$Label.ClientSize.Height){$Label.Font=$font;return}
    }
    $Label.Font=Get-UiFont 'Segoe UI' $Minimum $Style
}
function Set-FlatButton($Button,[Drawing.Color]$Back,[Drawing.Color]$Fore){
    $Button.FlatStyle='Flat';$Button.FlatAppearance.BorderSize=0;$Button.BackColor=$Back;$Button.ForeColor=$Fore
    $Button.Font=Get-UiFont 'Segoe UI Semibold' 9.5;$Button.Cursor='Hand';$Button.UseCompatibleTextRendering=$true
}

$purple=[Drawing.Color]::FromArgb(177,92,255)
$deep=[Drawing.Color]::FromArgb(22,13,37)
$surface=[Drawing.Color]::FromArgb(36,22,57)
$muted=[Drawing.Color]::FromArgb(58,36,81)
$light=[Drawing.Color]::FromArgb(224,190,255)
$text=[Drawing.Color]::FromArgb(218,210,229)
$green=[Drawing.Color]::FromArgb(78,214,132)

$form=New-Object Windows.Forms.Form
$key=[Drawing.Color]::FromArgb(1,2,3)
$form.Text='Coco Launcher';$form.Size=New-Object Drawing.Size(1080,740);$form.StartPosition='CenterScreen'
$form.FormBorderStyle='None';$form.MaximizeBox=$false;$form.ShowInTaskbar=$true;$form.TopMost=$true
$form.BackColor=$key;$form.TransparencyKey=$key;$form.ForeColor=[Drawing.Color]::White
try{$form.Icon=New-Object Drawing.Icon((Join-Path (Split-Path $PSScriptRoot -Parent) 'reynaico.ico'))}catch{}

$panel=New-Object Windows.Forms.Panel;$panel.Location=New-Object Drawing.Point(25,180);$panel.Size=New-Object Drawing.Size(640,470);$panel.BackColor=$deep
$accent=New-Object Windows.Forms.Panel;$accent.Location=New-Object Drawing.Point(0,0);$accent.Size=New-Object Drawing.Size(9,470);$accent.BackColor=$purple
$title=New-Object Windows.Forms.Label;$title.Location=New-Object Drawing.Point(43,30);$title.Size=New-Object Drawing.Size(570,72);$title.ForeColor=$light;$title.Font=Get-UiFont 'Segoe UI' 22 ([Drawing.FontStyle]::Bold);$title.UseCompatibleTextRendering=$true
$detail=New-Object Windows.Forms.Label;$detail.Location=New-Object Drawing.Point(46,106);$detail.Size=New-Object Drawing.Size(570,76);$detail.ForeColor=$text;$detail.Font=Get-UiFont 'Segoe UI' 12;$detail.UseCompatibleTextRendering=$true
$track=New-Object Windows.Forms.Panel;$track.Location=New-Object Drawing.Point(46,190);$track.Size=New-Object Drawing.Size(570,30);$track.BackColor=$muted
$fill=New-Object Windows.Forms.Panel;$fill.Location=New-Object Drawing.Point(0,0);$fill.Size=New-Object Drawing.Size(4,30);$fill.BackColor=$purple;$track.Controls.Add($fill)
$sparkle=[char]0x2726
$brand=New-Object Windows.Forms.Label;$brand.Text="$sparkle  COCO LAUNCHER  |  UNA PARTIDA ACTIVA";$brand.Location=New-Object Drawing.Point(46,240);$brand.Size=New-Object Drawing.Size(570,25);$brand.ForeColor=$purple;$brand.Font=Get-UiFont 'Segoe UI Semibold' 10
$dynamic=New-Object Windows.Forms.Panel;$dynamic.Location=New-Object Drawing.Point(46,270);$dynamic.Size=New-Object Drawing.Size(570,100)
$session=New-Object Windows.Forms.Label;$session.Location=New-Object Drawing.Point(0,4);$session.Size=New-Object Drawing.Size(550,70);$session.Text="INTO THE BACKROOMS`r`nPartida de smolbird | 10.77.37.1:25565 | Conexion privada";$session.ForeColor=$text;$session.Font=Get-UiFont 'Segoe UI' 10;$session.UseCompatibleTextRendering=$true;$dynamic.Controls.Add($session)
$identityCard=New-Object Windows.Forms.Panel;$identityCard.Location=New-Object Drawing.Point(46,378);$identityCard.Size=New-Object Drawing.Size(445,70);$identityCard.BackColor=$muted;$identityCard.AllowDrop=$true
$skinPicture=New-Object Windows.Forms.PictureBox;$skinPicture.Location=New-Object Drawing.Point(6,6);$skinPicture.Size=New-Object Drawing.Size(58,58);$skinPicture.SizeMode='Zoom';$skinPicture.BackColor=$surface;$skinPicture.Cursor='Hand';$skinPicture.AllowDrop=$true
$identityHeading=New-Object Windows.Forms.Label;$identityHeading.Text='TU IDENTIDAD COCO';$identityHeading.Location=New-Object Drawing.Point(76,5);$identityHeading.Size=New-Object Drawing.Size(195,18);$identityHeading.ForeColor=$light;$identityHeading.Font=Get-UiFont 'Segoe UI Semibold' 8.5
$identityText=New-Object Windows.Forms.TextBox;$identityText.Location=New-Object Drawing.Point(76,25);$identityText.Size=New-Object Drawing.Size(195,25);$identityText.MaxLength=16;$identityText.Font=Get-UiFont 'Segoe UI' 10
$identityStatus=New-Object Windows.Forms.Label;$identityStatus.Location=New-Object Drawing.Point(76,52);$identityStatus.Size=New-Object Drawing.Size(195,15);$identityStatus.Font=Get-UiFont 'Segoe UI' 7.5
$skinHeading=New-Object Windows.Forms.Label;$skinHeading.Text='TU SKIN';$skinHeading.Location=New-Object Drawing.Point(286,7);$skinHeading.Size=New-Object Drawing.Size(145,17);$skinHeading.ForeColor=$light;$skinHeading.Font=Get-UiFont 'Segoe UI Semibold' 8.5;$skinHeading.Cursor='Hand';$skinHeading.AllowDrop=$true
$skinLabel=New-Object Windows.Forms.Label;$skinLabel.Location=New-Object Drawing.Point(286,26);$skinLabel.Size=New-Object Drawing.Size(150,38);$skinLabel.Text="CLIC O ARRASTRA UN PNG`r`nPARA ELEGIRLA";$skinLabel.ForeColor=$light;$skinLabel.Font=Get-UiFont 'Segoe UI Semibold' 7.5;$skinLabel.Cursor='Hand';$skinLabel.AllowDrop=$true
$identityCard.Controls.AddRange(@($skinPicture,$identityHeading,$identityText,$identityStatus,$skinHeading,$skinLabel))
$close=New-Object Windows.Forms.Button;$close.Text='CERRAR';$close.Location=New-Object Drawing.Point(501,395);$close.Size=New-Object Drawing.Size(115,36);Set-FlatButton $close $muted $text
$close.Add_Click({$form.Close()})
$panel.Controls.AddRange(@($accent,$title,$detail,$track,$brand,$dynamic,$identityCard,$close));$form.Controls.Add($panel)

$art=New-Object Windows.Forms.PictureBox;$art.Location=New-Object Drawing.Point(675,5);$art.Size=New-Object Drawing.Size(380,720);$art.SizeMode='Zoom';$art.BackColor=[Drawing.Color]::Transparent
try{$art.Image=[Drawing.Image]::FromFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'fullbody.png'))}catch{}
$form.Controls.Add($art)

$script:username=if($IdentityState-eq'Configured'){'AmigoCoco'}else{''}
$script:confirmedUsername=$script:username
$identityText.Text=$script:username
$script:clock=[Diagnostics.Stopwatch]::new()
$duration=if($SmokeTest){0.9}else{6.0}
$stages=@(
    @{At=0.00;Progress=5;Title='INICIANDO COCO LAUNCHER';Detail='Comprobando el ejecutable, el engine y la version instalada.';State='Componentes locales verificados.'},
    @{At=0.10;Progress=16;Title='PREPARANDO LA RED PRIVADA';Detail='Verificando ZeroTier, el adaptador privado, la autorizacion del equipo y la ruta hacia 10.77.37.1.';State='Conexion privada en preparacion.'},
    @{At=0.20;Progress=25;Title='PARTIDA DETECTADA';Detail='Se encontro una sesion activa de Into The Backrooms alojada por smolbird.';State='Partida encontrada.'},
    @{At=0.30;Progress=42;Title='DESCARGANDO INTO THE BACKROOMS';Detail='Archivo 47/184 | sodium-extra.jar | 186,4 MB de 612,8 MB | 8,7 MB/s.';State='Descarga verificada por hash.'},
    @{At=0.50;Progress=61;Title='INSTALANDO LA INSTANCIA AISLADA';Detail='Archivo 131/184 | ya verificado: config/backrooms-client.json. Mundos e inventarios permanecen protegidos.';State='Aplicando archivos administrados.'},
    @{At=0.67;Progress=78;Title='PREPARANDO MINECRAFT';Detail='Verificando Java 17, Fabric Loader 0.19.3 y los assets oficiales.';State='Runtime de Minecraft listo.'},
    @{At=0.77;Progress=88;Title='JUGADOR LISTO';Detail='La identidad local estable conserva inventario, avances y permisos.';State='Identidad verificada.'},
    @{At=0.84;Progress=92;Title='ABRIENDO MINECRAFT';Detail='Iniciando Into The Backrooms y preparando el ingreso directo a la partida.';State='Proceso de Minecraft iniciado.'},
    @{At=0.92;Progress=97;Title='CONECTANDO AUTOMATICAMENTE';Detail='Minecraft se esta conectando a Coco - Backrooms mediante 10.77.37.1:25565.';State='Esperando confirmacion del juego.'},
    @{At=1.00;Progress=100;Title='TODO LISTO';Detail='Minecraft esta conectado a Coco - Backrooms.';State='Partida iniciada correctamente.'}
)

$validateIdentity={
    $candidate=([string]$identityText.Text).Trim()
    $valid=$candidate-match'^[A-Za-z0-9_]{3,16}$';$confirmed=$valid-and$candidate-eq$script:confirmedUsername
    $identityStatus.Text=if($confirmed){'Nombre valido.'}elseif($valid){'Pulsa Enter para confirmar.'}else{'3-16 letras, numeros o _.'}
    $identityStatus.ForeColor=if($confirmed){$green}elseif($valid){$light}else{[Drawing.Color]::FromArgb(255,139,151)}
    $valid
}
$saveIdentity={
    $candidate=([string]$identityText.Text).Trim()
    if($candidate-match'^[A-Za-z0-9_]{3,16}$'){
        $script:username=$candidate;$script:confirmedUsername=$candidate;$identityStatus.Text='Nombre valido.';$identityStatus.ForeColor=$green
        if($script:clock-and-not$script:clock.IsRunning-and$script:clock.Elapsed.TotalSeconds-ge($duration*0.77)){$script:clock.Start()}
        return $true
    }
    [void](&$validateIdentity);$false
}
$identityText.Add_TextChanged({[void](&$validateIdentity)})
$identityText.Add_Leave({[void](&$saveIdentity)})
$identityText.Add_KeyDown({param($sender,$eventArgs)if($eventArgs.KeyCode-eq'Enter'){$eventArgs.SuppressKeyPress=$true;[void](&$saveIdentity)}})
[void](&$validateIdentity)
$applyVisualSkin={
    param([string]$Path)
    try{
        if(-not(&$saveIdentity)){[void]$identityText.Focus();throw 'ESCRIBE PRIMERO UN NOMBRE VALIDO'}
        if(-not(Test-Path -LiteralPath $Path -PathType Leaf)-or(Get-Item -LiteralPath $Path).Length-gt1048576){throw 'PNG INVALIDO'}
        $bytes=[IO.File]::ReadAllBytes($Path);$memory=[IO.MemoryStream]::new($bytes,$false);$source=$null
        try{
            $source=[Drawing.Bitmap]::new($memory)
            if($source.RawFormat.Guid-ne[Drawing.Imaging.ImageFormat]::Png.Guid-or$source.Width-ne64-or$source.Height-notin@(32,64)){throw 'USA 64x64 O 64x32'}
            $preview=[Drawing.Bitmap]::new(58,58,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics=[Drawing.Graphics]::FromImage($preview)
            try{
                $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::NearestNeighbor;$graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::Half
                $graphics.DrawImage($source,[Drawing.Rectangle]::new(0,0,58,58),[Drawing.Rectangle]::new(8,8,8,8),[Drawing.GraphicsUnit]::Pixel)
                if($source.Height-ge64){$graphics.DrawImage($source,[Drawing.Rectangle]::new(0,0,58,58),[Drawing.Rectangle]::new(40,8,8,8),[Drawing.GraphicsUnit]::Pixel)}
            }finally{$graphics.Dispose()}
            if($skinPicture.Image){$old=$skinPicture.Image;$skinPicture.Image=$null;$old.Dispose()};$skinPicture.Image=$preview
        }finally{if($source){$source.Dispose()};$memory.Dispose()}
        $skinLabel.ForeColor=$light;$skinLabel.Text="SE SINCRONIZARA AL JUGAR`r`nCLIC O ARRASTRA PARA CAMBIAR"
    }catch{$skinLabel.ForeColor=[Drawing.Color]::FromArgb(255,139,151);$skinLabel.Text="NO SE PUDO USAR`r`n$($_.Exception.Message)"}
}
$chooseVisualSkin={
    $dialog=New-Object Windows.Forms.OpenFileDialog
    try{$dialog.Title='Elige tu skin de Minecraft';$dialog.Filter='Skin de Minecraft (*.png)|*.png';if($dialog.ShowDialog($form)-eq'OK'){&$applyVisualSkin $dialog.FileName}}finally{$dialog.Dispose()}
}
$skinDragEnter={param($sender,$eventArgs)$files=if($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)){@($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))}else{@()};$eventArgs.Effect=if($files.Count-eq1-and[IO.Path]::GetExtension([string]$files[0])-eq'.png'){'Copy'}else{'None'}}
$skinDragDrop={param($sender,$eventArgs)$files=@($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop));if($files.Count-eq1){&$applyVisualSkin ([string]$files[0])}}
foreach($control in @($identityCard,$skinPicture,$skinHeading,$skinLabel)){$control.Add_Click($chooseVisualSkin);$control.Add_DragEnter($skinDragEnter);$control.Add_DragDrop($skinDragDrop)}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=50
$timer.Add_Tick({
    $ratio=[Math]::Min(1.0,$script:clock.Elapsed.TotalSeconds/$duration)
    $index=0
    for($i=0;$i-lt$stages.Count;$i++){if($ratio-ge[double]$stages[$i].At){$index=$i}}
    $stage=$stages[$index]
    $nextStage=if($index-lt$stages.Count-1){$stages[$index+1]}else{$stage}
    $span=[Math]::Max(0.001,[double]$nextStage.At-[double]$stage.At)
    $within=[Math]::Min(1.0,[Math]::Max(0.0,($ratio-[double]$stage.At)/$span))
    $progress=[int]([double]$stage.Progress+(([double]$nextStage.Progress-[double]$stage.Progress)*$within))
    Set-FittedText $title ("ETAPA {0}/10 | {1}"-f($index+1),$stage.Title) 22 11 ([Drawing.FontStyle]::Bold)
    Set-FittedText $detail ([string]$stage.Detail) 12 8
    $fill.Width=[Math]::Max(6,[int]($track.ClientSize.Width*$progress/100));$fill.BackColor=if($progress-ge100){$green}else{$purple}
    $identityReady=(([string]$identityText.Text).Trim()-eq$script:confirmedUsername)-and($script:confirmedUsername-match'^[A-Za-z0-9_]{3,16}$')
    if($ratio-ge0.77-and-not$identityReady){
        if($script:clock.IsRunning){$script:clock.Stop()}
        Set-FittedText $detail 'La preparacion termino. Escribe un nombre valido en tu tarjeta para abrir Minecraft.' 12 8
        [void]$identityText.Focus()
        if($SmokeTest){$identityText.Text='CocoAudit';if(&$saveIdentity){$script:clock.Start()}}
    }
    $identityCard.Enabled=$ratio-lt0.84-or$ratio-ge1.0
    $close.Enabled=$ratio-lt0.30-or$ratio-ge1.0
    if($ratio-ge1.0){$timer.Stop();if($SmokeTest){$form.Close()}}
})

$script:threadFailure=$null
$threadHandler=[Threading.ThreadExceptionEventHandler]{param($sender,$eventArgs)$script:threadFailure=$eventArgs.Exception;$form.Close()}
[Windows.Forms.Application]::add_ThreadException($threadHandler)
$form.Add_Shown({$script:clock.Start();$timer.Start()})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose();if($art.Image){$art.Image.Dispose()}})
try{[Windows.Forms.Application]::Run($form)}
finally{
    [Windows.Forms.Application]::remove_ThreadException($threadHandler)
    foreach($font in @($script:UiFonts.Values)){if($font){$font.Dispose()}};$script:UiFonts.Clear()
}
if($script:threadFailure){throw $script:threadFailure}
