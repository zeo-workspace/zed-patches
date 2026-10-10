#!/usr/bin/env bash
# Story 032, task 8.1 — GUI proof of the Pinned section on a private X display (E2E).
#
#     run.sh --binary <zeo-editor built from dev-032> --out <docs/assets/032-live-proof-DATE>
#
# What it proves (R2.1, R2.7, R4.1, R4.3): in a window that has only `alpha` open, the sidebar
# shows a "Pinned" section after the last project group holding a thread of `alpha` AND a thread
# of `delta`, a project open in no window; confirming the `delta` row opens `delta`.
#
# How: two xvfb-proof.sh runs and a seeding step over one --keep directory (an isolated --user-data-dir, never the
# operator's profile):
#   0. launch once so Zeo creates its database and runs every migration (the harness stops it);
#   1. seed two threads (sidebar_threads) and two pins (thread_organization) with sqlite3 —
#      newest pin first: delta, then alpha — exactly as the store stores them;
#   2. relaunch, open `alpha`, capture the sidebar; walk the keyboard into the section, confirm the
#      `delta` row, capture again.
# The captures are checked with tesseract: proof-1 must read "Pinned", both thread titles and
# "delta"; proof-3 must read the delta thread's title in the opened project. Before story 032 the
# first check fails ("Pinned" is never drawn): that is this proof's Red.
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
for tool in sqlite3 tesseract xdotool Xvfb; do
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
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp032-XXXX")"
PROJECTS="${STATE}/projects"
mkdir -p -- "${PROJECTS}/alpha" "${PROJECTS}/delta"
printf 'alpha\n' >"${PROJECTS}/alpha/README"
printf 'delta\n' >"${PROJECTS}/delta/README"
ALPHA="${PROJECTS}/alpha"
DELTA="${PROJECTS}/delta"
ALPHA_TITLE="Alpha pinned thread"
DELTA_TITLE="Delta pinned thread"
ALPHA_ID="0a1b2c3d4e5f40718293a4b5c6d7e8f9"
DELTA_ID="1a1b2c3d4e5f40718293a4b5c6d7e8f9"
# Zeo's own path prompt (the portal's would need a desktop), and no trust prompt over the window.
cat >"${STATE}/settings.json" <<'JSON'
{"use_system_path_prompts": false, "session": {"trust_all_worktrees": true}}
JSON

harness() {
	local steps="$1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "${STATE}/zeo" \
		--steps "${steps}" ||
		die 2 "xvfb-proof.sh refused or failed on ${steps} (exit $?)"
}

# 0 — first launch: database and migrations. No ctrl+q: the harness checks Zeo is alive after
# every step, so a quit ends the run with exit 1; it stops Zeo itself when the steps are done.
cat >"${STATE}/steps-0.json" <<'JSON'
[{"sleep": 20}]
JSON
harness "${STATE}/steps-0.json"

# 1 — seed. db/0-global holds only kv_store; the release channel's directory (0-dev for a dev
# build, 0-zeo for the package) holds the rest: take the database that has sidebar_threads.
has_table() {
	[[ "$(sqlite3 "$1" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$2'")" == 1 ]]
}
DB=""
while IFS= read -r -d '' candidate; do
	if has_table "${candidate}" sidebar_threads; then
		DB="${candidate}"
		break
	fi
done < <(find "${STATE}/zeo" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database under ${STATE}/zeo holds sidebar_threads"
printf 'database: %s\n' "${DB}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
# agent_id NULL is the native agent's id (ThreadMetadataDb::save), so no agent server is needed.
sqlite3 "${DB}" <<SQL || die 2 "seeding the threads into ${DB} failed"
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'${ALPHA_ID}', 'proof-032-alpha', NULL, '${ALPHA_TITLE}', '${NOW}', '${NOW}',
     '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${DELTA_ID}', 'proof-032-delta', NULL, '${DELTA_TITLE}', '${NOW}', '${NOW}',
     '${DELTA}', '0', 0, '${DELTA}', '0');
SQL
# A build without the organization store (before 032) has nowhere to keep a pin: say so and drive
# the GUI anyway, so the Red is the first OCR check ("Pinned" is never drawn), not a seeding error.
if has_table "${DB}" thread_organization; then
	sqlite3 "${DB}" <<SQL || die 2 "seeding the pins into ${DB} failed"
INSERT INTO thread_organization (thread_id, pinned_position) VALUES
    (X'${DELTA_ID}', 0),
    (X'${ALPHA_ID}', 1);
SQL
	printf 'seeded: 2 threads, 2 pins (delta first)\n'
else
	printf 'note: %s has no thread_organization table: this build stores no pin; 2 threads seeded, 0 pins\n' "${DB}"
fi

# 2 — open alpha through Zeo's own path prompt (settings: use_system_path_prompts false; ctrl+a
# replaces the $HOME it is prefilled with), show and focus the threads sidebar (ctrl+alt+;), capture.
# Focus lands in the sidebar's filter with no selection, where Up selects the LAST entry: the
# entries end [... Pinned header, delta row, alpha row], so Up twice is the delta row whatever the
# groups above hold. Confirm it, capture.
cat >"${STATE}/steps-2.json" <<JSON
[
  {"sleep": 15},
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "${ALPHA}/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
  {"chord": ["ctrl", "alt", "semicolon"]}, {"sleep": 3},
  {"shot": "${OUT}/proof-1-pinned-section.png"},
  {"key": ["Up"]}, {"key": ["Up"]}, {"sleep": 1},
  {"shot": "${OUT}/proof-2-delta-row-selected.png"},
  {"key": ["Return"]}, {"sleep": 8},
  {"shot": "${OUT}/proof-3-delta-opened.png"}
]
JSON
harness "${STATE}/steps-2.json"

# The Leptonica under tesseract may read no PNG at all ("pixReadStreamPng: function not present"),
# and muted UI text at 1x is small and pale: the Pinned header and a row's project name are dropped
# unless the capture is enlarged three times and thresholded to black on white, handed over as PNM.
# A failure here is the environment's, so it exits 2 rather than reading as a failed check.
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
check proof-1-pinned-section.png "Pinned" "R2.1 the section header"
check proof-1-pinned-section.png "${DELTA_TITLE}" "R4.1 a thread of a project open nowhere"
check proof-1-pinned-section.png "${ALPHA_TITLE}" "the open project's pinned thread"
check proof-1-pinned-section.png "delta" "R2.7 the row names its project"
check proof-3-delta-opened.png "${DELTA_TITLE}" "R4.3 the closed project's thread opened"
# The title is also on the pinned row itself, so proof-3 reading it does not show delta opened: the
# workspace Zeo recorded for the window does. Confirming the row is the only route to delta here.
if [[ "$(sqlite3 "${DB}" "SELECT count(*) FROM workspaces WHERE paths = '${DELTA}'")" -ge 1 ]]; then
	printf 'ok    workspaces holds %s (R4.3 confirming the row opened the closed project)\n' "${DELTA}"
else
	printf 'FAIL  workspaces holds no %s (R4.3 confirming the row opened the closed project)\n' "${DELTA}"
	failed=1
fi

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
