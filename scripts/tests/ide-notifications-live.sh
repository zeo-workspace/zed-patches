#!/usr/bin/env bash
# Story 066, sub-task 5.1 (R3.1, R3.4, R4.1): a live `claude` <-> Zeo session pushed both
# IDE notifications, server -> client, in the shape CLI 2.1.316 parses.
#
# Input: the server -> client half of a frame capture, in the format of
# terminal-ide/acp-capture-wrapper.sh's OUT log -- one JSON-RPC message per line (one
# WebSocket text frame each), `=====` session-header lines, nothing else. The direction is
# the file: pass the half Zeo sent, never the CLI's.
#
# The shapes, read from `strings /opt/bin/claude` (2.1.316):
#   method:T("selection_changed"),params:u({selection:u({start:u({line:E(),character:E()}),
#     end:u({line:E(),character:E()})}).nullable().optional(),text:o().optional(),
#     filePath:o().optional()})
#   var ho="at_mentioned",vo=p(()=>u({method:T(ho),params:u({filePath:o(),
#     lineStart:E().optional(),lineEnd:E().optional()})}))
#   ...O=M.lineStart!==void 0?M.lineStart+1:void 0   <- the wire lines are 0-based
#
# Exit 0 when both notifications are there, 1 when one is missing or malformed, 2 when the
# capture cannot be read.
#
# Usage: ide-notifications-live.sh <server-to-client.jsonl>
set -euo pipefail

capture="${1:-}"
if [[ -z "${capture}" || ! -s "${capture}" ]]; then
	echo "usage: ${0##*/} <server-to-client.jsonl>  (a non-empty capture)" >&2
	exit 2
fi
command -v jq >/dev/null || {
	echo "ERROR: jq is required" >&2
	exit 2
}

# Every line but the wrapper's session headers must be one JSON value: a capture with
# anything else in it is not the format this check was written against.
frames="$(grep -v -e '^=====' -e '^[[:space:]]*$' "${capture}" || true)"
if [[ -z "${frames}" ]]; then
	echo "FAIL: ${capture} holds no frames" >&2
	exit 1
fi
if ! jq empty >/dev/null 2>&1 <<<"${frames}"; then
	echo "ERROR: ${capture} has a line that is not JSON; expected acp-capture-wrapper.sh's format" >&2
	exit 2
fi

# A notification is JSON-RPC 2.0 with a method and NO id: a request or a response that
# merely mentions the method name does not count.
nat='(type == "number") and (. >= 0) and (. == floor)'
selections="$(jq -c "
	select(type == \"object\" and .jsonrpc == \"2.0\" and (has(\"id\") | not)
		and .method == \"selection_changed\")
	| select((.params.filePath | type) == \"string\" and .params.filePath != \"\"
		and (.params.text | type) == \"string\"
		and (.params.selection.start.line | ${nat})
		and (.params.selection.start.character | ${nat})
		and (.params.selection.end.line | ${nat})
		and (.params.selection.end.character | ${nat}))" <<<"${frames}")"
mentions="$(jq -c "
	select(type == \"object\" and .jsonrpc == \"2.0\" and (has(\"id\") | not)
		and .method == \"at_mentioned\")
	| select((.params.filePath | type) == \"string\" and .params.filePath != \"\"
		and (.params.lineStart | ${nat}) and (.params.lineEnd | ${nat})
		and .params.lineStart <= .params.lineEnd)" <<<"${frames}")"

status=0
if [[ -z "${selections}" ]]; then
	echo "FAIL: no server->client selection_changed with filePath, text and a 0-based start/end (R3.1)" >&2
	status=1
else
	echo "ok: $(wc -l <<<"${selections}") selection_changed with a file selection (R3.1)"
fi
if [[ -z "${mentions}" ]]; then
	echo "FAIL: no server->client at_mentioned with filePath and 0-based lineStart <= lineEnd (R4.1)" >&2
	status=1
else
	echo "ok: $(wc -l <<<"${mentions}") at_mentioned with filePath and lines (R4.1)"
fi

# 0-based, checked against the session itself: a mention of the selection the editor last
# reported for that file must name the same lines. A 1-based at_mentioned is off by one
# here -- the CLI adds 1 itself. A selection ending at character 0 of a line may be
# mentioned up to the line before it.
off_by="$(jq -s -r '
	reduce .[] as $m ({last: {}, bad: []};
		if $m.method == "selection_changed" and ($m.params.selection | type) == "object"
		then .last[$m.params.filePath] = $m.params.selection
		elif $m.method == "at_mentioned" and (.last[$m.params.filePath] != null)
		then .last[$m.params.filePath] as $s
			| if $m.params.lineStart == $s.start.line
				and ($m.params.lineEnd == $s.end.line
					or ($s.end.character == 0 and $m.params.lineEnd == $s.end.line - 1))
			then . else .bad += ["\($m.params.filePath): mention \($m.params.lineStart)-\($m.params.lineEnd), selection \($s.start.line)-\($s.end.line)"] end
		else . end)
	| .bad[]' <<<"$(jq -c 'select(type == "object" and (has("id") | not)
		and (.params.filePath | type) == "string")' <<<"${frames}")")"
if [[ -n "${off_by}" ]]; then
	echo "FAIL: at_mentioned lines differ from the selection last sent for the file (0-based, R4.1):" >&2
	printf '  %s\n' "${off_by}" >&2
	status=1
fi

if ((status == 0)); then
	echo "PASS: ${capture} holds selection_changed and at_mentioned in the CLI's shape"
fi
exit "${status}"
