//! Movies and series signed by the host, on their own channel next to the games one.
//!
//! A new episode or film reaches every open Coco within minutes, without a new Setup: the host
//! publishes `coco2-media-head.json` → `coco2-media-s<N>.json` (+ `.sig`) on `coco2-channel`
//! (`scripts/Publish-Coco2Media.mjs`). The body lists every title as its public card plus its
//! private manifest (streams, parts, subtitles), signed with the updater key. Coco versions before
//! this one never read these names, and the games channel stays games only (older clients reject
//! a games channel with anything else in it).
//!
//! A signed title replaces the one this Setup ships only when it holds every episode the Setup
//! knows (a newer Setup is never shortened by an older channel); a title this Setup does not have
//! is added at the end of the library, so it shows as the latest addition.

use crate::services::catalog::Experience;
use crate::services::catalog::catalog_channel as channel;
use crate::services::media::PrivateMedia;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const HEAD: &str = "coco2-media-head.json";
const MAX_HEAD: u64 = 4096;
const MAX_BODY: u64 = 16 * 1024 * 1024;
const MAX_MEDIA: usize = 128;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Head {
    schema_version: u32,
    sequence: u64,
    sha256: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Body {
    schema_version: u32,
    sequence: u64,
    media: Vec<RawRecord>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRecord {
    entry: Experience,
    manifest: serde_json::Value,
}

#[derive(Clone, Debug)]
pub(super) struct Record {
    pub(super) entry: Experience,
    pub(super) media: PrivateMedia,
}

fn cache_dir() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|local| Path::new(&local).join("CocoLauncher2").join("media-channel"))
}

fn hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    (2..=48).contains(&bytes.len()) && bytes[0].is_ascii_lowercase()
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

/// The signed body, checked entry by entry; one bad title rejects the whole channel.
fn decode(body: &[u8]) -> Result<(u64, Vec<Record>), String> {
    if body.len() as u64 > MAX_BODY { return Err("Media channel oversized".into()); }
    let parsed: Body = serde_json::from_slice(body).map_err(|error| format!("Invalid media channel: {error}"))?;
    if parsed.schema_version != 1 || parsed.sequence == 0 || parsed.media.is_empty() || parsed.media.len() > MAX_MEDIA {
        return Err("Invalid media channel header".into());
    }
    let manifests: Vec<&serde_json::Value> = parsed.media.iter().map(|record| &record.manifest).collect();
    let raw = serde_json::to_vec(&manifests).map_err(|error| error.to_string())?;
    let private = super::media::validate_manifest(&raw)?;
    let mut ids = HashSet::new();
    let mut records = Vec::new();
    for (raw, media) in parsed.media.into_iter().zip(private) {
        let e = &raw.entry;
        if e.id != media.id || !valid_id(&e.id) || !ids.insert(e.id.clone()) || e.instance_id.trim().is_empty()
            || e.workflow != "coco-media" || e.name.trim().is_empty() || !e.executable.is_empty()
            || !e.required_files.is_empty() || !e.launch_arguments.is_empty()
            || !e.minecraft_version.is_empty() || !e.loader.is_empty() || e.description.chars().count() > 10_000 {
            return Err(format!("Invalid signed media entry: {}", e.id));
        }
        channel::verify_cover(&e.image)?;
        if channel::withdrawn(&e.id) { continue; }
        records.push(Record { entry: raw.entry, media });
    }
    Ok((parsed.sequence, records))
}

/// The verified cached channel; re-checked against the key whenever its bytes change.
fn load() -> Option<(u64, String, Vec<Record>)> {
    static MEMO: Mutex<Option<(String, u64, Vec<Record>)>> = Mutex::new(None);
    let dir = cache_dir()?;
    let body = std::fs::read(dir.join("body.json")).ok()?;
    let digest = hex(&body);
    if let Ok(memo) = MEMO.lock() {
        if let Some((sha, sequence, records)) = memo.as_ref().filter(|(sha, ..)| *sha == digest) {
            return Some((*sequence, sha.clone(), records.clone()));
        }
    }
    let sig = std::fs::read(dir.join("body.sig")).ok()?;
    let key = channel::embedded_key().ok()?;
    channel::verify_detached(&body, &sig, &key).ok()?;
    let (sequence, records) = decode(&body).ok()?;
    if let Ok(mut memo) = MEMO.lock() { *memo = Some((digest.clone(), sequence, records.clone())); }
    Some((sequence, digest, records))
}

/// Reads the small head and, when it names a newer channel, downloads, verifies and caches it.
/// `true` when the movies and series changed.
pub(super) fn sync(key: &[u8; 32]) -> Result<bool, String> {
    let client = channel::http_client()?;
    let base = channel::channel_base();
    let head = match channel::fetch_bounded(&client, &format!("{base}{HEAD}"), MAX_HEAD) {
        Ok(bytes) => bytes,
        // Not published yet, or no connection: what is cached stays.
        Err(error) if channel::offline_error(&error) => return Ok(false),
        Err(error) => return Err(error),
    };
    let head: Head = serde_json::from_slice(&head).map_err(|_| "Invalid media channel head")?;
    if head.schema_version != 1 || head.sequence == 0 || head.sha256.len() != 64 {
        return Err("Invalid media channel head".into());
    }
    if let Some((sequence, digest, _)) = load() {
        // Never go back to an older channel, nor fetch the one already here.
        if head.sequence < sequence || head.sequence == sequence && head.sha256.eq_ignore_ascii_case(&digest) {
            return Ok(false);
        }
    }
    let name = format!("{base}coco2-media-s{}.json", head.sequence);
    let body = match channel::fetch_bounded(&client, &name, MAX_BODY) {
        Ok(bytes) => bytes,
        Err(error) if channel::offline_error(&error) => return Ok(false),
        Err(error) => return Err(error),
    };
    if !hex(&body).eq_ignore_ascii_case(&head.sha256) { return Err("Media channel does not match its head".into()); }
    let sig = match channel::fetch_bounded(&client, &format!("{name}.sig"), 512) {
        Ok(bytes) => bytes,
        Err(error) if channel::offline_error(&error) => return Ok(false),
        Err(error) => return Err(error),
    };
    channel::verify_detached(&body, &sig, key)?;
    let (sequence, records) = decode(&body)?;
    if sequence != head.sequence { return Err("Media channel sequence disagrees with its head".into()); }
    let dir = cache_dir().ok_or("Sin LOCALAPPDATA")?;
    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
    // The signature lands first: a body without its own signature never loads.
    for (file, bytes) in [("body.sig", &sig), ("body.json", &body)] {
        let temp = dir.join(format!("{file}.tmp"));
        std::fs::write(&temp, bytes).map_err(|error| error.to_string())?;
        std::fs::rename(&temp, dir.join(file)).map_err(|error| error.to_string())?;
    }
    super::diagnostics::log("catalog", &format!("películas y series firmadas s{sequence}: {} títulos", records.len()));
    Ok(true)
}

/// The signed titles that apply on this Setup (see the module notes).
pub(super) fn accepted() -> Vec<Record> {
    accepted_against(load().map(|(_, _, records)| records).unwrap_or_default(),
        &super::media::embedded_media().unwrap_or_default())
}

fn accepted_against(records: Vec<Record>, embedded: &[PrivateMedia]) -> Vec<Record> {
    records.into_iter().filter(|record| match embedded.iter().find(|media| media.id == record.media.id) {
        Some(shipped) => shipped.episodes.iter().all(|episode| record.media.episodes.iter().any(|signed| signed.id == episode.id)),
        None => true,
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const COVER: &str = "data:image/png;base64,iVBORw0KGgoAAAA=";
    fn url(name: &str) -> String {
        format!("https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/serie/{name}")
    }
    fn record(id: &str, episodes: &[&str]) -> serde_json::Value {
        serde_json::json!({
            "entry": {"id":id,"instanceId":id,"name":"Serie","image":COVER,"description":"Una serie.","workflow":"coco-media",
                "minecraftVersion":"","loader":"","requiredFiles":[],"executable":"","launchArguments":[],"hostingMode":""},
            "manifest": {"id":id,"name":"Serie","type":"episodic-video","episodes":episodes.iter().map(|ep| serde_json::json!({
                "id":ep,"title":format!("Episodio {ep}"),"fileName":format!("{ep}.mkv"),"streamUrl":url(&format!("{ep}.mkv")),
                "sourceUrl":url(&format!("{ep}.mkv")),"size":10,"sha256":"a".repeat(64)})).collect::<Vec<_>>()}
        })
    }
    fn body(records: Vec<serde_json::Value>) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({"schemaVersion":1,"sequence":3,"media":records})).unwrap()
    }

    #[test]
    fn a_signed_title_is_checked_whole() {
        let (sequence, records) = decode(&body(vec![record("serie-nueva", &["ep-1", "ep-2"])])).unwrap();
        assert_eq!(sequence, 3);
        assert_eq!(records[0].media.episodes.len(), 2);
        assert_eq!(records[0].entry.workflow, "coco-media");
        let mut game = record("juego", &["ep-1"]);
        game["entry"]["workflow"] = "coco-standalone".into();
        assert!(decode(&body(vec![game])).is_err(), "a game never rides the media channel");
        let mut foreign = record("serie", &["ep-1"]);
        foreign["manifest"]["episodes"][0]["streamUrl"] = "https://evil.example/ep.mkv".into();
        assert!(decode(&body(vec![foreign])).is_err(), "streams only from the owned releases");
        let mut mismatched = record("serie", &["ep-1"]);
        mismatched["manifest"]["id"] = "otra".into();
        assert!(decode(&body(vec![mismatched])).is_err());
        let mut cover = record("serie", &["ep-1"]);
        cover["entry"]["image"] = "https://example.com/cover.png".into();
        assert!(decode(&body(vec![cover])).is_err(), "covers travel inside the signed body");
        assert!(decode(&body(vec![record("serie", &["ep-1"]), record("serie", &["ep-2"])])).is_err(), "unique titles");
        let mut extra = serde_json::from_slice::<serde_json::Value>(&body(vec![record("serie", &["ep-1"])])).unwrap();
        extra["unexpected"] = true.into();
        assert!(decode(&serde_json::to_vec(&extra).unwrap()).is_err());
    }

    #[test]
    fn a_signed_title_never_shortens_what_the_setup_ships() {
        let signed = |episodes: &[&str]| decode(&body(vec![record("serie", episodes)])).unwrap().1;
        let shipped = decode(&body(vec![record("serie", &["ep-1", "ep-2"])])).unwrap().1.into_iter().map(|r| r.media).collect::<Vec<_>>();
        assert_eq!(accepted_against(signed(&["ep-1", "ep-2", "ep-3"]), &shipped).len(), 1, "a new episode arrives");
        assert!(accepted_against(signed(&["ep-1"]), &shipped).is_empty(), "an older channel loses to a newer Setup");
        assert_eq!(accepted_against(signed(&["ep-9"]), &[]).len(), 1, "a title the Setup lacks is added");
    }
}
