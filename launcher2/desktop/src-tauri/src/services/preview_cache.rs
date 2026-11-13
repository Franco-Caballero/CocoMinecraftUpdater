//! Permanent per-user cache of the host-curated hover clips. Once a clip is on
//! disk a hover never touches the network again, across launches and updates.
//! The sources are embedded at build time; the frontend cannot add URLs.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const CURATED: &str = include_str!("../../../src/game-hover-previews.json");
const ALLOWED_HOSTS: [&str; 2] = ["cdn.akamai.steamstatic.com", "shared.akamai.steamstatic.com"];
const MAX_CLIP_BYTES: u64 = 64 * 1024 * 1024;
const WEBM_MAGIC: [u8; 4] = [0x1A, 0x45, 0xDF, 0xA3];
const HEADER_BYTES: usize = 8;
// All clips together weigh a few dozen MiB, so finish quickly on first launch.
const WORKERS: usize = 10;
const ATTEMPTS: usize = 3;

static RUNNING: AtomicBool = AtomicBool::new(false);
/// Clips still to fetch this session. Shared so a hover can move its clip to the front.
static QUEUE: Mutex<VecDeque<(String, String)>> = Mutex::new(VecDeque::new());

#[derive(Deserialize)]
struct CuratedClip { url: String }

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CachedPreview { pub id: String, pub path: String }

fn curated() -> Result<BTreeMap<String, CuratedClip>, String> {
    let all: BTreeMap<String, CuratedClip> = serde_json::from_str(CURATED)
        .map_err(|error| format!("Invalid curated previews: {error}"))?;
    Ok(all.into_iter().filter(|(_, clip)| allowed_url(&clip.url)).collect())
}

fn allowed_url(url: &str) -> bool {
    reqwest::Url::parse(url).is_ok_and(|parsed| {
        parsed.scheme() == "https"
            && parsed.host_str().is_some_and(|host| ALLOWED_HOSTS.contains(&host))
            && clip_extension(parsed.path()).is_some()
    })
}

/// Steam serves microtrailers as WebM and newer store clips as MP4.
fn clip_extension(path: &str) -> Option<&'static str> {
    if path.ends_with(".webm") { Some("webm") } else if path.ends_with(".mp4") { Some("mp4") } else { None }
}

fn valid_header(extension: &str, header: &[u8]) -> bool {
    match extension {
        "webm" => header.starts_with(&WEBM_MAGIC),
        "mp4" => header.len() >= HEADER_BYTES && &header[4..8] == b"ftyp",
        _ => false,
    }
}

fn cache_dir() -> Result<PathBuf, String> {
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
        .map(|root| root.join("CocoMinecraftUpdater").join("preview-cache"))
        .ok_or_else(|| "LOCALAPPDATA unavailable".to_string())
}

/// Addressed by source URL: replacing a trailer in the curated list downloads
/// a new file instead of ever serving the previous clip under the same name.
fn clip_file(dir: &Path, url: &str) -> PathBuf {
    let digest = Sha256::digest(url.as_bytes());
    let name = digest.iter().take(16).map(|byte| format!("{byte:02x}")).collect::<String>();
    dir.join(format!("{name}.{}", clip_extension(url).unwrap_or("webm")))
}

fn scan(dir: &Path, clips: &BTreeMap<String, CuratedClip>) -> Vec<CachedPreview> {
    clips.iter().filter_map(|(id, clip)| {
        let path = clip_file(dir, &clip.url);
        let complete = fs::symlink_metadata(&path)
            .is_ok_and(|meta| meta.is_file() && meta.len() > 0);
        complete.then(|| CachedPreview { id: id.clone(), path: path.to_string_lossy().into_owned() })
    }).collect()
}

/// Publish only a fully received video. The rename is the commit point, so a
/// crash or a lost connection can never leave a truncated clip behind.
fn store_clip(mut body: impl Read, target: &Path, expected: Option<u64>) -> Result<(), String> {
    if expected.is_some_and(|size| size == 0 || size > MAX_CLIP_BYTES) {
        return Err("Preview outside allowed size".into());
    }
    let extension = target.extension().and_then(|value| value.to_str()).unwrap_or_default().to_string();
    let part = target.with_extension(format!("{}.part", std::process::id()));
    let result = (|| {
        let mut output = File::create(&part).map_err(|error| error.to_string())?;
        let mut buffer = [0u8; 64 * 1024];
        let mut received = 0u64;
        let mut first = Vec::with_capacity(HEADER_BYTES);
        loop {
            let count = body.read(&mut buffer).map_err(|error| error.to_string())?;
            if count == 0 { break; }
            received += count as u64;
            if received > MAX_CLIP_BYTES { return Err("Preview outside allowed size".to_string()); }
            if first.len() < HEADER_BYTES {
                let missing = (HEADER_BYTES - first.len()).min(count);
                first.extend_from_slice(&buffer[..missing]);
            }
            output.write_all(&buffer[..count]).map_err(|error| error.to_string())?;
        }
        if !valid_header(&extension, &first) { return Err("Preview is not a video file".to_string()); }
        if expected.is_some_and(|size| size != received) { return Err("Truncated preview".to_string()); }
        output.sync_all().map_err(|error| error.to_string())?;
        drop(output);
        fs::rename(&part, target).map_err(|error| error.to_string())
    })();
    if result.is_err() { let _ = fs::remove_file(&part); }
    result
}

fn client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let trusted = attempt.url().host_str().is_some_and(|host| ALLOWED_HOSTS.contains(&host));
            if attempt.previous().len() >= 3 || !trusted { attempt.stop() } else { attempt.follow() }
        }))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(120))
        .build().map_err(|error| error.to_string())
}

fn download(client: &reqwest::blocking::Client, url: &str, target: &Path) -> Result<(), String> {
    let response = client.get(url).send().and_then(|r| r.error_for_status())
        .map_err(|error| error.to_string())?;
    let expected = response.content_length();
    store_clip(response, target, expected)
}

/// Clears interrupted transfers from earlier sessions. Finished clips stay forever.
fn remove_partials(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if entry.path().extension().is_some_and(|ext| ext == "part") {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn pending_order(clips: &BTreeMap<String, CuratedClip>, cached: &[CachedPreview], priority: &[String])
    -> VecDeque<(String, String)> {
    let done = |id: &String| cached.iter().any(|entry| &entry.id == id);
    let mut queue = VecDeque::new();
    for id in priority.iter().chain(clips.keys()) {
        if done(id) || queue.iter().any(|(queued, _): &(String, String)| queued == id) { continue; }
        if let Some(clip) = clips.get(id) { queue.push_back((id.clone(), clip.url.clone())); }
    }
    queue
}

#[tauri::command]
pub async fn get_preview_cache() -> Result<Vec<CachedPreview>, String> {
    tauri::async_runtime::spawn_blocking(|| Ok(scan(&cache_dir()?, &curated()?)))
        .await.map_err(|error| format!("Preview cache read interrupted: {error}"))?
}

/// Starts the background downloader once per session. Returns immediately; each
/// finished clip is announced through `coco2://preview-ready`.
#[tauri::command]
pub async fn start_preview_cache(app: AppHandle, priority: Vec<String>) -> Result<usize, String> {
    if RUNNING.swap(true, Ordering::SeqCst) { return Ok(0); }
    let prepared = tauri::async_runtime::spawn_blocking(move || -> Result<_, String> {
        let dir = cache_dir()?;
        fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
        remove_partials(&dir);
        let clips = curated()?;
        Ok((pending_order(&clips, &scan(&dir, &clips), &priority), dir))
    }).await.map_err(|error| format!("Preview cache interrupted: {error}"))?;
    let (queue, dir) = match prepared {
        Ok(value) => value,
        Err(error) => { RUNNING.store(false, Ordering::SeqCst); return Err(error); }
    };
    let total = queue.len();
    if total == 0 { RUNNING.store(false, Ordering::SeqCst); return Ok(0); }
    let http = match client() {
        Ok(value) => value,
        Err(error) => { RUNNING.store(false, Ordering::SeqCst); return Err(error); }
    };
    if let Ok(mut shared) = QUEUE.lock() { *shared = queue; }
    let remaining = Arc::new(Mutex::new(WORKERS));
    for _ in 0..WORKERS {
        let (remaining, dir, http, app) = (remaining.clone(), dir.clone(), http.clone(), app.clone());
        std::thread::spawn(move || {
            loop {
                let Some((id, url)) = QUEUE.lock().ok().and_then(|mut q| q.pop_front()) else { break };
                let target = clip_file(&dir, &url);
                let stored = (0..ATTEMPTS).any(|attempt| {
                    if attempt > 0 { std::thread::sleep(Duration::from_secs(2 << attempt)); }
                    download(&http, &url, &target).is_ok()
                });
                if stored {
                    let _ = app.emit("coco2://preview-ready", CachedPreview {
                        id, path: target.to_string_lossy().into_owned(),
                    });
                }
            }
            // A failed clip falls back to streaming and is retried next launch.
            if let Ok(mut left) = remaining.lock() {
                *left -= 1;
                if *left == 0 {
                    RUNNING.store(false, Ordering::SeqCst);
                    let _ = app.emit("coco2://preview-cache-finished", ());
                }
            }
        });
    }
    Ok(total)
}

/// The clip the player is looking at jumps the line; one already downloading or done is left alone.
#[tauri::command]
pub fn prioritize_preview(id: String) {
    let Ok(mut queue) = QUEUE.lock() else { return };
    if let Some(at) = queue.iter().position(|(queued, _)| *queued == id) {
        if let Some(clip) = queue.remove(at) { queue.push_front(clip); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("coco2-preview-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }
    #[test]
    fn mp4_clips_are_cached_under_their_own_extension() {
        let dir = temp("mp4");
        let url = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1/extras/a.mp4";
        assert!(allowed_url(url));
        let target = clip_file(&dir, url);
        assert_eq!(target.extension().unwrap(), "mp4");
        let mut bytes = vec![0, 0, 0, 24];
        bytes.extend_from_slice(b"ftypisom");
        bytes.resize(4096, 1);
        store_clip(&bytes[..], &target, Some(4096)).unwrap();
        assert_eq!(fs::read(&target).unwrap(), bytes);
        let wrong = clip_file(&dir, "https://shared.akamai.steamstatic.com/b.mp4");
        assert!(store_clip(&webm(4096)[..], &wrong, None).is_err(), "a WebM body is not an MP4");
    }

    fn webm(size: usize) -> Vec<u8> {
        let mut bytes = WEBM_MAGIC.to_vec();
        bytes.resize(size, 7);
        bytes
    }

    #[test]
    fn every_curated_clip_passes_the_host_allowlist() {
        let parsed: BTreeMap<String, CuratedClip> = serde_json::from_str(CURATED).unwrap();
        assert!(!parsed.is_empty());
        // A clip shipped inside the app (Steam had no short one) is served locally and never fetched.
        for clip in parsed.values() {
            if let Some(bundled) = clip.url.strip_prefix('/') {
                assert!(Path::new(env!("CARGO_MANIFEST_DIR")).join("../public").join(bundled).is_file(), "{}", clip.url);
            } else {
                assert!(allowed_url(&clip.url), "{}", clip.url);
            }
        }
    }

    #[test]
    fn only_https_steam_webm_urls_are_allowed() {
        assert!(allowed_url("https://cdn.akamai.steamstatic.com/steam/apps/1/microtrailer.webm"));
        assert!(!allowed_url("http://cdn.akamai.steamstatic.com/steam/apps/1/microtrailer.webm"));
        assert!(!allowed_url("https://evil.example/steam/apps/1/microtrailer.webm"));
        assert!(!allowed_url("https://cdn.akamai.steamstatic.com/payload.exe"));
    }

    #[test]
    fn a_complete_clip_is_published_and_scanned_as_cached() {
        let dir = temp("complete");
        let url = "https://cdn.akamai.steamstatic.com/a.webm";
        let bytes = webm(200_000);
        store_clip(&bytes[..], &clip_file(&dir, url), Some(bytes.len() as u64)).unwrap();
        let clips = BTreeMap::from([("game".to_string(), CuratedClip { url: url.into() })]);
        let cached = scan(&dir, &clips);
        assert_eq!(cached.len(), 1);
        assert_eq!(fs::read(&cached[0].path).unwrap(), bytes);
        assert!(pending_order(&clips, &cached, &[]).is_empty());
    }

    #[test]
    fn truncated_or_foreign_bytes_never_become_a_cached_clip() {
        let dir = temp("rejected");
        let target = clip_file(&dir, "https://cdn.akamai.steamstatic.com/a.webm");
        assert!(store_clip(&webm(100)[..], &target, Some(500)).is_err());
        assert!(store_clip(&b"<html>not video</html>"[..], &target, None).is_err());
        assert!(!target.exists());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0, "failed transfers leave no partial file");
    }

    #[test]
    fn priority_clips_download_first_without_duplicates() {
        let clips = BTreeMap::from([
            ("a".to_string(), CuratedClip { url: "https://x/a.webm".into() }),
            ("b".to_string(), CuratedClip { url: "https://x/b.webm".into() }),
        ]);
        let order = pending_order(&clips, &[], &["b".into(), "b".into(), "unknown".into()]);
        assert_eq!(order.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
    }
}
