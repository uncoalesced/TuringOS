// Start the agent on a task. Arguments go straight to `turingos agent start`
// (no shell strings), which creates the sandbox first.

use crate::{config_env, projects, state::Shared, system};
use serde_json::{json, Value};
use std::path::PathBuf;

fn turingos_bin() -> Option<PathBuf> {
    std::env::var_os("TURINGOS_BIN")
        .map(PathBuf::from)
        .filter(|p| p.is_file())
        .or_else(|| system::which("turingos"))
}

#[tauri::command]
pub async fn agent_start(
    project: String,
    task: String,
    model: Option<String>,
    shared: tauri::State<'_, Shared>,
) -> Result<Value, ()> {
    let fail = |msg: &str| Ok(json!({ "ok": false, "error": msg }));
    if !config_env::data_dir().exists() {
        return fail("TuringOS is not set up. Run turingos init first.");
    }
    let task = task.trim();
    if task.is_empty() {
        return fail("Describe the task first.");
    }

    // Only projects the picker offered: the page can't point the agent at
    // arbitrary paths
    let cached = shared.projects.lock().unwrap().clone();
    let known = if cached.is_empty() {
        let found = tauri::async_runtime::spawn_blocking(projects::find)
            .await
            .unwrap_or_default();
        found
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect()
    } else {
        cached
    };
    if !known.contains(&project) || !std::path::Path::new(&project).is_dir() {
        return fail("That project folder no longer exists.");
    }

    let Some(bin) = turingos_bin() else {
        return fail("The turingos command isn't installed on this machine.");
    };
    let envs: Vec<(&str, &str)> = model
        .as_deref()
        .map(|m| ("TURINGOS_AGENT_MODEL", m))
        .into_iter()
        .collect();
    match system::spawn_detached(&bin, &["agent", "start", &project, task], &envs) {
        Ok(()) => Ok(json!({ "ok": true })),
        Err(e) => fail(&format!("Couldn't start the agent: {e}")),
    }
}
