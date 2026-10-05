#!/usr/bin/env python3
import argparse
import json
import socket
import sys
from pathlib import Path

SOCKET_PATH = "/run/turingos/sandbox.sock"


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


def cmd_run(args):
    result = send_msg({
        "action": "run",
        "grant_id": args.grant_id,
        "tool_path": args.tool_path,
        "args": args.args or [],
    })
    print(json.dumps(result, indent=2))
    sys.exit(0 if result.get("status") == "ok" else 1)


def main():
    parser = argparse.ArgumentParser(description="TuringOS sandbox CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="Run a tool inside a sandbox")
    run.add_argument("--grant-id", required=True)
    run.add_argument("--tool-path", required=True)
    run.add_argument("--args", nargs="*", default=[])
    run.set_defaults(func=cmd_run)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
