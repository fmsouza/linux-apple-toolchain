#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    assert_eq!(cdylib_probe::probe(), 42);
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_hello::init())
        .run(tauri::generate_context!())
        .expect("error while running HelloTauri");
}
