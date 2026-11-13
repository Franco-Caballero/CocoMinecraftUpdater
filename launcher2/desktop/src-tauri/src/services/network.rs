//! Windows ZeroTier status + guarded Coco network join.
//! Never installs/starts services, elevates, reads tokens or authorizes controller
//! members. Join changes ONLY the fixed Coco network, never any existing network.
//! No .bat, PowerShell, cmd.exe, SSH or unverified installer is executed.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Read;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const NETWORK_ID: &str = "58997fc5f3c0c001";
const HOST_IP: Ipv4Addr = Ipv4Addr::new(10, 77, 37, 1);
const SUBNET: &str = "10.77.37.0/24";
const CLI_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CLI_OUTPUT: u64 = 64 * 1024;
// Pinned in the legacy engine manifest. Do NOT use this to infer Authenticode
// trust: download + signer verification + UAC must be implemented separately.
const INSTALLER_VERSION: &str = "1.16.2";
const INSTALLER_URL: &str =
    "https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi";
const INSTALLER_SHA256: &str =
    "42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670";
static JOIN_MUTEX: Mutex<()> = Mutex::new(());

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct NetworkSetupPlan {
    pub provider: &'static str,
    pub network_id: &'static str,
    pub action: &'static str,
    pub can_join: bool,
    pub automatic_install_supported: bool,
    pub installer_version: &'static str,
    pub installer_url: &'static str,
    pub installer_sha256: &'static str,
    pub installer_signature_required: bool,
    pub install_requires_uac: bool,
    pub status: NetworkStatus,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct NetworkJoinOutcome {
    pub network_id: &'static str,
    pub action: &'static str,
    pub join_requested: bool,
    pub authorization_confirmed: bool,
    pub reason: &'static str,
    pub status: NetworkStatus,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct NetworkStatus {
    pub provider: &'static str,
    pub network_id: &'static str,
    pub host: String,
    pub subnet: &'static str,
    pub state: &'static str,
    pub service_installed: Option<bool>,
    pub service_running: Option<bool>,
    pub cli_installed: bool,
    pub cli_queried: bool,
    pub network_joined: bool,
    pub authorized: bool,
    pub assigned_ipv4: Option<String>,
    pub role: Option<&'static str>,
    pub reason: &'static str,
    pub setup_supported: bool,
}

impl NetworkStatus {
    fn new() -> Self {
        Self {
            provider: "zerotier",
            network_id: NETWORK_ID,
            host: HOST_IP.to_string(),
            subnet: SUBNET,
            state: "unknown",
            service_installed: None,
            service_running: None,
            cli_installed: false,
            cli_queried: false,
            network_joined: false,
            authorized: false,
            assigned_ipv4: None,
            role: None,
            reason: "not-checked",
            setup_supported: false,
        }
    }

    fn finish(&mut self, state: &'static str, reason: &'static str) {
        self.state = state;
        self.reason = reason;
    }
}

#[derive(Deserialize)]
struct SessionConfig {
    discovery: Discovery,
}

#[derive(Deserialize)]
struct Discovery {
    host: String,
    port: u16,
}

fn trusted_config() -> Result<(), String> {
    let config: SessionConfig =
        serde_json::from_str(include_str!("../../resources/session-config.json"))
            .map_err(|_| "Invalid embedded session config")?;
    if config.discovery.host != HOST_IP.to_string() || config.discovery.port != 25564 {
        return Err("Embedded ZeroTier host or session port differs from trusted Coco configuration".into());
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ServiceSnapshot {
    installed: Option<bool>,
    running: Option<bool>,
}

#[cfg(windows)]
fn service_snapshot() -> ServiceSnapshot {
    use std::iter::once;
    use std::os::windows::ffi::OsStrExt;
    use std::ffi::OsStr;

    type Handle = isize;
    #[repr(C)]
    struct ServiceStatus {
        service_type: u32,
        current_state: u32,
        controls_accepted: u32,
        win32_exit_code: u32,
        service_specific_exit_code: u32,
        check_point: u32,
        wait_hint: u32,
    }
    #[link(name = "advapi32")]
    extern "system" {
        fn OpenSCManagerW(machine: *const u16, database: *const u16, access: u32) -> Handle;
        fn OpenServiceW(manager: Handle, service: *const u16, access: u32) -> Handle;
        fn QueryServiceStatus(service: Handle, status: *mut ServiceStatus) -> i32;
        fn CloseServiceHandle(handle: Handle) -> i32;
    }
    let mut snapshot = ServiceSnapshot { installed: None, running: None };
    // SC_MANAGER_CONNECT / SERVICE_QUERY_STATUS: no modification privileges.
    let manager = unsafe { OpenSCManagerW(std::ptr::null(), std::ptr::null(), 0x0001) };
    if manager == 0 { return snapshot; }
    let name: Vec<u16> = OsStr::new("ZeroTierOneService")
        .encode_wide().chain(once(0)).collect();
    let service = unsafe { OpenServiceW(manager, name.as_ptr(), 0x0004) };
    if service == 0 {
        let error = std::io::Error::last_os_error().raw_os_error();
        // ERROR_SERVICE_DOES_NOT_EXIST. Access denied remains unknown.
        if error == Some(1060) {
            snapshot.installed = Some(false);
            snapshot.running = Some(false);
        }
    } else {
        snapshot.installed = Some(true);
        let mut current = ServiceStatus {
            service_type: 0, current_state: 0, controls_accepted: 0,
            win32_exit_code: 0, service_specific_exit_code: 0,
            check_point: 0, wait_hint: 0,
        };
        if unsafe { QueryServiceStatus(service, &mut current) } != 0 {
            snapshot.running = Some(current.current_state == 4); // SERVICE_RUNNING
        }
        unsafe { CloseServiceHandle(service) };
    }
    unsafe { CloseServiceHandle(manager) };
    snapshot
}

#[cfg(not(windows))]
fn service_snapshot() -> ServiceSnapshot {
    ServiceSnapshot { installed: None, running: None }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CliInstallation {
    installed: bool,
    command: Option<CliCommand>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CliCommand {
    path: PathBuf,
    query_flag: bool,
}

/// Windows Program Files only. Never trust PATH, arbitrary environment overrides,
/// writable user directories, or a .bat/.cmd wrapper invoking cmd.exe.
#[cfg(windows)]
fn discover_cli() -> CliInstallation {
    let mut installation = CliInstallation { installed: false, command: None };
    for base in [r"C:\Program Files\ZeroTier\One", r"C:\Program Files (x86)\ZeroTier\One"] {
        let root = Path::new(base);
        let bat = root.join("zerotier-cli.bat");
        let legacy = root.join("zerotier-one_x64.exe");
        let native = root.join("zerotier-cli.exe");
        if regular_unredirected(&bat) || regular_unredirected(&native)
            || regular_unredirected(&legacy) {
            installation.installed = true;
        }
        if regular_unredirected(&native) {
            installation.command = Some(CliCommand { path: native, query_flag: false });
            break;
        }
        // ZeroTier normally ships a BAT that calls zerotier-one_x64.exe -q %*.
        // Never invoke the BAT. Inspect only a small official-pattern wrapper,
        // then call the existing native binary directly in query mode.
        if regular_unredirected(&bat) && regular_unredirected(&legacy)
            && bat_is_query_wrapper(&bat)
        {
            installation.command = Some(CliCommand { path: legacy, query_flag: true });
            break;
        }
    }
    installation
}

#[cfg(not(windows))]
fn discover_cli() -> CliInstallation {
    CliInstallation { installed: false, command: None }
}

fn regular_unredirected(path: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    for component in path.ancestors() {
        match fs::symlink_metadata(component) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return false;
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return false;
                    }
                }
                if component == path {
                    if !metadata.is_file() {
                        return false;
                    }
                } else if !metadata.is_dir() {
                    return false;
                }
            }
            Err(_) => return false,
        }
    }
    true
}

fn bat_is_query_wrapper(path: &Path) -> bool {
    if fs::metadata(path).map(|meta| meta.len() > 8192).unwrap_or(true) {
        return false;
    }
    let Ok(wrapper) = fs::read_to_string(path) else { return false };
    let wrapper = wrapper.to_ascii_lowercase();
    wrapper.contains("zerotier-one_x64.exe")
        && wrapper.contains("-q")
        && wrapper.contains("%*")
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum CliError {
    Unavailable,
    TimedOut,
    TooLarge,
    Failed,
    Malformed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CliOperation {
    ListNetworks,
    JoinCoco,
}

/// The CLI command is a fixed ZeroTier executable under a standard,
/// system-managed Program Files directory. Never execute a caller-supplied
/// path, PATH lookup, .bat, helper downloaded into AppData or a shell.
#[cfg(windows)]
fn trusted_cli_command(cli: &CliCommand) -> bool {
    let roots = [r"C:\Program Files\ZeroTier\One", r"C:\Program Files (x86)\ZeroTier\One"];
    roots.iter().any(|root| {
        ((!cli.query_flag && cli.path == Path::new(root).join("zerotier-cli.exe"))
            || (cli.query_flag && cli.path == Path::new(root).join("zerotier-one_x64.exe")
                && bat_is_query_wrapper(&Path::new(root).join("zerotier-cli.bat"))))
            && regular_unredirected(&cli.path)
    })
}

#[cfg(not(windows))]
fn trusted_cli_command(_cli: &CliCommand) -> bool {
    false
}

fn run_cli_native(cli: &CliCommand, operation: CliOperation) -> Result<Vec<u8>, CliError> {
    if !trusted_cli_command(cli) {
        return Err(CliError::Unavailable);
    }
    let mut command = Command::new(&cli.path);
    if cli.query_flag { command.arg("-q"); }
    match operation {
        CliOperation::ListNetworks => { command.args(["-j", "listnetworks"]); }
        CliOperation::JoinCoco => { command.args(["join", NETWORK_ID]); }
    };
    command.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    let mut child = command.spawn().map_err(|_| CliError::Unavailable)?;
    let stdout = child.stdout.take().ok_or(CliError::Unavailable)?;
    let stderr = child.stderr.take().ok_or(CliError::Unavailable)?;
    // Drain both pipes concurrently to avoid child deadlocks. Never print CLI
    // stdout/stderr (they can include local node metadata or error details).
    let (out_tx, out_rx) = mpsc::channel();
    let (err_tx, err_rx) = mpsc::channel();
    thread::spawn(move || { let _ = out_tx.send(bounded_read(stdout)); });
    thread::spawn(move || { let _ = err_tx.send(bounded_read(stderr)); });
    let start = Instant::now();
    let finished = loop {
        match child.try_wait() {
            Ok(Some(exit)) => break exit.success(),
            Ok(None) => {}
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CliError::Failed);
            }
        }
        if start.elapsed() >= CLI_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(CliError::TimedOut);
        }
        thread::sleep(Duration::from_millis(35));
    };
    // A buggy CLI (or an inherited pipe handle) must never keep the UI waiting
    // forever after the parent process exits.
    let stdout = out_rx.recv_timeout(Duration::from_millis(250))
        .map_err(|_| CliError::TimedOut)??;
    let stderr = err_rx.recv_timeout(Duration::from_millis(250))
        .map_err(|_| CliError::TimedOut)??;
    if stdout.len() as u64 > MAX_CLI_OUTPUT || stderr.len() as u64 > MAX_CLI_OUTPUT {
        return Err(CliError::TooLarge);
    }
    if !finished {
        return Err(CliError::Failed);
    }
    Ok(stdout)
}

fn query_cli_native(cli: &CliCommand) -> Result<Vec<u8>, CliError> {
    run_cli_native(cli, CliOperation::ListNetworks)
}

fn bounded_read(input: impl Read) -> Result<Vec<u8>, CliError> {
    let mut output = Vec::new();
    input.take(MAX_CLI_OUTPUT + 1)
        .read_to_end(&mut output)
        .map_err(|_| CliError::Failed)?;
    if output.len() as u64 > MAX_CLI_OUTPUT {
        return Err(CliError::TooLarge);
    }
    Ok(output)
}

#[derive(Debug, Deserialize)]
struct CliNetwork {
    id: Option<String>,
    nwid: Option<String>,
    status: Option<String>,
    #[serde(default, rename = "assignedAddresses")]
    assigned_addresses: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
enum NetworkObservation {
    NotJoined,
    Pending,
    Ready { address: String, role: &'static str },
}

fn network_observation(json: &[u8]) -> Result<NetworkObservation, CliError> {
    if json.len() > MAX_CLI_OUTPUT as usize {
        return Err(CliError::TooLarge);
    }
    let raw = std::str::from_utf8(json).map_err(|_| CliError::Malformed)?;
    // Official BAT wrappers sometimes print a BOM or notices before the JSON.
    // No CLI text is logged or returned. Refuse excessive or ambiguous prefixes.
    let stripped = raw.trim_start_matches(['\u{feff}', ' ', '\r', '\n', '\t']);
    let start = stripped.find(|ch| ch == '[' || ch == '{').ok_or(CliError::Malformed)?;
    if start > 1024 {
        return Err(CliError::Malformed);
    }
    let value: serde_json::Value = serde_json::from_str(&stripped[start..])
        .map_err(|_| CliError::Malformed)?;
    let rows: Vec<CliNetwork> = if value.is_array() {
        serde_json::from_value(value).map_err(|_| CliError::Malformed)?
    } else if value.is_object() {
        vec![serde_json::from_value(value).map_err(|_| CliError::Malformed)?]
    } else {
        return Err(CliError::Malformed);
    };
    if rows.len() > 4096 {
        return Err(CliError::TooLarge);
    }
    let matches: Vec<_> = rows.iter().filter(|network| {
        network.id.as_deref().map(|id| id.eq_ignore_ascii_case(NETWORK_ID)).unwrap_or(false)
            || network.nwid.as_deref().map(|id| id.eq_ignore_ascii_case(NETWORK_ID)).unwrap_or(false)
    }).collect();
    if matches.is_empty() {
        return Ok(NetworkObservation::NotJoined);
    }
    if matches.len() != 1 {
        return Err(CliError::Malformed);
    }
    let network = matches[0];
    if network.status.as_deref() != Some("OK") {
        return Ok(NetworkObservation::Pending);
    }
    let mut selected: Option<(String, &'static str)> = None;
    for candidate in &network.assigned_addresses {
        if let Some(address) = coco_address(candidate) {
            if let Some(previous) = &selected {
                // Two different Coco addresses (especially host and client)
                // cannot establish one unambiguous local role.
                if *previous != address {
                    return Err(CliError::Malformed);
                }
            } else {
                selected = Some(address);
            }
        }
    }
    match selected {
        Some((address, role)) => Ok(NetworkObservation::Ready { address, role }),
        None => Ok(NetworkObservation::Pending),
    }
}

fn coco_address(value: &str) -> Option<(String, &'static str)> {
    let addr = match value.split_once('/') {
        Some((addr, prefix)) => {
            if prefix != "24" { return None; }
            addr
        }
        None => value,
    };
    let parsed = addr.parse::<Ipv4Addr>().ok()?;
    let octets = parsed.octets();
    if octets[..3] != [10, 77, 37] {
        return None;
    }
    let role = match octets[3] {
        1 => "host",
        2..=254 => "client",
        _ => return None,
    };
    Some((parsed.to_string(), role))
}

fn status_from_observation(
    service: ServiceSnapshot,
    cli: CliInstallation,
    parsed: Option<Result<NetworkObservation, CliError>>,
) -> NetworkStatus {
    let mut result = NetworkStatus::new();
    result.service_installed = service.installed;
    result.service_running = service.running;
    result.cli_installed = cli.installed;
    if service.installed == Some(false) && !cli.installed {
        result.finish("not-installed", "zerotier-not-found");
        return result;
    }
    if service.running == Some(false) {
        result.finish("service-stopped", "zerotier-service-not-running");
        return result;
    }
    if !cli.installed {
        result.finish("cli-unavailable", "native-zerotier-cli-not-found");
        return result;
    }
    if cli.command.is_none() {
        result.finish("cli-unavailable", "zerotier-batch-only-no-shell-execution");
        return result;
    }
    let Some(response) = parsed else {
        result.finish("unknown", "read-only-query-not-run");
        return result;
    };
    result.cli_queried = true;
    match response {
        Ok(NetworkObservation::NotJoined) => result.finish("network-not-joined", "coco-network-not-present"),
        Ok(NetworkObservation::Pending) => {
            result.network_joined = true;
            result.finish("authorization-pending", "network-not-ready-or-no-coco-ip");
        }
        Ok(NetworkObservation::Ready { address, role }) => {
            result.network_joined = true;
            result.authorized = true;
            result.assigned_ipv4 = Some(address);
            result.role = Some(role);
            result.finish("ready", "network-authorized-with-coco-ip");
        }
        Err(CliError::TimedOut) => result.finish("unknown", "zerotier-cli-timeout"),
        Err(CliError::TooLarge) => result.finish("unknown", "zerotier-cli-output-limit"),
        Err(_) => result.finish("unknown", "zerotier-cli-query-failed"),
    }
    result
}

fn inspect_network() -> NetworkStatus {
    let service = service_snapshot();
    let cli = discover_cli();
    // Check service first; never run a tool if its service is known stopped.
    let observation = if service.running == Some(false) || cli.command.is_none() {
        None
    } else {
        cli.command.as_ref().map(|command| {
            query_cli_native(command).and_then(|bytes| network_observation(&bytes))
        })
    };
    status_from_observation(service, cli, observation)
}

fn setup_plan_from_status(status: NetworkStatus) -> NetworkSetupPlan {
    let action = if !cfg!(windows) {
        "windows-required"
    } else {
        match status.state {
            "ready" => "connected",
            "authorization-pending" => "wait-for-controller-authorization",
            "network-not-joined" if status.service_running == Some(true)
                && status.service_installed == Some(true)
                && status.cli_installed && status.cli_queried => "join-coco-network",
            "not-installed" => "install-official-zerotier-with-user-approval",
            "service-stopped" => "start-zerotier-service-with-windows-approval",
            "cli-unavailable" => "repair-official-zerotier-installation",
            _ => "inspect-zerotier-installation",
        }
    };
    NetworkSetupPlan {
        provider: "zerotier",
        network_id: NETWORK_ID,
        action,
        can_join: action == "join-coco-network",
        automatic_install_supported: false,
        installer_version: INSTALLER_VERSION,
        installer_url: INSTALLER_URL,
        installer_sha256: INSTALLER_SHA256,
        installer_signature_required: true,
        install_requires_uac: true,
        status,
    }
}

fn join_outcome(
    status: NetworkStatus,
    action: &'static str,
    reason: &'static str,
    requested: bool,
) -> NetworkJoinOutcome {
    NetworkJoinOutcome {
        network_id: NETWORK_ID,
        action,
        join_requested: requested,
        authorization_confirmed: status.authorized,
        reason,
        status,
    }
}

/// Pure decision gate: no CLI join is permitted without an explicit, positive
/// SCM Running response AND an exhaustive, successful listnetworks query.
fn join_preflight(status: NetworkStatus) -> Result<NetworkStatus, NetworkJoinOutcome> {
    let plan = setup_plan_from_status(status.clone());
    if plan.can_join {
        return Ok(status);
    }
    let action = match status.state {
        "ready" => "already-connected",
        "authorization-pending" => "already-joined-awaiting-authorization",
        _ => "blocked",
    };
    let reason = match plan.action {
        "windows-required" => "windows-only",
        "connected" => "coco-network-ready",
        "wait-for-controller-authorization" => "network-joined-authorization-pending",
        "install-official-zerotier-with-user-approval" => "official-installation-required",
        "start-zerotier-service-with-windows-approval" => "service-must-be-running",
        "repair-official-zerotier-installation" => "native-cli-unavailable",
        _ => "read-only-preflight-not-confirmed",
    };
    Err(join_outcome(status, action, reason, false))
}

fn outcome_after_join(status: NetworkStatus) -> NetworkJoinOutcome {
    match status.state {
        "ready" => join_outcome(status, "joined-and-authorized", "network-ready", true),
        "authorization-pending" => join_outcome(
            status, "joined-awaiting-authorization", "controller-must-authorize-this-node", true),
        "network-not-joined" => join_outcome(
            status, "join-unconfirmed", "join-returned-but-membership-not-observed", true),
        _ => join_outcome(status, "join-unconfirmed", "post-join-status-not-verifiable", true),
    }
}

fn join_coco_native() -> NetworkJoinOutcome {
    // The mutex is intentionally process-local and blocks concurrent joins
    // from multiple windows. Other ZeroTier networks remain untouched.
    let _guard = match JOIN_MUTEX.lock() {
        Ok(guard) => guard,
        Err(_) => return join_outcome(
            inspect_network(), "blocked", "network-join-mutex-unavailable", false),
    };
    let status = match join_preflight(inspect_network()) {
        Ok(status) => status,
        Err(outcome) => return outcome,
    };
    let cli = discover_cli();
    let Some(command) = cli.command.as_ref().filter(|cli| trusted_cli_command(cli)) else {
        return join_outcome(status, "blocked", "trusted-native-cli-not-found", false);
    };
    // The ONLY mutating call in this module: e.g.
    // C:\Program Files\ZeroTier\One\zerotier-cli.exe join 58997fc5f3c0c001
    // or verified native zerotier-one_x64.exe -q join <same fixed ID>.
    // Never call join for an unknown/broken status or an already-joined network.
    let mutating_result = run_cli_native(command, CliOperation::JoinCoco);
    // A process may timeout AFTER the daemon accepted the request. Once a
    // mutating command is attempted its effect is unknown until read back.
    let mut after = inspect_network();
    // Native ZeroTier may acknowledge a join before its service lists the
    // membership. Poll a *bounded* number of read-only snapshots, never retry
    // the mutating join command. Do not claim success from CLI exit status.
    for _ in 0..2 {
        if after.network_joined || after.state != "network-not-joined" { break; }
        thread::sleep(Duration::from_millis(250));
        after = inspect_network();
    }
    if mutating_result.is_err() && !after.network_joined {
        return join_outcome(after, "join-unconfirmed", "join-command-error-or-timeout", true);
    }
    outcome_after_join(after)
}

/// Read-only. Never joins/leaves networks, elevates, reads ZeroTier secrets, or
/// claims the game/session is running simply because ZeroTier is online.
#[tauri::command]
pub async fn get_network_status() -> Result<NetworkStatus, String> {
    trusted_config()?;
    tauri::async_runtime::spawn_blocking(inspect_network)
        .await.map_err(|_| "ZeroTier status inspection interrupted".into())
}

/// Read-only typed setup plan. Installed Windows ZeroTier can be joined directly
/// only when a trusted native CLI and a running service are confirmed.
/// Installer URL + SHA come from the pinned legacy manifest, but no download,
/// Authenticode verification, MSI run or UAC attempt is performed here.
#[tauri::command]
pub async fn prepare_network_setup() -> Result<NetworkSetupPlan, String> {
    trusted_config()?;
    tauri::async_runtime::spawn_blocking(|| setup_plan_from_status(inspect_network()))
        .await.map_err(|_| "ZeroTier setup preflight interrupted".into())
}

/// Joins only the fixed Coco network; requires a running ZeroTier service and
/// an authoritative read-only snapshot proving the network is not already
/// joined. The host controller must still authorize the user separately.
#[tauri::command]
pub async fn join_coco_network() -> Result<NetworkJoinOutcome, String> {
    trusted_config()?;
    tauri::async_runtime::spawn_blocking(join_coco_native)
        .await.map_err(|_| "ZeroTier join operation interrupted".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(value: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    fn network(status: &str, addresses: &[&str]) -> serde_json::Value {
        serde_json::json!({
            "id": NETWORK_ID, "status": status,
            "assignedAddresses": addresses
        })
    }

    fn mock_cli() -> CliInstallation {
        CliInstallation {
            installed: true,
            command: Some(CliCommand { path: PathBuf::from("C:\\mock.exe"), query_flag: false }),
        }
    }

    fn running() -> ServiceSnapshot {
        ServiceSnapshot { installed: Some(true), running: Some(true) }
    }

    #[test]
    fn trusted_embedded_host_and_network_id() {
        trusted_config().unwrap();
        assert_eq!(NETWORK_ID, "58997fc5f3c0c001");
        assert_eq!(HOST_IP.to_string(), "10.77.37.1");
    }

    #[test]
    fn native_listnetworks_parses_exact_network_and_client_address() {
        let input = fixture(serde_json::json!([
            {"id":"154a350c866b8062","status":"OK","assignedAddresses":["10.77.37.33/24"]},
            network("OK", &["10.77.37.2/24","fe80::1234/64"])
        ]));
        let observation = network_observation(&input).unwrap();
        assert_eq!(observation, NetworkObservation::Ready {
            address: "10.77.37.2".to_owned(), role: "client"
        });
        let result = status_from_observation(running(), mock_cli(), Some(Ok(observation)));
        assert_eq!(result.state, "ready");
        assert_eq!(result.assigned_ipv4.as_deref(), Some("10.77.37.2"));
        assert!(result.authorized && result.network_joined);
        assert!(!result.setup_supported);
        assert!(!serde_json::to_string(&result).unwrap().contains("fe80::1234"));
    }

    #[test]
    fn host_and_untrusted_addresses_are_distinguished() {
        assert_eq!(coco_address("10.77.37.1/24"), Some(("10.77.37.1".into(), "host")));
        for value in [
            "10.77.37.0/24", "10.77.37.255/24", "10.77.38.3/24",
            "10.77.37.4/16", "127.0.0.1/24", "10.77.37.3/24 extra",
            "10.77.37.999/24", "fe80::1/64",
        ] {
            assert_eq!(coco_address(value), None, "{value}");
        }
        assert_eq!(
            network_observation(&fixture(serde_json::json!([network("OK", &["10.77.38.3/24"])]))).unwrap(),
            NetworkObservation::Pending
        );
    }

    #[test]
    fn offline_or_unapproved_is_not_ready() {
        let joined = fixture(serde_json::json!([network("ACCESS_DENIED", &["10.77.37.10/24"])]));
        assert_eq!(network_observation(&joined).unwrap(), NetworkObservation::Pending);
        let state = status_from_observation(running(), mock_cli(), Some(Ok(NetworkObservation::Pending)));
        assert!(!state.authorized);
        assert_eq!(state.state, "authorization-pending");
        let absent = fixture(serde_json::json!([{"nwid":"ffffffffffffffff","status":"OK","assignedAddresses":["10.77.37.2/24"]}]));
        assert_eq!(network_observation(&absent).unwrap(), NetworkObservation::NotJoined);
        assert_eq!(status_from_observation(running(), mock_cli(), Some(Ok(NetworkObservation::NotJoined))).state, "network-not-joined");
    }

    #[test]
    fn malformed_duplicate_or_oversized_output_fails_closed() {
        let duplicate = fixture(serde_json::json!([
            network("OK", &["10.77.37.3/24"]),
            {"nwid": NETWORK_ID, "status":"OK", "assignedAddresses":["10.77.37.1/24"]}
        ]));
        assert_eq!(network_observation(&duplicate), Err(CliError::Malformed));
        let conflicting_ips = fixture(serde_json::json!([
            network("OK", &["10.77.37.1/24", "10.77.37.4/24"])
        ]));
        assert_eq!(network_observation(&conflicting_ips), Err(CliError::Malformed));
        assert_eq!(network_observation(b"{not-json"), Err(CliError::Malformed));
        assert_eq!(network_observation(&vec![b'X'; MAX_CLI_OUTPUT as usize + 1]), Err(CliError::TooLarge));
        let prefixed = [b"ZeroTier notice\r\n".as_slice(),
            fixture(serde_json::json!([network("OK", &["10.77.37.3/24"])])).as_slice()].concat();
        assert!(matches!(network_observation(&prefixed).unwrap(), NetworkObservation::Ready { .. }));
    }

    #[test]
    fn installation_states_do_not_guess_or_claim_ready() {
        let none = CliInstallation { installed: false, command: None };
        let missing = status_from_observation(
            ServiceSnapshot { installed: Some(false), running: Some(false) }, none, None);
        assert_eq!(missing.state, "not-installed");
        let stopped = status_from_observation(
            ServiceSnapshot { installed: Some(true), running: Some(false) }, mock_cli(), None);
        assert_eq!(stopped.state, "service-stopped");
        let wrapper_only = status_from_observation(
            running(), CliInstallation { installed: true, command: None }, None);
        assert_eq!(wrapper_only.state, "cli-unavailable");
        let timeout = status_from_observation(running(), mock_cli(), Some(Err(CliError::TimedOut)));
        assert_eq!(timeout.reason, "zerotier-cli-timeout");
        assert!(!timeout.authorized);
    }

    #[test]
    fn preflight_exposes_only_the_pinned_official_installer_and_no_install_capability() {
        let missing = status_from_observation(
            ServiceSnapshot { installed: Some(false), running: Some(false) },
            CliInstallation { installed: false, command: None }, None);
        let plan = setup_plan_from_status(missing);
        assert_eq!(plan.action, if cfg!(windows) {
            "install-official-zerotier-with-user-approval"
        } else { "windows-required" });
        assert!(!plan.can_join);
        assert!(!plan.automatic_install_supported);
        assert!(plan.installer_signature_required && plan.install_requires_uac);
        assert_eq!(plan.installer_version, "1.16.2");
        assert_eq!(plan.installer_url,
            "https://download.zerotier.com/RELEASES/1.16.2/dist/ZeroTier%20One.msi");
        assert_eq!(plan.installer_sha256,
            "42514072b0fe44b8f66e0395bcd23a0b1d1642c28ed00831f1527b2f41b14670");
        assert!(!plan.status.authorized);
    }

    #[test]
    fn only_a_confirmed_missing_membership_with_running_service_allows_join() {
        let eligible = status_from_observation(
            running(), mock_cli(), Some(Ok(NetworkObservation::NotJoined)));
        let plan = setup_plan_from_status(eligible.clone());
        if cfg!(windows) {
            assert_eq!(plan.action, "join-coco-network");
            assert!(plan.can_join);
            assert_eq!(join_preflight(eligible).unwrap().state, "network-not-joined");
        } else {
            assert_eq!(plan.action, "windows-required");
            assert!(join_preflight(eligible).is_err());
        }
        let unknown_service = status_from_observation(
            ServiceSnapshot { installed: Some(true), running: None }, mock_cli(),
            Some(Ok(NetworkObservation::NotJoined)));
        assert!(!setup_plan_from_status(unknown_service.clone()).can_join);
        assert!(!join_preflight(unknown_service).is_ok());
        let not_queried = status_from_observation(running(), mock_cli(), None);
        assert!(!setup_plan_from_status(not_queried.clone()).can_join);
        assert!(join_preflight(not_queried).is_err());
    }

    #[test]
    fn joining_existing_or_unapproved_membership_is_never_retried() {
        let ready = status_from_observation(running(), mock_cli(),
            Some(Ok(NetworkObservation::Ready {
                address: "10.77.37.12".into(), role: "client",
            })));
        let result = join_preflight(ready).unwrap_err();
        assert_eq!(result.action, "already-connected");
        assert!(result.authorization_confirmed);
        assert!(!result.join_requested);
        let pending = status_from_observation(running(), mock_cli(),
            Some(Ok(NetworkObservation::Pending)));
        let result = join_preflight(pending).unwrap_err();
        assert_eq!(result.action, "already-joined-awaiting-authorization");
        assert_eq!(result.reason, "network-joined-authorization-pending");
        assert!(!result.authorization_confirmed);
        assert!(!result.join_requested);
        let unknown = status_from_observation(running(), mock_cli(),
            Some(Err(CliError::Malformed)));
        assert_eq!(join_preflight(unknown).unwrap_err().action, "blocked");
    }

    #[test]
    fn join_outcome_does_not_infer_authorization_from_cli_exit_or_request() {
        let awaiting = status_from_observation(running(), mock_cli(),
            Some(Ok(NetworkObservation::Pending)));
        let result = join_outcome(
            awaiting, "joined-awaiting-authorization",
            "controller-must-authorize-this-node", true);
        assert!(result.join_requested);
        assert!(!result.authorization_confirmed);
        assert!(!result.status.authorized);
        let serialized = serde_json::to_string(&result).unwrap();
        assert!(serialized.contains("\"joinRequested\":true"));
        assert!(!serialized.contains("authtoken"));
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("secret"));
    }

    #[test]
    fn post_join_requires_fresh_authoritative_membership_observation() {
        let absent = status_from_observation(running(), mock_cli(),
            Some(Ok(NetworkObservation::NotJoined)));
        let outcome = outcome_after_join(absent);
        assert_eq!(outcome.action, "join-unconfirmed");
        assert!(outcome.join_requested);
        assert!(!outcome.authorization_confirmed);
        let pending = status_from_observation(running(), mock_cli(),
            Some(Ok(NetworkObservation::Pending)));
        let outcome = outcome_after_join(pending);
        assert_eq!(outcome.action, "joined-awaiting-authorization");
        assert!(outcome.join_requested);
        assert!(!outcome.authorization_confirmed);
        let ready = status_from_observation(running(), mock_cli(),
            Some(Ok(NetworkObservation::Ready {
                address: "10.77.37.22".into(), role: "client",
            })));
        let outcome = outcome_after_join(ready);
        assert_eq!(outcome.action, "joined-and-authorized");
        assert!(outcome.join_requested && outcome.authorization_confirmed);
    }
}
