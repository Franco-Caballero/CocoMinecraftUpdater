mod services;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // A second Explorer invocation only delivers a validated path request to
    // the running primary process. Never display a second UI on IPC failure.
    match services::activation::start_or_handoff() {
        Ok(true) => {}
        Ok(false) => return,
        Err(error) => {
            eprintln!("Coco 2 Windows activation failed closed: {error}");
            return;
        }
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(services::standalone::RuntimeState::default())
        .manage(services::session::SessionState)
        .manage(services::install::InstallState::default())
        .manage(services::media_download::MediaDownloadState::default())
        .manage(services::verify::VerifyState::default())
        .setup(|app| {
            services::activation::attach_app(app.handle())
                .map_err(std::io::Error::other)?;
            // Before any install can start: what a closed or crashed session left behind.
            if let Some(local_data)=std::env::var_os("LOCALAPPDATA"){
                services::install::sweep_download_cache(std::path::Path::new(&local_data));
            }
            services::uninstall::sweep_in_background();
            services::handoff::retire_launcher1_shortcuts_in_background();
            services::zerotier_host::accept_friends_in_background();
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            services::activation::take_pending_package_open_requests,
            services::activation::peek_pending_package_open_requests,
            services::activation::acknowledge_pending_package_open_requests,
            services::activation::has_pending_package_open_requests,
            services::activation::try_arm_app_update_install,
            services::activation::finish_app_update_install_guard,
            services::activation::confirm_package_open_listener_ready,
            services::activation::cancel_pending_package_open_request,
            services::activation::release_reviewed_package_replay_suppression,
            services::catalog::get_catalog,
            services::catalog::review_local_publish_package,
            services::catalog::import_local_publish_package,
            services::catalog::sync_catalog_channel,
            services::catalog::get_catalog_channel_status,
            services::catalog::prepare_catalog_channel,
            services::catalog::review_channel_delivery,
            services::catalog::verify_channel_delivery_online,
            services::catalog::get_catalog_provenance,
            services::identity::get_local_identity,
            services::identity::set_local_identity,
            services::identity::confirm_local_identity_change,
            services::identity::get_profile_avatar,
            services::identity::set_profile_avatar,
            services::identity::remove_profile_avatar,
            services::r#import::inspect_standalone_archive,
            services::r#import::host_studio_available,
            services::r#import::create_standalone_draft,
            services::r#import::create_standalone_update_draft,
            services::r#import::review_standalone_draft,
            services::r#import::promote_standalone_draft,
            services::r#import::preview_standalone_publish,
            services::r#import::prepare_standalone_publish,
            services::r#import::export_portable_standalone_package,
            services::inventory::get_local_instances,
            services::status::get_engine_status,
            services::standalone::list_running_games,
            services::standalone::get_active_game_processes,
            services::standalone::launch_standalone,
            services::session::get_session_status,
            services::install::plan_standalone_install,
            services::install::plan_standalone_upgrade,
            services::install::upgrade_standalone,
            services::install::recover_standalone_upgrade,
            services::install::recover_pending_standalone_operations,
            services::install::plan_standalone_repair,
            services::install::prepare_standalone_repair,
            services::install::commit_standalone_repair,
            services::install::recover_standalone_repair,
            services::install::get_standalone_repair_recovery_status,
            services::install::install_standalone,
            services::install::cancel_standalone_install,
            services::defender::ensure_defender_exclusions,
            services::defender::prepare_windows,
            services::diagnostics::log_event,
            services::diagnostics::get_diagnostic_report,
            services::diagnostics::open_log_folder,
            services::location::get_install_location,
            services::location::check_install_location,
            services::location::set_install_location,
            services::location::move_installation,
            services::location::open_game_folder,
            services::uninstall::get_installed_size,
            services::uninstall::uninstall_standalone,
            services::managed::plan_managed,
            services::media::get_media_catalog,
            services::media::prepare_media_stream,
            services::media::prepare_local_media_stream,
            services::media::close_media_stream,
            services::native_player::open_native_player,
            services::native_player::native_player_status,
            services::native_player::control_native_player,
            services::native_player::close_native_player,
            services::media_download::get_media_download_status,
            services::media_download::download_media_episode,
            services::media_download::cancel_media_download,
            services::preview_cache::get_preview_cache,
            services::preview_cache::start_preview_cache,
            services::preview_cache::prioritize_preview,
            services::network::get_network_status,
            services::network::prepare_network_setup,
            services::network::join_coco_network,
            services::network_installer::install_zerotier_msi,
            services::verify::verify_local_instance,
            services::verify::cancel_verification,
            services::windows_security::get_game_security_guide,
            services::windows_security::open_windows_security
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Coco Launcher 2")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                services::native_player::shutdown();
                use tauri::Manager;
                services::install::discard_pending_downloads(&app.state::<services::install::InstallState>());
                // Stop Win32 handoff listeners on a real app exit; closing a
                // view or hiding a window must not disable single-instance.
                if let Err(error) = services::activation::shutdown_activation() {
                    eprintln!("Coco 2 Windows activation shutdown: {error}");
                }
            }
        });
}
