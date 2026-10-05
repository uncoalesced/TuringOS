#!/usr/bin/env python3
import argparse
import json
import os
import socket
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BRIDGE_SOCKET = "/run/turingos/bridge.sock"
AUDIT_SOCKET = "/run/turingos/audit.sock"
MODEL_API_URL = os.environ.get("TURINGOS_MODEL_API_URL", "https://api.anthropic.com/v1/messages")
MODEL_API_KEY = os.environ.get("TURINGOS_MODEL_API_KEY", "")
MODEL_NAME = os.environ.get("TURINGOS_MODEL_API_MODEL", "claude-sonnet-4-20250514")


def audit(entry: dict):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(AUDIT_SOCKET)
        sock.sendall(json.dumps(entry).encode() + b"\n")
        sock.recv(4096)
        sock.close()
    except Exception:
        pass


def call_model(messages: list[dict]) -> dict:
    payload = {
        "model": MODEL_NAME,
        "max_tokens": 4096,
        "messages": messages,
        "stream": True,
    }
    req = urllib.request.Request(
        MODEL_API_URL,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "x-api-key": MODEL_API_KEY,
            "anthropic-version": "2023-06-01",
        },
    )
    response = urllib.request.urlopen(req, timeout=60)
    return response


def parse_stream(response) -> list[dict]:
    events = []
    for line in response:
        line = line.decode().strip()
        if line.startswith("data: "):
            data = line[6:]
            if data == "[DONE]":
                break
            try:
                event = json.loads(data)
                events.append(event)
            except json.JSONDecodeError:
                continue
    return events


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
        if action == "complete":
            messages = msg.get("messages", [])
            if not messages:
                client.sendall(json.dumps({"status": "error", "errors": ["missing messages"]}).encode() + b"\n")
                return

            session_id = msg.get("session_id", "unknown")
            now = datetime.now(timezone.utc).isoformat()

            audit({
                "version": 1,
                "timestamp": now,
                "subject": {"kind": "agent", "id": "agentd-llm"},
                "session_id": session_id,
                "action": {"kind": "model_call"},
                "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
                "outcome": "allowed",
            })

            try:
                response = call_model(messages)
                events = parse_stream(response)
                client.sendall(json.dumps({"status": "ok", "events": events}).encode() + b"\n")
            except Exception as e:
                audit({
                    "version": 1,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "subject": {"kind": "agent", "id": "agentd-llm"},
                    "session_id": session_id,
                    "action": {"kind": "model_call"},
                    "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
                    "outcome": "error",
                })
                client.sendall(json.dumps({"status": "error", "errors": [str(e)]}).encode() + b"\n")
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

    print(f"turingos-agentd-llm listening on {socket_path}", file=sys.stderr)

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
    parser = argparse.ArgumentParser(description="TuringOS agentd-llm daemon")
    parser.add_argument("--socket", type=Path, default=Path("/run/turingos/agent-llm.sock"))
    args = parser.parse_args()
    run_daemon(args.socket)


if __name__ == "__main__":
    main()
