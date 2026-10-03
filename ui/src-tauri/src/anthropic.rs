// One-shot Claude calls, shared by Clawd and the composer's plain-chat path
// (no @project attached). One question, one answer, no history kept. The
// API key stays here; the page has no network access of its own.

use crate::config_env;
use serde_json::{json, Value};
use std::time::Duration;

const DEFAULT_MODEL: &str = "claude-haiku-4-5";
// Haiku doesn't take an effort setting
const EFFORT_MODELS: [&str; 3] = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"];
const CLAWD_SYSTEM_PROMPT: &str = "You are Clawd, a small, friendly pixel mascot that lives on the TuringOS desktop. Answer questions briefly and helpfully, in a couple of sentences unless more detail is clearly needed.";

struct Ask<'a> {
    message: &'a str,
    model: Option<&'a str>,
    effort: Option<&'a str>,
    system: Option<&'a str>,
    max_tokens: u32,
    who: &'a str,
}

async fn ask(a: Ask<'_>) -> Value {
    let fail = |msg: String| json!({ "ok": false, "error": msg });
    let message = a.message.trim();
    if message.is_empty() {
        return fail("Say something first.".into());
    }
    let Some(key) = config_env::get("ANTHROPIC_API_KEY") else {
        return fail(format!(
            "{} needs an API key — set ANTHROPIC_API_KEY in ~/.turingos/config.env.",
            a.who
        ));
    };
    let model = a.model.filter(|m| !m.is_empty()).unwrap_or(DEFAULT_MODEL);
    let mut body = json!({
        "model": model,
        "max_tokens": a.max_tokens,
        "messages": [{ "role": "user", "content": message }],
    });
    if let Some(system) = a.system {
        body["system"] = json!(system);
    }
    if let Some(effort) = a.effort.filter(|_| EFFORT_MODELS.contains(&model)) {
        body["output_config"] = json!({ "effort": effort });
    }

    let offline = || fail(format!("{} is offline right now.", a.who));
    let Ok(client) = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
    else {
        return offline();
    };
    let res = match client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", key)
        .header("anthropic-version", "2023-06-01")
        .json(&body)
        .send()
        .await
    {
        Ok(r) => r,
        Err(_) => return offline(),
    };
    match res.status().as_u16() {
        401 => return fail(format!("{}'s API key looks wrong.", a.who)),
        429 => {
            return fail(format!(
                "{} is popular right now — try again shortly.",
                a.who
            ))
        }
        s if !(200..300).contains(&s) => return fail(format!("{} hit an error ({s}).", a.who)),
        _ => {}
    }
    let Ok(data) = res.json::<Value>().await else {
        return offline();
    };
    let text = data["content"]
        .as_array()
        .and_then(|blocks| blocks.iter().find(|b| b["type"] == "text"))
        .and_then(|b| b["text"].as_str())
        .unwrap_or("");
    json!({ "ok": true, "text": text })
}

#[tauri::command]
pub async fn clawd_ask(message: String) -> Value {
    ask(Ask {
        message: &message,
        model: Some(DEFAULT_MODEL),
        effort: None,
        system: Some(CLAWD_SYSTEM_PROMPT),
        max_tokens: 512,
        who: "Clawd",
    })
    .await
}

#[tauri::command]
pub async fn chat_ask(message: String, model: Option<String>, effort: Option<String>) -> Value {
    ask(Ask {
        message: &message,
        model: model.as_deref(),
        effort: effort.as_deref(),
        system: None,
        max_tokens: 2048,
        who: "TuringOS",
    })
    .await
}
