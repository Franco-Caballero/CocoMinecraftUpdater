//! Keeps Windows Defender from quarantining game files while they download, unpack and run.
//! Exclusions need one UAC approval and cover game folders and Coco's cache, never a whole
//! drive or a personal folder. Defender does not let a normal user read its exclusions, so
//! what was added is remembered here and Windows is only asked about what is new.
use crate::services::inventory;
use serde::{Deserialize,Serialize};
use serde_json::{Map,Value};
use std::fs;
use std::path::{Path,PathBuf};
use std::time::{SystemTime,UNIX_EPOCH};
use tauri::{AppHandle,Emitter};

const STATE_FILE:&str="defender-exclusions.json";
const AUTHORIZATION_EVENT:&str="coco2://windows-authorization";
const DECLINED_RETRY_SECONDS:u64=6*60*60;
const UNAVAILABLE_RETRY_SECONDS:u64=7*24*60*60;
/// Folders next to a game hold its installation stage, a move in progress and kept saves.
const WORK_FOLDER_PATTERNS:&[&str]=&[".coco2-stage-*",".coco-moving-*",".coco-moved-*",".coco-uninstalling-*",".coco-kept-saves"];

#[derive(Debug,Default,Serialize,Deserialize)]
#[serde(rename_all="camelCase",default)]
struct State{paths:Vec<String>,retry_after:u64,network_retry_after:u64}

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
/// the player chose, including the one an operation is about to use.
fn desired_paths(app_data:&Path,local_data:&Path,locations:&Map<String,Value>,extra:&[PathBuf],home:Option<&Path>)->Vec<String>{
    let mut paths=vec![
        app_data.join("CocoLauncher2").display().to_string(),
        app_data.join("CocoMinecraft").display().to_string(),
        local_data.join("CocoMinecraftUpdater").display().to_string(),
    ];
    for value in locations.values().filter_map(Value::as_str){add_game_folder(Path::new(value),home,&mut paths);}
    for root in extra{add_game_folder(root,home,&mut paths);}
    let mut seen=Vec::new();
    paths.retain(|path|{let key=normalized(path);if seen.contains(&key){false}else{seen.push(key);true}});
    paths
}

fn powershell_literal(value:&str)->String{format!("'{}'",value.replace('\'',"''"))}

fn elevated_script(paths:&[String],result:&Path,extra:&str)->String{
    let list=paths.iter().map(|path|powershell_literal(path)).collect::<Vec<_>>().join(",");
    format!("$done=@();if(Get-Command Add-MpPreference -ErrorAction SilentlyContinue){{foreach($p in @({list})){{try{{Add-MpPreference -ExclusionPath $p -ErrorAction Stop;$done+=$p}}catch{{$done+=('error:'+$_.Exception.Message)}}}}}}else{{$done+='error:Add-MpPreference no existe'}};{extra}[IO.File]::WriteAllLines({},[string[]]$done)",
        powershell_literal(&result.display().to_string()))
}

const NETWORK_ID:&str="58997fc5f3c0c001";

/// ZeroTier rides on the same Windows prompt, so a new friend says «Sí» once: install the
/// bundled MSI if it is missing, keep its service running, join Coco's network, let this user
/// read ZeroTier's status afterwards (what ZeroTier's own tray app does) and treat that network
/// as private. Results come back as "zerotier:" lines. Acceptance happens on the host's side.
fn zerotier_script(msi:Option<&Path>,user_local:&Path)->String{
    let install=msi.map(|msi|format!(
        "$p=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\\msiexec.exe') -ArgumentList @('/i',('\"'+{}+'\"'),'/qn','/norestart') -Wait -PassThru;$zt+=('msi='+$p.ExitCode);",
        powershell_literal(&msi.display().to_string()))).unwrap_or_default();
    let token=powershell_literal(&user_local.join("ZeroTier").join("authtoken.secret").display().to_string());
    format!("$zt=@();try{{{install}\
$s=$null;for($i=0;$i -lt 30 -and -not $s;$i++){{$s=Get-Service ZeroTierOneService -ErrorAction SilentlyContinue;if(-not $s){{Start-Sleep 1}}}};\
if($s){{if($s.StartType -ne 'Automatic'){{Set-Service ZeroTierOneService -StartupType Automatic}};if($s.Status -ne 'Running'){{Start-Service ZeroTierOneService}};\
$root=@('C:\\ProgramData\\ZeroTier\\One','C:\\Program Files\\ZeroTier\\One','C:\\Program Files (x86)\\ZeroTier\\One')|Where-Object{{Test-Path (Join-Path $_ 'zerotier-one_x64.exe')}}|Select-Object -First 1;\
if($root){{$exe=Join-Path $root 'zerotier-one_x64.exe';for($i=0;$i -lt 30;$i++){{$out=(& $exe -q join {NETWORK_ID} 2>&1|Out-String);if($out -match '200'){{$zt+='joined';break}};Start-Sleep 1}}}}else{{$zt+='error:cli'}};\
$secret='C:\\ProgramData\\ZeroTier\\One\\authtoken.secret';$mine={token};\
if((Test-Path $secret) -and -not (Test-Path $mine)){{New-Item -ItemType Directory -Path (Split-Path $mine) -Force|Out-Null;Copy-Item $secret $mine;$zt+='token'}};\
{tuning}\
}}else{{$zt+='error:service'}}}}catch{{$zt+=('error:'+$_.Exception.Message)}};foreach($z in $zt){{$done+=('zerotier:'+$z)}};",tuning=lan_tuning_commands())
}

/// Some LAN games search only on their preferred interface. Prioritize Coco's IPv4
/// adapter, not every ZeroTier network or VPN the player happens to use.
const LAN_SELECT:&str="$cocoIndexes=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object{$_.IPAddress -like '10.77.37.*'}|ForEach-Object{$_.InterfaceIndex});$a=@(Get-NetAdapter -ErrorAction SilentlyContinue|Where-Object{$_.InterfaceDescription -like 'ZeroTier*' -and ($_.Name -like '*58997fc5f3c0c001*' -or $_.ifIndex -in $cocoIndexes)})";
const LAN_TUNING:&str="for($i=0;$i -lt 20;$i++){__SELECT__;if($a.Count){foreach($x in $a){Get-NetConnectionProfile -InterfaceIndex $x.ifIndex -ErrorAction SilentlyContinue|Where-Object{$_.NetworkCategory -ne 'Private'}|Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop;Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $x.ifIndex -ErrorAction Stop|Where-Object{$_.InterfaceMetric -ne 1 -or $_.AutomaticMetric -ne 'Disabled'}|Set-NetIPInterface -AutomaticMetric Disabled -InterfaceMetric 1 -ErrorAction Stop};$zt+='lan';break};Start-Sleep 1};if(-not $a.Count){$zt+='error:lan-adapter-not-ready'};";

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

#[cfg(windows)]
fn run_elevated(script:&str)->Elevation{
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
    if unsafe{ShellExecuteExW(&mut info)}==0{
        return if unsafe{GetLastError()}==1223{Elevation::Declined}else{Elevation::Failed};
    }
    if info.hProcess.is_null(){return Elevation::Failed;}
    // Installing ZeroTier and waiting for its service can take a few minutes on a slow PC.
    let waited=unsafe{WaitForSingleObject(info.hProcess,300_000)};
    unsafe{CloseHandle(info.hProcess)};
    if waited==0{Elevation::Finished}else{Elevation::Failed}
}

#[cfg(not(windows))]
fn run_elevated(_script:&str)->Elevation{Elevation::Failed}

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

fn request(app:Option<&AppHandle>,extra:&[PathBuf],force:bool)->&'static str{
    request_with(app,extra,force,None)
}

fn request_with(app:Option<&AppHandle>,extra:&[PathBuf],force:bool,zerotier:Option<String>)->&'static str{
    let (Some(app_data),Some(local_data))=(std::env::var_os("APPDATA"),std::env::var_os("LOCALAPPDATA")) else {return "failed"};
    let (app_data,local_data)=(PathBuf::from(app_data),PathBuf::from(local_data));
    let locations=inventory::custom_locations(&local_data).unwrap_or_default();
    let home=std::env::var_os("USERPROFILE").map(PathBuf::from);
    let desired=desired_paths(&app_data,&local_data,&locations,extra,home.as_deref());
    let state_path=local_data.join("CocoMinecraftUpdater").join(STATE_FILE);
    let mut state=read_state(&state_path);
    let defender=defender_installed();
    let missing:Vec<String>=if defender{desired.into_iter().filter(|path|!covered(path,&state.paths)).collect()}else{Vec::new()};
    if missing.is_empty()&&zerotier.is_none(){return if defender{"present"}else{"unavailable"};}
    let networking=zerotier.is_some();
    // A previous Defender refusal must not silently suppress a new LAN repair
    // for six hours (or seven days). Each permission has its own quiet period.
    if !force&&retry_pending(&state,networking,now()){return "skipped";}
    let result=state_path.with_file_name(format!("defender-result-{}.txt",std::process::id()));
    let _=fs::remove_file(&result);
    if let Some(app)=app{let _=app.emit(AUTHORIZATION_EVENT,true);}
    let elevation=run_elevated(&elevated_script(&missing,&result,zerotier.as_deref().unwrap_or_default()));
    if let Some(app)=app{let _=app.emit(AUTHORIZATION_EVENT,false);}
    let status=match elevation{
        Elevation::Declined=>{
            if networking{state.network_retry_after=now()+DECLINED_RETRY_SECONDS;}
            if !missing.is_empty(){state.retry_after=now()+DECLINED_RETRY_SECONDS;}
            "declined"
        }
        Elevation::Failed=>"failed",
        Elevation::Finished=>{
            let lines:Vec<String>=fs::read_to_string(&result).unwrap_or_default().lines()
                .map(|line|line.trim_start_matches('\u{feff}').trim().to_string()).filter(|line|!line.is_empty()).collect();
            for line in lines.iter().filter(|line|line.starts_with("zerotier:")||line.starts_with("error:")){
                crate::services::diagnostics::log("windows",line);
            }
            let network_complete=lines.iter().any(|line|line=="zerotier:lan")
                &&!lines.iter().any(|line|line.starts_with("zerotier:error:"));
            let added:Vec<String>=lines.into_iter().filter(|line|!line.starts_with("zerotier:")&&!line.starts_with("error:")).collect();
            let complete=added.len()==missing.len();
            let zerotier_only=missing.is_empty();
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
pub(crate) fn ensure(app:&AppHandle,extra:&[PathBuf]){
    let status=request(Some(app),extra,false);
    if !matches!(status,"present"|"skipped"){crate::services::diagnostics::log("defender",&format!("exclusiones al abrir: {status}"));}
}

/// Installing or moving into a folder is something the player just chose, so it asks even inside
/// the quiet period after an earlier «No»: otherwise Defender could strip the fix files on the way.
pub(crate) fn ensure_for_new_folder(app:&AppHandle,root:&Path){
    let status=request(Some(app),std::slice::from_ref(&root.to_path_buf()),true);
    if status!="present"{crate::services::diagnostics::log("defender",&format!("exclusiones al instalar o mover: {status}"));}
}

/// Everything Windows needs to approve, asked together once when Coco opens: Defender for
/// the game folders and, when missing, ZeroTier for playing with the host. Never blocks the
/// launcher: a refusal, no Defender or the host being offline all leave Coco fully usable.
#[tauri::command]
pub async fn prepare_windows(app:AppHandle)->Result<&'static str,String>{
    use tauri::Manager;
    let status=crate::services::network::get_network_status().await.ok();
    let zerotier_missing=status.as_ref().is_some_and(|s|s.setup_supported&&s.service_installed==Some(false));
    // Membership comes from ZeroTier's own API: its CLI lives in different folders per installer
    // version, and a wrong "not joined" would ask for permission on every start.
    let membership=tauri::async_runtime::spawn_blocking(crate::services::zerotier_host::local_membership).await.ok().flatten();
    let needs_join=status.as_ref().is_some_and(|s|s.setup_supported&&s.service_installed==Some(true))
        &&!membership.as_ref().is_some_and(|(joined,_)|*joined);
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
        let status=request_with(Some(&app),&[],false,script);
        crate::services::diagnostics::log("windows",&format!("preparación al abrir: {status}"));
        status
    }).await.map_err(|error|format!("Autorización interrumpida: {error}"))
}

#[tauri::command]
pub async fn ensure_defender_exclusions(app:AppHandle)->Result<&'static str,String>{
    tauri::async_runtime::spawn_blocking(move||request(Some(&app),&[],true))
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
        desired_paths(Path::new(APP),Path::new(LOCAL),&map(locations),&extra.iter().map(PathBuf::from).collect::<Vec<_>>(),Some(Path::new(HOME)))
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
