//! Own software decoder; RGBA frames shared with WebView2's canvas compositor.
//! No child video HWND: controls, subtitles and hover UI share one DOM layer.
use serde::Serialize;
use std::sync::{Arc,Mutex};
const MAX_WIDTH:usize=1920;
const MAX_HEIGHT:usize=1080;
const HEADER:usize=64;
const SLOT_BYTES:usize=MAX_WIDTH*MAX_HEIGHT*4;
const SHARED_BYTES:usize=HEADER+2*SLOT_BYTES;

#[derive(Clone,Default,Serialize)]
#[serde(rename_all="camelCase")]
pub struct Snapshot {
    position:f64,duration:f64,paused:bool,volume:f64,muted:bool,rate:f64,
    buffering:bool,ended:bool,loaded:bool,has_video:bool,cache_seconds:f64,
    codec:String,error:Option<String>,inputs:Vec<String>,
}
fn valid_request(id:&str)->bool{id.len()==36&&id.bytes().all(|c|c.is_ascii_hexdigit()||c==b'-')}
fn valid_value(action:&str,value:Option<f64>)->Result<f64,String>{
    let (min,max)=match action{"play"|"pause"=>return Ok(0.0),"seek"=>(0.0,86400.0),"volume"|"mute"=>(0.0,1.0),"rate"=>(0.25,4.0),_=>return Err("Unknown player action".into())};
    value.filter(|v|v.is_finite()&&*v>=min&&*v<=max).ok_or("Invalid player value".into())
}

fn copy_bgrx_to_rgba(source:&[u8],target:&mut[u8]){
    assert_eq!(source.len(),target.len());
    let mut at=0;
    #[cfg(target_arch="x86_64")]
    unsafe{
        use std::arch::x86_64::*;
        let green=_mm_set1_epi32(0x0000ff00);let red=_mm_set1_epi32(0x00ff0000);
        let blue=_mm_set1_epi32(0x000000ff);let alpha=_mm_set1_epi32(0xff000000u32 as i32);
        while at+16<=source.len(){
            let p=_mm_loadu_si128(source.as_ptr().add(at) as *const __m128i);
            let swapped=_mm_or_si128(_mm_and_si128(p,green),_mm_or_si128(_mm_srli_epi32(_mm_and_si128(p,red),16),_mm_slli_epi32(_mm_and_si128(p,blue),16)));
            _mm_storeu_si128(target.as_mut_ptr().add(at) as *mut __m128i,_mm_or_si128(swapped,alpha));at+=16;
        }
    }
    for(source,target)in source[at..].chunks_exact(4).zip(target[at..].chunks_exact_mut(4)){target.copy_from_slice(&[source[2],source[1],source[0],255]);}
}

#[cfg(windows)]
mod win {
    use super::*;
    use std::ffi::{c_char,c_void,CString};
    use std::path::{Path,PathBuf};
    use std::sync::{OnceLock,atomic::{AtomicU32,Ordering}};
    use std::time::Duration;
    use tauri::Manager;
    use sha2::{Digest,Sha256};
    use std::io::Read;
    use windows::core::{Interface,PCWSTR};
    use webview2_com::Microsoft::Web::WebView2::Win32::{ICoreWebView2Environment12,ICoreWebView2_17,ICoreWebView2SharedBuffer,COREWEBVIEW2_SHARED_BUFFER_ACCESS_READ_ONLY};

    #[link(name="kernel32")]
    extern "system"{
        fn LoadLibraryExW(path:*const u16,file:isize,flags:u32)->isize;
        fn GetProcAddress(module:isize,name:*const u8)->*mut c_void;
    }
    type P=*mut c_void;
    type Lock=unsafe extern "C" fn(P,*mut P)->P;
    type Unlock=unsafe extern "C" fn(P,P,*const P);
    type Display=unsafe extern "C" fn(P,P);
    type Format=unsafe extern "C" fn(*mut P,*mut c_char,*mut u32,*mut u32,*mut u32,*mut u32)->u32;
    type Cleanup=unsafe extern "C" fn(P);
    #[repr(C)]
    struct MediaTrack{codec:u32,original:u32,id:i32,kind:i32,profile:i32,level:i32,details:P,bitrate:u32,language:*mut c_char,description:*mut c_char}
    #[repr(C)]
    struct VideoTrack{height:u32,width:u32,sar_num:u32,sar_den:u32,rate_num:u32,rate_den:u32,orientation:i32,projection:i32,viewpoint:[f32;4]}
    struct Api {
        _core:isize,_dll:isize,
        new:unsafe extern "C" fn(i32,*const *const c_char)->P,
        release:unsafe extern "C" fn(P),
        media:unsafe extern "C" fn(P,*const c_char)->P,
        media_release:unsafe extern "C" fn(P),
        parse:unsafe extern "C" fn(P,i32,i32)->i32,
        parsed:unsafe extern "C" fn(P)->i32,
        tracks:unsafe extern "C" fn(P,*mut *mut *mut MediaTrack)->u32,
        tracks_release:unsafe extern "C" fn(*mut *mut MediaTrack,u32),
        player:unsafe extern "C" fn(P)->P,
        player_release:unsafe extern "C" fn(P),
        play:unsafe extern "C" fn(P)->i32,
        pause:unsafe extern "C" fn(P,i32),
        stop:unsafe extern "C" fn(P),
        time:unsafe extern "C" fn(P)->i64,
        length:unsafe extern "C" fn(P)->i64,
        set_time:unsafe extern "C" fn(P,i64),
        state:unsafe extern "C" fn(P)->i32,
        volume:unsafe extern "C" fn(P)->i32,
        set_volume:unsafe extern "C" fn(P,i32)->i32,
        mute:unsafe extern "C" fn(P)->i32,
        set_mute:unsafe extern "C" fn(P,i32),
        rate:unsafe extern "C" fn(P)->f32,
        set_rate:unsafe extern "C" fn(P,f32)->i32,
        audio_track:unsafe extern "C" fn(P)->i32,
        callbacks:unsafe extern "C" fn(P,Option<Lock>,Option<Unlock>,Option<Display>,P),
        format:unsafe extern "C" fn(P,Option<Format>,Option<Cleanup>),
    }
    unsafe fn symbol<T:Copy>(module:isize,name:&[u8])->Result<T,String>{
        let ptr=unsafe{GetProcAddress(module,name.as_ptr())};
        if ptr.is_null(){return Err("Bundled decoder API incomplete".into());}
        Ok(unsafe{std::mem::transmute_copy(&ptr)})
    }
    fn verify(directory:&Path)->Result<(),String>{
        let manifest:serde_json::Value=serde_json::from_str(include_str!("../../resources/vlc-runtime-manifest.json")).map_err(|_|"Invalid decoder manifest")?;
        for entry in manifest["files"].as_array().ok_or("Incomplete decoder manifest")?{
            let relative=entry["path"].as_str().ok_or("Invalid decoder path")?;
            if relative.starts_with('/')||relative.split('/').any(|p|p==".."||p.contains(':')){return Err("Unsafe decoder path".into());}
            let path=directory.join(relative);
            let meta=std::fs::symlink_metadata(&path).map_err(|_|"Falta un archivo del motor de vídeo. Reinstala Coco.")?;
            use std::os::windows::fs::MetadataExt;
            if meta.file_attributes()&0x400!=0||!meta.is_file()||meta.len()!=entry["size"].as_u64().unwrap_or(0){return Err("Altered decoder file".into());}
            let mut file=std::fs::File::open(path).map_err(|_|"Cannot verify decoder")?;
            let mut hash=Sha256::new();let mut block=[0u8;65536];
            loop{let n=file.read(&mut block).map_err(|_|"Cannot verify decoder")?;if n==0{break;}hash.update(&block[..n]);}
            if format!("{:x}",hash.finalize())!=entry["sha256"].as_str().unwrap_or(""){return Err("Decoder hash mismatch".into());}
        }
        Ok(())
    }
    fn runtime(app:&tauri::AppHandle)->Result<PathBuf,String>{
        #[cfg(debug_assertions)]
        if let Some(path)=std::env::var_os("COCO_PLAYER_RUNTIME"){return Ok(path.into());}
        Ok(app.path().resource_dir().map_err(|_|"Missing resource directory")?.join("player"))
    }
    fn api(directory:&Path)->Result<Arc<Api>,String>{
        static API:OnceLock<Result<Arc<Api>,String>>=OnceLock::new();
        API.get_or_init(||{
            verify(directory)?;
            // Process-local library path; no system codec/association changes.
            std::env::set_var("VLC_PLUGIN_PATH",directory.join("plugins"));
            let load=|name:&str|->Result<isize,String>{
                let wide:Vec<u16>=directory.join(name).as_os_str().encode_wide().chain(Some(0)).collect();
                let module=unsafe{LoadLibraryExW(wide.as_ptr(),0,0x1100)};
                if module==0{Err("Cannot load bundled decoder".into())}else{Ok(module)}
            };
            use std::os::windows::ffi::OsStrExt;
            let core=load("libvlccore.dll")?;let dll=load("libvlc.dll")?;
            unsafe{Ok(Arc::new(Api{
                _core:core,_dll:dll,
                new:symbol(dll,b"libvlc_new\0")?,release:symbol(dll,b"libvlc_release\0")?,
                media:symbol(dll,b"libvlc_media_new_location\0")?,media_release:symbol(dll,b"libvlc_media_release\0")?,
                parse:symbol(dll,b"libvlc_media_parse_with_options\0")?,parsed:symbol(dll,b"libvlc_media_get_parsed_status\0")?,tracks:symbol(dll,b"libvlc_media_tracks_get\0")?,tracks_release:symbol(dll,b"libvlc_media_tracks_release\0")?,
                player:symbol(dll,b"libvlc_media_player_new_from_media\0")?,player_release:symbol(dll,b"libvlc_media_player_release\0")?,
                play:symbol(dll,b"libvlc_media_player_play\0")?,pause:symbol(dll,b"libvlc_media_player_set_pause\0")?,stop:symbol(dll,b"libvlc_media_player_stop\0")?,
                time:symbol(dll,b"libvlc_media_player_get_time\0")?,length:symbol(dll,b"libvlc_media_player_get_length\0")?,set_time:symbol(dll,b"libvlc_media_player_set_time\0")?,
                state:symbol(dll,b"libvlc_media_player_get_state\0")?,volume:symbol(dll,b"libvlc_audio_get_volume\0")?,set_volume:symbol(dll,b"libvlc_audio_set_volume\0")?,
                mute:symbol(dll,b"libvlc_audio_get_mute\0")?,set_mute:symbol(dll,b"libvlc_audio_set_mute\0")?,rate:symbol(dll,b"libvlc_media_player_get_rate\0")?,set_rate:symbol(dll,b"libvlc_media_player_set_rate\0")?,audio_track:symbol(dll,b"libvlc_audio_get_track\0")?,
                callbacks:symbol(dll,b"libvlc_video_set_callbacks\0")?,format:symbol(dll,b"libvlc_video_set_format_callbacks\0")?,
            }))}
        }).clone()
    }

    struct UiBuffer(ICoreWebView2SharedBuffer);
    // Transport only; COM methods/release execute on the WebView UI thread.
    unsafe impl Send for UiBuffer{}
    impl UiBuffer{fn close(self){unsafe{let _=self.0.Close();}}}
    struct Memory {
        pointer:usize,owner:Mutex<Option<UiBuffer>>,window:Option<tauri::WebviewWindow>,
        #[cfg(test)] _heap:Option<Vec<u32>>,
    }
    // The Buffer() mapping is documented shared memory. Native callbacks only
    // touch the mapping; the apartment-bound interface stays in its UI owner.
    unsafe impl Send for Memory{} unsafe impl Sync for Memory{}
    impl Memory {
        fn word(&self,index:usize)->&AtomicU32{unsafe{&*((self.pointer as *const AtomicU32).add(index))}}
    }
    impl Drop for Memory{
        fn drop(&mut self){
            if let Some(owner)=self.owner.lock().ok().and_then(|mut o|o.take()){
                let raw=Box::into_raw(Box::new(owner)) as usize;
                if let Some(window)=self.window.as_ref(){let _=window.run_on_main_thread(move||unsafe{Box::from_raw(raw as *mut UiBuffer).close();});}
                // If the UI has already exited, the process reclaims the mapping.
            }
        }
    }
    fn shared_memory(window:&tauri::WebviewWindow,id:&str,request:&str)->Result<Arc<Memory>,String>{
        let(tx,rx)=std::sync::mpsc::channel();let owner=window.clone();let id=id.to_owned();let request=request.to_owned();
        window.with_webview(move|view|{
            let result=(||unsafe{
                let environment=view.environment().cast::<ICoreWebView2Environment12>().map_err(|_|"Actualiza Microsoft Edge WebView2 para reproducir vídeo.")?;
                let core=view.controller().CoreWebView2().map_err(|_|"Missing WebView controller")?.cast::<ICoreWebView2_17>().map_err(|_|"Shared video frames unavailable")?;
                let buffer=environment.CreateSharedBuffer(SHARED_BYTES as u64).map_err(|_|"Cannot allocate video frames")?;
                let mut pointer=std::ptr::null_mut();buffer.Buffer(&mut pointer).map_err(|_|"Cannot map video frames")?;
                if pointer.is_null(){return Err("Empty shared video mapping".into());}
                std::ptr::write_bytes(pointer,0,SHARED_BYTES);
                let info=serde_json::json!({"kind":"coco-video-rgba-v1","id":id,"requestId":request,"headerBytes":HEADER,"slotBytes":SLOT_BYTES,"byteLength":SHARED_BYTES}).to_string();
                let info:Vec<u16>=info.encode_utf16().chain(Some(0)).collect();
                core.PostSharedBufferToScript(&buffer,COREWEBVIEW2_SHARED_BUFFER_ACCESS_READ_ONLY,PCWSTR(info.as_ptr())).map_err(|_|"Cannot share video frames")?;
                Ok(Arc::new(Memory{pointer:pointer as usize,owner:Mutex::new(Some(UiBuffer(buffer))),window:Some(owner),#[cfg(test)]_heap:None}))
            })();let _=tx.send(result);
        }).map_err(|_|"Video view closed")?;
        rx.recv_timeout(Duration::from_secs(5)).map_err(|_|"Video view did not respond".to_owned())?
    }
    struct Picture {bytes:Box<[u8]>,width:usize,height:usize,stride:usize}
    struct Context {memory:Arc<Memory>,picture:Mutex<Picture>,visible_width:usize,visible_height:usize}
    unsafe extern "C" fn format(opaque:*mut P,chroma:*mut c_char,width:*mut u32,height:*mut u32,pitches:*mut u32,lines:*mut u32)->u32{
        if opaque.is_null()||unsafe{(*opaque).is_null()}{return 0;}
        let context=unsafe{&*(*opaque as *const Context)};
        // The callback initially receives coded/aligned sizes (e.g. 832 for
        // an 804-line movie). Use visible track dimensions, not decoder padding.
        let (w,h)=(context.visible_width,context.visible_height);if w==0||h==0{return 0;}
        let scale=(MAX_WIDTH as f64/w as f64).min(MAX_HEIGHT as f64/h as f64).min(1.0);
        let w=((w as f64*scale).floor() as usize).max(1);let h=((h as f64*scale).floor() as usize).max(1);
        let stride=(w*4+31)&!31;if stride*h>SLOT_BYTES{return 0;}
        let Ok(mut pic)=context.picture.lock()else{return 0};
        pic.width=w;pic.height=h;pic.stride=stride;
        let seq=context.memory.word(0).load(Ordering::Relaxed);context.memory.word(0).store(seq|1,Ordering::Release);
        unsafe{std::ptr::copy_nonoverlapping(b"RV32".as_ptr(),chroma as *mut u8,4);*width=w as u32;*height=h as u32;*pitches=stride as u32;*lines=h as u32;}
        1
    }
    unsafe extern "C" fn cleanup(_opaque:P){}
    unsafe extern "C" fn lock(opaque:P,planes:*mut P)->P{
        let context=unsafe{&*(opaque as *const Context)};
        let Ok(mut pic)=context.picture.lock()else{return std::ptr::null_mut()};
        unsafe{*planes=pic.bytes.as_mut_ptr() as P;}opaque
    }
    unsafe extern "C" fn unlock(_opaque:P,_picture:P,_planes:*const P){}
    unsafe extern "C" fn display(opaque:P,_picture:P){
        let context=unsafe{&*(opaque as *const Context)};let Ok(pic)=context.picture.lock()else{return};
        if pic.width==0||pic.height==0{return;}
        let m=&context.memory;let seq=m.word(0).load(Ordering::Relaxed)|1;m.word(0).store(seq,Ordering::Release);
        let slot=(m.word(1).load(Ordering::Relaxed)^1)&1;
        let destination=unsafe{std::slice::from_raw_parts_mut((m.pointer as *mut u8).add(HEADER+slot as usize*SLOT_BYTES),pic.stride*pic.height)};
        // VLC's portable RV32 output is BGRX on Windows; canvas needs RGBA.
        copy_bgrx_to_rgba(&pic.bytes[..pic.stride*pic.height],destination);
        m.word(1).store(slot,Ordering::Relaxed);m.word(2).store(pic.width as u32,Ordering::Relaxed);m.word(3).store(pic.height as u32,Ordering::Relaxed);m.word(4).store(pic.stride as u32,Ordering::Relaxed);
        m.word(0).store(seq.wrapping_add(1),Ordering::Release);
    }
    struct Player {id:String,label:String,api:Arc<Api>,instance:usize,player:usize,context:Box<Context>}
    impl Drop for Player{fn drop(&mut self){unsafe{(self.api.stop)(self.player as P);(self.api.player_release)(self.player as P);(self.api.release)(self.instance as P);}}}
    fn create(api:Arc<Api>,memory:Arc<Memory>,url:&str,id:String,label:String)->Result<Player,String>{
        let options=["--ignore-config","--no-osd","--no-video-title-show","--no-sub-autodetect-file","--no-stats","--no-media-library","--no-plugins-cache","--avcodec-hw=none","--network-caching=1200"];
        let options:Vec<CString>=options.iter().map(|s|CString::new(*s).unwrap()).collect();let args:Vec<_>=options.iter().map(|s|s.as_ptr()).collect();
        let instance=unsafe{(api.new)(args.len() as i32,args.as_ptr())};if instance.is_null(){return Err("Cannot initialize bundled decoder".into());}
        let source=CString::new(url).map_err(|_|"Invalid movie URL")?;
        let media=unsafe{(api.media)(instance,source.as_ptr())};if media.is_null(){unsafe{(api.release)(instance);}return Err("Cannot open movie".into());}
        let parsed=unsafe{(api.parse)(media,1,5000)};
        if parsed==0{
            let started=std::time::Instant::now();
            while unsafe{(api.parsed)(media)}==0&&started.elapsed()<Duration::from_secs(6){std::thread::sleep(Duration::from_millis(20));}
        }
        let mut tracks=std::ptr::null_mut();let count=unsafe{(api.tracks)(media,&mut tracks)};
        let mut dimensions=None;
        if count>0&&!tracks.is_null(){
            for ptr in unsafe{std::slice::from_raw_parts(tracks,count.min(128) as usize)}{
                if ptr.is_null(){continue;}let track=unsafe{&**ptr};
                if track.kind==1&&!track.details.is_null(){
                    let video=unsafe{&*(track.details as *const VideoTrack)};
                    if video.width>0&&video.height>0{
                        let sar=if video.sar_num>0&&video.sar_den>0{video.sar_num as f64/video.sar_den as f64}else{1.0};
                        dimensions=Some(((video.width as f64*sar).round().clamp(1.0,32768.0) as usize,video.height as usize));break;
                    }
                }
            }
            unsafe{(api.tracks_release)(tracks,count);}
        }
        let Some((visible_width,visible_height))=dimensions else{unsafe{(api.media_release)(media);(api.release)(instance);}return Err("No se pudieron leer las dimensiones del vídeo.".into());};
        let player=unsafe{(api.player)(media)};unsafe{(api.media_release)(media);}
        if player.is_null(){unsafe{(api.release)(instance);}return Err("Cannot create decoder".into());}
        let context=Box::new(Context{memory,picture:Mutex::new(Picture{bytes:vec![0u8;SLOT_BYTES].into_boxed_slice(),width:0,height:0,stride:0}),visible_width,visible_height});
        let opaque=&*context as *const Context as P;
        unsafe{(api.callbacks)(player,Some(lock),Some(unlock),Some(display),opaque);(api.format)(player,Some(format),Some(cleanup));}
        Ok(Player{id,label,api,instance:instance as usize,player:player as usize,context})
    }
    static PLAYER:OnceLock<Mutex<Option<Player>>>=OnceLock::new();static RESERVATION:OnceLock<Mutex<Option<String>>>=OnceLock::new();
    fn slot()->&'static Mutex<Option<Player>>{PLAYER.get_or_init(||Mutex::new(None))}
    fn reservation()->&'static Mutex<Option<String>>{RESERVATION.get_or_init(||Mutex::new(None))}
    pub fn open(app:tauri::AppHandle,window:tauri::WebviewWindow,url:String,request:String)->Result<String,String>{
        if !valid_request(&request)||!super::super::media::active_stream(&url){return Err("Unrecognized prepared movie".into());}
        let mut random=[0u8;16];ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(),&mut random).map_err(|_|"Cannot create video session")?;
        let id=random.iter().map(|b|format!("{b:02x}")).collect::<String>();
        {let mut r=reservation().lock().map_err(|_|"Player unavailable")?;if r.is_some(){return Err("A video is already active".into());}*r=Some(id.clone());}
        let result=(||{let api=api(&runtime(&app)?)?;let memory=shared_memory(&window,&id,&request)?;create(api,memory,&url,id.clone(),window.label().into())})();
        let mut r=reservation().lock().map_err(|_|"Player unavailable")?;
        match result{
            Ok(player)if r.as_ref()==Some(&id)=>{*slot().lock().map_err(|_|"Player unavailable")?=Some(player);Ok(id)},
            Ok(_)=>Err("Video view was closed".into()),
            Err(error)=>{if r.as_ref()==Some(&id){*r=None;}Err(error)}
        }
    }
    pub fn control(window:&tauri::WebviewWindow,id:&str,action:&str,value:Option<f64>)->Result<(),String>{
        let value=valid_value(action,value)?;let guard=slot().lock().map_err(|_|"Player unavailable")?;
        let p=guard.as_ref().filter(|p|p.id==id&&p.label==window.label()).ok_or("Expired movie session")?;
        unsafe{match action{
            "play"=>{if (p.api.play)(p.player as P)!=0{return Err("Cannot start movie".into());}},
            "pause"=>(p.api.pause)(p.player as P,1),"seek"=>(p.api.set_time)(p.player as P,(value*1000.0) as i64),
            "volume"=>{(p.api.set_volume)(p.player as P,(value*100.0).round() as i32);},"mute"=>(p.api.set_mute)(p.player as P,i32::from(value!=0.0)),
            "rate"=>{if (p.api.set_rate)(p.player as P,value as f32)!=0{return Err("Cannot change playback rate".into());}},_=>unreachable!()
        }}Ok(())
    }
    fn snapshot(p:&Player)->Snapshot{unsafe{
        let state=(p.api.state)(p.player as P);let frame=p.context.memory.word(0).load(Ordering::Acquire);let video=frame>0&&frame%2==0;
        Snapshot{position:((p.api.time)(p.player as P).max(0) as f64)/1000.0,duration:((p.api.length)(p.player as P).max(0) as f64)/1000.0,
            paused:state==4,volume:(p.api.volume)(p.player as P).clamp(0,100) as f64/100.0,muted:(p.api.mute)(p.player as P)>0,rate:(p.api.rate)(p.player as P) as f64,
            buffering:matches!(state,1|2),ended:state==6,loaded:video,has_video:video,cache_seconds:0.0,codec:"VLC / FFmpeg".into(),error:if state==7{Some("No se pudo abrir o decodificar el vídeo.".into())}else{None},inputs:Vec::new()}
    }}
    pub fn status(window:&tauri::WebviewWindow,id:&str)->Result<Snapshot,String>{
        let guard=slot().lock().map_err(|_|"Player unavailable")?;let p=guard.as_ref().filter(|p|p.id==id&&p.label==window.label()).ok_or("Expired movie session")?;Ok(snapshot(p))
    }
    pub fn close(window:&tauri::WebviewWindow,id:&str)->Result<bool,String>{
        let mut r=reservation().lock().map_err(|_|"Player unavailable")?;
        let player={let mut guard=slot().lock().map_err(|_|"Player unavailable")?;if !guard.as_ref().is_some_and(|p|p.id==id&&p.label==window.label()){return Ok(false);}guard.take()};
        if r.as_deref()==Some(id){*r=None;}drop(r);drop(player);Ok(true)
    }
    pub fn shutdown(){if let Ok(mut r)=reservation().lock(){*r=None;}if let Ok(mut guard)=slot().lock(){if let Some(player)=guard.take(){let _=std::thread::spawn(move||drop(player));}}}

    #[test]
    #[ignore]
    fn real_vlc_hevc_frames_and_controls(){
        let directory=PathBuf::from(std::env::var("COCO_PLAYER_RUNTIME").unwrap());let source=std::env::var("COCO_PLAYER_SMOKE_SOURCE").unwrap();
        let source=if source.starts_with("http"){source}else{reqwest::Url::from_file_path(&source).unwrap().to_string()};
        let mut heap=vec![0u32;SHARED_BYTES/4];let pointer=heap.as_mut_ptr() as usize;
        let memory=Arc::new(Memory{pointer,owner:Mutex::new(None),window:None,_heap:Some(heap)});
        let player=create(api(&directory).unwrap(),Arc::clone(&memory),&source,"test".into(),"test".into()).unwrap();
        unsafe{(player.api.set_mute)(player.player as P,1);assert_eq!((player.api.play)(player.player as P),0);}
        let started=std::time::Instant::now();
        loop{let state=snapshot(&player);assert!(state.error.is_none(),"{:?}",state.error);if state.has_video&&state.position>1.0{break;}assert!(started.elapsed()<Duration::from_secs(30));std::thread::sleep(Duration::from_millis(30));}
        let target=(snapshot(&player).duration*0.5).min(324.0);let old_frame=memory.word(0).load(Ordering::Acquire);
        unsafe{(player.api.set_time)(player.player as P,(target*1000.0) as i64);(player.api.set_volume)(player.player as P,25);assert_eq!((player.api.set_rate)(player.player as P,1.25),0);}
        let started=std::time::Instant::now();
        loop {
            let pic=player.context.picture.lock().unwrap();
            let state=snapshot(&player);
            let sequence=memory.word(0).load(Ordering::Acquire);
            if state.position>=target+1.0&&state.has_video&&sequence>old_frame+2{drop(pic);break;}
            drop(pic);assert!(started.elapsed()<Duration::from_secs(20));std::thread::sleep(Duration::from_millis(20));
        }
        unsafe{(player.api.pause)(player.player as P,1);}
        std::thread::sleep(Duration::from_millis(100));
        let pic=player.context.picture.lock().unwrap();
        let state=snapshot(&player);assert!(state.paused);assert!(unsafe{(player.api.audio_track)(player.player as P)}>=0);
        assert!(state.has_video);assert!((state.volume-0.25).abs()<0.02);
        let slot=memory.word(1).load(Ordering::Acquire) as usize;
        let bytes=unsafe{std::slice::from_raw_parts((memory.pointer as *const u8).add(HEADER+slot*SLOT_BYTES),pic.stride*pic.height)};
        assert!(bytes.chunks_exact(4).any(|p|p[0]>40||p[1]>40||p[2]>40),"decoded frame is black");
        assert!(bytes.chunks_exact(4).filter(|p|p[3]==255).count()>pic.width*pic.height/2,"RGBA alpha invalid");
        if let Ok(path)=std::env::var("COCO_PLAYER_SMOKE_FRAME"){
            std::fs::write(&path,bytes).unwrap();std::fs::write(format!("{path}.json"),serde_json::json!({"width":pic.width,"height":pic.height,"stride":pic.stride}).to_string()).unwrap();
        }
        println!("Own HEVC decoder, RGBA frames, audio track, seek, pause, volume and rate PASS: {}",serde_json::to_string(&state).unwrap());
        drop(pic);drop(player);
    }
}

#[tauri::command]
pub async fn open_native_player(app:tauri::AppHandle,window:tauri::WebviewWindow,url:String,request_id:String)->Result<String,String>{
    #[cfg(windows)]{tauri::async_runtime::spawn_blocking(move||win::open(app,window,url,request_id)).await.map_err(|_|"Decoder start interrupted".to_owned())?}
    #[cfg(not(windows))]{let _=(app,window,url,request_id);Err("Native playback requires Windows".into())}
}
#[tauri::command]
pub async fn native_player_status(window:tauri::WebviewWindow,id:String)->Result<Snapshot,String>{
    #[cfg(windows)]{tauri::async_runtime::spawn_blocking(move||win::status(&window,&id)).await.map_err(|_|"Player status interrupted".to_owned())?}
    #[cfg(not(windows))]{let _=(window,id);Err("Unsupported platform".into())}
}
#[tauri::command]
pub async fn control_native_player(window:tauri::WebviewWindow,id:String,action:String,value:Option<f64>)->Result<(),String>{
    #[cfg(windows)]{tauri::async_runtime::spawn_blocking(move||win::control(&window,&id,&action,value)).await.map_err(|_|"Player control interrupted".to_owned())?}
    #[cfg(not(windows))]{let _=(window,id,action,value);Err("Unsupported platform".into())}
}
#[tauri::command]
pub async fn close_native_player(window:tauri::WebviewWindow,id:String)->Result<bool,String>{
    #[cfg(windows)]{tauri::async_runtime::spawn_blocking(move||win::close(&window,&id)).await.map_err(|_|"Player close interrupted".to_owned())?}
    #[cfg(not(windows))]{let _=(window,id);Ok(false)}
}
pub fn shutdown(){#[cfg(windows)]win::shutdown();}
#[cfg(test)]
mod tests{
    use super::*;
    #[test]fn controls_do_not_expose_arbitrary_decoder_commands(){
        for action in ["run","loadfile","screenshot","quit"]{assert!(valid_value(action,None).is_err());}
        assert!(valid_value("volume",Some(f64::NAN)).is_err());assert!(valid_value("seek",Some(-1.0)).is_err());
        assert_eq!(valid_value("volume",Some(0.5)).unwrap(),0.5);
    }
    #[test]fn a_buffer_is_correlated_to_one_request(){assert!(valid_request("12345678-1234-1234-1234-123456789abc"));assert!(!valid_request("other"));}
    #[test]fn canvas_colors_and_alpha_match_bgrx_decoder_pixels(){
        let source=[0,0,255,0,0,255,0,0,255,0,0,0,255,255,255,0,10,20,30,0];let mut target=[0;20];
        copy_bgrx_to_rgba(&source,&mut target);
        assert_eq!(target,[255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255,30,20,10,255]);
    }
}
