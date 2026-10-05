#!/usr/bin/env python3
"""shell-helper.py: /shell commands run as the login session's user, and only
the bridge (SO_PEERCRED: root or `turingos`) may submit them. Owns the 60s
timeout and 64 KB output cap that /shell used to enforce.

    python3 -m unittest trust/tests/test_shell_helper.py   (stdlib only)
"""
import asyncio
import importlib.util
import json
import os
import pwd
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HELPER_PATH = Path(__file__).parent.parent / "daemons" / "shell-helper.py"
spec = importlib.util.spec_from_file_location("shell_helper", HELPER_PATH)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def stop(proc: subprocess.Popen):
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    if proc.stderr:
        proc.stderr.close()


def request(sock: Path, command: str) -> dict:
    """One request per connection: write a JSON line, read until close."""
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(str(sock))
        s.sendall((json.dumps({"command": command}) + "\n").encode())
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode())


class RunShell(unittest.TestCase):
    """Execution budget, moved here from test_bridge_shell.py."""

    def test_exit_code_and_stderr(self):
        res = asyncio.run(helper.run_shell("echo out; echo err >&2; exit 3"))
        self.assertEqual(res["code"], 3)
        self.assertEqual(res["output"].replace("\r", ""), "out\nerr\n")

    def test_timeout(self):
        res = asyncio.run(helper.run_shell("sleep 30", timeout=1))
        self.assertEqual(res["code"], 124)
        self.assertTrue(res["output"].endswith("[stopped after 1s]"))

    def test_output_cap(self):
        res = asyncio.run(helper.run_shell("yes", timeout=10))
        self.assertTrue(res["output"].endswith("[output truncated at 64 KB]"))
        self.assertLess(len(res["output"]), helper.SHELL_MAX_OUTPUT + 64)


class AllowedUids(unittest.TestCase):
    def test_default_allows_root_and_the_bridge(self):
        uids = helper.allowed_uids()
        self.assertIn(0, uids)
        try:
            bridge_uid = pwd.getpwnam("turingos").pw_uid
        except KeyError:
            bridge_uid = os.getuid()  # dev machine: no system user yet
        self.assertIn(bridge_uid, uids)

    def test_override_is_a_uid_list(self):
        self.addCleanup(os.environ.pop, "TURINGOS_SHELL_ALLOW_UIDS", None)
        os.environ["TURINGOS_SHELL_ALLOW_UIDS"] = "7, 9"
        self.assertEqual(helper.allowed_uids(), {7, 9})


class HelperSocket(unittest.TestCase):
    """End to end over the session socket, as turingos-bridged-ws sees it."""

    def start(self, **env) -> Path:
        session = tempfile.mkdtemp(prefix="turingos-session-")
        self.addCleanup(shutil.rmtree, session, ignore_errors=True)
        child_env = {
            **os.environ,
            "TURINGOS_SESSION_DIR": session,
            "TURINGOS_SHELL_ALLOW_UIDS": str(os.getuid()),
            **env,
        }
        proc = subprocess.Popen(
            [sys.executable, str(HELPER_PATH)],
            env=child_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(stop, proc)
        sock = Path(session, f"{os.getuid()}.sock")
        deadline = time.monotonic() + 5
        while not sock.exists():
            if proc.poll() is not None:
                self.fail(
                    "helper exited %d: %s"
                    % (proc.returncode, proc.stderr.read().decode())
                )
            if time.monotonic() > deadline:
                self.fail("helper socket never appeared")
            time.sleep(0.05)
        return sock

    def test_runs_as_the_session_user(self):
        res = request(self.start(), "id -u")
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["code"], 0)
        self.assertEqual(res["output"].split()[-1], str(os.getuid()))

    def test_socket_is_world_connectable_peer_check_decides(self):
        mode = stat.S_IMODE(os.stat(self.start()).st_mode)
        self.assertEqual(mode, 0o666)

    def test_empty_command(self):
        res = request(self.start(), "   ")
        self.assertEqual(res["status"], "error")
        self.assertEqual(res["errors"], ["missing command"])

    @unittest.skipUnless(
        hasattr(socket, "SO_PEERCRED"), "SO_PEERCRED is Linux-only"
    )
    def test_peer_outside_the_allowlist_is_refused(self):
        res = request(self.start(TURINGOS_SHELL_ALLOW_UIDS="999999"), "echo hi")
        self.assertEqual(res["status"], "error")
        self.assertIn("may not run commands", res["errors"][0])


if __name__ == "__main__":
    unittest.main()
