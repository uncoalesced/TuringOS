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

pub async fn start(shared: &Shared, project: &str, task: &str, model: Option<&str>) -> Value {
    let fail = |msg: &str| json!({ "ok": false, "error": msg });
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
        let found = tokio::task::spawn_blocking(projects::find)
            .await
            .unwrap_or_default();
        found
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect()
    } else {
        cached
    };
    if !known.iter().any(|p| p == project) || !std::path::Path::new(project).is_dir() {
        return fail("That project folder no longer exists.");
    }

    let Some(bin) = turingos_bin() else {
        return fail("The turingos command isn't installed on this machine.");
    };
    let envs: Vec<(&str, &str)> = model
        .filter(|m| !m.is_empty())
        .map(|m| ("TURINGOS_AGENT_MODEL", m))
        .into_iter()
        .collect();
    // A run outlives a restart of this service, as it outlived the old UI
    match system::spawn_lasting(&bin, &["agent", "start", project, task], &envs) {
        Ok(()) => json!({ "ok": true }),
        Err(e) => fail(&format!("Couldn't start the agent: {e}")),
    }
}
