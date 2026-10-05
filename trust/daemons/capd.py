#!/usr/bin/env python3
import argparse
import json
import os
import socket
import sqlite3
import sys
import time
import uuid
from datetime import datetime, timezone, timedelta
from pathlib import Path

SOCKET_PATH = "/run/turingos/cap.sock"
DB_PATH = "/var/lib/turingos/grants.db"
AUDIT_SOCKET = "/run/turingos/audit.sock"
SCHEMA_PATH = Path(__file__).parent.parent / "schemas" / "grant.json"


def init_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS grants (
            grant_id TEXT PRIMARY KEY,
            version INTEGER NOT NULL,
            subject_kind TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            subject_version TEXT,
            session_id TEXT NOT NULL,
            issued_by_kind TEXT NOT NULL,
            issued_by_id TEXT NOT NULL,
            capabilities TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            revocable INTEGER NOT NULL DEFAULT 1,
            revoked INTEGER NOT NULL DEFAULT 0,
            revoked_at TEXT,
            revoke_reason TEXT,
            signature TEXT,
            created_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_session ON grants(session_id)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_subject ON grants(subject_kind, subject_id)
    """)
    conn.commit()
    return conn


def audit(entry: dict):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(AUDIT_SOCKET)
        sock.sendall(json.dumps(entry).encode() + b"\n")
        sock.recv(4096)
        sock.close()
    except Exception:
        pass


def validate_grant(grant: dict) -> list[str]:
    errors = []
    required = ["version", "grant_id", "subject", "session_id", "issued_by", "capabilities", "expires_at", "revocable"]
    for field in required:
        if field not in grant:
            errors.append(f"missing required field: {field}")
    if grant.get("version") != 1:
        errors.append("version must be 1")
    if not isinstance(grant.get("subject"), dict):
        errors.append("subject must be an object")
    elif "kind" not in grant["subject"] or "id" not in grant["subject"]:
        errors.append("subject must have kind and id")
    if not isinstance(grant.get("capabilities"), list) or len(grant.get("capabilities", [])) == 0:
        errors.append("capabilities must be a non-empty array")
    try:
        datetime.fromisoformat(grant.get("expires_at", "").replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        errors.append("expires_at must be a valid ISO 8601 timestamp")
    return errors


def issue_grant(conn: sqlite3.Connection, grant: dict) -> dict:
    errors = validate_grant(grant)
    if errors:
        return {"status": "error", "errors": errors}

    now = datetime.now(timezone.utc)
    expires = datetime.fromisoformat(grant["expires_at"].replace("Z", "+00:00"))
    if expires <= now:
        return {"status": "error", "errors": ["expires_at must be in the future"]}

    grant["created_at"] = now.isoformat()

    conn.execute("""
        INSERT INTO grants (grant_id, version, subject_kind, subject_id, subject_version,
            session_id, issued_by_kind, issued_by_id, capabilities, expires_at, revocable,
            revoked, signature, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
    """, (
        grant["grant_id"], grant["version"], grant["subject"]["kind"],
        grant["subject"]["id"], grant["subject"].get("version"),
        grant["session_id"], grant["issued_by"]["kind"], grant["issued_by"]["id"],
        json.dumps(grant["capabilities"]), grant["expires_at"],
        1 if grant["revocable"] else 0, grant.get("signature"), grant["created_at"]
    ))
    conn.commit()

    audit({
        "version": 1,
        "timestamp": now.isoformat(),
        "subject": {"kind": "agent", "id": "capd"},
        "session_id": grant["session_id"],
        "grant_id": grant["grant_id"],
        "action": {"kind": "grant.issue"},
        "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
        "outcome": "allowed",
    })

    return {"status": "ok", "grant_id": grant["grant_id"], "expires_at": grant["expires_at"]}


def revoke_grant(conn: sqlite3.Connection, grant_id: str, reason: str, revoked_by: str = "user") -> dict:
    row = conn.execute("SELECT * FROM grants WHERE grant_id = ?", (grant_id,)).fetchone()
    if not row:
        return {"status": "error", "errors": [f"grant not found: {grant_id}"]}

    if row[11]:
        return {"status": "ok", "message": "already revoked", "grant_id": grant_id}

    now = datetime.now(timezone.utc).isoformat()
    conn.execute("""
        UPDATE grants SET revoked = 1, revoked_at = ?, revoke_reason = ?
        WHERE grant_id = ?
    """, (now, reason, grant_id))
    conn.commit()

    audit({
        "version": 1,
        "timestamp": now,
        "subject": {"kind": "user", "id": revoked_by},
        "session_id": row[5],
        "grant_id": grant_id,
        "action": {"kind": "grant.revoke", "reason": reason},
        "provenance": {"origin": "user_request", "taint": "trusted", "chain": []},
        "outcome": "complete",
    })

    return {"status": "ok", "grant_id": grant_id, "revoked_at": now, "reason": reason}


def list_grants(conn: sqlite3.Connection, session_id: str = None, active_only: bool = False) -> list[dict]:
    query = "SELECT * FROM grants"
    conditions = []
    params = []
    if session_id:
        conditions.append("session_id = ?")
        params.append(session_id)
    if active_only:
        conditions.append("revoked = 0")
        conditions.append("expires_at > ?")
        params.append(datetime.now(timezone.utc).isoformat())
    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    query += " ORDER BY created_at DESC"

    rows = conn.execute(query, params).fetchall()
    grants = []
    for row in rows:
        grants.append({
            "grant_id": row[0],
            "version": row[1],
            "subject": {"kind": row[2], "id": row[3], "version": row[4]},
            "session_id": row[5],
            "issued_by": {"kind": row[6], "id": row[7]},
            "capabilities": json.loads(row[8]),
            "expires_at": row[9],
            "revocable": bool(row[10]),
            "revoked": bool(row[11]),
            "revoked_at": row[12],
            "revoke_reason": row[13],
            "signature": row[14],
            "created_at": row[15],
        })
    return grants


def handle_client(conn: sqlite3.Connection, client: socket.socket):
    try:
        data = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        if not data:
            return

        try:
            msg = json.loads(data.decode().strip())
        except json.JSONDecodeError as e:
            client.sendall(json.dumps({"status": "error", "errors": [f"invalid JSON: {e}"]}).encode() + b"\n")
            return

        action = msg.get("action")
        if action == "issue":
            result = issue_grant(conn, msg.get("grant", {}))
        elif action == "revoke":
            result = revoke_grant(conn, msg.get("grant_id", ""), msg.get("reason", ""), msg.get("revoked_by", "user"))
        elif action == "list":
            grants = list_grants(conn, msg.get("session_id"), msg.get("active_only", False))
            result = {"status": "ok", "grants": grants}
        else:
            result = {"status": "error", "errors": [f"unknown action: {action}"]}

        client.sendall(json.dumps(result).encode() + b"\n")
    except Exception as e:
        try:
            client.sendall(json.dumps({"status": "error", "errors": [str(e)]}).encode() + b"\n")
        except Exception:
            pass
    finally:
        client.close()


def run_daemon(db_path: Path, socket_path: Path):
    conn = init_db(db_path)

    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        os.unlink(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o666)
    server.listen(16)

    print(f"turingos-capd listening on {socket_path}", file=sys.stderr)

    while True:
        try:
            client, _ = server.accept()
            handle_client(conn, client)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)

    server.close()
    conn.close()


def main():
    parser = argparse.ArgumentParser(description="TuringOS capability daemon")
    parser.add_argument("--db", type=Path, default=Path(DB_PATH))
    parser.add_argument("--socket", type=Path, default=Path(SOCKET_PATH))
    args = parser.parse_args()
    run_daemon(args.db, args.socket)


if __name__ == "__main__":
    main()
