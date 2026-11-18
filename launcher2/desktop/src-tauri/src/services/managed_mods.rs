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

fn stage_profile(
    profile: &Profile, destination: &Path, cache: &Path, token: &AtomicBool,
    progress: &mut impl FnMut(&'static str, &str, u64, u64),
) -> Result<(), String> {
    let client = reqwest::blocking::Client::builder().connect_timeout(Duration::from_secs(30))
        .timeout(HTTP_CHUNK_TIMEOUT).redirect(safe_archive_redirect())
        .build().map_err(|error| error.to_string())?;
    let archives: Vec<_> = profile.active_packages().map(|package| package.archive.clone()).collect();
    let total = archives.iter().map(|archive| archive.size).sum();
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
    let identity = format!("{:x}", Sha256::digest(LOCK.as_bytes()));
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
