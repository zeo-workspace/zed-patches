#!/usr/bin/env node
// acp-probe.mjs — drive an ACP adapter over stdio, without Zed, and print what
// crosses the wire.
//
//     acp-probe.mjs init <adapter> [args...]
//     acp-probe.mjs plan <adapter> [--cwd DIR] [--from MODE] [args...]
//     acp-probe.mjs fallback <adapter> [--notices] [args...]
//     acp-probe.mjs load <adapter> --session ID --cwd DIR [args...]
//     acp-probe.mjs ask <adapter> [--cwd DIR] [args...]
//     acp-probe.mjs tasks <adapter> [--cwd DIR] [args...]
//
// <adapter> is an executable (/usr/bin/claude-agent-acp-plus) or a .js entry
// point (dist/index.js), which is run with this node.
//
//   init  send a full-capability `initialize` and print the result as JSON:
//         what the adapter ADVERTISES, read off the wire rather than argued from
//         commits. No model turn, no cost.
//   plan  put a fresh session in plan mode (optionally entering it FROM another
//         mode, e.g. bypassPermissions), ask for a one-step plan, approve it
//         without clearing context, and print the permission options offered and
//         every mode / config update that follows. ONE REAL MODEL TURN on the
//         account the adapter runs as.
//   fallback  for each model the session offers, select it and ask for Auto;
//         print every update that answers. A model without Auto support makes
//         the adapter fall back and warn -- as a `notice` when the client
//         advertised `session.notices` (--notices), as a transcript line
//         otherwise. No model turn, no cost.
//   load  session/load an existing session and count what the replay sends:
//         user and agent message chunks, and the first user text. Loading
//         APPENDS to the transcript, so point it at a copy. No model turn.
//   ask   advertise form elicitation, have the model ask a multi-select
//         AskUserQuestion, answer it by ticking two options AND typing a note,
//         and print what the model says it received. ONE REAL MODEL TURN.
//   tasks have the model start two background shells (`sleep 20`, `sleep 60`),
//         print every `_claude/tasks` snapshot with a timestamp, and send
//         `_claude/tasks/stop` for the second once it runs. Exits 0 only after
//         seeing running -> completed for the first and stopped for the second
//         within 120 s of the prompt; past that it prints what it saw and exits
//         1. A task is told apart by the command of the tool call that started
//         it (`toolCallId`), never by its model-written description. SPENDS
//         MODEL TURNS: the prompt, plus the followup the CLI wakes the model
//         for when a background task ends.
//
// Why it is versioned: every parity round from the 2026-09-11 one on wrote this
// probe fresh into /tmp (acp-probe2..6, acp-probe-plan) and lost it with the
// next cleanup, although it is the only instrument that separates an adapter
// fault from a client fault. Exit: 0 finished · 1 the adapter answered an error
// or the turn timed out · 2 usage.

import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";

const [mode, adapter, ...rest] = process.argv.slice(2);
if (!["init", "plan", "fallback", "load", "ask", "tasks"].includes(mode) || !adapter) {
  console.error(
    "usage: acp-probe.mjs init|plan|fallback|load|ask|tasks <adapter> [--cwd DIR] [--from MODE] [--notices] [--session ID] [args...]",
  );
  process.exit(2);
}

const opts = {
  cwd: process.cwd(),
  from: undefined,
  notices: false,
  session: undefined,
  args: [],
};
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === "--cwd") opts.cwd = rest[++i];
  else if (rest[i] === "--from") opts.from = rest[++i];
  else if (rest[i] === "--notices") opts.notices = true;
  else if (rest[i] === "--session") opts.session = rest[++i];
  else opts.args.push(rest[i]);
}
mkdirSync(opts.cwd, { recursive: true });

// An argument list, never a shell: the adapter path and its arguments are data.
const [command, args] = adapter.endsWith(".js")
  ? [process.execPath, [adapter, ...opts.args]]
  : [adapter, opts.args];
const child = spawn(command, args, {
  cwd: opts.cwd,
  stdio: ["pipe", "pipe", "inherit"],
});

let nextId = 1;
const pending = new Map();
const log = (tag, obj) => console.log(JSON.stringify({ tag, ...obj }));
const send = (msg) =>
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n");
const request = (method, params) => {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
};
const finish = (code) => {
  child.kill();
  process.exit(code);
};

const replay = { user: 0, agent: 0, firstUser: undefined };
// tasks mode: tool call id -> the shell command it ran, and what each task did.
const commands = new Map();
const seen = new Map(); // task id -> Set of statuses observed
let onSnapshot = () => {};
let answerText = "";
let buffer = "";
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.id !== undefined && !msg.method) {
      const waiter = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? waiter.reject(msg.error) : waiter.resolve(msg.result);
    } else if (msg.method === "session/update") {
      const u = msg.params.update;
      if (u.sessionUpdate === "user_message_chunk") {
        replay.user++;
        replay.firstUser ??= u.content?.text?.slice(0, 60);
      } else if (u.sessionUpdate === "agent_message_chunk" && mode === "load")
        replay.agent++;
      else if (u.sessionUpdate === "agent_message_chunk" && mode === "ask")
        answerText += u.content?.text ?? "";
      else if (u.sessionUpdate === "current_mode_update")
        log("MODE", { mode: u.currentModeId });
      else if (u.sessionUpdate === "config_option_update")
        log("CONFIG", {
          mode: u.configOptions.find((o) => o.id === "mode")?.currentValue,
        });
      else if (u.sessionUpdate === "tool_call") {
        log("TOOL", { title: u.title });
        if (typeof u.rawInput?.command === "string")
          commands.set(u.toolCallId, u.rawInput.command);
      } else if (
        u.sessionUpdate === "tool_call_update" &&
        typeof u.rawInput?.command === "string"
      )
        commands.set(u.toolCallId, u.rawInput.command);
      else if (
        u.sessionUpdate === "session_info_update" &&
        u._meta?.["_claude/tasks"]
      ) {
        const snapshot = u._meta["_claude/tasks"];
        log("TASKS", { at: new Date().toISOString(), snapshot });
        for (const t of snapshot.tasks) {
          if (!seen.has(t.id)) seen.set(t.id, new Set());
          seen.get(t.id).add(t.status);
        }
        onSnapshot(snapshot);
      }
      else if (u.sessionUpdate === "notice")
        log("NOTICE", {
          severity: u.severity,
          title: u.title,
          description: u.description,
        });
      else if (u.sessionUpdate === "agent_message_chunk" && mode === "fallback")
        log("TRANSCRIPT", { text: u.content?.text, meta: u._meta });
    } else if (msg.method === "session/request_permission") {
      log("PERMISSION", {
        tool: msg.params.toolCall?.title,
        options: msg.params.options.map(
          (o) => `${o.optionId}:${o.kind}:${o.name}`,
        ),
      });
      // Approve without clearing context: the first allow option that names no reset.
      const pick =
        msg.params.options.find(
          (o) => o.kind.startsWith("allow") && !/clear|fresh/i.test(o.name),
        ) ?? msg.params.options[0];
      log("PICK", { optionId: pick.optionId });
      send({
        id: msg.id,
        result: { outcome: { outcome: "selected", optionId: pick.optionId } },
      });
    } else if (msg.method === "elicitation/create" && mode === "ask") {
      // Tick the first two options of the first question AND type a note: the
      // combination the adapter used to collapse to the note alone.
      const props = msg.params.requestedSchema?.properties ?? {};
      const key = Object.keys(props).find((k) => !k.endsWith("_custom"));
      const options = (props[key]?.items?.anyOf ?? []).map((o) => o.const);
      const content = {
        [key]: options.slice(0, 2),
        [`${key}_custom`]: "and also teal",
      };
      log("ELICIT", { fields: Object.keys(props), answering: content });
      send({ id: msg.id, result: { action: "accept", content } });
    } else if (msg.id !== undefined && msg.method) {
      // fs/terminal requests: this probe offers none of them.
      send({
        id: msg.id,
        error: { code: -32601, message: "not supported by acp-probe" },
      });
    }
  }
});

setTimeout(() => {
  log("TIMEOUT", {});
  finish(1);
}, 240_000).unref();

try {
  const init = await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: {
      fs: { readTextFile: true, writeTextFile: true },
      // tasks: the CLI must run the shells itself, in the background; this
      // probe answers no terminal request.
      terminal: mode !== "tasks",
      _meta: { terminal_output: true, "terminal-auth": true },
      ...(opts.notices ? { session: { notices: {} } } : {}),
      ...(mode === "ask" ? { elicitation: { form: {} } } : {}),
    },
  });
  if (mode === "init") {
    console.log(JSON.stringify(init, null, 2));
    finish(0);
  }

  if (mode === "load") {
    await request("session/load", {
      sessionId: opts.session,
      cwd: opts.cwd,
      mcpServers: [],
    });
    log("REPLAY", replay);
    finish(0);
  }
  const session = await request("session/new", {
    cwd: opts.cwd,
    mcpServers: [],
  });
  log("SESSION", {
    current: session.modes?.currentModeId,
    modes: session.modes?.availableModes?.map((m) => m.id),
  });
  if (mode === "fallback") {
    const models =
      session.configOptions?.find((o) => o.id === "model")?.options ?? [];
    for (const model of models) {
      const value = model.value ?? model.id;
      await request("session/set_mode", {
        sessionId: session.sessionId,
        modeId: "default",
      });
      await request("session/set_config_option", {
        sessionId: session.sessionId,
        configId: "model",
        value,
      });
      log("MODEL", { value });
      await request("session/set_mode", {
        sessionId: session.sessionId,
        modeId: "auto",
      });
      await new Promise((r) => setTimeout(r, 300));
    }
    finish(0);
  }
  if (mode === "ask") {
    const asked = await request("session/prompt", {
      sessionId: session.sessionId,
      prompt: [
        {
          type: "text",
          text:
            "Use the AskUserQuestion tool once, with multiSelect true, to ask which colors I like, " +
            "offering exactly: red, green, blue. Then reply with one line quoting exactly the " +
            "answer the tool returned to you, and nothing else.",
        },
      ],
    });
    log("ANSWER", {
      stopReason: asked.stopReason,
      text: answerText.trim().slice(0, 300),
    });
    finish(0);
  }
  if (mode === "tasks") {
    const sessionId = session.sessionId;
    const taskOf = (snapshot, pattern) =>
      snapshot.tasks.find((t) => pattern.test(commands.get(t.toolCallId) ?? ""));
    let first; // sleep 20: must run, then complete
    let second; // sleep 60: must run, then be stopped by us
    let stopSent = false;
    const done = () =>
      first &&
      second &&
      seen.get(first)?.has("running") &&
      seen.get(first)?.has("completed") &&
      seen.get(second)?.has("stopped");
    const verdict = new Promise((resolve) => {
      onSnapshot = (snapshot) => {
        first ??= taskOf(snapshot, /\bsleep\s+20\b/)?.id;
        const b = taskOf(snapshot, /\bsleep\s+60\b/);
        second ??= b?.id;
        if (b?.status === "running" && !stopSent) {
          stopSent = true;
          request("_claude/tasks/stop", { sessionId, taskId: b.id }).then(
            (result) => log("STOP", { taskId: b.id, result }),
            (error) => {
              log("STOP_ERROR", { taskId: b.id, error });
              finish(1);
            },
          );
        }
        if (done()) resolve(true);
      };
      setTimeout(() => resolve(false), 120_000).unref();
    });
    const turn = request("session/prompt", {
      sessionId,
      prompt: [
        {
          type: "text",
          text:
            "Use the Bash tool twice, both times with run_in_background set to true: first run " +
            "exactly `sleep 20`, then run exactly `sleep 60`. Do not wait for either, do not check " +
            "on them, and do not run anything else. Then reply with the single word: started.",
        },
      ],
    });
    turn.then(
      (result) => log("TURN", { stopReason: result.stopReason }),
      (error) => log("TURN_ERROR", { error }),
    );
    const ok = await verdict;
    log(ok ? "DONE" : "INCOMPLETE", {
      first: first ?? null,
      second: second ?? null,
      seen: Object.fromEntries([...seen].map(([id, s]) => [id, [...s]])),
    });
    finish(ok ? 0 : 1);
  }
  for (const modeId of [opts.from, "plan"].filter(Boolean)) {
    await request("session/set_mode", { sessionId: session.sessionId, modeId });
  }
  const result = await request("session/prompt", {
    sessionId: session.sessionId,
    prompt: [
      {
        type: "text",
        text:
          "Plan only, do not explore: the plan is to create hello.txt containing 'hi'. " +
          "Write that one-step plan and call ExitPlanMode immediately. After approval, stop " +
          "without doing anything else.",
      },
    ],
  });
  log("DONE", { stopReason: result.stopReason });
  finish(0);
} catch (error) {
  log("ERROR", { error });
  finish(1);
}
