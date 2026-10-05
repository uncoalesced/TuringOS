#!/usr/bin/env python3
"""bridged-ws /shell (Phase 3 fallback): only the bridge's own localhost page
may open it; commands are forwarded to shell-helper.py so they run as the
login session's user, not as `turingos`. Also covers where the bridge finds
the UI (APP_DIR).

    python3 -m unittest trust/tests/test_bridge_shell.py   (needs fastapi, httpx)
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

spec = importlib.util.spec_from_file_location(
    "bridged_ws", Path(__file__).parent.parent / "daemons" / "bridged-ws.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

HELPER = Path(__file__).parent.parent / "daemons" / "shell-helper.py"
_helper_proc = None
_session_dir = None


def setUpModule():
    """A real shell-helper in a temp drop-box, so /shell forwards end to end."""
    global _helper_proc, _session_dir
    _session_dir = tempfile.mkdtemp(prefix="turingos-session-")
    os.environ["TURINGOS_SESSION_DIR"] = _session_dir
    os.environ["TURINGOS_SHELL_ALLOW_UIDS"] = str(os.getuid())
    _helper_proc = subprocess.Popen(
        [sys.executable, str(HELPER)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    sock = Path(_session_dir, f"{os.getuid()}.sock")
    deadline = time.monotonic() + 5
    while not sock.exists():
        if _helper_proc.poll() is not None:
            raise RuntimeError(
                "shell-helper exited %d: %s"
                % (_helper_proc.returncode, _helper_proc.stderr.read().decode())
            )
        if time.monotonic() > deadline:
            raise RuntimeError("shell-helper socket never appeared")
        time.sleep(0.05)


def tearDownModule():
    if _helper_proc and _helper_proc.poll() is None:
        _helper_proc.terminate()
        try:
            _helper_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _helper_proc.kill()
            _helper_proc.wait()
    if _helper_proc and _helper_proc.stderr:
        _helper_proc.stderr.close()
    if _session_dir:
        shutil.rmtree(_session_dir, ignore_errors=True)
    os.environ.pop("TURINGOS_SESSION_DIR", None)
    os.environ.pop("TURINGOS_SHELL_ALLOW_UIDS", None)


def connect(host: str, origin: str):
    return TestClient(bridge.app).websocket_connect(
        "/shell", headers={"host": host, "origin": origin}
    )


class ShellOrigin(unittest.TestCase):
    def test_own_page_runs_a_command_in_the_session(self):
        with connect("localhost:8080", "http://localhost:8080") as ws:
            ws.send_json({"command": "echo hi"})
            res = ws.receive_json()
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["code"], 0)
        self.assertEqual(res["output"].strip(), "hi")

    def test_own_page_sees_the_session_user(self):
        with connect("localhost:8080", "http://localhost:8080") as ws:
            ws.send_json({"command": "id -u"})
            res = ws.receive_json()
        self.assertEqual(res["output"].strip(), str(os.getuid()))

    def test_no_helper_gives_a_clear_error(self):
        empty = tempfile.mkdtemp(prefix="turingos-empty-")
        self.addCleanup(shutil.rmtree, empty, ignore_errors=True)
        saved = os.environ.pop("TURINGOS_SESSION_DIR", None)
        os.environ["TURINGOS_SESSION_DIR"] = empty
        try:
            with connect("localhost:8080", "http://localhost:8080") as ws:
                ws.send_json({"command": "echo hi"})
                res = ws.receive_json()
        finally:
            if saved is not None:
                os.environ["TURINGOS_SESSION_DIR"] = saved
        self.assertEqual(res["status"], "error")
        self.assertIn("shell helper", res["errors"][0])

    def test_other_site_is_refused(self):
        with self.assertRaises(WebSocketDisconnect):
            with connect("localhost:8080", "https://evil.example") as ws:
                ws.receive_json()

    def test_missing_origin_is_refused(self):
        with self.assertRaises(WebSocketDisconnect):
            with connect("localhost:8080", "") as ws:
                ws.receive_json()

    def test_dns_rebinding_is_refused(self):
        with self.assertRaises(WebSocketDisconnect):
            with connect("evil.example:8080", "http://evil.example:8080") as ws:
                ws.receive_json()

    def test_empty_command(self):
        with connect("127.0.0.1:8080", "http://127.0.0.1:8080") as ws:
            ws.send_json({"command": "  "})
            self.assertEqual(ws.receive_json()["status"], "error")


class ServesUi(unittest.TestCase):
    """The page loads css/ and js/ relative to /, so the bridge must serve
    them there; otherwise reconnect.js (the "Reconnecting..." overlay) never
    loads. /health and the WebSocket routes must still win over the mount."""

    def test_page_and_assets(self):
        client = TestClient(bridge.app)
        self.assertEqual(client.get("/").status_code, 200)
        self.assertIn("js/reconnect.js", client.get("/").text)
        self.assertEqual(client.get("/js/reconnect.js").status_code, 200)
        self.assertEqual(client.get("/css/base.css").status_code, 200)
        self.assertEqual(client.get("/health").json(), {"status": "ok"})

    def test_env_override_wins(self):
        """TURINGOS_UI_DIR points the bridge at any tree (installed or not)."""
        self.addCleanup(spec.loader.exec_module, bridge)  # restore for other tests
        with tempfile.TemporaryDirectory() as ui:
            Path(ui, "index.html").write_text("<html>override</html>")
            os.environ["TURINGOS_UI_DIR"] = ui
            try:
                spec.loader.exec_module(bridge)
            finally:
                del os.environ["TURINGOS_UI_DIR"]
            self.assertEqual(bridge.APP_DIR, Path(ui))
            self.assertIn("override", TestClient(bridge.app).get("/").text)

    def test_default_is_the_installed_path_or_the_checkout(self):
        src = (Path(__file__).parent.parent / "daemons" / "bridged-ws.py").read_text()
        self.assertIn('"/usr/lib/turingos/ui/web"', src)
        self.assertIn("TURINGOS_UI_DIR", src)


class Defaults(unittest.TestCase):
    def test_binds_loopback_by_default(self):
        src = (Path(__file__).parent.parent / "daemons" / "bridged-ws.py").read_text()
        self.assertIn('parser.add_argument("--host", default="127.0.0.1")', src)


if __name__ == "__main__":
    unittest.main()
