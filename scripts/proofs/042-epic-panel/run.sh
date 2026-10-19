#!/usr/bin/env bash
# Story 042, task 8.1 — GUI proof of the read-only Epic panel on a private X display (E2E).
#
#     run.sh --binary <zeo-editor built from dev-042> --out <docs/assets/042-live-proof-DATE>
#
# What it proves (R1.1, R1.2/R1.4, R2.1, R2.3, R2.4, R2.6, R5.1, R8.1):
#   proof-1  the palette action `epic panel: toggle focus` opens the panel over a temp project
#            holding a COPY of this workspace's .epic/ (gitignored, as in real use): it reads
#            "Open EPIC.md", an active story's slug and the collapsed "Archived (N)" header;
#   proof-2  Archived expanded with the keyboard: an archived story's slug is shown;
#   proof-3  a box ticked in the copy while Zeo runs: the row's progress reads the new count;
#   proof-4  Enter on a story row opens its story.md in a tab (its title is on screen);
#   proof-5  a project without .epic/: the panel shows "No .epic/ directory in this project"
#            (the missing dock button is described in the README from the capture);
#   and the log holds `epic_panel event=scan … duration_ms=<n>` (the Success Metric).
#
# Before story 042 there is no `epic panel: toggle focus`, so proof-1 never reads
# "Open EPIC.md": that first check failing is this proof's Red.
#
# Never touches the operator's profile (xvfb-proof.sh isolates Zeo under --keep) nor the
# workspace's .epic/ (only a copy under $STATE is shown and edited).
#
# Keystrokes and sleeps are first guesses: tune them against the real dev-042 build (task 8.1)
# and record what changed in the proof README.
#
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
HUB="$(cd -- "${HERE}/../../../.." && pwd)"
CORPUS="${HUB}/.epic"
BINARY=""
OUT=""
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
[[ -d "${CORPUS}/archive" ]] || die 2 "no corpus at ${CORPUS}"
for tool in tesseract xdotool Xvfb; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then
	MAGICK=(magick)
elif command -v convert >/dev/null; then
	MAGICK=(convert)
else
	die 2 "missing tool: magick (ImageMagick)"
fi

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
# A capture left by an earlier run would let the background tick fire before its time.
rm -f -- "${OUT}"/proof-[0-9]*.png "${OUT}/scan-log-line.txt"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp042-XXXX")"
PROJECT="${STATE}/projects/epic-proof"
PLAIN="${STATE}/projects/plain"
mkdir -p -- "${PROJECT}" "${PLAIN}"
printf '.epic/\n' >"${PROJECT}/.gitignore"
printf 'epic proof\n' >"${PROJECT}/README"
printf 'no epic here\n' >"${PLAIN}/README"
# A copy, never the corpus: the proof edits it. The corpus's digest is compared at the end.
corpus_digest() {
	(cd -- "${CORPUS}" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
}
CORPUS_BEFORE="$(corpus_digest)"
cp -a -- "${CORPUS}" "${PROJECT}/.epic"

# The story whose box is ticked: the first active story with an open box and no `[~]` box, so
# its progress is just [x] over all boxes.
TICKED=""
for dir in "${PROJECT}/.epic/stories"/*/; do
	tasks="${dir}tasks.md"
	[[ -f "${tasks}" ]] || continue
	grep -qE '^[[:space:]]*- \[~\]' "${tasks}" && continue
	grep -qE '^[[:space:]]*- \[ \]' "${tasks}" || continue
	TICKED="${dir%/}"
	TICKED="${TICKED##*/}"
	break
done
[[ -n "${TICKED}" ]] || die 2 "no active story in the copy has an open box to tick"
TICKED_TASKS="${PROJECT}/.epic/stories/${TICKED}/tasks.md"
total="$(grep -cE '^[[:space:]]*- \[[ x~]\]' "${TICKED_TASKS}")"
closed="$(grep -cE '^[[:space:]]*- \[x\]' "${TICKED_TASKS}" || true)"
EXPECTED_AFTER="$((closed + 1))/${total}"
TICKED_SLUG="${TICKED#*-}"
ACTIVE_SLUG="epic-panel-read-only"
ARCHIVED_SLUG="close-the-parity-backlog"
ARCHIVED_COUNT="$(find "${PROJECT}/.epic/archive" -mindepth 1 -maxdepth 1 -type d | wc -l)"
printf 'ticked story: %s (%s/%s -> %s)\n' "${TICKED}" "${closed}" "${total}" "${EXPECTED_AFTER}"

cat >"${STATE}/settings.json" <<'JSON'
{"use_system_path_prompts": false, "session": {"trust_all_worktrees": true}}
JSON

harness() {
	local steps="$1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "${STATE}/zeo" \
		--steps "${steps}" ||
		die 2 "xvfb-proof.sh refused or failed on ${steps} (exit $?)"
}

# 1 — open the project, toggle the panel from the palette, capture; expand Archived; tick a box
# in the copy from a background job while Zeo runs; capture; open a story; capture.
cat >"${STATE}/steps-1.json" <<JSON
[
  {"sleep": 15},
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "${PROJECT}/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
  {"chord": ["ctrl", "shift", "p"]}, {"sleep": 2},
  {"type": "epic panel: toggle focus"}, {"sleep": 2},
  {"key": ["Return"]}, {"sleep": 4},
  {"shot": "${OUT}/proof-1-panel-rows.png"},
  {"key": ["Up"]}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 2},
  {"shot": "${OUT}/proof-2-archived-expanded.png"},
  {"sleep": 30},
  {"shot": "${OUT}/proof-3-progress-after-tick.png"},
  {"key": ["Down"]}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 4},
  {"shot": "${OUT}/proof-4-story-opened.png"}
]
JSON
(
	# Tuned on dev-042: a fixed +70 s ticked after proof-3 was taken, since the harness's start-up
	# time varies. The tick now waits for proof-2 to land, then gives the steps 2 s.
	for ((tries = 600; tries > 0; tries--)); do
		[[ -e "${OUT}/proof-2-archived-expanded.png" ]] && break
		sleep 0.5
	done
	((tries > 0)) || exit 1
	sleep 2
	# Ticks the first open box of the copy, never the corpus.
	sed -i '0,/^\([[:space:]]*\)- \[ \]/s//\1- [x]/' "${TICKED_TASKS}"
	printf 'ticked one box in %s after proof-2\n' "${TICKED_TASKS#"${STATE}"/}"
) &
TICKER=$!
harness "${STATE}/steps-1.json"
wait "${TICKER}" || die 2 "the background tick failed"

# 2 — a project without .epic/: the palette still opens the panel, which shows the empty state.
cat >"${STATE}/steps-2.json" <<JSON
[
  {"sleep": 15},
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "${PLAIN}/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
  {"shot": "${OUT}/proof-5a-no-epic-dock.png"},
  {"chord": ["ctrl", "shift", "p"]}, {"sleep": 2},
  {"type": "epic panel: toggle focus"}, {"sleep": 2},
  {"key": ["Return"]}, {"sleep": 3},
  {"shot": "${OUT}/proof-5b-no-epic-empty-state.png"}
]
JSON
harness "${STATE}/steps-2.json"

ocr() {
	local pnm="${STATE}/ocr.pnm" text
	"${MAGICK[@]}" "$1" -colorspace Gray -resize 300% -threshold 70% "${pnm}" ||
		die 2 "cannot convert $1 for tesseract"
	text="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read ${pnm} (from $1)"
	tr '\n' ' ' <<<"${text}"
}

failed=0
check() {
	local shot="$1" needle="$2" why="$3" text
	text="$(ocr "${OUT}/${shot}")"
	if [[ "${text}" == *"${needle}"* ]]; then
		printf 'ok    %s reads "%s" (%s)\n' "${shot}" "${needle}" "${why}"
	else
		printf 'FAIL  %s does not read "%s" (%s)\n' "${shot}" "${needle}" "${why}"
		failed=1
	fi
}
check proof-1-panel-rows.png "Open EPIC.md" "R1.1 the palette action opened the panel; R2.8"
check proof-1-panel-rows.png "${ACTIVE_SLUG}" "R2.1 an active story's row"
check proof-1-panel-rows.png "Archived (${ARCHIVED_COUNT})" "R2.3 the archive group, collapsed"
check proof-2-archived-expanded.png "${ARCHIVED_SLUG}" "R2.4 the archive expanded"
check proof-3-progress-after-tick.png "${EXPECTED_AFTER}" "R5.1 ${TICKED_SLUG}'s progress after the tick"
check proof-4-story-opened.png "story.md" "R2.6 a story file opened in a tab"
check proof-5b-no-epic-empty-state.png "No .epic/ directory in this project" "R1.4 the empty state"

# The Success Metric: the scan's own duration, from Zeo's log under the isolated state.
SCAN_LINE="$(grep -rh --include='*.log' 'epic_panel event=scan' "${STATE}/zeo" 2>/dev/null | head -n 1 || true)"
if [[ -n "${SCAN_LINE}" && "${SCAN_LINE}" == *"duration_ms="* ]]; then
	printf '%s\n' "${SCAN_LINE}" >"${OUT}/scan-log-line.txt"
	printf 'ok    log holds the scan line (R8.1): %s\n' "${SCAN_LINE}"
else
	printf 'FAIL  no "epic_panel event=scan … duration_ms=" line under %s (R8.1)\n' "${STATE}/zeo"
	failed=1
fi

# The corpus itself must be untouched by the run (the copy is what was edited).
if [[ "$(corpus_digest)" == "${CORPUS_BEFORE}" ]]; then
	printf 'ok    the workspace .epic/ is byte-identical after the run\n'
else
	printf 'FAIL  the workspace .epic/ changed during the run\n'
	failed=1
fi
printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
