// Local shell mode (Phase 3 fallback): when the AI is unreachable, the
// composer runs what the user types as a plain shell command, like a
// terminal would. The user's own command, as the user; no agent involved.

use crate::config_env;
use serde_json::{json, Value};
use std::io::Read;
use std::process::{Command, Stdio};

const TIMEOUT_SECS: u64 = 60;
const MAX_OUTPUT: usize = 64 * 1024;

fn run(command: &str, timeout_secs: u64) -> Value {
    if command.trim().is_empty() {
        return json!({ "ok": false, "error": "Nothing to run." });
    }
    // coreutils timeout: SIGTERM after the limit, SIGKILL 5s later. Not a
    // login shell: the first-run profile script would prompt for a key.
    let child = Command::new("timeout")
        .args(["-k", "5", &timeout_secs.to_string(), "bash", "-c"])
        .arg(format!("exec 2>&1\n{command}"))
        .current_dir(config_env::home())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return json!({ "ok": false, "error": format!("Couldn't start bash: {e}") }),
    };

    // Read at most MAX_OUTPUT + 1 bytes, then drop the pipe: a command that
    // keeps writing (`yes`) dies of SIGPIPE instead of filling memory
    let mut buf = Vec::new();
    if let Some(out) = child.stdout.take() {
        let _ = out.take(MAX_OUTPUT as u64 + 1).read_to_end(&mut buf);
    }
    let code = child.wait().ok().and_then(|s| s.code());

    let truncated = buf.len() > MAX_OUTPUT;
    buf.truncate(MAX_OUTPUT);
    let mut output = String::from_utf8_lossy(&buf).into_owned();
    if truncated {
        output.push_str("\n[output truncated at 64 KB]");
    }
    if code == Some(124) {
        output.push_str(&format!("\n[stopped after {timeout_secs}s]"));
    }
    json!({ "ok": true, "code": code, "output": output })
}

#[tauri::command]
pub async fn shell_run(command: String) -> Value {
    tauri::async_runtime::spawn_blocking(move || run(&command, TIMEOUT_SECS))
        .await
        .unwrap_or_else(|e| json!({ "ok": false, "error": e.to_string() }))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn output_and_exit_code() {
        let r = run("echo out; echo err >&2; exit 3", 10);
        assert_eq!(r["ok"], true);
        assert_eq!(r["code"], 3);
        assert_eq!(r["output"], "out\nerr\n");
    }

    #[test]
    fn empty_command_is_refused() {
        assert_eq!(run("   ", 10)["ok"], false);
    }

    #[test]
    fn endless_output_is_capped() {
        let r = run("yes", 10);
        let out = r["output"].as_str().unwrap();
        assert!(out.ends_with("[output truncated at 64 KB]"));
        assert!(out.len() < MAX_OUTPUT + 64);
    }

    #[test]
    fn slow_command_is_stopped() {
        let r = run("sleep 30", 1);
        assert_eq!(r["code"], 124);
        assert!(r["output"]
            .as_str()
            .unwrap()
            .ends_with("[stopped after 1s]"));
    }
}
