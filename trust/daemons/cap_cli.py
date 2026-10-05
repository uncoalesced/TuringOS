#!/usr/bin/env python3
import argparse
import json
import socket
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

SOCKET_PATH = "/run/turingos/cap.sock"


def send_msg(msg: dict) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
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
    except Exception as e:
        return {"status": "error", "errors": [str(e)]}
    finally:
        sock.close()


def cmd_issue(args):
    grant = {
        "version": 1,
        "grant_id": args.grant_id or __import__("uuid").uuid4().hex[:26],
        "subject": {"kind": args.subject_kind, "id": args.subject_id},
        "session_id": args.session_id,
        "issued_by": {"kind": args.issued_by_kind, "id": args.issued_by_id},
        "capabilities": json.loads(args.capabilities),
        "expires_at": args.expires_at or (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat(),
        "revocable": not args.no_revocable,
    }
    result = send_msg({"action": "issue", "grant": grant})
    print(json.dumps(result, indent=2))
    sys.exit(0 if result.get("status") == "ok" else 1)


def cmd_revoke(args):
    result = send_msg({
        "action": "revoke",
        "grant_id": args.grant_id,
        "reason": args.reason,
        "revoked_by": args.revoked_by,
    })
    print(json.dumps(result, indent=2))
    sys.exit(0 if result.get("status") == "ok" else 1)


def cmd_list(args):
    result = send_msg({
        "action": "list",
        "session_id": args.session,
        "active_only": args.active,
    })
    print(json.dumps(result, indent=2))
    sys.exit(0 if result.get("status") == "ok" else 1)


def main():
    parser = argparse.ArgumentParser(description="TuringOS capability CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    issue = sub.add_parser("issue", help="Issue a capability grant")
    issue.add_argument("--subject-kind", required=True, choices=["user", "agent", "tool", "service"])
    issue.add_argument("--subject-id", required=True)
    issue.add_argument("--session-id", required=True)
    issue.add_argument("--issued-by-kind", default="user", choices=["user", "agent", "policy"])
    issue.add_argument("--issued-by-id", default="local")
    issue.add_argument("--capabilities", required=True, help='JSON array, e.g. \'[{"kind":"fs.read","paths":["/home/user/**"]}]\'')
    issue.add_argument("--expires-at", help="ISO 8601 timestamp (default: 5 minutes from now)")
    issue.add_argument("--grant-id")
    issue.add_argument("--no-revocable", action="store_true")
    issue.set_defaults(func=cmd_issue)

    revoke = sub.add_parser("revoke", help="Revoke a capability grant")
    revoke.add_argument("--grant-id", required=True)
    revoke.add_argument("--reason", default="user requested")
    revoke.add_argument("--revoked-by", default="user")
    revoke.set_defaults(func=cmd_revoke)

    list_cmd = sub.add_parser("list", help="List capability grants")
    list_cmd.add_argument("--session")
    list_cmd.add_argument("--active", action="store_true")
    list_cmd.set_defaults(func=cmd_list)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
