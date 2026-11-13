fn main() {
    // Bare Cargo test executables do not inherit Tauri's Windows application
    // manifest. Wry uses TaskDialogIndirect from comctl32 v6; without this
    // SxS activation Cargo test can fail before executing its first test.
    // Tauri's release EXE uses its bundled manifest. Bare Windows unit-test
    // EXEs do not link Tauri's main-bin resource and need a common-controls v6
    // dependency to load WebView/dialog symbols. In debug builds, embed that
    // dependency via link.exe and make Tauri's .res omit its own manifest so
    // both `cargo test --lib` AND `cargo build` avoid duplicate PE resources.
    #[cfg(target_os = "windows")]
    if std::env::var("PROFILE").as_deref() == Ok("debug") {
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTINPUT:windows/common-controls-v6.manifest");
        tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(
            tauri_build::WindowsAttributes::new_without_app_manifest(),
        )).expect("failed to build Coco 2 debug resources");
        return;
    }
    tauri_build::build()
}
