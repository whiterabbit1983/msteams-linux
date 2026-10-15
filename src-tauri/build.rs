fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&["set_unread_count", "show_notification"]),
    ))
    .expect("failed to run tauri-build");
}
