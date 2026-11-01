#!/usr/bin/env bash
# The matchers and predicates are invoked through check/either/expect, which shellcheck cannot follow.
# shellcheck disable=SC2329
# Story 072, task 5.4 — on Zed a4b39c38, the build opens as Zeo 0.7.1 and the three surfaces the
# carry touched still render, off-desktop, with no model turn (E2E).
#
#     run.sh --binary <zeo-editor built from zeo-0.7.1_p20261101> --out <docs/assets/072-a4b3-proof>
#            [--version <X.Y.Z>]      (default 0.7.1)
#     run.sh --self-test              (the pure matchers only: no display, no editor)
#
# What it proves (R4.4, R2.2, R2.3, Q9). Hostile halves first, per surface:
#   0049 Pinned section (R2.2: the carry rewrote it for upstream's iterator-returning
#        workspaces_for_project_group and Option<&RemoteConnectionOptions> host()). Seeded: in
#        project alpha, Apricot (pinned 2nd), Blueberry and Kumquat (unpinned); in project delta,
#        open in no window, Damson (pinned 1st).
#     h1 Blueberry, unpinned, stays above the "Pinned" header (does not collapse into it);
#     h2 Apricot, pinned, is in the sidebar exactly once (it left its group, not copied);
#     h3 Damson, pinned last-but-newest (position 0), is drawn ABOVE Apricot (position 1);
#     c1 the "Pinned" header is drawn and both pinned rows sit below it;
#     c2 Damson's row is labelled "delta", the project open nowhere.
#   0005 multiline elicitation field (R2.3: upstream's default validation kept, the multiline field
#        on top). A deterministic stub ACP agent (written by this script, `python3 -I`, no model,
#        no network) answers the prompt ELICIT with `elicitation/create`: a form with Notes
#        (string, default ORCHID) and Code (string, maxLength 3, default PEONY).
#     h4 PEONY, a default its own schema rejects, is not prefilled (upstream's
#        validate_string_value survived the conflict);
#     h5 after End, shift+Return and TULIP in Notes, TULIP is NOT on ORCHID's row (a single-line
#        editor would keep it there, or swallow the newline);
#     c3 the card is drawn (its message KESTREL, both titles) and the valid default ORCHID is
#        prefilled (a validation that dropped every default would fail here);
#     c4 TULIP is on the line below ORCHID, in the same column.
#   0044 composer history. Seeded: Kumquat's body holds two user messages, HERON then OSPREY. The
#        composer is focused empty, then Up, then Up again. Counted as word boxes on the screen:
#        the transcript holds one of each, so a recalled message makes its count two.
#     h6 before Up: one HERON and one OSPREY (control: the composer starts empty);
#     h7 after one Up: still one HERON (the newest is recalled first, not the oldest);
#     h8 after two Ups: back to one OSPREY (a recall replaces the composer, it does not append);
#     c5 after one Up: two OSPREY;  c6 after two Ups: two HERON.
#   about: the About names "Zeo <version>" (default 0.7.1), never 0.7.10, 0.7.0 or 10.7.1.
#
# No model turn: the seeded threads belong to the native agent and are only opened, never sent;
# the stub's turn is a deterministic script. No API token is read anywhere.
#
# How (059's recipe for the seeded part: one --keep profile, one xvfb-proof.sh run per phase, a
# point found in one phase's capture used in the next; 064's for the stub: a FRESH profile per run,
# because the elicitation lives only as long as the stub process, so run E1 captures and run E2
# repeats the same steps and points there). Profiles live under a fresh mktemp dir, never the
# operator's. Keymap: ctrl-alt-j opens a thread on the stub (agent::NewExternalAgentThread).
#   P0  launch: databases and migrations; seed sidebar_threads, thread_organization, threads.db
#   P1  open alpha and the threads sidebar: the Pinned checks
#   P2  relaunch, open Kumquat: its transcript, and where the composer's placeholder is
#   P3  relaunch, open Kumquat, click the placeholder, Up, Up; then the About
#   E1  fresh profile: open alpha, a stub thread, send ELICIT: the card, where ORCHID is
#   E2  fresh profile: the same, then click ORCHID, End, shift+Return, TULIP
#
# Red: deferred to Run mode. Against the installed 0.7.0 (Zed a5c4ca8b) the About reads 0.7.0 and
# PEONY is prefilled (a5c4ca8b has no default validation): h4 and about fail, exit 1.
#
# Tuning: the sleeps, the agent dock (left, 900 px, 061's layout), the sidebar span and the
# line/column tolerances (MIN_LINE, MAX_LINE, COLUMN) are first guesses at 1920x1080. Tune them
# in Run mode and record what changed in the README; never change a verdict.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager, no network, no model.
# Not covered: Wayland, GPU, a real adapter's elicitation (Claude Agent (Plus)), submitting the
# form, pinning through the UI (032's run-ui.sh), sending a recalled message.
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, the
# stub never received the prompt, a capture could not be read or located).

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run.sh: %s\n' "$*" >&2
	exit "${code}"
}

# ── Pure matchers: exercised by --self-test, which needs no display ───────
SCALE=3
# Two lines of the editor's text are this far apart, centre to centre, in screen pixels.
MIN_LINE=8 MAX_LINE=60 COLUMN=24
# names_version <text> <X.Y.Z>: "Zeo X.Y.Z" not followed by a digit, dots literal (059).
names_version() {
	grep -qE "Zeo ${2//./\\.}([^0-9]|\$)" <<<"$1"
}
# word_boxes <word> [left right top] < tesseract TSV (3x): "cx cy left top" in screen pixels of
# every box reading exactly <word> (trailing punctuation dropped, and a caret OCR'd as `|` at either
# end, tuned at run time 2026-11-01), inside the region when given.
# "Apricots", "apricot" or "ORCHIDTULIP" are not the word.
word_boxes() {
	awk -F '\t' -v word="$1" -v l="${2:-}" -v r="${3:-}" -v t="${4:-}" -v s="${SCALE}" '
		NR > 1 && $12 != "" {
			text = $12; sub(/[.,:;!?]+$/, "", text); sub(/^\|/, "", text); sub(/\|$/, "", text)
			if (text != word) next
			x = ($7 + $9 / 2) / s; y = ($8 + $10 / 2) / s
			if (l != "" && (x < l || x >= r || y <= t)) next
			printf "%d %d %d %d\n", x, y, $7 / s, $8 / s
		}'
}
count_word() { # <word> [region] < TSV
	word_boxes "$@" | wc -l
}
# next_line_below <upper> <lower> < TSV: a <lower> box on the line under the first <upper> box,
# starting in the same column. Same row, a far field, another column or above: not.
next_line_below() {
	local tsv uy ul ly ll
	tsv="$(cat)"
	read -r _ uy ul _ < <(word_boxes "$1" <<<"${tsv}" | head -1) || return 1
	while read -r _ ly ll _; do
		local dy=$((ly - uy)) dx=$((ll - ul))
		((dx < 0)) && dx=$((-dx))
		if ((dy >= MIN_LINE && dy <= MAX_LINE && dx <= COLUMN)); then return 0; fi
	done < <(word_boxes "$2" <<<"${tsv}")
	return 1
}
# on_same_row <upper> <lower> < TSV: a <lower> box whose centre is within MIN_LINE of <upper>'s.
on_same_row() {
	local tsv uy ly
	tsv="$(cat)"
	read -r _ uy _ _ < <(word_boxes "$1" <<<"${tsv}" | head -1) || return 1
	while read -r _ ly _ _; do
		local dy=$((ly - uy))
		((dy < 0)) && dy=$((-dy))
		((dy < MIN_LINE)) && return 0
	done < <(word_boxes "$2" <<<"${tsv}")
	return 1
}
# row_has <prefix> <row y> <left> <right> < TSV: 059's — a box starting with <prefix> on the row.
ROW_TOLERANCE=8
# A sidebar row's project label sits on its second line, this far below the title's centre
# (measured at run time, 2026-11-01: Damson 221, "delta" 243).
SUBTITLE_DY=22
row_has() {
	awk -F '\t' -v word="$1" -v y="$2" -v l="$3" -v r="$4" -v s="${SCALE}" -v tol="${ROW_TOLERANCE}" '
		NR > 1 && $12 != "" && index(tolower($12), tolower(word)) == 1 {
			x = ($7 + $9 / 2) / s; d = ($8 + $10 / 2) / s - y; if (d < 0) d = -d
			if (x >= l && x < r && d <= tol) found = 1
		}
		END { exit !found }'
}

self_test() {
	local bad=0 head
	expect() { # <0|1> <why> <command...>
		local want="$1" why="$2" got=0
		shift 2
		"$@" || got=1
		if [[ "${got}" == "${want}" ]]; then printf 'ok    %s\n' "${why}"; else
			printf 'FAIL  %s\n' "${why}"
			bad=1
		fi
	}
	expect_count() { # <n> <why> <tsv> <word> [region]
		local n="$1" why="$2" tsv="$3" got
		shift 3
		got="$(count_word "$@" <<<"${tsv}")"
		if [[ "${got}" == "${n}" ]]; then printf 'ok    %s\n' "${why}"; else
			printf 'FAIL  %s (counted %s, want %s)\n' "${why}" "${got}" "${n}"
			bad=1
		fi
	}
	# box <text> <left> <top> at 1x; the TSV is 3x, as tesseract reads the enlarged capture.
	box() { printf '5\t1\t1\t1\t1\t1\t%d\t%d\t%d\t%d\t90\t%s\n' "$(($2 * 3))" "$(($3 * 3))" 120 45 "$1"; }
	head=$'level\tpage\tblock\tpar\tline\tword\tleft\ttop\twidth\theight\tconf\ttext\n'
	local orchid tulip_row tulip_far tulip_col tulip_above glued tulip_next
	orchid="$(box ORCHID 600 400)"
	tulip_row="${head}${orchid}"$'\n'"$(box TULIP 700 400)"
	tulip_far="${head}${orchid}"$'\n'"$(box TULIP 600 520)"
	tulip_col="${head}${orchid}"$'\n'"$(box TULIP 900 420)"
	tulip_above="${head}${orchid}"$'\n'"$(box TULIP 600 380)"
	glued="${head}$(box ORCHIDTULIP 600 400)"
	tulip_next="${head}${orchid}"$'\n'"$(box TULIP 600 420)"
	# Hostile first — what would make each check fire wrongly.
	expect 1 "TULIP on ORCHID's row is not a second line" next_line_below ORCHID TULIP <<<"${tulip_row}"
	expect 1 "TULIP glued to ORCHID is not a second line" next_line_below ORCHID TULIP <<<"${glued}"
	expect 1 "TULIP in a field far below is not the next line" next_line_below ORCHID TULIP <<<"${tulip_far}"
	expect 1 "TULIP below in another column is not the next line" next_line_below ORCHID TULIP <<<"${tulip_col}"
	expect 1 "TULIP above ORCHID is not the next line" next_line_below ORCHID TULIP <<<"${tulip_above}"
	expect 1 "no ORCHID at all is not a second line" next_line_below ORCHID TULIP <<<"${head}$(box TULIP 600 420)"
	expect 0 "TULIP on ORCHID's row is on the same row" on_same_row ORCHID TULIP <<<"${tulip_row}"
	expect 1 "TULIP on the next line is not on the same row" on_same_row ORCHID TULIP <<<"${tulip_next}"
	local herons apricot_twice outside
	herons="${head}$(box HERONS 300 300)"$'\n'"$(box heron 300 340)"$'\n'"$(box HERON 300 380)"
	expect_count 1 "HERONS and heron are not HERON" "${herons}" HERON
	expect_count 2 "a trailing full stop is still the word" "${head}$(box HERON 300 300)"$'\n'"$(box HERON. 300 600)" HERON
	apricot_twice="${head}$(box Apricot 250 200)"$'\n'"$(box Apricot 250 600)"
	expect_count 2 "a pinned row left in its group is counted twice" "${apricot_twice}" Apricot 194 454 80
	outside="${head}$(box Apricot 250 200)"$'\n'"$(box Apricot 1200 200)"
	expect_count 1 "a title outside the sidebar is not a sidebar row" "${outside}" Apricot 194 454 80
	expect_count 1 "a word above the sidebar's top is not a row" "${head}$(box Apricot 250 200)"$'\n'"$(box Apricot 250 40)" Apricot 194 454 80
	expect 1 "refuses 0.7.10 for 0.7.1" names_version "Zeo 0.7.10" 0.7.1
	expect 1 "refuses the previous release" names_version "Zeo 0.7.0" 0.7.1
	expect 1 "refuses a leading digit" names_version "Zeo 10.7.1" 0.7.1
	expect 1 "refuses any character for a dot" names_version "Zeo 0x7y1" 0.7.1
	expect 1 "refuses Zed's own version" names_version "Zed 0.7.1" 0.7.1
	expect 1 "a project label on the next row is not on this one" row_has delta 200 194 454 <<<"${head}$(box delta 300 230)"
	# Then what each check exists to find.
	expect 0 "TULIP on the next line, same column" next_line_below ORCHID TULIP <<<"${tulip_next}"
	expect 0 "names 0.7.1 before the PF suffix" names_version "Zeo 0.7.1_p20261101" 0.7.1
	expect 0 "names 0.7.1 on its own line" names_version $'About\nZeo 0.7.1\nZed 1.28.0' 0.7.1
	expect 0 "the project label on the row" row_has delta 200 194 454 <<<"${head}$(box delta 300 195)"
	exit "${bad}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
BINARY=""
OUT=""
VERSION="0.7.1"
while (($#)); do
	case "$1" in
	--self-test) self_test ;;
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--version) VERSION="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor: ${BINARY:-<empty>}"
[[ "$(realpath -- "${BINARY}")" != /usr/bin/zeo ]] ||
	die 2 "/usr/bin/zeo is the CLI launcher (it forwards to a running Zeo); pass the zeo-editor binary"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 2 "--version must be X.Y.Z, got: ${VERSION:-<empty>}"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in tesseract xdotool Xvfb sqlite3 jq python3 awk realpath sha256sum; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then MAGICK=(magick); elif command -v convert >/dev/null; then
	MAGICK=(convert)
else die 2 "missing tool: magick (ImageMagick)"; fi
python3 -c 'import PIL' 2>/dev/null || die 2 "missing python3 Pillow (the About crop)"

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
# Captures left by an earlier run would be read as this run's.
rm -f -- "${OUT}"/p[0-9]-*.png "${OUT}"/e[0-9]-*.png "${OUT}/README.md"
# /tmp, not TMPDIR: xvfb-proof.sh caps the workdir at 60 bytes (Unix socket paths).
STATE="$(mktemp -d /tmp/zp072-XXXX)"
PROFILE="${STATE}/zeo"
ALPHA="${STATE}/p/alpha"
DELTA="${STATE}/p/delta"
mkdir -p -- "${ALPHA}" "${DELTA}"
printf 'alpha\n' >"${ALPHA}/README"
printf 'delta\n' >"${DELTA}/README"
STUB="${STATE}/stub_elicit.py"
STUB_LOG="${STATE}/stub.log"

# ── The stub agent: ACP v1 over stdio, one JSON message per line. It never calls a model and never
# touches the network. ELICIT in a prompt sends one form elicitation and holds the turn open until
# the form is answered (or the session cancelled), so the card stays on screen for the captures.
cat >"${STUB}" <<'PY'
import json, os, sys, time

LOG = os.environ.get("STUB_LOG")
pending = {}  # elicitation request id -> prompt request id
counter = 0


def log(event, **fields):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"ts": round(time.time(), 3), "event": event, **fields}, sort_keys=True) + "\n")


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def form(session_id):
    return {"sessionId": session_id, "mode": "form", "message": "KESTREL form",
            "requestedSchema": {"type": "object", "required": ["notes"], "properties": {
                "notes": {"type": "string", "title": "Notes", "default": "ORCHID"},
                "code": {"type": "string", "title": "Code", "maxLength": 3, "default": "PEONY"}}}}


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        log("unparsable", length=len(line))
        continue
    method, rid, params = message.get("method"), message.get("id"), message.get("params") or {}
    if method is None:
        prompt_id = pending.pop(rid, None)
        log("elicitation_answered", id=rid, result=message.get("result"), error=message.get("error"))
        if prompt_id is not None:
            send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn"}})
        continue
    log("received", method=method)
    if rid is None:
        if method == "session/cancel":
            for eid, prompt_id in list(pending.items()):
                send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "cancelled"}})
                pending.pop(eid)
        continue
    if method == "initialize":
        offered = (params.get("clientCapabilities") or {}).get("elicitation") or {}
        log("initialize", form_offered=("form" in offered))
        send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1,
              "agentCapabilities": {"loadSession": False}, "authMethods": []}})
    elif method == "session/new":
        counter += 1
        send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": f"stub-072-{counter}"}})
    elif method == "session/prompt":
        words = " ".join(p.get("text", "") for p in params.get("prompt") or [] if isinstance(p, dict))
        if "ELICIT" in words:
            eid = f"elicit-{rid}"
            pending[eid] = rid
            send({"jsonrpc": "2.0", "id": eid, "method": "elicitation/create", "params": form(params.get("sessionId", ""))})
            log("elicit_sent", id=eid, session=params.get("sessionId", ""))
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
    else:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"not supported by the stub: {method}"}})
log("eof")
PY

jq -n --arg stub "${STUB}" --arg log "${STUB_LOG}" '{
  use_system_path_prompts: false,
  use_system_prompts: false,
  cursor_blink: false,
  session: { trust_all_worktrees: true },
  agent: { dock: "left", default_width: 900.0 },
  agent_servers: {
    "Elicit Stub": { type: "custom", command: "python3", args: ["-I", $stub], env: { STUB_LOG: $log } }
  }
}' >"${STATE}/settings.json"
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Elicit Stub"}]}}]
JSON
printf 'binary: %s\nversion: %s\nstate: %s\nout: %s\n' "${BINARY}" "${VERSION}" "${STATE}" "${OUT}"

# ── Verdicts, kept for the README ─────────────────────────────────────────
failed=0
RESULTS=()
verdict() { # <PASS|FAIL> <id> <capture> <text>
	RESULTS+=("| $2 | $4 | **$1** | \`$3\` |")
	if [[ "$1" == PASS ]]; then printf 'ok    [%s] %s (%s)\n' "$2" "$4" "$3"; else
		printf 'FAIL  [%s] %s (%s)\n' "$2" "$4" "$3"
		failed=1
	fi
}
check() { # <id> <capture> <why> <command...>: PASS when the command succeeds
	local id="$1" capture="$2" why="$3"
	shift 3
	if "$@"; then verdict PASS "${id}" "${capture}" "${why}"; else verdict FAIL "${id}" "${capture}" "${why}"; fi
}

# ── Steps and the harness ─────────────────────────────────────────────────
steps() { # <name> <JSON step objects...>
	local file="${STATE}/steps-$1.json"
	shift
	printf '%s\n' "$@" | jq -s '.' >"${file}" || die 2 "cannot write ${file}"
	printf '%s' "${file}"
}
at() { jq -cn --arg k "$1" --argjson x "$2" --argjson y "$3" '{($k): [$x, $y]}'; }
shot() { jq -cn --arg p "${OUT}/$1" '{shot: $p}'; }
typed() { jq -cn --arg t "$1" '{type: $t}'; }
AWAY="$(at move 1700 1000)"
# The steps are validated (--dry-run) first, so a refusal is this script's fault (exit 2) and an
# exit 1 during the run is Zeo or the input failing.
harness() { # <name> <profile dir> <steps file>
	local status=0
	"${HARNESS}" --dry-run --steps "$3" >/dev/null || die 2 "xvfb-proof.sh refused the steps of $1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keymap "${STATE}/keymap.json" \
		--keep "$2" --steps "$3" || status=$?
	case "${status}" in
	0) ;;
	1)
		printf 'FAIL  %s: Zeo or the input failed during the run (exit 1 from the harness)\nstate kept: %s\n' "$1" "${STATE}"
		exit 1
		;;
	*) die 2 "xvfb-proof.sh failed on $1 (exit ${status})" ;;
	esac
}
# 059's tuned recipe for one project: workspace::Open, the path, then the threads sidebar.
OPEN=('{"sleep": 15}' '{"chord": ["ctrl", "k"]}' '{"chord": ["ctrl", "o"]}' '{"sleep": 2}'
	'{"chord": ["ctrl", "a"]}' "$(typed "${ALPHA}/")" '{"sleep": 1}' '{"key": ["Return"]}'
	'{"sleep": 8}' '{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}')

# ── OCR (059's recipe): red channel and greyscale, 3x, thresholded. Text checks count when any
# reading has the phrase; box checks read the red channel first, then grey. Every cache is filled
# in the main shell, never inside $(…), so a tesseract failure exits 2.
declare -A OCR_CACHE=() TSV_CACHE=()
to_pgm() { # <png> <pgm> <red|grey>
	local args=()
	if [[ "$3" == red ]]; then args+=(-channel R -separate +channel); else args+=(-colorspace Gray); fi
	"${MAGICK[@]}" "$1" "${args[@]}" -resize "$((SCALE * 100))%" -threshold 70% -depth 8 "PGM:$2" ||
		die 2 "cannot convert $1 for tesseract"
}
load_ocr() { # <capture>
	local pgm="${STATE}/ocr.pgm" mode psm text all=""
	[[ -z "${OCR_CACHE[$1]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	for mode in red grey; do
		to_pgm "${OUT}/$1" "${pgm}" "${mode}"
		for psm in 3 11; do
			text="$(tesseract "${pgm}" - --psm "${psm}" 2>/dev/null)" || die 2 "tesseract could not read $1"
			all+=" ||| ${text//$'\n'/ }"
		done
	done
	OCR_CACHE[$1]="${all}"
}
reads() { # <capture> <text>
	load_ocr "$1"
	[[ "${OCR_CACHE[$1]}" == *"$2"* ]]
}
lacks() { ! reads "$@"; }
reads_all() { # <capture> <text...>
	local capture="$1" text
	shift
	for text in "$@"; do reads "${capture}" "${text}" || return 1; done
}
# holds <arithmetic expression>: the checks' comparisons, named so a verdict reads as its rule.
holds() { (("$1")); }
load_tsv() { # <capture> <red|grey>
	local key="$1|$2"
	[[ -z "${TSV_CACHE[${key}]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	to_pgm "${OUT}/$1" "${STATE}/box.pgm" "$2"
	TSV_CACHE[${key}]="$(tesseract "${STATE}/box.pgm" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
}
load_tsvs() { load_tsv "$1" red && load_tsv "$1" grey; }
# most <capture> <word> [region]: the largest count over both readings (a "must be one" check only
# gets stricter, as in 059).
MOST=0
most() {
	local capture="$1" mode n key
	shift
	load_tsvs "${capture}"
	MOST=0
	for mode in red grey; do
		key="${capture}|${mode}"
		n="$(count_word "$@" <<<"${TSV_CACHE[${key}]}")"
		((n > MOST)) && MOST="${n}"
	done
	return 0
}
# locate <capture> <word> <prefix> [region] [first|last]: sets <prefix>X/<prefix>Y/<prefix>L/<prefix>T
# from the topmost (or bottommost) box, red reading first; exit 2 when neither reading has it.
locate() {
	local capture="$1" word="$2" prefix="$3" pick="${5:-first}" mode line="" key
	load_tsvs "${capture}"
	for mode in red grey; do
		key="${capture}|${mode}"
		# shellcheck disable=SC2086 # the region is three numbers or nothing
		line="$(word_boxes "${word}" ${4:-} <<<"${TSV_CACHE[${key}]}" | sort -n -k2 |
			if [[ "${pick}" == last ]]; then tail -1; else head -1; fi)"
		[[ -n "${line}" ]] && break
	done
	[[ -n "${line}" ]] || die 2 "\"${word}\" was not boxed in ${capture}"
	read -r "${prefix}X" "${prefix}Y" "${prefix}L" "${prefix}T" <<<"${line}"
}
# Whether a predicate over a TSV holds on either reading.
either() { # <capture> <predicate...>
	local capture="$1" mode key
	shift
	load_tsvs "${capture}"
	for mode in red grey; do
		key="${capture}|${mode}"
		"$@" <<<"${TSV_CACHE[${key}]}" && return 0
	done
	return 1
}

# The sidebar's box, measured on p1-sidebar from its search field (059): from "Search"'s left edge
# minus 24 px to SIDEBAR_SPAN px right of it, below that row.
SIDEBAR_SPAN=260
REGION=""
# Set by locate (<prefix>X/Y/L/T); declared here so every later use is visibly assigned.
SB_L="" SB_T="" APRICOT_Y="" BLUEBERRY_Y="" DAMSON_Y="" KUMQUAT_X="" KUMQUAT_Y=""
MSG_X="" MSG_Y="" K2_X="" K2_Y="" OR_X="" OR_Y="" OR_L=""
measure_sidebar() {
	locate "$1" Search SB_
	REGION="$((SB_L - 24)) $((SB_L + SIDEBAR_SPAN)) $((SB_T + 10))"
	printf 'sidebar: x %s..%s, below y %s\n' "$((SB_L - 24))" "$((SB_L + SIDEBAR_SPAN))" "$((SB_T + 10))"
}

# ── P0: first launch, then seed ───────────────────────────────────────────
harness P0 "${PROFILE}" "$(steps P0 '{"sleep": 20}')"
has_table() { [[ "$(sqlite3 "$1" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$2'")" == 1 ]]; }
DB=""
while IFS= read -r -d '' candidate; do
	if has_table "${candidate}" sidebar_threads; then
		DB="${candidate}"
		break
	fi
done < <(find "${PROFILE}" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database under ${PROFILE} holds sidebar_threads: the editor did not start"
has_table "${DB}" thread_organization || die 2 "${DB} has no thread_organization: not a Zeo build (0048)"
THREADS_DB="$(find "${PROFILE}" -path '*/threads/threads.db' -print -quit)"
[[ -n "${THREADS_DB}" ]] || die 2 "no threads/threads.db under ${PROFILE}: the native agent store was not created"
printf 'database: %s\nthreads: %s\n' "${DB}" "${THREADS_DB}"

APRICOT="72a1000000000000000000000000000a" BLUEBERRY="72a1000000000000000000000000000b"
KUMQUAT="72a1000000000000000000000000000c" DAMSON="72a1000000000000000000000000000d"
t() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
# agent_id NULL is the native agent's id: no agent server and no model turn. Position 0 is the
# newest pin (032), so Damson is drawn first. One word per title, none equal to a message word.
sqlite3 "${DB}" <<SQL || die 2 "seeding ${DB} failed"
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'${APRICOT}', 'p072-apricot', NULL, 'Apricot', '$(t '-1 hour')', '$(t '-1 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${BLUEBERRY}', 'p072-blueberry', NULL, 'Blueberry', '$(t '-2 hour')', '$(t '-2 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${KUMQUAT}', 'p072-kumquat', NULL, 'Kumquat', '$(t '-3 hour')', '$(t '-3 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${DAMSON}', 'p072-damson', NULL, 'Damson', '$(t '-4 hour')', '$(t '-4 hour')', '${DELTA}', '0', 0, '${DELTA}', '0');
INSERT INTO thread_organization (thread_id, pinned_position) VALUES (X'${DAMSON}', 0), (X'${APRICOT}', 1);
SQL
# The body opened from the sidebar (DbThread 0.3.0 as plain JSON, 059): HERON, then OSPREY.
KUMQUAT_BODY="$(jq -cn --arg at "$(t '-3 hour')" '{
	version: "0.3.0", title: "Kumquat", updated_at: $at,
	messages: [{User: {id: "p072-kumquat-1", content: [{Text: "HERON"}]}},
		{Agent: {content: [{Text: "Seeded answer one."}], tool_results: {}}},
		{User: {id: "p072-kumquat-2", content: [{Text: "OSPREY"}]}},
		{Agent: {content: [{Text: "Seeded answer two."}], tool_results: {}}}]}')"
sqlite3 "${THREADS_DB}" "INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, folder_paths_order, created_at)
	VALUES ('p072-kumquat', 'Kumquat', '$(t '-3 hour')', 'json', CAST('${KUMQUAT_BODY}' AS BLOB), '${ALPHA}', '0', '$(t '-3 hour')')" ||
	die 2 "seeding Kumquat's body into ${THREADS_DB} failed"

# ── P1: the Pinned section ────────────────────────────────────────────────
harness P1 "${PROFILE}" "$(steps P1 "${OPEN[@]}" "${AWAY}" '{"sleep": 1}' "$(shot p1-sidebar.png)")"
[[ -s "${OUT}/p1-sidebar.png" ]] || die 2 "no p1-sidebar capture: the editor did not open a window"
measure_sidebar p1-sidebar.png
for word in Apricot Blueberry Kumquat Damson; do
	locate p1-sidebar.png "${word}" "${word^^}_" "${REGION}"
done
PIN_Y=""
load_tsvs p1-sidebar.png
for mode in red grey; do
	key="p1-sidebar.png|${mode}"
	# shellcheck disable=SC2086 # REGION is three numbers
	line="$(word_boxes Pinned ${REGION} <<<"${TSV_CACHE[${key}]}" | head -1)"
	if [[ -n "${line}" ]]; then
		read -r _ PIN_Y _ _ <<<"${line}"
		break
	fi
done
if [[ -n "${PIN_Y}" ]]; then
	verdict PASS c1 p1-sidebar.png "the sidebar draws a \"Pinned\" header (y ${PIN_Y})"
	check h1 p1-sidebar.png "unpinned Blueberry (y ${BLUEBERRY_Y}) stays above the header" holds "BLUEBERRY_Y < PIN_Y"
	check c1 p1-sidebar.png "pinned Damson (y ${DAMSON_Y}) and Apricot (y ${APRICOT_Y}) sit below it" \
		holds "DAMSON_Y > PIN_Y && APRICOT_Y > PIN_Y"
else
	verdict FAIL c1 p1-sidebar.png "no \"Pinned\" header in the sidebar"
	verdict FAIL h1 p1-sidebar.png "no header to place unpinned Blueberry against"
fi
# shellcheck disable=SC2086
most p1-sidebar.png Apricot ${REGION}
check h2 p1-sidebar.png "pinned Apricot is in the sidebar once, not also in its group (counted ${MOST})" holds "MOST == 1"
check h3 p1-sidebar.png "Damson (newest pin) is drawn above Apricot" holds "DAMSON_Y < APRICOT_Y"
check c2 p1-sidebar.png "Damson's row is labelled with its project, delta" \
	either p1-sidebar.png row_has delta "$((DAMSON_Y + SUBTITLE_DY))" "$((SB_L - 24))" "$((SB_L + SIDEBAR_SPAN))"

# ── P2: open Kumquat; find the composer's placeholder ─────────────────────
harness P2 "${PROFILE}" "$(steps P2 "${OPEN[@]}" "$(at click "${KUMQUAT_X}" "${KUMQUAT_Y}")" '{"sleep": 4}' \
	"${AWAY}" '{"sleep": 1}' "$(shot p2-thread.png)")"
reads_all p2-thread.png HERON OSPREY ||
	die 2 "Kumquat's seeded messages are not on p2-thread: the body was not opened (seed or click)"
locate p2-thread.png Message MSG_ "" last
# The sidebar lists by recency and opening a thread can move it (059): re-locate Kumquat.
measure_sidebar p2-thread.png
locate p2-thread.png Kumquat K2_ "${REGION}"
printf 'composer placeholder at %s,%s; Kumquat at %s,%s\n' "${MSG_X}" "${MSG_Y}" "${K2_X}" "${K2_Y}"

# ── P3: Up, Up in the empty composer; then the About ──────────────────────
harness P3 "${PROFILE}" "$(steps P3 "${OPEN[@]}" "$(at click "${K2_X}" "${K2_Y}")" '{"sleep": 4}' \
	"$(at click "${MSG_X}" "${MSG_Y}")" '{"sleep": 1}' "${AWAY}" '{"sleep": 1}' "$(shot p3-h0.png)" \
	'{"key": ["Up"]}' '{"sleep": 1}' '{"key": ["End"]}' '{"sleep": 1}' "$(shot p3-h1.png)" \
	'{"key": ["Home"]}' '{"key": ["Up"]}' '{"sleep": 1}' '{"key": ["End"]}' '{"sleep": 1}' "$(shot p3-h2.png)" \
	'{"chord": ["ctrl", "shift", "p"]}' '{"sleep": 1}' "$(typed about)" '{"sleep": 1}' '{"key": ["Return"]}' \
	'{"sleep": 3}' "$(shot p3-about.png)")"
most p3-h0.png HERON
H0_HERON="${MOST}"
most p3-h0.png OSPREY
H0_OSPREY="${MOST}"
((H0_HERON >= 1 && H0_OSPREY >= 1)) || die 2 "the transcript's HERON/OSPREY were not boxed on p3-h0 (OCR recipe)"
check h6 p3-h0.png "before Up: one HERON (${H0_HERON}) and one OSPREY (${H0_OSPREY}), the composer is empty" \
	holds "H0_HERON == 1 && H0_OSPREY == 1"
most p3-h1.png HERON
check h7 p3-h1.png "one Up does not recall the oldest message: HERON counted ${MOST}" holds "MOST == 1"
most p3-h1.png OSPREY
check c5 p3-h1.png "one Up recalls the newest message: OSPREY counted ${MOST}" holds "MOST == 2"
most p3-h2.png OSPREY
check h8 p3-h2.png "a second Up replaces OSPREY, it does not append: OSPREY counted ${MOST}" holds "MOST == 1"
most p3-h2.png HERON
check c6 p3-h2.png "a second Up recalls the older message: HERON counted ${MOST}" holds "MOST == 2"

# The version, as 048 and 059 read it: a centre crop of the About capture, 3x, as 8-bit PGM.
python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("L"); w, h = im.size
box = (w // 2 - 260, h // 2 - 280, w // 2 + 260, h // 2 + 120)
im.crop(box).resize(((box[2] - box[0]) * 3, (box[3] - box[1]) * 3)).save(sys.argv[2])' \
	"${OUT}/p3-about.png" "${STATE}/about.pgm" || die 2 "could not convert the About capture to PGM"
about="$(tesseract "${STATE}/about.pgm" - 2>/dev/null || true)"
check about p3-about.png "the About names Zeo ${VERSION}; OCR: ${about//$'\n'/ }" names_version "${about}" "${VERSION}"

# ── E1/E2: the stub's elicitation, each on a fresh profile ────────────────
ELICIT=("${OPEN[@]}" '{"chord": ["ctrl", "alt", "j"]}' '{"sleep": 10}' "$(typed ELICIT)" '{"key": ["Return"]}'
'{"sleep": 5}' "${AWAY}" '{"sleep": 1}')
sent() { grep -c '"event": "elicit_sent"' "${STUB_LOG}" 2>/dev/null || true; }
harness E1 "${STATE}/e1" "$(steps E1 "${ELICIT[@]}" "$(shot e1-card.png)")"
(($(sent) >= 1)) || die 2 "the stub never sent the elicitation (no ELICIT prompt reached it; see ${STUB_LOG})"
grep -q '"form_offered": true' "${STUB_LOG}" ||
	printf 'note: Zeo did not offer elicitation.form in initialize (the card may still render)\n'
check c3 e1-card.png "the elicitation card is drawn (its message KESTREL)" reads e1-card.png KESTREL
check c3 e1-card.png "both fields are drawn (Notes, Code)" reads_all e1-card.png Notes Code
check h4 e1-card.png "PEONY, a default its schema rejects, is not prefilled" lacks e1-card.png PEONY
check c3 e1-card.png "ORCHID, a valid default, is prefilled" reads e1-card.png ORCHID
locate e1-card.png ORCHID OR_
# The press lands just right of the last glyph; End makes sure the caret is at the end.
harness E2 "${STATE}/e2" "$(steps E2 "${ELICIT[@]}" "$(at click "$((OR_L + (OR_X - OR_L) * 2 + 3))" "${OR_Y}")" \
	'{"sleep": 1}' '{"key": ["End"]}' '{"chord": ["shift", "Return"]}' "$(typed TULIP)" \
	'{"chord": ["shift", "Return"]}' '{"sleep": 1}' \
	"${AWAY}" '{"sleep": 1}' "$(shot e2-multiline.png)")"
(($(sent) >= 2)) || die 2 "the stub did not send the elicitation on E2 (see ${STUB_LOG})"
reads e2-multiline.png TULIP || die 2 "TULIP is on no reading of e2-multiline: the typing did not land in Notes"
if either e2-multiline.png on_same_row ORCHID TULIP; then
	verdict FAIL h5 e2-multiline.png "TULIP is on ORCHID's row: the field did not take a newline"
else
	verdict PASS h5 e2-multiline.png "TULIP is not on ORCHID's row"
fi
check c4 e2-multiline.png "TULIP is on the line below ORCHID, same column (a multiline field)" \
	either e2-multiline.png next_line_below ORCHID TULIP

# ── The record ────────────────────────────────────────────────────────────
result="PROVEN — Zeo ${VERSION} opened; Pinned (0049), the multiline field (0005) and composer history (0044) render"
((failed == 0)) || result="FAILED — see the FAIL rows (exit 1)"
# shellcheck disable=SC2016 # the backticks are Markdown, not a command substitution
{
	printf '# 072 — zeo-0.7.1_p20261101 on Zed a4b39c38: version, Pinned, multiline elicitation, composer history\n\n'
	printf -- '- **Run:** %s, `zed-patches/scripts/proofs/072-a4b3-proof/run.sh --version %s`\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "${VERSION}"
	printf -- '- **Binary:** `%s`, sha256 `%s`\n' "${BINARY}" "$(sha256sum -- "${BINARY}" | cut -d' ' -f1)"
	printf -- '- **Rung:** X11 on Xvfb (llvmpipe), no window manager, isolated `--user-data-dir` profiles under `%s`, no model turn, no network; the elicitation comes from a deterministic stub ACP agent. Not covered: Wayland, GPU, a real adapter'"'"'s elicitation, submitting the form, pinning through the UI, sending a recalled message.\n' "${STATE}"
	printf -- '- **Result:** %s\n\n| Check | What | Result | Capture |\n|---|---|---|---|\n' "${result}"
	printf '%s\n' "${RESULTS[@]}"
} >"${OUT}/README.md"
printf 'state kept for inspection: %s\nrecord: %s/README.md\nrun.sh: %s\n' "${STATE}" "${OUT}" "${result}"
exit "${failed}"
