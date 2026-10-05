#!/usr/bin/env python3
import argparse
import asyncio
import json
import os
import socket
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

CAP_SOCKET = "/run/turingos/cap.sock"
SANDBOX_SOCKET = "/run/turingos/sandbox.sock"
AUDIT_SOCKET = "/run/turingos/audit.sock"
MEMORY_SOCKET = "/run/turingos/memory.sock"


def audit(entry: dict):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(AUDIT_SOCKET)
        sock.sendall(json.dumps(entry).encode() + b"\n")
        sock.recv(4096)
        sock.close()
    except Exception:
        pass


async def send_to_socket(socket_path: str, msg: dict) -> dict:
    try:
        reader, writer = await asyncio.open_unix_connection(socket_path)
        writer.write((json.dumps(msg) + "\n").encode())
        await writer.drain()
        data = await reader.read(4096)
        writer.close()
        await writer.wait_closed()
        return json.loads(data.decode().strip())
    except Exception as e:
        return {"status": "error", "errors": [str(e)]}


class PlanStore:
    def __init__(self):
        self.plans = {}
        self.approval_events = {}

    def create(self, session_id: str, intent: str, steps: list[dict]) -> dict:
        plan_id = uuid.uuid4().hex[:26]
        now = datetime.now(timezone.utc).isoformat()
        plan = {
            "version": 1,
            "plan_id": plan_id,
            "session_id": session_id,
            "created_at": now,
            "intent": intent,
            "steps": steps,
            "approval": {"required": True, "mode": "plan", "granted_by": None, "granted_at": None},
            "dry_run": True,
            "status": "pending_approval",
        }
        self.plans[plan_id] = plan
        self.approval_events[plan_id] = asyncio.Event()

        audit({
            "version": 1,
            "timestamp": now,
            "subject": {"kind": "agent", "id": "agentd-plan"},
            "session_id": session_id,
            "action": {"kind": "plan.create", "plan_id": plan_id},
            "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
            "outcome": "allowed",
        })
        return plan

    def get(self, plan_id: str) -> dict | None:
        return self.plans.get(plan_id)

    def approve(self, plan_id: str, session_id: str) -> dict:
        plan = self.plans.get(plan_id)
        if not plan:
            return {"status": "error", "errors": [f"plan not found: {plan_id}"]}

        now = datetime.now(timezone.utc).isoformat()
        plan["approval"]["granted_by"] = "local"
        plan["approval"]["granted_at"] = now
        plan["status"] = "approved"

        audit({
            "version": 1,
            "timestamp": now,
            "subject": {"kind": "user", "id": "local"},
            "session_id": session_id,
            "action": {"kind": "plan.approve", "plan_id": plan_id},
            "provenance": {"origin": "user_request", "taint": "trusted", "chain": []},
            "outcome": "allowed",
        })

        if plan_id in self.approval_events:
            self.approval_events[plan_id].set()

        return {"status": "ok", "plan_id": plan_id, "approved_at": now}

    async def wait_for_approval(self, plan_id: str) -> bool:
        event = self.approval_events.get(plan_id)
        if not event:
            return False
        try:
            await asyncio.wait_for(event.wait(), timeout=300.0)
            return True
        except asyncio.TimeoutError:
            return False

    def get_approved_plan(self, plan_id: str) -> dict | None:
        plan = self.plans.get(plan_id)
        if plan and plan["status"] == "approved":
            return plan
        return None


plan_store = PlanStore()


async def execute_plan(plan: dict) -> dict:
    session_id = plan["session_id"]
    plan_id = plan["plan_id"]
    results = []

    audit({
        "version": 1,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "subject": {"kind": "agent", "id": "agentd-plan"},
        "session_id": session_id,
        "action": {"kind": "plan.execute", "plan_id": plan_id},
        "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
        "outcome": "initiated",
    })

    for step in plan["steps"]:
        if plan["status"] != "approved":
            step["status"] = "cancelled"
            results.append({"step_id": step["step_id"], "error": "plan not approved"})
            continue

        if step["kind"] == "tool_call":
            grant = {
                "version": 1,
                "grant_id": uuid.uuid4().hex[:26],
                "subject": {"kind": "tool", "id": step["tool"]},
                "session_id": session_id,
                "issued_by": {"kind": "user", "id": "local"},
                "capabilities": step.get("capabilities_required", []),
                "expires_at": (datetime.now(timezone.utc) + __import__("datetime").timedelta(minutes=5)).isoformat(),
                "revocable": True,
            }
            grant_result = await send_to_socket(CAP_SOCKET, {"action": "issue", "grant": grant})
            if grant_result.get("status") != "ok":
                step["status"] = "failed"
                results.append({"step_id": step["step_id"], "error": "grant issuance failed"})
                continue

            run_result = await send_to_socket(SANDBOX_SOCKET, {
                "action": "run",
                "grant_id": grant["grant_id"],
                "tool_path": f"/usr/lib/turingos/tools/{step['tool']}",
                "args": [step.get("args", {}).get("path", "")] if step.get("args") else [],
            })
            step["status"] = "completed" if run_result.get("status") == "ok" else "failed"
            step["output_ref"] = f"step:{step['step_id']}:output"
            results.append({"step_id": step["step_id"], "result": run_result})

        elif step["kind"] == "model_call":
            step["status"] = "completed"
            results.append({"step_id": step["step_id"], "result": {"status": "ok"}})

        elif step["kind"] == "ui":
            step["status"] = "completed"
            results.append({"step_id": step["step_id"], "result": {"status": "ok"}})

    audit({
        "version": 1,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "subject": {"kind": "agent", "id": "agentd-plan"},
        "session_id": plan["session_id"],
        "action": {"kind": "plan.execute", "plan_id": plan["plan_id"]},
        "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
        "outcome": "complete",
    })

    return {"status": "ok", "plan_id": plan["plan_id"], "results": results}


async def execute_plan_after_approval(plan_id: str):
    approved = await plan_store.wait_for_approval(plan_id)
    if not approved:
        return

    plan = plan_store.get_approved_plan(plan_id)
    if not plan:
        return

    await execute_plan(plan)


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        data = await reader.read(4096)
        if not data:
            return

        try:
            msg = json.loads(data.decode().strip())
        except json.JSONDecodeError as e:
            writer.write((json.dumps({"status": "error", "errors": [f"invalid JSON: {e}"]}) + "\n").encode())
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return

        action = msg.get("action")
        if action == "create_plan":
            plan = plan_store.create(
                msg.get("session_id", "unknown"),
                msg.get("intent", ""),
                msg.get("steps", []),
            )
            writer.write((json.dumps({"status": "ok", "plan": plan}) + "\n").encode())
            await writer.drain()

            asyncio.create_task(execute_plan_after_approval(plan["plan_id"]))

        elif action == "approve_plan":
            result = plan_store.approve(msg.get("plan_id", ""), msg.get("session_id", "unknown"))
            writer.write((json.dumps(result) + "\n").encode())
            await writer.drain()

        elif action == "execute_plan":
            plan = plan_store.get(msg.get("plan_id", ""))
            if not plan:
                writer.write((json.dumps({"status": "error", "errors": ["plan not found"]}) + "\n").encode())
            else:
                result = await execute_plan(plan)
                writer.write((json.dumps(result) + "\n").encode())
            await writer.drain()

        else:
            writer.write((json.dumps({"status": "error", "errors": [f"unknown action: {msg.get('action')}"]}) + "\n").encode())
            await writer.drain()

    except Exception as e:
        try:
            writer.write((json.dumps({"status": "error", "errors": [str(e)]}) + "\n").encode())
            await writer.drain()
        except Exception:
            pass
    finally:
        writer.close()
        await writer.wait_closed()


async def run_daemon(socket_path: Path):
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        os.unlink(socket_path)

    server = await asyncio.start_unix_server(handle_client, path=str(socket_path))
    os.chmod(socket_path, 0o666)

    print(f"turingos-agentd-plan listening on {socket_path}", file=sys.stderr)

    async with server:
        await server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="TuringOS agentd-plan daemon")
    parser.add_argument("--socket", type=Path, default=Path("/run/turingos/agent-plan.sock"))
    args = parser.parse_args()
    asyncio.run(run_daemon(args.socket))


if __name__ == "__main__":
    main()