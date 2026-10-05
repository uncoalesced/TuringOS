#!/usr/bin/env python3
import argparse
import json
import os
import socket
import sys
from pathlib import Path

SOCKET_PATH = "/run/turingos/toolreg.sock"
SYSTEM_TOOLS_DIR = Path("/etc/turingos/tools.d")
USER_TOOLS_DIR = Path.home() / ".turingos" / "tools.d"


def discover_tools() -> list[dict]:
    tools = []
    for directory in [SYSTEM_TOOLS_DIR, USER_TOOLS_DIR]:
        if not directory.exists():
            continue
        for manifest_file in directory.glob("*.json"):
            try:
                manifest = json.loads(manifest_file.read_text())
                manifest["_manifest_path"] = str(manifest_file)
                tools.append(manifest)
            except (json.JSONDecodeError, KeyError):
                continue
    return tools


def handle_client(client: socket.socket):
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
        if action == "list":
            tools = discover_tools()
            client.sendall(json.dumps({"status": "ok", "tools": tools}).encode() + b"\n")
        elif action == "get":
            tool_id = msg.get("tool_id", "")
            tools = discover_tools()
            for tool in tools:
                if tool.get("id") == tool_id:
                    client.sendall(json.dumps({"status": "ok", "tool": tool}).encode() + b"\n")
                    return
            client.sendall(json.dumps({"status": "error", "errors": [f"tool not found: {tool_id}"]}).encode() + b"\n")
        else:
            client.sendall(json.dumps({"status": "error", "errors": [f"unknown action: {action}"]}).encode() + b"\n")
    except Exception as e:
        try:
            client.sendall(json.dumps({"status": "error", "errors": [str(e)]}).encode() + b"\n")
        except Exception:
            pass
    finally:
        client.close()


def run_daemon(socket_path: Path):
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        os.unlink(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o666)
    server.listen(16)

    print(f"turingos-toolreg listening on {socket_path}", file=sys.stderr)

    while True:
        try:
            client, _ = server.accept()
            handle_client(client)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)

    server.close()


def main():
    parser = argparse.ArgumentParser(description="TuringOS tool registry daemon")
    parser.add_argument("--socket", type=Path, default=Path(SOCKET_PATH))
    args = parser.parse_args()
    run_daemon(args.socket)


if __name__ == "__main__":
    main()
