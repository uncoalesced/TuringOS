#!/usr/bin/env python3
"""Local-access hardening: bridged's egress policy is the server's, not the
caller's; the bridge only trusts pages from a logged-in user's own processes
and only helper sockets owned by the uid in their name; shell-helper refuses
peers it cannot identify; a rejected plan stays rejected and a plan runs once.

    python3 -m unittest trust/tests/test_local_auth.py   (needs fastapi, httpx)
"""
import asyncio
import http.server
import importlib.util
import json
import os
import shutil
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

DAEMONS = Path(__file__).parent.parent / "daemons"


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, DAEMONS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridged = load("bridged_local_auth", "bridged.py")
bridge = load("bridged_ws_local_auth", "bridged-ws.py")
helper = load("shell_helper_local_auth", "shell-helper.py")
planner = load("agentd_plan_local_auth", "agentd-plan.py")


class BridgedEgress(unittest.TestCase):
    def test_allowlist_belongs_to_the_server(self):
        self.assertEqual(bridged.server_allowlist(), bridged.DEFAULT_ALLOWLIST)
        with mock.patch.dict(os.environ, {"TURINGOS_BRIDGE_ALLOWLIST": "a.example, b.example"}):
            self.assertEqual(
                bridged.server_allowlist(),
                bridged.DEFAULT_ALLOWLIST + ["a.example", "b.example"],
            )

    def test_empty_domain_never_matches(self):
        self.assertFalse(bridged.is_allowed("", [""]))
        self.assertFalse(bridged.is_allowed("", bridged.DEFAULT_ALLOWLIST))

    def test_only_http_and_https(self):
        res = bridged.fetch_url("file:///etc/passwd", [""])
        self.assertEqual(res["status"], "error")
        self.assertIn("scheme", res["errors"][0])

    def test_unlisted_domain_refused(self):
        res = bridged.fetch_url("http://evil.example/", bridged.DEFAULT_ALLOWLIST)
        self.assertIn("allowlist", res["errors"][0])

    def test_allowed_name_cannot_reach_loopback(self):
        res = bridged.fetch_url("http://127.0.0.1:9/", ["127.0.0.1"])
        self.assertEqual(res["status"], "error")
        self.assertIn("non-public", res["errors"][0])

    def test_client_cannot_widen_the_allowlist(self):
        a, b = socket.socketpair()
        try:
            req = {"action": "fetch", "url": "http://127.0.0.1:1/", "allowlist": ["127.0.0.1"]}
            a.sendall(json.dumps(req).encode() + b"\n")
            bridged.handle_client(b)
            reply = json.loads(a.recv(65536).decode())
        finally:
            a.close()
        self.assertEqual(reply["status"], "error")
        self.assertIn("allowlist", reply["errors"][0])

    def _serve(self, handler_cls):
        server = http.server.HTTPServer(("127.0.0.1", 0), handler_cls)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server.server_address[1]

    def test_redirects_are_not_followed(self):
        class Redirect(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "http://other.invalid/")
                self.end_headers()

            def log_message(self, *args):
                pass

        port = self._serve(Redirect)
        # the test server is on loopback; skip only the address check
        with mock.patch.object(bridged, "resolves_to_private", return_value=False):
            res = bridged.fetch_url(f"http://127.0.0.1:{port}/", ["127.0.0.1"])
        self.assertEqual(res["status"], "error")

    def test_plain_page_comes_back_untrusted(self):
        class Page(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"hello")

            def log_message(self, *args):
                pass

        port = self._serve(Page)
        with mock.patch.object(bridged, "resolves_to_private", return_value=False):
            res = bridged.fetch_url(f"http://127.0.0.1:{port}/", ["127.0.0.1"])
        self.assertEqual((res["status"], res["content"], res["taint"]), ("ok", "hello", "untrusted"))


class SessionSockets(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="tos-auth-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        env = mock.patch.dict(os.environ, {"TURINGOS_SESSION_DIR": self.dir})
        env.start()
        self.addCleanup(env.stop)

    def bind(self, name: str):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(str(Path(self.dir, name)))
        self.addCleanup(s.close)

    def test_shell_and_desktop_are_told_apart(self):
        uid = os.getuid()
        self.bind(f"{uid}.sock")
        self.bind(f"{uid}.desktop.sock")
        shell = bridge.session_socks("shell")
        desktop = bridge.session_socks("desktop")
        self.assertEqual([u for u, _ in shell], [uid])
        self.assertEqual([u for u, _ in desktop], [uid])
        self.assertEqual(shell[0][1].name, f"{uid}.sock")
        self.assertEqual(desktop[0][1].name, f"{uid}.desktop.sock")

    def test_a_socket_named_for_someone_else_is_ignored(self):
        # the drop-box is world-writable: owner must match the uid in the name
        self.bind(f"{os.getuid() + 1}.sock")
        self.bind(f"{os.getuid() + 1}.desktop.sock")
        self.bind("notauid.sock")
        self.assertEqual(bridge.session_socks("shell"), [])
        self.assertEqual(bridge.session_socks("desktop"), [])

    def test_a_plain_file_is_not_a_socket(self):
        Path(self.dir, f"{os.getuid()}.sock").touch()
        self.assertEqual(bridge.session_socks("shell"), [])


@unittest.skipUnless(os.path.exists("/proc/net/tcp"), "needs the Linux socket table")
class TcpPeer(unittest.TestCase):
    def test_finds_the_uid_of_a_loopback_client(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        self.addCleanup(server.close)
        client = socket.create_connection(server.getsockname())
        self.addCleanup(client.close)
        conn, _ = server.accept()
        self.addCleanup(conn.close)
        self.assertEqual(bridge.tcp_peer_uid("127.0.0.1", client.getsockname()[1]), os.getuid())

    def test_unknown_connection_is_unknown(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        self.assertIsNone(bridge.tcp_peer_uid("127.0.0.1", port))

    def test_non_loopback_and_junk_are_unknown(self):
        self.assertIsNone(bridge.tcp_peer_uid("8.8.8.8", 443))
        self.assertIsNone(bridge.tcp_peer_uid("testclient", 50000))


class PeerGate(unittest.TestCase):
    OWN = {"host": "localhost:8080", "origin": "http://localhost:8080"}

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="tos-peer-")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        env = mock.patch.dict(os.environ, {"TURINGOS_SESSION_DIR": self.dir})
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("TURINGOS_BRIDGE_PEER_CHECK", None)
        os.environ.pop("TURINGOS_BRIDGE_ALLOW_UIDS", None)

    def ws(self):
        return SimpleNamespace(headers=dict(self.OWN), client=SimpleNamespace(host="127.0.0.1", port=40000))

    def login(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(str(Path(self.dir, f"{os.getuid()}.sock")))
        self.addCleanup(s.close)

    def test_same_user_gets_in(self):
        self.login()
        with mock.patch.object(bridge, "tcp_peer_uid", return_value=os.getuid()):
            self.assertTrue(bridge.origin_allowed(self.ws()))

    def test_another_user_is_refused_despite_good_headers(self):
        self.login()
        with mock.patch.object(bridge, "tcp_peer_uid", return_value=os.getuid() + 1):
            self.assertFalse(bridge.origin_allowed(self.ws()))

    def test_unidentifiable_peer_is_refused(self):
        self.login()
        with mock.patch.object(bridge, "tcp_peer_uid", return_value=None):
            self.assertFalse(bridge.origin_allowed(self.ws()))

    def test_no_session_yet_has_nothing_to_match(self):
        with mock.patch.object(bridge, "tcp_peer_uid", return_value=None):
            self.assertTrue(bridge.peer_allowed(self.ws()))

    def test_check_can_be_switched_off(self):
        self.login()
        with mock.patch.dict(os.environ, {"TURINGOS_BRIDGE_PEER_CHECK": "0"}):
            with mock.patch.object(bridge, "tcp_peer_uid", return_value=None):
                self.assertTrue(bridge.peer_allowed(self.ws()))

    def test_bad_headers_still_refused(self):
        ws = self.ws()
        ws.headers["origin"] = "http://evil.example"
        with mock.patch.dict(os.environ, {"TURINGOS_BRIDGE_PEER_CHECK": "0"}):
            self.assertFalse(bridge.origin_allowed(ws))


@unittest.skipUnless(hasattr(socket, "SO_PEERCRED"), "needs SO_PEERCRED")
class ShellHelperPeer(unittest.TestCase):
    def test_unidentifiable_peer_may_not_run_commands(self):
        async def go():
            d = tempfile.mkdtemp(prefix="tos-sh-")
            path = os.path.join(d, "h.sock")
            try:
                with mock.patch.object(helper, "peer_uid", return_value=-1):
                    server = await asyncio.start_unix_server(helper.handle, path=path)
                    async with server:
                        reader, writer = await asyncio.open_unix_connection(path)
                        writer.write(b'{"command": "echo hi"}\n')
                        await writer.drain()
                        reply = json.loads((await reader.readline()).decode())
                        writer.close()
                return reply
            finally:
                shutil.rmtree(d, ignore_errors=True)

        reply = asyncio.run(go())
        self.assertEqual(reply["status"], "error")
        self.assertIn("refusing", reply["errors"][0])


class PlanLifecycle(unittest.TestCase):
    def fresh(self):
        store = planner.PlanStore()
        return store, store.create("sess", "do a thing", [])

    def test_rejected_plan_stays_rejected(self):
        async def go():
            store, plan = self.fresh()
            self.assertEqual(store.reject(plan["plan_id"], "sess")["status"], "ok")
            self.assertEqual(plan["status"], "rejected")
            self.assertEqual(store.approve(plan["plan_id"], "sess")["status"], "error")
            self.assertIsNone(store.get_approved_plan(plan["plan_id"]))
            return (await planner.execute_plan(plan))["status"]

        self.assertEqual(asyncio.run(go()), "error")

    def test_approved_plan_runs_once(self):
        async def go():
            store, plan = self.fresh()
            self.assertEqual(store.approve(plan["plan_id"], "sess")["status"], "ok")
            self.assertEqual(store.reject(plan["plan_id"], "sess")["status"], "error")
            first = await planner.execute_plan(plan)
            second = await planner.execute_plan(plan)
            return first["status"], second["status"], plan["status"]

        self.assertEqual(asyncio.run(go()), ("ok", "error", "completed"))

    def test_unknown_plan(self):
        store = planner.PlanStore()
        self.assertEqual(store.reject("nope", "sess")["status"], "error")


if __name__ == "__main__":
    unittest.main()
