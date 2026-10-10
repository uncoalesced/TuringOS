#!/usr/bin/env python3
"""bridged-ws and the desktop page: /desktop copies frames to turingosd's
socket in the session drop-box and back; every WebSocket is closed to pages
the bridge didn't serve; /boot.js tells the page it is live; responses carry
the CSP the page is written for.

    python3 -m unittest trust/tests/test_bridge_desktop.py   (needs fastapi, httpx)
"""
import importlib.util
import json
import os
import shutil
import socket
import tempfile
import threading
import unittest
from pathlib import Path

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

spec = importlib.util.spec_from_file_location(
    "bridged_ws_desktop", Path(__file__).parent.parent / "daemons" / "bridged-ws.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

OWN = {"host": "localhost:8080", "origin": "http://localhost:8080"}


class FakeDesktop:
    """Stands in for turingosd: answers each line with {"echo": <line>},
    and sends one line of its own first, as turingosd's state push would."""

    def __init__(self, directory: str):
        self.path = Path(directory, f"{os.getuid()}.desktop.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen()
        self.received = []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.talk, args=(conn,), daemon=True).start()

    def talk(self, conn):
        with conn, conn.makefile("rwb") as f:
            f.write(b'{"type":"state","data":{"live":true}}\n')
            f.flush()
            for line in f:
                text = line.decode().rstrip("\n")
                self.received.append(text)
                f.write((json.dumps({"echo": text}) + "\n").encode())
                f.flush()

    def close(self):
        self.server.close()
        self.path.unlink(missing_ok=True)


class Desktop(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="tos-desk-")
        os.environ["TURINGOS_SESSION_DIR"] = self.dir
        self.client = TestClient(bridge.app)

    def tearDown(self):
        os.environ.pop("TURINGOS_SESSION_DIR", None)
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_frames_go_through_both_ways(self):
        desk = FakeDesktop(self.dir)
        try:
            with self.client.websocket_connect("/desktop", headers=OWN) as ws:
                self.assertEqual(json.loads(ws.receive_text())["type"], "state")
                hello = json.dumps({"v": 1, "type": "hello", "id": "p-1", "data": {"last_seq": None}})
                ws.send_text(hello)
                self.assertEqual(json.loads(ws.receive_text()), {"echo": hello})
                # A newline inside a frame must not split it into two messages
                ws.send_text('{"type":"ping",\n"id":"p-2"}')
                self.assertEqual(json.loads(ws.receive_text()), {"echo": '{"type":"ping", "id":"p-2"}'})
            self.assertEqual(len(desk.received), 2)
        finally:
            desk.close()

    def test_no_desktop_service_means_try_again(self):
        with self.client.websocket_connect("/desktop", headers=OWN) as ws:
            with self.assertRaises(WebSocketDisconnect) as closed:
                ws.receive_text()
        self.assertEqual(closed.exception.code, 1013)

    def test_shell_helper_socket_is_not_the_desktop(self):
        # <uid>.sock is shell-helper's; only *.desktop.sock counts
        Path(self.dir, f"{os.getuid()}.sock").touch()
        self.assertIsNone(bridge.desktop_socket())


class EveryWebSocketIsLocked(unittest.TestCase):
    """Browsers don't apply CORS to WebSockets: without the Origin check any
    site open in Brave could drive the agent or the desktop."""

    def test_other_sites_are_refused(self):
        client = TestClient(bridge.app)
        for path in ["/plan", "/agent", "/bridge", "/cap", "/memory", "/desktop", "/shell"]:
            for headers in (
                {"host": "localhost:8080", "origin": "https://evil.example"},
                {"host": "evil.example:8080", "origin": "http://evil.example:8080"},
                {"host": "localhost:8080"},
            ):
                with self.subTest(path=path, headers=headers):
                    with self.assertRaises(WebSocketDisconnect) as closed:
                        with client.websocket_connect(path, headers=headers) as ws:
                            ws.receive_text()
                    self.assertEqual(closed.exception.code, 1008)

    def test_own_page_gets_in(self):
        with TestClient(bridge.app).websocket_connect("/cap", headers=OWN) as ws:
            ws.send_text(json.dumps({"action": "nope"}))
            self.assertEqual(json.loads(ws.receive_text())["status"], "error")


class Page(unittest.TestCase):
    def test_boot_js_says_live_then_runs_the_pages_own(self):
        res = TestClient(bridge.app).get("/boot.js")
        self.assertEqual(res.status_code, 200)
        self.assertTrue(res.text.startswith("window.__TURINGOS__ = { v: 1 };\n"))
        self.assertIn("javascript", res.headers["content-type"])
        own = (bridge.APP_DIR / "boot.js").read_text()
        self.assertTrue(res.text.endswith(own))

    def test_every_response_carries_the_csp(self):
        client = TestClient(bridge.app)
        for path in ["/", "/health", "/boot.js", "/css/tokens.css"]:
            with self.subTest(path=path):
                res = client.get(path)
                self.assertEqual(res.status_code, 200)
                csp = res.headers["content-security-policy"]
                self.assertIn("script-src 'self';", csp)
                self.assertIn("connect-src 'self';", csp)
                self.assertNotIn("unsafe", csp)
                self.assertEqual(res.headers["x-content-type-options"], "nosniff")


if __name__ == "__main__":
    unittest.main()
