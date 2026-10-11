#!/usr/bin/env bash
# Story 035, task 4.2 — GUI proof of the Run button and the conditional Decline (E2E).
#
#     run.sh --binary <zeo-editor built from dev-035> --settings <settings.json> \
#            --out <docs/assets/035-live-proof-DATE> [--coords <coords.env>] [--calibrate]
#
# What it proves (R1.1, R1.3, R1.5, R2.1, R2.2, R2.6, R2.11, R3.1), in ONE Zeo session on a
# private X display (xvfb-proof.sh; isolated --user-data-dir, never the operator's profile):
#   proof-1  the agent's reply: one code block holding /help, hovered — [Run][New Thread][Copy]
#   proof-2  New Thread clicked: a new thread, /help in its composer, unsent (R1.5)
#   proof-3  in that thread, the composer cleared and the same request sent again; its reply
#   proof-4  Run clicked: a new thread in which /help was SENT (R1.3)
#   proof-5  AskUserQuestion, Decline untouched: no prompt, a "Skipped" line (R2.1, R3.1)
#   proof-6  AskUserQuestion again, text typed in "Other", Decline: the prompt (R2.2, R2.11)
#   proof-7  "Keep Answering": the typed text is still there, no new "Skipped" (R2.6)
#   proof-8  Decline again, "Skip Question": a second "Skipped" line (R3.1)
#
# --settings must configure the agent under test ("Claude Agent (Plus)") as the panel's agent,
# with credentials the isolated profile can use: this proof talks to a live model. No credit or
# no adapter means exit 2 (environment), and task 4.2 closes [~] deferred, naming it.
#
# Why coordinates: xvfb-proof.sh replays a static step script inside one launch, and a pending
# question does not survive a relaunch, so nothing can be located by OCR between steps. Icon
# buttons have no text either. --calibrate runs only up to proof-1 and the first question card,
# then stops: read RUN_XY, NEW_THREAD_XY, DECLINE_XY and OTHER_XY off those captures into the
# --coords file (KEY=X,Y per line). Same prompt, same reply shape, same card: same positions.
# The prompt is answered by keyboard (Q12): KEEP_KEY picks "Keep Answering" (default Down Return),
# SKIP_KEY confirms "Skip Question" (default Return) — each a space-separated key sequence,
# overridable in --coords. Escape does not answer this prompt: Zeo's prompt maps menu::Cancel to
# an action named "Cancel" only, so "Keep Answering" is reached with Down (menu::SelectNext);
# End is no help either: upstream's prompt has SelectFirst and SelectLast swapped.
#
# The agent: a fresh profile's panel opens the native agent. The driver passes a keymap binding
# ctrl-alt-j to agent::NewExternalAgentThread {"agent": "Claude Agent (Plus)"} and presses it
# before the burned turn; every later thread inherits the panel's selected agent.
#
# Red (before story 035): there is no Run button, so proof-4 shows no sent /help, Decline never
# asks and never leaves "Skipped" — the OCR checks on proof-5/6/8 fail. Exit 1.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe). Not covered: Wayland, GPU, the KDE session.
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused).

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run.sh: %s\n' "$*" >&2
	exit "${code}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
BINARY=""
SETTINGS=""
OUT=""
COORDS=""
CALIBRATE=0
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--settings) SETTINGS="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--coords) COORDS="${2:-}" && shift ;;
	--calibrate) CALIBRATE=1 ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${SETTINGS}" && -r "${SETTINGS}" ]] || die 2 "--settings must name a readable settings.json"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in tesseract xdotool Xvfb jq; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then
	MAGICK=(magick)
elif command -v convert >/dev/null; then
	MAGICK=(convert)
else
	die 2 "missing tool: magick (ImageMagick)"
fi

KEEP_KEY="Down Return"
SKIP_KEY="Return"
RUN_XY=""
NEW_THREAD_XY=""
DECLINE_XY=""
OTHER_XY=""
if ((!CALIBRATE)); then
	[[ -n "${COORDS}" && -r "${COORDS}" ]] || die 2 "--coords is required unless --calibrate"
	while IFS='=' read -r key value; do
		[[ -z "${key}" || "${key}" == \#* ]] && continue
		case "${key}" in
		RUN_XY | NEW_THREAD_XY | DECLINE_XY | OTHER_XY | KEEP_KEY | SKIP_KEY) printf -v "${key}" '%s' "${value}" ;;
		*) die 2 "unknown key in ${COORDS}: ${key}" ;;
		esac
	done <"${COORDS}"
	for key in RUN_XY NEW_THREAD_XY DECLINE_XY OTHER_XY; do
		[[ "${!key}" =~ ^[0-9]+,[0-9]+$ ]] || die 2 "${key} must be X,Y in ${COORDS}"
	done
fi

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp035-XXXX")"
mkdir -p -- "${STATE}/project"
printf 'proof\n' >"${STATE}/project/README"

ASK_HELP="Reply with exactly one fenced code block that contains only the line /help, and no other text."
ASK_QUESTION="Use the AskUserQuestion tool once to ask me which colour I prefer, with the options Red and Blue. Do nothing else."
ANSWER="zeo-proof-answer"

# JSON helpers: a click at "X,Y", a hover at "X,Y"; a key step from a space-separated sequence.
at() { jq -cn --arg v "$2" "{\"$1\": (\$v | split(\",\") | map(tonumber))}"; }
keys() { jq -cn --arg v "$1" '{"key": ($v | split(" ") | map(select(length > 0)))}'; }

# The agent under test, bound to a key: no setting selects the panel's agent.
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Claude Agent (Plus)"}]}}]
JSON

common_open() {
	# Open the project through Zeo's own path prompt, focus the agent panel, open a thread on the
	# agent under test, burn one turn (memory: the first turn of a fresh session can carry a
	# thinking-change note) before any capture.
	cat <<JSON
  {"sleep": 15},
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "${STATE}/project/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
  {"chord": ["ctrl", "question"]}, {"sleep": 3},
  {"chord": ["ctrl", "alt", "j"]}, {"sleep": 10},
  {"type": "Say ok."}, {"key": ["Return"]}, {"sleep": 30},
  {"chord": ["ctrl", "n"]}, {"sleep": 3},
  {"type": "${ASK_HELP}"}, {"key": ["Return"]}, {"sleep": 45}
JSON
}

if ((CALIBRATE)); then
	cat >"${STATE}/steps.json" <<JSON
[
$(common_open),
  {"shot": "${OUT}/calibrate-1-reply.png"},
  {"type": "${ASK_QUESTION}"}, {"key": ["Return"]}, {"sleep": 45},
  {"shot": "${OUT}/calibrate-2-question-card.png"}
]
JSON
	"${HARNESS}" --binary "${BINARY}" --settings "${SETTINGS}" --keymap "${STATE}/keymap.json" \
		--keep "${STATE}/zeo" \
		--steps "${STATE}/steps.json" || die 2 "xvfb-proof.sh refused or failed (exit $?)"
	printf 'calibration captures in %s: hover the code block in calibrate-1 to read RUN_XY and\n' "${OUT}"
	printf 'NEW_THREAD_XY (the row shows on hover: Run is left of New Thread, which is left of Copy);\n'
	printf 'read DECLINE_XY and OTHER_XY off calibrate-2. Write them to a --coords file.\n'
	exit 0
fi

cat >"${STATE}/steps.json" <<JSON
[
$(common_open),
  $(at move "${RUN_XY}"), {"sleep": 1},
  {"shot": "${OUT}/proof-1-run-beside-new-thread.png"},
  $(at click "${NEW_THREAD_XY}"), {"sleep": 4},
  {"shot": "${OUT}/proof-2-new-thread-prefilled-unsent.png"},
  {"chord": ["ctrl", "a"]}, {"key": ["BackSpace"]},
  {"type": "${ASK_HELP}"}, {"key": ["Return"]}, {"sleep": 45},
  {"shot": "${OUT}/proof-3-second-reply.png"},
  $(at move "${RUN_XY}"), {"sleep": 1},
  $(at click "${RUN_XY}"), {"sleep": 30},
  {"shot": "${OUT}/proof-4-run-sent-in-new-thread.png"},
  {"type": "${ASK_QUESTION}"}, {"key": ["Return"]}, {"sleep": 45},
  $(at click "${DECLINE_XY}"), {"sleep": 3},
  {"shot": "${OUT}/proof-5-untouched-decline-skipped.png"},
  {"sleep": 20},
  {"type": "${ASK_QUESTION}"}, {"key": ["Return"]}, {"sleep": 45},
  $(at click "${OTHER_XY}"), {"sleep": 1},
  {"type": "${ANSWER}"}, {"sleep": 1},
  $(at click "${DECLINE_XY}"), {"sleep": 2},
  {"shot": "${OUT}/proof-6-touched-decline-asks.png"},
  $(keys "${KEEP_KEY}"), {"sleep": 2},
  {"shot": "${OUT}/proof-7-keep-answering-kept-text.png"},
  $(at click "${DECLINE_XY}"), {"sleep": 2},
  $(keys "${SKIP_KEY}"), {"sleep": 3},
  {"shot": "${OUT}/proof-8-skip-question-skipped.png"}
]
JSON
jq empty "${STATE}/steps.json" || die 2 "generated step script is not valid JSON"
"${HARNESS}" --binary "${BINARY}" --settings "${SETTINGS}" --keymap "${STATE}/keymap.json" \
	--keep "${STATE}/zeo" \
	--steps "${STATE}/steps.json" || die 2 "xvfb-proof.sh refused or failed (exit $?)"

# OCR, two renderings of one capture: grey (this driver's first recipe) and the blue channel
# (032/034's). The blue channel turns the blue text caret into background, so "/help|" in a
# composer reads; grey keeps text the prompt's dimming fades. reads/lacks test either rendering
# (lacks is stricter for it); count_at_least takes the higher count of the two, never the sum.
ocr_one() {
	local pnm="${STATE}/ocr.pnm" text
	case "$2" in
	grey) "${MAGICK[@]}" "$1" -colorspace Gray -resize 300% -threshold 70% "${pnm}" ;;
	blue) "${MAGICK[@]}" "$1" -channel B -separate +channel -resize 300% -threshold 70% "${pnm}" ;;
	esac || die 2 "cannot convert $1 for tesseract"
	text="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read ${pnm} (from $1)"
	tr '\n' ' ' <<<"${text}"
}
ocr() {
	printf '%s\n%s' "$(ocr_one "$1" grey)" "$(ocr_one "$1" blue)"
}

failed=0
reads() {
	local shot="$1" needle="$2" why="$3" text
	text="$(ocr "${OUT}/${shot}")"
	if [[ "${text}" == *"${needle}"* ]]; then
		printf 'ok    %s reads "%s" (%s)\n' "${shot}" "${needle}" "${why}"
	else
		printf 'FAIL  %s does not read "%s" (%s)\n' "${shot}" "${needle}" "${why}"
		failed=1
	fi
}
lacks() {
	local shot="$1" needle="$2" why="$3" text
	text="$(ocr "${OUT}/${shot}")"
	if [[ "${text}" == *"${needle}"* ]]; then
		printf 'FAIL  %s reads "%s" (%s)\n' "${shot}" "${needle}" "${why}"
		failed=1
	else
		printf 'ok    %s does not read "%s" (%s)\n' "${shot}" "${needle}" "${why}"
	fi
}
count_at_least() {
	local shot="$1" needle="$2" n="$3" why="$4" mode text count found=0
	for mode in grey blue; do
		text="$(ocr_one "${OUT}/${shot}" "${mode}")"
		# grep finds nothing -> status 1; under pipefail that would abort the script unreported.
		count="$({ grep -o -- "${needle}" <<<"${text}" || true; } | wc -l)"
		((count <= found)) || found="${count}"
	done
	if ((found >= n)); then
		printf 'ok    %s reads "%s" %d times (%s)\n' "${shot}" "${needle}" "${found}" "${why}"
	else
		printf 'FAIL  %s reads "%s" %d times, want >= %d (%s)\n' "${shot}" "${needle}" "${found}" "${n}" "${why}"
		failed=1
	fi
}

reads proof-2-new-thread-prefilled-unsent.png "/help" "R1.5 the command waits in the composer"
reads proof-4-run-sent-in-new-thread.png "/help" "R1.3 the command is in the new thread"
reads proof-5-untouched-decline-skipped.png "Skipped" "R2.1/R3.1 untouched Decline leaves Skipped"
lacks proof-5-untouched-decline-skipped.png "Skip this question?" "R2.1 no prompt when untouched"
reads proof-6-touched-decline-asks.png "Skip this question?" "R2.2/R2.11 the prompt's title"
reads proof-6-touched-decline-asks.png "Keep Answering" "R2.11 the keep button"
reads proof-6-touched-decline-asks.png "Skip Question" "R2.11 the skip button"
reads proof-7-keep-answering-kept-text.png "${ANSWER}" "R2.6 the typed text survives Keep Answering"
lacks proof-7-keep-answering-kept-text.png "Skip this question?" "R2.6 the prompt is gone"
count_at_least proof-8-skip-question-skipped.png "Skipped" 2 "R3.1 both declined questions leave a line"

printf 'Captures need a human look as well: proof-2 must show an EMPTY transcript (unsent), proof-4 a\n'
printf 'sent /help as the first user message; OCR cannot tell a composer from a message.\n'
printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
