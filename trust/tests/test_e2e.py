#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path

DAEMONS_DIR = Path(__file__).parent.parent / "daemons"
SOCKET_DIR = Path("/tmp/turingos-test")
DB_DIR = Path("/tmp/turingos-test-db")

AUDIT_SOCKET = SOCKET_DIR / "audit.sock"
CAP_SOCKET = SOCKET_DIR / "cap.sock"
SANDBOX_SOCKET = SOCKET_DIR / "sandbox.sock"

AUDIT_DB = DB_DIR / "audit.db"
GRANTS_DB = DB_DIR / "grants.db"

TEST_FILE = Path("/tmp/turingos-test-input.txt")
TEST_CONTENT = "Hello, TuringOS trust model."


def wait_for_socket(socket_path: Path, timeout: float = 5.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        if socket_path.exists():
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(str(socket_path))
                sock.close()
                return True
            except (ConnectionRefusedError, FileNotFoundError):
                pass
        time.sleep(0.1)
    return False


def send_msg(socket_path: Path, msg: dict) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    try:
        sock.connect(str(socket_path))
        sock.sendall(json.dumps(msg).encode() + b"\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        return json.loads(data.decode().strip())
    finally:
        sock.close()


def start_daemon(script: str, socket_path: Path, db_path: Path = None, extra_args: list = None) -> subprocess.Popen:
    cmd = [sys.executable, str(DAEMONS_DIR / script), "--socket", str(socket_path)]
    if db_path:
        cmd.extend(["--db", str(db_path)])
    if extra_args:
        cmd.extend(extra_args)
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def stop_daemon(proc: subprocess.Popen):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def cleanup():
    import shutil
    if SOCKET_DIR.exists():
        shutil.rmtree(SOCKET_DIR)
    if DB_DIR.exists():
        shutil.rmtree(DB_DIR)
    if TEST_FILE.exists():
        TEST_FILE.unlink()


def main():
    cleanup()
    SOCKET_DIR.mkdir(parents=True)
    DB_DIR.mkdir(parents=True)
    TEST_FILE.write_text(TEST_CONTENT)

    print("=== TuringOS Trust Model E2E Test ===\n")

    print("[1] Starting auditd...")
    auditd = start_daemon("auditd.py", AUDIT_SOCKET, AUDIT_DB)
    assert wait_for_socket(AUDIT_SOCKET), "auditd failed to start"
    print("    OK\n")

    print("[2] Starting capd...")
    capd = start_daemon("capd.py", CAP_SOCKET, GRANTS_DB, extra_args=["--audit-socket", str(AUDIT_SOCKET)])
    assert wait_for_socket(CAP_SOCKET), "capd failed to start"
    print("    OK\n")

    print("[3] Starting sandboxd...")
    sandboxd = start_daemon("sandboxd.py", SANDBOX_SOCKET, extra_args=["--cap-socket", str(CAP_SOCKET)])
    assert wait_for_socket(SANDBOX_SOCKET), "sandboxd failed to start"
    print("    OK\n")

    session_id = uuid.uuid4().hex[:26]
    grant_id = uuid.uuid4().hex[:26]

    print("[4] Issuing capability grant...")
    grant = {
        "version": 1,
        "grant_id": grant_id,
        "subject": {"kind": "tool", "id": "file-reader"},
        "session_id": session_id,
        "issued_by": {"kind": "user", "id": "local"},
        "capabilities": [
            {"kind": "fs.read", "paths": [str(TEST_FILE)]}
        ],
        "expires_at": (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat(),
        "revocable": True,
    }
    result = send_msg(CAP_SOCKET, {"action": "issue", "grant": grant})
    assert result["status"] == "ok", f"grant issuance failed: {result}"
    print(f"    grant_id: {result['grant_id']}")
    print("    OK\n")

    print("[5] Running file-reader in sandbox...")
    result = send_msg(SANDBOX_SOCKET, {
        "action": "run",
        "grant_id": grant_id,
        "tool_path": str(DAEMONS_DIR / "file-reader.py"),
        "args": [str(TEST_FILE)],
    })
    if result.get("errors") and "bwrap" in str(result.get("errors", "")):
        print("    SKIPPED (bwrap not available on this platform)\n")
    else:
        assert result["status"] == "ok", f"sandbox execution failed: {result}"
        assert result["stdout"] == TEST_CONTENT, f"unexpected content: {result['stdout']!r}"
        print(f"    stdout: {result['stdout']!r}")
        print("    OK\n")

    print("[6] Verifying audit trail...")
    time.sleep(0.5)
    import sqlite3
    conn = sqlite3.connect(AUDIT_DB)
    rows = conn.execute("""
        SELECT seq, action_kind, outcome, provenance_taint FROM entries ORDER BY seq
    """).fetchall()
    conn.close()

    assert len(rows) >= 1, f"expected at least 1 audit entry, got {len(rows)}"
    actions = [r[1] for r in rows]
    assert "grant.issue" in actions, "missing grant.issue audit entry"
    if "sandbox.spawn" not in actions:
        print("    (sandbox entries skipped — bwrap not available)")
    print(f"    {len(rows)} entries recorded:")
    for seq, action, outcome, taint in rows:
        print(f"      [{seq}] {action} → {outcome} (taint: {taint})")
    print("    OK\n")

    print("[7] Revoking grant...")
    result = send_msg(CAP_SOCKET, {
        "action": "revoke",
        "grant_id": grant_id,
        "reason": "test cleanup",
    })
    assert result["status"] == "ok", f"revocation failed: {result}"
    print("    OK\n")

    print("[8] Verifying revoked grant is rejected...")
    result = send_msg(SANDBOX_SOCKET, {
        "action": "run",
        "grant_id": grant_id,
        "tool_path": str(DAEMONS_DIR / "file-reader.py"),
        "args": [str(TEST_FILE)],
    })
    assert result["status"] == "error", "revoked grant should have been rejected"
    print("    OK\n")

    print("[9] Stopping daemons...")
    stop_daemon(sandboxd)
    stop_daemon(capd)
    stop_daemon(auditd)
    print("    OK\n")

    cleanup()
    print("=== ALL TESTS PASSED ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
