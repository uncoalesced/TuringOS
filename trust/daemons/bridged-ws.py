#!/usr/bin/env python3
import argparse
import asyncio
import json
import os
import socket
import sys
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

APP_DIR = Path(__file__).parent.parent.parent / "ui" / "web"
CAP_SOCKET = "/run/turingos/cap.sock"
PLAN_SOCKET = "/run/turingos/agent-plan.sock"
AGENT_LLM_SOCKET = "/run/turingos/agent-llm.sock"
BRIDGE_SOCKET = "/run/turingos/bridge.sock"
MEMORY_SOCKET = "/run/turingos/memory.sock"

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


@app.get("/health")
async def health():
    return {"status": "ok"}


if APP_DIR.exists():
    app.mount("/static", StaticFiles(directory=APP_DIR), name="static")

    @app.get("/")
    async def root():
        return FileResponse(APP_DIR / "index.html")


def main():
    parser = argparse.ArgumentParser(description="TuringOS Bridge WebSocket Server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--reload", action="store_true")
    args = parser.parse_args()

    uvicorn.run(app, host=args.host, port=args.port, reload=args.reload)


if __name__ == "__main__":
    main()