#!/usr/bin/env python3
import argparse
import asyncio
import json
import os
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles

# The installed UI lives at /usr/lib/turingos/ui/web (sync-scripts stages it;
# launch-ui.sh expects the same path). In a checkout, __file__ resolves to
# trust/daemons/bridged-ws.py, so fall back to the repo's ui/web — that is
# what trust/tests/test_bridge_shell.py serves. TURINGOS_UI_DIR overrides both.
def _app_dir() -> Path:
    override = os.environ.get("TURINGOS_UI_DIR")
    if override:
        return Path(override)
    installed = Path("/usr/lib/turingos/ui/web")
    if installed.exists():
        return installed
    return Path(__file__).resolve().parent.parent.parent / "ui" / "web"


APP_DIR = _app_dir()
CAP_SOCKET = "/run/turingos/cap.sock"
PLAN_SOCKET = "/run/turingos/agent-plan.sock"
AGENT_LLM_SOCKET = "/run/turingos/agent-llm.sock"
BRIDGE_SOCKET = "/run/turingos/bridge.sock"
MEMORY_SOCKET = "/run/turingos/memory.sock"

# Local shell mode (Phase 3 fallback): when the model is unreachable the UI
# runs what the user types as a plain command, like a terminal would. The
# bridge runs as the system user `turingos`, which is nobody's login session,
# so run_shell() forwards to shell-helper.py (a per-session user unit) — the
# 60s/64KB budget lives there; this is just how long we wait for it.
SHELL_TIMEOUT = 60
LOCAL_HOSTS = {"localhost", "127.0.0.1"}

app = FastAPI(title="TuringOS Bridge")


class UnixSocketClient:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path

    async def send(self, msg: dict) -> dict:
        loop = asyncio.get_event_loop()
        try:
            reader, writer = await asyncio.open_unix_connection(self.socket_path)
            writer.write((json.dumps(msg) + "\n").encode())
            await writer.drain()
            data = await reader.read(4096)
            writer.close()
            await writer.wait_closed()
            return json.loads(data.decode().strip())
        except Exception as e:
            return {"status": "error", "errors": [str(e)]}


cap_client = UnixSocketClient(CAP_SOCKET)
plan_client = UnixSocketClient(PLAN_SOCKET)
llm_client = UnixSocketClient(AGENT_LLM_SOCKET)
bridge_client = UnixSocketClient(BRIDGE_SOCKET)
memory_client = UnixSocketClient(MEMORY_SOCKET)


@app.websocket("/plan")
async def plan_ws(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            action = msg.get("action")

            if action == "create_plan":
                result = await plan_client.send({"action": "create_plan", **msg})
            elif action == "approve_plan":
                result = await plan_client.send({"action": "approve_plan", **msg})
            elif action == "execute_plan":
                result = await plan_client.send({"action": "execute_plan", **msg})
            else:
                result = {"status": "error", "errors": [f"unknown plan action: {action}"]}

            await ws.send_text(json.dumps(result))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await ws.send_text(json.dumps({"status": "error", "errors": [str(e)]}))


@app.websocket("/agent")
async def agent_ws(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            action = msg.get("action")

            if action == "complete":
                result = await llm_client.send({"action": "complete", **msg})
                await ws.send_text(json.dumps(result))
            else:
                await ws.send_text(json.dumps({"status": "error", "errors": [f"unknown agent action: {action}"]}))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await ws.send_text(json.dumps({"status": "error", "errors": [str(e)]}))


@app.websocket("/bridge")
async def bridge_ws(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            action = msg.get("action")

            if action == "fetch":
                result = await bridge_client.send({"action": "fetch", **msg})
                await ws.send_text(json.dumps(result))
            else:
                await ws.send_text(json.dumps({"status": "error", "errors": [f"unknown bridge action: {action}"]}))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await ws.send_text(json.dumps({"status": "error", "errors": [str(e)]}))


@app.websocket("/cap")
async def cap_ws(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            action = msg.get("action")

            if action == "issue":
                result = await cap_client.send({"action": "issue", **msg})
            elif action == "revoke":
                result = await cap_client.send({"action": "revoke", **msg})
            elif action == "list":
                result = await cap_client.send({"action": "list", **msg})
            else:
                result = {"status": "error", "errors": [f"unknown cap action: {action}"]}
            await ws.send_text(json.dumps(result))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await ws.send_text(json.dumps({"status": "error", "errors": [str(e)]}))


@app.websocket("/memory")
async def memory_ws(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            action = msg.get("action")

            if action == "create_session":
                result = await memory_client.send({"action": "create_session", **msg})
            elif action == "append":
                result = await memory_client.send({"action": "append", **msg})
            elif action == "search":
                result = await memory_client.send({"action": "search", **msg})
            elif action == "store":
                result = await memory_client.send({"action": "store", **msg})
            elif action == "search_memory":
                result = await memory_client.send({"action": "search_memory", **msg})
            else:
                result = {"status": "error", "errors": [f"unknown memory action: {action}"]}
            await ws.send_text(json.dumps(result))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await ws.send_text(json.dumps({"status": "error", "errors": [str(e)]}))


def origin_allowed(ws: WebSocket) -> bool:
    """Only the UI page this bridge serves may open /shell. Browsers don't
    apply CORS to WebSockets, so without this any site open in Brave could
    run commands; a DNS-rebound name fails the localhost check."""
    host = ws.headers.get("host", "")
    return (
        host.rsplit(":", 1)[0] in LOCAL_HOSTS
        and ws.headers.get("origin", "") == f"http://{host}"
    )


def session_dir() -> Path:
    # 1777 drop-box (turingos-tmpfiles.conf): each session's helper drops
    # <uid>.sock here; read at call time so tests can point it anywhere
    return Path(os.environ.get("TURINGOS_SESSION_DIR", "/run/turingos/session"))


async def run_shell(command: str, timeout: float = SHELL_TIMEOUT + 15) -> dict:
    """Forward to the login session's shell-helper so commands run as the
    person at the keyboard, not as the system user `turingos`."""
    socks = sorted(
        (p for p in session_dir().glob("*.sock") if p.is_socket()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not socks:
        return {
            "status": "error",
            "errors": ["no login session: shell helper is not running"],
        }
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(str(socks[0])), 5
        )
    except Exception as e:
        return {"status": "error", "errors": [f"shell helper unreachable: {e}"]}
    data = b""
    try:
        writer.write((json.dumps({"command": command}) + "\n").encode())
        await writer.drain()
        # the helper replies then closes; output can reach 64 KB, so read
        # everything rather than one chunk
        data = await asyncio.wait_for(reader.read(), timeout)
    except asyncio.TimeoutError:
        return {"status": "error", "errors": ["shell helper timed out"]}
    except Exception as e:
        return {"status": "error", "errors": [str(e)]}
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
    try:
        return json.loads(data.decode().strip())
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return {"status": "error", "errors": ["bad reply from shell helper"]}


@app.websocket("/shell")
async def shell_ws(ws: WebSocket):
    if not origin_allowed(ws):
        await ws.close(code=1008)
        return
    await ws.accept()
    try:
        while True:
            msg = json.loads(await ws.receive_text())
            command = str(msg.get("command", "")).strip()
            if not command:
                result = {"status": "error", "errors": ["missing command"]}
            else:
                result = await run_shell(command)
            await ws.send_text(json.dumps(result))
    except WebSocketDisconnect:
        pass
    except Exception as e:
        await ws.send_text(json.dumps({"status": "error", "errors": [str(e)]}))


@app.get("/health")
async def health():
    return {"status": "ok"}


# The page loads its assets relative to / (css/..., js/...), so serve the UI
# at the root. Mounted last: /health and the WebSocket routes above win.
if APP_DIR.exists():
    app.mount("/", StaticFiles(directory=APP_DIR, html=True), name="ui")


def main():
    parser = argparse.ArgumentParser(description="TuringOS Bridge WebSocket Server")
    # Loopback only: the bridge drives the agent and /shell runs commands
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--reload", action="store_true")
    args = parser.parse_args()

    uvicorn.run(app, host=args.host, port=args.port, reload=args.reload)


if __name__ == "__main__":
    main()