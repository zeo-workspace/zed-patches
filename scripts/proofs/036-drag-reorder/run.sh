#!/usr/bin/env bash
# Story 036, task 10.1 — drag to reorder projects, threads and pinned threads, with a real pointer
# on a real Zeo window, off-desktop (E2E).
#
#     run.sh --out <docs/assets/036-live-proof-DATE> [--binary <zeo-editor>]
#
# What it proves (R1.1, R1.5, R2.2, R2.4, R2.7, R4.1, R5.7, R5.8; Q11): on a build carrying the
# drag-reorder patch, a project header dragged onto another takes its place; a thread dragged onto
# the top row of its project takes that place and the project turns Manual, and the order holds
# when another thread becomes the most recent; a pinned row dragged onto the first takes its
# place; and all three orders survive a relaunch. A press-release with no motion still opens a
# thread (R5.7), and a dragged header does not collapse (R5.8).
#
# Each verdict compares the capture after an action with a negative-control capture taken before
# it in the same run, and the database is read after each action.
#
# How: one --keep directory (an isolated --user-data-dir under a fresh mktemp dir, never the
# operator's profile) and one xvfb-proof.sh run per phase. The harness replays a fixed step script,
# so a coordinate cannot be read and used in the same run: a phase captures, tesseract's TSV boxes
# locate what to point at, and the next phase relaunches into the same layout and points there.
#   0  launch once: database and migrations; seed alpha (Apricot, Blueberry, Cranberry: newest
#      first) and beta (Damson, Elderberry, Fig), and pin Fig then Elderberry (Fig first)
#   1  open alpha and beta, shot c0 (control: locate both headers, alpha's rows, the pins)
#   2  relaunch, shot c1a (control: beta above alpha); drag alpha's header onto beta's; shot c1b
#      (alpha above beta, alpha's rows still shown: not collapsed)
#   3  relaunch, shot c2a (control: Apricot above Cranberry); drag Cranberry onto Apricot; shot
#      c2b (Cranberry first); the store holds alpha Manual with three places
#   4  between launches, make Blueberry (alpha) the most recent thread and add Gooseberry to beta
#      (created first, active now); relaunch, shot c3a (alpha's order holds; Recent beta lifted
#      Gooseberry — the control that the activity is real); relaunch, click Blueberry with no
#      motion, shot c3c (it opened: its title shows in the row and in the panel)
#   5  relaunch, shot c4a (control: Fig above Elderberry); drag Elderberry onto Fig; shot c4b
#   6  relaunch (the restart), shot c5: all three orders hold
#
# Red is deferred to Run mode: on a build WITHOUT the patch (or with the harness lacking the drag
# step) the run must exit 1 at phase 2 (or 2 for the missing step).
#
# Tuning (task 10.1 ToDo 1): coordinates come from OCR, but the sleeps and the way the second
# project is opened in the same window are first guesses, to be tuned on a build of dev-036.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland, GPU,
# the drop-target highlight while dragging (no capture can be taken mid-drag with this harness).
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
grep -q '"drag"' "${HARNESS}" ||
	die 2 "xvfb-proof.sh has no {\"drag\": [x1, y1, x2, y2]} step (task 2.1); nothing can be dragged"
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
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp036-XXXX")"
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

# One word per title, each unique on screen, none equal to a project label.
APRICOT_ID="36a1000000000000000000000000000a"
BLUEBERRY_ID="36a1000000000000000000000000000b"
CRANBERRY_ID="36a1000000000000000000000000000c"
DAMSON_ID="36b1000000000000000000000000000d"
ELDERBERRY_ID="36b1000000000000000000000000000e"
FIG_ID="36b1000000000000000000000000000f"

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

# Open a folder through Zeo's own path prompt (032's tuned recipe). On a relaunch both projects
# are restored and opening them again only activates them.
# Tuned on the release build (10.1): ctrl-o is workspace::OpenFiles, which always asks for a new
# window, so a second project landed in a second window stacked over the first. ctrl-k ctrl-o is
# workspace::Open, which follows default_open_behavior (existing_window): beta joins alpha's
# window as another project group in the same sidebar.
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
# The centre ("x y"), in screen pixels, of the TOPMOST word box whose text matches $2 exactly
# (case-insensitive) INSIDE THE THREADS SIDEBAR. Topmost, because a project label also appears in
# its pinned rows ("Fig · beta"), and the Pinned section is listed after the last group.
# Tuned on the release build (10.1): the active project's name is also drawn in the title bar
# (y ~16, right of the sidebar) and at the root of the project panel, so an unbounded search
# boxed the title bar's "beta" and dragged onto it. The sidebar is bounded from its own search
# field's OCR box ("Search threads..."): below that row, and from its left edge to SIDEBAR_SPAN
# pixels right of it — less than the sidebar's default 300 px, and short of the title bar's
# project name, which starts past the sidebar's right edge.
SIDEBAR_SPAN=260
locate() {
	local pnm="${STATE}/locate.pnm" tsv
	to_pnm "${OUT}/$1" "${pnm}"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
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
		}' <<<"${tsv}"
}
# y of a word's topmost box, or die 2 naming the capture.
y_of() {
	local _x y
	read -r _x y < <(locate "$1" "$2") || die 2 "\"$2\" was not boxed in $1"
	printf '%s' "${y}"
}
# check_above <capture> <upper word> <lower word> <why>
check_above() {
	local upper lower
	upper="$(y_of "$1" "$2")"
	lower="$(y_of "$1" "$3")"
	if ((upper < lower)); then
		ok "$1: $2 above $3 ($4)"
	else
		fail "$1: $2 (y ${upper}) is not above $3 (y ${lower}) ($4)"
	fi
}
# How many boxes read the word: a title shown in its row AND in the opened thread's panel is 2.
count_word() {
	local pnm="${STATE}/count.pnm" tsv
	to_pnm "${OUT}/$1" "${pnm}"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	awk -F '\t' -v word="$2" 'NR > 1 && tolower($12) == tolower(word) { n++ } END { print n + 0 }' <<<"${tsv}"
}

# ── The database ───────────────────────────────────────────────────────────
pins() {
	sqlite3 "${DB}" "SELECT lower(hex(thread_id)) FROM thread_organization
		WHERE pinned_position IS NOT NULL ORDER BY pinned_position" | tr '\n' ' ' | sed 's/ $//'
}
manual_order() {
	sqlite3 "${DB}" "SELECT lower(hex(thread_id)) FROM thread_organization
		WHERE manual_position IS NOT NULL ORDER BY manual_position" | tr '\n' ' ' | sed 's/ $//'
}
manual_projects() {
	sqlite3 "${DB}" "SELECT count(*) FROM project_sort_mode"
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
for table in thread_organization project_sort_mode; do
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
    (X'${APRICOT_ID}', 'p036-apricot', NULL, 'Apricot', '$(t '-1 hour')', '$(t '-1 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${BLUEBERRY_ID}', 'p036-blueberry', NULL, 'Blueberry', '$(t '-2 hour')', '$(t '-2 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${CRANBERRY_ID}', 'p036-cranberry', NULL, 'Cranberry', '$(t '-3 hour')', '$(t '-3 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${DAMSON_ID}', 'p036-damson', NULL, 'Damson', '$(t '-4 hour')', '$(t '-4 hour')', '${BETA}', '0', 0, '${BETA}', '0'),
    (X'${ELDERBERRY_ID}', 'p036-elderberry', NULL, 'Elderberry', '$(t '-5 hour')', '$(t '-5 hour')', '${BETA}', '0', 0, '${BETA}', '0'),
    (X'${FIG_ID}', 'p036-fig', NULL, 'Fig', '$(t '-6 hour')', '$(t '-6 hour')', '${BETA}', '0', 0, '${BETA}', '0');
INSERT INTO thread_organization (thread_id, pinned_position) VALUES
    (X'${FIG_ID}', 0),
    (X'${ELDERBERRY_ID}', 1);
SQL
check_eq "$(pins)" "${FIG_ID} ${ELDERBERRY_ID}" "seeded pins, Fig first"
check_eq "$(manual_projects)" "0" "seeded: no Manual project"
stop_if_failed 0

# ── 1: open both projects ──────────────────────────────────────────────────
harness 1 "$(steps 1 "${OPEN},
  {\"shot\": \"${OUT}/c0-opened.png\"}")"
for word in alpha beta Apricot Cranberry Fig Elderberry; do
	check_reads c0-opened.png "${word}" "control: the sidebar shows ${word}"
done
check_above c0-opened.png beta alpha "control: the most recently opened project first"
stop_if_failed 1

# ── 2: drag alpha's header onto beta's ─────────────────────────────────────
read -r AX AY < <(locate c0-opened.png alpha) || die 2 "alpha's header not boxed in c0"
read -r BX BY < <(locate c0-opened.png beta) || die 2 "beta's header not boxed in c0"
harness 2 "$(steps 2 "${OPEN},
  {\"shot\": \"${OUT}/c1a-before-header-drag.png\"},
  {\"drag\": [${AX}, ${AY}, ${BX}, ${BY}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c1b-after-header-drag.png\"}")"
check_above c1a-before-header-drag.png beta alpha "control: beta above alpha before the drag"
check_above c1b-after-header-drag.png alpha beta "R1.1 the dragged project took beta's place"
check_reads c1b-after-header-drag.png Apricot "R5.8 the dragged header did not collapse"
stop_if_failed 2

# ── 3: drag Cranberry (alpha's last row) onto Apricot (its first) ──────────
read -r CX CY < <(locate c1b-after-header-drag.png Cranberry) || die 2 "Cranberry not boxed in c1b"
read -r PX PY < <(locate c1b-after-header-drag.png Apricot) || die 2 "Apricot not boxed in c1b"
harness 3 "$(steps 3 "${OPEN},
  {\"shot\": \"${OUT}/c2a-before-thread-drag.png\"},
  {\"drag\": [${CX}, ${CY}, ${PX}, ${PY}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c2b-after-thread-drag.png\"}")"
check_above c2a-before-thread-drag.png Apricot Cranberry "control: Recent order before the drag"
check_above c2b-after-thread-drag.png Cranberry Apricot "R2.2 the dragged thread took the top place"
check_above c2b-after-thread-drag.png Apricot Blueberry "R2.3 the others shifted by one, in order"
check_eq "$(manual_projects)" "1" "R2.2 alpha turned Manual (one project_sort_mode row)"
check_eq "$(manual_order)" "${CRANBERRY_ID} ${APRICOT_ID} ${BLUEBERRY_ID}" \
	"R2.2 the whole group was recorded in screen order"
stop_if_failed 3

# ── 4: activity, then a click with no motion ───────────────────────────────
# Zeo is not running between phases, so the database is written directly. Blueberry (alpha,
# Manual) becomes the most recent thread; in beta (Recent) a new row, Gooseberry, created before
# every beta thread but active now, is the control: Recent must lift it to the top.
NOW="$(t 'now')"
sqlite3 "${DB}" <<SQL || die 2 "updating activity in ${DB} failed"
UPDATE sidebar_threads SET updated_at = '${NOW}' WHERE thread_id = X'${BLUEBERRY_ID}';
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'36b10000000000000000000000000010', 'p036-gooseberry', NULL, 'Gooseberry', '${NOW}', '$(t '-7 hour')', '${BETA}', '0', 0, '${BETA}', '0');
SQL
# Tuned on dev-036 (10.1): sidebar_threads is only the sidebar's index. Opening a row asks the
# native agent for the session's body in threads/threads.db, and a row with no body opens a
# "Failed to Launch: no thread found" panel titled "New Zed Agent Thread", so the clicked title
# never reaches the panel. Blueberry gets a body (DbThread version 0.3.0 as plain JSON) carrying
# its title and its new activity time, with one user message: opened with no message at all, the
# thread is treated as a fresh draft (its row turns into "New Zed Agent Thread"). The message
# does not contain the title, so only the title can add a "Blueberry" box to the panel.
THREADS_DB="$(find "${PROFILE}" -path '*/threads/threads.db' -print -quit)"
[[ -n "${THREADS_DB}" ]] || die 2 "no threads/threads.db under ${PROFILE}: the native agent store was not created"
sqlite3 "${THREADS_DB}" <<SQL || die 2 "seeding Blueberry's body into ${THREADS_DB} failed"
INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, folder_paths_order, created_at)
VALUES ('p036-blueberry', 'Blueberry', '${NOW}', 'json',
    CAST('{"version": "0.3.0", "title": "Blueberry", "messages": [{"User": {"id": "p036-blueberry-1", "content": [{"Text": "Seeded message."}]}}], "updated_at": "${NOW}"}' AS BLOB),
    '${ALPHA}', '0', '$(t '-2 hour')');
SQL
harness 4 "$(steps 4 "${OPEN},
  {\"shot\": \"${OUT}/c3a-after-activity.png\"}")"
check_above c3a-after-activity.png Gooseberry Damson "control: the activity is real (Recent beta lifted Gooseberry)"
check_above c3a-after-activity.png Cranberry Blueberry "R2.4 Manual alpha ignores Blueberry's activity"
stop_if_failed 4
read -r UX UY < <(locate c3a-after-activity.png Blueberry) || die 2 "Blueberry not boxed in c3a"
harness 4b "$(steps 4b "${OPEN},
  {\"shot\": \"${OUT}/c3b-before-click.png\"},
  {\"click\": [${UX}, ${UY}]}, {\"sleep\": 3},
  {\"shot\": \"${OUT}/c3c-after-click.png\"}")"
before_count="$(count_word c3b-before-click.png Blueberry)"
after_count="$(count_word c3c-after-click.png Blueberry)"
if ((after_count > before_count)); then
	ok "R5.7 a click with no motion opened Blueberry (${before_count} -> ${after_count} boxes)"
else
	fail "R5.7 Blueberry did not open on a click (${before_count} -> ${after_count} boxes)"
fi
check_eq "$(manual_order)" "${CRANBERRY_ID} ${APRICOT_ID} ${BLUEBERRY_ID}" "R5.7 a click records no order"
stop_if_failed 4

# ── 5: drag Elderberry (second pinned row) onto Fig (the first) ────────────
read -r EX EY < <(locate c3c-after-click.png Elderberry) || die 2 "Elderberry not boxed in c3c"
read -r FX FY < <(locate c3c-after-click.png Fig) || die 2 "Fig not boxed in c3c"
harness 5 "$(steps 5 "${OPEN},
  {\"shot\": \"${OUT}/c4a-before-pinned-drag.png\"},
  {\"drag\": [${EX}, ${EY}, ${FX}, ${FY}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c4b-after-pinned-drag.png\"}")"
check_above c4a-before-pinned-drag.png Fig Elderberry "control: Fig first among the pins"
check_above c4b-after-pinned-drag.png Elderberry Fig "R4.1 the dragged pin took the first place"
check_eq "$(pins)" "${ELDERBERRY_ID} ${FIG_ID}" "R4.1 the store holds the new pinned order"
stop_if_failed 5

# ── 6: the restart ─────────────────────────────────────────────────────────
harness 6 "$(steps 6 "${OPEN},
  {\"shot\": \"${OUT}/c5-after-restart.png\"}")"
check_above c5-after-restart.png alpha beta "R1.5 the project order survives a restart"
check_above c5-after-restart.png Cranberry Apricot "R2.7 the Manual thread order survives a restart"
check_above c5-after-restart.png Apricot Blueberry "R2.7 the whole Manual order survives"
check_above c5-after-restart.png Elderberry Fig "R4.1 the pinned order survives a restart"

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
