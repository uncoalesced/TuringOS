// turingosd — the TuringOS desktop service, behind turingos-bridged-ws. The
// page (served by the bridge to a Brave app window) draws; this process runs
// in the user's session, reads ~/.turingos and the machine, and does what the
// desktop needs: state for the menu bar and widgets, projects, starting the
// agent, dock apps, voice, Google sign-in. The page reaches it through the
// bridge's /desktop WebSocket: see protocol/v1/README.md.

mod agent;
mod anthropic;
mod config_env;
mod control;
mod gfx;
mod github;
mod google;
mod launch;
mod projects;
mod rpc;
mod session;
mod state;
mod system;
mod voice;
mod weather;

use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// A message for every connected page: (`type`, `data`)
pub type Event = (&'static str, Value);

pub struct App {
    pub shared: state::Shared,
    pub recorder: voice::Recorder,
    pub events: broadcast::Sender<Event>,
    /// The page's last frame-time report, for `turingos status` and the VM matrix
    pub gfx_report: Mutex<Value>,
    /// Since this service started: pages that connected, hotkey presses.
    /// tests/kiosk_contract.sh reads them to tell a reload from no reload.
    pub connections: AtomicU64,
    pub omni_presses: AtomicU64,
}

pub type AppRef = Arc<App>;

impl App {
    /// Send to every connected page; nobody listening is not an error
    pub fn emit(&self, kind: &'static str, data: Value) {
        let _ = self.events.send((kind, data));
    }
}

/// $XDG_RUNTIME_DIR/turingos: per user, in memory, gone at logout (the
/// launcher's graphics hint, the control socket). Without a runtime dir (a
/// checkout on macOS), ~/.cache/turingos: not ~/.turingos, whose existence is
/// what "TuringOS is set up here" means.
pub fn runtime_dir() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR").filter(|d| !d.is_empty()) {
        Some(d) => PathBuf::from(d).join("turingos"),
        None => config_env::home().join(".cache").join("turingos"),
    }
}

#[tokio::main]
async fn main() {
    let run = runtime_dir();
    if let Err(e) = std::fs::create_dir_all(&run).and_then(|()| {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&run, std::fs::Permissions::from_mode(0o700))
    }) {
        eprintln!("turingosd: can't prepare {}: {e}", run.display());
        std::process::exit(1);
    }

    let app = Arc::new(App {
        shared: state::Shared::default(),
        recorder: voice::Recorder::default(),
        events: broadcast::channel(64).0,
        gfx_report: Mutex::new(Value::Null),
        connections: AtomicU64::new(0),
        omni_presses: AtomicU64::new(0),
    });
    state::spawn_loops(app.clone());
    control::spawn(app.clone());

    tokio::select! {
        r = session::listen(app) => {
            if let Err(e) = r {
                eprintln!("turingosd: no desktop socket in {}: {e}", session::session_dir().display());
                std::process::exit(1);
            }
        }
        () = shutdown() => {}
    }
}

async fn shutdown() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).expect("SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}
