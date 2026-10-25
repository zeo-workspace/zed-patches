#!/usr/bin/env bash
# Story 061, task 5.5 — on Zed a5c4ca8b, a native subagent card on a `claude-acp` thread, and an
# unchanged tasks card and sidebar on a Claude Agent (Plus) thread, off-desktop (E2E).
#
#     run.sh --binary <zeo-editor built from zeo-0.7.0_p20261025> --out <docs/assets/061-a5c4-proof>
#            [--plus <claude-agent-acp-plus command>]
#     run.sh --self-test        (the pure matchers only: no display, no editor, no model turn)
#
# What it proves (R4.5, Q9). Both threads are given the SAME request — launch one subagent with a
# one-word description — so the only difference between them is the entry, and each surface is
# checked where it must appear and where it must not. The hostile halves come first:
#   h1  Plus: the subagent WOMBAT is on screen as Plus's tool call, and hovering down the
#       transcript never shows the native card's tooltip ("Click to Preview" / "Click to
#       Collapse"): Plus does not speak the subagents RFD, so a native card there would be the
#       same subagent drawn twice, beside Zeo's task row (PARITY-REPORT §23.1).
#   h2  claude-acp: while its subagent PANGOLIN runs, Zeo's tasks card (0037) is not drawn — no
#       "<n> running" header in the card's region: upstream emits no `_claude/tasks`, and a row
#       there would again be the subagent twice.
#   h3  controls against a check reading the transcript instead of a tooltip: with the pointer
#       parked away, neither the card tooltip nor "Running in the Background" is on screen.
#   c1  claude-acp: hovering down its transcript shows the native card's tooltip — the card the
#       RFD gives a v2 entry after this bump (§23.1: on 92447a17 v2 had no subagent handling).
#   c2  Plus: Zeo's tasks card is drawn with a "<n> running" header and a "Background" chip for
#       the background shell the same prompt starts (0037, unchanged).
#   c3  Plus: after its turn ends, hovering its sidebar row's icon shows "Running in the
#       Background" (0029, unchanged: the turn is idle, the shell still runs).
#
# How: ONE xvfb-proof.sh run (the subagent child and the background shell live in memory, so a
# relaunch would lose both) on an isolated --user-data-dir under a fresh mktemp dir, never the
# operator's profile. The settings declare exactly two agent_servers entries — `claude-acp`
# (type registry: Zeo fetches upstream's claude-agent-acp itself, which needs the network) and
# "Claude Agent (Plus)" running --plus — and a keymap opens a thread on each by name
# (agent::NewExternalAgentThread). The harness replays a fixed step script, so a point cannot be
# read and then used in the same run: where a surface's place is not known in advance, the run
# hovers a line or grid of points and captures each (038's footer scan), and OCR reads them after.
#
# Cost: four short model turns (each thread's turn and each subagent's), on the operator's own
# Claude login (~/.claude, shared by both adapters). The subagents use no tool, so no permission
# prompt can stall the run; Plus's background shell is 041's proven recipe.
#
# Red: deferred to Run mode. Against the installed 0.7.0 (Zed 92447a17) the claude-acp thread
# shows the Agent call as a plain tool call: c1 fails while every control passes, exit 1.
#
# Tuning: CARD_X, the scan ranges, TASKS_CARD and the sidebar grid are first guesses from 041's
# and 038's layouts (1920x1080, window ~1536 wide centred, agent panel docked left at 900 px,
# sidebar at x 194..493 when open). Tune them in Run mode and record what changed in the README;
# never change a verdict.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager, real network and model.
# Not covered: Wayland, GPU, "Stop Subagent", the full-screen child view, a background RFD child
# (story 064), the Agent Tasks panel.
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, no
# claude-acp download, the model did not launch a subagent, a capture could not be read).

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run.sh: %s\n' "$*" >&2
	exit "${code}"
}

# ── Pure matchers: exercised by --self-test, which needs no display ───────
# card_tooltip <text>: the native subagent card's header tooltip meta, collapsed or expanded
# (thread_view.rs, render_subagent_card). Both strings are unique to that card in a5c4ca8b and in
# the series.
card_tooltip() {
	[[ "$1" == *"Click to Preview"* || "$1" == *"Click to Collapse"* ]]
}
# running_header <text>: the tasks card's header count, "<n> running" (0037). A capitalised
# "Running" (a status label, the chip's tooltip) or a bare "running" is not the header.
running_header() {
	grep -qE '(^|[^0-9A-Za-z])[0-9]+ running([^A-Za-z]|$)' <<<"$1"
}
# background_tooltip <text>: 0029's sidebar tooltip, word for word.
background_tooltip() {
	[[ "$1" == *"Running in the Background"* ]]
}
# has_word <text> <WORD>: WORD as a whole word, case-sensitive — PANGOLINS or pangolin is not it.
has_word() {
	grep -qE "(^|[^A-Za-z])$2([^A-Za-z]|\$)" <<<"$1"
}

self_test() {
	local bad=0
	expect() { # <0|1> <why> <command...>
		local want="$1" why="$2" got=0
		shift 2
		"$@" || got=1
		if [[ "${got}" == "${want}" ]]; then printf 'ok    %s\n' "${why}"; else
			printf 'FAIL  %s\n' "${why}"
			bad=1
		fi
	}
	# Hostile first: what would make each check fire wrongly.
	expect 1 "a tool call's own label is not the card" card_tooltip "PANGOLIN Agent"
	expect 1 "a half-read tooltip is not the card" card_tooltip "Click to"
	expect 1 "the chip's tooltip is not the header" running_header "Running in the Background"
	expect 1 "a status label is not the header" running_header "Running"
	expect 1 "a bare word is not the header" running_header "still running here"
	expect 1 "a number after the word is not the header" running_header "running 1"
	expect 1 "the chip's text is not the sidebar tooltip" background_tooltip "Background"
	expect 1 "lower case is not 0029's tooltip" background_tooltip "Running in the background"
	expect 1 "a longer word is not the description" has_word "PANGOLINS" PANGOLIN
	expect 1 "lower case is not the description" has_word "a pangolin" PANGOLIN
	# Then what each check exists to find.
	expect 0 "the collapsed card's tooltip" card_tooltip "PANGOLIN ||| Click to Preview"
	expect 0 "the expanded card's tooltip" card_tooltip "Click to Collapse"
	expect 0 "the header" running_header "Tasks 1 running"
	expect 0 "the header on its own line" running_header $'Tasks\n2 running\nBackground'
	expect 0 "0029's tooltip" background_tooltip "x Running in the Background y"
	expect 0 "the description as a word" has_word "Agent: PANGOLIN." PANGOLIN
	exit "${bad}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
BINARY=""
PLUS="/usr/bin/claude-agent-acp-plus"
OUT=""
while (($#)); do
	case "$1" in
	--self-test) self_test ;;
	--binary) BINARY="${2:-}" && shift ;;
	--plus) PLUS="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor: ${BINARY:-<empty>}"
[[ "$(realpath -- "${BINARY}")" != /usr/bin/zeo ]] ||
	die 2 "/usr/bin/zeo is the CLI launcher (it forwards to a running Zeo); pass the zeo-editor binary"
[[ -n "${PLUS}" && -x "${PLUS}" ]] || die 2 "--plus must name an executable Claude Agent (Plus): ${PLUS:-<empty>}"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in tesseract xdotool Xvfb jq awk realpath find; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then MAGICK=(magick); elif command -v convert >/dev/null; then
	MAGICK=(convert)
else die 2 "missing tool: magick (ImageMagick)"; fi

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
# Captures left by an earlier run would be read as this run's.
rm -f -- "${OUT}"/[ab][0-9]-*.png "${OUT}"/hover-*.png "${OUT}"/side-*.png "${OUT}/README.md"
# /tmp, not TMPDIR: xvfb-proof.sh caps the workdir at 60 bytes (Unix socket paths).
STATE="$(mktemp -d /tmp/zp061-XXXX)"
PROFILE="${STATE}/zeo"
PROJECT="${STATE}/p/alpha"
mkdir -p -- "${PROJECT}"
printf 'alpha\n' >"${PROJECT}/README"
jq -n --arg plus "${PLUS}" '{
  use_system_path_prompts: false,
  use_system_prompts: false,
  cursor_blink: false,
  session: { trust_all_worktrees: true },
  agent: { dock: "left", default_width: 900.0 },
  agent_servers: {
    "claude-acp": { type: "registry" },
    "Claude Agent (Plus)": { type: "custom", command: $plus }
  }
}' >"${STATE}/settings.json"
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-h": ["agent::NewExternalAgentThread", {"agent": "claude-acp"}],
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Claude Agent (Plus)"}]}}]
JSON
printf 'binary: %s\nplus: %s\nstate: %s\nout: %s\n' "${BINARY}" "${PLUS}" "${STATE}" "${OUT}"

# The descriptions are UPPER case and one word each, so OCR can find them and no reply word or
# title is confused with them. The claude-acp subagent writes for a while (no tool, no permission)
# so its run is long enough to be captured; Plus's background shell outlives every capture below.
ACP_PROMPT='Use the Agent tool exactly once, with the description PANGOLIN and this prompt for the subagent: "Without using any tool, write a 250-word story about a pangolin, then stop." Wait for it, then reply with the single word finished.'
PLUS_PROMPT='First use the Agent tool exactly once, with the description WOMBAT and this prompt for the subagent: "Without using any tool, reply with the single word done." Then use the Bash tool with run_in_background set to true to run exactly: sleep 420 -- then reply with the single word started.'

# Points and regions (see Tuning in the header).
CARD_X=500
SCAN_Y0=90 SCAN_Y1=1000 SCAN_STEP=14
# Run-mode tuning (2026-10-25): the card header ("Tasks <n> running") sits at y~91, above the
# first guess +120; the card spans x 482..832, y 76..180 at this layout.
TASKS_CARD="420x300+460+60"
SIDE_XS=(204 216 228 240)
SIDE_Y0=90 SIDE_Y1=270 SIDE_STEP=12

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

# ── Steps and the harness ─────────────────────────────────────────────────
STEPS=()
add() { STEPS+=("$@"); }
at() { jq -cn --arg k "$1" --argjson x "$2" --argjson y "$3" '{($k): [$x, $y]}'; }
shot() { jq -cn --arg p "${OUT}/$1" '{shot: $p}'; }
typed() { jq -cn --arg t "$1" '{type: $t}'; }
pause() { # <seconds>: the harness caps one sleep at 60
	local left="$1"
	while ((left > 0)); do
		add "$(jq -cn --argjson s "$((left > 60 ? 60 : left))" '{sleep: $s}')"
		left=$((left - 60))
	done
}
AWAY="$(at move 1700 1000)"
# hover_line <prefix>: hover down CARD_X, one capture per y, pointer parked away after.
hover_line() {
	local y
	for ((y = SCAN_Y0; y <= SCAN_Y1; y += SCAN_STEP)); do
		add "$(at move "${CARD_X}" "${y}")" '{"sleep": 1}' "$(shot "hover-$1-${y}.png")"
	done
	add "${AWAY}"
}

# Open the project through Zeo's own prompt (041's recipe), then the claude-acp thread. A fresh
# profile fetches the registry agent on first use, hence the long wait.
pause 12
add '{"chord": ["ctrl", "o"]}' '{"sleep": 2}' '{"chord": ["ctrl", "a"]}' "$(typed "${PROJECT}/")" \
	'{"sleep": 1}' '{"key": ["Return"]}' '{"sleep": 8}'
add '{"chord": ["ctrl", "alt", "h"]}'
pause 75
add "$(shot a0-acp-thread.png)" "$(typed "${ACP_PROMPT}")" '{"key": ["Return"]}'
# While the subagent writes: three captures for h2 (no tasks card), then its end and the scan.
for t in 1 2 3; do
	pause 7
	add "$(shot "a${t}-acp-running.png")"
done
pause 60
add "${AWAY}" '{"sleep": 1}' "$(shot a4-acp-done.png)"
hover_line acp
# The Plus thread: same panel, the claude-acp conversation retained beside it.
add '{"chord": ["ctrl", "alt", "j"]}'
pause 12
add "$(shot b0-plus-thread.png)" "$(typed "${PLUS_PROMPT}")" '{"key": ["Return"]}'
pause 45
add "${AWAY}" '{"sleep": 1}' "$(shot b1-plus-tasks.png)"
# The threads sidebar (038's chord), its icon grid while the shell runs, then closed again so the
# transcript is back where hover_line expects it.
add '{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}' "${AWAY}" '{"sleep": 1}' "$(shot b2-sidebar.png)"
for x in "${SIDE_XS[@]}"; do
	for ((y = SIDE_Y0; y <= SIDE_Y1; y += SIDE_STEP)); do
		add "$(at move "${x}" "${y}")" '{"sleep": 1}' "$(shot "side-${x}-${y}.png")"
	done
done
add '{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}'
hover_line plus

STEPS_FILE="${STATE}/steps.json"
printf '%s\n' "${STEPS[@]}" | jq -s '.' >"${STEPS_FILE}" || die 2 "cannot write ${STEPS_FILE}"
# The steps are validated first, so a refusal is this script's fault (exit 2) and an exit 1 during
# the run is Zeo or the input failing.
"${HARNESS}" --dry-run --steps "${STEPS_FILE}" >/dev/null || die 2 "xvfb-proof.sh refused the steps"
status=0
"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keymap "${STATE}/keymap.json" \
	--keep "${PROFILE}" --steps "${STEPS_FILE}" || status=$?
case "${status}" in
0) ;;
1)
	printf 'FAIL  Zeo or the input failed during the run (exit 1 from the harness)\nstate kept: %s\n' "${STATE}"
	exit 1
	;;
*) die 2 "xvfb-proof.sh failed (exit ${status})" ;;
esac

# ── OCR: red channel and greyscale, each read default and sparse (059's recipe). A phrase counts
# when any reading has it, so a "lacks" check only gets stricter. The cache is filled in the main
# shell, never inside $(…), so a tesseract failure exits 2 instead of passing for a missing surface.
SCALE=3
declare -A OCR_CACHE=()
load_ocr() { # <capture> [crop]
	local key="$1|${2:-}" pgm="${STATE}/ocr.pgm" mode psm text all="" args
	[[ -z "${OCR_CACHE[${key}]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	for mode in red grey; do
		args=()
		[[ -n "${2:-}" ]] && args=(-crop "$2" +repage)
		if [[ "${mode}" == red ]]; then args+=(-channel R -separate +channel); else args+=(-colorspace Gray); fi
		"${MAGICK[@]}" "${OUT}/$1" "${args[@]}" -resize "$((SCALE * 100))%" -threshold 70% -depth 8 "PGM:${pgm}" ||
			die 2 "cannot convert $1 for tesseract"
		for psm in 3 11; do
			text="$(tesseract "${pgm}" - --psm "${psm}" 2>/dev/null)" || die 2 "tesseract could not read $1"
			all+=" ||| ${text//$'\n'/ }"
		done
	done
	OCR_CACHE[${key}]="${all}"
}
text_of() { # <capture> [crop] -> sets TEXT
	local key="$1|${2:-}"
	load_ocr "$1" "${2:-}"
	TEXT="${OCR_CACHE[${key}]}"
}
# first_hit <matcher> <glob prefix>: sets HIT to the first capture (by name) the matcher accepts.
first_hit() {
	local f
	HIT=""
	for f in "${OUT}/$2"*.png; do
		[[ -e "${f}" ]] || continue
		text_of "${f##*/}"
		if "$1" "${TEXT}"; then
			HIT="${f##*/}"
			return 0
		fi
	done
	return 1
}

# ── Environment controls: a failure here is not a verdict on the build ────
[[ -s "${OUT}/a0-acp-thread.png" ]] || die 2 "no a0 capture: the editor did not open a window"
# -print -quit: with pipefail, `grep -q` closing the pipe early would fail find with SIGPIPE.
find "${PROFILE}" \( -ipath '*claude-acp*' -o -ipath '*claude-agent-acp*' \) -print -quit | grep -q . ||
	die 2 "no claude-acp download under ${PROFILE}: the registry agent was never fetched (network?)"
first_hit_word() { # <WORD> <glob prefix>
	local f
	for f in "${OUT}/$2"*.png; do
		[[ -e "${f}" ]] || continue
		text_of "${f##*/}"
		has_word "${TEXT}" "$1" && return 0
	done
	return 1
}
first_hit_word PANGOLIN a || die 2 "PANGOLIN is on no claude-acp capture: the model did not launch the subagent"
first_hit_word WOMBAT b || die 2 "WOMBAT is on no Plus capture: the model did not launch the subagent"

# ── h1–h3: what must NOT be on screen ─────────────────────────────────────
if first_hit card_tooltip hover-plus-; then
	verdict FAIL h1 "${HIT}" "a native subagent card on the Plus thread (WOMBAT drawn twice)"
else
	verdict PASS h1 "hover-plus-*.png" "no native subagent card on the Plus thread"
fi
h2=PASS h2_at="a1..a3-acp-running.png"
for t in 1 2 3; do
	text_of "a${t}-acp-running.png" "${TASKS_CARD}"
	if running_header "${TEXT}"; then h2=FAIL h2_at="a${t}-acp-running.png"; fi
done
verdict "${h2}" h2 "${h2_at}" "Zeo's tasks card while claude-acp's subagent runs: $([[ "${h2}" == PASS ]] && echo none || echo drawn)"
for capture in a4-acp-done.png b1-plus-tasks.png b2-sidebar.png; do
	text_of "${capture}"
	if card_tooltip "${TEXT}" || background_tooltip "${TEXT}"; then
		verdict FAIL h3 "${capture}" "a tooltip phrase is on screen with the pointer parked away"
	else
		verdict PASS h3 "${capture}" "no tooltip phrase with the pointer parked away"
	fi
done

# ── c1–c3: what must be on screen ─────────────────────────────────────────
if first_hit card_tooltip hover-acp-; then
	verdict PASS c1 "${HIT}" "the claude-acp thread draws a native subagent card"
else
	verdict FAIL c1 "hover-acp-*.png" "no native subagent card on the claude-acp thread"
fi
text_of b1-plus-tasks.png "${TASKS_CARD}"
if running_header "${TEXT}" && has_word "${TEXT}" Background; then
	verdict PASS c2 b1-plus-tasks.png "Plus: the tasks card shows a running count and a Background chip"
else
	verdict FAIL c2 b1-plus-tasks.png "Plus: no tasks card with a running count and a Background chip"
fi
if first_hit background_tooltip side-; then
	verdict PASS c3 "${HIT}" "Plus: the sidebar row reads Running in the Background"
else
	verdict FAIL c3 "side-*.png" "Plus: no sidebar row reads Running in the Background"
fi

result="$([[ "${failed}" == 0 ]] && echo PROVEN || echo FAILED)"
{
	printf '# 061 — native subagent card and unchanged Plus surfaces on zeo-0.7.0_p20261025\n\n'
	# shellcheck disable=SC2016 # the backticks are Markdown, not a command substitution
	printf 'Binary: `%s` · Plus: `%s` · %s · result: **%s**\n\n' "${BINARY}" "${PLUS}" "$(date -u +%Y-%m-%dT%H:%MZ)" "${result}"
	printf '| check | what | verdict | capture |\n|---|---|---|---|\n'
	printf '%s\n' "${RESULTS[@]}"
} >"${OUT}/README.md"
printf 'state kept for inspection: %s\nrecord: %s/README.md\nrun.sh: %s\n' "${STATE}" "${OUT}" "${result}"
exit "${failed}"
