#!/usr/bin/env python3
import argparse
import json
import os
import socket
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SOCKET_PATH = "/run/turingos/memory.sock"
DB_PATH = Path.home() / ".turingos" / "memory.db"
AUDIT_SOCKET = "/run/turingos/audit.sock"


def audit(entry: dict):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(AUDIT_SOCKET)
        sock.sendall(json.dumps(entry).encode() + b"\n")
        sock.recv(4096)
        sock.close()
    except Exception:
        pass


def init_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            session_id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            namespace TEXT NOT NULL DEFAULT 'default',
            metadata TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            metadata TEXT,
            FOREIGN KEY (session_id) REFERENCES sessions(session_id)
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            namespace TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            embedding BLOB,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES sessions(session_id)
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_session ON messages(session_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_memory_session ON memories(session_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_memory_namespace ON memories(namespace)")
    conn.commit()
    return conn


def create_session(conn: sqlite3.Connection, session_id: str, namespace: str = "default") -> dict:
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("""
        INSERT OR REPLACE INTO sessions (session_id, created_at, updated_at, namespace)
        VALUES (?, ?, ?, ?)
    """, (session_id, now, now, namespace))
    conn.commit()
    return {"status": "ok", "session_id": session_id, "created_at": now}


def append_message(conn: sqlite3.Connection, session_id: str, role: str, content: str) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("""
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES (?, ?, ?, ?)
    """, (session_id, role, content, now))
    conn.execute("""
        UPDATE sessions SET updated_at = ? WHERE session_id = ?
    """, (now, session_id))
    conn.commit()
    return {"status": "ok", "session_id": session_id, "timestamp": now}


def search_messages(conn: sqlite3.Connection, session_id: str, limit: int = 50) -> list[dict]:
    rows = conn.execute("""
        SELECT id, role, content, timestamp FROM messages
        WHERE session_id = ? ORDER BY id DESC LIMIT ?
    """, (session_id, limit)).fetchall()
    return [{"id": r[0], "role": r[1], "content": r[2], "timestamp": r[3]} for r in reversed(rows)]


def store_memory(conn: sqlite3.Connection, session_id: str, namespace: str, key: str, value: str) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("""
        INSERT INTO memories (session_id, namespace, key, value, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, namespace, key) DO UPDATE SET
            value = excluded.value, updated_at = excluded.updated_at
    """, (session_id, namespace, key, value, now, now))
    conn.commit()
    return {"status": "ok", "session_id": session_id, "key": key}


def search_memory(conn: sqlite3.Connection, session_id: str, namespace: str = None, limit: int = 20) -> list[dict]:
    query = "SELECT id, namespace, key, value, created_at FROM memories WHERE session_id = ?"
    params = [session_id]
    if namespace:
        query += " AND namespace = ?"
        params.append(namespace)
    query += " ORDER BY updated_at DESC LIMIT ?"
    params.append(limit)
    rows = conn.execute(query, params).fetchall()
    return [{"id": r[0], "namespace": r[1], "key": r[2], "value": r[3], "created_at": r[4]} for r in rows]


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
        session_id = msg.get("session_id", "unknown")

        if action == "create_session":
            result = create_session(conn, session_id, msg.get("namespace", "default"))
        elif action == "append":
            result = append_message(conn, session_id, msg.get("role", ""), msg.get("content", ""))
        elif action == "search":
            messages = search_messages(conn, session_id, msg.get("limit", 50))
            result = {"status": "ok", "messages": messages}
        elif action == "store":
            result = store_memory(conn, session_id, msg.get("namespace", "default"), msg.get("key", ""), msg.get("value", ""))
        elif action == "search_memory":
            memories = search_memory(conn, session_id, msg.get("namespace"), msg.get("limit", 20))
            result = {"status": "ok", "memories": memories}
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


def run_daemon(socket_path: Path, db_path: Path):
    conn = init_db(db_path)

    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        os.unlink(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o666)
    server.listen(16)

    print(f"turingos-memoryd listening on {socket_path}", file=sys.stderr)

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
    parser = argparse.ArgumentParser(description="TuringOS memory daemon")
    parser.add_argument("--socket", type=Path, default=Path(SOCKET_PATH))
    parser.add_argument("--db", type=Path, default=DB_PATH)
    args = parser.parse_args()
    run_daemon(args.socket, args.db)


if __name__ == "__main__":
    main()
