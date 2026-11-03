#!/usr/bin/env bash
# Story 064, task 9.1 — GUI proof of Zeo's task surfaces on native ACP subagents (E2E).
#
#     run.sh --binary <zeo-editor built from zed-064> --out <docs/assets/064-native-subagents>
#            [--stub-only] [--stop-x <px>] [--claude-acp-command <path>]
#
# What it proves, each against a control from the same run:
#   stub part (deterministic, no model, no network — stub_adapter.py beside this file):
#     1. R1.1 / R5.3: after "TWO", the conversation shows a card for Alpha (sent a message) AND
#        for Bravo (sent none), and the Agent Tasks panel lists both (control c0: the panel
#        before the prompt, with neither);
#     2. R4.1: the parent's turn has ended while both children run, and the sidebar row's
#        tooltip reads "Running in the Background";
#     3. R1.4: Stop on Alpha's panel row sends exactly one `session/cancel`, for "alpha" (the
#        stub's own log, not the screen), never for the parent or "bravo"; Bravo's row stays;
#     4. R5.2: after "WAIT", Bravo's card reads "Waiting for you";
#     5. R3.1 / R3.2: after "BOTH", the panel shows ONE row for Charlie although it was sent as an
#        RFD child and as a `_claude/tasks` entry carrying `childSessionId: "charlie"`, beside
#        the feed-only shell row.
#   claude-acp part (the real upstream adapter through Zeo's `claude-acp` registry entry; one
#   model turn; skipped by --stub-only): a prompt that launches two background subagents shows
#   two cards, two panel rows, and the sidebar's Background tooltip (R1.1, R4.1, R5).
#
# How: xvfb-proof.sh, one FRESH --keep directory per run (an isolated --user-data-dir under a
# mktemp dir, never the operator's profile): a relaunch reopens the last thread, and ACP children
# live only as long as their adapter process, so each run does its whole sequence in one launch.
# The stub is deterministic, so the discovery run and the acting run draw the same layout: run S1
# captures, tesseract's TSV boxes locate the rows, and run S2 repeats the sequence and points
# there (story 036's recipe). Keymap:
#   ctrl-alt-j  agent::NewExternalAgentThread {"agent": "Subagent Stub"}
#   ctrl-alt-u  agent::NewExternalAgentThread {"agent": "claude-acp"} (ctrl-alt-l is lsp_tool::ToggleMenu)
#   ctrl-alt-k  agent_tasks_panel::ToggleFocus
#   ctrl-alt-;  the threads sidebar (032's recipe)
#
# Red is deferred to Run mode (it needs a build of zed-064): on a build without the story the
# panel lists neither child, and the script exits 1 at run S1's first panel check.
#
# Tuning (task 9.1): the Stop control of a panel row is an icon, which OCR cannot read; its x is
# `--stop-x` (first guess below, at the panel row's right end at 1920x1080), its y the y of the
# row's located title. The sleeps, the crop that separates the conversation from the panel, and
# the hover point on the sidebar row are first guesses, to be tuned on a build of zed-064.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland,
# GPU, the tray (R6.1: Zeo runs on a private runtime dir here; the GPUI tests cover it), the
# browser sidebar (R6.2: its GPUI and vitest tests), a Stop on the real adapter (its subagents'
# layout is not reproducible between launches; the stub carries R1.4).
# Remote step (claude-acp part only): the registry entry fetches the upstream adapter with npx
# unless --claude-acp-command names a local install.
# Exit: 0 proven · 1 a check failed · 2 environment problem.

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run.sh: %s\n' "$*" >&2
	exit "${code}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
STUB="${HERE}/stub_adapter.py"
BINARY=""
OUT=""
STUB_ONLY=0
STOP_X=1471
CLAUDE_ACP_COMMAND=""
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--stub-only) STUB_ONLY=1 ;;
	--stop-x) STOP_X="${2:-}" && shift ;;
	--claude-acp-command) CLAUDE_ACP_COMMAND="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
[[ -r "${STUB}" ]] || die 2 "stub adapter not found: ${STUB}"
[[ "${STOP_X}" =~ ^[0-9]+$ ]] || die 2 "--stop-x must be a whole number of pixels"
for tool in tesseract jq magick python3 awk; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
PYTHON="$(command -v python3)"

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp064-XXXX")"
PROJECT="${STATE}/project"
mkdir -p -- "${PROJECT}"
printf 'proof\n' >"${PROJECT}/README"
STUB_LOG="${STATE}/stub.log"
printf 'binary: %s\nstate: %s\n' "${BINARY}" "${STATE}"

if [[ -n "${CLAUDE_ACP_COMMAND}" ]]; then
	CLAUDE_ACP_ENTRY="$(jq -cn --arg c "${CLAUDE_ACP_COMMAND}" '{type: "custom", command: $c, args: []}')"
else
	CLAUDE_ACP_ENTRY='{"type": "registry"}'
fi
jq -n --arg python "${PYTHON}" --arg stub "${STUB}" --arg log "${STUB_LOG}" \
	--argjson acp "${CLAUDE_ACP_ENTRY}" '{
  use_system_path_prompts: false,
  use_system_prompts: false,
  session: { trust_all_worktrees: true },
  agent: { dock: "left", default_width: 900.0 },
  agent_servers: {
    "Subagent Stub": { type: "custom", command: $python, args: ["-I", $stub],
                       env: { SUBAGENT_STUB_LOG: $log } },
    "claude-acp": $acp
  }
}' >"${STATE}/settings.json"
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Subagent Stub"}],
  "ctrl-alt-u": ["agent::NewExternalAgentThread", {"agent": "claude-acp"}],
  "ctrl-alt-k": "agent_tasks_panel::ToggleFocus"}}]
JSON

FAILED=0
ok() { printf 'ok   %s\n' "$*"; }
fail() {
	printf 'FAIL %s\n' "$*" >&2
	FAILED=1
}
stop_if_failed() {
	if ((FAILED)); then
		printf 'stopping after run %s: later runs depend on it; state kept in %s\n' "$1" "${STATE}"
		exit 1
	fi
}

steps() { # $1 = file, rest = JSON step objects
	local file="$1"
	shift
	printf '%s\n' "$@" | jq -s '.' >"${file}"
}
at() { # $1 = click|move, $2 = "X Y"
	jq -cn --arg k "$1" --arg v "$2" '{($k): ($v | split(" ") | map(tonumber))}'
}
shot() { jq -cn --arg p "$1" '{shot: $p}'; }
typed() { jq -cn --arg t "$1" '{type: $t}'; }

harness() { # $1 = run name, $2 = steps file; a fresh profile per run
	"${HARNESS}" --dry-run --steps "$2" >/dev/null || die 2 "xvfb-proof.sh refused run $1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" \
		--keymap "${STATE}/keymap.json" --keep "${STATE}/zeo-$1" --steps "$2" ||
		die 2 "xvfb-proof.sh failed on run $1"
}

# ── OCR (041's recipe: grey, 3x, threshold, 8-bit PGM) ──
SCALE=3
# The conversation is drawn above this y, the Agent Tasks panel (bottom dock) below it: a word
# in the panel is counted only under it. First guess at 1920x1080.
PANEL_TOP=640
to_pgm() { # $1 = capture, $2 = pgm, [$3 = magick crop geometry]
	local crop=()
	[[ -n "${3:-}" ]] && crop=(-crop "$3" +repage)
	magick "$1" "${crop[@]}" -colorspace Gray -resize "$((SCALE * 100))%" -threshold 70% \
		-depth 8 "PGM:$2" || die 2 "cannot convert $1 for tesseract"
}
reads() { # $1 = capture, $2 = text, [$3 = crop]
	[[ -s "$1" ]] || die 2 "capture missing: $1"
	local pgm="${STATE}/ocr.pgm" text
	to_pgm "$1" "${pgm}" "${3:-}"
	text="$(tesseract "${pgm}" - --psm 3 2>/dev/null)" || die 2 "tesseract could not read $1"
	grep -qF -- "$2" <<<"${text}"
}
count_words() { # $1 = capture, $2 = word, [$3 = crop] -> how many word boxes read exactly $2
	local pgm="${STATE}/count.pgm" tsv
	to_pgm "$1" "${pgm}" "${3:-}"
	tsv="$(tesseract "${pgm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	awk -F '\t' -v word="$2" 'NR > 1 && $12 == word { n++ } END { print n + 0 }' <<<"${tsv}"
}
locate() { # $1 = capture, $2 = word, [$3 = lowest] -> "X Y" of the topmost (or lowest) box
	[[ -s "$1" ]] || die 2 "capture missing: $1"
	local pgm="${STATE}/locate.pgm" tsv
	to_pgm "$1" "${pgm}"
	tsv="$(tesseract "${pgm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	awk -F '\t' -v word="$2" -v s="${SCALE}" -v lowest="${3:-}" '
		NR > 1 && $12 == word && (!found || (lowest ? $8 > top : $8 < top)) {
			found = 1; top = $8; x = int(($7 + $9 / 2) / s); y = int(($8 + $10 / 2) / s)
		}
		END { if (!found) exit 1; print x, y }' <<<"${tsv}"
}
must_locate() { # $1 = run, $2 = capture, $3 = word, $4 = why, [$5 = lowest]
	local point
	if point="$(locate "$2" "$3" "${5:-}")"; then
		printf '%s' "${point}"
	else
		fail "run $1: \"$3\" not found in $(basename "$2") ($4)"
		stop_if_failed "$1"
	fi
}
CONVERSATION="1920x${PANEL_TOP}+0+0"
PANEL="1920x$((1080 - PANEL_TOP))+0+${PANEL_TOP}"
cancels_of() { # sessions the stub saw a session/cancel for, one per line
	[[ -s "${STUB_LOG}" ]] || return 0
	jq -r 'select(.event == "cancel") | .session' "${STUB_LOG}"
}

OPEN_PROJECT=(
	'{"sleep": 12}'
	'{"chord": ["ctrl", "o"]}' '{"sleep": 2}'
	'{"chord": ["ctrl", "a"]}' "$(typed "${PROJECT}/")" '{"sleep": 1}'
	'{"key": ["Return"]}' '{"sleep": 8}'
)
# In a fresh profile the first ToggleFocus after a thread exists does not open the panel; one
# open/close before the thread does (run S1's control does it by itself), so S2 and S3 warm it.
WARM_PANEL=(
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}'
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 2}'
)
# The sidebar's first thread row and the composer, with the sidebar open (S1's s3 capture).
SIDEBAR_ROW_XY="271 83"
COMPOSER_XY="740 945"
# The tooltip is drawn beside the sidebar row; the tasks card's own "Background" buttons start at
# x=632, so the read is cropped to the left of them.
SIDEBAR_TOOLTIP="436x300+194+60"
# "Waiting for you" is the tooltip of the card's status dot, not text on the card: hover Bravo's
# dot, below the "WAIT" turn (S2's s6 capture, sidebar open).
BRAVO_DOT_XY="531 399"
# The stub thread after "TWO": two children running under an idle parent.
TWO=(
	'{"chord": ["ctrl", "alt", "j"]}' '{"sleep": 8}'
	"$(typed "TWO")" '{"key": ["Return"]}' '{"sleep": 6}'
)

# ── Run S1: control, the two children everywhere, the sidebar tooltip ──
steps "${STATE}/s1.json" "${OPEN_PROJECT[@]}" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/c0-panel-before.png")" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 2}' \
	"${TWO[@]}" \
	"$(shot "${OUT}/s1-conversation-two-children.png")" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/s2-panel-two-children.png")" \
	'{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/s3-sidebar.png")"
harness S1 "${STATE}/s1.json"
if reads "${OUT}/c0-panel-before.png" "Alpha"; then
	fail "c0: the panel lists Alpha before the prompt (control)"
else
	ok "c0: no subagent row before the prompt (control)"
fi
for child in Alpha Bravo; do
	if reads "${OUT}/s2-panel-two-children.png" "${child}" "${PANEL}"; then
		ok "R1.1 the Agent Tasks panel lists ${child}"
	else
		fail "R1.1 the Agent Tasks panel does not list ${child}"
	fi
	if reads "${OUT}/s1-conversation-two-children.png" "${child}" "${CONVERSATION}"; then
		ok "R1.1/R5.3 the conversation shows a card for ${child}"
	else
		fail "the conversation shows no card for ${child}"
	fi
done
stop_if_failed S1
ALPHA_ROW="$(must_locate S1 "${OUT}/s2-panel-two-children.png" "Alpha" "Alpha's panel row" lowest)"
TITLE_XY="${SIDEBAR_ROW_XY}"

# ── Run S2: the same layout; the sidebar tooltip, Stop on Alpha, Waiting ──
STOP_XY="${STOP_X} ${ALPHA_ROW#* }"
printf 'Alpha row at %s; Stop at %s; sidebar title at %s\n' "${ALPHA_ROW}" "${STOP_XY}" "${TITLE_XY}"
: >"${STUB_LOG}"
steps "${STATE}/s2.json" "${OPEN_PROJECT[@]}" "${WARM_PANEL[@]}" "${TWO[@]}" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
	'{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}' \
	"$(at move "${TITLE_XY}")" '{"sleep": 2}' \
	"$(shot "${OUT}/s4-sidebar-background-tooltip.png")" \
	"$(at click "${STOP_XY}")" '{"sleep": 2}' \
	'{"key": ["Return"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/s5-panel-after-stop.png")" \
	"$(at click "${COMPOSER_XY}")" '{"sleep": 1}' \
	"$(typed "WAIT")" '{"key": ["Return"]}' '{"sleep": 5}' \
	"$(at move "${BRAVO_DOT_XY}")" '{"sleep": 2}' \
	"$(shot "${OUT}/s6-conversation-bravo-waiting.png")"
harness S2 "${STATE}/s2.json"
if reads "${OUT}/s4-sidebar-background-tooltip.png" "Background" "${SIDEBAR_TOOLTIP}"; then
	ok "R4.1 the idle parent with running children reads \"Running in the Background\""
else
	fail "R4.1 no Background tooltip on the parent's sidebar row"
fi
mapfile -t CANCELS < <(cancels_of)
if [[ "${CANCELS[*]:-}" == "alpha" ]]; then
	ok "R1.4 Stop sent exactly one session/cancel, for alpha (stub log)"
else
	fail "R1.4 the stub saw session/cancel for [${CANCELS[*]:-}], want [alpha]"
fi
if reads "${OUT}/s5-panel-after-stop.png" "Bravo" "${PANEL}"; then
	ok "R1.4 Bravo keeps its row after Alpha's Stop"
else
	fail "R1.4 Bravo's row is gone after Alpha's Stop"
fi
if reads "${OUT}/s6-conversation-bravo-waiting.png" "Waiting for you" "${CONVERSATION}"; then
	ok "R5.2 Bravo's card reads \"Waiting for you\""
else
	fail "R5.2 no \"Waiting for you\" on Bravo's card"
fi
if jq -e 'select(.event == "initialize") | .subagents_offered' "${STUB_LOG}" >/dev/null 2>&1; then
	ok "Zeo offered the subagents capability (acp-beta on by default, R7.1)"
else
	fail "Zeo did not offer the subagents capability to the stub"
fi

# ── Run S3: one subagent sent both ways is one row ──
steps "${STATE}/s3.json" "${OPEN_PROJECT[@]}" "${WARM_PANEL[@]}" \
	'{"chord": ["ctrl", "alt", "j"]}' '{"sleep": 8}' \
	"$(typed "BOTH")" '{"key": ["Return"]}' '{"sleep": 6}' \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/s7-panel-charlie-both-ways.png")"
harness S3 "${STATE}/s3.json"
charlies="$(count_words "${OUT}/s7-panel-charlie-both-ways.png" "Charlie" "${PANEL}")"
if [[ "${charlies}" == 1 ]]; then
	ok "R3.1 Charlie, sent as an RFD child and as a feed entry, is ONE panel row"
else
	fail "R3.1 the panel reads \"Charlie\" ${charlies} times, want 1"
fi
if reads "${OUT}/s7-panel-charlie-both-ways.png" "Feedonly" "${PANEL}"; then
	ok "R3.2 the feed-only shell keeps its own row (control)"
else
	fail "R3.2 the feed-only shell row is missing"
fi

# ── Run A1: the real adapter (claude-acp), two background subagents ──
ACP_RESULT="not run (--stub-only)"
if ((! STUB_ONLY)); then
	ACP_PROMPT="Use the Task tool twice, in parallel and in the background, to start two \
subagents: one described as Alpha and one described as Bravo; each must only run the shell \
command sleep 120. Do not wait for them; reply DONE once both are started."
	steps "${STATE}/a1.json" "${OPEN_PROJECT[@]}" "${WARM_PANEL[@]}" \
		'{"chord": ["ctrl", "alt", "u"]}' '{"sleep": 20}' \
		"$(typed "${ACP_PROMPT}")" '{"key": ["Return"]}' '{"sleep": 50}' \
		"$(shot "${OUT}/a1-claude-acp-conversation.png")" \
		'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
		"$(shot "${OUT}/a2-claude-acp-panel.png")" \
		'{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}' \
		"$(shot "${OUT}/a3-claude-acp-sidebar.png")"
	harness A1 "${STATE}/a1.json"
	acp_ok=1
	for child in Alpha Bravo; do
		if reads "${OUT}/a2-claude-acp-panel.png" "${child}" "${PANEL}"; then
			ok "claude-acp: the panel lists ${child}"
		else
			fail "claude-acp: the panel does not list ${child}"
			acp_ok=0
		fi
	done
	ACP_RESULT="$( ((acp_ok)) && echo proven || echo FAILED)"
fi

RESULT="proven"
((FAILED)) && RESULT="FAILED"
cat >"${OUT}/README.md" <<README
# Story 064 — live proof of Zeo's task surfaces on native ACP subagents

Driver: \`zed-patches/scripts/proofs/064-native-subagents/run.sh\`, binary \`${BINARY}\`,
stub \`stub_adapter.py\` (deterministic ACP v1, no model), isolated profiles under \`${STATE}\`.

| Capture | Shows | Its control |
|---|---|---|
| \`s1-conversation-two-children.png\` | cards for Alpha (messaged) and Bravo (never messaged, R5.3) | — |
| \`s2-panel-two-children.png\` | panel rows for Alpha and Bravo (R1.1) | \`c0-panel-before.png\`: neither |
| \`s4-sidebar-background-tooltip.png\` | "Running in the Background" on the idle parent (R4.1) | — |
| \`s5-panel-after-stop.png\` | Bravo's row after Alpha's Stop; \`stub.log\`: one cancel, alpha (R1.4) | — |
| \`s6-conversation-bravo-waiting.png\` | Bravo's card "Waiting for you" (R5.2) | \`s1\`: running |
| \`s7-panel-charlie-both-ways.png\` | one Charlie row although sent both ways (R3.1) | the feed-only shell row (R3.2) |
| \`a1\`–\`a3\` (claude-acp) | the real adapter's two subagents: card, panel, sidebar | — |

Stub part: ${RESULT}. claude-acp part: ${ACP_RESULT}.
README
cp -- "${STUB_LOG}" "${OUT}/stub.log" 2>/dev/null || true

((FAILED)) && exit 1
printf 'proven: %s\n' "${OUT}"
