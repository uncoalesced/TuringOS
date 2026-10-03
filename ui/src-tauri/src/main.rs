// turingos-ui — the TuringOS desktop shell. The page (ui/index.html) draws;
// this process reads ~/.turingos and the machine, and does everything that
// touches the system. KIOSK=1: fullscreen, as on the live ISO.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod agent;
mod anthropic;
mod config_env;
mod github;
mod google;
mod launch;
mod projects;
mod state;
mod system;
mod voice;
mod weather;

use tauri::{WebviewUrl, WebviewWindowBuilder};

fn main() {
    system::prepare_webview_env();
    let kiosk = std::env::var("KIOSK").as_deref() == Ok("1");

    tauri::Builder::default()
        .manage(state::Shared::default())
        .manage(voice::Recorder::default())
        .invoke_handler(tauri::generate_handler![
            state::state_get,
            projects::projects_list,
            agent::agent_start,
            launch::dock_launch,
            launch::open_external,
            launch::app_quit,
            google::google_connect,
            anthropic::clawd_ask,
            anthropic::chat_ask,
            voice::voice_start,
            voice::voice_stop,
        ])
        .setup(move |app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("TuringOS")
                .inner_size(1440.0, 900.0)
                .min_inner_size(960.0, 600.0)
                .decorations(false)
                .fullscreen(kiosk)
                // The shell never navigates away from its own pages
                .on_navigation(|url| {
                    url.scheme() == "tauri" || url.host_str() == Some("tauri.localhost")
                })
                .build()?;
            state::spawn_loops(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to start the TuringOS UI");
}
