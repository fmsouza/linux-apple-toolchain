//! Local plugin with an iOS Swift implementation (`ios/`), laid out like a `tauri plugin new` plugin.
//! `ping` has no Rust handler: on iOS the call is forwarded to `HelloPlugin.ping` in Swift.
use tauri::{
    plugin::{Builder, TauriPlugin},
    Runtime,
};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_hello);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("hello")
        .setup(|_app, _api| {
            #[cfg(target_os = "ios")]
            _api.register_ios_plugin(init_plugin_hello)?;
            Ok(())
        })
        .build()
}
