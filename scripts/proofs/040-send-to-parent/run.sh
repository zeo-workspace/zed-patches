#!/usr/bin/env bash
# Story 040, task 9.1 — GUI proof of Send to Parent and the sub-thread item (E2E).
#
#     run.sh --binary <zeo-editor built from dev-040> --out <docs/assets/040-live-proof-DATE>
#            [--adapter <path to claude-agent-acp-plus>]
#
# What it proves (R2.1, R2.2, R7.1; Q11), each against a negative control from the same run:
#   1. "Send Last Reply" in a sub-thread puts `From sub-thread "…":` and the sub-thread's reply
#      into the PARENT's composer (control c1: the parent's composer before, without that header);
#   2. the block stays unsent: twenty seconds later it is still in the composer and the agent has
#      not answered it (a send empties the composer);
#   3. the Agent Tasks panel lists the sub-thread with its "Sub-thread" chip (control c0: the
#      panel before the link, without that chip), and the history holds one item of origin
#      `sub_thread` (sqlite3 on the isolated profile).
#
# How: xvfb-proof.sh over one --keep directory (an isolated --user-data-dir under a fresh mktemp
# dir, never the operator's profile), a settings file whose only `agent_servers` entry is the
# real "Claude Agent (Plus)" (story 041's recipe), and a keymap:
#   ctrl-alt-j  agent::NewExternalAgentThread {"agent": "Claude Agent (Plus)"};
#   ctrl-alt-k  agent_tasks_panel::ToggleFocus.
# The harness replays a fixed script, so a coordinate cannot be read and used in one run: a run
# captures, tesseract's TSV boxes locate what to point at, and the next run relaunches into the
# same layout and points there (story 036's recipe). The sub-thread is made with story 039's
# message menu ("Clean sub-thread" on a selected word of the parent's reply).
#   1  open the project; c0 = the Agent Tasks panel before any link; start the parent thread
#      and get one reply (APRICOT); p1 = the parent with its composer empty (control c1)
#   2  relaunch, select APRICOT, open its menu; p2 locates "Clean sub-thread"
#   3  relaunch, same selection, choose it; in the sub-thread ask for one reply (QUINCE);
#      p3 locates "Send to Parent"
#   4  relaunch, open Send to Parent; p4 locates "Send Last Reply"
#   5  relaunch, Send Last Reply; s1 = the parent's composer; s2 = twenty seconds later; then
#      open the Agent Tasks panel; s3 = the sub-thread row
#
# Red is deferred to Run mode (it needs a build of dev-040 and the real adapter): on a build
# without the patch, run 3 finds no "Send to Parent" in p3 and the script exits 1 there.
#
# Tuning (task 9.1 ToDo 1): every point comes from OCR, but the sleeps, the double click that
# selects a word, and whether a relaunch reopens the sub-thread or the parent are first guesses,
# to be tuned on a build of dev-040.
#
# Two short model turns. Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager.
# Not covered: Wayland, GPU, the KDE session, a parent in another window (the GPUI tests cover it).
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, a
# capture could not be read).

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
ADAPTER="/usr/bin/claude-agent-acp-plus"
OUT=""
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--adapter) ADAPTER="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${ADAPTER}" && -x "${ADAPTER}" ]] || die 2 "--adapter must name an executable adapter"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in tesseract jq magick sqlite3 awk; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp040-XXXX")"
PROJECT="${STATE}/project"
mkdir -p -- "${PROJECT}"
printf 'proof\n' >"${PROJECT}/README"
printf 'binary: %s\nadapter: %s\nstate: %s\n' "${BINARY}" "${ADAPTER}" "${STATE}"

jq -n --arg adapter "${ADAPTER}" '{
  use_system_path_prompts: false,
  use_system_prompts: false,
  session: { trust_all_worktrees: true },
  agent: { dock: "left", default_width: 900.0 },
  agent_servers: { "Claude Agent (Plus)": { type: "custom", command: $adapter, args: [] } }
}' >"${STATE}/settings.json"
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Claude Agent (Plus)"}],
  "ctrl-alt-k": "agent_tasks_panel::ToggleFocus"}}]
JSON

# One word each, absent from every label Zeo draws, so OCR can only find it in a reply.
PARENT_WORD="APRICOT"
SUB_WORD="QUINCE"
PARENT_PROMPT="Reply with exactly the word ${PARENT_WORD} and nothing else."
SUB_PROMPT="Reply with exactly the word ${SUB_WORD} and nothing else."

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
at() { # $1 = click|rclick|move, $2 = "X Y"
	jq -cn --arg k "$1" --arg v "$2" '{($k): ($v | split(" ") | map(tonumber))}'
}
shot() { jq -cn --arg p "$1" '{shot: $p}'; }
typed() { jq -cn --arg t "$1" '{type: $t}'; }

harness() { # $1 = run number, $2 = steps file
	"${HARNESS}" --dry-run --steps "$2" >/dev/null || die 2 "xvfb-proof.sh refused run $1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" \
		--keymap "${STATE}/keymap.json" --keep "${STATE}/zeo" --steps "$2" ||
		die 2 "xvfb-proof.sh failed on run $1"
}

# ── OCR (041's recipe: grey, 3x, threshold, 8-bit PGM; Leptonica here reads no PNG) ──
SCALE=3
to_pgm() {
	magick "$1" -colorspace Gray -resize "$((SCALE * 100))%" -threshold 70% -depth 8 "PGM:$2" ||
		die 2 "cannot convert $1 for tesseract"
}
reads() { # $1 = capture, $2 = text
	[[ -s "$1" ]] || die 2 "capture missing: $1"
	local pgm="${STATE}/ocr.pgm" text
	to_pgm "$1" "${pgm}"
	text="$(tesseract "${pgm}" - --psm 3 2>/dev/null)" || die 2 "tesseract could not read $1"
	grep -qF -- "$2" <<<"${text}"
}
# The centre ("X Y"), in screen pixels, of the topmost word box reading exactly $2 — or, with
# $3 = lowest, the bottommost one (a reply word that the thread's title and the prompt repeat
# above it).
locate() { # $1 = capture, $2 = word, [$3 = lowest]
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

OPEN_PROJECT=(
	'{"sleep": 12}'
	'{"chord": ["ctrl", "o"]}' '{"sleep": 2}'
	'{"chord": ["ctrl", "a"]}' "$(typed "${PROJECT}/")" '{"sleep": 1}'
	'{"key": ["Return"]}' '{"sleep": 8}'
)

# ── Run 1: the panel before any link (c0), the parent and its reply (c1) ──
steps "${STATE}/run1.json" "${OPEN_PROJECT[@]}" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/c0-panel-before-link.png")" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 2}' \
	'{"chord": ["ctrl", "alt", "j"]}' '{"sleep": 10}' \
	"$(typed "${PARENT_PROMPT}")" '{"key": ["Return"]}' '{"sleep": 45}' \
	"$(shot "${OUT}/c1-parent-before-send.png")"
harness 1 "${STATE}/run1.json"
if reads "${OUT}/c0-panel-before-link.png" "Sub-thread"; then
	fail "c0: the panel shows a Sub-thread chip before any link (control)"
else
	ok "c0: no Sub-thread chip before the link (control)"
fi
if reads "${OUT}/c1-parent-before-send.png" "From sub-thread"; then
	fail "c1: the parent's composer already holds a sub-thread block (control)"
else
	ok "c1: the parent's composer holds no sub-thread block (control)"
fi
WORD_XY="$(must_locate 1 "${OUT}/c1-parent-before-send.png" "${PARENT_WORD}" "the parent's reply" lowest)"

# ── Runs 2 and 3: a clean sub-thread from the selected word (story 039's menu) ──
# Two clicks at one point select the word; the right click opens its message menu.
SELECT=(
	"$(at click "${WORD_XY}")" "$(at click "${WORD_XY}")" '{"sleep": 1}'
	"$(at rclick "${WORD_XY}")" '{"sleep": 2}'
)
steps "${STATE}/run2.json" '{"sleep": 15}' "${SELECT[@]}" "$(shot "${OUT}/p2-message-menu.png")"
harness 2 "${STATE}/run2.json"
CLEAN_XY="$(must_locate 2 "${OUT}/p2-message-menu.png" "Clean" "039's Clean sub-thread entry")"

steps "${STATE}/run3.json" '{"sleep": 15}' "${SELECT[@]}" \
	"$(at click "${CLEAN_XY}")" '{"sleep": 8}' \
	"$(typed "${SUB_PROMPT}")" '{"key": ["Return"]}' '{"sleep": 45}' \
	"$(shot "${OUT}/p3-sub-thread.png")"
harness 3 "${STATE}/run3.json"
if reads "${OUT}/p3-sub-thread.png" "${SUB_WORD}"; then
	ok "the sub-thread answered ${SUB_WORD}"
else
	fail "the sub-thread's reply is not on screen"
fi
CONTROL_XY="$(must_locate 3 "${OUT}/p3-sub-thread.png" "Parent" "R1.1 Send to Parent in the footer")"

# ── Run 4: the control's two choices ──
steps "${STATE}/run4.json" '{"sleep": 15}' "$(at click "${CONTROL_XY}")" '{"sleep": 2}' \
	"$(shot "${OUT}/p4-send-menu.png")"
harness 4 "${STATE}/run4.json"
if reads "${OUT}/p4-send-menu.png" "Summarize and Send"; then
	ok "R1.3 Summarize and Send is offered"
else
	fail "R1.3 Summarize and Send is not offered"
fi
LAST_XY="$(must_locate 4 "${OUT}/p4-send-menu.png" "Last" "R1.3 Send Last Reply")"

# ── Run 5: Send Last Reply, unsent, and the panel row ──
steps "${STATE}/run5.json" '{"sleep": 15}' "$(at click "${CONTROL_XY}")" '{"sleep": 2}' \
	"$(at click "${LAST_XY}")" '{"sleep": 4}' \
	"$(shot "${OUT}/s1-parent-after-send.png")" '{"sleep": 20}' \
	"$(shot "${OUT}/s2-parent-twenty-seconds-later.png")" \
	'{"chord": ["ctrl", "alt", "k"]}' '{"sleep": 3}' \
	"$(shot "${OUT}/s3-panel-after-link.png")"
harness 5 "${STATE}/run5.json"
for capture in s1-parent-after-send.png s2-parent-twenty-seconds-later.png; do
	if reads "${OUT}/${capture}" "From sub-thread" && reads "${OUT}/${capture}" "${SUB_WORD}"; then
		ok "R2.1/R2.2 ${capture}: the block is in the parent's composer (c1 had none)"
	else
		fail "R2.1/R2.2 ${capture}: no sub-thread block in the parent's composer"
	fi
done
if reads "${OUT}/s3-panel-after-link.png" "Sub-thread"; then
	ok "R7.1 the panel lists the sub-thread with its chip (c0 had none)"
else
	fail "R7.1 no Sub-thread chip in the Agent Tasks panel"
fi

DB=""
while IFS= read -r -d '' candidate; do
	if [[ "$(sqlite3 "${candidate}" "SELECT count(*) FROM sqlite_master WHERE name = 'agent_task_history'")" == 1 ]]; then
		DB="${candidate}"
	fi
done < <(find "${STATE}/zeo" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database with agent_task_history under ${STATE}/zeo"
items="$(sqlite3 "${DB}" "SELECT count(*) FROM agent_task_history WHERE origin = 'sub_thread'")"
if [[ "${items}" == 1 ]]; then
	ok "R5.1 the history holds one sub-thread item"
else
	fail "R5.1 the history holds ${items} sub-thread items, want 1"
fi

RESULT="proven"
((FAILED)) && RESULT="FAILED"
cat >"${OUT}/README.md" <<README
# Story 040 — live proof of Send to Parent and the sub-thread item

Driver: \`zed-patches/scripts/proofs/040-send-to-parent/run.sh\`, binary \`${BINARY}\`,
adapter \`${ADAPTER}\`, isolated profile under \`${STATE}\`.

| Capture | Shows | Its control |
|---|---|---|
| \`s1-parent-after-send.png\` | the parent's composer holding \`From sub-thread …\` and ${SUB_WORD} | \`c1-parent-before-send.png\`: the same composer before, empty |
| \`s2-parent-twenty-seconds-later.png\` | the block still unsent, no agent answer | \`s1-parent-after-send.png\` |
| \`s3-panel-after-link.png\` | the sub-thread row with its "Sub-thread" chip | \`c0-panel-before-link.png\`: the panel before any link |
| \`p2-message-menu.png\`, \`p3-sub-thread.png\`, \`p4-send-menu.png\` | how the run got there (039's menu, the footer control, its two choices) | — |

Result: ${RESULT}
README

((FAILED)) && exit 1
printf 'proven: %s\n' "${OUT}"
