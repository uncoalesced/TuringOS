// Engineered by uncoalesced
// daemon/src/bazaar.rs — TuringOS Bazaar service module:
// catalog fetching, 24h caching, SHA-256 verification, installation,
// state queries, and per-project disable rule management.

use crate::{config_env, system};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub const DEFAULT_REMOTE_URL: &str =
    "https://uncoalesced.github.io/turingos-bazaar/v1/index.json";
pub const CACHE_TTL_SECS: u64 = 86400; // 24 hours

pub fn bazaar_dir() -> PathBuf {
    config_env::home().join(".turingos").join("bazaar")
}

pub fn cache_path() -> PathBuf {
    if let Ok(p) = std::env::var("TURINGOS_BAZAAR_CACHE") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    config_env::home()
        .join(".cache")
        .join("turingos")
        .join("bazaar")
        .join("index.json")
}

pub fn bundled_registry_path() -> PathBuf {
    if let Ok(r) = std::env::var("TURINGOS_REGISTRY") {
        if !r.is_empty() {
            return PathBuf::from(r);
        }
    }
    PathBuf::from("/usr/share/turingos/bazaar/registry.json")
}

pub fn rules_file_path() -> PathBuf {
    config_env::data_dir().join("bazaar_rules.json")
}

pub fn remote_url() -> String {
    std::env::var("TURINGOS_BAZAAR_REMOTE_URL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_REMOTE_URL.to_string())
}

/// Check if cache file exists and was modified within 24 hours
fn is_cache_fresh(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    let Ok(modified) = metadata.modified() else {
        return false;
    };
    let Ok(elapsed) = SystemTime::now().duration_since(modified) else {
        return false;
    };
    elapsed.as_secs() < CACHE_TTL_SECS
}

pub fn public_key_path() -> PathBuf {
    if let Ok(p) = std::env::var("TURINGOS_BAZAAR_PUBKEY") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let default_path = PathBuf::from("/etc/turingos/trust/bazaar.pub");
    if default_path.is_file() {
        return default_path;
    }
    PathBuf::from("/usr/lib/turingos/trust/keys/bazaar.pub")
}

pub fn verify_signature(data: &[u8], sig: &[u8]) -> bool {
    // Fail closed: any problem verifying means the index is not trusted.
    let pubkey = public_key_path();
    if !pubkey.is_file() {
        return false;
    }

    let pid = std::process::id();
    let tmp_data = cache_path().with_file_name(format!(".verify_data.{pid}.tmp"));
    let tmp_sig = cache_path().with_file_name(format!(".verify_sig.{pid}.tmp"));

    if let Some(parent) = tmp_data.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if fs::write(&tmp_data, data).is_err() || fs::write(&tmp_sig, sig).is_err() {
        let _ = fs::remove_file(&tmp_data);
        let _ = fs::remove_file(&tmp_sig);
        return false;
    }

    let status = std::process::Command::new("openssl")
        .args([
            "pkeyutl",
            "-verify",
            "-pubin",
            "-inkey",
            pubkey.to_str().unwrap_or(""),
            "-rawin",
            "-in",
            tmp_data.to_str().unwrap_or(""),
            "-sigfile",
            tmp_sig.to_str().unwrap_or(""),
        ])
        .status();

    let _ = fs::remove_file(&tmp_data);
    let _ = fs::remove_file(&tmp_sig);

    match status {
        Ok(s) => s.success(),
        Err(_) => false,
    }
}

/// Fetch remote index or fall back to cache / bundled snapshot
pub async fn fetch_index() -> (Value, bool) {
    let cache = cache_path();
    let is_offline_mode = std::env::var("TURINGOS_BAZAAR_OFFLINE_MODE")
        .map(|v| v == "1")
        .unwrap_or(false);

    // 1. Fresh cache check
    if !is_offline_mode && is_cache_fresh(&cache) {
        if let Ok(content) = fs::read_to_string(&cache) {
            if let Ok(parsed) = serde_json::from_str::<Value>(&content) {
                if parsed.get("entries").is_some() || parsed.get("tools").is_some() {
                    return (parsed, false);
                }
            }
        }
    }

    // 2. Remote HTTP fetch with 5-second timeout
    if !is_offline_mode {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build();
        if let Ok(client) = client {
            let r_url = remote_url();
            if let Ok(res) = client.get(&r_url).send().await {
                if res.status().is_success() {
                    if let Ok(bytes) = res.bytes().await {
                        if let Ok(parsed) = serde_json::from_slice::<Value>(&bytes) {
                            if parsed.get("entries").is_some() || parsed.get("tools").is_some() {
                                // A valid detached signature is mandatory. Missing,
                                // unfetchable or invalid => discard the remote index
                                // and fall through to stale cache / bundled snapshot.
                                let sig_url = format!("{r_url}.sig");
                                let mut verified = false;
                                if let Ok(sig_res) = client.get(&sig_url).send().await {
                                    if sig_res.status().is_success() {
                                        if let Ok(sig_bytes) = sig_res.bytes().await {
                                            verified = verify_signature(&bytes, &sig_bytes);
                                        }
                                    }
                                }
                                if verified {
                                    if let Some(parent) = cache.parent() {
                                        let _ = fs::create_dir_all(parent);
                                    }
                                    let _ = fs::write(&cache, &bytes);
                                    return (parsed, false);
                                }
                                eprintln!(
                                    "turingosd: bazaar index signature missing or invalid; ignoring remote index"
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. Fallback: stale cache
    if cache.is_file() {
        if let Ok(content) = fs::read_to_string(&cache) {
            if let Ok(parsed) = serde_json::from_str::<Value>(&content) {
                if parsed.get("entries").is_some() || parsed.get("tools").is_some() {
                    return (parsed, true);
                }
            }
        }
    }

    // 4. Fallback: bundled operating system snapshot
    let bundled = bundled_registry_path();
    if bundled.is_file() {
        if let Ok(content) = fs::read_to_string(&bundled) {
            if let Ok(parsed) = serde_json::from_str::<Value>(&content) {
                if parsed.get("entries").is_some() || parsed.get("tools").is_some() {
                    return (parsed, true);
                }
            }
        }
    }

    (json!({ "version": 1, "entries": {} }), true)
}

/// Returns all installed tool identifiers
pub fn installed_tools() -> HashSet<String> {
    let mut installed = HashSet::new();
    let dir = bazaar_dir();
    let Ok(entries) = fs::read_dir(dir) else {
        return installed;
    };
    for entry in entries.flatten() {
        if entry.path().join(".installed").is_file() {
            if let Some(name) = entry.file_name().to_str() {
                installed.insert(name.to_string());
            }
        }
    }
    installed
}

/// Retrieve per-project disabled items (nearest rule wins, repo file overrides daemon state)
pub fn get_disabled_items(project_dir: &Path) -> HashSet<String> {
    let mut disabled = HashSet::new();

    // 1. Check for committed .turingos/bazaar.toml in folder or ancestors
    let mut curr = Some(project_dir);
    while let Some(dir) = curr {
        let toml_path = dir.join(".turingos").join("bazaar.toml");
        if toml_path.is_file() {
            if let Ok(text) = fs::read_to_string(&toml_path) {
                for line in text.lines() {
                    let line = line.trim();
                    if line.starts_with("disabled") {
                        if let Some((_, list)) = line.split_once('=') {
                            let list = list.trim().trim_matches(|c| c == '[' || c == ']');
                            for item in list.split(',') {
                                let id = item.trim().trim_matches(|c| c == '"' || c == '\'');
                                if !id.is_empty() {
                                    disabled.insert(id.to_string());
                                }
                            }
                        }
                    }
                }
            }
            return disabled;
        }
        curr = dir.parent();
    }

    // 2. Read daemon state rules from bazaar_rules.json
    let rules_file = rules_file_path();
    if let Ok(text) = fs::read_to_string(&rules_file) {
        if let Ok(rules) = serde_json::from_str::<Value>(&text) {
            if let Some(map) = rules.as_object() {
                let canonical = project_dir
                    .canonicalize()
                    .unwrap_or_else(|_| project_dir.to_path_buf());
                let mut best_prefix = "";
                let mut best_list = Vec::new();

                for (prefix, list) in map {
                    let prefix_path = Path::new(prefix);
                    if canonical.starts_with(prefix_path) && prefix.len() > best_prefix.len() {
                        best_prefix = prefix;
                        if let Some(arr) = list.as_array() {
                            best_list = arr
                                .iter()
                                .filter_map(Value::as_str)
                                .map(String::from)
                                .collect();
                        }
                    }
                }
                for item in best_list {
                    disabled.insert(item);
                }
            }
        }
    }

    disabled
}

/// Set enable/disable toggle for a project folder
pub fn set_project_rule(project_dir: &Path, item_id: &str, enabled: bool) -> Result<(), String> {
    let canonical = project_dir
        .canonicalize()
        .unwrap_or_else(|_| project_dir.to_path_buf())
        .to_string_lossy()
        .into_owned();

    let rules_file = rules_file_path();
    let mut rules = if let Ok(text) = fs::read_to_string(&rules_file) {
        serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({}))
    } else {
        json!({})
    };

    if !rules.is_object() {
        rules = json!({});
    }

    let obj = rules.as_object_mut().unwrap();
    let mut current_set: HashSet<String> = obj
        .get(&canonical)
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    if enabled {
        current_set.remove(item_id);
    } else {
        current_set.insert(item_id.to_string());
    }

    let updated_arr: Vec<String> = current_set.into_iter().collect();
    obj.insert(canonical.clone(), json!(updated_arr));

    if let Some(parent) = rules_file.parent() {
        let _ = fs::create_dir_all(parent);
    }
    fs::write(&rules_file, serde_json::to_string_pretty(&rules).unwrap())
        .map_err(|e| format!("Could not save bazaar rules: {e}"))?;

    // Also sync to .turingos/bazaar.toml if directory already exists
    let dot_turingos = project_dir.join(".turingos");
    if dot_turingos.is_dir() {
        let toml_path = dot_turingos.join("bazaar.toml");
        let formatted_items = updated_arr
            .iter()
            .map(|s| format!("\"{}\"", s))
            .collect::<Vec<_>>()
            .join(", ");
        let toml_content = format!(
            "# TuringOS Bazaar Project Configuration\n[bazaar]\ndisabled = [{}]\n",
            formatted_items
        );
        let _ = fs::write(&toml_path, toml_content);
    }

    // Write Claude Code project-level disabled MCP configuration
    sync_claude_project_config(project_dir, &updated_arr)?;

    Ok(())
}

/// Sync per-project disablement to Claude Code project config
fn sync_claude_project_config(project_dir: &Path, disabled: &[String]) -> Result<(), String> {
    let claude_dir = project_dir.join(".claude");
    let _ = fs::create_dir_all(&claude_dir);
    let settings_path = claude_dir.join("settings.json");

    let mut settings = if let Ok(text) = fs::read_to_string(&settings_path) {
        serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({}))
    } else {
        json!({})
    };

    if !settings.is_object() {
        settings = json!({});
    }

    let obj = settings.as_object_mut().unwrap();
    obj.insert("disabledMcpServers".to_string(), json!(disabled));

    let _ = fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap(),
    );
    Ok(())
}

/// List all bazaar entries with install & project enablement flags
pub async fn list(project_path: Option<&str>) -> Value {
    let (index, offline) = fetch_index().await;
    let installed = installed_tools();
    let project_dir = project_path.map(Path::new);
    let disabled = project_dir
        .map(get_disabled_items)
        .unwrap_or_default();

    let empty_map = serde_json::Map::new();
    let entries_map = index
        .get("entries")
        .or_else(|| index.get("tools"))
        .and_then(Value::as_object)
        .unwrap_or(&empty_map);

    let mut result_list = Vec::new();
    for (key, val) in entries_map {
        let mut item = val.clone();
        let is_installed = installed.contains(key);
        let is_enabled = !disabled.contains(key);

        if let Some(obj) = item.as_object_mut() {
            obj.insert("id".to_string(), json!(key));
            obj.insert("installed".to_string(), json!(is_installed));
            obj.insert("enabled".to_string(), json!(is_enabled));

            if is_installed {
                let marker = bazaar_dir().join(key).join(".installed");
                if let Ok(ts) = fs::read_to_string(marker) {
                    obj.insert("installed_at".to_string(), json!(ts.trim()));
                }
            }
        }
        result_list.push(item);
    }

    json!({
        "ok": true,
        "offline": offline,
        "count": result_list.len(),
        "entries": result_list
    })
}

/// Get detailed info for a single tool
pub async fn info(key: &str) -> Value {
    let (index, offline) = fetch_index().await;
    let entries = index
        .get("entries")
        .or_else(|| index.get("tools"))
        .and_then(Value::as_object);

    let Some(entry) = entries.and_then(|m| m.get(key)) else {
        return json!({ "ok": false, "error": format!("Tool not found: {key}") });
    };

    let mut item = entry.clone();
    let installed = installed_tools().contains(key);
    if let Some(obj) = item.as_object_mut() {
        obj.insert("id".to_string(), json!(key));
        obj.insert("installed".to_string(), json!(installed));
        obj.insert("offline".to_string(), json!(offline));
        if installed {
            let marker = bazaar_dir().join(key).join(".installed");
            if let Ok(ts) = fs::read_to_string(marker) {
                obj.insert("installed_at".to_string(), json!(ts.trim()));
            }
        }
    }

    json!({ "ok": true, "entry": item })
}

/// Install tool via tested shell runner (ensuring 100% test parity and security)
pub async fn install(key: &str) -> Value {
    let tos_bin = system::which("turingos").unwrap_or_else(|| PathBuf::from("turingos"));
    let output = tokio::process::Command::new(tos_bin)
        .args(["bazaar", "install", "-y", key])
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => {
            json!({
                "ok": true,
                "key": key,
                "message": format!("{key} installed successfully")
            })
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            json!({
                "ok": false,
                "error": if !stderr.is_empty() { stderr } else { stdout }
            })
        }
        Err(e) => json!({ "ok": false, "error": format!("Install process error: {e}") }),
    }
}

/// Uninstall tool via tested shell runner
pub async fn uninstall(key: &str) -> Value {
    let tos_bin = system::which("turingos").unwrap_or_else(|| PathBuf::from("turingos"));
    let output = tokio::process::Command::new(tos_bin)
        .args(["bazaar", "uninstall", "-y", key])
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => {
            json!({ "ok": true, "key": key, "message": format!("{key} uninstalled") })
        }
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr).into_owned();
            json!({ "ok": false, "error": err })
        }
        Err(e) => json!({ "ok": false, "error": format!("Uninstall process error: {e}") }),
    }
}

/// Retrieve rules for a project path
pub async fn get_rules(project_path: &str) -> Value {
    let path = Path::new(project_path);
    let disabled = get_disabled_items(path);
    json!({
        "ok": true,
        "path": project_path,
        "disabled": disabled.into_iter().collect::<Vec<_>>()
    })
}

/// Set rule for a project path
pub async fn set_rule(project_path: &str, item_id: &str, enabled: bool) -> Value {
    let path = Path::new(project_path);
    match set_project_rule(path, item_id, enabled) {
        Ok(()) => json!({ "ok": true, "path": project_path, "id": item_id, "enabled": enabled }),
        Err(e) => json!({ "ok": false, "error": e }),
    }
}
