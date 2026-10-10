// Projects for the @ picker: git repos up to 3 levels under $HOME (or under
// TURINGOS_PROJECT_ROOTS=/path/a:/path/b).

use crate::{config_env, state::Shared};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const SKIP_DIRS: [&str; 9] = [
    "node_modules",
    "snap",
    "go",
    "vendor",
    "target",
    "build",
    "dist",
    "Music",
    "Pictures",
];
const MAX_PROJECTS: usize = 200;

fn walk(dir: &Path, depth: u8, found: &mut Vec<PathBuf>) {
    if found.len() >= MAX_PROJECTS {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let entries: Vec<_> = entries.flatten().collect();
    if entries.iter().any(|e| e.file_name() == ".git") {
        found.push(dir.to_path_buf());
        return;
    }
    if depth == 0 {
        return;
    }
    for e in entries {
        let name = e.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with('.')
            && !SKIP_DIRS.contains(&name.as_ref())
            && e.file_type().is_ok_and(|t| t.is_dir())
        {
            walk(&e.path(), depth - 1, found);
        }
    }
}

pub fn find() -> Vec<PathBuf> {
    let roots: Vec<PathBuf> = match std::env::var_os("TURINGOS_PROJECT_ROOTS") {
        Some(r) => std::env::split_paths(&r).collect(),
        None => vec![config_env::home()],
    };
    let mut found = Vec::new();
    for root in roots {
        walk(&root, 3, &mut found);
    }
    found.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()));
    found.dedup();
    found
}

pub async fn list(shared: &Shared) -> Value {
    let found = tokio::task::spawn_blocking(find).await.unwrap_or_default();
    *shared.projects.lock().unwrap() = found
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    found
        .iter()
        .map(|p| json!({ "name": p.file_name().map(|n| n.to_string_lossy()), "path": p }))
        .collect()
}
