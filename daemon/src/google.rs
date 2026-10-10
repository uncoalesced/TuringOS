// Google Calendar widget: next event, via a Google Cloud "Desktop app" OAuth
// client (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET in ~/.turingos/config.env).
//
// Sign-in runs in the system browser against a one-shot loopback listener,
// with a `state` check and PKCE. Tokens live in their own file (mode 600) and
// never cross to the page: only the event title and start time do.

use crate::{config_env, state, system, AppRef};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const SCOPE: &str = "https://www.googleapis.com/auth/calendar.events.readonly";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
static IN_FLIGHT: AtomicBool = AtomicBool::new(false);

pub fn disconnected() -> Value {
    json!({ "connected": false, "nextEvent": null })
}

fn creds() -> Option<(String, String)> {
    Some((
        config_env::get("GOOGLE_CLIENT_ID")?,
        config_env::get("GOOGLE_CLIENT_SECRET")?,
    ))
}

fn tokens_path() -> std::path::PathBuf {
    config_env::data_dir().join("google-tokens.json")
}

fn load_tokens() -> Option<Value> {
    serde_json::from_str(&std::fs::read_to_string(tokens_path()).ok()?).ok()
}

fn save_tokens(tokens: &Value) -> std::io::Result<()> {
    let path = tokens_path();
    let tmp = path.with_extension("json.tmp");
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts.open(&tmp)?.write_all(tokens.to_string().as_bytes())?;
    std::fs::rename(tmp, path)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn random_b64(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    getrandom::getrandom(&mut buf).expect("OS random source");
    B64.encode(buf)
}

/// x-www-form-urlencoded body
fn form(pairs: &[(&str, &str)]) -> String {
    reqwest::Url::parse_with_params("http://form.invalid/", pairs)
        .ok()
        .and_then(|u| u.query().map(str::to_string))
        .unwrap_or_default()
}

fn err(msg: &str) -> Value {
    json!({ "ok": false, "error": msg })
}

// ─── Sign-in ──────────────────────────────────────────────────────────────────

pub async fn google_connect(app: &AppRef) -> Value {
    let Some((id, secret)) = creds() else {
        return err("Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in ~/.turingos/config.env first (a Google Cloud \"Desktop app\" OAuth client).");
    };
    if IN_FLIGHT.swap(true, Ordering::SeqCst) {
        return err("Already connecting — check your browser.");
    }
    let result = connect(&id, &secret).await;
    IN_FLIGHT.store(false, Ordering::SeqCst);
    match result {
        Ok(()) => {
            let cal = next_event().await;
            *app.shared.calendar.lock().unwrap() = cal;
            state::push(app);
            json!({ "ok": true })
        }
        Err(e) => err(e),
    }
}

async fn connect(id: &str, secret: &str) -> Result<(), &'static str> {
    const LISTEN_ERR: &str = "Could not start the sign-in listener.";
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|_| LISTEN_ERR)?;
    let port = listener.local_addr().map_err(|_| LISTEN_ERR)?.port();
    let redirect = format!("http://127.0.0.1:{port}/oauth2callback");
    let state = random_b64(16);
    let verifier = random_b64(32);
    let challenge = B64.encode(Sha256::digest(verifier.as_bytes()));

    let url = reqwest::Url::parse_with_params(
        "https://accounts.google.com/o/oauth2/v2/auth",
        &[
            ("client_id", id),
            ("redirect_uri", redirect.as_str()),
            ("response_type", "code"),
            ("scope", SCOPE),
            ("access_type", "offline"),
            ("prompt", "consent"),
            ("state", state.as_str()),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ],
    )
    .map_err(|_| LISTEN_ERR)?;
    // Google rejects OAuth inside embedded webviews: always the real browser
    if !system::open_url(url.as_str()) {
        return Err("Couldn't open a browser on this machine.");
    }

    let code = tokio::time::timeout(Duration::from_secs(300), wait_for_code(&listener, &state))
        .await
        .map_err(|_| "Timed out waiting for Google sign-in.")??;
    let tokens = token_request(&[
        ("code", code.as_str()),
        ("client_id", id),
        ("client_secret", secret),
        ("redirect_uri", redirect.as_str()),
        ("grant_type", "authorization_code"),
        ("code_verifier", verifier.as_str()),
    ])
    .await
    .ok_or("Could not finish connecting Google Calendar.")?;
    save_tokens(&tokens).map_err(|_| "Could not save the Google sign-in.")
}

async fn wait_for_code(
    listener: &tokio::net::TcpListener,
    state: &str,
) -> Result<String, &'static str> {
    loop {
        let (mut sock, _) = listener
            .accept()
            .await
            .map_err(|_| "Google sign-in failed.")?;
        let mut buf = vec![0u8; 8192];
        let n = sock.read(&mut buf).await.unwrap_or(0);
        let request = String::from_utf8_lossy(&buf[..n]);
        let target = request.split_whitespace().nth(1).unwrap_or("");
        let Ok(url) = reqwest::Url::parse(&format!("http://127.0.0.1{target}")) else {
            continue;
        };
        if url.path() != "/oauth2callback" {
            let _ = sock
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
            continue;
        }
        let query: HashMap<String, String> = url.query_pairs().into_owned().collect();
        let state_ok = query.get("state").map(String::as_str) == Some(state);
        let code = query.get("code").filter(|_| state_ok).cloned();
        let body = if code.is_some() {
            "<html><body>Google Calendar connected — you can close this tab and go back to TuringOS.</body></html>"
        } else {
            "<html><body>Could not connect Google Calendar. You can close this tab.</body></html>"
        };
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = sock.write_all(response.as_bytes()).await;
        if !state_ok {
            return Err("Google sign-in returned a mismatched state — try again.");
        }
        return code.ok_or("Google sign-in was cancelled or denied.");
    }
}

async fn token_request(pairs: &[(&str, &str)]) -> Option<Value> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .ok()?;
    let res = client
        .post(TOKEN_URL)
        .header("content-type", "application/x-www-form-urlencoded")
        .body(form(pairs))
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    let mut tokens: Value = res.json().await.ok()?;
    if let Some(expires_in) = tokens["expires_in"].as_u64() {
        tokens["expires_at"] = json!(now() + expires_in.saturating_sub(60));
    }
    Some(tokens)
}

// ─── Next event ───────────────────────────────────────────────────────────────

async fn access_token() -> Option<String> {
    let (id, secret) = creds()?;
    let mut tokens = load_tokens()?;
    if tokens["expires_at"].as_u64().unwrap_or(0) > now() {
        if let Some(t) = tokens["access_token"].as_str() {
            return Some(t.to_string());
        }
    }
    let refresh = tokens["refresh_token"].as_str()?.to_string();
    let fresh = token_request(&[
        ("client_id", id.as_str()),
        ("client_secret", secret.as_str()),
        ("refresh_token", refresh.as_str()),
        ("grant_type", "refresh_token"),
    ])
    .await?;
    // A refresh response has no refresh_token: keep ours
    if let (Some(t), Some(f)) = (tokens.as_object_mut(), fresh.as_object()) {
        t.extend(f.clone());
    }
    let _ = save_tokens(&tokens);
    tokens["access_token"].as_str().map(str::to_string)
}

/// Calendar state for the snapshot. Connected with no event when offline or
/// the token is stale: drop the event rather than guess.
pub async fn next_event() -> Value {
    if creds().is_none() || load_tokens().is_none() {
        return disconnected();
    }
    let empty = json!({ "connected": true, "nextEvent": null });
    let Some(token) = access_token().await else {
        return empty;
    };
    let Ok(url) = reqwest::Url::parse_with_params(
        "https://www.googleapis.com/calendar/v3/calendars/primary/events",
        &[
            ("timeMin", rfc3339(now()).as_str()),
            ("maxResults", "1"),
            ("singleEvents", "true"),
            ("orderBy", "startTime"),
        ],
    ) else {
        return empty;
    };
    let Ok(client) = reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
    else {
        return empty;
    };
    let data: Option<Value> = match client.get(url).bearer_auth(token).send().await {
        Ok(res) if res.status().is_success() => res.json().await.ok(),
        _ => None,
    };
    let Some(ev) = data.as_ref().and_then(|d| d["items"].get(0)) else {
        return empty;
    };
    json!({
        "connected": true,
        "nextEvent": {
            "title": ev["summary"].as_str().unwrap_or("(no title)"),
            "start": ev["start"]["dateTime"].as_str().or(ev["start"]["date"].as_str()),
        }
    })
}

/// UTC timestamp as RFC 3339 (civil-from-days, no date crate needed)
fn rfc3339(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    use super::rfc3339;

    #[test]
    fn formats_utc_timestamps() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(1_790_985_600 + 3_661), "2026-10-03T01:01:01Z");
    }
}
