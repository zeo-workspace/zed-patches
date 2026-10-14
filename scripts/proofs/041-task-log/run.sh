#!/usr/bin/env bash
# Story 041, task 8.2 — GUI proof of the expanded task card and the task log (E2E).
#
#     run.sh --binary <zeo-editor built from dev-041> --adapter <fork-041/dist/index.js> \
#            --out <docs/assets/041-live-proof-DATE>
#
# What it proves (R4.3, R5.2, R5.9, R6.3, R6.5; Q11):
#   1. an expanded running shell row shows its tail (OCR of the expanded row reads "line");
#   2. "Open Log" on that row opens a read-only tab holding the output (OCR reads "line 1");
#   3. after the task ended and Zeo restarted, the Agent Tasks panel's "Open Log" opens the
#      saved log from Zeo's data directory (OCR reads "line 8");
#   4. the saved log is mode 600 and its directories 700 (`stat -c %a`);
#   5. after Delete of the archived record, no file is left for that task.
#
# How: three xvfb-proof.sh runs over one --keep directory (an isolated --user-data-dir, never the
# operator's profile), with a settings file whose only `agent_servers` entry runs the adapter
# given by --adapter, and a keymap that binds the actions the driver needs:
#   ctrl-alt-j  agent::NewExternalAgentThread {"agent": "Claude Agent (Plus)"} — a fresh
#               profile's panel opens the native agent, and no setting selects an external one;
#   ctrl-alt-k  agent_tasks_panel::ToggleFocus;
#   ctrl-alt-w  workspace::CloseAllItemsAndPanes — run 1 closes the card's log tab, so the tab
#               captured after the restart can only have come from the panel's Open Log.
# Run 1 opens the project through Zeo's own path prompt, starts a thread on the agent, types the
# prompt that starts a background shell printing eight lines three seconds apart, expands the
# row while the shell runs and captures it, activates the row's Open Log and captures, then
# waits for the task to end (the card's copy on end rewrites the log whole). Between runs the
# log file's modes are read from the kept data directory. Run 2 restarts (the project and the
# thread come back by themselves), opens the Agent Tasks panel and its row's Open Log, captures.
# Run 3 archives the row, shows Archived, deletes the record through its prompt, and the
# directory is listed again.
#
# OCR reads a region, never the whole screen: the thread always holds the model's own words,
# and after the task ends its reply quotes the output ("line 1 a line 8"). So the command is
# spelled `echo "lin""e $i"`: it prints "line N", but neither its text in the thread nor the
# card's "running what" line reads "line". The regions, read off the --binary build at
# 1920x1080 with the agent panel docked left (900 px wide):
#   EXPANDED_ROW  the card under the row's own line, where the expanded tail is drawn;
#   EDITOR_TEXT   the text column of the centre pane, where an opened log tab is drawn, above
#                 the Agent Tasks panel when that is open (no gutter, no scrollbar: both
#                 confuse tesseract).
# Each region is saved beside its capture as ocr-*.png, so the reader sees what was read.
# The opened tab takes the focus with its caret on column 0 of line 1, where it turns "line 1"
# into "hine 1" for tesseract (and at the end of the line, into "line 4"); run 1 presses
# ctrl+End before its capture, which parks it on the empty line after the last newline.
#
# Red (before story 041): the row has no disclosure and no Open Log, so the expanded-row region
# shows only the thread under the card and no tab ever opens: checks 1 and 2 fail, and no log
# directory exists (exit 1 before run 2).
#
# It needs two short model turns (the prompt, and the agent's own turn when the task ends).
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
ADAPTER=""
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
[[ -n "${ADAPTER}" && -f "${ADAPTER}" ]] || die 2 "--adapter must name the built adapter's dist/index.js"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in tesseract node jq magick; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
ADAPTER="$(cd -- "$(dirname -- "${ADAPTER}")" && pwd)/$(basename -- "${ADAPTER}")"

# Points and regions on the 1920x1080 Xvfb (see the header). The card's row line sits at y 148
# with one thread and one task; its controls are right-aligned, so Open Log moves one slot right
# once the task ends and Stop goes away. The panel's row sits at y 834 under its group header.
CARD_EXPAND_XY=508,148
CARD_OPEN_LOG_RUNNING_XY=760,148
PANEL_OPEN_LOG_XY=1445,834
PANEL_ARCHIVE_XY=1471,834
PANEL_ARCHIVED_FILTER_XY=1022,776
PANEL_DELETE_XY=1471,834
EXPANDED_ROW=352x260+481+160
EDITOR_TEXT=470x620+930+110

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp041-XXXX")"
PROJECT="${STATE}/project"
mkdir -p -- "${PROJECT}"
printf 'proof\n' >"${PROJECT}/README"

# The agent entry runs the story's adapter; no other entry exists in this isolated profile.
# Zeo's own path and prompt dialogs (not the portal's), so keystrokes can answer them.
jq -n --arg node "$(command -v node)" --arg adapter "${ADAPTER}" '{
  use_system_path_prompts: false,
  use_system_prompts: false,
  session: { trust_all_worktrees: true },
  agent: { dock: "left", default_width: 900.0 },
  agent_servers: { "Claude Agent (Plus)": { type: "custom", command: $node, args: [$adapter] } }
}' >"${STATE}/settings.json"
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Claude Agent (Plus)"}],
  "ctrl-alt-k": "agent_tasks_panel::ToggleFocus",
  "ctrl-alt-w": "workspace::CloseAllItemsAndPanes"}}]
JSON

# shellcheck disable=SC2016 # the command is literal text for the model
PROMPT='Use the Bash tool with run_in_background set to true to run exactly: for i in $(seq 1 8); do echo "lin""e $i"; sleep 3; done -- then reply started.'

steps() { # $1 = file, rest = JSON step objects
	local file="$1"
	shift
	printf '%s\n' "$@" | jq -s '.' >"${file}"
}
at() { # $1 = click|rclick|move, $2 = "X,Y"
	jq -cn --arg k "$1" --arg v "$2" '{($k): ($v | split(",") | map(tonumber))}'
}
shot() { # $1 = path
	jq -cn --arg p "$1" '{shot: $p}'
}

harness() { # $1 = steps file
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" \
		--keymap "${STATE}/keymap.json" --keep "${STATE}/zeo" \
		--steps "$1" || die 2 "harness refused or failed on $1"
}

# region <capture> <WxH+X+Y> <out> — the part of a capture a check reads.
region() {
	[[ -s "$1" ]] || die 1 "capture missing: $1"
	magick "$1" -crop "$2" +repage "$3" || die 2 "cannot crop $1 to $2"
}

# The text tesseract reads in a capture. It goes through PNM: the Leptonica on this host has no
# PNG reader, and tesseract fails on a .png with nothing on stdout — which would read as a
# failed check rather than as the environment problem it is.
# Grey, enlarged three times and thresholded, read as one block of text (--psm 6): with the
# default page segmentation the log's digits drop out of the column.
# shellcheck disable=SC2329 # invoked through ocr_has, which check invokes
ocr_text() { # $1 = png
	local pnm="${STATE}/ocr.pnm"
	# 8-bit PGM: a blank region thresholds to one colour, which ImageMagick would otherwise write
	# with maxval 1, a header Leptonica refuses.
	magick "$1" -colorspace Gray -resize 300% -threshold 70% -depth 8 "PGM:${pnm}" ||
		die 2 "cannot convert $1 for tesseract"
	tesseract "${pnm}" - --psm 6 2>/dev/null || die 2 "tesseract could not read ${pnm} (from $1)"
}

# shellcheck disable=SC2329 # invoked through check
ocr_has() { # $1 = png, $2 = text
	[[ -s "$1" ]] || die 1 "capture missing: $1"
	local text
	# ocr_text dies in a subshell here; its status is passed on, not read as a failed check.
	text="$(ocr_text "$1")" || exit "$?"
	grep -qF -- "$2" <<<"${text}"
}

check() { # $1 = description, rest = command
	local what="$1"
	shift
	if "$@"; then
		printf 'ok   %s\n' "${what}"
	else
		printf 'FAIL %s\n' "${what}" >&2
		FAILED=1
	fi
}
FAILED=0

# ---- Run 1: start the shell, expand its row, Open Log -------------------------------------
steps "${STATE}/run1.json" \
	'{"sleep": 12}' \
	'{"chord": ["ctrl", "o"]}' '{"sleep": 2}' \
	'{"chord": ["ctrl", "a"]}' "$(jq -cn --arg t "${PROJECT}/" '{type: $t}')" '{"sleep": 1}' \
	'{"key": ["Return"]}' '{"sleep": 8}' \
	'{"chord": ["ctrl", "question"]}' '{"sleep": 3}' \
	'{"chord": ["ctrl", "alt", "j"]}' '{"sleep": 10}' \
	"$(shot "${OUT}/proof-0-thread-on-the-agent.png")" \
	"$(jq -cn --arg t "${PROMPT}" '{type: $t}')" \
	'{"key": ["Return"]}' \
	'{"sleep": 8}' \
	"$(at click "${CARD_EXPAND_XY}")" \
	'{"sleep": 3}' \
	"$(shot "${OUT}/proof-1-expanded-row.png")" \
	"$(at click "${CARD_OPEN_LOG_RUNNING_XY}")" \
	'{"sleep": 3}' \
	'{"chord": ["ctrl", "End"]}' \
	'{"sleep": 1}' \
	"$(shot "${OUT}/proof-2-open-log-card.png")" \
	'{"sleep": 40}' \
	"$(shot "${OUT}/proof-2b-task-ended.png")" \
	'{"chord": ["ctrl", "alt", "w"]}' \
	'{"sleep": 2}'
harness "${STATE}/run1.json"
region "${OUT}/proof-1-expanded-row.png" "${EXPANDED_ROW}" "${OUT}/ocr-1-expanded-row.png"
region "${OUT}/proof-2-open-log-card.png" "${EDITOR_TEXT}" "${OUT}/ocr-2-open-log-card.png"
check "expanded row shows a tail line" ocr_has "${OUT}/ocr-1-expanded-row.png" "line"
check "card Open Log tab holds the output" ocr_has "${OUT}/ocr-2-open-log-card.png" "line 1"

# ---- Modes of the saved log (R6.3) --------------------------------------------------------
LOGS="$(find "${STATE}/zeo" -type d -name agent_task_logs -print -quit)"
[[ -n "${LOGS}" ]] || die 1 "no agent_task_logs directory under the isolated data directory"
LOG="$(find "${LOGS}" -type f -name '*.log' -print -quit)"
[[ -n "${LOG}" ]] || die 1 "no saved log under ${LOGS}"
{
	printf 'log  %s %s\n' "$(stat -c %a "${LOG}")" "${LOG#"${STATE}/"}"
	printf 'dir  %s %s\n' "$(stat -c %a "$(dirname "${LOG}")")" "session dir"
	printf 'root %s %s\n' "$(stat -c %a "${LOGS}")" "agent_task_logs"
} | tee "${OUT}/modes.txt"
check "log file is 600" test "$(stat -c %a "${LOG}")" = 600
check "session dir is 700" test "$(stat -c %a "$(dirname "${LOG}")")" = 700
check "log root is 700" test "$(stat -c %a "${LOGS}")" = 700
check "the saved log holds the last line" grep -qF "line 8" "${LOG}"

# ---- Run 2: restart, Agent Tasks panel, Open Log (R5.9) -----------------------------------
steps "${STATE}/run2.json" \
	'{"sleep": 12}' \
	"$(shot "${OUT}/proof-3a-restarted.png")" \
	'{"chord": ["ctrl", "alt", "k"]}' \
	'{"sleep": 3}' \
	"$(at click "${PANEL_OPEN_LOG_XY}")" \
	'{"sleep": 3}' \
	"$(shot "${OUT}/proof-3-open-log-panel.png")"
harness "${STATE}/run2.json"
region "${OUT}/proof-3-open-log-panel.png" "${EDITOR_TEXT}" "${OUT}/ocr-3-open-log-panel.png"
check "panel Open Log opens the saved log after a restart" ocr_has "${OUT}/ocr-3-open-log-panel.png" "line 8"

# ---- Run 3: archive, Delete, no file left (R6.5) ------------------------------------------
# The panel comes back open from run 2. Archive hides the row until Archived is shown; the
# archived row's last slot is Delete, whose prompt's first button ("Delete") has the focus.
steps "${STATE}/run3.json" \
	'{"sleep": 12}' \
	"$(at click "${PANEL_ARCHIVE_XY}")" \
	'{"sleep": 2}' \
	"$(at click "${PANEL_ARCHIVED_FILTER_XY}")" \
	'{"sleep": 2}' \
	"$(shot "${OUT}/proof-4a-archived.png")" \
	"$(at click "${PANEL_DELETE_XY}")" \
	'{"sleep": 2}' \
	"$(shot "${OUT}/proof-4b-delete-prompt.png")" \
	'{"key": ["Return"]}' \
	'{"sleep": 3}' \
	"$(shot "${OUT}/proof-4-deleted.png")"
harness "${STATE}/run3.json"
find "${LOGS}" -type f | sed "s|^${STATE}/||" >"${OUT}/after-delete.txt"
check "no log file is left after Delete" test ! -e "${LOG}"

printf 'state kept in %s\n' "${STATE}"
exit "${FAILED}"
