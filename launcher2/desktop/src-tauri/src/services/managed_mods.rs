//! Host-selected mods from their original Thunderstore packages. The signed
//! launcher pins both the archives and the files they may supply.
use super::{
    assert_no_links, cancelled, copy_stream, create_stage, download_one, ensure_free_space,
    inspect_zip, matches_digest, normal_path, pin_verified_archives, publish_stage,
    safe_archive_redirect, valid_hash, ArchiveSpec, Manifest, HTTP_CHUNK_TIMEOUT,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::{atomic::AtomicBool, OnceLock};
use std::time::Duration;

const GAME: &str = "lethal-company";
const LOCK: &str = include_str!("../../resources/lethal-company-mods.json");
const PROXY: &str = "winhttp.dll";
const PRELOADER: &str = "BepInEx/core/BepInEx.Preloader.dll";
const MIRROR: &str =
    "https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/download/lethal-company-mods-v81/";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Profile {
    game_executable: String,
    game_executable_sha256: String,
    packages: Vec<Package>,
    defaults: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct Package {
    name: String,
    #[serde(flatten)]
    archive: ArchiveSpec,
    files: Vec<InstalledFile>,
    #[serde(rename = "disabledReason", default)]
    disabled_reason: String,
}

impl Profile {
    fn active_packages(&self) -> impl Iterator<Item = &Package> {
        self.packages.iter().filter(|package| package.disabled_reason.is_empty())
    }
}

#[derive(Deserialize)]
struct InstalledFile {
    source: String,
    path: String,
    sha256: String,
    size: u64,
}

fn profile() -> Result<&'static Profile, String> {
    static PROFILE: OnceLock<Result<Profile, String>> = OnceLock::new();
    PROFILE.get_or_init(|| {
        let profile: Profile = serde_json::from_str(LOCK).map_err(|error| error.to_string())?;
        let mut paths = HashSet::new();
        for package in &profile.packages {
            let (name, version) = package.name.rsplit_once('-').ok_or("Mod sin versión")?;
            let (owner, slug) = name.split_once('-').ok_or("Mod sin autor")?;
            let url = format!("https://thunderstore.io/package/download/{owner}/{slug}/{version}/");
            if package.archive.url != url || !valid_hash(&package.archive.sha256)
                || package.archive.size == 0
                || package.files.is_empty() == package.disabled_reason.is_empty()
            {
                return Err(format!("Paquete de mods inválido: {}", package.name));
            }
            for file in &package.files {
                if normal_path(&file.source)? != file.source || normal_path(&file.path)? != file.path
                    || !valid_hash(&file.sha256) || !paths.insert(file.path.to_lowercase())
                    || !(file.path == PROXY || ["core", "config", "patchers", "plugins"]
                        .iter().any(|folder| file.path.starts_with(&format!("BepInEx/{folder}/"))))
                {
                    return Err(format!("Ruta o hash de mod inválido: {}", file.path));
                }
            }
        }
        for path in profile.defaults.keys() {
            if normal_path(path)? != *path || !path.starts_with("BepInEx/config/")
                || !paths.insert(path.to_lowercase())
            {
                return Err(format!("Configuración de mods inválida: {path}"));
            }
        }
        if !paths.contains(PROXY) || !paths.contains(&PRELOADER.to_lowercase()) {
            return Err("Faltan los archivos de arranque de BepInEx".into());
        }
        Ok(profile)
    }).as_ref().map_err(Clone::clone)
}

/// Coco 0.6.61 hashed the lock as it was on the build machine, with CRLF line
/// ends, while Git stores it with LF. Hash the CRLF form whatever the checkout
/// has, so installed profiles keep their folder (9ffcd019ec4982cdfff815d4).
fn profile_identity() -> String {
    let crlf = LOCK.replace("\r\n", "\n").replace('\n', "\r\n");
    format!("{:x}", Sha256::digest(crlf.as_bytes()))
}

fn profile_for(id: &str, executable_hash: &str) -> Result<Option<&'static Profile>, String> {
    if id != GAME { return Ok(None); }
    let profile = profile()?;
    if executable_hash.eq_ignore_ascii_case(&profile.game_executable_sha256) {
        return Ok(Some(profile));
    }
    Err("El perfil de mods requiere el ejecutable de Lethal Company v81 autorizado".into())
}

fn install_profile(manifest: &Manifest) -> Result<Option<&'static Profile>, String> {
    if !applies(&manifest.id) { return Ok(None); }
    let profile = profile()?;
    let executable = manifest.required_files.iter().find(|file| file.path == profile.game_executable)
        .ok_or("Falta el ejecutable de Lethal Company en el manifiesto del juego")?;
    profile_for(&manifest.id, &executable.sha256)
}

pub(super) fn download_size(manifest: &Manifest) -> (usize, u64) {
    install_profile(manifest).ok().flatten().map_or((0, 0), |profile| (
        profile.active_packages().count(),
        profile.active_packages().map(|package| package.archive.size).sum(),
    ))
}

pub(super) fn prepare_install(
    manifest: &Manifest, root: &Path, cache: &Path, token: &AtomicBool,
    progress: &mut impl FnMut(&'static str, &str, u64, u64),
) -> Result<(), String> {
    if let Some(profile) = install_profile(manifest)? {
        prepare(&manifest.id, &profile.game_executable_sha256, root, &profile.game_executable,
            cache, token, progress)?;
    }
    Ok(())
}

fn copy_locked_file(
    source: &mut impl std::io::Read, destination: &Path, file: &InstalledFile, token: &AtomicBool,
) -> Result<(), String> {
    let parent = destination.parent().ok_or("Ruta de mod sin carpeta")?;
    assert_no_links(parent)?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let mut output = OpenOptions::new().create_new(true).write(true).open(destination)
        .map_err(|error| error.to_string())?;
    copy_stream(source, &mut output, 0, file.size, token, &mut |_| {})?;
    drop(output);
    if !matches_digest(destination, file.size, &file.sha256, token)? {
        return Err(format!("Archivo de mod no coincide con SHA-256: {}", file.path));
    }
    Ok(())
}

const PIECE: u64 = 32 * 1024 * 1024;
const CONNECTIONS: usize = 12;

/// Download every archive missing from the cache at once, split into ranged
/// pieces shared by CONNECTIONS workers. Each archive is written to a private
/// file, checked against its size and SHA-256 and only then renamed to the
/// content-addressed cache name that download_one() accepts. Failures are not
/// fatal here: download_one() retries that archive with its resumable path.
/// Returns how many archives it completed.
fn parallel_fetch(
    archives: &[ArchiveSpec], cache: &Path, client: &reqwest::blocking::Client,
    token: &AtomicBool, progress: &mut impl FnMut(u64),
) -> Result<usize, String> {
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::Mutex;
    assert_no_links(cache)?;
    fs::create_dir_all(cache).map_err(|error| error.to_string())?;
    let mut ready = 0u64;
    let mut todo = Vec::new();
    for archive in archives {
        let hash = archive.sha256.to_ascii_lowercase();
        let path = cache.join(format!("{hash}.zip"));
        if matches_digest(&path, archive.size, &hash, token)? {
            ready += archive.size;
        } else if fs::symlink_metadata(&path).is_err() {
            todo.push(archive);
        }
    }
    progress(ready);
    if todo.is_empty() { return Ok(0); }
    ensure_free_space(cache, todo.iter().map(|archive| archive.size).sum())?;
    let work = cache.join(format!("mods-parallel-{}", std::process::id()));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).map_err(|error| error.to_string())?;
    let mut pieces = Vec::new();
    for (index, archive) in todo.iter().enumerate() {
        let file = File::create(work.join(index.to_string())).map_err(|error| error.to_string())?;
        file.set_len(archive.size).map_err(|error| error.to_string())?;
        let mut start = 0;
        while start < archive.size {
            let len = PIECE.min(archive.size - start);
            pieces.push((index, start, len));
            start += len;
        }
    }
    // Large archives first, so the slowest piece does not start last.
    pieces.sort_by_key(|&(index, start, _)| (std::cmp::Reverse(todo[index].size), index, start));
    let remaining: Vec<_> = todo.iter().map(|archive| AtomicUsize::new(
        archive.size.div_ceil(PIECE) as usize)).collect();
    let failed: Vec<_> = todo.iter().map(|_| std::sync::atomic::AtomicBool::new(false)).collect();
    let next = AtomicUsize::new(0);
    let fetched = AtomicU64::new(0);
    let completed = AtomicUsize::new(0);
    let fatal = Mutex::new(None::<String>);
    let fetch_piece = |index: usize, start: u64, len: u64| -> Result<(), String> {
        let archive = todo[index];
        let end = start + len - 1;
        let mut response = client.get(&archive.url)
            .header(reqwest::header::RANGE, format!("bytes={start}-{end}"))
            .header(reqwest::header::ACCEPT_ENCODING, "identity")
            .send().map_err(|error| error.to_string())?;
        let expected = format!("bytes {start}-{end}/{}", archive.size);
        let range = response.headers().get(reqwest::header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok()).unwrap_or("");
        if response.status() != reqwest::StatusCode::PARTIAL_CONTENT || range != expected
            || response.headers().contains_key(reqwest::header::CONTENT_ENCODING)
        {
            return Err(format!("Rango no admitido: {} {range}", response.status()));
        }
        let mut output = OpenOptions::new().write(true).open(work.join(index.to_string()))
            .map_err(|error| error.to_string())?;
        output.seek(SeekFrom::Start(start)).map_err(|error| error.to_string())?;
        let mut buffer = vec![0u8; 256 * 1024];
        let mut written = 0u64;
        loop {
            cancelled(token)?;
            let count = response.read(&mut buffer).map_err(|error| error.to_string())?;
            if count == 0 { break; }
            if written + count as u64 > len { return Err("El servidor envió bytes de más".into()); }
            output.write_all(&buffer[..count]).map_err(|error| error.to_string())?;
            written += count as u64;
        }
        if written != len { return Err("Respuesta cortada".into()); }
        Ok(())
    };
    let finish = |index: usize| -> Result<(), String> {
        let archive = todo[index];
        let hash = archive.sha256.to_ascii_lowercase();
        let piece_file = work.join(index.to_string());
        if !matches_digest(&piece_file, archive.size, &hash, token)? {
            return Err("SHA-256 distinto".into());
        }
        let destination = cache.join(format!("{hash}.zip"));
        if fs::symlink_metadata(&destination).is_ok() { return Ok(()); }
        fs::rename(&piece_file, &destination).map_err(|error| error.to_string())
    };
    std::thread::scope(|scope| {
        for _ in 0..CONNECTIONS {
            scope.spawn(|| loop {
                if token.load(Ordering::Relaxed) { return; }
                let Some(&(index, start, len)) = pieces.get(next.fetch_add(1, Ordering::Relaxed))
                else { return; };
                if failed[index].load(Ordering::Relaxed) { continue; }
                let mut result = Err(String::new());
                for _ in 0..3 {
                    result = fetch_piece(index, start, len);
                    if result.is_ok() || token.load(Ordering::Relaxed) { break; }
                }
                if let Err(error) = result {
                    failed[index].store(true, Ordering::Relaxed);
                    let mut fatal = fatal.lock().unwrap_or_else(|poison| poison.into_inner());
                    fatal.get_or_insert(format!("{}: {error}", todo[index].url));
                    continue;
                }
                fetched.fetch_add(len, Ordering::Relaxed);
                if remaining[index].fetch_sub(1, Ordering::AcqRel) == 1 {
                    match finish(index) {
                        Ok(()) => { completed.fetch_add(1, Ordering::Relaxed); }
                        Err(_) => failed[index].store(true, Ordering::Relaxed),
                    }
                }
            });
        }
        let mut last = u64::MAX;
        while next.load(Ordering::Relaxed) < pieces.len() + CONNECTIONS
            && !token.load(Ordering::Relaxed)
        {
            let done = ready + fetched.load(Ordering::Relaxed);
            if done != last { progress(done); last = done; }
            std::thread::sleep(Duration::from_millis(150));
        }
    });
    let _ = fs::remove_dir_all(&work);
    cancelled(token)?;
    progress(ready + fetched.load(Ordering::Relaxed));
    if let Some(error) = fatal.into_inner().unwrap_or_else(|poison| poison.into_inner()) {
        eprintln!("[mods] descarga en paralelo incompleta, se reintenta: {error}");
    }
    Ok(completed.load(Ordering::Relaxed))
}

fn stage_profile(
    profile: &Profile, destination: &Path, cache: &Path, token: &AtomicBool,
    progress: &mut impl FnMut(&'static str, &str, u64, u64),
) -> Result<(), String> {
    let client = reqwest::blocking::Client::builder().connect_timeout(Duration::from_secs(30))
        .timeout(HTTP_CHUNK_TIMEOUT).redirect(safe_archive_redirect())
        .build().map_err(|error| error.to_string())?;
    // The lock records each original Thunderstore URL. The same bytes are on
    // the host's GitHub prerelease, which is many times faster; SHA-256 and
    // size are checked exactly as before, and Thunderstore stays the fallback.
    let mirrored: Vec<_> = profile.active_packages().map(|package| ArchiveSpec {
        url: format!("{MIRROR}{}.zip", package.name), ..package.archive.clone()
    }).collect();
    let archives: Vec<_> = profile.active_packages().map(|package| package.archive.clone()).collect();
    let total = archives.iter().map(|archive| archive.size).sum();
    // One Thunderstore connection often runs at ~1.5 MB/s, so fetch every
    // package at once in ranged pieces. Whatever this misses (an error, a
    // server that ignores Range) goes through download_one() below.
    parallel_fetch(&mirrored, cache, &client, token, &mut |done| {
        progress("mods-downloading", "", done, total);
    })?;
    // Anything the mirror did not deliver: Thunderstore, in parallel too.
    parallel_fetch(&archives, cache, &client, token, &mut |done| {
        progress("mods-downloading", "", done, total);
    })?;
    let mut downloaded = 0;
    let mut paths = Vec::with_capacity(archives.len());
    for package in profile.active_packages() {
        let mut last_percent = None;
        let path = download_one(&package.archive, cache, &client, token, |bytes| {
            let done = downloaded + bytes;
            let percent = done * 100 / total;
            if last_percent != Some(percent) {
                last_percent = Some(percent);
                progress("mods-downloading", &package.name, done, total);
            }
        }).map_err(|error| if error == "cancelled" { error } else {
            format!("No se pudo descargar {}: {error}", package.name)
        })?;
        paths.push(path);
        downloaded += package.archive.size;
    }
    let _pins = pin_verified_archives(&paths, &archives, token)?;
    let expanded = profile.packages.iter().flat_map(|package| &package.files)
        .map(|file| file.size).sum();
    let stage = create_stage(destination)?;
    ensure_free_space(&stage.0, expanded)?;
    for (index, (package, path)) in profile.active_packages().zip(paths).enumerate() {
        cancelled(token)?;
        progress("mods-extracting", &package.name, index as u64, archives.len() as u64);
        let mut zip = zip::ZipArchive::new(File::open(path).map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())?;
        let entries = inspect_zip(&mut zip)?;
        for file in &package.files {
            let entry = entries.iter().find(|entry| entry.name == file.source
                && !entry.directory && entry.size == file.size)
                .ok_or_else(|| format!("Falta {} en {}", file.source, package.name))?;
            let mut source = zip.by_index(entry.index).map_err(|error| error.to_string())?;
            copy_locked_file(&mut source, &stage.0.join(&file.path), file, token)?;
        }
    }
    for (path, text) in &profile.defaults {
        let output = stage.0.join(path);
        let parent = output.parent().ok_or("Configuración sin carpeta")?;
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        fs::write(output, text).map_err(|error| error.to_string())?;
    }
    cancelled(token)?;
    publish_stage(&stage.0, destination)
}

pub(in crate::services) fn prepare(
    id: &str, executable_hash: &str, root: &Path, executable: &str, cache: &Path,
    token: &AtomicBool, progress: &mut impl FnMut(&'static str, &str, u64, u64),
) -> Result<Option<PathBuf>, String> {
    let Some(profile) = profile_for(id, executable_hash)? else { return Ok(None); };
    let runtime = root.join(normal_path(executable)?);
    let game_dir = runtime.parent().ok_or("El ejecutable no tiene carpeta")?;
    assert_no_links(game_dir)?;
    let proxy = game_dir.join(PROXY);
    let proxy_spec = profile.packages.iter().flat_map(|package| &package.files)
        .find(|file| file.path == PROXY).ok_or("Falta el cargador de mods")?;
    let validate_proxy = || -> Result<bool, String> {
        if matches_digest(&proxy, proxy_spec.size, &proxy_spec.sha256, token)? {
            return Ok(true);
        }
        if fs::symlink_metadata(&proxy).is_ok() {
            return Err("Ya existe un winhttp.dll distinto junto al juego. Se conservó ese archivo.".into());
        }
        Ok(false)
    };
    validate_proxy()?;
    let identity = profile_identity();
    // Keep Unity's paths short on Windows, including under custom game locations.
    let destination = root.join(".coco").join("managed-mods").join(&identity[..24]);
    assert_no_links(&destination)?;
    if !destination.is_dir() {
        stage_profile(profile, &destination, cache, token, progress)?;
    }
    for file in profile.packages.iter().flat_map(|package| &package.files) {
        if !file.path.starts_with("BepInEx/config/") && !matches_digest(
            &destination.join(&file.path), file.size, &file.sha256, token,
        )? {
            return Err(format!("Archivo de mods incompleto: {}. Perfil: {}", file.path, destination.display()));
        }
    }
    if !validate_proxy()? {
        let name = runtime.file_name().and_then(|value| value.to_str()).ok_or("Ejecutable inválido")?;
        if super::super::standalone::process_may_be_running(name) {
            return Err("Cierra Lethal Company para terminar de instalar los mods".into());
        }
        cancelled(token)?;
        let stage = create_stage(&proxy)?;
        let staged_proxy = stage.0.join(PROXY);
        let mut input = File::open(destination.join(PROXY)).map_err(|error| error.to_string())?;
        copy_locked_file(&mut input, &staged_proxy, proxy_spec, token)?;
        publish_stage(&staged_proxy, &proxy)?;
    }
    progress("mods-ready", "", 1, 1);
    Ok(Some(destination.join(PRELOADER)))
}

pub(in crate::services) fn applies(id: &str) -> bool { id == GAME }

pub(in crate::services) fn clear_downloads(id: &str, cache: &Path) {
    if !applies(id) || assert_no_links(cache).is_err() { return; }
    if let Ok(profile) = profile() {
        for package in profile.active_packages() {
            let path = cache.join(format!("{}.zip", package.archive.sha256));
            if assert_no_links(&path).is_ok() { let _ = fs::remove_file(path); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lethal_company_profile_pins_all_dependencies_and_the_catalog_executable() {
        let profile = profile().unwrap();
        let manifest = super::super::read_manifest(GAME).unwrap();
        assert!(install_profile(&manifest).unwrap().is_some());
        assert!(profile_for(GAME, "other executable").is_err());
        assert!(profile_for("other-game", "").unwrap().is_none());

        let raw: serde_json::Value = serde_json::from_str(LOCK).unwrap();
        let packages = raw["packages"].as_array().unwrap();
        for package in packages {
            for dependency in package["deps"].as_array().unwrap() {
                let (name, version) = dependency.as_str().unwrap().rsplit_once('-').unwrap();
                let actual = profile.packages.iter().find_map(|item| {
                    let (item_name, item_version) = item.name.rsplit_once('-')?;
                    (item_name == name).then_some(item_version)
                }).unwrap_or_else(|| panic!("Missing dependency {name}"));
                assert!(super::super::version_parts(actual).unwrap() >=
                    super::super::version_parts(version).unwrap(), "Outdated dependency {name}");
            }
        }
    }

    #[test]
    fn the_profile_folder_is_the_one_coco_0_6_61_installed_on_any_checkout() {
        assert!(profile_identity().starts_with("9ffcd019ec4982cdfff815d4"));
    }

    /// Serves `files` by path with exact byte ranges. The first request for
    /// "/flaky" is cut short, so the worker has to retry that piece.
    fn range_server(files: Vec<(&'static str, Vec<u8>)>) -> String {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let flaky = std::sync::Arc::new(AtomicBool::new(true));
        std::thread::spawn(move || for stream in listener.incoming().flatten() {
            let files = files.clone();
            let flaky = flaky.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                let mut range = None;
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) <= 2 { break; }
                    if let Some(value) = header.to_ascii_lowercase().strip_prefix("range: bytes=") {
                        let (a, b) = value.trim().split_once('-').unwrap();
                        range = Some((a.parse::<usize>().unwrap(), b.parse::<usize>().unwrap()));
                    }
                }
                let mut stream = stream;
                let Some((_, body)) = files.iter().find(|(name, _)| *name == path) else {
                    let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                    return;
                };
                let (a, b) = range.unwrap();
                let slice = &body[a..=b];
                let head = format!("HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {a}-{b}/{}\r\nConnection: close\r\n\r\n", slice.len(), body.len());
                let _ = stream.write_all(head.as_bytes());
                let cut = path == "/flaky" && flaky.swap(false, std::sync::atomic::Ordering::SeqCst);
                let _ = stream.write_all(if cut { &slice[..slice.len() / 2] } else { slice });
            });
        });
        format!("http://127.0.0.1:{port}")
    }

    #[test]
    fn parallel_fetch_caches_only_archives_whose_bytes_match() {
        let root = std::env::temp_dir().join(format!("coco-mods-parallel-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let big: Vec<u8> = (0..(PIECE as usize * 2 + 12_345)).map(|n| (n % 251) as u8).collect();
        let small = b"small archive".to_vec();
        let base = range_server(vec![("/flaky", big.clone()), ("/small", small.clone()),
            ("/wrong", b"not what the lock says".to_vec())]);
        let spec = |path: &str, bytes: &[u8]| ArchiveSpec {
            url: format!("{base}{path}"), size: bytes.len() as u64,
            sha256: format!("{:x}", Sha256::digest(bytes)),
        };
        let wrong = ArchiveSpec { sha256: "0".repeat(64), ..spec("/wrong", b"not what the lock says") };
        let missing = spec("/missing", b"gone");
        let archives = [spec("/flaky", &big), spec("/small", &small), wrong.clone(), missing];
        let client = reqwest::blocking::Client::builder().build().unwrap();
        let token = AtomicBool::new(false);
        let mut last = 0;
        let done = parallel_fetch(&archives, &root, &client, &token, &mut |bytes| last = bytes).unwrap();
        assert_eq!(done, 2);
        assert!(last >= (big.len() + small.len()) as u64);
        assert_eq!(fs::read(root.join(format!("{}.zip", archives[0].sha256))).unwrap(), big);
        assert_eq!(fs::read(root.join(format!("{}.zip", archives[1].sha256))).unwrap(), small);
        assert!(!root.join(format!("{}.zip", wrong.sha256)).exists());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 2, "no work files left behind");
        // A second run finds both in the cache and downloads nothing.
        assert_eq!(parallel_fetch(&archives[..2], &root, &client, &token, &mut |_| {}).unwrap(), 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[ignore = "downloads the real mirror (1 GB) from GitHub"]
    fn the_github_mirror_serves_every_locked_archive() {
        let profile = profile().unwrap();
        let cache = PathBuf::from(std::env::var_os("COCO2_MODS_MIRROR_CACHE").unwrap());
        let mirrored: Vec<_> = profile.active_packages().map(|package| ArchiveSpec {
            url: format!("{MIRROR}{}.zip", package.name), ..package.archive.clone()
        }).collect();
        let client = reqwest::blocking::Client::builder().redirect(safe_archive_redirect())
            .timeout(HTTP_CHUNK_TIMEOUT).build().unwrap();
        let started = std::time::Instant::now();
        let done = parallel_fetch(&mirrored, &cache, &client, &AtomicBool::new(false), &mut |_| {}).unwrap();
        println!("{done} archives in {:.1}s", started.elapsed().as_secs_f64());
        assert_eq!(done, mirrored.len());
    }

    #[test]
    #[ignore = "uses the explicitly supplied pristine copy of the published v81 installation"]
    fn host_existing_install_gets_the_same_profile_and_keeps_existing_files() {
        let root = PathBuf::from(std::env::var_os("COCO2_HOST_MOD_MIGRATION_TARGET").unwrap());
        let cache = PathBuf::from(std::env::var_os("COCO2_HOST_SMOKE_CACHE").unwrap());
        let manifest = super::super::read_manifest(GAME).unwrap();
        let receipt = root.join(".coco/standalone-install-v1.json");
        let before = fs::read(&receipt).unwrap();
        let token = AtomicBool::new(false);
        // Online-Fix legitimately stores this PC's state after first launch.
        // Compare established files byte for byte, including that local state.
        let expected: Vec<_> = manifest.required_files.iter().map(|file| {
            let path = root.join(&file.path);
            let fingerprint = super::super::file_digest(&path, &token).unwrap();
            (path, fingerprint)
        }).collect();
        let profile = install_profile(&manifest).unwrap().unwrap();
        let executable = root.join(&profile.game_executable);
        let proxy = executable.with_file_name(PROXY);
        assert!(!proxy.exists());
        let run = || prepare(
            GAME, &profile.game_executable_sha256, &root, &profile.game_executable,
            &cache, &token, &mut |_, _, _, _| {},
        ).unwrap().unwrap();
        let preloader = run();
        assert!(preloader.is_file() && proxy.is_file());
        assert_eq!(run(), preloader);
        assert_eq!(before, fs::read(receipt).unwrap());
        for (path, fingerprint) in expected {
            assert_eq!(super::super::file_digest(&path, &token).unwrap(), fingerprint);
        }
        println!("Managed preloader: {}", preloader.display());
    }
}
