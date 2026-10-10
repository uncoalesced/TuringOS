// End to end: start the built turingosd with a throwaway HOME, runtime dir
// and session drop-box, and talk to its desktop socket the way
// turingos-bridged-ws does for a page: one JSON message per line.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;

struct Service {
    child: Child,
    dir: PathBuf,
}

impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn fixture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../protocol/v1/fixtures")
        .join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

impl Service {
    async fn start(name: &str, allow: Option<&str>) -> Self {
        // Short: a Unix socket path has about 100 bytes to live in
        let dir = std::env::temp_dir().join(format!("tosd-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let run = dir.join("r").join("turingos");
        for d in [dir.join("home"), dir.join("s"), run.clone()] {
            std::fs::create_dir_all(d).unwrap();
        }
        // What session/turingos-gfx-detect leaves for a VM without 3D
        std::fs::write(run.join("gfx.env"), "GFX_PATH=sw\nGFX_TIER=lite\n").unwrap();

        let mut cmd = Command::new(env!("CARGO_BIN_EXE_turingosd"));
        cmd.env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", dir.join("home"))
            .env("XDG_RUNTIME_DIR", dir.join("r"))
            .env("TURINGOS_SESSION_DIR", dir.join("s"))
            .stdin(Stdio::null());
        if let Some(allow) = allow {
            cmd.env("TURINGOS_DESKTOP_ALLOW_UIDS", allow);
        }
        let service = Self {
            child: cmd.spawn().expect("start turingosd"),
            dir,
        };
        // A freshly linked binary can take seconds to start on macOS
        for _ in 0..300 {
            if service.socket_path().is_some() && service.run_dir().join("control.sock").exists() {
                return service;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("turingosd made no desktop socket");
    }

    fn run_dir(&self) -> PathBuf {
        self.dir.join("r").join("turingos")
    }

    /// <uid>.desktop.sock in the drop-box
    fn socket_path(&self) -> Option<PathBuf> {
        std::fs::read_dir(self.dir.join("s"))
            .ok()?
            .flatten()
            .map(|e| e.path())
            .find(|p| p.to_string_lossy().ends_with(".desktop.sock"))
    }

    async fn connect(&self) -> Page {
        let stream = UnixStream::connect(self.socket_path().unwrap())
            .await
            .unwrap();
        let (read, write) = stream.into_split();
        Page {
            lines: BufReader::new(read),
            write,
        }
    }

    /// One request over the control socket; the response body as JSON
    async fn control(&self, method: &str, path: &str) -> Value {
        let mut stream = UnixStream::connect(self.run_dir().join("control.sock"))
            .await
            .expect("control socket");
        let request = format!(
            "{method} {path} HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        let body = response.split("\r\n\r\n").nth(1).unwrap_or("");
        serde_json::from_str(body).unwrap_or_else(|e| panic!("control {path}: {e}: {response}"))
    }
}

struct Page {
    lines: BufReader<OwnedReadHalf>,
    write: OwnedWriteHalf,
}

impl Page {
    async fn send(&mut self, line: &str) {
        self.write
            .write_all(line.trim_end().as_bytes())
            .await
            .unwrap();
        self.write.write_all(b"\n").await.unwrap();
    }

    /// The next message of this type; `state` pushes in between are skipped
    async fn next_of(&mut self, kind: &str) -> Value {
        let wait = async {
            loop {
                let mut line = String::new();
                assert!(
                    self.lines.read_line(&mut line).await.unwrap() > 0,
                    "socket closed"
                );
                let msg: Value = serde_json::from_str(&line).unwrap();
                if msg["type"] == kind {
                    return msg;
                }
            }
        };
        tokio::time::timeout(Duration::from_secs(5), wait)
            .await
            .unwrap_or_else(|_| panic!("no `{kind}` within 5 s"))
    }

    async fn call(&mut self, id: &str, method: &str, params: Value) -> Value {
        let frame = json!({ "v": 1, "type": "rpc", "id": id, "re": null, "ts": 0,
                            "data": { "method": method, "params": params } });
        self.send(&frame.to_string()).await;
        loop {
            let msg = self.next_of("rpc_result").await;
            if msg["re"] == id {
                return msg["data"].clone();
            }
        }
    }
}

#[tokio::test]
async fn a_page_conversation() {
    let service = Service::start("page", None).await;

    {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        // The bridge (another user) must reach it; the peer check guards it
        assert_eq!(mode(&service.socket_path().unwrap()), 0o666);
        assert_eq!(mode(&service.run_dir().join("control.sock")), 0o600);
    }

    let mut page = service.connect().await;
    page.send(&fixture("page.hello.json")).await;
    let hello = page.next_of("hello").await;
    assert_eq!(
        (&hello["v"], &hello["re"], &hello["seq"]),
        (&json!(1), &json!("p-1"), &json!(1))
    );
    assert_eq!(
        hello["data"]["gfx"],
        json!({ "path": "sw", "tier": "lite" })
    );
    assert_eq!(hello["data"]["version"], env!("CARGO_PKG_VERSION"));

    let state = page.next_of("state").await;
    assert_eq!(state["seq"], 2);
    let snap = &state["data"];
    // Same fields as the fixture the page's tests read
    let expected: Value = serde_json::from_str(&fixture("service.state.json")).unwrap();
    for key in expected["data"].as_object().unwrap().keys() {
        assert!(snap.get(key).is_some(), "snapshot has no `{key}`");
    }
    assert_eq!(snap["live"], false, "this HOME has no ~/.turingos");
    assert_eq!(
        snap["calendar"],
        json!({ "connected": false, "nextEvent": null })
    );

    page.send(&fixture("page.ping.json")).await;
    assert_eq!(page.next_of("pong").await["re"], "p-3");

    let got = page.call("p-10", "state_get", json!({})).await;
    assert_eq!(got["ok"], true);
    assert!(got["result"]["system"]["host"].is_string());

    let got = page.call("p-11", "nope", json!({})).await;
    assert_eq!(got, json!({ "ok": false, "error": "Unknown method: nope" }));
    let got = page.call("p-12", "dock_launch", json!({})).await;
    assert_eq!(got, json!({ "ok": false, "error": "Missing argument: id" }));

    // The call was made; the method itself says no
    let got = page
        .call(
            "p-13",
            "agent_start",
            json!({ "project": "/etc", "task": "anything", "model": null }),
        )
        .await;
    assert_eq!(
        (&got["ok"], &got["result"]["ok"]),
        (&json!(true), &json!(false))
    );
    let got = page
        .call(
            "p-14",
            "open_external",
            json!({ "url": "file:///etc/passwd" }),
        )
        .await;
    assert_eq!(got, json!({ "ok": true, "result": false }));
    let got = page.call("p-15", "projects_list", json!({})).await;
    assert_eq!(got, json!({ "ok": true, "result": [] }));

    // Rubbish on the wire costs nothing: the next message is still answered
    for junk in ["not json", "{}", r#"{"type":"from-the-future","data":{}}"#] {
        page.send(junk).await;
    }
    page.write.write_all(&[0xff, 0xfe, b'\n']).await.unwrap();
    page.send(&"x".repeat(300 * 1024)).await;
    let got = page
        .call(
            "p-16",
            "gfx_report",
            json!({ "tier": "lite", "p90_ms": 31.5, "samples": 240 }),
        )
        .await;
    assert_eq!(got, json!({ "ok": true, "result": { "ok": true } }));

    // Super+Space arrives over the control socket and reaches the page
    let pressed = service.control("POST", "/omni").await;
    assert_eq!(pressed, json!({ "ok": true, "pages": 1 }));
    assert_eq!(page.next_of("omni").await["data"], json!({ "open": true }));

    let status = service.control("GET", "/status").await;
    assert_eq!(status["pages"], 1);
    assert_eq!(
        (&status["connections"], &status["omni_presses"]),
        (&json!(1), &json!(1))
    );
    assert_eq!(status["gfx"]["tier"], "lite");
    assert_eq!(status["gfx_report"]["p90_ms"], 31.5);
}

/// Only root and the bridge's user may connect; anyone else is hung up on
#[tokio::test]
async fn strangers_are_refused() {
    let service = Service::start("refuse", Some("0")).await;
    let mut page = service.connect().await;
    let hello = format!("{}\n", fixture("page.hello.json").trim());
    let _ = page.write.write_all(hello.as_bytes()).await;
    let mut line = String::new();
    let read = tokio::time::timeout(Duration::from_secs(5), page.lines.read_line(&mut line)).await;
    assert!(
        matches!(read, Ok(Ok(0)) | Ok(Err(_))),
        "a refused peer got an answer: {line}"
    );
}
