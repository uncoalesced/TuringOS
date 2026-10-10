// One snapshot of TuringOS + the machine, pushed to the page as the `state`
// message whenever it changes. Slow sources (weather, GitHub, calendar, Wi-Fi)
// refresh on their own timers into the shared cache.

use crate::{config_env, github, google, system, weather, AppRef};
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;

pub struct Shared {
    pub weather: Mutex<Value>,
    pub github: Mutex<Value>,
    pub calendar: Mutex<Value>,
    pub wifi: Mutex<Value>,
    /// Last projects_list result: agent_start only accepts these paths
    pub projects: Mutex<Vec<String>>,
    cpu_prev: Mutex<Option<(u64, u64)>>,
    user: Option<String>,
}

impl Default for Shared {
    fn default() -> Self {
        Self {
            weather: Mutex::new(Value::Null),
            github: Mutex::new(Value::Null),
            calendar: Mutex::new(google::disconnected()),
            wifi: Mutex::new(Value::Null),
            projects: Mutex::new(Vec::new()),
            cpu_prev: Mutex::new(None),
            user: system::first_name(),
        }
    }
}

pub fn snapshot(shared: &Shared) -> Value {
    let dir = config_env::data_dir();
    let state: Value = std::fs::read_to_string(dir.join("state.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
    let field = |k: &str| {
        state
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let task = field("agent_task");
    let sandbox = std::path::Path::new(&field("active_sandbox"))
        .file_name()
        .map(|n| n.to_string_lossy().into_owned());

    json!({
        // "live" means TuringOS has been initialised on this machine
        "live": dir.exists(),
        "user": { "name": shared.user },
        "agent": {
            "running": system::pid_alive(&field("agent_pid")),
            "task": if task.is_empty() { None } else { Some(task) },
        },
        "sandbox": sandbox,
        "gameMode": field("game_mode") == "on",
        "system": {
            "host": system::host(),
            "cpu": system::cpu(&shared.cpu_prev),
            "mem": system::mem(),
            "battery": system::battery(),
            "wifi": shared.wifi.lock().unwrap().clone(),
            "installer": system::installer_available(),
        },
        "weather": shared.weather.lock().unwrap().clone(),
        "github": shared.github.lock().unwrap().clone(),
        "calendar": shared.calendar.lock().unwrap().clone(),
    })
}

/// Push now, without waiting for the next tick (after a sign-in, say)
pub fn push(app: &AppRef) {
    app.emit("state", snapshot(&app.shared));
}

/// Start the push loop and every refresh loop
pub fn spawn_loops(app: AppRef) {
    // Checked every second, sent only when something changed. With no page
    // connected there is nothing to read the machine for.
    tokio::spawn({
        let app = app.clone();
        async move {
            let mut tick = tokio::time::interval(Duration::from_secs(1));
            let mut last = Value::Null;
            loop {
                tick.tick().await;
                if app.events.receiver_count() == 0 {
                    last = Value::Null;
                    continue;
                }
                let snap = snapshot(&app.shared);
                if snap != last {
                    app.emit("state", snap.clone());
                    last = snap;
                }
            }
        }
    });
    every(app.clone(), Duration::from_secs(10), |app| async move {
        let wifi = tokio::task::spawn_blocking(system::wifi)
            .await
            .unwrap_or(Value::Null);
        *app.shared.wifi.lock().unwrap() = wifi;
    });
    every(
        app.clone(),
        Duration::from_secs(15 * 60),
        |app| async move {
            // Offline or blocked: keep the last reading
            if let Some(w) = weather::fetch().await {
                *app.shared.weather.lock().unwrap() = w;
            }
        },
    );
    every(app.clone(), Duration::from_secs(5 * 60), |app| async move {
        // gh missing or logged out: keep the last good reading
        if let Some(g) = tokio::task::spawn_blocking(github::fetch)
            .await
            .ok()
            .flatten()
        {
            *app.shared.github.lock().unwrap() = g;
        }
    });
    every(app, Duration::from_secs(5 * 60), |app| async move {
        let cal = google::next_event().await;
        *app.shared.calendar.lock().unwrap() = cal;
    });
}

fn every<F, Fut>(app: AppRef, period: Duration, task: F)
where
    F: Fn(AppRef) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(period);
        loop {
            tick.tick().await;
            task(app.clone()).await;
        }
    });
}
