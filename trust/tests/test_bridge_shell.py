#!/usr/bin/env python3
"""bridged-ws /shell (Phase 3 fallback): only the bridge's own localhost page
may open it; commands get output, exit code, a timeout and an output cap.
Also covers where the bridge finds the UI (APP_DIR).

    python3 -m unittest trust/tests/test_bridge_shell.py   (needs fastapi, httpx)
"""
import asyncio
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

spec = importlib.util.spec_from_file_location(
    "bridged_ws", Path(__file__).parent.parent / "daemons" / "bridged-ws.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def connect(host: str, origin: str):
    return TestClient(bridge.app).websocket_connect(
        "/shell", headers={"host": host, "origin": origin}
    )


class ShellOrigin(unittest.TestCase):
    def test_own_page_runs_a_command(self):
        with connect("localhost:8080", "http://localhost:8080") as ws:
            ws.send_json({"command": "echo hi"})
            res = ws.receive_json()
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["code"], 0)
        self.assertEqual(res["output"].strip(), "hi")

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


class RunShell(unittest.TestCase):
    def test_exit_code_and_stderr(self):
        res = asyncio.run(bridge.run_shell("echo out; echo err >&2; exit 3"))
        self.assertEqual(res["code"], 3)
        self.assertEqual(res["output"].replace("\r", ""), "out\nerr\n")

    def test_timeout(self):
        res = asyncio.run(bridge.run_shell("sleep 30", timeout=1))
        self.assertEqual(res["code"], 124)
        self.assertTrue(res["output"].endswith("[stopped after 1s]"))

    def test_output_cap(self):
        res = asyncio.run(bridge.run_shell("yes", timeout=10))
        self.assertTrue(res["output"].endswith("[output truncated at 64 KB]"))
        self.assertLess(len(res["output"]), bridge.SHELL_MAX_OUTPUT + 64)


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
