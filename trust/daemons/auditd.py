#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import socket
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SOCKET_PATH = "/run/turingos/audit.sock"
DB_PATH = "/var/lib/turingos/audit.db"
SCHEMA_PATH = Path(__file__).parent.parent / "schemas" / "audit-entry.json"


def init_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS entries (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            version INTEGER NOT NULL,
            prev_hash TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            subject_kind TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            session_id TEXT,
            grant_id TEXT,
            action_kind TEXT NOT NULL,
            action_path TEXT,
            action_domain TEXT,
            action_command TEXT,
            action_plan_id TEXT,
            action_fragment_id TEXT,
            action_reason TEXT,
            provenance_origin TEXT NOT NULL,
            provenance_taint TEXT NOT NULL,
            provenance_chain TEXT NOT NULL,
            outcome TEXT NOT NULL,
            hash TEXT NOT NULL UNIQUE,
            raw_json TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_session ON entries(session_id)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_grant ON entries(grant_id)
    """)
    conn.commit()
    return conn


def compute_hash(entry: dict) -> str:
    canonical = json.dumps(entry, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()


def get_last_hash(conn: sqlite3.Connection) -> str:
    row = conn.execute("SELECT hash FROM entries ORDER BY seq DESC LIMIT 1").fetchone()
    if row:
        return row[0]
    return "sha256:" + "0" * 64


def validate_entry(entry: dict) -> list[str]:
    errors = []
    required = ["version", "timestamp", "subject", "action", "provenance", "outcome"]
    for field in required:
        if field not in entry:
            errors.append(f"missing required field: {field}")
    if entry.get("version") != 1:
        errors.append("version must be 1")
    if not isinstance(entry.get("subject"), dict):
        errors.append("subject must be an object")
    elif "kind" not in entry["subject"] or "id" not in entry["subject"]:
        errors.append("subject must have kind and id")
    if not isinstance(entry.get("action"), dict):
        errors.append("action must be an object")
    elif "kind" not in entry["action"]:
        errors.append("action must have kind")
    if not isinstance(entry.get("provenance"), dict):
        errors.append("provenance must be an object")
    elif "origin" not in entry["provenance"] or "taint" not in entry["provenance"]:
        errors.append("provenance must have origin and taint")
    if entry.get("outcome") not in ("allowed", "denied", "error", "terminated", "initiated", "complete"):
        errors.append(f"invalid outcome: {entry.get('outcome')}")
    return errors


def insert_entry(conn: sqlite3.Connection, entry: dict) -> dict:
    errors = validate_entry(entry)
    if errors:
        return {"status": "error", "errors": errors}

    prev_hash = get_last_hash(conn)
    seq = conn.execute("SELECT COALESCE(MAX(seq), 0) + 1 FROM entries").fetchone()[0]

    entry["version"] = 1
    entry["seq"] = seq
    entry["prev_hash"] = prev_hash
    entry["hash"] = compute_hash(entry)

    action = entry.get("action", {})
    provenance = entry.get("provenance", {})
    subject = entry.get("subject", {})

    conn.execute("""
        INSERT INTO entries (version, prev_hash, timestamp, subject_kind, subject_id,
            session_id, grant_id, action_kind, action_path, action_domain, action_command,
            action_plan_id, action_fragment_id, action_reason, provenance_origin,
            provenance_taint, provenance_chain, outcome, hash, raw_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        entry["version"], entry["prev_hash"], entry["timestamp"],
        subject.get("kind"), subject.get("id"),
        entry.get("session_id"), entry.get("grant_id"),
        action.get("kind"), action.get("path"), action.get("domain"),
        action.get("command"), action.get("plan_id"), action.get("fragment_id"),
        action.get("reason"), provenance.get("origin"), provenance.get("taint"),
        json.dumps(provenance.get("chain", [])), entry["outcome"],
        entry["hash"], json.dumps(entry)
    ))
    conn.commit()
    return {"status": "ok", "seq": seq, "hash": entry["hash"]}


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
            entry = json.loads(data.decode().strip())
        except json.JSONDecodeError as e:
            response = {"status": "error", "errors": [f"invalid JSON: {e}"]}
            client.sendall(json.dumps(response).encode() + b"\n")
            return

        result = insert_entry(conn, entry)
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

    print(f"turingos-auditd listening on {socket_path}", file=sys.stderr)

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
    parser = argparse.ArgumentParser(description="TuringOS audit daemon")
    parser.add_argument("--db", type=Path, default=Path(DB_PATH))
    parser.add_argument("--socket", type=Path, default=Path(SOCKET_PATH))
    args = parser.parse_args()
    run_daemon(args.db, args.socket)


if __name__ == "__main__":
    main()
