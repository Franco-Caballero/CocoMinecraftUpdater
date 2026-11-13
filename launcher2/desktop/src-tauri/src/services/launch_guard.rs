//! Guards around every game Coco opens, for whatever a fix does when its hash is not accepted
//! (a first run that could not settle it, a fix that keeps no ini, one not seen yet):
//! - the game and everything it starts share a job that Windows reports each new process from,
//!   and a browser among them is ended before it can hand its page to a browser already open;
//! - Windows reports each window as it appears, and the fix's credits box is hidden and answered
//!   the moment it is shown, instead of waiting for a periodic scan.
//! Neither limits the game: it may start any other process it needs.
use std::time::Duration;

/// Browsers a game or a fix may start to show a page. A process with one of these names that the
/// game itself started is never something the game needs.
const BROWSERS:&[&str]=&["brave.exe","chrome.exe","msedge.exe","firefox.exe","opera.exe","opera_gx.exe",
    "vivaldi.exe","iexplore.exe","yandex.exe","browser.exe","arc.exe","librewolf.exe","waterfox.exe",
    "thorium.exe","chromium.exe","palemoon.exe","floorp.exe","zen.exe","whale.exe","maxthon.exe","seamonkey.exe"];

/// True for a browser's program: a known name, or any program this PC registers as a browser,
/// whatever it is called (Zen registers itself as Firefox, for one). Opera starts through a
/// generic launcher.exe, so that one counts only at its registered path.
pub(crate) fn is_browser(path:&str)->bool{
    let lower=path.replace('/',"\\").to_ascii_lowercase();
    let name=lower.rsplit('\\').next().unwrap_or("");
    if name.is_empty(){return false;}
    if BROWSERS.contains(&name)||(name=="launcher.exe"&&lower.contains("\\opera")){return true;}
    let registered=registered_browsers();
    registered.iter().any(|known|*known==lower)||(name!="launcher.exe"&&registered.iter().any(|known|known.rsplit('\\').next()==Some(name)))
}

/// Programs that hand a link on to a browser outside the game's job: a new explorer.exe passes it
/// to the desktop's own Explorer, and the other two open web apps and «open with». A game needs
/// none of them to run.
pub(crate) fn is_link_opener(path:&str)->bool{
    let lower=path.replace('/',"\\").to_ascii_lowercase();
    let name=lower.rsplit('\\').next().unwrap_or("");
    matches!(name,"explorer.exe"|"launchwinapp.exe"|"openwith.exe")
}

/// The program in a shell command line: «"C:\x\y.exe" -osint -url "%1"» gives C:\x\y.exe.
fn command_program(command:&str)->Option<String>{
    let command=command.trim();
    let program=if let Some(rest)=command.strip_prefix('"'){rest.split('"').next()?.to_string()}
        else{let lower=command.to_ascii_lowercase();command[..lower.find(".exe")?+4].to_string()};
    Some(program.replace('/',"\\").to_ascii_lowercase())
}

/// Browsers registered on this PC: the one opening http and https links, and every program listed
/// as an internet client for this user and the machine.
fn registered_browsers()->&'static Vec<String>{
    static FOUND:std::sync::OnceLock<Vec<String>>=std::sync::OnceLock::new();
    FOUND.get_or_init(||{
        let mut found=Vec::new();
        #[cfg(windows)]{
            use crate::services::game_prepare::registry::{read,CLASSES,MACHINE,USER};
            for scheme in ["http","https"]{
                let choice=format!("Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\{scheme}\\UserChoice");
                if let Some(program)=read(USER,&choice,"ProgId").and_then(|id|read(CLASSES,&format!("{id}\\shell\\open\\command"),""))
                    .and_then(|command|command_program(&command)){found.push(program);}
            }
            for (root,base) in [(MACHINE,"Software\\Clients\\StartMenuInternet"),(MACHINE,"Software\\WOW6432Node\\Clients\\StartMenuInternet"),(USER,"Software\\Clients\\StartMenuInternet")]{
                for client in subkeys(root,base){
                    if let Some(program)=read(root,&format!("{base}\\{client}\\shell\\open\\command"),"").and_then(|command|command_program(&command)){
                        found.push(program);
                    }
                }
            }
        }
        found.sort();found.dedup();
        found
    })
}

#[cfg(windows)]
fn subkeys(root:windows_sys::Win32::System::Registry::HKEY,path:&str)->Vec<String>{
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::System::Registry::{RegCloseKey,RegEnumKeyExW,RegOpenKeyExW,HKEY,KEY_READ};
    let wide:Vec<u16>=std::ffi::OsStr::new(path).encode_wide().chain(std::iter::once(0)).collect();
    let mut key:HKEY=std::ptr::null_mut();
    if unsafe{RegOpenKeyExW(root,wide.as_ptr(),0,KEY_READ,&mut key)}!=0{return Vec::new();}
    let mut names=Vec::new();
    for index in 0..256u32{
        let mut buffer=[0u16;256];
        let mut length=buffer.len() as u32;
        let status=unsafe{RegEnumKeyExW(key,index,buffer.as_mut_ptr(),&mut length,std::ptr::null(),std::ptr::null_mut(),std::ptr::null_mut(),std::ptr::null_mut())};
        if status!=0{break;}
        names.push(String::from_utf16_lossy(&buffer[..length as usize]));
    }
    unsafe{RegCloseKey(key)};
    names
}

/// Puts a just-started game in a job of its own (it inherits it to everything it starts) and ends
/// any browser that appears in it. Lasts as long as the game's processes; best effort.
#[cfg(windows)]
pub(crate) fn guard_children(process:std::os::windows::io::RawHandle){
    use windows_sys::Win32::Foundation::{CloseHandle,INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::IO::{CreateIoCompletionPort,GetQueuedCompletionStatus,OVERLAPPED};
    use windows_sys::Win32::System::JobObjects::*;
    use windows_sys::Win32::System::Threading::{OpenProcess,QueryFullProcessImageNameW,TerminateProcess,
        PROCESS_QUERY_LIMITED_INFORMATION,PROCESS_TERMINATE};
    const MSG_ACTIVE_PROCESS_ZERO:u32=4;
    const MSG_NEW_PROCESS:u32=6;
    let job=unsafe{CreateJobObjectW(std::ptr::null(),std::ptr::null())};
    if job.is_null(){return;}
    let port=unsafe{CreateIoCompletionPort(INVALID_HANDLE_VALUE,std::ptr::null_mut(),0,1)};
    if port.is_null(){unsafe{CloseHandle(job)};return;}
    let link=JOBOBJECT_ASSOCIATE_COMPLETION_PORT{CompletionKey:job,CompletionPort:port};
    let linked=unsafe{SetInformationJobObject(job,JobObjectAssociateCompletionPortInformation,
        (&link as *const JOBOBJECT_ASSOCIATE_COMPLETION_PORT).cast(),std::mem::size_of::<JOBOBJECT_ASSOCIATE_COMPLETION_PORT>() as u32)};
    // No limits: the game may start what it likes, and closing Coco leaves it running. A program
    // that asks to leave the job may (some launchers and crash reporters do, and would fail
    // otherwise); a browser opened for a page never asks.
    let mut limits:JOBOBJECT_EXTENDED_LIMIT_INFORMATION=unsafe{std::mem::zeroed()};
    limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    unsafe{SetInformationJobObject(job,JobObjectExtendedLimitInformation,
        (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32)};
    if linked==0||unsafe{AssignProcessToJobObject(job,process as _)}==0{
        unsafe{CloseHandle(port);CloseHandle(job)};
        return;
    }
    let (job,port)=(job as usize,port as usize);
    std::thread::spawn(move||{
        loop{
            let (mut message,mut key,mut overlapped)=(0u32,0usize,std::ptr::null_mut::<OVERLAPPED>());
            if unsafe{GetQueuedCompletionStatus(port as _,&mut message,&mut key,&mut overlapped,u32::MAX)}==0{break;}
            if message==MSG_ACTIVE_PROCESS_ZERO{break;}
            if message!=MSG_NEW_PROCESS{continue;}
            let pid=overlapped as usize as u32;
            let handle=unsafe{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_TERMINATE,0,pid)};
            if handle.is_null(){continue;}
            let mut buffer=[0u16;1024];
            let mut length=buffer.len() as u32;
            let named=unsafe{QueryFullProcessImageNameW(handle,0,buffer.as_mut_ptr(),&mut length)}!=0;
            let path=if named{String::from_utf16_lossy(&buffer[..length as usize])}else{String::new()};
            if is_browser(&path)||is_link_opener(&path){
                unsafe{TerminateProcess(handle,1)};
                crate::services::diagnostics::log("online-fix",&format!("navegador iniciado por el juego, cerrado al nacer: {path}"));
            }
            unsafe{CloseHandle(handle)};
        }
        unsafe{CloseHandle(port as _);CloseHandle(job as _)};
    });
}

#[cfg(not(windows))]
pub(crate) fn guard_children(_process:*mut std::ffi::c_void){}

/// Lets a game started paused run. It is started that way so it is inside its job before its
/// first instruction: nothing it starts, however early, escapes the guard.
#[cfg(windows)]
pub(crate) fn resume(process:std::os::windows::io::RawHandle){
    #[link(name="ntdll")]
    extern "system"{fn NtResumeProcess(process:*mut std::ffi::c_void)->i32;}
    unsafe{NtResumeProcess(process as _)};
}

/// For this long, the fix's credits box is answered the moment Windows shows it, anywhere.
#[cfg(windows)]
pub(crate) fn guard_credits_box(duration:Duration){
    use std::ffi::c_void;
    type Hwnd=*mut c_void;
    #[repr(C)]
    struct Msg{hwnd:Hwnd,message:u32,wparam:usize,lparam:isize,time:u32,pt_x:i32,pt_y:i32,private:u32}
    type WinEventProc=unsafe extern "system" fn(*mut c_void,u32,Hwnd,i32,i32,u32,u32);
    #[link(name="user32")]
    extern "system"{
        fn SetWinEventHook(min:u32,max:u32,module:*mut c_void,callback:WinEventProc,process:u32,thread:u32,flags:u32)->*mut c_void;
        fn UnhookWinEvent(hook:*mut c_void)->i32;
        fn GetMessageW(msg:*mut Msg,hwnd:Hwnd,min:u32,max:u32)->i32;
        fn DispatchMessageW(msg:*const Msg)->isize;
        fn PostThreadMessageW(thread:u32,message:u32,wparam:usize,lparam:isize)->i32;
    }
    #[link(name="kernel32")]
    extern "system"{fn GetCurrentThreadId()->u32;}
    const EVENT_OBJECT_SHOW:u32=0x8002;
    const OBJID_WINDOW:i32=0;
    const WINEVENT_OUTOFCONTEXT:u32=0;
    const WINEVENT_SKIPOWNPROCESS:u32=2;
    const WM_QUIT:u32=0x0012;
    unsafe extern "system" fn shown(_hook:*mut c_void,_event:u32,window:Hwnd,object:i32,_child:i32,_thread:u32,_time:u32){
        if object!=OBJID_WINDOW||window.is_null(){return;}
        if crate::services::game_prepare::answer_fix_popup_window(window as usize){
            crate::services::diagnostics::log("online-fix","aviso del fix ocultado y respondido al aparecer");
        }
    }
    std::thread::spawn(move||{
        let thread=unsafe{GetCurrentThreadId()};
        let hook=unsafe{SetWinEventHook(EVENT_OBJECT_SHOW,EVENT_OBJECT_SHOW,std::ptr::null_mut(),shown,0,0,WINEVENT_OUTOFCONTEXT|WINEVENT_SKIPOWNPROCESS)};
        if hook.is_null(){return;}
        std::thread::spawn(move||{std::thread::sleep(duration);unsafe{PostThreadMessageW(thread,WM_QUIT,0,0)};});
        let mut message:Msg=unsafe{std::mem::zeroed()};
        // Out-of-context events arrive through this thread's message loop.
        while unsafe{GetMessageW(&mut message,std::ptr::null_mut(),0,0)}>0{unsafe{DispatchMessageW(&message)};}
        unsafe{UnhookWinEvent(hook)};
    });
}

#[cfg(not(windows))]
pub(crate) fn guard_credits_box(_duration:Duration){}

#[cfg(test)]
mod tests{
    use super::*;

    /// The worst case on a real game: opened normally with a hash its fix rejects, guarded only by
    /// this module. Manual; it shows the game for a few seconds:
    /// COCO_GUARD_ROOT=<folder> COCO_GUARD_EXE=<exe> cargo test --lib a_rejected_hash -- --ignored --nocapture
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn a_rejected_hash_shows_no_box_and_opens_no_page(){
        use std::os::windows::io::AsRawHandle;
        let root=std::path::PathBuf::from(std::env::var("COCO_GUARD_ROOT").expect("COCO_GUARD_ROOT"));
        let exe=root.join(std::env::var("COCO_GUARD_EXE").expect("COCO_GUARD_EXE"));
        let seconds=std::env::var("COCO_GUARD_SECONDS").ok().and_then(|value|value.parse::<u64>().ok()).unwrap_or(8).clamp(5,180);
        let args:Vec<String>=std::env::var("COCO_GUARD_ARGS").ok().map(|value|serde_json::from_str(&value).expect("COCO_GUARD_ARGS JSON array")).unwrap_or_default();
        guard_credits_box(Duration::from_secs(seconds+5));
        std::thread::sleep(Duration::from_millis(300));
        // Exactly as Coco starts a game: paused, put in its job, then let go.
        let mut game={use std::os::windows::process::CommandExt;std::process::Command::new(&exe).args(&args).current_dir(&root).creation_flags(0x4).spawn().unwrap()};
        guard_children(game.as_raw_handle());
        resume(game.as_raw_handle());
        let mut seen=false;
        for _ in 0..seconds*10{
            // Whatever the instant guard leaves on screen is seen here.
            seen|=crate::services::game_prepare::answer_fix_popups(&std::collections::HashSet::new());
            std::thread::sleep(Duration::from_millis(100));
        }
        let alive=game.try_wait().unwrap().is_none();
        let _=game.kill();let _=game.wait();
        println!("credits box still found by the slow scan: {seen}; game running after {seconds}s: {alive}");
        assert!(!seen,"credits box escaped the immediate guard");
        if std::env::var_os("COCO_GUARD_REQUIRE_RUNNING").is_some(){assert!(alive,"game exited before the launch probe ended");}
    }

    /// A stand-in game starts a stand-in browser (ping.exe renamed chrome.exe): the guard must end
    /// it at birth. Manual, it starts real processes:
    /// cargo test --lib a_browser_started_by_the_game -- --ignored --nocapture
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn a_browser_started_by_the_game_dies_at_birth(){
        use std::os::windows::io::AsRawHandle;
        let dir=std::env::temp_dir().join(format!("coco-guard-{}",std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fake=dir.join("chrome.exe");
        std::fs::copy(std::path::Path::new(&std::env::var("SystemRoot").unwrap()).join("System32\\PING.EXE"),&fake).unwrap();
        // The «game» waits a moment (so the guard is in place, as Coco does right after spawning),
        // then starts the «browser» and reports how it ended.
        let script=format!("ping -n 2 127.0.0.1 >nul & \"{}\" -n 30 127.0.0.1 >nul",fake.display());
        let mut game=std::process::Command::new("cmd.exe").args(["/d","/c",&script]).stdout(std::process::Stdio::piped()).spawn().unwrap();
        guard_children(game.as_raw_handle());
        let started=std::time::Instant::now();
        let output=game.wait_with_output().unwrap();
        let text=String::from_utf8_lossy(&output.stdout);
        println!("game finished in {:?}{}",started.elapsed(),text.trim());
        let _=std::fs::remove_dir_all(&dir);
        // Unguarded, the stand-in browser would run 30 seconds.
        assert!(started.elapsed()<Duration::from_secs(8),"the browser was not ended");
    }

    #[test]
    fn programs_that_pass_a_link_on_are_ended_too(){
        for path in ["C:/Windows/explorer.exe","C:/Windows/System32/LaunchWinApp.exe","C:/Windows/System32/OpenWith.exe"]{
            assert!(is_link_opener(path),"{path}");
        }
        for path in ["C:/Games/CRACK/CRACK.exe","C:/Windows/System32/cmd.exe","C:/Games/explorer-tools/game.exe"]{
            assert!(!is_link_opener(path),"{path}");
        }
    }

    #[test]
    fn a_browsers_program_is_read_from_its_registered_command(){
        assert_eq!(command_program("\"C:\\Program Files\\Zen Browser\\zen.exe\" -osint -url \"%1\"").as_deref(),Some("c:\\program files\\zen browser\\zen.exe"));
        assert_eq!(command_program("C:\\Browsers\\Thing.EXE --single-argument %1").as_deref(),Some("c:\\browsers\\thing.exe"));
        assert_eq!(command_program("rundll32 url.dll,FileProtocolHandler %1"),None);
    }

    /// Whatever this PC's default browser is, it is recognised. Runs where a browser is set.
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn this_pcs_registered_browsers_are_recognised(){
        println!("registered: {:?}",registered_browsers());
        assert!(registered_browsers().iter().all(|path|is_browser(path)));
        assert!(!registered_browsers().is_empty());
    }

    #[test]
    fn browsers_are_told_apart_from_games_and_their_helpers(){
        for path in ["C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe","C:/x/chrome.exe",
            "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe","C:\\Users\\a\\AppData\\Local\\Programs\\Opera GX\\launcher.exe",
            "C:\\Program Files\\Mozilla Firefox\\firefox.exe"]{
            assert!(is_browser(path),"{path}");
        }
        for path in ["C:\\Games\\CRACK\\CRACK.exe","C:\\Games\\X\\launcher.exe","C:\\Games\\X\\UnityCrashHandler64.exe",
            "C:\\Games\\Love\\win\\love.exe","C:\\Windows\\System32\\cmd.exe","msedgewebview2.exe",""]{
            assert!(!is_browser(path),"{path}");
        }
    }
}
