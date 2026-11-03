#!/usr/bin/env python3
"""Story 064, task 9.1 -- a deterministic ACP v1 agent that announces subagents (E2E fixture).

Run by Zeo as a custom agent server (`python3 -I stub_adapter.py`); it speaks ACP v1 JSON-RPC,
one message per line, on stdin/stdout. It never calls a model and never touches the network.

What a prompt's text selects (case-sensitive words anywhere in it):

  TWO   announce Alpha (titled, cancellable, running) and send it the parent's first message;
        announce Bravo (titled, cancellable, running) and send it NO message (R5.3); title the
        thread; end the turn while both keep running (R4.1: idle parent, running children).
  WAIT  Bravo reports `requires_action` (R5.2).
  BOTH  announce Charlie as an RFD child AND list it in `_claude/tasks` with
        `childSessionId: "charlie"`, beside a feed-only shell task (R3.1, R3.2).

A `session/cancel` naming a child answers with that child's `idle`/`cancelled` state on its
parent; one naming the parent changes nothing. Every received method, the advertised
`clientCapabilities.subagents`, and each cancelled session are appended as JSON lines to
$SUBAGENT_STUB_LOG, the objective record the driver checks (the screen cannot show which
session a `session/cancel` named).

Wire shapes are agent-client-protocol-schema 1.12.0's v1 (`unstable_subagents`):
`{"sessionUpdate": "subagent_update", "sessionId": <child>, "title", "capabilities":
{"cancel": {}}, "state": {"state": "running" | "requires_action" | "idle", "stopReason"}}` and
`{"sessionUpdate": "session_message_chunk", "messageId", "senderSessionId",
"recipientSessionId", "content"}`.
"""

import json
import os
import sys
import time

LOG_PATH = os.environ.get("SUBAGENT_STUB_LOG")
PARENT_PREFIX = "stub-parent-"
CHILDREN = ("alpha", "bravo", "charlie")

_next_session = 0
_parents = []


def log(event, **fields):
    if not LOG_PATH:
        return
    record = {"ts": round(time.time(), 3), "event": event}
    record.update(fields)
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def respond_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def update(session_id, payload):
    send(
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"sessionId": session_id, "update": payload},
        }
    )


def subagent(parent, child, **fields):
    payload = {"sessionUpdate": "subagent_update", "sessionId": child}
    payload.update(fields)
    update(parent, payload)


def cancellable():
    return {"cancel": {}}


def running():
    return {"state": "running"}


def text(value):
    return {"type": "text", "text": value}


def wire_task(task_id, kind, description, child=None):
    task = {
        "id": task_id,
        "toolCallId": None,
        "type": kind,
        "description": description,
        "background": True,
        "depth": 0,
        "status": "running",
        "startedAt": int(time.time() * 1000) - 5_000,
        "endedAt": None,
        "usage": {"tokens": 1234, "toolUses": 3, "durationMs": 5_000},
        "lastTool": "Read",
        "summary": "Reading the parser",
        "hasOutput": False,
        "tail": None,
    }
    if child is not None:
        task["childSessionId"] = child
    return task


def scenario_two(parent):
    update(parent, {"sessionUpdate": "session_info_update", "title": "Subagent proof"})
    subagent(parent, "alpha", title="Alpha", capabilities=cancellable(), state=running())
    update(
        parent,
        {
            "sessionUpdate": "session_message_chunk",
            "messageId": "launch-alpha",
            "senderSessionId": parent,
            "recipientSessionId": "alpha",
            "content": text("Investigate the Alpha failure"),
        },
    )
    subagent(parent, "bravo", title="Bravo", capabilities=cancellable(), state=running())
    update(
        parent,
        {"sessionUpdate": "agent_message_chunk", "content": text("Launched two subagents.")},
    )


def scenario_wait(parent):
    subagent(parent, "bravo", state={"state": "requires_action"})
    update(
        parent,
        {"sessionUpdate": "agent_message_chunk", "content": text("Bravo needs you.")},
    )


def scenario_both(parent):
    update(parent, {"sessionUpdate": "session_info_update", "title": "Dedupe proof"})
    subagent(parent, "charlie", title="Charlie", capabilities=cancellable(), state=running())
    update(
        parent,
        {
            "sessionUpdate": "session_message_chunk",
            "messageId": "launch-charlie",
            "senderSessionId": parent,
            "recipientSessionId": "charlie",
            "content": text("Investigate the Charlie failure"),
        },
    )
    update(
        parent,
        {
            "sessionUpdate": "session_info_update",
            "_meta": {
                "_claude/tasks": {
                    "tasks": [
                        wire_task("task-charlie", "subagent", "Charlie", child="charlie"),
                        wire_task("shell-1", "shell", "Feedonly shell"),
                    ]
                }
            },
        },
    )
    update(
        parent,
        {"sessionUpdate": "agent_message_chunk", "content": text("Charlie sent both ways.")},
    )


def prompt_text(params):
    parts = params.get("prompt") or []
    return " ".join(part.get("text", "") for part in parts if isinstance(part, dict))


def handle_request(message):
    global _next_session
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    log("request", method=method)
    if method == "initialize":
        capabilities = params.get("clientCapabilities") or {}
        log("initialize", subagents_offered=("subagents" in capabilities))
        respond(
            request_id,
            {
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": False,
                    "_meta": {"_claude/tasks": {"version": 3}},
                },
                "authMethods": [],
            },
        )
    elif method == "session/new":
        _next_session += 1
        session_id = f"{PARENT_PREFIX}{_next_session}"
        _parents.append(session_id)
        respond(request_id, {"sessionId": session_id})
    elif method == "session/prompt":
        parent = params.get("sessionId", "")
        words = prompt_text(params)
        if "TWO" in words:
            scenario_two(parent)
        if "WAIT" in words:
            scenario_wait(parent)
        if "BOTH" in words:
            scenario_both(parent)
        log("prompt", session=parent, words=words[:80])
        respond(request_id, {"stopReason": "end_turn"})
    else:
        respond_error(request_id, -32601, f"method not supported by the stub: {method}")


def handle_notification(message):
    method = message.get("method")
    params = message.get("params") or {}
    log("notification", method=method)
    if method != "session/cancel":
        return
    session_id = params.get("sessionId", "")
    log("cancel", session=session_id)
    if session_id in CHILDREN and _parents:
        subagent(_parents[-1], session_id, state={"state": "idle", "stopReason": "cancelled"})


def main():
    log("start", pid=os.getpid())
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            log("unparsable", length=len(line))
            continue
        if "method" in message and "id" in message:
            handle_request(message)
        elif "method" in message:
            handle_notification(message)
        # A response to a request of ours: the stub sends none, so there is nothing to match.
    log("eof")


if __name__ == "__main__":
    main()
