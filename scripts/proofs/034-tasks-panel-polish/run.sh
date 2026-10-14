#!/usr/bin/env bash
# Story 034, task 7.1 — the Agent Tasks panel polish, seen in a built Zeo (E2E).
#
#     run.sh --out <docs/assets/034-live-proof-DATE> [--binary <zeo-editor>]
#
# What it proves (R1.1, R2.2, R2.3, R3.1, R4.2, R5.1/R5.5, R6.2, R7.3; Q12, Q13):
#   1  rows of DIFFERENT label lengths start at one x (a centred label would not), bottom dock
#   2  the 62-row list shows a scrollbar thumb at its right, and a one-row list none
#   3  typing "zq7x" in "Filter tasks…" leaves the target row and no other
#   4  two rows selected from the keyboard (shift-space) and archived with one click: the
#      database holds exactly those two archived
#   5  under Archived, Delete Selected asks "Delete 1 task record?"; Cancel keeps the record
#   6  the X closes the panel; ToggleFocus reopens it with the filter text kept
#   7  the same alignment in the right dock at the panel's 320 px default width
#
# Every verdict reads a capture (tesseract) or the database (sqlite3). Coordinates found in one
# phase are pointed at in the next: the harness replays a fixed script, and the layout is the
# same on every relaunch of the same --keep profile (032's method). Selection lives in memory,
# so each phase that needs it rebuilds it from scratch.
#
# Tuned in Run mode (task 7.1): the harness has no modifier-click or drag step, so selection uses
# the keyboard (R5.5: ToggleFocus focuses the panel, Tab walks its controls, shift-space toggles
# the row whose control has focus) and the thumb drag is not driven; the 600 px width of the
# success metric is replaced by the bottom dock's full width.
#
# Red is deferred to the run: on a build without the story the first check fails ("Filter
# tasks" is not on screen) and the driver exits 1.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe). Not covered: Wayland, GPU, HiDPI.
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
BINARY="/usr/libexec/zeo-editor"
OUT=""
TABS_PER_ROW=3 # open, rename, archive on a finished unarchived row
# Tab stops from the panel (focused by ToggleFocus) to t00's open control, measured on the built
# Zeo: filter input, X, the four toggles, the header's archive, then t00. Under Archived the
# filter bar adds Delete All Archived, and the header keeps its archive (t02.. are unarchived).
TABS_TO_FIRST_ROW=7
TABS_TO_FIRST_ROW_ARCHIVED=8
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
for tool in sqlite3 tesseract xdotool Xvfb awk; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then MAGICK=(magick); elif command -v convert >/dev/null; then
	MAGICK=(convert)
else die 2 "missing tool: magick (ImageMagick)"; fi

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp034-XXXX")"
PROFILE="${STATE}/zeo"
ALPHA="${STATE}/projects/alpha"
mkdir -p -- "${ALPHA}"
printf 'alpha\n' >"${ALPHA}/README"
cat >"${STATE}/settings.json" <<'JSON'
{"use_system_path_prompts": false, "use_system_prompts": false, "session": {"trust_all_worktrees": true}}
JSON
printf 'binary: %s\nprofile: %s\n' "${BINARY}" "${PROFILE}"

failed=0
fail() { printf 'FAIL  %s\n' "$*" && failed=1; }
ok() { printf 'ok    %s\n' "$*"; }
stop_if_failed() {
	((failed)) || return 0
	printf 'stopping after phase %s; state kept: %s\n' "$1" "${STATE}"
	exit 1
}
harness() {
	local phase="$1" steps="$2" status=0
	"${HARNESS}" --dry-run --steps "${steps}" >/dev/null || die 2 "harness refused phase ${phase}"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "${PROFILE}" \
		--steps "${steps}" || status=$?
	case "${status}" in
	0) ;;
	1) fail "phase ${phase}: Zeo or the input failed (harness exit 1)" && stop_if_failed "${phase}" ;;
	*) die 2 "xvfb-proof.sh failed on phase ${phase} (exit ${status})" ;;
	esac
}
steps() {
	local file="${STATE}/steps-$1.json"
	printf '[\n  %s\n]\n' "$2" >"${file}"
	printf '%s' "${file}"
}

# Open alpha, then show the panel with agent_tasks_panel::ToggleFocus (ctrl-alt-shift-a).
OPEN='{"sleep": 15},
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "'"${ALPHA}"'/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
  {"chord": ["ctrl", "alt", "shift", "a"]}, {"sleep": 3}'

# ── OCR (032's recipe: blue channel, 3x, threshold) ───────────────────────
SCALE=3
to_pnm() {
	"${MAGICK[@]}" "$1" -channel B -separate +channel -resize "$((SCALE * 100))%" -threshold 70% "$2" ||
		die 2 "cannot convert $1"
}
tsv() {
	local pnm="${STATE}/ocr.pnm"
	to_pnm "${OUT}/$1" "${pnm}"
	tesseract "${pnm}" - tsv 2>/dev/null || die 2 "tesseract could not read $1"
}
reads() { [[ "$(tsv "$1" | awk -F '\t' 'NR > 1 { printf "%s ", $12 }')" == *"$2"* ]]; }
check_reads() { if reads "$1" "$2"; then ok "$1 reads \"$2\" ($3)"; else fail "$1 lacks \"$2\" ($3)"; fi; }
check_not_reads() { if reads "$1" "$2"; then fail "$1 reads \"$2\" ($3)"; else ok "$1 lacks \"$2\" ($3)"; fi; }
# Centre "x y" (screen px) of the first word matching $2.
locate() {
	tsv "$1" | awk -F '\t' -v w="$2" -v s="${SCALE}" '
		NR > 1 && $12 ~ w { printf "%d %d\n", ($7 + $9 / 2) / s, ($8 + $10 / 2) / s; f = 1; exit }
		END { exit !f }'
}
# R1.1: the left edges of every "Proof" word (one per row label) agree within 1 px.
check_aligned() {
	local spread
	spread="$(tsv "$1" | awk -F '\t' -v s="${SCALE}" '
		NR > 1 && $12 == "Proof" { x = $7 / s; if (n++ == 0 || x < lo) lo = x; if (x > hi) hi = x }
		END { if (n < 4) { print "few"; exit } printf "%.1f\n", hi - lo }')"
	if [[ "${spread}" == few ]]; then
		fail "$1: fewer than four row labels read ($2)"
	elif awk -v d="${spread}" 'BEGIN { exit !(d <= 1.0) }'; then
		ok "$1: row labels start within ${spread} px ($2)"
	else
		fail "$1: row labels start ${spread} px apart — not left-aligned ($2)"
	fi
}
diff_box() {
	local g
	g="$("${MAGICK[@]}" "$1" "$2" -compose difference -composite -colorspace Gray -threshold 8% \
		-format '%@' info:)" || die 2 "cannot diff $1 $2"
	[[ "${g}" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] || return 1
	printf '%d %d %d %d\n' "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" \
		"$((BASH_REMATCH[3] + BASH_REMATCH[1]))" "$((BASH_REMATCH[4] + BASH_REMATCH[2]))"
}
# hover_scan <phase> <prefix steps> <y> <x0> <x1> <step>: one shot per hovered x.
hover_scan() {
	local phase="$1" body="$2" y="$3" x="$4" x1="$5" step="$6"
	while ((x <= x1)); do
		body+=", {\"move\": [${x}, ${y}]}, {\"sleep\": 2}, {\"shot\": \"${OUT}/${phase}-hover-${x}.png\"}"
		x=$((x + step))
	done
	harness "${phase}" "$(steps "${phase}" "${body}")"
}
# first_hover <phase> <tooltip word>: the x whose capture reads the tooltip.
first_hover() {
	local shot
	for shot in "${OUT}/$1"-hover-*.png; do
		reads "$(basename "${shot}")" "$2" && { basename "${shot}" .png | sed 's/.*-hover-//'; return 0; }
	done
	return 1
}
db_archived() { sqlite3 "${DB}" "SELECT task_id FROM agent_task_history WHERE archived = 1 ORDER BY task_id" | tr '\n' ' ' | sed 's/ $//'; }

# ── 0: first launch, then seed 62 finished records ─────────────────────────
harness 0 "$(steps 0 '{"sleep": 20}')"
DB=""
while IFS= read -r -d '' candidate; do
	if [[ "$(sqlite3 "${candidate}" "SELECT count(*) FROM sqlite_master WHERE name = 'agent_task_history'")" == 1 ]]; then
		DB="${candidate}" && break
	fi
done < <(find "${PROFILE}" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database under ${PROFILE} holds agent_task_history"
NOW_MS="$(($(date +%s) * 1000))"
{
	printf 'BEGIN;\n'
	for i in $(seq 0 60); do
		desc="$(printf 'Proof task %02d' "${i}")"
		((i % 2)) && desc+=" with a much longer description to vary the label width"
		at=$((NOW_MS - i * 60000))
		printf "INSERT INTO agent_task_history (session_id, task_id, thread_title, project, kind, description, background, status, started_at, ended_at, tokens, tool_uses, archived) VALUES ('proof-034', 't%02d', 'Proof thread', '%s', 'shell', '%s', 0, 'completed', %d, %d, 100, 3, 0);\n" \
			"${i}" "${ALPHA}" "${desc}" "${at}" "$((at + 1000))"
	done
	printf "INSERT INTO agent_task_history (session_id, task_id, thread_title, project, kind, description, background, status, started_at, ended_at, tokens, tool_uses, archived) VALUES ('proof-034', 'target', 'Proof thread', '%s', 'shell', 'Deploy zq7x pipeline', 0, 'completed', %d, %d, 100, 3, 0);\n" \
		"${ALPHA}" "$((NOW_MS - 3600000 * 5))" "$((NOW_MS - 3600000 * 5 + 1000))"
	printf 'COMMIT;\n'
} | sqlite3 "${DB}" || die 2 "seeding ${DB} failed"
ok "seeded 62 records into ${DB}"

# ── 1: alignment, scrollbar, the filter input is there ─────────────────────
harness 1 "$(steps 1 "${OPEN}, {\"move\": [5, 5]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/p1-panel.png\"}")"
check_reads p1-panel.png "Filter tasks" "R4.1 the filter input is on the toolbar"
check_reads p1-panel.png "Proof task" "the seeded rows are listed"
check_aligned p1-panel.png "R1.1 bottom dock, full width"
stop_if_failed 1
# The first "Proof" is the group header's title ("Proof thread"), just above the list's top.
read -r _ HDR_Y < <(locate p1-panel.png "^Proof$") || die 2 "no group header boxed in p1"
read -r FIL_X FIL_Y < <(locate p1-panel.png "^Filter") || die 2 "the filter input was read but not boxed"
read -r ARC_X ARC_Y < <(locate p1-panel.png "^Archived") || die 2 "the Archived toggle was not boxed"

# ── 2: the text filter; where the X sits; the scrollbar beside it ───────────
FILTER="${OPEN}, {\"click\": [${FIL_X}, ${FIL_Y}]}, {\"sleep\": 1}, {\"type\": \"zq7x\"}, {\"sleep\": 2}"
harness 2 "$(steps 2 "${FILTER}, {\"move\": [5, 5]}, {\"sleep\": 2}, {\"shot\": \"${OUT}/p2-filtered.png\"}")"
check_reads p2-filtered.png "zq7x" "R4.2 the target row is listed"
check_not_reads p2-filtered.png "Proof task" "R4.2 no unrelated row is listed"
# The X is the toolbar's last control. The bottom dock spans the editor area, which xvfb-proof.sh
# lays out the same on every run (1920x1080, window ~1536 wide and centred), so its right end is
# scanned for the "Close Panel" tooltip rather than derived from another measurement.
hover_scan 2x "${OPEN}" "${FIL_Y}" 1420 1500 6
X_X="$(first_hover 2x "Close")" || die 2 "no hover on the toolbar's right end showed \"Close Panel\""
ok "R2.1 the X (tooltip \"Close Panel\") is at ${X_X},${FIL_Y}"
# R3.1/R3.3: the scrollbar's lane runs down the list's right edge, under the X. With 62 rows the
# lane holds a thumb; filtered to one row it holds nothing. 18 px wide, from the X's centre on.
lane() { "${MAGICK[@]}" "${OUT}/$1" -crop "18x120+${X_X}+$((HDR_Y - 20))" +repage "${STATE}/$2"; }
lane p1-panel.png lane-full.png
lane p2-filtered.png lane-one.png
if read -r _ LANE_Y0 _ LANE_Y1 < <(diff_box "${STATE}/lane-full.png" "${STATE}/lane-one.png") &&
	((LANE_Y1 - LANE_Y0 >= 20)); then
	ok "R3.1 a thumb $((LANE_Y1 - LANE_Y0)) px tall in the lane under the X; none with one row (R3.3)"
	"${MAGICK[@]}" "${OUT}/p1-panel.png" -crop "60x260+$((X_X - 30))+$((HDR_Y - 40))" +repage \
		-scale 300% "${OUT}/p1-scrollbar-lane.png"
else
	fail "R3.1 no thumb in the list's right lane at x ${X_X}"
fi
stop_if_failed 2

# ── 3: select two rows from the keyboard, Archive Selected ─────────────────
# A click does not focus a row (ButtonLike keeps focus where it was), so the keyboard route starts
# from the panel itself: OPEN ends with ToggleFocus.
tabs() { local out="" _; for _ in $(seq "$1"); do out+=', {"key": ["Tab"]}'; done; printf '%s' "${out}"; }
SELECT2="${OPEN}$(tabs "${TABS_TO_FIRST_ROW}"), {\"key\": [\"shift+space\"]}$(tabs "${TABS_PER_ROW}"),
  {\"key\": [\"shift+space\"]}, {\"sleep\": 1}"
harness 3 "$(steps 3 "${SELECT2}, {\"shot\": \"${OUT}/p3-two-selected.png\"}")"
check_reads p3-two-selected.png "2 selected" "R5.5 R5.7 two rows selected from the keyboard"
stop_if_failed 3
# The selection toolbar puts "N selected" at its left and its icons at its right end, under the X.
read -r _ SEL_Y < <(locate p3-two-selected.png "^selected") || die 2 "\"selected\" not boxed"
hover_scan 3x "${SELECT2}" "${SEL_Y}" $((X_X - 70)) $((X_X + 6)) 6
ARCH_X="$(first_hover 3x "Archive Selected")" || die 2 "no hover showed \"Archive Selected Tasks\""
harness 3c "$(steps 3c "${SELECT2}, {\"click\": [${ARCH_X}, ${SEL_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/p4-after-archive-selected.png\"}")"
check_not_reads p4-after-archive-selected.png "selected" "R6.2 the selection is cleared"
got="$(db_archived)"
if [[ "${got}" == "t00 t01" ]]; then ok "R6.2 exactly t00 and t01 are archived (one click)"; else
	fail "archived rows are [${got}], want [t00 t01]"; fi
stop_if_failed 3c

# ── 4: Delete Selected under Archived asks with the count; Cancel keeps ────
SELECT_ARCH="${OPEN}, {\"click\": [${ARC_X}, ${ARC_Y}]}, {\"sleep\": 2}$(tabs "${TABS_TO_FIRST_ROW_ARCHIVED}"),
  {\"key\": [\"shift+space\"]}, {\"sleep\": 1}"
harness 4 "$(steps 4 "${SELECT_ARCH}, {\"shot\": \"${OUT}/p5-archived-selected.png\"}")"
check_reads p5-archived-selected.png "1 selected" "R5.5 an archived row selected from the keyboard"
stop_if_failed 4
read -r _ SEL4_Y < <(locate p5-archived-selected.png "^selected") || die 2 "\"selected\" not boxed in p5"
hover_scan 4x "${SELECT_ARCH}" "${SEL4_Y}" $((X_X - 70)) $((X_X + 6)) 6
DEL_X="$(first_hover 4x "Delete Selected")" || die 2 "no hover showed \"Delete Selected Records\""
harness 4c "$(steps 4c "${SELECT_ARCH}, {\"click\": [${DEL_X}, ${SEL4_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/p6-delete-selected-prompt.png\"}, {\"key\": [\"Escape\"]}, {\"sleep\": 2}")"
check_reads p6-delete-selected-prompt.png "Delete 1 task record" "R7.3 the prompt counts the selection"
check_reads p6-delete-selected-prompt.png "not affected" "R7.3 the prompt's detail"
if [[ "$(sqlite3 "${DB}" "SELECT count(*) FROM agent_task_history")" == 62 ]]; then
	ok "R7.5 Cancel deleted nothing"
else
	fail "a record was deleted without a confirm"
fi

# ── 5: the X closes; ToggleFocus reopens with the filter text kept ─────────
harness 5 "$(steps 5 "${FILTER}, {\"click\": [${X_X}, ${FIL_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/p7-closed-by-x.png\"},
  {\"chord\": [\"ctrl\", \"alt\", \"shift\", \"a\"]}, {\"sleep\": 3},
  {\"shot\": \"${OUT}/p8-reopened.png\"}")"
check_not_reads p7-closed-by-x.png "zq7x" "R2.2 the X closed the panel"
check_reads p8-reopened.png "zq7x" "R2.3 the filter text survived the X"
check_not_reads p8-reopened.png "Proof task" "R2.3 still filtered"

# ── 6: the right dock at the panel's default 320 px ────────────────────────
sqlite3 "${DB}" "INSERT OR REPLACE INTO kv_store(key, value) VALUES ('AgentTasksPanel', 'right')" ||
	die 2 "cannot write the dock position"
harness 6 "$(steps 6 "${OPEN}, {\"move\": [5, 5]}, {\"sleep\": 2}, {\"shot\": \"${OUT}/p9-right-320.png\"}")"
check_aligned p9-right-320.png "R1.1 right dock, 320 px"

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
