#!/usr/bin/env python3
"""TuringOS session shell helper: runs /shell commands as you.

turingos-bridged-ws runs as the system user `turingos`, which is nobody's
login session, so it forwards every /shell command here instead. This runs
as a systemd *user* unit (one per graphical session) and listens on

    /run/turingos/session/<uid>.sock

a 1777 drop-box (see turingos-tmpfiles.conf): the session user cannot write
into /run/turingos (owned by `turingos`) and `turingos` cannot traverse
/run/user/<uid>. Requests are authenticated with SO_PEERCRED — only root and
the `turingos` system user (the bridge) may run commands.

Protocol: one JSON line {"command": ...} in, one JSON line
{"status": "ok", "code": ..., "output": ...} out, then close.
"""
import asyncio
import json
import os
import pwd
import signal
import socket
import struct
import sys
from pathlib import Path

SHELL_TIMEOUT = 60
SHELL_MAX_OUTPUT = 64 * 1024

# 1777 drop-box created at boot by /usr/lib/tmpfiles.d/turingos.conf
SESSION_DIR = Path(os.environ.get("TURINGOS_SESSION_DIR", "/run/turingos/session"))


def socket_path() -> Path:
    return SESSION_DIR / f"{os.getuid()}.sock"


def allowed_uids() -> set:
    """root and the bridge's system user. On a dev machine without a
    `turingos` user, the helper's own uid too — nothing to protect there."""
    override = os.environ.get("TURINGOS_SHELL_ALLOW_UIDS")
    if override:
        return {int(u) for u in override.split(",") if u.strip()}
    uids = {0}
    try:
        uids.add(pwd.getpwnam("turingos").pw_uid)
    except KeyError:
        uids.add(os.getuid())
    return uids


def peer_uid(conn) -> int:
    """Connecting process's uid, or -1 where the platform cannot say
    (SO_PEERCRED is Linux-only; macOS dev boxes skip the check)."""
    if conn is None or not hasattr(socket, "SO_PEERCRED"):
        return -1
    try:
        raw = conn.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
        )
    except OSError:
        return -1
    return struct.unpack("3i", raw)[1]


async def run_shell(command: str, timeout: float = SHELL_TIMEOUT) -> dict:
    proc = await asyncio.create_subprocess_exec(
        "bash", "-c", "exec 2>&1\n" + command,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        cwd=os.path.expanduser("~"),
        start_new_session=True,
    )
    buf = b""

    async def collect():
        nonlocal buf
        while len(buf) <= SHELL_MAX_OUTPUT:
            chunk = await proc.stdout.read(65536)
            if not chunk:
                break
            buf += chunk

    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    timed_out = False
    try:
        await asyncio.wait_for(collect(), timeout)
        if len(buf) <= SHELL_MAX_OUTPUT:
            await asyncio.wait_for(proc.wait(), max(0.0, deadline - loop.time()))
    except asyncio.TimeoutError:
        timed_out = True
    if proc.returncode is None:  # timed out or flooding output: kill the whole group
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (AttributeError, ProcessLookupError):
            proc.kill()
    code = await proc.wait()

    output = buf[:SHELL_MAX_OUTPUT].decode(errors="replace")
    if len(buf) > SHELL_MAX_OUTPUT:
        output += "\n[output truncated at 64 KB]"
    if timed_out:
        code = 124
        output += f"\n[stopped after {timeout:g}s]"
    return {"status": "ok", "code": code, "output": output}


async def handle(reader, writer):
    try:
        uid = peer_uid(writer.get_extra_info("socket"))
        # read before answering: closing first would race the client's write
        line = await asyncio.wait_for(reader.readline(), 10)
        msg = json.loads(line.decode(errors="replace") or "{}")
        command = str(msg.get("command", "")).strip()
        if uid >= 0 and uid not in allowed_uids():
            reply = {"status": "error", "errors": [f"peer uid {uid} may not run commands"]}
        elif not command:
            reply = {"status": "error", "errors": ["missing command"]}
        else:
            reply = await run_shell(command)
    except asyncio.TimeoutError:
        reply = {"status": "error", "errors": ["no command within 10s"]}
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        reply = {"status": "error", "errors": ["bad request"]}
    except Exception as e:
        reply = {"status": "error", "errors": [str(e)]}
    try:
        writer.write((json.dumps(reply) + "\n").encode())
        await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass


async def serve(path: Path):
    server = await asyncio.start_unix_server(handle, path=str(path))
    # the bridge (user `turingos`) must be able to connect; peer uid decides
    os.chmod(path, 0o666)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()
    path.unlink(missing_ok=True)


def main():
    try:
        SESSION_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        sys.exit(
            f"shell-helper: cannot create {SESSION_DIR}: {e}\n"
            "  (installed as /usr/lib/tmpfiles.d/turingos.conf at boot)"
        )
    path = socket_path()
    if path.exists():
        probe = socket.socket(socket.AF_UNIX)
        probe.settimeout(1)
        try:
            probe.connect(str(path))  # a live instance already owns it
            probe.close()
            return
        except OSError:
            probe.close()
            path.unlink()  # stale socket from a SIGKILLed instance
    asyncio.run(serve(path))


if __name__ == "__main__":
    main()
