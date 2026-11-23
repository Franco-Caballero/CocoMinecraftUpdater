//! Keeps Windows Defender from quarantining game files while they download, unpack and run.
//! Exclusions need one UAC approval and cover game folders and Coco's cache, never a whole
//! drive or a personal folder. Defender does not let a normal user read its exclusions, so
//! what was added is remembered here and Windows is only asked about what is new.
//! The same approval lets each game's program through Windows Firewall, so a LAN game
//! never stops on «¿Quieres permitir que las redes accedan a esta aplicación?».
use crate::services::inventory;
use serde::{Deserialize,Serialize};
use serde_json::{Map,Value};
use std::fs;
use std::path::{Path,PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime,UNIX_EPOCH};
use tauri::{AppHandle,Emitter};

const STATE_FILE:&str="defender-exclusions.json";
const AUTHORIZATION_EVENT:&str="coco2://windows-authorization";
static PREPARATION:Mutex<()>=Mutex::new(());
/// The "zerotier:" lines of the last elevated run, so «Reparar conexión» can say what failed.
static LAST_ZEROTIER_LINES:Mutex<Vec<String>>=Mutex::new(Vec::new());
const DECLINED_RETRY_SECONDS:u64=6*60*60;
const UNAVAILABLE_RETRY_SECONDS:u64=7*24*60*60;
/// Folders next to a game hold its installation stage, a move in progress and kept saves.
const WORK_FOLDER_PATTERNS:&[&str]=&[".coco2-stage-*",".coco-moving-*",".coco-moved-*",".coco-uninstalling-*",".coco-kept-saves",".coco-downloads"];

#[derive(Debug,Default,Serialize,Deserialize)]
#[serde(rename_all="camelCase",default)]
struct State{paths:Vec<String>,retry_after:u64,network_retry_after:u64,firewall:Vec<String>}

fn retry_pending(state:&State,network:bool,timestamp:u64)->bool{
    timestamp<if network{state.network_retry_after}else{state.retry_after}
}

fn now()->u64{SystemTime::now().duration_since(UNIX_EPOCH).map(|time|time.as_secs()).unwrap_or_default()}

fn normalized(path:&str)->String{path.trim_end_matches(['\\','/']).to_lowercase()}

fn covered(path:&str,known:&[String])->bool{
    let path=normalized(path);
    known.iter().map(|entry|normalized(entry)).any(|entry|path==entry||path.starts_with(&format!("{entry}\\")))
}

fn is_local_absolute(path:&Path)->bool{
    path.is_absolute()&&!path.to_string_lossy().starts_with("\\\\")
}

/// Excluding Desktop or a whole drive because a game lives there would expose far more
/// than the game. Those parents only get Coco's own work folders.
fn too_broad(parent:&Path,home:Option<&Path>)->bool{
    if parent.parent().is_none(){return true;}
    let Some(home)=home else {return false};
    parent==home||parent.parent()==Some(home)||home.starts_with(parent)
}

fn add_game_folder(root:&Path,home:Option<&Path>,paths:&mut Vec<String>){
    if !is_local_absolute(root)||root.parent().is_none(){return;}
    paths.push(root.display().to_string());
    let Some(parent)=root.parent() else {return};
    if too_broad(parent,home){
        for pattern in WORK_FOLDER_PATTERNS{paths.push(parent.join(pattern).display().to_string());}
    }else{paths.push(parent.display().to_string());}
}

/// Everything a game can touch: both default folders, Coco's downloads and every location
/// the player chose, including the one an operation is about to use. Also the video engine
/// (`engine`, the install's `player` folder) and its repair copy: an antivirus otherwise scans
/// each of its modules again after every update before a film can start. Coco checks the
/// SHA-256 of every engine file before loading it, so nothing unverified runs from there.
fn desired_paths(app_data:&Path,local_data:&Path,locations:&Map<String,Value>,extra:&[PathBuf],home:Option<&Path>,engine:Option<&Path>)->Vec<String>{
    let mut paths=vec![
        app_data.join("CocoLauncher2").display().to_string(),
        app_data.join("CocoMinecraft").display().to_string(),
        local_data.join("CocoMinecraftUpdater").display().to_string(),
        local_data.join("CocoLauncher2").join("player-runtime").display().to_string(),
    ];
    if let Some(engine)=engine.filter(|path|is_local_absolute(path)&&path.parent().is_some()){paths.push(engine.display().to_string());}
    for value in locations.values().filter_map(Value::as_str){add_game_folder(Path::new(value),home,&mut paths);}
    for root in extra{add_game_folder(root,home,&mut paths);}
    let mut seen=Vec::new();
    paths.retain(|path|{let key=normalized(path);if seen.contains(&key){false}else{seen.push(key);true}});
    paths
}

fn powershell_literal(value:&str)->String{format!("'{}'",value.replace('\'',"''"))}

/// The programs of a game that open network ports: its executable and every other .exe it
/// declares (an Unreal `-Shipping.exe` behind a launcher). Crash reporters never listen.
pub(crate) fn game_programs<'a>(root:&Path,executable:&'a str,declared:impl IntoIterator<Item=&'a str>)->Vec<PathBuf>{
    let mut programs:Vec<PathBuf>=Vec::new();
    for relative in std::iter::once(executable).chain(declared){
        let lower=relative.to_ascii_lowercase();
        if !lower.ends_with(".exe")||lower.contains("crashhandler")||lower.contains("crashreport"){continue;}
        if relative.split(['/','\\']).any(|part|part==".."||part.is_empty()){continue;}
        let path=root.join(relative.replace('/',"\\"));
        if !programs.iter().any(|known|normalized(&known.display().to_string())==normalized(&path.display().to_string())){programs.push(path);}
    }
    programs
}

/// One allow rule per program, named after it so a repeat replaces instead of piling up.
/// Windows' own block rules for that program (left when someone pressed «Cancelar» on its
/// prompt) are removed: a block rule wins over any allow rule.
fn firewall_script(programs:&[String])->String{
    if programs.is_empty(){return String::new();}
    let list=programs.iter().map(|path|powershell_literal(path)).collect::<Vec<_>>().join(",");
    format!("foreach($g in @({list})){{try{{$n='Coco - '+$g;\
Get-NetFirewallApplicationFilter -Program $g -ErrorAction SilentlyContinue|Get-NetFirewallRule -ErrorAction SilentlyContinue|Where-Object{{$_.Direction -eq 'Inbound' -and $_.Action -eq 'Block'}}|Remove-NetFirewallRule -ErrorAction SilentlyContinue;\
Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction SilentlyContinue;\
New-NetFirewallRule -DisplayName $n -Direction Inbound -Action Allow -Program $g -Profile Any -ErrorAction Stop|Out-Null;$done+=('firewall:'+$g)}}catch{{$done+=('firewall:error:'+$_.Exception.Message)}}}};")
}

fn elevated_script(paths:&[String],result:&Path,extra:&str)->String{
    let list=paths.iter().map(|path|powershell_literal(path)).collect::<Vec<_>>().join(",");
    format!("$done=@();if(Get-Command Add-MpPreference -ErrorAction SilentlyContinue){{foreach($p in @({list})){{try{{Add-MpPreference -ExclusionPath $p -ErrorAction Stop;$done+=$p}}catch{{$done+=('error:'+$_.Exception.Message)}}}}}}else{{$done+='error:Add-MpPreference no existe'}};{extra}[IO.File]::WriteAllLines({},[string[]]$done)",
        powershell_literal(&result.display().to_string()))
}

const NETWORK_ID:&str="58997fc5f3c0c001";

/// Folders where the ZeroTier installers put the service program (1.16 uses ProgramData).
const ZEROTIER_ROOTS:&[&str]=&["C:\\ProgramData\\ZeroTier\\One","C:\\Program Files\\ZeroTier\\One","C:\\Program Files (x86)\\ZeroTier\\One"];

fn zerotier_program_present()->bool{
    ZEROTIER_ROOTS.iter().any(|root|Path::new(root).join("zerotier-one_x64.exe").is_file())
}

/// Runs the bundled MSI from the elevated script. Every way 0.6.81 or a friend's PC can trip it:
/// - msiexec cannot open a `\\?\` path (exit 1619: every new friend in 0.6.81) nor, for the
///   administrator who approves the prompt, perhaps a folder of another account. The MSI is
///   copied into a fresh folder under Windows\Temp and installed from there; if that copy is
///   impossible it still runs from where Coco is installed.
/// - the copy is hashed again inside the elevated script, so what runs is the pinned MSI;
/// - another installation in progress (Windows Update, exit 1618) is waited out;
/// - the exit code and the first error of msiexec's own log come back as result lines.
///
/// `action` and `extra` exist for the test, which runs an administrative image ('/a') unelevated.
fn msi_commands(msi:&Path,action:&str,extra:&str)->String{
    const TEMPLATE:&str=r#"$src=__SRC__;$work=Join-Path $env:SystemRoot ('Temp\coco-zerotier-'+[guid]::NewGuid().ToString('N'));$pkg=$src;$log=$null;$msiok=$false;
try{New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop|Out-Null;$log=Join-Path $work 'msi.log';$copy=Join-Path $work 'ZeroTierOne.msi';Copy-Item -LiteralPath $src -Destination $copy -Force -ErrorAction Stop;$pkg=$copy}catch{$zt+='msi-copy-skipped'};
$msiexec=Join-Path $env:SystemRoot 'System32\msiexec.exe';
$run={param([string[]]$more)$a=@(__ACTION__,('"'+$pkg+'"'))+$more+@('/qn','/norestart');if($log){$a+=@('/l*v',('"'+$log+'"'))};$p=Start-Process -FilePath $msiexec -ArgumentList $a -PassThru;$null=$p.Handle;$p.WaitForExit();$p.ExitCode};
if((Get-FileHash -LiteralPath $pkg -Algorithm SHA256 -ErrorAction Stop).Hash -ne '__SHA__'){$zt+='error:msi-hash'}else{
$code=$null;for($t=0;$t -lt 6;$t++){$code=& $run __EXTRA__;if($code -ne 1618){break};Start-Sleep 20};$zt+=('msi='+$code);
if($code -eq 0 -or $code -eq 3010){$msiok=$true}else{$zt+=('error:msi-'+$code);
try{if($log -and (Test-Path -LiteralPath $log)){$why=Get-Content -LiteralPath $log -ErrorAction Stop|Where-Object{$_ -match 'Error \d{4}|Return value 3'}|Select-Object -First 1;if($why){$why=($why -replace '\s+',' ').Trim();$zt+=('msi-log:'+$why.Substring(0,[Math]::Min(220,$why.Length)))}}}catch{}}};
"#;
    TEMPLATE.replace("__SRC__",&powershell_literal(&msi.display().to_string()))
        .replace("__SHA__",&crate::services::network_installer::PINNED_SHA256.to_ascii_uppercase())
        .replace("__ACTION__",action).replace("__EXTRA__",extra).replace('\n',"")
}

/// ZeroTier rides on the same Windows prompt, so a new friend says «Sí» once: install the
/// bundled MSI if it is missing, keep its service running, join Coco's network, let this user
/// read ZeroTier's status afterwards (what ZeroTier's own tray app does) and treat that network
/// as private. Results come back as "zerotier:" lines. Acceptance happens on the host's side.
/// An install that leaves no service or no program behind (a half-removed old ZeroTier still
/// registered with Windows) is reinstalled in place once.
fn zerotier_script(msi:Option<&Path>,user_local:&Path)->String{
    let install=msi.map(|msi|format!("{}if($msiok){{Start-Sleep 3;if(-not (Get-Service ZeroTierOneService -ErrorAction SilentlyContinue) -or -not (Test-Path (Join-Path $env:ProgramData 'ZeroTier\\One\\zerotier-one_x64.exe'))){{$code=& $run @('REINSTALL=ALL','REINSTALLMODE=amus');$zt+=('msi-reinstall='+$code);if($code -ne 0 -and $code -ne 3010){{$zt+=('error:msi-reinstall-'+$code)}}}};Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}};",
        msi_commands(msi,"'/i'","@()"))).unwrap_or_default();
    let token=powershell_literal(&user_local.join("ZeroTier").join("authtoken.secret").display().to_string());
    let roots=ZEROTIER_ROOTS.iter().map(|root|powershell_literal(root)).collect::<Vec<_>>().join(",");
    format!("$zt=@();try{{{install}\
$s=$null;for($i=0;$i -lt 60 -and -not $s;$i++){{$s=Get-Service ZeroTierOneService -ErrorAction SilentlyContinue;if(-not $s){{Start-Sleep 1}}}};\
if($s){{try{{if($s.StartType -ne 'Automatic'){{Set-Service ZeroTierOneService -StartupType Automatic -ErrorAction Stop}};if($s.Status -ne 'Running'){{Start-Service ZeroTierOneService -ErrorAction Stop}}}}catch{{$zt+=('error:service-start:'+($_.Exception.Message -replace '\\s+',' '))}};\
$zt+=('service='+(Get-Service ZeroTierOneService -ErrorAction SilentlyContinue).Status);\
$root=@({roots})|Where-Object{{Test-Path (Join-Path $_ 'zerotier-one_x64.exe')}}|Select-Object -First 1;\
if($root){{$exe=Join-Path $root 'zerotier-one_x64.exe';for($i=0;$i -lt 45;$i++){{$out=(& $exe -q join {NETWORK_ID} 2>&1|Out-String);if($out -match '200'){{$zt+='joined';break}};Start-Sleep 1}};if('joined' -notin $zt){{$zt+='error:join'}}}}else{{$zt+='error:cli'}};\
$secret='C:\\ProgramData\\ZeroTier\\One\\authtoken.secret';$mine={token};\
if((Test-Path -LiteralPath $secret) -and (-not (Test-Path -LiteralPath $mine) -or (Get-FileHash -LiteralPath $secret).Hash -ne (Get-FileHash -LiteralPath $mine).Hash)){{New-Item -ItemType Directory -Path (Split-Path $mine) -Force|Out-Null;Copy-Item -LiteralPath $secret -Destination $mine -Force;$zt+='token'}};\
{tuning}\
}}else{{$zt+='error:service'}}}}catch{{$zt+=('error:'+($_.Exception.Message -replace '\\s+',' '))}};foreach($z in $zt){{$done+=('zerotier:'+$z)}};",tuning=lan_tuning_commands())
}

/// Some LAN games search only on their preferred interface. Prioritize Coco's IPv4
/// adapter, not every ZeroTier network or VPN the player happens to use.
const LAN_SELECT:&str="$cocoIndexes=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object{$_.IPAddress -like '10.77.37.*'}|ForEach-Object{$_.InterfaceIndex});$a=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object{$_.InterfaceDescription -like 'ZeroTier*' -and ($_.Name -like '*58997fc5f3c0c001*' -or $_.ifIndex -in $cocoIndexes)})";
const LAN_TUNING:&str="for($i=0;$i -lt 60;$i++){__SELECT__;if($a.Count){foreach($x in $a){Get-NetConnectionProfile -InterfaceIndex $x.ifIndex -ErrorAction SilentlyContinue|Where-Object{$_.NetworkCategory -ne 'Private'}|Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop;Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $x.ifIndex -ErrorAction Stop|Where-Object{$_.InterfaceMetric -ne 1 -or $_.AutomaticMetric -ne 'Disabled'}|Set-NetIPInterface -AutomaticMetric Disabled -InterfaceMetric 1 -ErrorAction Stop};$zt+='lan';break};Start-Sleep 1};if(-not $a.Count){$zt+='error:lan-adapter-not-ready'};";

fn lan_tuning_commands()->String{LAN_TUNING.replace("__SELECT__",LAN_SELECT)}

fn lan_tuning_script()->String{
    format!("$zt=@();try{{{}}}catch{{$zt+=('error:'+$_.Exception.Message)}};foreach($z in $zt){{$done+=('zerotier:'+$z)}};",lan_tuning_commands())
}

/// "metric|category" per ZeroTier adapter and address family, read without elevation.
fn lan_probe_script()->String{
    format!("{LAN_SELECT};foreach($x in $a){{$c=(Get-NetConnectionProfile -InterfaceIndex $x.ifIndex -ErrorAction SilentlyContinue).NetworkCategory;Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $x.ifIndex -ErrorAction SilentlyContinue|ForEach-Object{{[string]$_.InterfaceMetric+'|'+$c}}}}")
}

fn lan_tuning_missing(probe:&str)->bool{
    probe.lines().map(str::trim).filter(|line|!line.is_empty()).any(|line|{
        let (metric,category)=line.split_once('|').unwrap_or((line,""));
        metric.trim()!="1"||category.trim().eq_ignore_ascii_case("Public")
    })
}

#[cfg(windows)]
fn lan_tuning_needed()->bool{
    use std::os::windows::process::CommandExt;
    let mut exe=std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(||PathBuf::from("C:\\Windows"));
    exe.push("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    let output=std::process::Command::new(exe).args(["-NoProfile","-NonInteractive","-EncodedCommand",&encoded_command(&lan_probe_script())])
        .stdin(std::process::Stdio::null()).creation_flags(0x08000000).output(); // CREATE_NO_WINDOW
    output.ok().filter(|output|output.status.success()).is_some_and(|output|lan_tuning_missing(&String::from_utf8_lossy(&output.stdout)))
}

#[cfg(not(windows))]
fn lan_tuning_needed()->bool{false}

fn encoded_command(script:&str)->String{
    use base64::Engine;
    let bytes:Vec<u8>=script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

enum Elevation{Finished,Declined,Failed}

#[derive(Clone,Copy,Serialize)]
#[serde(rename_all="kebab-case")]
enum WindowsPreparation{Requesting,Configuring,Idle}

#[cfg(windows)]
fn run_elevated(script:&str,set_phase:impl Fn(WindowsPreparation))->Elevation{
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{CloseHandle,GetLastError};
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;
    use windows_sys::Win32::System::Threading::WaitForSingleObject;
    use windows_sys::Win32::UI::Shell::{ShellExecuteExW,SHELLEXECUTEINFOW,SEE_MASK_NOCLOSEPROCESS};
    let mut system=[0u16;512];
    let count=unsafe{GetSystemDirectoryW(system.as_mut_ptr(),system.len() as u32)} as usize;
    if count==0||count>=system.len(){return Elevation::Failed;}
    let Ok(base)=String::from_utf16(&system[..count]) else {return Elevation::Failed};
    // A fixed System32 path: never whichever powershell.exe comes first on PATH.
    let exe=Path::new(&base).join("WindowsPowerShell").join("v1.0").join("powershell.exe");
    let wide=|value:&std::ffi::OsStr|value.encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let verb=wide(std::ffi::OsStr::new("runas"));
    let program=wide(exe.as_os_str());
    let arguments=wide(std::ffi::OsStr::new(&format!("-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {}",encoded_command(script))));
    let mut info:SHELLEXECUTEINFOW=unsafe{std::mem::zeroed()};
    info.cbSize=std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask=SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb=verb.as_ptr();
    info.lpFile=program.as_ptr();
    info.lpParameters=arguments.as_ptr();
    info.nShow=0;
    set_phase(WindowsPreparation::Requesting);
    if unsafe{ShellExecuteExW(&mut info)}==0{
        return if unsafe{GetLastError()}==1223{Elevation::Declined}else{Elevation::Failed};
    }
    if info.hProcess.is_null(){return Elevation::Failed;}
    set_phase(WindowsPreparation::Configuring);
    // Installing ZeroTier (after waiting out a Windows Update install) and waiting for its
    // service and the join can take several minutes on a slow PC.
    let waited=unsafe{WaitForSingleObject(info.hProcess,900_000)};
    unsafe{CloseHandle(info.hProcess)};
    if waited==0{Elevation::Finished}else{Elevation::Failed}
}

#[cfg(not(windows))]
fn run_elevated(_script:&str,_set_phase:impl Fn(WindowsPreparation))->Elevation{Elevation::Failed}

fn read_state(path:&Path)->State{
    fs::read(path).ok().and_then(|bytes|serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

fn write_state(path:&Path,state:&State){
    let Ok(payload)=serde_json::to_vec_pretty(state) else {return};
    if let Some(parent)=path.parent(){let _=fs::create_dir_all(parent);}
    let temp=path.with_extension("tmp");
    if fs::write(&temp,payload).is_ok()&&crate::services::identity::atomic_replace(&temp,path).is_err(){
        let _=fs::remove_file(&temp);
    }
}

/// A PC whose Defender was removed (debloat tools do this) has nothing to exclude: asking for
/// permission there would only be a pointless Windows prompt.
fn defender_installed()->bool{
    #[cfg(windows)]{
        use crate::services::game_prepare::registry::{read,MACHINE};
        return read(MACHINE,"SYSTEM\\CurrentControlSet\\Services\\WinDefend","DisplayName").is_some();
    }
    #[allow(unreachable_code)]
    false
}

fn request(app:Option<&AppHandle>,extra:&[PathBuf],programs:&[PathBuf],force:bool)->&'static str{
    request_with(app,extra,programs,force,None)
}

fn request_with(app:Option<&AppHandle>,extra:&[PathBuf],programs:&[PathBuf],force:bool,zerotier:Option<String>)->&'static str{
    let (Some(app_data),Some(local_data))=(std::env::var_os("APPDATA"),std::env::var_os("LOCALAPPDATA")) else {return "failed"};
    let (app_data,local_data)=(PathBuf::from(app_data),PathBuf::from(local_data));
    // Startup and game operations share the permissions cache and helper result file.
    let Ok(_preparation)=PREPARATION.lock() else{return "failed"};
    let locations=inventory::custom_locations(&local_data).unwrap_or_default();
    let home=std::env::var_os("USERPROFILE").map(PathBuf::from);
    // The installed video engine sits next to Coco's own executable.
    let engine=std::env::current_exe().ok().and_then(|exe|exe.parent().map(|dir|dir.join("player"))).filter(|dir|dir.is_dir());
    let desired=desired_paths(&app_data,&local_data,&locations,extra,home.as_deref(),engine.as_deref());
    let state_path=local_data.join("CocoMinecraftUpdater").join(STATE_FILE);
    let mut state=read_state(&state_path);
    let defender=defender_installed();
    let missing:Vec<String>=if defender{desired.into_iter().filter(|path|!covered(path,&state.paths)).collect()}else{Vec::new()};
    let mut firewall:Vec<String>=Vec::new();
    for program in programs.iter().filter(|path|is_local_absolute(path)).map(|path|path.display().to_string()){
        let key=normalized(&program);
        if !state.firewall.iter().any(|known|normalized(known)==key)&&!firewall.iter().any(|known|normalized(known)==key){firewall.push(program);}
    }
    if missing.is_empty()&&firewall.is_empty()&&zerotier.is_none(){return if defender{"present"}else{"unavailable"};}
    let networking=zerotier.is_some();
    // A previous Defender refusal must not silently suppress a new LAN repair
    // for six hours (or seven days). Each permission has its own quiet period.
    if !force&&retry_pending(&state,networking,now()){return "skipped";}
    let result=state_path.with_file_name(format!("defender-result-{}.txt",std::process::id()));
    if let Some(parent)=result.parent(){let _=fs::create_dir_all(parent);}
    let _=fs::remove_file(&result);
    let set_phase=|phase|{if let Some(app)=app{let _=app.emit(AUTHORIZATION_EVENT,phase);}};
    let extra_script=format!("{}{}",firewall_script(&firewall),zerotier.as_deref().unwrap_or_default());
    let elevation=run_elevated(&elevated_script(&missing,&result,&extra_script),set_phase);
    set_phase(WindowsPreparation::Idle);
    let status=match elevation{
        Elevation::Declined=>{
            if networking{state.network_retry_after=now()+DECLINED_RETRY_SECONDS;}
            if !missing.is_empty()||!firewall.is_empty(){state.retry_after=now()+DECLINED_RETRY_SECONDS;}
            "declined"
        }
        Elevation::Failed=>"failed",
        Elevation::Finished=>{
            let lines:Vec<String>=fs::read_to_string(&result).unwrap_or_default().lines()
                .map(|line|line.trim_start_matches('\u{feff}').trim().to_string()).filter(|line|!line.is_empty()).collect();
            for line in lines.iter().filter(|line|line.starts_with("zerotier:")||line.starts_with("error:")||line.starts_with("firewall:")){
                crate::services::diagnostics::log("windows",line);
            }
            if let Ok(mut last)=LAST_ZEROTIER_LINES.lock(){*last=lines.iter().filter(|line|line.starts_with("zerotier:")).cloned().collect();}
            let allowed:Vec<String>=lines.iter().filter_map(|line|line.strip_prefix("firewall:"))
                .filter(|program|!program.starts_with("error:")).map(str::to_string).collect();
            let firewall_complete=allowed.len()==firewall.len();
            state.firewall.extend(allowed);
            let network_complete=lines.iter().any(|line|line=="zerotier:lan")
                &&!lines.iter().any(|line|line.starts_with("zerotier:error:"));
            let added:Vec<String>=lines.into_iter().filter(|line|!line.starts_with("zerotier:")&&!line.starts_with("error:")&&!line.starts_with("firewall:")).collect();
            let complete=added.len()==missing.len()&&firewall_complete;
            let zerotier_only=missing.is_empty()&&firewall.is_empty();
            state.paths.extend(added);
            // No Defender (another antivirus) or a policy that forbids it: do not nag. A ZeroTier-only
            // prompt is not repeated right away either if the join did not take.
            if !zerotier_only{state.retry_after=if !complete{now()+UNAVAILABLE_RETRY_SECONDS}else{0};}
            if networking{state.network_retry_after=if network_complete{0}else{now()+DECLINED_RETRY_SECONDS};}
            if networking&&!network_complete{"network-incomplete"}else if zerotier_only{"zerotier"}else if complete{"added"}else{"unavailable"}
        }
    };
    let _=fs::remove_file(&result);
    write_state(&state_path,&state);
    status
}

/// Never blocks playing: if Windows says no, the game still gets its chance to run.
pub(crate) fn ensure(app:&AppHandle,extra:&[PathBuf],programs:&[PathBuf]){
    let status=request(Some(app),extra,programs,false);
    if !matches!(status,"present"|"skipped"){crate::services::diagnostics::log("defender",&format!("exclusiones al abrir: {status}"));}
}

/// Installing or moving into a folder is something the player just chose, so it asks even inside
/// the quiet period after an earlier «No»: otherwise Defender could strip the fix files on the way.
pub(crate) fn ensure_for_new_folder(app:&AppHandle,root:&Path,programs:&[PathBuf]){
    let status=request(Some(app),std::slice::from_ref(&root.to_path_buf()),programs,true);
    if status!="present"{crate::services::diagnostics::log("defender",&format!("exclusiones al instalar o mover: {status}"));}
}

/// A friend without ZeroTier gets the bundled MSI. Only a definite «service does not exist»
/// counts: an unreadable service state must not reinstall over a working ZeroTier.
/// (NetworkStatus::setup_supported is the old read-only status flag and is never true, so it
/// must not gate this: it kept every friend who did not come from Coco 1 off the network.)
fn zerotier_install_needed(service_installed:Option<bool>)->bool{
    cfg!(windows)&&service_installed==Some(false)
}

/// An installed ZeroTier joins Coco's network unless its own API says it already has.
fn zerotier_join_needed(service_installed:Option<bool>,joined:Option<bool>)->bool{
    cfg!(windows)&&service_installed==Some(true)&&joined!=Some(true)
}

/// Everything Windows needs to approve, asked together once when Coco opens: Defender for
/// the game folders and, when missing, ZeroTier for playing with the host. Never blocks the
/// launcher: a refusal, no Defender or the host being offline all leave Coco fully usable.
#[tauri::command]
pub async fn prepare_windows(app:AppHandle)->Result<&'static str,String>{
    use tauri::Manager;
    let status=crate::services::network::get_network_status().await.ok();
    let service=status.as_ref().and_then(|s|s.service_installed);
    let zerotier_missing=zerotier_install_needed(service);
    // Membership comes from ZeroTier's own API: its CLI lives in different folders per installer
    // version, and a wrong "not joined" would ask for permission on every start.
    let membership=tauri::async_runtime::spawn_blocking(crate::services::zerotier_host::local_membership).await.ok().flatten();
    let needs_join=zerotier_join_needed(service,membership.as_ref().map(|(joined,_)|*joined));
    let msi=if zerotier_missing{
        let resources=app.path().resource_dir().map_err(|_|"Recursos de Coco no disponibles")?;
        match crate::services::network_installer::pinned_installer(&resources){
            Ok(found)=>Some(found),
            Err(error)=>{crate::services::diagnostics::log("zerotier",&format!("MSI no disponible: {error}"));None}
        }
    }else{None};
    let local=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or("LOCALAPPDATA no disponible")?;
    // Friends who already had ZeroTier (from Coco 1) never ran the join script, so their adapter
    // is checked separately and only fixed when it needs it.
    let script=if msi.is_some()||needs_join{Some(zerotier_script(msi.as_ref().map(|(path,_)|path.as_path()),&local))}
        else if tauri::async_runtime::spawn_blocking(lan_tuning_needed).await.unwrap_or(false){Some(lan_tuning_script())}
        else{None};
    tauri::async_runtime::spawn_blocking(move||{
        // The verified MSI stays locked against changes until Windows has installed it.
        let _locked=msi;
        // The host's Coco receives friends' profile names on the Coco network.
        let host_program:Vec<PathBuf>=if crate::services::zerotier_host::is_host(){std::env::current_exe().into_iter().collect()}else{Vec::new()};
        let status=request_with(Some(&app),&[],&host_program,false,script);
        crate::services::diagnostics::log("windows",&format!("preparación al abrir: {status}"));
        status
    }).await.map_err(|error|format!("Autorización interrumpida: {error}"))
}

#[derive(Debug,Serialize)]
#[serde(rename_all="camelCase")]
pub struct NetworkRepair{pub status:&'static str,pub detail:String}

/// A ZeroTier that did not install or whose service does not run is reported as such right
/// away (with msiexec's own error), instead of waiting a minute for a host acceptance.
/// A join or adapter that is still settling is not a failure: the membership check decides.
fn repair_failure(lines:&[String])->Option<NetworkRepair>{
    let error=|prefix:&str|lines.iter().find(|line|line.starts_with(prefix)).cloned();
    let why=lines.iter().find_map(|line|line.strip_prefix("zerotier:msi-log:")).unwrap_or("").to_string();
    if let Some(line)=error("zerotier:error:msi"){
        return Some(NetworkRepair{status:"install-failed",detail:format!("{} {why}",line.trim_start_matches("zerotier:error:")).trim().to_string()});
    }
    error("zerotier:error:service").or_else(||error("zerotier:error:cli")).map(|line|NetworkRepair{status:"service-failed",detail:line.trim_start_matches("zerotier:error:").to_string()})
}

/// Ajustes → «Reparar conexión»: what the first open does for ZeroTier, right now and without
/// the quiet period after an earlier failure or «No». Installs the bundled MSI when the service
/// or its program is missing; otherwise starts, joins and tunes what is there. One Windows
/// prompt, no installer windows. Then waits for the host to accept this PC.
#[tauri::command]
pub async fn repair_zerotier(app:AppHandle)->Result<NetworkRepair,String>{
    use tauri::Manager;
    let status=crate::services::network::get_network_status().await.ok();
    let service=status.as_ref().and_then(|s|s.service_installed);
    let install=cfg!(windows)&&(service==Some(false)||!zerotier_program_present());
    let msi=if install{
        let resources=app.path().resource_dir().map_err(|_|"Recursos de Coco no disponibles")?;
        match crate::services::network_installer::pinned_installer(&resources){
            Ok(found)=>Some(found),
            Err(error)=>{
                crate::services::diagnostics::log("zerotier",&format!("reparación: MSI no disponible: {error}"));
                return Ok(NetworkRepair{status:"missing-installer",detail:error});
            }
        }
    }else{None};
    let local=std::env::var_os("LOCALAPPDATA").map(PathBuf::from).ok_or("LOCALAPPDATA no disponible")?;
    let script=zerotier_script(msi.as_ref().map(|(path,_)|path.as_path()),&local);
    tauri::async_runtime::spawn_blocking(move||{
        let _locked=msi;
        let host_program:Vec<PathBuf>=if crate::services::zerotier_host::is_host(){std::env::current_exe().into_iter().collect()}else{Vec::new()};
        if let Ok(mut last)=LAST_ZEROTIER_LINES.lock(){last.clear();}
        let elevated=request_with(Some(&app),&[],&host_program,true,Some(script));
        let lines=LAST_ZEROTIER_LINES.lock().map(|last|last.clone()).unwrap_or_default();
        let outcome=match (elevated,repair_failure(&lines)){
            ("declined",_)=>NetworkRepair{status:"declined",detail:String::new()},
            ("failed",_)=>NetworkRepair{status:"failed",detail:String::new()},
            (_,Some(failure))=>failure,
            _=>{
                // The host's Coco accepts new PCs within a few seconds while it is open.
                let mut last=None;
                for _ in 0..20{
                    last=crate::services::zerotier_host::local_membership();
                    if last.as_ref().is_some_and(|(joined,state)|*joined&&state.starts_with("OK")){break;}
                    std::thread::sleep(std::time::Duration::from_secs(3));
                }
                match last{
                    Some((true,state)) if state.starts_with("OK")=>NetworkRepair{status:"connected",detail:state},
                    Some((true,state))=>NetworkRepair{status:"waiting-host",detail:state},
                    Some((false,state))=>NetworkRepair{status:"incomplete",detail:state},
                    None=>NetworkRepair{status:"incomplete",detail:"ZeroTier no responde".into()},
                }
            }
        };
        crate::services::diagnostics::log("windows",&format!("reparación de ZeroTier: {elevated} → {} {}",outcome.status,outcome.detail));
        outcome
    }).await.map_err(|error|format!("Reparación interrumpida: {error}"))
}

#[tauri::command]
pub async fn ensure_defender_exclusions(app:AppHandle)->Result<&'static str,String>{
    tauri::async_runtime::spawn_blocking(move||request(Some(&app),&[],&[],true))
        .await.map_err(|error|format!("Autorización interrumpida: {error}"))
}

#[cfg(test)]
mod tests{
    use super::*;

    fn map(entries:&[(&str,&str)])->Map<String,Value>{
        entries.iter().map(|(key,value)|(key.to_string(),Value::String(value.to_string()))).collect()
    }
    const APP:&str="C:\\Users\\a\\AppData\\Roaming";
    const LOCAL:&str="C:\\Users\\a\\AppData\\Local";
    const HOME:&str="C:\\Users\\a";
    fn desired(locations:&[(&str,&str)],extra:&[&str])->Vec<String>{
        desired_paths(Path::new(APP),Path::new(LOCAL),&map(locations),&extra.iter().map(PathBuf::from).collect::<Vec<_>>(),Some(Path::new(HOME)),None)
    }

    #[test]
    fn zerotier_adapter_is_fixed_only_when_lan_search_would_miss_it(){
        assert!(!lan_tuning_missing(""));
        assert!(!lan_tuning_missing("1|Private\r\n1|Private\r\n"));
        assert!(!lan_tuning_missing("1|\r\n"));
        assert!(lan_tuning_missing("35|Private\r\n1|Private\r\n"));
        assert!(lan_tuning_missing("1|Public\r\n"));
        assert!(zerotier_script(None,Path::new(LOCAL)).contains("-InterfaceMetric 1"));
        assert!(lan_tuning_script().contains("Set-NetConnectionProfile -NetworkCategory Private"));
        assert!(lan_tuning_script().contains(NETWORK_ID));
        assert!(lan_tuning_script().contains("-AddressFamily IPv4"));
        assert!(lan_tuning_script().contains("-AutomaticMetric Disabled"));
        assert!(!lan_tuning_script().contains("__SELECT__"));
    }

    #[test]
    fn defender_cooldown_cannot_skip_a_new_network_repair(){
        let old:State=serde_json::from_str(r#"{"paths":[],"retryAfter":900}"#).unwrap();
        assert!(retry_pending(&old,false,100));
        assert!(!retry_pending(&old,true,100));
        let declined=State{network_retry_after:900,..State::default()};
        assert!(retry_pending(&declined,true,100));
        assert!(!retry_pending(&declined,true,901));
        assert!(!retry_pending(&declined,false,100));
    }

    #[cfg(windows)]
    #[test]
    fn lan_script_tunes_only_coco_and_reports_permission_errors(){
        use std::os::windows::process::CommandExt;
        let fixtures=r#"
$done=@();$metric=35;$category='Public';$fail=$false
function Get-NetAdapter {[CmdletBinding()]param()
 [pscustomobject]@{Name='Renamed adapter';InterfaceDescription='ZeroTier Virtual Port';ifIndex=13}
 [pscustomobject]@{Name='ZeroTier Other';InterfaceDescription='ZeroTier Virtual Port';ifIndex=99}
 [pscustomobject]@{Name='Ethernet';InterfaceDescription='Physical';ifIndex=20}
}
function Get-NetIPAddress {[CmdletBinding()]param($AddressFamily)
 [pscustomobject]@{IPAddress='10.77.37.1';InterfaceIndex=13}
}
function Get-NetConnectionProfile {[CmdletBinding()]param($InterfaceIndex)
 [pscustomobject]@{InterfaceIndex=$InterfaceIndex;NetworkCategory=$script:category}
}
function Set-NetConnectionProfile {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject,$NetworkCategory)
 process{if($InputObject.InterfaceIndex -ne 13){throw 'unrelated adapter'};$script:category=$NetworkCategory}
}
function Get-NetIPInterface {[CmdletBinding()]param($InterfaceIndex,$AddressFamily)
 if($AddressFamily -ne 'IPv4'){throw 'unexpected family'}
 [pscustomobject]@{InterfaceIndex=$InterfaceIndex;InterfaceMetric=$script:metric;AutomaticMetric='Enabled'}
}
function Set-NetIPInterface {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject,$InterfaceMetric,$AutomaticMetric)
 process{if($InputObject.InterfaceIndex -ne 13){throw 'unrelated adapter'};if($script:fail){throw 'permission denied'};if($AutomaticMetric -ne 'Disabled'){throw 'automatic metric'};$script:metric=$InterfaceMetric}
}
"#;
        let tuning=lan_tuning_script();
        let script=format!("{fixtures}{tuning};if($metric -ne 1 -or $category -ne 'Private' -or 'zerotier:lan' -notin $done){{exit 2}};$fail=$true;$done=@();{tuning};if('zerotier:lan' -in $done -or -not($done -like 'zerotier:error:*')){{exit 3}}");
        let output=std::process::Command::new("powershell.exe")
            .args(["-NoProfile","-NonInteractive","-EncodedCommand",&encoded_command(&script)])
            .creation_flags(0x08000000).output().unwrap();
        assert!(output.status.success(),"{}",String::from_utf8_lossy(&output.stderr));
    }

    #[cfg(windows)]
    #[test]
    fn real_probe_reads_this_pcs_zerotier_adapter(){
        // Runs the unelevated probe for real: it must answer without a prompt.
        let _=lan_tuning_needed();
    }

    #[cfg(windows)]
    #[test]
    fn every_place_a_game_can_touch_is_covered(){
        let paths=desired(&[("a","D:\\Juegos\\a")],&["E:\\Otros\\b"]);
        for expected in ["C:\\Users\\a\\AppData\\Roaming\\CocoLauncher2","C:\\Users\\a\\AppData\\Roaming\\CocoMinecraft",
            "C:\\Users\\a\\AppData\\Local\\CocoMinecraftUpdater","D:\\Juegos\\a","D:\\Juegos","E:\\Otros\\b","E:\\Otros"]{
            assert!(paths.iter().any(|path|path==expected),"{expected} missing from {paths:?}");
        }
    }

    #[cfg(windows)]
    #[test]
    fn the_video_engine_and_its_repair_copy_are_excluded_but_not_coco_itself(){
        let engine=Path::new("C:\\Users\\a\\AppData\\Local\\Coco Launcher 2\\player");
        let paths=desired_paths(Path::new(APP),Path::new(LOCAL),&map(&[]),&[],Some(Path::new(HOME)),Some(engine));
        assert!(paths.iter().any(|path|path=="C:\\Users\\a\\AppData\\Local\\Coco Launcher 2\\player"));
        assert!(paths.iter().any(|path|path=="C:\\Users\\a\\AppData\\Local\\CocoLauncher2\\player-runtime"));
        assert!(!paths.iter().any(|path|path=="C:\\Users\\a\\AppData\\Local\\Coco Launcher 2"),"only the engine, never the launcher's own folder");
        let without=desired_paths(Path::new(APP),Path::new(LOCAL),&map(&[]),&[],Some(Path::new(HOME)),Some(Path::new("\\\\server\\player")));
        assert!(!without.iter().any(|path|path.contains("server")),"a network engine folder is not excluded");
    }

    #[cfg(windows)]
    #[test]
    fn a_personal_folder_or_a_drive_is_never_excluded_whole(){
        for (root,parent) in [("D:\\game","D:\\"),("C:\\Users\\a\\Desktop\\game","C:\\Users\\a\\Desktop"),("C:\\Users\\a\\game","C:\\Users\\a"),("C:\\Users\\game","C:\\Users")]{
            let paths=desired(&[],&[root]);
            assert!(paths.iter().any(|path|path==root));
            assert!(!paths.iter().any(|path|path==parent),"{parent} must not be excluded: {paths:?}");
            assert!(paths.iter().any(|path|path.ends_with(".coco2-stage-*")),"installs there still need their stage");
        }
        assert!(!desired(&[("a","D:\\")],&[]).iter().any(|path|path=="D:\\"),"a location at a drive root is ignored");
        assert!(!desired(&[("a","\\\\server\\share\\game")],&[]).iter().any(|path|path.contains("server")),"network folders are not local");
    }

    #[test]
    fn known_folders_are_not_requested_twice(){
        let known=vec!["C:\\Users\\a\\AppData\\Roaming\\CocoMinecraft\\".to_string()];
        assert!(covered("c:\\users\\a\\appdata\\roaming\\cocominecraft\\experiences\\demo",&known));
        assert!(covered("C:\\Users\\a\\AppData\\Roaming\\CocoMinecraft",&known));
        assert!(!covered("C:\\Users\\a\\AppData\\Roaming\\CocoMinecraftOther",&known),"a similar name is another folder");
        let paths=desired(&[("a","D:\\Juegos\\a"),("b","D:\\Juegos\\b")],&["D:\\Juegos\\a"]);
        assert_eq!(paths.iter().filter(|path|path.as_str()=="D:\\Juegos").count(),1);
    }

    #[test]
    fn zerotier_runs_inside_the_same_prompt_with_quoted_paths(){
        let script=zerotier_script(Some(Path::new("C:\\Coco's\\ZeroTierOne.msi")),Path::new("C:\\Users\\O'Neil\\AppData\\Local"));
        assert!(script.contains("'C:\\Coco''s\\ZeroTierOne.msi'"),"MSI path is a single-quoted literal");
        assert!(script.contains("'C:\\Users\\O''Neil\\AppData\\Local\\ZeroTier\\authtoken.secret'"));
        assert!(script.contains("join 58997fc5f3c0c001"));
        assert!(script.contains("'/qn','/norestart'"));
        let without=zerotier_script(None,Path::new("C:\\L"));
        assert!(!without.contains("msiexec"),"an installed ZeroTier is never reinstalled");
        let whole=elevated_script(&["C:\\G".into()],Path::new("C:\\r.txt"),&without);
        assert!(whole.find("join").unwrap()<whole.find("WriteAllLines").unwrap(),"results are written after ZeroTier");
    }

    /// Runs the real MSI step unelevated as an administrative image ('/a'), from a folder with a
    /// space and an apostrophe given in the `\\?\` form Tauri hands over: it must open the
    /// package (0.6.81 got 1619 here), and a forged MSI must never reach msiexec.
    #[cfg(windows)]
    #[test]
    fn the_msi_step_opens_the_real_package_and_refuses_a_forged_one(){
        use std::os::windows::process::CommandExt;
        let base=std::env::temp_dir().join(format!("coco zt's-{}",std::process::id()));
        let _=fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("resources")).unwrap();
        fs::copy(Path::new(env!("CARGO_MANIFEST_DIR")).join("resources").join("ZeroTierOne.msi"),base.join("resources").join("ZeroTierOne.msi")).unwrap();
        let (msi,lock)=crate::services::network_installer::pinned_installer(&fs::canonicalize(&base).unwrap()).unwrap();
        let run=|msi:&Path|{
            let target=base.join("admin image");
            let script=format!("$zt=@();{}if($msiok){{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}};$zt -join '|'",
                msi_commands(msi,"'/a'",&format!("@(('TARGETDIR=\"'+{}+'\"'))",powershell_literal(&target.display().to_string()))));
            let output=std::process::Command::new("powershell.exe").args(["-NoProfile","-NonInteractive","-EncodedCommand",&encoded_command(&script)])
                .creation_flags(0x08000000).output().unwrap();
            (String::from_utf8_lossy(&output.stdout).trim().to_string(),target)
        };
        // Coco keeps the verified MSI open (read sharing only) while Windows installs it.
        let (lines,target)=run(&msi);
        println!("{lines}");
        assert!(lines.split('|').any(|line|line=="msi=0"),"{lines}");
        assert!(target.join("ZeroTierOne.msi").is_file()||fs::read_dir(&target).map(|d|d.count()>0).unwrap_or(false),"msiexec unpacked the package: {lines}");
        drop(lock);
        let forged=base.join("forged.msi");
        fs::write(&forged,b"not the pinned installer").unwrap();
        let (lines,_)=run(&forged);
        assert!(lines.split('|').any(|line|line=="error:msi-hash"),"{lines}");
        assert!(!lines.contains("msi="),"msiexec never ran: {lines}");
        let _=fs::remove_dir_all(&base);
    }

    #[cfg(windows)]
    #[test]
    fn the_whole_friend_script_parses_and_fits_the_command_line(){
        let script=elevated_script(&["C:\\G".into()],Path::new("C:\\r.txt"),
            &zerotier_script(Some(Path::new("D:\\Users\\caro r\\AppData\\Local\\Coco Launcher 2\\resources\\ZeroTierOne.msi")),Path::new("C:\\L")));
        let encoded=encoded_command(&script);
        assert!(encoded.len()<30_000,"Windows caps a command line at 32767 characters: {}",encoded.len());
        let check=format!("$e=$null;[void][Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('{encoded}')),[ref]$null,[ref]$e);$e.Count");
        let output=std::process::Command::new("powershell.exe").args(["-NoProfile","-NonInteractive","-Command",&check]).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(),"0","{}",String::from_utf8_lossy(&output.stderr));
        assert!(script.contains("REINSTALL=ALL"));
        assert!(script.find("msi=").unwrap()<script.find("join 58997fc5f3c0c001").unwrap(),"install before join");
    }

    #[test]
    fn a_repair_says_what_failed_instead_of_waiting(){
        let lines=|v:&[&str]|v.iter().map(|s|s.to_string()).collect::<Vec<_>>();
        let failed=repair_failure(&lines(&["zerotier:msi=1603","zerotier:error:msi-1603","zerotier:msi-log:Error 1920. Service failed to start"])).unwrap();
        assert_eq!(failed.status,"install-failed");
        assert!(failed.detail.contains("msi-1603")&&failed.detail.contains("Error 1920"),"{failed:?}");
        assert_eq!(repair_failure(&lines(&["zerotier:msi=0","zerotier:error:service"])).unwrap().status,"service-failed");
        assert_eq!(repair_failure(&lines(&["zerotier:error:service-start:Access denied","zerotier:service=Stopped"])).unwrap().status,"service-failed");
        assert!(repair_failure(&lines(&["zerotier:msi=0","zerotier:service=Running","zerotier:joined","zerotier:error:lan-adapter-not-ready"])).is_none(),"settling, not failed");
    }

    #[test]
    fn settings_can_repair_the_network_with_one_prompt(){
        let source=include_str!("defender.rs");
        let repair=&source[source.find("pub async fn repair_zerotier").unwrap()..];
        let repair=&repair[..repair.find("\n}").unwrap()];
        assert!(repair.contains("request_with(Some(&app),&[],&host_program,true,Some(script))"),"forced: ignores the quiet period");
        assert!(repair.contains("service==Some(false)||!zerotier_program_present()"));
        assert!(include_str!("../lib.rs").contains("services::defender::repair_zerotier"));
    }

    #[test]
    fn a_game_gets_firewall_rules_for_its_programs_only(){
        let root=Path::new("D:\\Juegos\\grocery");
        let programs=game_programs(root,"Grocery/Grocery.exe",["Grocery/Binaries/Win64/Grocery-Win64-Shipping.exe",
            "Grocery/Grocery.exe","Engine/Binaries/Win64/CrashReportClient.exe","UnityCrashHandler64.exe",
            "Grocery/Binaries/Win64/OnlineFix64.dll","../evil.exe"]);
        assert_eq!(programs,vec![root.join("Grocery\\Grocery.exe"),root.join("Grocery\\Binaries\\Win64\\Grocery-Win64-Shipping.exe")]);
    }

    #[cfg(windows)]
    #[test]
    fn a_friend_without_zerotier_gets_it_installed_and_joined(){
        assert!(zerotier_install_needed(Some(false)));
        assert!(!zerotier_install_needed(Some(true)));
        assert!(!zerotier_install_needed(None));
        assert!(zerotier_join_needed(Some(true),Some(false)));
        assert!(zerotier_join_needed(Some(true),None));
        assert!(!zerotier_join_needed(Some(true),Some(true)));
        assert!(!zerotier_join_needed(Some(false),None));
        // The bundled MSI and its pinned hash must ship, or the install above has nothing to run.
        let root=Path::new(env!("CARGO_MANIFEST_DIR"));
        assert!(crate::services::network_installer::pinned_installer(root).is_ok());
        let source=include_str!("defender.rs");
        let prepare=&source[source.find("pub async fn prepare_windows").unwrap()..];
        assert!(!prepare[..prepare.find("\n}").unwrap()].contains("setup_supported"));
    }

    #[test]
    fn firewall_rules_ride_on_the_same_prompt_and_remove_windows_block_rules(){
        let script=firewall_script(&["D:\\it's';calc;'\\volleyball.exe".to_string()]);
        assert!(script.contains("@('D:\\it''s'';calc;''\\volleyball.exe')"),"program path is one quoted literal");
        assert!(script.contains("-Action Allow -Program $g -Profile Any"));
        assert!(script.contains("$_.Action -eq 'Block'"));
        assert!(firewall_script(&[]).is_empty());
        let whole=elevated_script(&[],Path::new("C:\\r.txt"),&script);
        assert!(whole.find("New-NetFirewallRule").unwrap()<whole.find("WriteAllLines").unwrap());
    }

    #[cfg(windows)]
    #[test]
    fn the_elevated_script_with_firewall_rules_parses_in_windows_powershell(){
        let script=elevated_script(&["C:\\G".into()],Path::new("C:\\r.txt"),
            &format!("{}{}",firewall_script(&["C:\\G\\game's.exe".into()]),zerotier_script(None,Path::new("C:\\L"))));
        let check=format!("$e=$null;[void][Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('{}')),[ref]$null,[ref]$e);$e.Count",encoded_command(&script));
        let output=std::process::Command::new("powershell.exe").args(["-NoProfile","-NonInteractive","-Command",&check]).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(),"0","{}",String::from_utf8_lossy(&output.stderr));
    }

    /// Real Windows check (asks for UAC): the rule is created for a program, read back while
    /// elevated, and removed again. COCO_FIREWALL_PROGRAM names any .exe path.
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn real_firewall_rule_is_created_and_removed(){
        let program=std::env::var("COCO_FIREWALL_PROGRAM").expect("COCO_FIREWALL_PROGRAM");
        let result=std::env::temp_dir().join(format!("coco-firewall-{}.txt",std::process::id()));
        let check=format!("$r=Get-NetFirewallRule -DisplayName ('Coco - '+{p}) -ErrorAction SilentlyContinue;$done+=('rule:'+[string]$r.Action+'|'+[string]$r.Direction+'|'+(($r|Get-NetFirewallApplicationFilter).Program));$r|Remove-NetFirewallRule;",p=powershell_literal(&program));
        let script=elevated_script(&[],&result,&format!("{}{}",firewall_script(std::slice::from_ref(&program)),check));
        assert!(matches!(run_elevated(&script,|_|{}),Elevation::Finished),"UAC accepted");
        let lines=fs::read_to_string(&result).unwrap();
        let _=fs::remove_file(&result);
        println!("{lines}");
        assert!(lines.contains(&format!("firewall:{program}")),"{lines}");
        assert!(lines.contains(&format!("rule:Allow|Inbound|{program}")),"{lines}");
    }

    #[test]
    fn a_folder_name_cannot_break_out_of_the_elevated_script(){
        let script=elevated_script(&["D:\\it's';calc;'\\game".to_string()],Path::new("C:\\r.txt"),"");
        assert!(script.contains("'D:\\it''s'';calc;''\\game'"),"{script}");
        assert!(script.contains("Add-MpPreference -ExclusionPath $p"));
        assert!(!script.to_lowercase().contains("disablerealtimemonitoring"));
        assert!(!script.contains("Set-MpPreference"));
        use base64::Engine;
        let decoded=base64::engine::general_purpose::STANDARD.decode(encoded_command("ñ")).unwrap();
        assert_eq!(decoded,vec![0xF1,0x00],"PowerShell reads UTF-16LE");
    }
}
