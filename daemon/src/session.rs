// One page's connection, as turingos-bridged-ws forwards it from the page's
// /desktop WebSocket: one JSON message per line each way. The envelope, the
// hello exchange, calls from the page and messages for it are in
// protocol/v1/README.md.
//
// The socket is in the session drop-box (/run/turingos/session, 1777, from
// turingos-tmpfiles.conf), next to shell-helper's: the bridge runs as the
// system user `turingos`, which can't reach /run/user/<uid>. Like
// shell-helper, only root and `turingos` may connect.

use crate::{gfx, rpc, state, AppRef, VERSION};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::mpsc;

/// Largest line a page may send: a prompt, not a file
const MAX_FRAME: usize = 256 * 1024;

pub fn session_dir() -> PathBuf {
    std::env::var_os("TURINGOS_SESSION_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/run/turingos/session".into())
}

/// The uid of a user from /etc/passwd
fn uid_of(user: &str) -> Option<u32> {
    std::fs::read_to_string("/etc/passwd")
        .ok()?
        .lines()
        .find(|l| l.starts_with(&format!("{user}:")))
        .and_then(|l| l.split(':').nth(2)?.parse().ok())
}

/// root and the bridge's system user. On a dev machine without a `turingos`
/// user, our own uid too: nothing to protect there. TURINGOS_DESKTOP_ALLOW_UIDS
/// overrides (tests).
fn allowed_uids(own: u32) -> Vec<u32> {
    if let Ok(list) = std::env::var("TURINGOS_DESKTOP_ALLOW_UIDS") {
        return list
            .split(',')
            .filter_map(|u| u.trim().parse().ok())
            .collect();
    }
    vec![0, uid_of("turingos").unwrap_or(own)]
}

pub async fn listen(app: AppRef) -> std::io::Result<()> {
    let dir = session_dir();
    // Our uid, without a libc call: whoever owns a file we just made
    let probe = dir.join(format!(".turingosd-{}", std::process::id()));
    std::fs::write(&probe, b"")?;
    let own = {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(&probe)?.uid()
    };
    let _ = std::fs::remove_file(&probe);

    let path = dir.join(format!("{own}.desktop.sock"));
    // Left behind by a service that was killed
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    {
        use std::os::unix::fs::PermissionsExt;
        // The bridge must be able to connect; the peer's uid decides
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666))?;
    }
    let allowed = allowed_uids(own);
    eprintln!("turingosd: listening on {}", path.display());
    loop {
        let (stream, _) = listener.accept().await?;
        let uid = stream.peer_cred().map(|c| c.uid()).ok();
        if !uid.is_some_and(|u| allowed.contains(&u)) {
            eprintln!("turingosd: refused a connection from uid {uid:?}");
            continue;
        }
        tokio::spawn(serve(app.clone(), stream));
    }
}

/// A page message: `type`, `id` and `data`. Anything else in the frame is
/// ignored, and a frame without a `type` is not a message at all.
#[derive(Debug, PartialEq)]
pub struct Frame {
    pub kind: String,
    pub id: Option<String>,
    pub data: Value,
}

impl Frame {
    pub fn parse(text: &str) -> Option<Self> {
        let mut v: Value = serde_json::from_str(text).ok()?;
        let kind = v.get("type")?.as_str()?.to_string();
        let id = v.get("id").and_then(Value::as_str).map(str::to_string);
        let data = v.get_mut("data").map(Value::take).unwrap_or(Value::Null);
        Some(Self { kind, id, data })
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Numbers this connection's outgoing messages
struct Outbox {
    seq: u64,
}

impl Outbox {
    fn envelope(&mut self, kind: &str, re: Option<&str>, data: Value) -> String {
        self.seq += 1;
        json!({
            "v": 1,
            "type": kind,
            "id": format!("s-{}", self.seq),
            "re": re,
            "seq": self.seq,
            "ts": now_ms(),
            "data": data,
        })
        .to_string()
    }
}

async fn serve(app: AppRef, stream: UnixStream) {
    app.connections
        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read);
    let mut out = Outbox { seq: 0 };
    let mut events = app.events.subscribe();
    // Answers from calls still running when the next message arrives
    let (reply_tx, mut reply_rx) = mpsc::channel::<(String, Value)>(32);
    let mut greeted = false;
    let mut dropped = 0u32;
    let mut buf = String::new();

    loop {
        let frame = tokio::select! {
            read = read_line(&mut lines, &mut buf) => match read {
                Ok(true) => match Frame::parse(&buf) {
                    Some(frame) => match frame.kind.as_str() {
                        "hello" => {
                            greeted = true;
                            let hello = json!({
                                "version": VERSION,
                                "gfx": gfx::hint(&crate::runtime_dir()),
                                "safe": false,
                            });
                            let first = out.envelope("hello", frame.id.as_deref(), hello);
                            if send(&mut write, &first).await.is_err() {
                                break;
                            }
                            out.envelope("state", None, state::snapshot(&app.shared))
                        }
                        "ping" => out.envelope("pong", frame.id.as_deref(), json!({})),
                        "rpc" => {
                            let (app, tx) = (app.clone(), reply_tx.clone());
                            tokio::spawn(async move {
                                let method = frame.data["method"].as_str().unwrap_or("");
                                let data = match rpc::call(&app, method, &frame.data["params"]).await {
                                    Ok(result) => json!({ "ok": true, "result": result }),
                                    Err(error) => json!({ "ok": false, "error": error }),
                                };
                                let _ = tx.send((frame.id.unwrap_or_default(), data)).await;
                            });
                            continue;
                        }
                        // A newer page: not ours to understand
                        _ => continue,
                    },
                    None => {
                        dropped += 1;
                        continue;
                    }
                },
                // Too long, or not text: drop it and carry on
                Err(LineError::Bad) => {
                    dropped += 1;
                    continue;
                }
                Ok(false) | Err(LineError::Closed) => break,
            },
            Some((re, data)) = reply_rx.recv() => out.envelope("rpc_result", Some(&re), data),
            event = events.recv() => match event {
                Ok((kind, data)) if greeted => out.envelope(kind, None, data),
                Ok(_) => continue,
                // Fell behind: whatever was missed, the current state replaces it
                Err(RecvError::Lagged(_)) if greeted => {
                    out.envelope("state", None, state::snapshot(&app.shared))
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            },
        };
        if send(&mut write, &frame).await.is_err() {
            break;
        }
    }
    if dropped > 0 {
        eprintln!("turingosd: dropped {dropped} unreadable frame(s) from a page");
    }
}

enum LineError {
    Bad,
    Closed,
}

/// The next line into `buf`, without its newline. Ok(false) at end of stream.
async fn read_line(
    lines: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    buf: &mut String,
) -> Result<bool, LineError> {
    buf.clear();
    let mut raw = Vec::new();
    loop {
        let chunk = lines.fill_buf().await.map_err(|_| LineError::Closed)?;
        if chunk.is_empty() {
            return if raw.is_empty() {
                Ok(false)
            } else {
                Err(LineError::Bad)
            };
        }
        let (part, done) = match chunk.iter().position(|b| *b == b'\n') {
            Some(i) => (&chunk[..i], Some(i + 1)),
            None => (chunk, None),
        };
        let too_long = raw.len() + part.len() > MAX_FRAME;
        if !too_long {
            raw.extend_from_slice(part);
        }
        let used = done.unwrap_or(chunk.len());
        lines.consume(used);
        if too_long {
            // Skip the rest of this line, then report it
            if done.is_none() {
                loop {
                    let chunk = lines.fill_buf().await.map_err(|_| LineError::Closed)?;
                    if chunk.is_empty() {
                        break;
                    }
                    match chunk.iter().position(|b| *b == b'\n') {
                        Some(i) => {
                            lines.consume(i + 1);
                            break;
                        }
                        None => {
                            let n = chunk.len();
                            lines.consume(n);
                        }
                    }
                }
            }
            return Err(LineError::Bad);
        }
        if done.is_some() {
            *buf = String::from_utf8(raw).map_err(|_| LineError::Bad)?;
            return Ok(true);
        }
    }
}

async fn send(write: &mut tokio::net::unix::OwnedWriteHalf, frame: &str) -> std::io::Result<()> {
    write.write_all(frame.as_bytes()).await?;
    write.write_all(b"\n").await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn fixture(name: &str) -> String {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../protocol/v1/fixtures")
            .join(name);
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
    }

    #[test]
    fn reads_every_page_fixture() {
        let hello = Frame::parse(&fixture("page.hello.json")).unwrap();
        assert_eq!(hello.kind, "hello");
        assert_eq!(hello.data["last_seq"], Value::Null);
        let resume = Frame::parse(&fixture("page.hello.resume.json")).unwrap();
        assert_eq!(resume.data["last_seq"], 412);

        let rpc = Frame::parse(&fixture("page.rpc.json")).unwrap();
        assert_eq!((rpc.kind.as_str(), rpc.id.as_deref()), ("rpc", Some("p-2")));
        assert_eq!(rpc.data["method"], "agent_start");
        assert_eq!(rpc.data["params"]["task"], "Run the tests");

        assert_eq!(
            Frame::parse(&fixture("page.ping.json")).unwrap().kind,
            "ping"
        );
    }

    #[test]
    fn unreadable_frames_are_not_messages() {
        assert_eq!(Frame::parse("not json"), None);
        assert_eq!(Frame::parse("{}"), None);
        assert_eq!(Frame::parse(r#"{"type":7}"#), None);
        // No id and no data is still a message; the caller decides what to do
        let bare = Frame::parse(r#"{"type":"ping"}"#).unwrap();
        assert_eq!((bare.id, bare.data), (None, Value::Null));
    }

    /// Ours and the fixture's envelopes carry the same fields
    #[test]
    fn envelopes_match_the_service_fixtures() {
        let mut out = Outbox { seq: 0 };
        let ours: Value =
            serde_json::from_str(&out.envelope("pong", Some("p-3"), json!({}))).unwrap();
        let theirs: Value = serde_json::from_str(&fixture("service.pong.json")).unwrap();
        let keys = |v: &Value| {
            let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
            k.sort();
            k
        };
        assert_eq!(keys(&ours), keys(&theirs));
        assert_eq!(
            (&ours["v"], &ours["type"], &ours["re"]),
            (&theirs["v"], &theirs["type"], &theirs["re"])
        );
        assert_eq!(ours["seq"], 1);
        let next: Value = serde_json::from_str(&out.envelope("state", None, json!({}))).unwrap();
        assert_eq!((next["seq"].as_u64(), &next["re"]), (Some(2), &Value::Null));
    }
}
