#!/usr/bin/env python3
import argparse
import ipaddress
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


MAX_FETCH_BYTES = 5 * 1024 * 1024


def server_allowlist() -> list[str]:
    """The allowlist is decided here, never by the caller: any local process
    can reach this socket. Operators extend it via TURINGOS_BRIDGE_ALLOWLIST
    (comma-separated hostnames)."""
    extra = os.environ.get("TURINGOS_BRIDGE_ALLOWLIST", "")
    return DEFAULT_ALLOWLIST + [d.strip() for d in extra.split(",") if d.strip()]


def is_allowed(domain: str, allowlist: list[str]) -> bool:
    if not domain:
        return False
    for allowed in allowlist:
        if allowed and (domain == allowed or domain.endswith("." + allowed)):
            return True
    return False


def resolves_to_private(host: str) -> bool:
    """True if any address for host is loopback/private/link-local/etc, which
    would turn an allowed name into a way to reach local services (SSRF)."""
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return True
    for info in infos:
        try:
            addr = ipaddress.ip_address(info[4][0].split("%", 1)[0])
        except ValueError:
            return True
        if (
            addr.is_private
            or addr.is_loopback
            or addr.is_link_local
            or addr.is_multicast
            or addr.is_reserved
            or addr.is_unspecified
        ):
            return True
    return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect could leave the allowlist, so never follow one."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_url(url: str, allowlist: list[str]) -> dict:
    from urllib.parse import urlparse
    parsed = urlparse(url)
    domain = parsed.hostname or ""

    if parsed.scheme not in ("http", "https"):
        return {
            "status": "error",
            "errors": [f"unsupported URL scheme: {parsed.scheme or 'none'}"],
            "taint": "untrusted",
        }

    if not is_allowed(domain, allowlist):
        return {
            "status": "error",
            "errors": [f"domain not in allowlist: {domain}"],
            "taint": "untrusted",
        }

    if resolves_to_private(domain):
        return {
            "status": "error",
            "errors": [f"refusing to fetch non-public address: {domain}"],
            "taint": "untrusted",
        }

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "TuringOS/1.2"})
        opener = urllib.request.build_opener(_NoRedirect)
        response = opener.open(req, timeout=30)
        raw = response.read(MAX_FETCH_BYTES + 1)
        if len(raw) > MAX_FETCH_BYTES:
            return {
                "status": "error",
                "errors": [f"response larger than {MAX_FETCH_BYTES} bytes"],
                "taint": "untrusted",
            }
        content = raw.decode("utf-8", errors="replace")

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
            # A client-supplied "allowlist" is deliberately ignored
            result = fetch_url(url, server_allowlist())
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
