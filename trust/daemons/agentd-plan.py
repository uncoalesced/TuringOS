#!/usr/bin/env python3
import argparse
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


def send_to_socket(socket_path: str, msg: dict) -> dict:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(socket_path)
        sock.sendall(json.dumps(msg).encode() + b"\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        sock.close()
        return json.loads(data.decode().strip())
    except Exception as e:
        return {"status": "error", "errors": [str(e)]}


def create_plan(session_id: str, intent: str, steps: list[dict]) -> dict:
    plan = {
        "version": 1,
        "plan_id": uuid.uuid4().hex[:26],
        "session_id": session_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "intent": intent,
        "steps": steps,
        "approval": {"required": True, "mode": "plan", "granted_by": None, "granted_at": None},
        "dry_run": True,
    }

    audit({
        "version": 1,
        "timestamp": plan["created_at"],
        "subject": {"kind": "agent", "id": "agentd-plan"},
        "session_id": session_id,
        "action": {"kind": "plan.create", "plan_id": plan["plan_id"]},
        "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
        "outcome": "allowed",
    })

    return plan


def approve_plan(plan_id: str, session_id: str) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    audit({
        "version": 1,
        "timestamp": now,
        "subject": {"kind": "user", "id": "local"},
        "session_id": session_id,
        "action": {"kind": "plan.approve", "plan_id": plan_id},
        "provenance": {"origin": "user_request", "taint": "trusted", "chain": []},
        "outcome": "allowed",
    })
    return {"status": "ok", "plan_id": plan_id, "approved_at": now}


def execute_plan(plan: dict) -> dict:
    session_id = plan["session_id"]
    results = []

    for step in plan["steps"]:
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
            grant_result = send_to_socket(CAP_SOCKET, {"action": "issue", "grant": grant})
            if grant_result.get("status") != "ok":
                step["status"] = "failed"
                results.append({"step_id": step["step_id"], "error": "grant issuance failed"})
                continue

            run_result = send_to_socket(SANDBOX_SOCKET, {
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
        "session_id": session_id,
        "action": {"kind": "plan.execute", "plan_id": plan["plan_id"]},
        "provenance": {"origin": "agent_plan", "taint": "trusted", "chain": []},
        "outcome": "allowed",
    })

    return {"status": "ok", "plan_id": plan["plan_id"], "results": results}


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
        if action == "create_plan":
            plan = create_plan(msg.get("session_id", "unknown"), msg.get("intent", ""), msg.get("steps", []))
            client.sendall(json.dumps({"status": "ok", "plan": plan}).encode() + b"\n")
        elif action == "approve_plan":
            result = approve_plan(msg.get("plan_id", ""), msg.get("session_id", "unknown"))
            client.sendall(json.dumps(result).encode() + b"\n")
        elif action == "execute_plan":
            result = execute_plan(msg.get("plan", {}))
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


def run_daemon(socket_path: Path):
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    if socket_path.exists():
        os.unlink(socket_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(socket_path))
    os.chmod(socket_path, 0o666)
    server.listen(16)

    print(f"turingos-agentd-plan listening on {socket_path}", file=sys.stderr)

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
    parser = argparse.ArgumentParser(description="TuringOS agentd-plan daemon")
    parser.add_argument("--socket", type=Path, default=Path("/run/turingos/agent-plan.sock"))
    args = parser.parse_args()
    run_daemon(args.socket)


if __name__ == "__main__":
    main()
