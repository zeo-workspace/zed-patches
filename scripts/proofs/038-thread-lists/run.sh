#!/usr/bin/env bash
# Story 038, task 9.1 — the Lists view of the agent sidebar, driven with a real pointer and
# keyboard on a real Zeo window, off-desktop (E2E).
#
#     run.sh --out <docs/assets/038-live-proof-DATE> [--binary <zeo-editor>]
#
# What it proves (R1.1, R1.2, R1.3, R1.6, R2.2, R2.7, R2.9, R3.1, R3.4, R4.1, R4.2, R5.1, R5.10;
# Q11): on a build carrying the Lists view patch, the footer has a "Thread Lists" button beside
# History; clicking it replaces the thread list with the Lists view and its empty state; a list is
# created from that empty state; a thread is filed into it from its context menu ("Move to List")
# and keeps its row in the thread list; the Lists view shows the list with the thread and its
# project's name; clicking the row opens the thread in its project while the Lists view stays;
# and the view, the list and its member are back after a relaunch.
#
# Each verdict compares the capture after an action with a negative-control capture taken before
# it in the same run, and the database is read after each write.
#
# How: one --keep directory (an isolated --user-data-dir under a fresh mktemp dir, never the
# operator's profile) and one xvfb-proof.sh run per phase. The harness replays a fixed step script,
# so a coordinate cannot be read and used in the same run: a phase captures, tesseract's TSV boxes
# locate what to point at, and the next phase relaunches into the same layout and points there.
# Menus do not survive a relaunch, so each menu level costs one phase.
#   0  launch once: database and migrations; seed alpha (Apricot) and beta (Damson), and give
#      Damson a body in threads.db so it can be opened
#   1  open alpha and beta, shot c0 (control: the thread list, no Lists view); hover the footer
#      left to right, one capture per x, and find the "Thread Lists" tooltip (History's tooltip
#      is the control that the scan reached the footer)
#   2  relaunch, click the button, shot c1 (the Lists view's empty state replaced the thread list)
#   3  relaunch, shot c2a (the view was restored); click New List, type Errands, Enter, shot c2b
#      (the list exists, on screen and in thread_lists); click the button again, shot c2c (the
#      thread list is back)
#   4  relaunch, right-click Damson, shot c3a (the menu offers Move to List)
#   5  relaunch, right-click Damson, open Move to List, shot c3b (the submenu lists Errands)
#   6  relaunch, right-click Damson, Move to List, Errands, shot c3c (filed: thread_organization
#      holds Errands' id; Damson still in the thread list); click the button, shot c4a (the Lists
#      view shows Errands, Damson under it, and Damson's project name)
#   7  relaunch (the view is restored), shot c4b (control); click Damson, shot c5 (the thread
#      opened: its title reaches the panel; the Lists view is still shown)
#   8  relaunch (the restart), shot c6: the view, the list and its member are back
#
# Red is deferred to Run mode: on a build WITHOUT the patch the run must exit 1 at phase 1 (the
# footer scan finds History's tooltip and no "Thread Lists" one).
#
# Tuning (task 9.1): the footer row's y and the scan's x range come from 036's captures of the
# same harness (1920x1080 screen, sidebar at x 194..493, footer icons at y ~1065: toggle ~209,
# History ~235); the sleeps, and how the Lists view draws its New List button and rows, are first
# guesses, to be tuned on a build of dev-038. Every located coordinate is printed.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland, GPU,
# a second window (R2.8, R3.2: one window only here), the header menu (rename, delete, reorder:
# covered by the GPUI tests of task 6.1).
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
rm -f -- "${OUT}"/c[0-9]*.png "${OUT}"/footer-*.png
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp038-XXXX")"
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

# One word per title and per list name, each unique on screen, none equal to a project label or
# to a word of the Lists view's own text.
APRICOT_ID="38a1000000000000000000000000000a"
DAMSON_ID="38b1000000000000000000000000000d"
LIST_NAME="Errands"

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

# 036's tuned recipe: ctrl-k ctrl-o is workspace::Open, which follows default_open_behavior
# (existing_window), so beta joins alpha's window as another project group in the same sidebar.
# On a relaunch both projects are restored and opening them again only activates them.
open_folder() {
	printf '{"chord": ["ctrl", "k"]}, {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "%s/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8}' "$1"
}
OPEN='{"sleep": 15},
  '"$(open_folder "${ALPHA}")"',
  '"$(open_folder "${BETA}")"',
  {"chord": ["ctrl", "alt", "semicolon"]}, {"sleep": 3}'

# ── OCR and location (032's recipe: blue channel, 3x, threshold, PNM) ──────
SCALE=3
to_pnm() {
	"${MAGICK[@]}" "$1" -channel B -separate +channel -resize "$((SCALE * 100))%" -threshold 70% "$2" ||
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

# The sidebar's box, in screen pixels, measured once on the thread list's capture c0 from its
# search field's OCR box ("Search threads..."), as 036 tuned it: from that box's left edge minus
# 24 px to SIDEBAR_SPAN px right of it, below that row. The Lists view may not draw the search
# field, so later captures reuse c0's numbers: the screen, the window and the sidebar's width do
# not change between launches of one run.
SIDEBAR_SPAN=260
SB_LEFT=""
SB_RIGHT=""
SB_TOP=""
measure_sidebar() {
	local pnm="${STATE}/measure.pnm" tsv
	to_pnm "${OUT}/$1" "${pnm}"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	read -r SB_LEFT SB_RIGHT SB_TOP < <(awk -F '\t' -v s="${SCALE}" -v span="${SIDEBAR_SPAN}" '
		NR > 1 && $12 == "Search" {
			printf "%d %d %d\n", $7 / s - 24, $7 / s + span, ($8 + $10) / s
			found = 1
			exit
		}
		END { if (!found) exit 1 }' <<<"${tsv}") ||
		die 2 "the sidebar's search field was not boxed in $1"
	printf 'sidebar: x %s..%s, below y %s\n' "${SB_LEFT}" "${SB_RIGHT}" "${SB_TOP}"
}
# boxes <capture> <word> <inside:1|0>: "x y" lines (screen pixels), top to bottom, of every word
# box reading <word> exactly (case-insensitive); inside=1 keeps only boxes within the sidebar.
boxes() {
	local pnm="${STATE}/locate.pnm" tsv
	to_pnm "${OUT}/$1" "${pnm}"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	awk -F '\t' -v word="$2" -v s="${SCALE}" -v inside="$3" \
		-v l="${SB_LEFT:-0}" -v r="${SB_RIGHT:-0}" -v t="${SB_TOP:-0}" '
		NR > 1 && tolower($12) == tolower(word) {
			x = ($7 + $9 / 2) / s; y = ($8 + $10 / 2) / s
			if (inside == 1 && (x < l || x >= r || y <= t)) next
			printf "%d %d\n", x, y
		}' <<<"${tsv}" | sort -n -k2,2
}
# The topmost box of <word> in the sidebar of <capture>; exit 1 when there is none.
locate() {
	local found
	found="$(boxes "$1" "$2" 1 | head -n 1)"
	[[ -n "${found}" ]] || return 1
	printf '%s\n' "${found}"
}
# The topmost box of <word> anywhere on screen (menus are drawn past the sidebar's right edge).
locate_anywhere() {
	local found
	found="$(boxes "$1" "$2" 0 | head -n 1)"
	[[ -n "${found}" ]] || return 1
	printf '%s\n' "${found}"
}
in_sidebar() {
	locate "$1" "$2" >/dev/null
}
check_in_sidebar() {
	if in_sidebar "$1" "$2"; then
		ok "$1: the sidebar shows \"$2\" ($3)"
	else
		fail "$1: the sidebar does not show \"$2\" ($3)"
	fi
}
check_not_in_sidebar() {
	if in_sidebar "$1" "$2"; then
		fail "$1: the sidebar still shows \"$2\" ($3)"
	else
		ok "$1: the sidebar does not show \"$2\" ($3)"
	fi
}
y_of() {
	local _x y
	read -r _x y < <(locate "$1" "$2") || die 2 "\"$2\" was not boxed in the sidebar of $1"
	printf '%s' "${y}"
}
# check_above <capture> <upper word> <lower word> <why>, both inside the sidebar.
check_above() {
	local upper lower
	in_sidebar "$1" "$2" || {
		fail "$1: \"$2\" is not in the sidebar ($4)"
		return
	}
	in_sidebar "$1" "$3" || {
		fail "$1: \"$3\" is not in the sidebar ($4)"
		return
	}
	upper="$(y_of "$1" "$2")"
	lower="$(y_of "$1" "$3")"
	if ((upper < lower)); then
		ok "$1: $2 above $3 ($4)"
	else
		fail "$1: $2 (y ${upper}) is not above $3 (y ${lower}) ($4)"
	fi
}
# How many boxes read the word anywhere: a title shown in its row AND in the opened thread's
# panel is 2.
count_word() {
	boxes "$1" "$2" 0 | wc -l
}

# ── The footer: one capture per hovered x, kept by the tooltip it shows ────
# 034's hover scan. 036's captures put the footer icons at y ~1065 on this screen.
FOOTER_Y=1065
hover_scan_steps() {
	local x="$1" x1="$2" step="$3" body=""
	while ((x <= x1)); do
		body+=", {\"move\": [${x}, ${FOOTER_Y}]}, {\"sleep\": 2}, {\"shot\": \"${OUT}/footer-${x}.png\"}"
		x=$((x + step))
	done
	printf '%s' "${body}"
}
# first_hover <tooltip text>: the x whose capture reads the tooltip.
first_hover() {
	local shot
	for shot in "${OUT}"/footer-*.png; do
		[[ -e "${shot}" ]] || continue
		reads "$(basename "${shot}")" "$1" && {
			basename "${shot}" .png | sed 's/^footer-//'
			return 0
		}
	done
	return 1
}

# ── The database ───────────────────────────────────────────────────────────
list_names() {
	sqlite3 "${DB}" "SELECT name FROM thread_lists ORDER BY position" | tr '\n' ' ' | sed 's/ $//'
}
list_id_of() {
	sqlite3 "${DB}" "SELECT id FROM thread_lists WHERE name = '$1'"
}
damson_list() {
	sqlite3 "${DB}" "SELECT ifnull(list_id, '') FROM thread_organization
		WHERE thread_id = X'${DAMSON_ID}'"
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
for table in thread_organization thread_lists; do
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
    (X'${APRICOT_ID}', 'p038-apricot', NULL, 'Apricot', '$(t '-1 hour')', '$(t '-1 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${DAMSON_ID}', 'p038-damson', NULL, 'Damson', '$(t '-2 hour')', '$(t '-2 hour')', '${BETA}', '0', 0, '${BETA}', '0');
SQL
# 036's tuned lesson: sidebar_threads is only the sidebar's index. Opening a row asks the native
# agent for the session's body in threads/threads.db; with none, the panel shows "Failed to
# Launch" under "New Zed Agent Thread" and the title never reaches it. Damson gets a body
# (DbThread version 0.3.0 as plain JSON) with one user message that does not contain its title,
# so only the title can add a "Damson" box to the panel.
THREADS_DB="$(find "${PROFILE}" -path '*/threads/threads.db' -print -quit)"
[[ -n "${THREADS_DB}" ]] || die 2 "no threads/threads.db under ${PROFILE}: the native agent store was not created"
sqlite3 "${THREADS_DB}" <<SQL || die 2 "seeding Damson's body into ${THREADS_DB} failed"
INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, folder_paths_order, created_at)
VALUES ('p038-damson', 'Damson', '$(t '-2 hour')', 'json',
    CAST('{"version": "0.3.0", "title": "Damson", "messages": [{"User": {"id": "p038-damson-1", "content": [{"Text": "Seeded message."}]}}], "updated_at": "$(t '-2 hour')"}' AS BLOB),
    '${BETA}', '0', '$(t '-2 hour')');
SQL
check_eq "$(list_names)" "" "seeded: no list"
stop_if_failed 0

# ── 1: the thread list, then the footer scan ───────────────────────────────
harness 1 "$(steps 1 "${OPEN},
  {\"shot\": \"${OUT}/c0-thread-list.png\"}$(hover_scan_steps 200 330 8)")"
measure_sidebar c0-thread-list.png
check_in_sidebar c0-thread-list.png Apricot "control: the thread list shows alpha's thread"
check_in_sidebar c0-thread-list.png Damson "control: the thread list shows beta's thread"
check_not_in_sidebar c0-thread-list.png "${LIST_NAME}" "control: no list exists"
HX="$(first_hover "Thread History")" ||
	die 2 "no footer capture showed History's tooltip: the scan missed the footer (tune FOOTER_Y)"
ok "control: History's button is at ${HX},${FOOTER_Y}"
if LX="$(first_hover "Thread Lists")"; then
	ok "R1.1 the Thread Lists button is at ${LX},${FOOTER_Y}, beside History (${HX})"
else
	fail "R1.1 no footer button shows a \"Thread Lists\" tooltip"
fi
stop_if_failed 1

# ── 2: the button shows the Lists view ─────────────────────────────────────
harness 2 "$(steps 2 "${OPEN},
  {\"click\": [${LX}, ${FOOTER_Y}]}, {\"sleep\": 2},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c1-lists-empty.png\"}")"
check_not_in_sidebar c1-lists-empty.png Apricot "R1.2 the Lists view replaced the thread list"
check_in_sidebar c1-lists-empty.png New "R2.7 the empty state offers New List"
stop_if_failed 2

# ── 3: the view is restored; create a list; leave the view ─────────────────
read -r NX NY < <(locate c1-lists-empty.png New) || die 2 "New List was not boxed in c1"
printf 'New List: %s,%s\n' "${NX}" "${NY}"
harness 3 "$(steps 3 "${OPEN},
  {\"shot\": \"${OUT}/c2a-restored-empty.png\"},
  {\"click\": [${NX}, ${NY}]}, {\"sleep\": 1},
  {\"type\": \"${LIST_NAME}\"}, {\"key\": [\"Return\"]}, {\"sleep\": 2},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c2b-list-created.png\"},
  {\"click\": [${LX}, ${FOOTER_Y}]}, {\"sleep\": 2},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c2c-thread-list-again.png\"}")"
check_in_sidebar c2a-restored-empty.png New "R1.6 the Lists view was restored on relaunch"
check_not_in_sidebar c2a-restored-empty.png Apricot "R1.6 and not the thread list"
check_not_in_sidebar c2a-restored-empty.png "${LIST_NAME}" "control: no list before New List"
check_in_sidebar c2b-list-created.png "${LIST_NAME}" "R5.1 the new list's header is shown"
check_not_in_sidebar c2b-list-created.png beta "control: no row carries beta before a thread is filed"
check_eq "$(list_names)" "${LIST_NAME}" "R5.1 thread_lists holds the new list"
check_in_sidebar c2c-thread-list-again.png Apricot "R1.3 a second click shows the thread list"
check_not_in_sidebar c2c-thread-list-again.png "${LIST_NAME}" "R1.3 and the Lists view is gone"
stop_if_failed 3

# ── 4: the thread's menu offers Move to List ───────────────────────────────
read -r DX DY < <(locate c2c-thread-list-again.png Damson) || die 2 "Damson was not boxed in c2c"
printf 'Damson (thread list): %s,%s\n' "${DX}" "${DY}"
harness 4 "$(steps 4 "${OPEN},
  {\"rclick\": [${DX}, ${DY}]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c3a-thread-menu.png\"}")"
check_reads c3a-thread-menu.png "Move to List" "R4.1 the thread's context menu offers Move to List"
check_reads c3a-thread-menu.png "Archive Thread" "control: it is the thread's context menu"
stop_if_failed 4

# ── 5: the submenu lists the list ──────────────────────────────────────────
read -r MX MY < <(locate_anywhere c3a-thread-menu.png Move) || die 2 "Move to List was not boxed in c3a"
printf 'Move to List: %s,%s\n' "${MX}" "${MY}"
# The click opens the submenu, but ContextMenu draws it only once the trigger row has painted
# with its bounds recorded, which takes one more frame; under Xvfb nothing else asks for that
# frame, so a pointer move on the same row does (tuning run 1 on dev-038: c3b showed the row
# highlighted and no submenu; one more move drew it).
OPEN_SUBMENU="{\"click\": [${MX}, ${MY}]}, {\"sleep\": 1},
  {\"move\": [$((MX + 5)), ${MY}]}, {\"sleep\": 1}"
harness 5 "$(steps 5 "${OPEN},
  {\"rclick\": [${DX}, ${DY}]}, {\"sleep\": 1},
  ${OPEN_SUBMENU},
  {\"shot\": \"${OUT}/c3b-submenu.png\"}")"
check_reads c3b-submenu.png "${LIST_NAME}" "R4.1 the submenu lists the list"
check_reads c3b-submenu.png "New List" "R4.1 the submenu ends with New List..."
stop_if_failed 5

# ── 6: file the thread, then look at the Lists view ────────────────────────
read -r EX EY < <(locate_anywhere c3b-submenu.png "${LIST_NAME}") ||
	die 2 "${LIST_NAME} was not boxed in the submenu of c3b"
printf '%s (submenu): %s,%s\n' "${LIST_NAME}" "${EX}" "${EY}"
harness 6 "$(steps 6 "${OPEN},
  {\"rclick\": [${DX}, ${DY}]}, {\"sleep\": 1},
  ${OPEN_SUBMENU},
  {\"click\": [${EX}, ${EY}]}, {\"sleep\": 2},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c3c-filed-thread-list.png\"},
  {\"click\": [${LX}, ${FOOTER_Y}]}, {\"sleep\": 2},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c4a-lists-with-member.png\"}")"
check_eq "$(damson_list)" "$(list_id_of "${LIST_NAME}")" "R4.2 Damson is recorded in ${LIST_NAME}"
check_in_sidebar c3c-filed-thread-list.png Damson "R2.9 Damson keeps its row in the thread list"
check_above c4a-lists-with-member.png "${LIST_NAME}" Damson "R4.2 Damson is shown under ${LIST_NAME}"
check_in_sidebar c4a-lists-with-member.png beta "R2.2 the row carries its project's name"
check_not_in_sidebar c4a-lists-with-member.png Apricot "control: an unfiled thread is not in the view"
stop_if_failed 6

# ── 7: open the thread from the view ───────────────────────────────────────
read -r RX RY < <(locate c4a-lists-with-member.png Damson) || die 2 "Damson was not boxed in c4a"
printf 'Damson (Lists view): %s,%s\n' "${RX}" "${RY}"
harness 7 "$(steps 7 "${OPEN},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c4b-before-open.png\"},
  {\"click\": [${RX}, ${RY}]}, {\"sleep\": 4},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c5-opened.png\"}")"
check_above c4b-before-open.png "${LIST_NAME}" Damson "control: the restored view before the click"
before_count="$(count_word c4b-before-open.png Damson)"
after_count="$(count_word c5-opened.png Damson)"
if ((after_count > before_count)); then
	ok "R3.1 a click on the row opened Damson (${before_count} -> ${after_count} boxes)"
else
	fail "R3.1 Damson did not open from the Lists view (${before_count} -> ${after_count} boxes)"
fi
check_above c5-opened.png "${LIST_NAME}" Damson "R3.4 the Lists view is still shown after opening"
stop_if_failed 7

# ── 8: the restart ─────────────────────────────────────────────────────────
harness 8 "$(steps 8 "${OPEN},
  {\"move\": [960, 540]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c6-after-restart.png\"}")"
check_above c6-after-restart.png "${LIST_NAME}" Damson "R1.6 R5.10 the view, the list and its member survive a restart"
check_not_in_sidebar c6-after-restart.png Apricot "R1.6 the Lists view, not the thread list"
check_eq "$(list_names)" "${LIST_NAME}" "R5.10 thread_lists after the restart"
check_eq "$(damson_list)" "$(list_id_of "${LIST_NAME}")" "R5.10 Damson's list after the restart"

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
