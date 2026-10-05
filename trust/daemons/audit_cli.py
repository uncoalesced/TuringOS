#!/usr/bin/env python3
import argparse
import json
import socket
import sys
from pathlib import Path

SOCKET_PATH = "/run/turingos/audit.sock"


def send_entry(entry: dict) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(entry).encode() + b"\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        return json.loads(data.decode().strip())
    except Exception as e:
        return {"status": "error", "errors": [str(e)]}
    finally:
        sock.close()


def cmd_append(args):
    entry = {
        "version": 1,
        "timestamp": args.timestamp or __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        "subject": {"kind": args.subject_kind, "id": args.subject_id},
        "action": {"kind": args.action_kind},
        "provenance": {"origin": args.origin, "taint": args.taint},
        "outcome": args.outcome,
    }
    if args.session_id:
        entry["session_id"] = args.session_id
    if args.grant_id:
        entry["grant_id"] = args.grant_id
    if args.path:
        entry["action"]["path"] = args.path
    if args.domain:
        entry["action"]["domain"] = args.domain
    if args.command:
        entry["action"]["command"] = args.command
    if args.reason:
        entry["action"]["reason"] = args.reason
    if args.chain:
        entry["provenance"]["chain"] = args.chain.split(",")

    result = send_entry(entry)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result.get("status") == "ok" else 1)


def cmd_tail(args):
    import sqlite3
    db_path = Path(args.db)
    if not db_path.exists():
        print(f"database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    query = "SELECT * FROM entries"
    conditions = []
    params = []
    if args.session:
        conditions.append("session_id = ?")
        params.append(args.session)
    if args.grant:
        conditions.append("grant_id = ?")
        params.append(args.grant)
    if args.limit:
        conditions.append("1=1")

    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    query += " ORDER BY seq DESC"
    if args.limit:
        query += f" LIMIT {args.limit}"

    rows = conn.execute(query, params).fetchall()
    for row in reversed(rows):
        print(json.dumps(dict(row), indent=2))
    conn.close()


def main():
    parser = argparse.ArgumentParser(description="TuringOS audit CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    append = sub.add_parser("append", help="Append an entry to the audit log")
    append.add_argument("--subject-kind", required=True)
    append.add_argument("--subject-id", required=True)
    append.add_argument("--action-kind", required=True)
    append.add_argument("--origin", required=True, choices=["user_request", "agent_plan", "tool_output", "web_fetch", "file_read", "model_response"])
    append.add_argument("--taint", required=True, choices=["trusted", "untrusted", "derived"])
    append.add_argument("--outcome", required=True, choices=["allowed", "denied", "error", "terminated", "initiated", "complete"])
    append.add_argument("--timestamp")
    append.add_argument("--session-id")
    append.add_argument("--grant-id")
    append.add_argument("--path")
    append.add_argument("--domain")
    append.add_argument("--command")
    append.add_argument("--reason")
    append.add_argument("--chain")
    append.set_defaults(func=cmd_append)

    tail = sub.add_parser("tail", help="Read entries from the audit log")
    tail.add_argument("--db", default="/var/lib/turingos/audit.db")
    tail.add_argument("--session")
    tail.add_argument("--grant")
    tail.add_argument("--limit", type=int, default=50)
    tail.set_defaults(func=cmd_tail)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
