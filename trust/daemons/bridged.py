#!/usr/bin/env python3
import argparse
import json
import os
import socket
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SOCKET_PATH = "/run/turingos/bridge.sock"
AUDIT_SOCKET = "/run/turingos/audit.sock"
DEFAULT_ALLOWLIST = [
    "api.anthropic.com",
    "api.openai.com",
    "deb.debian.org",
    "security.debian.org",
    "brave-browser-apt-release.s3.brave.com",
]


def audit(entry: dict):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(AUDIT_SOCKET)
        sock.sendall(json.dumps(entry).encode() + b"\n")
        sock.recv(4096)
        sock.close()
    except Exception:
        pass


def is_allowed(domain: str, allowlist: list[str]) -> bool:
    for allowed in allowlist:
        if domain == allowed or domain.endswith("." + allowed):
            return True
    return False


def fetch_url(url: str, allowlist: list[str]) -> dict:
    from urllib.parse import urlparse
    parsed = urlparse(url)
    domain = parsed.hostname or ""

    if not is_allowed(domain, allowlist):
        return {
            "status": "error",
            "errors": [f"domain not in allowlist: {domain}"],
            "taint": "untrusted",
        }

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "TuringOS/1.2"})
        response = urllib.request.urlopen(req, timeout=30)
        content = response.read().decode("utf-8", errors="replace")

        audit({
            "version": 1,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "subject": {"kind": "service", "id": "bridged"},
            "action": {"kind": "net.egress", "domain": domain},
            "provenance": {"origin": "web_fetch", "taint": "untrusted", "chain": []},
            "outcome": "allowed",
        })

        return {
            "status": "ok",
            "content": content,
            "taint": "untrusted",
            "domain": domain,
        }
    except Exception as e:
        return {"status": "error", "errors": [str(e)], "taint": "untrusted"}


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
        if action == "fetch":
            url = msg.get("url", "")
            allowlist = msg.get("allowlist", DEFAULT_ALLOWLIST)
            result = fetch_url(url, allowlist)
            client.sendall(json.dumps(result).encode() + b"\n")
        elif action == "health":
            client.sendall(json.dumps({"status": "ok", "service": "bridged"}).encode() + b"\n")
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

    print(f"turingos-bridged listening on {socket_path}", file=sys.stderr)

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
    parser = argparse.ArgumentParser(description="TuringOS bridge daemon")
    parser.add_argument("--socket", type=Path, default=Path(SOCKET_PATH))
    args = parser.parse_args()
    run_daemon(args.socket)


if __name__ == "__main__":
    main()
