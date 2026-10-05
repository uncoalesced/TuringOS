#!/usr/bin/env python3
"""bridged-ws /shell (Phase 3 fallback): only the bridge's own localhost page
may open it; commands get output, exit code, a timeout and an output cap.

    python3 -m unittest trust/tests/test_bridge_shell.py   (needs fastapi, httpx)
"""
import asyncio
import importlib.util
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


class Defaults(unittest.TestCase):
    def test_binds_loopback_by_default(self):
        src = (Path(__file__).parent.parent / "daemons" / "bridged-ws.py").read_text()
        self.assertIn('parser.add_argument("--host", default="127.0.0.1")', src)


if __name__ == "__main__":
    unittest.main()
