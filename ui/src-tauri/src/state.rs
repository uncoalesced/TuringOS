// One snapshot of TuringOS + the machine, pushed to the page every second
// as the `state` event. Slow sources (weather, GitHub, calendar, Wi-Fi)
// refresh on their own timers into the shared cache.

use crate::{config_env, github, google, system, weather};
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

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
        },
        "weather": shared.weather.lock().unwrap().clone(),
        "github": shared.github.lock().unwrap().clone(),
        "calendar": shared.calendar.lock().unwrap().clone(),
    })
}

#[tauri::command]
pub fn state_get(shared: tauri::State<'_, Shared>) -> Value {
    snapshot(&shared)
}

pub fn push(app: &AppHandle) {
    let _ = app.emit("state", snapshot(&app.state::<Shared>()));
}

/// Start the push loop and every refresh loop
pub fn spawn_loops(app: AppHandle) {
    every(app.clone(), Duration::from_secs(1), |app| async move {
        push(&app)
    });
    every(app.clone(), Duration::from_secs(10), |app| async move {
        let wifi = tauri::async_runtime::spawn_blocking(system::wifi)
            .await
            .unwrap_or(Value::Null);
        *app.state::<Shared>().wifi.lock().unwrap() = wifi;
    });
    every(
        app.clone(),
        Duration::from_secs(15 * 60),
        |app| async move {
            // Offline or blocked: keep the last reading
            if let Some(w) = weather::fetch().await {
                *app.state::<Shared>().weather.lock().unwrap() = w;
            }
        },
    );
    every(app.clone(), Duration::from_secs(5 * 60), |app| async move {
        // gh missing or logged out: keep the last good reading
        if let Some(g) = tauri::async_runtime::spawn_blocking(github::fetch)
            .await
            .ok()
            .flatten()
        {
            *app.state::<Shared>().github.lock().unwrap() = g;
        }
    });
    every(app, Duration::from_secs(5 * 60), |app| async move {
        let cal = google::next_event().await;
        *app.state::<Shared>().calendar.lock().unwrap() = cal;
    });
}

fn every<F, Fut>(app: AppHandle, period: Duration, task: F)
where
    F: Fn(AppHandle) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    tauri::async_runtime::spawn(async move {
        let mut tick = tokio::time::interval(period);
        loop {
            tick.tick().await;
            task(app.clone()).await;
        }
    });
}
