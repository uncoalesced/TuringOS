#!/usr/bin/env python3
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SOCKET_PATH = "/run/turingos/sandbox.sock"
CAP_SOCKET = "/run/turingos/cap.sock"
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


def check_grant(grant_id: str, cap_socket: Path) -> dict:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(cap_socket))
        sock.sendall(json.dumps({"action": "list", "active_only": True}).encode() + b"\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        sock.close()
        result = json.loads(data.decode().strip())
        for grant in result.get("grants", []):
            if grant["grant_id"] == grant_id:
                return grant
        return None
    except Exception:
        return None


def build_bwrap_args(grant: dict, tool_path: str, tool_args: list[str]) -> list[str]:
    args = ["bwrap"]

    args.extend(["--unshare-all", "--die-with-parent"])
    args.extend(["--new-session", "--clearenv"])

    args.extend(["--proc", "/proc"])
    args.extend(["--dev", "/dev"])
    args.extend(["--tmpfs", "/tmp"])

    args.extend(["--ro-bind", "/usr", "/usr"])
    args.extend(["--ro-bind", "/lib", "/lib"])
    args.extend(["--ro-bind", "/lib64", "/lib64"])
    args.extend(["--ro-bind", "/bin", "/bin"])
    args.extend(["--ro-bind", "/sbin", "/sbin"])
    args.extend(["--ro-bind", "/etc", "/etc"])

    for cap in grant.get("capabilities", []):
        if cap["kind"] == "fs.read":
            for path in cap.get("paths", []):
                expanded = os.path.expanduser(path)
                if os.path.exists(expanded):
                    args.extend(["--ro-bind", expanded, expanded])
        elif cap["kind"] == "fs.write":
            for path in cap.get("paths", []):
                expanded = os.path.expanduser(path)
                os.makedirs(expanded, exist_ok=True)
                args.extend(["--bind", expanded, expanded])

    args.extend(["--chdir", "/"])
    args.append(tool_path)
    args.extend(tool_args)
    return args


def run_tool(grant: dict, tool_path: str, tool_args: list[str], session_id: str) -> dict:
    grant_id = grant["grant_id"]
    now = datetime.now(timezone.utc).isoformat()

    audit({
        "version": 1,
        "timestamp": now,
        "subject": {"kind": "tool", "id": grant["subject"]["id"]},
        "session_id": session_id,
        "grant_id": grant_id,
        "action": {"kind": "sandbox.spawn"},
        "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
        "outcome": "allowed",
    })

    bwrap_args = build_bwrap_args(grant, tool_path, tool_args)

    try:
        result = subprocess.run(
            bwrap_args,
            capture_output=True,
            text=True,
            timeout=30,
        )

        audit({
            "version": 1,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "subject": {"kind": "tool", "id": grant["subject"]["id"]},
            "session_id": session_id,
            "grant_id": grant_id,
            "action": {"kind": "fs.read" if any(c["kind"] == "fs.read" for c in grant["capabilities"]) else "fs.write"},
            "provenance": {"origin": "tool_output", "taint": "trusted", "chain": []},
            "outcome": "allowed" if result.returncode == 0 else "error",
        })

        return {
            "status": "ok" if result.returncode == 0 else "error",
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
    except subprocess.TimeoutExpired:
        audit({
            "version": 1,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "subject": {"kind": "tool", "id": grant["subject"]["id"]},
            "session_id": session_id,
            "grant_id": grant_id,
            "action": {"kind": "process.kill", "reason": "timeout"},
            "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
            "outcome": "terminated",
        })
        return {"status": "error", "errors": ["tool timed out after 30s"]}
    except Exception as e:
        return {"status": "error", "errors": [str(e)]}


def handle_client(client: socket.socket, cap_socket: Path):
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
        if action == "run":
            grant_id = msg.get("grant_id")
            if not grant_id:
                client.sendall(json.dumps({"status": "error", "errors": ["missing grant_id"]}).encode() + b"\n")
                return

            grant = check_grant(grant_id, cap_socket)
            if not grant:
                client.sendall(json.dumps({"status": "error", "errors": [f"grant not found or expired: {grant_id}"]}).encode() + b"\n")
                return

            tool_path = msg.get("tool_path")
            if not tool_path:
                client.sendall(json.dumps({"status": "error", "errors": ["missing tool_path"]}).encode() + b"\n")
                return

            tool_args = msg.get("args", [])
            result = run_tool(grant, tool_path, tool_args, grant["session_id"])
            client.sendall(json.dumps(result).encode() + b"\n")
        else:
            client.sendall(json.dumps({"status": "error", "errors": [f"unknown action: {action}"]}).encode() + b"\n")
    except Exception as e:
        try:
            client.sendall(json.dumps({"status": "error", "errors": [str(e)]}).encode() + b"\n")
        except Exception:
            pass
    finally:
        client.close()


def run_daemon(socket_path: Path, cap_socket: Path = Path(CAP_SOCKET)):
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        os.unlink(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o666)
    server.listen(16)

    print(f"turingos-sandboxd listening on {socket_path}", file=sys.stderr)

    while True:
        try:
            client, _ = server.accept()
            handle_client(client, cap_socket)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)

    server.close()


def main():
    parser = argparse.ArgumentParser(description="TuringOS sandbox daemon")
    parser.add_argument("--socket", type=Path, default=Path(SOCKET_PATH))
    parser.add_argument("--cap-socket", type=Path, default=Path(CAP_SOCKET))
    args = parser.parse_args()
    run_daemon(args.socket, args.cap_socket)


if __name__ == "__main__":
    main()
