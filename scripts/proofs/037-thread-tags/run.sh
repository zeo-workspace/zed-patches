#!/usr/bin/env bash
# Story 037, task 9.1 — thread tags on a real Zeo window, off-desktop (E2E): a tag set through the
# thread menu and the Tags picker, its chip, the `#tag` filter in the sidebar and in History,
# and the chip after a relaunch.
#
#     run.sh --out <docs/assets/037-live-proof-DATE> [--binary <zeo-editor>]
#
# What it proves (R1.1, R1.4, R1.5, R2.1, R2.7, R4.1, R4.2, R5.1; Q11): on a build carrying the
# thread-tags patch, a thread row's menu offers "Tags…"; the picker offers "Add tag" for a new
# tag and adds it on Enter; the row then shows the tag as a chip; `#php` in the sidebar filter
# leaves only the threads carrying the tag, across both projects and the Pinned section;
# `#php apricot` also requires the title; `#php` in History lists only the project's tagged
# thread; and the chip is still there after a relaunch. The database is read after the tag.
#
# Each verdict compares a capture after an action with a negative-control capture of the same
# run taken before it.
#
# How: one --keep directory (an isolated --user-data-dir under a fresh mktemp dir, never the
# operator's profile) and one xvfb-proof.sh run per phase. The harness replays a fixed step
# script, so a coordinate cannot be read and used in the same run: a phase captures, tesseract's
# TSV boxes locate what to point at, and the next phase relaunches into the same layout.
#   0  launch once: database and migrations; seed alpha (Apricot, Blueberry, Cranberry) and beta
#      (Damson, Elderberry, Fig), pin Fig; no tag anywhere
#   1  open alpha and beta, shot c0 (control: every title, no "php" anywhere)
#   2  relaunch, right-click Apricot, shot c1 (R1.1: the menu reads "Tags")
#   3  relaunch, right-click Apricot, choose Tags…, type php, shot c2a (R1.4: "Add tag"), Enter,
#      Escape, shot c2b (R1.5, R2.1: a "php" chip on Apricot's row); the database holds the tag
#   4  between launches, tag Damson (beta) php in the database; relaunch, sidebar filter `#php`,
#      shot c3a (R4.1); `#php apricot`, shot c3b (R4.2)
#   5  relaunch, open History, shot c4a (control: the active project's threads), filter `#php`,
#      shot c4b (R5.1)
#   6  relaunch (the restart), shot c5 (R2.7: the chip on Apricot's row)
#
# Red is deferred to Run mode: on a build WITHOUT the patch the run must exit 1 at phase 2 (the
# menu has no "Tags…").
#
# Tuning (task 9.1 ToDo 1): coordinates come from OCR, but the sleeps, the History key path
# (ctrl-g, then ctrl-f into its filter) and the chip's OCR (a small label) are first guesses, to
# be tuned on a build of dev-037.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland,
# GPU, the chips' tooltip (R2.3: no hover capture is taken), the picker's narrowing (GPUI tests).
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, a
# capture could not be read or located).

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
grep -q '"rclick"' "${HARNESS}" ||
	die 2 "xvfb-proof.sh has no {\"rclick\": [x, y]} step; no context menu can be opened"
for tool in sqlite3 tesseract xdotool Xvfb awk; do
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
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp037-XXXX")"
PROFILE="${STATE}/zeo"
ALPHA="${STATE}/projects/alpha"
BETA="${STATE}/projects/beta"
mkdir -p -- "${ALPHA}" "${BETA}"
printf 'alpha\n' >"${ALPHA}/README"
printf 'beta\n' >"${BETA}/README"
cat >"${STATE}/settings.json" <<'JSON'
{"use_system_path_prompts": false, "session": {"trust_all_worktrees": true}}
JSON
printf 'binary: %s\nprofile: %s\n' "${BINARY}" "${PROFILE}"

# One word per title, each unique on screen, none equal to a project label or to the tag.
APRICOT_ID="37a1000000000000000000000000000a"
BLUEBERRY_ID="37a1000000000000000000000000000b"
CRANBERRY_ID="37a1000000000000000000000000000c"
DAMSON_ID="37b1000000000000000000000000000d"
ELDERBERRY_ID="37b1000000000000000000000000000e"
FIG_ID="37b1000000000000000000000000000f"
TAG="php"

failed=0
fail() {
	printf 'FAIL  %s\n' "$*"
	failed=1
}
ok() {
	printf 'ok    %s\n' "$*"
}
stop_if_failed() {
	if ((failed)); then
		printf 'stopping after phase %s: a check failed, later phases depend on it\n' "$1"
		printf 'state kept for inspection: %s\n' "${STATE}"
		exit 1
	fi
}

# The steps are validated (--dry-run) before each launch, so a refusal is the script's fault
# (exit 2) and an exit 1 during the run is Zeo or the input failing.
harness() {
	local phase="$1" steps="$2" status=0
	"${HARNESS}" --dry-run --steps "${steps}" >/dev/null ||
		die 2 "xvfb-proof.sh refused the steps of phase ${phase}"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "${PROFILE}" \
		--steps "${steps}" || status=$?
	case "${status}" in
	0) ;;
	1)
		fail "phase ${phase}: Zeo or the input failed during the run (exit 1 from the harness)"
		stop_if_failed "${phase}"
		;;
	*) die 2 "xvfb-proof.sh failed on phase ${phase} (exit ${status})" ;;
	esac
}

steps() {
	local file="${STATE}/steps-$1.json"
	printf '[\n  %s\n]\n' "$2" >"${file}"
	printf '%s' "${file}"
}

# 036's tuned recipe: ctrl-k ctrl-o is workspace::Open, so beta joins alpha's window as a second
# project group of the same sidebar; on a relaunch both are restored and this only activates them.
open_folder() {
	printf '{"chord": ["ctrl", "k"]}, {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "%s/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8}' "$1"
}
OPEN='{"sleep": 15},
  '"$(open_folder "${ALPHA}")"',
  '"$(open_folder "${BETA}")"',
  {"chord": ["ctrl", "alt", "semicolon"]}, {"sleep": 3}'
# Focus the sidebar's filter (or History's, while History is shown) and replace its text.
# No ctrl-alt-; here: FocusWorkspaceSidebar is a toggle (multi_workspace.rs `focus_sidebar`), and
# OPEN already left the sidebar focused, so pressing it again moved focus out and the text was
# lost (tuning run 1 on dev-037). ctrl-f is ThreadsSidebar's FocusSidebarFilter, reached from the
# list and from the filter editor alike.
filter_steps() {
	printf '{"chord": ["ctrl", "f"]}, {"sleep": 1}, {"chord": ["ctrl", "a"]}, {"type": "%s"}, {"sleep": 3}' "$1"
}

# ── OCR and location (032's recipe, red channel instead of blue: 3x, threshold, PNM) ──
# A title the filter matched is drawn in the accent blue, which the blue channel thresholds to
# white (tuning run 1: "Apricot" vanished from c3b). Neutral text has R = G = B, so it reads the
# same in either channel.
SCALE=3
to_pnm() {
	"${MAGICK[@]}" "$1" -channel R -separate +channel -resize "$((SCALE * 100))%" -threshold 70% "$2" ||
		die 2 "cannot convert $1 for tesseract"
}
ocr() {
	local pnm="${STATE}/ocr.pnm" text
	to_pnm "$1" "${pnm}"
	text="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read $1"
	tr '\n' ' ' <<<"${text}"
}
reads() {
	[[ "$(ocr "${OUT}/$1")" == *"$2"* ]]
}
check_reads() {
	if reads "$1" "$2"; then ok "$1 reads \"$2\" ($3)"; else fail "$1 does not read \"$2\" ($3)"; fi
}
check_not_reads() {
	if reads "$1" "$2"; then fail "$1 reads \"$2\" ($3)"; else ok "$1 does not read \"$2\" ($3)"; fi
}
tsv_of() {
	local pnm="${STATE}/locate.pnm"
	to_pnm "${OUT}/$1" "${pnm}"
	tesseract "${pnm}" - tsv 2>/dev/null || die 2 "tesseract could not box $1"
}
# The centre ("x y"), in screen pixels, of the TOPMOST word box matching $2 exactly
# (case-insensitive) inside the threads sidebar: below its search field's "Search" box, from its
# left edge to SIDEBAR_SPAN pixels right of it (036's bounds, which keep the title bar's project
# name out).
SIDEBAR_SPAN=260
locate() {
	awk -F '\t' -v word="$2" -v s="${SCALE}" -v span="${SIDEBAR_SPAN}" '
		NR > 1 && !anchored && $12 == "Search" {
			left = $7 - 24 * s; right = $7 + span * s; below = $8 + $10; anchored = 1
		}
		NR > 1 { box[NR] = $0 }
		END {
			if (!anchored) exit 1
			for (r in box) {
				split(box[r], f, "\t")
				if (tolower(f[12]) != tolower(word) || f[7] < left || f[7] >= right || f[8] <= below) continue
				y = f[8] + f[10] / 2
				if (!found || y < best_y) { best_y = y; best_x = f[7] + f[9] / 2; found = 1 }
			}
			if (!found) exit 1
			printf "%d %d\n", best_x / s, best_y / s
		}' < <(tsv_of "$1")
}
# The centre of the topmost box ANYWHERE on screen whose text starts with $2 (case-insensitive):
# a context menu can reach past the sidebar's span, and OCR reads "Tags…" as "Tags…" or "Tags...".
locate_anywhere() {
	awk -F '\t' -v prefix="$2" -v s="${SCALE}" '
		NR > 1 && index(tolower($12), tolower(prefix)) == 1 {
			y = $8 + $10 / 2
			if (!found || y < best_y) { best_y = y; best_x = $7 + $9 / 2; found = 1 }
		}
		END {
			if (!found) exit 1
			printf "%d %d\n", best_x / s, best_y / s
		}' < <(tsv_of "$1")
}
# check_on_row <capture> <word> <row word> <why>: a box reading <word> (prefix, so a chip read as
# "php," still counts) sits on the row of <row word>, within ROW_TOLERANCE pixels of its centre.
ROW_TOLERANCE=8
check_on_row() {
	local _x row_y
	if ! read -r _x row_y < <(locate "$1" "$3"); then
		fail "$1: the row \"$3\" was not boxed ($4)"
		return
	fi
	if awk -F '\t' -v word="$2" -v s="${SCALE}" -v y="${row_y}" -v tol="${ROW_TOLERANCE}" '
		NR > 1 && index(tolower($12), tolower(word)) == 1 {
			d = ($8 + $10 / 2) / s - y
			if (d < 0) d = -d
			if (d <= tol) found = 1
		}
		END { exit !found }' < <(tsv_of "$1"); then
		ok "$1: \"$2\" on the row of $3 ($4)"
	else
		fail "$1: no \"$2\" on the row of $3 at y ${row_y} ($4)"
	fi
}

# ── The database ───────────────────────────────────────────────────────────
thread_tags() {
	sqlite3 "${DB}" "SELECT lower(hex(thread_id)) || ':' || tag_key FROM thread_tags
		ORDER BY 1" | tr '\n' ' ' | sed 's/ $//'
}
tag_display() {
	sqlite3 "${DB}" "SELECT display FROM tags WHERE tag_key = '$1'"
}
check_eq() {
	local got="$1" want="$2" why="$3"
	if [[ "${got}" == "${want}" ]]; then ok "${why}: [${got}]"; else fail "${why}: [${got}], want [${want}]"; fi
}

# ── 0: first launch, then seed ─────────────────────────────────────────────
harness 0 "$(steps 0 '{"sleep": 20}')"
has_table() {
	[[ "$(sqlite3 "$1" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$2'")" == 1 ]]
}
DB=""
while IFS= read -r -d '' candidate; do
	if has_table "${candidate}" sidebar_threads; then
		DB="${candidate}"
		break
	fi
done < <(find "${PROFILE}" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database under ${PROFILE} holds sidebar_threads"
for table in thread_organization thread_tags tags; do
	has_table "${DB}" "${table}" || die 2 "${DB} has no ${table} table: not a build with patch 0048"
done
printf 'database: %s\n' "${DB}"
t() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
# agent_id NULL is the native agent's id, so no agent server is needed.
sqlite3 "${DB}" <<SQL || die 2 "seeding ${DB} failed"
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'${APRICOT_ID}', 'p037-apricot', NULL, 'Apricot', '$(t '-1 hour')', '$(t '-1 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${BLUEBERRY_ID}', 'p037-blueberry', NULL, 'Blueberry', '$(t '-2 hour')', '$(t '-2 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${CRANBERRY_ID}', 'p037-cranberry', NULL, 'Cranberry', '$(t '-3 hour')', '$(t '-3 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${DAMSON_ID}', 'p037-damson', NULL, 'Damson', '$(t '-4 hour')', '$(t '-4 hour')', '${BETA}', '0', 0, '${BETA}', '0'),
    (X'${ELDERBERRY_ID}', 'p037-elderberry', NULL, 'Elderberry', '$(t '-5 hour')', '$(t '-5 hour')', '${BETA}', '0', 0, '${BETA}', '0'),
    (X'${FIG_ID}', 'p037-fig', NULL, 'Fig', '$(t '-6 hour')', '$(t '-6 hour')', '${BETA}', '0', 0, '${BETA}', '0');
INSERT INTO thread_organization (thread_id, pinned_position) VALUES (X'${FIG_ID}', 0);
SQL
check_eq "$(thread_tags)" "" "seeded: no tag anywhere"
stop_if_failed 0

# ── 1: open both projects (the control) ────────────────────────────────────
harness 1 "$(steps 1 "${OPEN},
  {\"shot\": \"${OUT}/c0-opened.png\"}")"
for word in alpha beta Apricot Blueberry Damson Elderberry Fig; do
	check_reads c0-opened.png "${word}" "control: the sidebar shows ${word}"
done
check_not_reads c0-opened.png "${TAG}" "control: no chip before the tag"
stop_if_failed 1

# ── 2: the thread menu offers Tags… ────────────────────────────────────────
read -r AX AY < <(locate c0-opened.png Apricot) || die 2 "Apricot not boxed in c0"
harness 2 "$(steps 2 "${OPEN},
  {\"rclick\": [${AX}, ${AY}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c1-menu.png\"},
  {\"key\": [\"Escape\"]}, {\"sleep\": 1}")"
check_reads c1-menu.png "Archive" "control: Apricot's context menu is open"
check_reads c1-menu.png "Tags" "R1.1 the thread menu offers Tags…"
stop_if_failed 2

# ── 3: tag Apricot through the menu and the picker ─────────────────────────
read -r TX TY < <(locate_anywhere c1-menu.png Tags) || die 2 "\"Tags\" not boxed in c1"
harness 3 "$(steps 3 "${OPEN},
  {\"rclick\": [${AX}, ${AY}]}, {\"sleep\": 2},
  {\"click\": [${TX}, ${TY}]}, {\"sleep\": 2},
  {\"type\": \"${TAG}\"}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c2a-picker-typed.png\"},
  {\"key\": [\"Return\"]}, {\"sleep\": 2},
  {\"key\": [\"Escape\"]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c2b-chip.png\"}")"
check_reads c2a-picker-typed.png "Add tag" "R1.4 a new tag is offered as \"Add tag\""
check_on_row c2b-chip.png "${TAG}" Apricot "R1.5, R2.1 the tag shows as a chip on Apricot's row"
check_reads c2b-chip.png Blueberry "control: the other rows are still shown"
check_eq "$(thread_tags)" "${APRICOT_ID}:${TAG}" "R1.5 the store holds the tag on Apricot only"
check_eq "$(tag_display "${TAG}")" "${TAG}" "R1.5 in the spelling typed"
stop_if_failed 3

# ── 4: the sidebar filter ──────────────────────────────────────────────────
# Zeo is not running between phases, so the second tagged thread is written directly; the tag's
# display row already exists (phase 3).
sqlite3 "${DB}" "INSERT INTO thread_tags (thread_id, tag_key) VALUES (X'${DAMSON_ID}', '${TAG}')" ||
	die 2 "tagging Damson in ${DB} failed"
harness 4 "$(steps 4 "${OPEN},
  {\"shot\": \"${OUT}/c3-before-filter.png\"},
  $(filter_steps "#${TAG}"),
  {\"shot\": \"${OUT}/c3a-filter-tag.png\"},
  $(filter_steps "#${TAG} apricot"),
  {\"shot\": \"${OUT}/c3b-filter-tag-and-text.png\"},
  {\"chord\": [\"ctrl\", \"a\"]}, {\"key\": [\"BackSpace\"]}, {\"sleep\": 1}")"
for word in Blueberry Cranberry Elderberry Fig; do
	check_reads c3-before-filter.png "${word}" "control: ${word} is shown before the filter"
done
check_reads c3a-filter-tag.png Apricot "R4.1 the tagged alpha thread"
check_reads c3a-filter-tag.png Damson "R4.1 the tagged beta thread, in the other project"
for word in Blueberry Cranberry Elderberry Fig; do
	check_not_reads c3a-filter-tag.png "${word}" "R4.1, R4.7 the untagged ${word} is hidden"
done
check_reads c3b-filter-tag-and-text.png Apricot "R4.2 tag and title both match"
check_not_reads c3b-filter-tag-and-text.png Damson "R4.2 tagged, but the title does not match"
stop_if_failed 4

# ── 5: the History filter ──────────────────────────────────────────────────
harness 5 "$(steps 5 "${OPEN},
  {\"chord\": [\"ctrl\", \"g\"]}, {\"sleep\": 3},
  {\"shot\": \"${OUT}/c4a-history.png\"},
  $(filter_steps "#${TAG}"),
  {\"shot\": \"${OUT}/c4b-history-tag.png\"},
  {\"chord\": [\"ctrl\", \"a\"]}, {\"key\": [\"BackSpace\"]}, {\"sleep\": 1},
  {\"chord\": [\"ctrl\", \"g\"]}, {\"sleep\": 2}")"
# The teardown above closes History again: the sidebar's view survives a relaunch, and phase 6
# must reopen on the thread list (tuning run 2 on dev-037: c5 came back in History).
# History lists the active project's threads (0015); which project is active after the two opens
# is read from the control rather than assumed.
if reads c4a-history.png Elderberry; then
	tagged=Damson
	untagged=(Elderberry Fig)
elif reads c4a-history.png Blueberry; then
	tagged=Apricot
	untagged=(Blueberry Cranberry)
else
	die 2 "c4a-history.png shows neither project's threads: History did not open"
fi
ok "control: History lists the active project (its tagged thread is ${tagged})"
check_reads c4b-history-tag.png "${tagged}" "R5.1 History lists the tagged thread"
for word in "${untagged[@]}"; do
	check_not_reads c4b-history-tag.png "${word}" "R5.1 History hides the untagged ${word}"
done
stop_if_failed 5

# ── 6: the restart ─────────────────────────────────────────────────────────
harness 6 "$(steps 6 "${OPEN},
  {\"shot\": \"${OUT}/c5-after-restart.png\"}")"
check_on_row c5-after-restart.png "${TAG}" Apricot "R2.7 the chip survives a restart"
check_on_row c5-after-restart.png "${TAG}" Damson "R2.1 the database-written tag shows too"
check_eq "$(thread_tags)" "${APRICOT_ID}:${TAG} ${DAMSON_ID}:${TAG}" "the store after the restart"

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
