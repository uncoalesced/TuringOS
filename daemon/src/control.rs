// The session's side door: a Unix socket in the runtime dir (mode 0600) for
// things the page can't start itself. The Super+Space hotkey lands here
// (session/turingos-omni), and `turingos status` reads from it.
//
//   curl --unix-socket "$XDG_RUNTIME_DIR/turingos/control.sock" -X POST http://d/omni

use crate::{gfx, AppRef, VERSION};

pub fn spawn(app: AppRef) {
    use axum::extract::State;
    use axum::routing::{get, post};
    use axum::{Json, Router};
    use serde_json::{json, Value};
    use std::sync::atomic::Ordering;

    async fn omni(State(app): State<AppRef>) -> Json<Value> {
        app.omni_presses.fetch_add(1, Ordering::Relaxed);
        app.emit("omni", json!({ "open": true }));
        Json(json!({ "ok": true, "pages": app.events.receiver_count() }))
    }

    async fn status(State(app): State<AppRef>) -> Json<Value> {
        Json(json!({
            "ok": true,
            "version": VERSION,
            "pages": app.events.receiver_count(),
            "connections": app.connections.load(Ordering::Relaxed),
            "omni_presses": app.omni_presses.load(Ordering::Relaxed),
            "gfx": gfx::hint(&crate::runtime_dir()),
            "gfx_report": app.gfx_report.lock().unwrap().clone(),
        }))
    }

    tokio::spawn(async move {
        let path = crate::runtime_dir().join("control.sock");
        // Left behind by a service that was killed
        let _ = std::fs::remove_file(&path);
        let listener = match tokio::net::UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("turingosd: no control socket at {}: {e}", path.display());
                return;
            }
        };
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        let router = Router::new()
            .route("/omni", post(omni))
            .route("/status", get(status))
            .with_state(app);
        if let Err(e) = axum::serve(listener, router).await {
            eprintln!("turingosd: control socket stopped: {e}");
        }
    });
}
