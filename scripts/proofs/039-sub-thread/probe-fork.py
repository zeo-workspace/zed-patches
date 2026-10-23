#!/usr/bin/env python3
"""Story 039, task 2.1 -- probe ACP `session/fork` on the released adapter, over stdio, without Zeo.

    python3 -I probe-fork.py --out <dir> [--adapter <cmd>] [--cwd <project dir>]
    python3 -I probe-fork.py --capabilities-only [--adapter <cmd>]

What it asserts (R3.4, R6.3; Q11), each a line of the summary written to <dir>/summary.json and
printed last on stdout:

  capability   `initialize` advertises `agentCapabilities.sessionCapabilities.fork`.
  new_id       `session/fork` of the parent answers a session id that is NOT the parent's
               (hostile half first: a fork that hands back the parent id would route the
               sub-thread's messages into the parent, R3.4).
  no_replay    no `user_message_chunk` / `agent_message_chunk` for the new session arrives before
               the fork's response -- Zeo opens the fork empty (design.md, the "open the fork
               through the registered thread" decision) and must not be racing a replay.
  inherited    a prompt on the fork asking for a random token that only the parent's earlier turn
               stated is answered with that token (the fork carries the parent's context).
  parent_quiet that prompt reaches the fork only: the parent session receives no update while the
               fork answers (R3.4, the converse of new_id).
  load_replay  `session/load` on the fork id is sent and the number of replayed message chunks is
               RECORDED (evidence for design.md's reopen assumption; no pass/fail on the number).
  unprompted_reload
               step 5 (R4.9): a SECOND fork of the parent, never prompted, then a FRESH adapter
               process (a restart) and `session/load` on that fork's id. What it answers is
               RECORDED — `{"loaded": true}` or `{"error_code": <code>}`; the case R4.9 handles is
               -32002 (resource not found: the adapter finds no transcript for a fork that was
               never used). No pass/fail: it measures the adapter, it does not gate it.

`"fork": "ok"` only when every assertion above holds. The token is random per run, so a model
cannot pass `inherited` by guessing, and no third (control) turn is spent.

--capabilities-only stops after `initialize`: no session, no model turn, no credit. It is what
Phase 3 could run; the full probe costs two short model turns (the parent's, the fork's).

Mirror Zeo's conditions or the answer does not transfer (project memory, "ACP stdio probe"): the
`cwd` is a project directory, and the environment is inherited unchanged. Nothing secret is
written: the transcript holds JSON-RPC frames and model text only, never the environment.

Exit: 0 every assertion holds - 1 an assertion failed - 2 environment problem (no adapter, no
answer, authentication required, a timeout).
"""

import argparse
import json
import os
import queue
import secrets
import subprocess
import sys
import threading
import time
from typing import IO

DEFAULT_ADAPTER = "/usr/bin/claude-agent-acp-plus"
MESSAGE_CHUNKS = ("user_message_chunk", "agent_message_chunk")
CONVERSATION_CHUNKS = MESSAGE_CHUNKS + ("agent_thought_chunk",)
SETUP_TIMEOUT = 60.0
TURN_TIMEOUT = 240.0


class EnvironmentProblem(Exception):
    """The probe could not ask its question: exit 2, never a verdict."""


class Wire:
    """One adapter process, JSON-RPC 2.0 over newline-delimited stdio."""

    def __init__(self, command, cwd, transcript_path):
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=cwd,
                text=True,
                bufsize=1,
            )
        except OSError as error:
            raise EnvironmentProblem(f"cannot start {command[0]}: {error}") from error
        # PIPE was asked for all three; a None here is a broken interpreter, not a verdict.
        stdin, stdout, stderr = self.process.stdin, self.process.stdout, self.process.stderr
        if stdin is None or stdout is None or stderr is None:
            self.process.kill()
            raise EnvironmentProblem(f"{command[0]}: stdio pipes were not created")
        self.stdin: IO[str] = stdin
        self.stdout: IO[str] = stdout
        self.stderr: IO[str] = stderr
        self.inbox = queue.Queue()
        self.next_id = 0
        # Every notification, in arrival order, as (monotonic time, session id, update kind).
        self.updates = []
        self.update_texts = {}
        self.transcript = open(transcript_path, "w", encoding="utf-8") if transcript_path else None
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _read(self):
        for line in self.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.inbox.put(json.loads(line))
            except json.JSONDecodeError:
                self.inbox.put({"_unparsed": line})
        self.inbox.put(None)

    def _drain_stderr(self):
        # Read and dropped: the adapter's own log may carry paths and ids, and a full pipe would
        # block it. Its exit status is what the probe reports on.
        for _ in self.stderr:
            pass

    def _log(self, direction, frame):
        if self.transcript:
            self.transcript.write(json.dumps({"dir": direction, "frame": frame}) + "\n")
            self.transcript.flush()

    def _send(self, frame):
        self._log("out", frame)
        try:
            self.stdin.write(json.dumps(frame) + "\n")
            self.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise EnvironmentProblem(f"the adapter closed its stdin: {error}") from error

    def _note(self, frame):
        params = frame.get("params") or {}
        update = params.get("update") or {}
        kind = update.get("sessionUpdate")
        session = params.get("sessionId")
        self.updates.append((time.monotonic(), session, kind))
        content = update.get("content")
        if isinstance(content, dict) and content.get("type") == "text":
            self.update_texts.setdefault((session, kind), []).append(content.get("text", ""))

    def _answer_agent_request(self, frame):
        # The probe grants nothing: a permission request is cancelled, anything else refused.
        if frame.get("method") == "session/request_permission":
            result = {"outcome": {"outcome": "cancelled"}}
            self._send({"jsonrpc": "2.0", "id": frame["id"], "result": result})
        else:
            error = {"code": -32601, "message": "not offered by the probe"}
            self._send({"jsonrpc": "2.0", "id": frame["id"], "error": error})

    def request(self, method, params, timeout):
        """Sends one request; returns (result, error, arrival time of the response)."""
        self.next_id += 1
        request_id = self.next_id
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise EnvironmentProblem(f"{method}: no answer within {timeout:.0f} s")
            try:
                frame = self.inbox.get(timeout=remaining)
            except queue.Empty as error:
                raise EnvironmentProblem(f"{method}: no answer within {timeout:.0f} s") from error
            if frame is None:
                raise EnvironmentProblem(
                    f"{method}: the adapter exited (status {self.process.poll()})"
                )
            self._log("in", frame)
            if "method" in frame and "id" in frame:
                self._answer_agent_request(frame)
            elif "method" in frame:
                if frame["method"] == "session/update":
                    self._note(frame)
            elif frame.get("id") == request_id:
                return frame.get("result"), frame.get("error"), time.monotonic()

    def settle(self, seconds):
        """Reads notifications for `seconds` more (late updates of the last turn)."""
        deadline = time.monotonic() + seconds
        while (remaining := deadline - time.monotonic()) > 0:
            try:
                frame = self.inbox.get(timeout=remaining)
            except queue.Empty:
                return
            if frame is None:
                return
            self._log("in", frame)
            if "method" in frame and "id" in frame:
                self._answer_agent_request(frame)
            elif frame.get("method") == "session/update":
                self._note(frame)

    def close(self):
        # A dead adapter leaves an unflushable pipe; closing it here keeps the exit status clean.
        try:
            self.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        if self.transcript:
            self.transcript.close()


def require(result, error, what):
    if error is not None:
        if error.get("code") == -32000:
            raise EnvironmentProblem(f"{what}: authentication required ({error.get('message')})")
        raise EnvironmentProblem(f"{what}: error {error.get('code')} {error.get('message')}")
    if not isinstance(result, dict):
        raise EnvironmentProblem(f"{what}: no result object")
    return result


def chunks_for(wire, session, since, until=None, kinds=MESSAGE_CHUNKS):
    return [
        kind
        for at, sid, kind in wire.updates
        if sid == session and kind in kinds and at >= since and (until is None or at <= until)
    ]


def prompt(wire, session, text):
    result, error = wire.request(
        "session/prompt",
        {"sessionId": session, "prompt": [{"type": "text", "text": text}]},
        TURN_TIMEOUT,
    )[:2]
    return require(result, error, "session/prompt")


def initialize(wire):
    result, error, _ = wire.request(
        "initialize",
        {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": False, "writeTextFile": False},
                "terminal": False,
            },
        },
        SETUP_TIMEOUT,
    )
    return require(result, error, "initialize")


def unprompted_reload(wire, parent, cwd, args, out) -> dict[str, object]:
    """Step 5: fork the parent again, never prompt the fork, restart, and load it."""
    result, error, _ = wire.request(
        "session/fork", {"sessionId": parent, "cwd": cwd, "mcpServers": []}, TURN_TIMEOUT
    )
    if error is not None:
        return {"fork_error_code": error.get("code")}
    unprompted = (result or {}).get("sessionId")
    if not unprompted:
        raise EnvironmentProblem("the second session/fork answered no sessionId")
    fresh = Wire(args.adapter, args.cwd, os.path.join(out, "wire-reload.jsonl"))
    try:
        initialize(fresh)
        result, error, _ = fresh.request(
            "session/load", {"sessionId": unprompted, "cwd": cwd, "mcpServers": []}, TURN_TIMEOUT
        )
    finally:
        fresh.close()
    if error is not None:
        return {"error_code": error.get("code"), "resource_not_found": error.get("code") == -32002}
    return {"loaded": True}


def run(args) -> dict[str, object]:
    summary: dict[str, object] = {"capability": "fail", "fork": "fail"}
    out = None
    if not args.capabilities_only:
        out = os.path.abspath(args.out)
        os.makedirs(out, exist_ok=True)
    transcript = os.path.join(out, "wire.jsonl") if out else None
    wire = Wire(args.adapter, args.cwd, transcript)
    try:
        init = initialize(wire)
        session_caps = (init.get("agentCapabilities") or {}).get("sessionCapabilities") or {}
        has_fork = session_caps.get("fork") is not None
        summary["capability"] = "ok" if has_fork else "fail"
        summary["load_session"] = bool((init.get("agentCapabilities") or {}).get("loadSession"))
        if args.capabilities_only or not has_fork:
            return summary

        cwd = os.path.abspath(args.cwd)
        result, error, _ = wire.request(
            "session/new", {"cwd": cwd, "mcpServers": []}, SETUP_TIMEOUT
        )
        parent = require(result, error, "session/new").get("sessionId")
        if not parent:
            raise EnvironmentProblem("session/new answered no sessionId")

        token = f"QZ-{secrets.token_hex(4).upper()}"
        prompt(
            wire,
            parent,
            f"Remember this token for later: {token}. Reply with the single word OK.",
        )
        wire.settle(2.0)

        fork_sent = time.monotonic()
        result, error, fork_answered = wire.request(
            "session/fork", {"sessionId": parent, "cwd": cwd, "mcpServers": []}, TURN_TIMEOUT
        )
        if error is not None:
            summary["fork_error"] = {"code": error.get("code"), "message": error.get("message")}
            return summary
        forked = (result or {}).get("sessionId")
        summary["new_id"] = "ok" if forked and forked != parent else "fail"
        replayed_early = chunks_for(wire, forked, fork_sent, fork_answered)
        summary["no_replay"] = "ok" if not replayed_early else "fail"
        summary["replayed_before_response"] = len(replayed_early)
        if summary["new_id"] != "ok":
            return summary

        parent_mark = time.monotonic()
        prompt(
            wire,
            forked,
            "What token did I ask you to remember earlier in this conversation? "
            "Reply with the token only.",
        )
        wire.settle(2.0)
        answer = "".join(wire.update_texts.get((forked, "agent_message_chunk"), []))
        summary["inherited"] = "ok" if token in answer else "fail"
        # Message chunks only: the adapter may still send the parent bookkeeping updates (its
        # command list, usage) on timers of its own; a delivered prompt shows as chunks.
        parent_chunks = chunks_for(wire, parent, parent_mark, kinds=CONVERSATION_CHUNKS)
        summary["parent_quiet"] = "ok" if not parent_chunks else "fail"
        summary["parent_chunks_during_fork_turn"] = len(parent_chunks)

        load_mark = time.monotonic()
        result, error, _ = wire.request(
            "session/load",
            {"sessionId": forked, "cwd": cwd, "mcpServers": []},
            TURN_TIMEOUT,
        )
        wire.settle(1.0)
        if error is not None:
            summary["load_replay"] = {"error": error.get("code")}
        else:
            replayed = chunks_for(wire, forked, load_mark)
            summary["load_replay"] = {
                "user_message_chunk": replayed.count("user_message_chunk"),
                "agent_message_chunk": replayed.count("agent_message_chunk"),
            }

        summary["unprompted_reload"] = unprompted_reload(wire, parent, cwd, args, out)

        verdicts = ("new_id", "no_replay", "inherited", "parent_quiet")
        summary["fork"] = "ok" if all(summary.get(v) == "ok" for v in verdicts) else "fail"
        return summary
    finally:
        wire.close()
        if out:
            with open(os.path.join(out, "summary.json"), "w", encoding="utf-8") as handle:
                json.dump(summary, handle, indent=2, sort_keys=True)
                handle.write("\n")


def main():
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    parser.add_argument("--out", help="directory for summary.json and wire.jsonl")
    parser.add_argument("--adapter", default=DEFAULT_ADAPTER, help="adapter executable")
    parser.add_argument("--cwd", default=os.getcwd(), help="project directory of the session")
    parser.add_argument("--capabilities-only", action="store_true", help="initialize only")
    args = parser.parse_args()
    if not args.capabilities_only and not args.out:
        parser.error("--out is required unless --capabilities-only")
    args.adapter = [args.adapter]
    try:
        summary = run(args)
    except EnvironmentProblem as problem:
        print(json.dumps({"environment": str(problem)}), file=sys.stderr)
        return 2
    print(json.dumps(summary, sort_keys=True))
    if args.capabilities_only:
        return 0 if summary["capability"] == "ok" else 1
    return 0 if summary["capability"] == "ok" and summary["fork"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
