//! Native WebView2 media bridge. Remote URLs are private embedded data, not UI arguments.
//! The local server is bound to 127.0.0.1 only. It never opens an external browser.
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
#[cfg(not(any(unix,windows)))]
use std::io::Seek;
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const SERVER_LIFETIME: Duration = Duration::from_secs(6 * 60 * 60);
const SERVER_IDLE_TIMEOUT: Duration = Duration::from_secs(20 * 60);
const MAX_PROXIES: usize = 8;
const MAX_CONNECTIONS_PER_PROXY: usize = 4;
const MAX_REQUEST_BYTES: usize = 16 * 1024;
const UPSTREAM_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const UPSTREAM_REQUEST_TIMEOUT: Duration = Duration::from_secs(3 * 60 * 60);
const CLIENT_TIMEOUT: Duration = Duration::from_secs(30);
static ACTIVE_PROXIES: AtomicUsize = AtomicUsize::new(0);
type ProxyRegistry = HashMap<u16, (String, Arc<AtomicBool>)>;
static PROXY_REGISTRY: OnceLock<Mutex<ProxyRegistry>> = OnceLock::new();

fn registry() -> &'static Mutex<ProxyRegistry> {
    PROXY_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) fn active_stream(url:&str)->bool {
    let Ok(parsed)=reqwest::Url::parse(url) else{return false};
    if parsed.scheme()!="http"||parsed.host_str()!=Some("127.0.0.1")||parsed.query().is_some()
        ||parsed.fragment().is_some()||!parsed.username().is_empty()||parsed.password().is_some(){return false;}
    let Some(port)=parsed.port() else{return false};
    registry().lock().ok().and_then(|active|active.get(&port).map(|(path,flag)|
        path==parsed.path()&&!flag.load(Ordering::Acquire))).unwrap_or(false)
}

fn release_proxy(url: &str) -> bool {
    let parsed = match reqwest::Url::parse(url) {Ok(parsed)=>parsed,Err(_)=>return false};
    if parsed.scheme()!="http" || parsed.host_str()!=Some("127.0.0.1")
        || parsed.query().is_some() || parsed.fragment().is_some() {return false;}
    let Some(port)=parsed.port() else {return false};
    let Ok(mut active)=registry().lock() else {return false};
    if let Some((path, token))=active.get(&port) {
        if path==parsed.path() {
            // A successful close ends this stream's quota ownership now,
            // not when the polling worker eventually exits. The guard uses
            // the same atomic flag so only one side decrements the count.
            if !token.swap(true,Ordering::AcqRel) {
                ACTIVE_PROXIES.fetch_sub(1,Ordering::AcqRel);
            }
            active.remove(&port);
            return true;
        }
    }
    false
}

#[tauri::command]
pub fn close_media_stream(url: String) -> bool {release_proxy(&url)}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PrivateMedia {
    pub(super) id: String,
    name: String,
    #[serde(rename = "type")]
    kind: String,
    pub(super) episodes: Vec<PrivateEpisode>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PrivateEpisode {
    pub(super) id: String,
    title: String,
    pub(super) file_name: String,
    pub(super) stream_url: String,
    #[serde(default)]
    pub(super) source_url: String,
    #[serde(default)]
    pub(super) size: u64,
    #[serde(default)]
    pub(super) sha256: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaEpisode {
    pub id: String,
    pub title: String,
    pub file_name: String,
    pub size: u64,
    pub mime_type: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaEntry {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub image: String,
    pub episodes: Vec<MediaEpisode>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedMediaStream {
    pub id: String,
    pub episode_id: String,
    pub url: String,
    pub mime_type: &'static str,
    pub expires_in_seconds: u64,
}

fn mime_type(file_name: &str) -> Option<(&'static str, &'static str)> {
    let ext = file_name.rsplit_once('.')?.1;
    if ext.eq_ignore_ascii_case("mp4") || ext.eq_ignore_ascii_case("m4v") {
        Some(("video/mp4", "mp4"))
    } else if ext.eq_ignore_ascii_case("webm") {
        Some(("video/webm", "webm"))
    } else if ext.eq_ignore_ascii_case("mkv") {
        Some(("video/x-matroska", "mkv"))
    } else {
        None
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 96
        && value.as_bytes().iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}

pub(super) fn upstream_allowed(url: &reqwest::Url, local_fixture: bool) -> bool {
    if url.username() != "" || url.password().is_some() || url.fragment().is_some() {
        return false;
    }
    if local_fixture {
        return url.scheme() == "http"
            && url.host_str() == Some("127.0.0.1")
            && url.port().is_some();
    }
    if url.scheme() != "https" || url.port_or_known_default() != Some(443) {
        return false;
    }
    match url.host_str() {
        Some("github.com") => url.path().starts_with(
            "/Franco-Caballero/CocoMinecraftUpdater/releases/download/"
        ),
        Some("release-assets.githubusercontent.com") | Some("objects.githubusercontent.com") => true,
        _ => false,
    }
}

fn validate_manifest(raw: &[u8]) -> Result<Vec<PrivateMedia>, String> {
    let entries: Vec<PrivateMedia> = serde_json::from_slice(raw)
        .map_err(|_| "Invalid private media manifest")?;
    if entries.len() > 256 {
        return Err("Too many media entries".into());
    }
    let mut ids = std::collections::HashSet::new();
    for entry in &entries {
        if !valid_id(&entry.id)
            || !ids.insert(entry.id.as_str())
            || entry.name.trim().is_empty()
            || !matches!(entry.kind.as_str(), "episodic-video" | "movie")
            || entry.episodes.is_empty()
            || entry.episodes.len() > 1_000
        {
            return Err(format!("Invalid media entry: {}", entry.id));
        }
        let mut episode_ids = std::collections::HashSet::new();
        for episode in &entry.episodes {
            if !valid_id(&episode.id)
                || !episode_ids.insert(episode.id.as_str())
                || episode.title.trim().is_empty()
                || mime_type(&episode.file_name).is_none()
                || !crate::services::media_download::safe_file_name(&episode.file_name)
                || episode.file_name.chars().any(char::is_control)
                || (!episode.sha256.is_empty() && (episode.sha256.len() != 64
                    || !episode.sha256.bytes().all(|b| b.is_ascii_hexdigit())))
            {
                return Err(format!("Invalid episode metadata: {} / {}", entry.id, episode.id));
            }
            let url = reqwest::Url::parse(&episode.stream_url)
                .map_err(|_| format!("Invalid stream URL in {} / {}", entry.id, episode.id))?;
            if !upstream_allowed(&url, false) {
                return Err(format!("Untrusted media URL in {} / {}", entry.id, episode.id));
            }
            if !episode.source_url.is_empty() {
                let source = reqwest::Url::parse(&episode.source_url)
                    .map_err(|_| "Invalid media download URL")?;
                if !upstream_allowed(&source, false) { return Err("Untrusted media download URL".into()); }
            }
        }
    }
    Ok(entries)
}

pub(super) fn private_catalog() -> Result<Vec<PrivateMedia>, String> {
    validate_manifest(include_bytes!("../../resources/media-manifests.json"))
}

fn public_catalog(
    private: &[PrivateMedia],
    covers: &[(String, String)],
) -> Vec<MediaEntry> {
    private.iter().map(|entry| MediaEntry {
        id: entry.id.clone(),
        name: entry.name.clone(),
        kind: entry.kind.clone(),
        image: covers.iter().find(|(id, _)| id == &entry.id)
            .map(|(_, path)| path.clone()).unwrap_or_default(),
        episodes: entry.episodes.iter().map(|ep| MediaEpisode {
            id: ep.id.clone(),
            title: ep.title.clone(),
            file_name: ep.file_name.clone(),
            size: ep.size,
            mime_type: mime_type(&ep.file_name).unwrap().0,
        }).collect(),
    }).collect()
}

#[tauri::command]
pub async fn get_media_catalog() -> Result<Vec<MediaEntry>, String> {
    tauri::async_runtime::spawn_blocking(read_media_catalog)
        .await.map_err(|error| format!("Media catalog read interrupted: {error}"))?
}

fn read_media_catalog() -> Result<Vec<MediaEntry>, String> {
    let private = private_catalog()?;
    let covers = crate::services::catalog::read_catalog()?
        .into_iter().filter(|item| item.workflow == "coco-media")
        .map(|item| (item.id, item.image)).collect::<Vec<_>>();
    Ok(public_catalog(&private, &covers))
}

// Token entropy comes from the operating system, not timestamps or a process ID.
fn secure_token() -> Result<String, String> {
    let mut bytes = [0_u8; 24];
    #[cfg(windows)]
    {
        #[link(name = "bcrypt")]
        extern "system" {
            fn BCryptGenRandom(algorithm: isize, output: *mut u8, len: u32, flags: u32) -> i32;
        }
        let status = unsafe { BCryptGenRandom(0, bytes.as_mut_ptr(), bytes.len() as u32, 2) };
        if status != 0 {
            return Err("Secure Windows RNG unavailable".into());
        }
    }
    #[cfg(not(windows))]
    {
        use std::fs::File;
        File::open("/dev/urandom")
            .and_then(|mut source| source.read_exact(&mut bytes))
            .map_err(|_| "Secure operating system RNG unavailable")?;
    }
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// The proxy accepts a single byte-range, including suffix ranges used by video engines.
fn valid_range(value: &str) -> bool {
    let Some(raw) = value.strip_prefix("bytes=") else { return false };
    if raw.contains(',') || raw.len() > 50 {
        return false;
    }
    let Some((start, end)) = raw.split_once('-') else { return false };
    if start.is_empty() && end.is_empty() {
        return false;
    }
    if !start.bytes().all(|b| b.is_ascii_digit())
        || !end.bytes().all(|b| b.is_ascii_digit())
    {
        return false;
    }
    let start_number = if start.is_empty() { None } else { start.parse::<u64>().ok() };
    let end_number = if end.is_empty() { None } else { end.parse::<u64>().ok() };
    if (!start.is_empty() && start_number.is_none())
        || (!end.is_empty() && end_number.is_none())
    {
        return false;
    }
    if start.is_empty() {
        return end_number.unwrap_or_default() > 0;
    }
    match (start_number, end_number) {
        (Some(left), Some(right)) => left <= right,
        (Some(_), None) => true,
        _ => false,
    }
}

fn valid_partial_response(request: &str, content_range: &str, length: u64) -> bool {
    let Some(numbers) = content_range.strip_prefix("bytes ") else { return false };
    let Some((range, total)) = numbers.split_once('/') else { return false };
    let Some((first, last)) = range.split_once('-') else { return false };
    let (Ok(first), Ok(last), Ok(total)) = (
        first.parse::<u64>(), last.parse::<u64>(), total.parse::<u64>()
    ) else { return false };
    if total == 0 || last < first || last >= total
        || last.checked_sub(first).and_then(|value| value.checked_add(1)) != Some(length)
    {
        return false;
    }
    let Some(range_request) = request.strip_prefix("bytes=") else { return false };
    let Some((start, end)) = range_request.split_once('-') else { return false };
    if start.is_empty() {
        let Ok(suffix) = end.parse::<u64>() else { return false };
        // The server must return exactly the last min(suffix, total) bytes.
        first == total.saturating_sub(suffix) && last == total - 1
    } else {
        let Ok(start) = start.parse::<u64>() else { return false };
        if first != start { return false; }
        if end.is_empty() {
            last == total - 1
        } else {
            let Ok(end) = end.parse::<u64>() else { return false };
            last == end.min(total - 1)
        }
    }
}

// HTTP 416 must describe the same immutable media object as the request.
// Some gateways send an unrelated/invalid 416 even for an ordinary GET;
// forwarding it would make the browser believe a valid video is unseekable.
fn valid_unsatisfiable_response(request: Option<&str>, content_range: Option<&str>, expected: u64) -> bool {
    let (Some(request), Some(content_range)) = (request, content_range) else {return false;};
    if !valid_range(request) {return false;}
    let Some(raw_total) = content_range.strip_prefix("bytes */") else {return false;};
    let Ok(total) = raw_total.parse::<u64>() else {return false;};
    if total == 0 || (expected != 0 && total != expected) {return false;}
    let raw = request.strip_prefix("bytes=").unwrap();
    let (first, _) = raw.split_once('-').unwrap();
    // A valid suffix range against a nonempty object is always satisfiable;
    // explicit positions are unsatisfiable only at/after its final byte.
    !first.is_empty() && first.parse::<u64>().is_ok_and(|start| start >= total)
}

struct Request {
    method: String,
    target: String,
    range: Option<String>,
}

fn read_request(stream: &mut TcpStream) -> Result<Request, u16> {
    let mut bytes = Vec::with_capacity(1024);
    let mut byte = [0_u8; 1];
    loop {
        if bytes.len() >= MAX_REQUEST_BYTES {
            return Err(431);
        }
        match stream.read_exact(&mut byte) {
            Ok(()) => bytes.push(byte[0]),
            Err(_) => return Err(400),
        }
        if bytes.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    if !bytes.iter().all(u8::is_ascii) {
        return Err(400);
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| 400u16)?;
    let mut lines = text.split("\r\n");
    let first = lines.next().ok_or(400u16)?;
    let mut parts = first.split(' ');
    let method = parts.next().ok_or(400u16)?;
    let target = parts.next().ok_or(400u16)?;
    if parts.next() != Some("HTTP/1.1") || parts.next().is_some() {
        return Err(400);
    }
    let mut range = None;
    for line in lines {
        if line.is_empty() {
            break;
        }
        let (key, value) = line.split_once(':').ok_or(400u16)?;
        let value = value.trim();
        if key.eq_ignore_ascii_case("Range") {
            if range.is_some() || !valid_range(value) {
                return Err(416);
            }
            range = Some(value.to_owned());
        }
        if key.eq_ignore_ascii_case("Transfer-Encoding") || key.eq_ignore_ascii_case("Content-Length") {
            return Err(400);
        }
    }
    Ok(Request { method: method.into(), target: target.into(), range })
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK", 204 => "No Content", 206 => "Partial Content",
        400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed",
        416 => "Range Not Satisfiable", 429 => "Too Many Requests",
        431 => "Request Header Fields Too Large", 502 => "Bad Gateway",
        503 => "Service Unavailable", _ => "Error",
    }
}

fn send_headers(
    stream: &mut TcpStream, code: u16, mime: &str, length: u64,
    content_range: Option<&str>, preflight: bool,
) -> std::io::Result<()> {
    let mut header = format!(
        "HTTP/1.1 {code} {}\r\n\
         Content-Type: {mime}\r\n\
         Content-Length: {length}\r\n\
         Accept-Ranges: bytes\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n\
         Access-Control-Allow-Headers: Range\r\n\
         Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n\
         Cache-Control: private, no-store\r\n\
         X-Content-Type-Options: nosniff\r\n\
         Connection: close\r\n",
        reason(code)
    );
    if preflight {
        header.push_str("Access-Control-Max-Age: 3600\r\n");
    }
    if let Some(value) = content_range {
        if value.bytes().all(|b| b.is_ascii_graphic() || b == b' ') && value.starts_with("bytes ") {
            header.push_str("Content-Range: ");
            header.push_str(value);
            header.push_str("\r\n");
        }
    }
    header.push_str("\r\n");
    stream.write_all(header.as_bytes())
}

fn make_client(local_fixture: bool) -> Result<reqwest::blocking::Client, String> {
    let policy = reqwest::redirect::Policy::custom(move |attempt| {
        if attempt.previous().len() >= 5 || !upstream_allowed(attempt.url(), local_fixture) {
            attempt.stop()
        } else {
            attempt.follow()
        }
    });
    reqwest::blocking::Client::builder()
        .redirect(policy)
        .connect_timeout(UPSTREAM_CONNECT_TIMEOUT)
        .timeout(UPSTREAM_REQUEST_TIMEOUT)
        .pool_max_idle_per_host(0)
        .build()
        .map_err(|_| "Cannot build native media client".into())
}

// WinSock can abort a just-created localhost connection under concurrent
// requests (WSAECONNABORTED/10053), before the origin sees an HTTP request.
// Retrying exactly once is safe here: only idempotent GET/HEAD are issued and
// no response body has reached the video client when send() returns an error.
fn transient_media_transport(error: &(dyn std::error::Error + 'static)) -> bool {
    let mut cause = Some(error);
    while let Some(current) = cause {
        if let Some(io) = current.downcast_ref::<std::io::Error>() {
            return matches!(io.kind(),
                std::io::ErrorKind::ConnectionAborted |
                std::io::ErrorKind::ConnectionReset |
                std::io::ErrorKind::BrokenPipe |
                std::io::ErrorKind::UnexpectedEof);
        }
        cause = current.source();
    }
    false
}

struct ProxySpec {
    url: reqwest::Url,
    mime: &'static str,
    path: String,
    expected_bytes: u64,
    local_fixture: bool,
    // A verified read-only handle is shared, but every request reads by its
    // own absolute offset. A stalled large GET must not serialize seeks.
    local_file: Option<File>,
    cancelled: Arc<AtomicBool>,
}

fn local_bounds(range:Option<&str>, total:u64)->Option<(u16,u64,u64,Option<String>)>{
    if total==0{return None;}
    let Some(range)=range else{return Some((200,0,total-1,None));};
    let raw=range.strip_prefix("bytes=")?;
    let (start,end)=raw.split_once('-')?;
    let (first,last)=if start.is_empty(){
        let suffix=end.parse::<u64>().ok()?;
        (total.saturating_sub(suffix),total-1)
    }else{
        let first=start.parse::<u64>().ok()?;
        if first>=total{return None;}
        let last=if end.is_empty(){total-1}else{end.parse::<u64>().ok()?.min(total-1)};
        if last<first{return None;}
        (first,last)
    };
    Some((206,first,last,Some(format!("bytes {first}-{last}/{total}"))))
}

fn local_read_at(file:&File,buffer:&mut [u8],offset:u64)->std::io::Result<usize>{
    #[cfg(windows)] {
        use std::os::windows::fs::FileExt;
        file.seek_read(buffer,offset)
    }
    #[cfg(unix)] {
        use std::os::unix::fs::FileExt;
        file.read_at(buffer,offset)
    }
    #[cfg(not(any(windows,unix)))] {
        let mut clone=file.try_clone()?;
        clone.seek(std::io::SeekFrom::Start(offset))?;
        clone.read(buffer)
    }
}

fn serve_local(mut stream:TcpStream,request:&Request,spec:&ProxySpec,file:&File){
    if spec.cancelled.load(Ordering::Acquire) {return;}
    // Range applies to GET, not HEAD. This must match the remote manifest-
    // pinned HEAD path: full Content-Length, 200, and no Content-Range.
    let selected_range=if request.method=="HEAD"{None}else{request.range.as_deref()};
    let Some((code,start,end,range))=local_bounds(selected_range,spec.expected_bytes)else{
        let _=send_headers(&mut stream,416,spec.mime,0,
            Some(&format!("bytes */{}",spec.expected_bytes)),false);
        return;
    };
    let len=end-start+1;
    let Ok(meta)=file.metadata()else{return};
    if meta.len()!=spec.expected_bytes {
        let _=send_headers(&mut stream,502,"text/plain",0,None,false);return;
    }
    if send_headers(&mut stream,code,spec.mime,len,range.as_deref(),false).is_err(){return;}
    if request.method=="GET" {
        let mut offset=start;
        let mut buffer=[0u8;64*1024];
        while offset<=end && !spec.cancelled.load(Ordering::Acquire) {
            let remaining=(end-offset+1).min(buffer.len() as u64) as usize;
            let Ok(read)=local_read_at(file,&mut buffer[..remaining],offset)else{break};
            if spec.cancelled.load(Ordering::Acquire) {break;}
            if read==0 || stream.write_all(&buffer[..read]).is_err(){break;}
            offset+=read as u64;
        }
    }
}

fn serve_connection(mut stream: TcpStream, spec: &ProxySpec, client: &reqwest::blocking::Client) {
    let _ = stream.set_read_timeout(Some(CLIENT_TIMEOUT));
    let _ = stream.set_write_timeout(Some(CLIENT_TIMEOUT));
    let request = match read_request(&mut stream) {
        Ok(value) => value,
        Err(status) => {
            let _ = send_headers(&mut stream, status, "text/plain", 0, None, false);
            return;
        }
    };
    if request.target != spec.path {
        let _ = send_headers(&mut stream, 404, "text/plain", 0, None, false);
        return;
    }
    if spec.cancelled.load(Ordering::Acquire) {return;}
    if request.method == "OPTIONS" {
        let _ = send_headers(&mut stream, 204, "text/plain", 0, None, true);
        return;
    }
    if request.method != "GET" && request.method != "HEAD" {
        let _ = send_headers(&mut stream, 405, "text/plain", 0, None, false);
        return;
    }
    if let Some(file)=spec.local_file.as_ref(){
        serve_local(stream,&request,spec,file);
        return;
    }
    // A frontend cannot supply a different remote URL or an HTTP redirect destination.
    if !upstream_allowed(&spec.url, spec.local_fixture) {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    // The immutable private manifest already pins the video byte length.
    // Answer HEAD locally, even if a viewer sends Range. HTTP Range applies
    // only to GET: origins are allowed to ignore it on HEAD and reply 200.
    // Forwarding ranged HEAD and demanding 206 spuriously translated a valid
    // 200 into a 502. A verified manifest length is sufficient for this HEAD.
    // Actual media bytes are still checked against response size/range on GET.
    if request.method == "HEAD" && spec.expected_bytes != 0 {
        let _ = send_headers(&mut stream, 200, spec.mime, spec.expected_bytes, None, false);
        return;
    }
    let mut retried_transport = false;
    let response = loop {
        if spec.cancelled.load(Ordering::Acquire) {return;}
        let mut upstream = match request.method.as_str() {
            "HEAD" => client.head(spec.url.clone()),
            _ => client.get(spec.url.clone()),
        };
        upstream = upstream.header(reqwest::header::ACCEPT_ENCODING, "identity");
        if let Some(range) = &request.range {
            upstream = upstream.header(reqwest::header::RANGE, range);
        }
        match upstream.send() {
            Ok(response) => break response,
            Err(error) if !retried_transport && transient_media_transport(&error) => {
                retried_transport = true;
            }
            Err(_) => {
                let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
                return;
            }
        }
    };
    if spec.cancelled.load(Ordering::Acquire) {return;}
    if !upstream_allowed(response.url(), spec.local_fixture) {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    let code = response.status().as_u16();
    // Multiple Content-Range fields can describe contradictory byte spans.
    // A first valid 206/416 value must never conceal a later conflicting one.
    // Reject before advertising range metadata or streaming video bytes.
    let mut ranges = response.headers().get_all(reqwest::header::CONTENT_RANGE).iter();
    let content_range = ranges.next()
        .and_then(|value| value.to_str().ok());
    if ranges.next().is_some() {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    if code == 416 {
        if valid_unsatisfiable_response(request.range.as_deref(), content_range, spec.expected_bytes) {
            let _ = send_headers(&mut stream, 416, "text/plain", 0, content_range, false);
        } else {
            let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        }
        return;
    }
    // The origin may ignore Accept-Encoding: identity. Forwarding a gzipped
    // Range under video/mp4 without Content-Encoding corrupts playback and
    // makes Content-Range refer to a different representation of the media.
    // Check every header instance; a second Content-Encoding line must not
    // bypass an initial "identity" value.
    if response.headers().get_all(reqwest::header::CONTENT_ENCODING).iter()
        .any(|encoding| !encoding.as_bytes().eq_ignore_ascii_case(b"identity")) {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    if !(code == 200 || code == 206)
        || (request.range.is_some() && code != 206)
        || (request.range.is_none() && code == 206)
    {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    // reqwest may report a zero-sized *body* for HEAD even when the remote
    // Content-Length accurately describes the full video. Read the raw header.
    let length = match response.headers().get(reqwest::header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
    {
        Some(value) => value,
        None => {
            let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
            return;
        }
    };
    if code == 200 && spec.expected_bytes != 0 && length != spec.expected_bytes {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    if code == 206 && !request.range.as_deref()
        .zip(content_range.as_deref())
        .map(|(range, content_range)| valid_partial_response(range, content_range, length))
        .unwrap_or(false)
    {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    if code == 206 && spec.expected_bytes != 0
        && content_range.as_deref()
            .and_then(|range| range.rsplit_once('/'))
            .and_then(|(_, total)| total.parse::<u64>().ok())
            != Some(spec.expected_bytes)
    {
        let _ = send_headers(&mut stream, 502, "text/plain", 0, None, false);
        return;
    }
    if spec.cancelled.load(Ordering::Acquire)
        || send_headers(&mut stream, code, spec.mime, length, content_range.as_deref(), false).is_err() {
        return;
    }
    if request.method == "GET" {
        // A released stream must stop forwarding a prior video GET. A bounded
        // per-chunk copy observes cancellation without buffering large media.
        let mut source=response.take(length);
        let mut buffer=[0u8;64*1024];
        let mut remaining=length;
        while remaining>0 && !spec.cancelled.load(Ordering::Acquire) {
            let requested=remaining.min(buffer.len() as u64) as usize;
            let Ok(count)=source.read(&mut buffer[..requested])else{break};
            if count==0 || spec.cancelled.load(Ordering::Acquire) {break;}
            if stream.write_all(&buffer[..count]).is_err(){break;}
            remaining-=count as u64;
        }
    }
}

struct ProxyGuard(Arc<AtomicBool>);
impl Drop for ProxyGuard {
    fn drop(&mut self) {
        if !self.0.swap(true,Ordering::AcqRel) {
            ACTIVE_PROXIES.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

fn start_proxy_internal(
    url:reqwest::Url, mime:&'static str, ext:&'static str,
    expected_bytes:u64, local_fixture:bool, ttl:Duration, local_file:Option<File>,
) -> Result<(String,u16),String> {
    if !upstream_allowed(&url, local_fixture) {
        return Err("Media stream origin is not permitted".into());
    }
    if ACTIVE_PROXIES.fetch_add(1, Ordering::AcqRel) >= MAX_PROXIES {
        ACTIVE_PROXIES.fetch_sub(1, Ordering::AcqRel);
        return Err("Too many media streams; retry after closing one".into());
    }
    let cancelled=Arc::new(AtomicBool::new(false));
    let guard = ProxyGuard(Arc::clone(&cancelled));
    let token = secure_token()?;
    let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0))
        .map_err(|_| "Cannot bind local media server")?;
    listener.set_nonblocking(true).map_err(|_| "Cannot configure media server")?;
    let port = listener.local_addr().map_err(|_| "Cannot read media server port")?.port();
    let path = format!("/coco-media/{token}/video.{ext}");
    let prepared_url = format!("http://127.0.0.1:{port}{path}");
    let spec = Arc::new(ProxySpec {
        url,mime,path,expected_bytes,local_fixture,
        local_file,cancelled:Arc::clone(&cancelled),
    });
    let client = Arc::new(make_client(local_fixture)?);
    {
        let mut active=registry().lock().map_err(|_|"Media server registry unavailable")?;
        active.insert(port,(spec.path.clone(),Arc::clone(&cancelled)));
    }
    let cancel_flag=Arc::clone(&cancelled);
    let spawn=thread::Builder::new().name("coco-media-loopback".into()).spawn(move || {
        let _guard = guard;
        let started = Instant::now();
        let mut last_request = Instant::now();
        let running = Arc::new(AtomicUsize::new(0));
        while !cancel_flag.load(Ordering::Acquire)
            && started.elapsed() < ttl
            && (last_request.elapsed() < SERVER_IDLE_TIMEOUT
                || running.load(Ordering::Acquire) > 0)
        {
            match listener.accept() {
                Ok((mut socket, _)) => {
                    last_request = Instant::now();
                    if running.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS_PER_PROXY {
                        running.fetch_sub(1, Ordering::AcqRel);
                        let _ = send_headers(&mut socket, 429, "text/plain", 0, None, false);
                        continue;
                    }
                    let client = Arc::clone(&client);
                    let spec = Arc::clone(&spec);
                    let counter = Arc::clone(&running);
                    thread::spawn(move || {
                        serve_connection(socket, &spec, &client);
                        counter.fetch_sub(1, Ordering::AcqRel);
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(50));
                }
                Err(_) => break,
            }
        }
        if let Ok(mut active)=registry().lock() {
            if active.get(&port).is_some_and(|(_,flag)|Arc::ptr_eq(flag,&cancel_flag)) {
                active.remove(&port);
            }
        }
    });
    if spawn.is_err(){
        if let Ok(mut active)=registry().lock(){active.remove(&port);}
        return Err("Cannot start local media server".into());
    }
    Ok((prepared_url, port))
}

fn prepared_stream(
    entries: &[PrivateMedia], id: &str, episode_id: &str,
    local_fixture: bool, ttl: Duration,
) -> Result<PreparedMediaStream, String> {
    let entry = entries.iter().find(|entry| entry.id == id)
        .ok_or("Unknown media title")?;
    let episode = entry.episodes.iter().find(|ep| ep.id == episode_id)
        .ok_or("Unknown media episode")?;
    let (mime, ext) = mime_type(&episode.file_name).ok_or("Unsupported media format")?;
    let upstream = reqwest::Url::parse(&episode.stream_url)
        .map_err(|_| "Invalid embedded media URL")?;
    let local = if local_fixture {None}else{
        crate::services::media_download::verified_for_episode(entry,episode)?
    };
    let (url, _) = start_proxy_internal(
        upstream,mime,ext,episode.size,local_fixture,ttl,local)?;
    Ok(PreparedMediaStream {
        id: id.to_owned(),
        episode_id: episode_id.to_owned(),
        url,
        mime_type: mime,
        expires_in_seconds: ttl.as_secs(),
    })
}

#[tauri::command]
pub async fn prepare_media_stream(id: String, episode_id: String) -> Result<PreparedMediaStream, String> {
    tauri::async_runtime::spawn_blocking(move ||{
        let entries = private_catalog()?;
        prepared_stream(&entries, &id, &episode_id, false, SERVER_LIFETIME)
    }).await.map_err(|_|"Media player interrupted".to_string())?
}

#[tauri::command]
pub async fn prepare_local_media_stream(
    id:String,episode_id:String,
) -> Result<PreparedMediaStream,String> {
    tauri::async_runtime::spawn_blocking(move || {
        let entries=private_catalog()?;
        let entry=entries.iter().find(|entry|entry.id==id).ok_or("Unknown media title")?;
        let ep=entry.episodes.iter().find(|ep|ep.id==episode_id).ok_or("Unknown episode")?;
        let verified=crate::services::media_download::verified_for_episode(entry,ep)?
            .ok_or("Episode is not downloaded and verified")?;
        let (mime,ext)=mime_type(&ep.file_name).ok_or("Unsupported local media format")?;
        let url=reqwest::Url::parse(&ep.stream_url)
            .map_err(|_|"Invalid private media URL")?;
        let (url,_)=start_proxy_internal(url,mime,ext,ep.size,false,SERVER_LIFETIME,Some(verified))?;
        Ok(PreparedMediaStream {
            id,episode_id,url,mime_type:mime,expires_in_seconds:SERVER_LIFETIME.as_secs(),
        })
    }).await.map_err(|_|"Local media player interrupted".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn test_entry(url: &str) -> Vec<PrivateMedia> {
        vec![PrivateMedia {
            id: "demo".into(), name: "Demo".into(), kind: "episodic-video".into(),
            episodes: vec![PrivateEpisode {
                id: "part-1".into(), title: "Part 1".into(),
                file_name: "sample.mp4".into(), stream_url: url.into(), source_url:url.into(),
                size: 12, sha256: String::new(),
            }],
        }]
    }

    // This is the *test origin's* HTTP reader, not a production proxy path.
    // Keep it shared between the full media fixture and adversarial tests so
    // injected scheduling pauses exercise the actual fixture implementation.
    fn fixture_read_upstream_headers(stream:&mut TcpStream)->Option<Vec<u8>>{
        stream.set_read_timeout(Some(Duration::from_secs(1))).ok()?;
        // The synthetic origin is not a production HTTP parser. An individual
        // socket read may time out if an 8-thread Rust run deschedules the
        // writer between header fragments. A valid request must not become
        // a fake upstream EOF/502 solely because of that fixture timeout.
        // Keep the existing 1s per-read timeout; bound the entire header to
        // 5s so malformed or permanently idle clients cannot stall the suite.
        let started=Instant::now();
        let budget=Duration::from_secs(5);
        let mut raw=Vec::new();
        let mut byte=[0u8;1];
        while raw.len()<8192 && !raw.ends_with(b"\r\n\r\n")
            && started.elapsed()<budget
        {
            match stream.read_exact(&mut byte){
                Ok(())=>raw.push(byte[0]),
                Err(error) if matches!(error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock)
                    && started.elapsed()<budget =>continue,
                Err(_)=>break,
            }
        }
        raw.ends_with(b"\r\n\r\n").then_some(raw)
    }

    #[test]
    fn injected_fixture_header_gap_does_not_spuriously_discard_valid_range() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let addr=listener.local_addr().unwrap();
        let (listening_tx,listening_rx)=mpsc::channel();
        let worker=thread::spawn(move||{
            let (mut stream,_)=listener.accept().unwrap();
            listening_tx.send(()).unwrap();
            fixture_read_upstream_headers(&mut stream)
                .map(|raw|String::from_utf8(raw).unwrap())
        });
        let mut client=TcpStream::connect(addr).unwrap();
        client.write_all(b"GET /fixture HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=2-").unwrap();
        listening_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        // Deterministically model a thread being descheduled between two
        // pieces of an otherwise valid Range header. A test-only 1s socket
        // idle timeout must not manufacture a missing upstream response/502.
        thread::sleep(Duration::from_millis(1300));
        let _=client.write_all(b"5\r\nConnection: close\r\n\r\n");
        drop(client);
        let request=worker.join().unwrap()
            .expect("valid Range should survive a synthetic >1s fixture header gap");
        assert!(request.starts_with("GET /fixture HTTP/1.1\r\n"));
        assert!(request.contains("\r\nRange: bytes=2-5\r\n"));
    }

    fn fixture_upstream() -> (String, mpsc::Receiver<()>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://127.0.0.1:{}/fixture", listener.local_addr().unwrap().port());
        let (done_tx, done_rx) = mpsc::channel();
        let handle = thread::spawn(move || {
            let started = Instant::now();
            let mut handled = 0usize;
            // Three *upstream* GETs are expected (a normal range, a suffix
            // range, and an unsatisfiable range). An absolute 3-second fixture
            // lifetime could expire between these requests when the full
            // Rust suite ran concurrently, falsely making the suffix a 502.
            // End as soon as all three are served, with a bounded safety cap.
            while handled < 3 && started.elapsed() < Duration::from_secs(20) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        // This acts as a remote web server. It must accept
                        // headers that reqwest sends (and which the *local*
                        // proxy correctly refuses from arbitrary callers).
                        let Some(raw)=fixture_read_upstream_headers(&mut stream) else{continue};
                        let request_text = match std::str::from_utf8(&raw) {Ok(t) => t,Err(_) => continue};
                        let method = request_text.split_whitespace().next().unwrap_or("");
                        let range = request_text.split("\r\n")
                            .filter_map(|line| line.split_once(':'))
                            .find(|(key,_)| key.eq_ignore_ascii_case("Range"))
                            .map(|(_,value)|value.trim());
                        let data = b"abcdefghijkl";
                        let (code, part, content_range) = match range {
                            Some("bytes=2-5") => (206, &data[2..6], Some("bytes 2-5/12")),
                            Some("bytes=-3") => (206, &data[9..12], Some("bytes 9-11/12")),
                            Some("bytes=80-") => (416, &data[0..0], Some("bytes */12")),
                            _ => (200, &data[..], None),
                        };
                        let header = format!("HTTP/1.1 {code} {}\r\nContent-Length: {}\r\n{}Connection: close\r\n\r\n",
                            reason(code), part.len(), content_range.map(|v| format!("Content-Range: {v}\r\n")).unwrap_or_default());
                        if stream.write_all(header.as_bytes()).is_err(){continue;}
                        if method != "HEAD" {let _=stream.write_all(part);}
                        let _ = done_tx.send(());
                        handled += 1;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock =>
                        thread::sleep(Duration::from_millis(10)),
                    Err(_) => break,
                }
            }
        });
        (url, done_rx, handle)
    }

    #[cfg(windows)]
    #[test]
    fn aborted_first_upstream_connection_retries_identical_range_once() {
        use std::os::windows::io::AsRawSocket;

        #[repr(C)]
        struct Linger { enabled: u16, seconds: u16 }
        #[link(name = "Ws2_32")]
        extern "system" {
            fn setsockopt(socket: usize, level: i32, name: i32,
                value: *const i8, length: i32) -> i32;
        }

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://127.0.0.1:{}/aborted-once", listener.local_addr().unwrap().port());
        let (seen_tx,seen_rx) = mpsc::channel::<String>();
        let server = thread::spawn(move || {
            // A zero-linger close sends an intentional TCP RST on WinSock.
            // The proxy must retry a *request transport* failure without
            // forwarding the first failure as HTTP 502 to the browser.
            let (first,_) = listener.accept().unwrap();
            let linger = Linger { enabled: 1, seconds: 0 };
            let result = unsafe { setsockopt(first.as_raw_socket() as usize,
                0xffff, 0x0080, &linger as *const Linger as *const i8,
                std::mem::size_of::<Linger>() as i32) };
            assert_eq!(result,0,"synthetic fixture must force a WinSock reset");
            drop(first);

            let (mut second,_) = listener.accept().unwrap();
            let request = upstream_test_request(&second);
            second.write_all(b"HTTP/1.1 206 Partial Content\r\n\
                Content-Length: 3\r\n\
                Content-Range: bytes 3-5/12\r\n\
                Connection: close\r\n\r\ndef").unwrap();
            seen_tx.send(request).unwrap();
        });
        let (url,_) = start_proxy_internal(reqwest::Url::parse(&origin).unwrap(),
            "video/mp4", "mp4", 12, true, Duration::from_secs(5), None).unwrap();
        let (status, headers, body) = fetch(&url, "GET", Some("bytes=3-5"));
        assert_eq!(status,206,"a transient TCP RST must not surface as 502");
        assert_eq!(body,b"def");
        assert!(headers.contains("Content-Range: bytes 3-5/12"));
        let retried = seen_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(retried.starts_with("GET /aborted-once HTTP/1.1"));
        assert!(retried.contains("\r\nrange: bytes=3-5\r\n")
            || retried.contains("\r\nRange: bytes=3-5\r\n"),
            "retry must keep the caller's requested byte range");
        assert!(release_proxy(&url));
        server.join().unwrap();
    }

    #[test]
    fn transport_retries_only_reset_abort_and_eof_not_timeout_or_untrusted_http() {
        for kind in [std::io::ErrorKind::ConnectionAborted,
            std::io::ErrorKind::ConnectionReset,
            std::io::ErrorKind::BrokenPipe,
            std::io::ErrorKind::UnexpectedEof] {
            let cause = std::io::Error::from(kind);
            assert!(transient_media_transport(&cause),"should retry: {kind:?}");
        }
        for kind in [std::io::ErrorKind::TimedOut,
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::InvalidData,
            std::io::ErrorKind::NotFound] {
            let cause = std::io::Error::from(kind);
            assert!(!transient_media_transport(&cause),"must not retry: {kind:?}");
        }
    }

    #[test]
    fn malformed_ranges_and_untrusted_origins_rejected() {
        for range in ["bytes=", "bytes=-0", "bytes=5-4", "bytes=1-2,4-5",
                      "bytes=4-ab", "items=0-1", "bytes=18446744073709551616-"] {
            assert!(!valid_range(range), "{range}");
        }
        for range in ["bytes=0-", "bytes=0-100", "bytes=-1024"] {
            assert!(valid_range(range), "{range}");
        }
        for url in ["http://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/x/y.mp4",
                    "https://127.0.0.1/private",
                    "https://example.com/video.mp4",
                    "https://github.com/other/repo/releases/download/x/y.mp4",
                    "https://user:secret@github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/x/y.mp4"] {
            assert!(!upstream_allowed(&reqwest::Url::parse(url).unwrap(), false), "{url}");
        }
    }

    #[test]
    fn rejects_forged_or_misaligned_content_range() {
        assert!(valid_partial_response("bytes=2-5", "bytes 2-5/12", 4));
        assert!(valid_partial_response("bytes=-3", "bytes 9-11/12", 3));
        assert!(valid_partial_response("bytes=10-", "bytes 10-11/12", 2));
        for (range, header, size) in [
            ("bytes=2-5", "bytes 3-6/12", 4),
            ("bytes=2-5", "bytes 2-5/12", 3),
            ("bytes=2-5", "bytes 2-5/4", 4),
            ("bytes=-3", "bytes 8-11/12", 4),
            ("bytes=10-", "bytes 10-10/12", 1),
        ] {
            assert!(!valid_partial_response(range, header, size), "{range} {header}");
        }
    }

    #[test]
    fn rejects_forged_unsatisfiable_range_and_unrequested_416() {
        assert!(valid_unsatisfiable_response(Some("bytes=12-"),Some("bytes */12"),12));
        assert!(valid_unsatisfiable_response(Some("bytes=999-1000"),Some("bytes */12"),12));
        for (request,content_range,total) in [
            (None,Some("bytes */12"),12),
            (Some("bytes=2-5"),Some("bytes */12"),12),
            (Some("bytes=-3"),Some("bytes */12"),12),
            (Some("bytes=12-"),Some("bytes */13"),12),
            (Some("bytes=12-"),Some("bytes */0"),12),
            (Some("bytes=12-"),Some("bytes */garbage"),12),
            (Some("bytes=12-"),Some("bytes */12\r\nX-Evil: yes"),12),
            (Some("bytes=12-"),None,12),
        ] {
            assert!(!valid_unsatisfiable_response(request,content_range,total),
                "must reject inconsistent upstream 416: {request:?} {content_range:?}");
        }
    }

    fn upstream_test_request(mut stream: &TcpStream) -> String {
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut request=Vec::new();
        let mut byte=[0u8;1];
        while request.len()<8192 && !request.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();request.push(byte[0]);
        }
        assert!(request.ends_with(b"\r\n\r\n"));
        String::from_utf8(request).unwrap()
    }

    #[test]
    fn ranged_head_ignores_range_per_http_semantics_without_origin_502_v19() {
        // Range applies to GET. A standards-compliant origin may ignore it on
        // HEAD and respond with 200, which the current proxy incorrectly
        // translates to 502. With trusted manifest length, HEAD is local.
        let origin=TcpListener::bind("127.0.0.1:0").unwrap();
        origin.set_nonblocking(true).unwrap();
        let upstream_url=format!("http://127.0.0.1:{}/v19-head",origin.local_addr().unwrap().port());
        let stop=Arc::new(AtomicBool::new(false));
        let exit=Arc::clone(&stop);
        let upstream=thread::spawn(move||{
            let mut count=0;
            while !exit.load(Ordering::Acquire) {
                match origin.accept() {
                    Ok((mut socket,_))=>{
                        count+=1;
                        let request=upstream_test_request(&socket);
                        assert!(request.starts_with("HEAD /v19-head "));
                        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n").unwrap();
                    },
                    Err(error) if error.kind()==std::io::ErrorKind::WouldBlock=>
                        thread::sleep(Duration::from_millis(5)),
                    Err(error)=>panic!("synthetic origin accept failed: {error}"),
                }
            }
            count
        });
        let (url,_)=start_proxy_internal(reqwest::Url::parse(&upstream_url).unwrap(),
            "video/mp4","mp4",12,true,Duration::from_secs(7),None).unwrap();
        let (code,header,body)=fetch(&url,"HEAD",Some("bytes=2-5"));
        assert!(release_proxy(&url));
        stop.store(true,Ordering::Release);
        let origin_requests=upstream.join().unwrap();
        assert_eq!(code,200,"HEAD with Range must not turn a valid origin 200 into proxy 502");
        assert!(body.is_empty());
        assert!(header.contains("Content-Length: 12"));
        assert!(!header.contains("Content-Range:"));
        assert_eq!(origin_requests,0,"manifest-pinned HEAD must not access remote network");
    }

    #[test]
    fn released_stream_slots_are_reusable_immediately_on_media_reload_v19() {
        // A stream's close command returns synchronously, but its worker
        // polls the cancellation flag at 50ms intervals. Rapid movie/episode
        // reloads can otherwise exhaust all 8 slots just after successful
        // closes and fail to start the next valid stream.
        let upstream=reqwest::Url::parse(
            "http://127.0.0.1:18081/media-reload-v19").unwrap();
        let mut opened=Vec::new();
        let mut capacity_reached=false;
        // Other Rust tests also start media proxies when --test-threads=8.
        // Fill only the currently available slots rather than assuming all
        // eight global slots belong exclusively to this one test.
        for _ in 0..=MAX_PROXIES {
            match start_proxy_internal(upstream.clone(),"video/mp4","mp4",
                12,true,Duration::from_secs(9),None){
                Ok((url,_))=>opened.push(url),
                Err(error) if error.starts_with("Too many media streams")=>{
                    capacity_reached=true;
                    break;
                },
                Err(error)=>panic!("unexpected media fixture error: {error}"),
            }
        }
        assert!(capacity_reached && !opened.is_empty(),
            "fixture must hold one or more slots until global quota is saturated");
        let just_closed=opened.pop().unwrap();
        assert!(release_proxy(&just_closed));
        let (fresh,_)=start_proxy_internal(upstream,"video/mp4","mp4",12,
            true,Duration::from_secs(9),None)
            .expect("one successful stream close must immediately free its quota for a reload");
        assert!(release_proxy(&fresh));
        for url in &opened {assert!(release_proxy(url));}
        assert!(!release_proxy(&just_closed));
        for url in &opened {assert!(!release_proxy(url));}
    }

    #[test]
    fn synthetic_upstream_416_requires_genuine_unsatisfiable_range_and_correct_total() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let origin=format!("http://127.0.0.1:{}/movie",listener.local_addr().unwrap().port());
        let upstream=thread::spawn(move||{
            for _ in 0..4 {
                let (mut stream,_)=listener.accept().unwrap();
                let request=upstream_test_request(&stream);
                let range=request.lines().find(|line|line.to_ascii_lowercase().starts_with("range:"));
                let claimed=if range.is_some_and(|line|line.contains("bytes=12-")){
                    "bytes */12"
                }else{"bytes */13"};
                let reply=format!("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: {claimed}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                stream.write_all(reply.as_bytes()).unwrap();
            }
        });
        let (url,_)=start_proxy_internal(reqwest::Url::parse(&origin).unwrap(),
            "video/mp4","mp4",12,true,Duration::from_secs(5),None).unwrap();
        let (status,header,_)=fetch(&url,"GET",Some("bytes=12-"));
        assert_eq!(status,416);assert!(header.contains("Content-Range: bytes */12"));
        let (status,header,_)=fetch(&url,"GET",Some("bytes=2-5"));
        assert_eq!(status,502);assert!(!header.contains("Content-Range:"));
        let (status,header,_)=fetch(&url,"GET",Some("bytes=100-"));
        assert_eq!(status,502);assert!(!header.contains("Content-Range:"),
            "a forged total must not be passed through despite an unsatisfiable start");
        // Request a plain GET: an upstream 416 is never a valid browser response.
        let (status,_,_)=fetch(&url,"GET",None);
        assert_eq!(status,502);
        assert!(release_proxy(&url));
        upstream.join().unwrap();
    }

    #[test]
    fn v29_duplicate_upstream_content_ranges_do_not_reach_browser(){
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let upstream_url=format!("http://127.0.0.1:{}/v29-range",listener.local_addr().unwrap().port());
        let upstream=thread::spawn(move||{
            for index in 0..2{
                let (mut stream,_)=listener.accept().unwrap();
                let request=upstream_test_request(&stream);
                if index==0 {
                    assert!(request.to_ascii_lowercase().contains("range: bytes=2-5"));
                    stream.write_all(b"HTTP/1.1 206 Partial Content\r\n\
                        Content-Range: bytes 2-5/12\r\n\
                        Content-Range: bytes 0-3/12\r\n\
                        Content-Length: 4\r\nConnection: close\r\n\r\ncdef").unwrap();
                }else{
                    assert!(request.to_ascii_lowercase().contains("range: bytes=12-"));
                    stream.write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\n\
                        Content-Range: bytes */12\r\n\
                        Content-Range: bytes */99\r\n\
                        Content-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                }
            }
        });
        let (url,_)=start_proxy_internal(reqwest::Url::parse(&upstream_url).unwrap(),
            "video/mp4","mp4",12,true,Duration::from_secs(5),None).unwrap();
        let (partial_code,partial_header,partial_body)=fetch(&url,"GET",Some("bytes=2-5"));
        let (unsat_code,unsat_header,unsat_body)=fetch(&url,"GET",Some("bytes=12-"));
        assert!(release_proxy(&url));
        upstream.join().unwrap();
        assert_eq!(partial_code,502,"conflicting 206 Content-Range cannot reach WebView");
        assert_eq!(unsat_code,502,"conflicting 416 Content-Range cannot reach WebView");
        assert!(!partial_header.contains("Content-Range:")&&!unsat_header.contains("Content-Range:"));
        assert!(partial_body.is_empty()&&unsat_body.is_empty());
    }

    #[test]
    fn closing_stream_stops_active_remote_get_before_later_upstream_chunks() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let origin=format!("http://127.0.0.1:{}/chunked",listener.local_addr().unwrap().port());
        let (send_later,may_send_later)=mpsc::channel::<()>();
        let (first_sent,first_sent_rx)=mpsc::channel::<()>();
        let upstream=thread::spawn(move||{
            let (mut socket,_)=listener.accept().unwrap();
            let request=upstream_test_request(&socket);
            assert!(request.starts_with("GET /chunked HTTP/1.1"));
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nabcd").unwrap();
            first_sent.send(()).unwrap();
            may_send_later.recv_timeout(Duration::from_secs(5)).unwrap();
            let _=socket.write_all(b"efgh");
        });
        let (url,_)=start_proxy_internal(reqwest::Url::parse(&origin).unwrap(),
            "video/mp4","mp4",8,true,Duration::from_secs(5),None).unwrap();
        let target=reqwest::Url::parse(&url).unwrap();
        let mut viewer=TcpStream::connect(("127.0.0.1",target.port().unwrap())).unwrap();
        viewer.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        viewer.write_all(format!("GET {} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",target.path()).as_bytes()).unwrap();
        first_sent_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        // HTTP headers and the first fragment are guaranteed to precede the
        // second fragment; close the token while that GET is still active.
        let mut received=Vec::new();
        let mut block=[0u8;1024];
        while !received.ends_with(b"abcd") {
            let size=viewer.read(&mut block).unwrap();
            assert!(size>0 && received.len()<4096,"incomplete synthetic HTTP response");
            received.extend_from_slice(&block[..size]);
        }
        assert!(release_proxy(&url));
        send_later.send(()).unwrap();
        viewer.read_to_end(&mut received).unwrap();
        let boundary=received.windows(4).position(|part|part==b"\r\n\r\n").unwrap()+4;
        assert_eq!(&received[boundary..],b"abcd",
            "released video must not continue streaming later upstream fragments");
        upstream.join().unwrap();
    }

    #[test]
    fn catalog_hides_private_urls_and_validates_pinned_metadata() {
        let url = "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/video.mp4";
        let entry = test_entry(url);
        let raw = serde_json::json!([{
            "id":"demo", "name":"Demo", "type":"episodic-video",
            "episodes":[{"id":"part-1","title":"Part 1","fileName":"sample.mp4",
                "streamUrl":url, "sourceUrl":url, "size":12}]
        }]);
        assert_eq!(validate_manifest(raw.to_string().as_bytes()).unwrap().len(), 1);
        let public = public_catalog(&entry, &[("demo".into(), "/covers/demo.jpg".into())]);
        let serialized = serde_json::to_string(&public).unwrap();
        assert!(!serialized.contains("github.com") && !serialized.contains("streamUrl"));
        assert!(serialized.contains("/covers/demo.jpg"));
        let invalid = raw.to_string().replace("github.com", "localhost");
        assert!(validate_manifest(invalid.as_bytes()).is_err());
    }

    #[test]
    fn actual_embedded_manifest_is_valid_and_public_metadata_has_no_secrets() {
        let private = private_catalog().expect("generated private media manifest must validate");
        assert!(!private.is_empty());
        assert!(private.iter().any(|entry| entry.id == "heart-signal"));
        let covers = crate::services::catalog::read_catalog().unwrap().into_iter()
            .filter(|entry| entry.workflow == "coco-media")
            .map(|entry| (entry.id, entry.image)).collect::<Vec<_>>();
        let public = public_catalog(&private, &covers);
        assert_eq!(public.len(), private.len());
        let serialized = serde_json::to_string(&public).unwrap();
        assert!(!serialized.contains("github.com"));
        assert!(!serialized.contains("sourceUrl"));
        assert!(!serialized.contains("streamUrl"));
        assert!(public.iter().all(|entry| !entry.episodes.is_empty()));
    }

    fn fetch(url: &str, method: &str, range: Option<&str>) -> (u16, String, Vec<u8>) {
        let target = reqwest::Url::parse(url).unwrap();
        let mut stream = TcpStream::connect((target.host_str().unwrap(), target.port().unwrap())).unwrap();
        let mut request = format!("{method} {} HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1:1420\r\n", target.path());
        if let Some(value) = range { request.push_str(&format!("Range: {value}\r\n")); }
        request.push_str("Connection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).unwrap();
        let separator = response.windows(4).position(|part| part == b"\r\n\r\n").unwrap();
        let header = String::from_utf8(response[..separator].to_vec()).unwrap();
        let code = header.split_whitespace().nth(1).unwrap().parse::<u16>().unwrap();
        (code, header, response[separator + 4..].to_vec())
    }

    #[test]
    fn v23_local_head_with_range_follows_http_head_semantics_without_a_body() {
        use std::fs;
        use std::sync::atomic::{AtomicUsize, Ordering};
        static UNIQUE: AtomicUsize = AtomicUsize::new(0);
        let folder = std::env::temp_dir().join(format!("coco-v23-local-head-{}-{}",
            std::process::id(), UNIQUE.fetch_add(1,Ordering::Relaxed)));
        fs::create_dir(&folder).unwrap();
        let path = folder.join("synthetic-episode.mp4");
        fs::write(&path,b"abcdefghijkl").unwrap();
        let upstream=reqwest::Url::parse(
            "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/synthetic.mp4").unwrap();
        let (url,_)=start_proxy_internal(upstream,"video/mp4","mp4",12,false,
            Duration::from_secs(4),Some(File::open(&path).unwrap())).unwrap();
        let (code,headers,bytes)=fetch(&url,"HEAD",Some("bytes=3-5"));
        let (get_code,get_headers,get_bytes)=fetch(&url,"GET",Some("bytes=3-5"));
        assert!(release_proxy(&url));
        thread::sleep(Duration::from_millis(150));
        fs::remove_file(&path).unwrap();
        fs::remove_dir(&folder).unwrap();
        assert_eq!(code,200,"HEAD Range must be ignored just like remote manifest-backed HEAD");
        assert!(headers.contains("Content-Length: 12"));
        assert!(!headers.contains("Content-Range:"));
        assert!(bytes.is_empty());
        assert_eq!(get_code,206,"GET Range must remain byte-addressable");
        assert!(get_headers.contains("Content-Range: bytes 3-5/12"));
        assert_eq!(get_bytes,b"def");
    }

    #[test]
    fn v23_upstream_compressed_206_cannot_be_misrepresented_as_raw_video_bytes() {
        let listener=TcpListener::bind("127.0.0.1:0").unwrap();
        let origin=format!("http://127.0.0.1:{}/compressed-206",listener.local_addr().unwrap().port());
        let origin_worker=thread::spawn(move||{
            let (mut socket,_)=listener.accept().unwrap();
            let request=upstream_test_request(&socket);
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\n\
                Content-Length: 4\r\n\
                Content-Range: bytes 3-6/12\r\n\
                Content-Encoding: gzip\r\n\
                Connection: close\r\n\r\nzzzz").unwrap();
            request
        });
        let (url,_)=start_proxy_internal(reqwest::Url::parse(&origin).unwrap(),
            "video/mp4","mp4",12,true,Duration::from_secs(4),None).unwrap();
        let (code,headers,bytes)=fetch(&url,"GET",Some("bytes=3-6"));
        assert!(release_proxy(&url));
        let seen=origin_worker.join().unwrap();
        assert!(seen.to_ascii_lowercase().contains("range: bytes=3-6"));
        assert!(seen.to_ascii_lowercase().contains("accept-encoding: identity"));
        assert_eq!(code,502,"encoded 206 must fail before exposing claimed raw video bytes");
        assert!(!headers.contains("Content-Range:"));
        assert!(bytes.is_empty());
    }

    #[test]
    fn local_range_proxy_supports_seek_head_cors_and_token_guard_without_real_network() {
        let (origin, upstream_requests, upstream_handle) = fixture_upstream();
        // The production TTL is six hours; allow the synthetic server enough
        // time for each request even when parallel native E2E tests load CPU.
        let prepared = prepared_stream(&test_entry(&origin), "demo", "part-1", true, Duration::from_secs(20)).unwrap();
        assert!(prepared.url.starts_with("http://127.0.0.1:"));
        assert!(!prepared.url.contains(&origin));
        let (status, headers, bytes) = fetch(&prepared.url, "GET", Some("bytes=2-5"));
        assert_eq!(status, 206);
        assert_eq!(bytes, b"cdef");
        assert!(headers.contains("Content-Range: bytes 2-5/12"));
        assert!(headers.contains("Access-Control-Allow-Origin: *"));
        let (status, _, bytes) = fetch(&prepared.url, "HEAD", None);
        assert_eq!(status, 200);
        assert!(bytes.is_empty());
        let (status, _, bytes) = fetch(&prepared.url, "GET", Some("bytes=-3"));
        assert_eq!(status, 206);
        assert_eq!(bytes, b"jkl");
        let (status, headers, bytes) = fetch(&prepared.url, "OPTIONS", None);
        assert_eq!(status, 204);
        assert!(bytes.is_empty() && headers.contains("Access-Control-Allow-Headers: Range"));
        let (status, _, _) = fetch(&prepared.url, "GET", Some("bytes=80-"));
        assert_eq!(status, 416);
        let (status, _, _) = fetch(&prepared.url.replace("/video.mp4", "/other.mp4"), "GET", None);
        assert_eq!(status, 404);
        assert!(release_proxy(&prepared.url));
        assert!(!release_proxy(&prepared.url));
        for _ in 0..3 { upstream_requests.recv_timeout(Duration::from_secs(5)).unwrap(); }
        upstream_handle.join().unwrap();
    }

    #[test]
    fn verified_local_media_serves_video_range_without_upstream_requests() {
        use std::fs::{self,File};
        use std::sync::atomic::{AtomicUsize,Ordering};
        static SERIAL:AtomicUsize=AtomicUsize::new(0);
        let folder=std::env::temp_dir().join(format!("coco-local-range-{}-{}",
            std::process::id(),SERIAL.fetch_add(1,Ordering::Relaxed)));
        fs::create_dir(&folder).unwrap();
        let local=folder.join("episode.mp4");
        fs::write(&local,b"abcdefghijkl").unwrap();
        let upstream=reqwest::Url::parse(
            "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/fixture.mp4").unwrap();
        let (url,_)=start_proxy_internal(
            upstream,"video/mp4","mp4",12,false,Duration::from_secs(3),
            Some(File::open(&local).unwrap())).unwrap();
        let (code,headers,bytes)=fetch(&url,"GET",Some("bytes=3-7"));
        assert_eq!(code,206);
        assert_eq!(&bytes,b"defgh");
        assert!(headers.contains("Content-Range: bytes 3-7/12"));
        let (code,_,bytes)=fetch(&url,"HEAD",None);
        assert_eq!(code,200);
        assert!(bytes.is_empty());
        let (code,_,bytes)=fetch(&url,"GET",Some("bytes=-4"));
        assert_eq!(code,206);
        assert_eq!(&bytes,b"ijkl");
        let (code,_,_)=fetch(&url,"GET",Some("bytes=40-"));
        assert_eq!(code,416);
        assert!(release_proxy(&url));
        // Windows playback handle is owned by the transient local server;
        // wait for its TTL before releasing a read-only fixture directory.
        thread::sleep(Duration::from_millis(150));
        let _=fs::remove_file(&local);
        let _=fs::remove_dir(&folder);
    }

    #[test]
    fn stalled_local_large_get_cannot_block_an_independent_range_seek() {
        use std::fs;
        let folder=std::env::temp_dir().join(format!("coco-concurrent-range-{}",std::process::id()));
        fs::create_dir(&folder).unwrap();
        let path=folder.join("large-fixture.mp4");
        let file=File::options().read(true).write(true).create_new(true).open(&path).unwrap();
        let size=32*1024*1024u64;
        file.set_len(size).unwrap();
        drop(file);
        let upstream=reqwest::Url::parse(
            "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/v1/fixture.mp4").unwrap();
        let (url,_)=start_proxy_internal(upstream,"video/mp4","mp4",size,false,
            Duration::from_secs(5),Some(File::open(&path).unwrap())).unwrap();
        let parsed=reqwest::Url::parse(&url).unwrap();
        let mut slow=TcpStream::connect((parsed.host_str().unwrap(),parsed.port().unwrap())).unwrap();
        slow.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        slow.write_all(format!("GET {} HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\nConnection: close\r\n\r\n",parsed.path()).as_bytes()).unwrap();
        let mut header=[0u8;512];
        let received=slow.read(&mut header).unwrap();
        assert!(String::from_utf8_lossy(&header[..received]).contains("HTTP/1.1 206"));
        // Do not consume the 32 MiB body. The first writer will stall once
        // TCP backpressure fills its socket buffers, but a new seek must work.
        let (tx,rx)=mpsc::channel();
        let second_url=url.clone();
        let second=thread::spawn(move||{let _=tx.send(fetch(&second_url,"GET",Some("bytes=2-5")));});
        let result=rx.recv_timeout(Duration::from_secs(2));
        drop(slow);
        if let Ok((code,_,bytes))=result {
            assert_eq!(code,206);
            assert_eq!(bytes,vec![0u8;4]);
        }else{panic!("Local Range seek stalled behind a different client's GET");}
        second.join().unwrap();
        assert!(release_proxy(&url));
        thread::sleep(Duration::from_millis(200));
        fs::remove_file(&path).unwrap();
        fs::remove_dir(&folder).unwrap();
    }
}
