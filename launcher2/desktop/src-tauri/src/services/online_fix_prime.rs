//! First run of an Online-Fix game on a PC, done out of sight. The fix shows its credits popup
//! and opens its website until it has written a hash into OnlineFix.ini, and that hash is tied
//! to the PC: one made on the host's machine does not satisfy a friend's. So the first time,
//! Coco starts the game on a desktop of its own that is never shown, inside a job that allows
//! that single process (no browser, no helper can start), presses the popup's OK there, waits
//! for the fix to write this PC's hash and ends the run. The real launch then finds a valid
//! hash and neither the popup nor the website appear.
use std::path::Path;
use std::time::{Duration,Instant};

#[derive(Debug,Default,Clone,Copy,PartialEq)]
pub(crate) struct PrimeOutcome{
    /// The credits popup appeared on the hidden desktop and was answered there.
    pub(crate) popup_answered:bool,
    /// The fix wrote a new hash while it ran.
    pub(crate) hash_written:bool,
    /// The game could be started at all.
    pub(crate) started:bool,
    /// It was still running when the wait ended, having written nothing: its fix found a hash it
    /// accepts. A game that closed by itself first proves nothing and gets another first run.
    pub(crate) survived:bool,
}

impl PrimeOutcome{
    /// Whether what the fix holds now can be kept as this PC's.
    pub(crate) fn conclusive(&self)->bool{self.started&&(self.hash_written||self.survived)}
}

/// How long to wait for the fix. It checks its hash as the game process starts (about a second
/// in every game tried); a fix that needs nothing simply lets the wait run out.
pub(crate) const PRIME_LIMIT:Duration=Duration::from_secs(15);
/// The fix writes its hash and only then asks Windows for the popup, which Windows shows on the
/// visible desktop and keeps even after the game is gone. So the ini is watched closely and the
/// game ended the moment the hash lands, before it reaches the popup.
const WATCH_EVERY:Duration=Duration::from_millis(2);
const POPUP_SCAN_EVERY:Duration=Duration::from_millis(60);
/// How long a rewritten ini must stay unchanged before the run ends.
const SETTLED_FOR:Duration=Duration::from_millis(25);

#[cfg(windows)]
pub(crate) fn prime(exe:&Path,root:&Path,args:&[String],hash_written:&(dyn Fn()->bool+Sync),limit:Duration)->PrimeOutcome{
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{CloseHandle,WAIT_OBJECT_0};
    use windows_sys::Win32::System::JobObjects::*;
    use windows_sys::Win32::System::StationsAndDesktops::{CloseDesktop,CreateDesktopW,SetThreadDesktop};
    use windows_sys::Win32::System::Threading::*;
    let wide=|text:&std::ffi::OsStr|text.encode_wide().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let quote=|text:&str|if text.is_empty()||text.contains([' ','\t','"']){format!("\"{}\"",text.replace('"',"\\\""))}else{text.to_string()};

    let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|time|time.as_nanos()).unwrap_or_default();
    let desktop_name=format!("CocoFirstRun-{}-{nonce}",std::process::id());
    let desktop_wide=wide(std::ffi::OsStr::new(&desktop_name));
    // GENERIC_ALL on a desktop of our own: it is created hidden and never switched to.
    let desktop=unsafe{CreateDesktopW(desktop_wide.as_ptr(),std::ptr::null(),std::ptr::null(),0,0x1000_0000,std::ptr::null())};
    if desktop.is_null(){return PrimeOutcome::default();}

    let job=unsafe{CreateJobObjectW(std::ptr::null(),std::ptr::null())};
    if job.is_null(){unsafe{CloseDesktop(desktop)};return PrimeOutcome::default();}
    let mut limits:JOBOBJECT_EXTENDED_LIMIT_INFORMATION=unsafe{std::mem::zeroed()};
    // One process: the game. Windows refuses any other it tries to start, the browser included.
    limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_ACTIVE_PROCESS|JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE|JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    limits.BasicLimitInformation.ActiveProcessLimit=1;
    let limited=unsafe{SetInformationJobObject(job,JobObjectExtendedLimitInformation,
        (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32)};
    if limited==0{unsafe{CloseHandle(job);CloseDesktop(desktop)};return PrimeOutcome::default();}

    let exe_wide=wide(exe.as_os_str());
    let root_wide=wide(root.as_os_str());
    let line=std::iter::once(quote(&exe.to_string_lossy())).chain(args.iter().map(|arg|quote(arg))).collect::<Vec<_>>().join(" ");
    let mut line_wide=wide(std::ffi::OsStr::new(&line));
    let mut desktop_field=desktop_wide.clone();
    let mut startup:STARTUPINFOW=unsafe{std::mem::zeroed()};
    startup.cb=std::mem::size_of::<STARTUPINFOW>() as u32;
    startup.lpDesktop=desktop_field.as_mut_ptr();
    let mut info:PROCESS_INFORMATION=unsafe{std::mem::zeroed()};
    // Suspended until it is inside the job, so not even its first instruction runs unlimited.
    let created=unsafe{CreateProcessW(exe_wide.as_ptr(),line_wide.as_mut_ptr(),std::ptr::null(),std::ptr::null(),0,
        CREATE_SUSPENDED,std::ptr::null(),root_wide.as_ptr(),&startup,&mut info)};
    if created==0{unsafe{CloseHandle(job);CloseDesktop(desktop)};return PrimeOutcome::default();}
    if unsafe{AssignProcessToJobObject(job,info.hProcess)}==0{
        unsafe{TerminateProcess(info.hProcess,1);CloseHandle(info.hThread);CloseHandle(info.hProcess);CloseHandle(job);CloseDesktop(desktop)};
        return PrimeOutcome::default();
    }
    unsafe{ResumeThread(info.hThread)};

    let pid=info.dwProcessId;
    let process=info.hProcess as usize;
    let desktop_handle=desktop as usize;
    let job_handle=job as usize;
    // A thread that owns no window can move to the hidden desktop and see its windows there.
    let outcome=std::thread::scope(|scope|scope.spawn(move||{
        unsafe{SetThreadDesktop(desktop_handle as _)};
        let started=Instant::now();
        let mut answered=false;
        let mut written=false;
        let mut exited=false;
        let mut last_scan=started;
        let pids=std::collections::HashSet::from([pid]);
        while started.elapsed()<limit{
            if hash_written(){
                // Ended at once: what the fix had to do here is done.
                unsafe{TerminateJobObject(job_handle as _,0)};
                written=true;
                break;
            }
            if last_scan.elapsed()>=POPUP_SCAN_EVERY{
                if super::game_prepare::answer_fix_popups(&pids){answered=true;}
                last_scan=Instant::now();
            }
            if unsafe{WaitForSingleObject(process as _,0)}==WAIT_OBJECT_0{exited=true;break;}
            std::thread::sleep(WATCH_EVERY);
        }
        let written=written||hash_written();
        PrimeOutcome{popup_answered:answered,hash_written:written,started:true,survived:!written&&!exited}
    }).join().unwrap_or_default());

    unsafe{
        TerminateJobObject(job,0);
        WaitForSingleObject(info.hProcess,5000);
        CloseHandle(info.hThread);CloseHandle(info.hProcess);CloseHandle(job);
        CloseDesktop(desktop);
    }
    outcome
}

/// The whole first run of a game on this PC: every folder where its fix runs, started through the
/// program that loads it there. True when every one of them settled its hash.
pub(crate) fn first_run(root:&Path,game_exe:&Path,launch_arguments:&[String])->bool{
    use crate::services::game_prepare::{fix_dirs,fix_watch_files,first_run_exe,hash_sections,ini_complete,inis_complete,sweep_fix_popups};
    let watched=fix_watch_files(root);
    // Kept to put back should a run end while the fix is rewriting one: a broken ini breaks the game.
    let originals:Vec<Option<Vec<u8>>>=watched.iter().map(|file|std::fs::read(file).ok()).collect();
    let mut conclusive=true;
    // Should a fix show its box before writing (not seen in any game yet), it never stays up.
    crate::services::launch_guard::guard_credits_box(PRIME_LIMIT*fix_dirs(root).len() as u32+Duration::from_secs(5));
    for dir in fix_dirs(root){
        let Some(exe)=first_run_exe(&dir,game_exe) else {
            crate::services::diagnostics::log("online-fix",&format!("sin ejecutable junto al fix en {}",dir.display()));
            conclusive=false;
            continue;
        };
        let args:&[String]=if exe==game_exe{launch_arguments}else{&[]};
        let before=hash_sections(&watched);
        let last=std::sync::Mutex::new((before.clone(),Instant::now()));
        // Written once [Hashes] differs, every ini is whole and nothing has moved for a while:
        // never while the fix is halfway through rewriting the file.
        let written=||{
            let now=hash_sections(&watched);
            if now==before||!inis_complete(&watched){return false;}
            // A whole new 1337 is the last thing the fix writes, right before it asks for the popup:
            // end at once. Anything else must first stay still a moment.
            if now.iter().zip(&before).any(|(now,was)|now!=was&&now.lines().any(|line|line.starts_with("1337="))){return true;}
            let Ok(mut previous)=last.lock() else {return false};
            if previous.0!=now{*previous=(now,Instant::now());return false;}
            previous.1.elapsed()>=SETTLED_FOR
        };
        let outcome=prime(&exe,&dir,args,&written,PRIME_LIMIT);
        crate::services::diagnostics::log("online-fix",&format!("primera vez en este PC con {}: {outcome:?}",exe.display()));
        conclusive&=outcome.conclusive();
    }
    // A run ended mid-write leaves a broken ini: put the original back and try again next time.
    for (file,original) in watched.iter().zip(&originals){
        let Some(original)=original else {continue};
        let whole=std::fs::read(file).is_ok_and(|bytes|ini_complete(&String::from_utf8_lossy(&bytes)));
        if !whole{
            let _=std::fs::write(file,original);
            crate::services::diagnostics::log("online-fix",&format!("ini restaurado tras una primera vez incompleta: {}",file.display()));
            conclusive=false;
        }
    }
    // Should the box still have made it to the screen, it does not stay there.
    sweep_fix_popups(Duration::from_secs(3));
    conclusive
}

#[cfg(all(test,windows))]
mod tests{
    use super::*;

    /// Lets the fix get its credits box onto the screen on purpose (the browser still cannot start)
    /// and checks that Coco's closer takes it away. Manual only, like the one below.
    #[test]
    #[ignore]
    fn real_credits_box_is_closed_if_it_ever_reaches_the_screen(){
        let root=std::path::PathBuf::from(std::env::var("COCO_PRIME_ROOT").expect("COCO_PRIME_ROOT"));
        let game=root.join(std::env::var("COCO_PRIME_EXE").expect("COCO_PRIME_EXE"));
        let started=Instant::now();
        let outcome=prime(&game,&root,&[],&||started.elapsed()>Duration::from_millis(2500),PRIME_LIMIT);
        let shown=crate::services::game_prepare::answer_fix_popups(&std::collections::HashSet::new());
        crate::services::game_prepare::sweep_fix_popups(Duration::from_secs(2));
        let still=crate::services::game_prepare::answer_fix_popups(&std::collections::HashSet::new());
        println!("outcome {outcome:?}; box shown: {shown}; still on screen after closing: {still}");
        assert!(!still,"Coco could not close the credits box");
    }

    /// The same first run Coco does, on a real installed game. Manual only, and only on a copy or
    /// with a backup of its OnlineFix.ini (put an invalid 1337 there to force the popup case):
    /// COCO_PRIME_ROOT=<game folder> COCO_PRIME_EXE=<exe relative to it> cargo test --lib real_first_run -- --ignored --nocapture
    #[test]
    #[ignore]
    fn real_first_run_writes_this_pcs_hash_without_showing_anything(){
        use crate::services::game_prepare::{fix_dirs,fix_watch_files,first_run_exe,hash_sections};
        let root=std::path::PathBuf::from(std::env::var("COCO_PRIME_ROOT").expect("COCO_PRIME_ROOT"));
        let game=root.join(std::env::var("COCO_PRIME_EXE").expect("COCO_PRIME_EXE"));
        for dir in fix_dirs(&root){println!("fix folder {} -> {:?}",dir.display(),first_run_exe(&dir,&game));}
        let watched=fix_watch_files(&root);
        let before=hash_sections(&watched);
        let started=Instant::now();
        let conclusive=first_run(&root,&game,&[]);
        let after=hash_sections(&watched);
        println!("conclusive {conclusive} in {:?}; hashes changed: {}",started.elapsed(),before!=after);
        // Did the credits box reach the visible desktop anyway?
        let mut seen=false;
        for _ in 0..75{seen|=crate::services::game_prepare::answer_fix_popups(&std::collections::HashSet::new());std::thread::sleep(Duration::from_millis(40));}
        println!("credits box on screen afterwards: {seen}");
        assert!(conclusive);
        assert!(!seen);
        // Optional host installation: keep the learned per-PC trust through the
        // same production function, so the next normal launch need not repeat it.
        if let Ok(id)=std::env::var("COCO_PRIME_ID"){
            let entry=crate::services::catalog::read_catalog().unwrap().into_iter().find(|entry|entry.id==id).expect("catalog id");
            crate::services::game_prepare::trust_current(&entry,&root);
        }
    }
}

#[cfg(not(windows))]
pub(crate) fn prime(_exe:&Path,_root:&Path,_args:&[String],_hash_written:&(dyn Fn()->bool+Sync),_limit:Duration)->PrimeOutcome{
    PrimeOutcome::default()
}
