// Calls from the page. `Err` is for a call that couldn't be made at all (an
// unknown method, a missing argument); a method that ran and failed says so
// in its own result, as it did when these were Tauri commands.

use crate::{agent, anthropic, google, launch, projects, state, voice, AppRef};
use serde_json::{json, Value};

/// A required string argument
fn text<'a>(params: &'a Value, name: &str) -> Result<&'a str, String> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing argument: {name}"))
}

/// An optional string argument; empty counts as absent
fn maybe<'a>(params: &'a Value, name: &str) -> Option<&'a str> {
    params
        .get(name)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
}

pub async fn call(app: &AppRef, method: &str, params: &Value) -> Result<Value, String> {
    Ok(match method {
        "state_get" => state::snapshot(&app.shared),
        "projects_list" => projects::list(&app.shared).await,
        "agent_start" => {
            agent::start(
                &app.shared,
                text(params, "project")?,
                text(params, "task")?,
                maybe(params, "model"),
            )
            .await
        }
        "dock_launch" => launch::dock_launch(text(params, "id")?),
        "open_external" => json!(launch::open_external(text(params, "url")?)),
        "google_connect" => google::google_connect(app).await,
        "clawd_ask" => anthropic::clawd_ask(text(params, "message")?).await,
        "chat_ask" => {
            anthropic::chat_ask(
                text(params, "message")?,
                maybe(params, "model"),
                maybe(params, "effort"),
            )
            .await
        }
        "voice_start" => voice::voice_start(app).await,
        "voice_stop" => voice::voice_stop(app).await,
        "gfx_report" => {
            // Lands in the journal: the VM matrix reads it from there
            eprintln!("turingosd: gfx report {params}");
            *app.gfx_report.lock().unwrap() = params.clone();
            json!({ "ok": true })
        }
        _ => return Err(format!("Unknown method: {method}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_are_checked_before_anything_runs() {
        let params = json!({ "id": "terminal", "model": "", "n": 3 });
        assert_eq!(text(&params, "id"), Ok("terminal"));
        assert_eq!(text(&params, "url"), Err("Missing argument: url".into()));
        assert_eq!(text(&params, "n"), Err("Missing argument: n".into()));
        assert_eq!(maybe(&params, "model"), None);
        assert_eq!(maybe(&params, "id"), Some("terminal"));
    }
}
