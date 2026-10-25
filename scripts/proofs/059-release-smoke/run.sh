#!/usr/bin/env bash
# Story 059, task 7.3 — smoke proof of the released Zeo 0.7.0 on a private X display (E2E).
#
#     run.sh --version <X.Y.Z> --out <docs/assets/059-release-0.7.0> [--binary <zeo-editor>]
#     run.sh --self-test        (the pure matchers only: no display, no editor)
#
# What it proves (R7.3, Q9): the editor the operator emerged opens a window, its About names the
# released version exactly, and one visible feature of each patch the release train carries is
# present, each against a negative control taken in the same run:
#   0068  thread tags: a tag seeded on Apricot shows as a "php" chip on Apricot's row and on no
#         other row (Blueberry, seeded untagged, is the control); the thread menu offers "Tags…"
#         (control: the same menu offers "Archive", so it is open);
#   0069  the Lists view: the sidebar footer has a "Thread Lists" button (control: History's
#         tooltip is found in the same hover scan); clicking it replaces the thread list with the
#         Lists view's empty state ("New List", no Apricot row); the thread menu offers
#         "Move to List";
#   0070  sub-threads from a selection: the reply's menu offers "Clean sub-thread" over a selected
#         phrase and no sub-thread entry without a selection (control); a thread seeded with a
#         parent link shows the "Sub-thread of" header, and its parent does not (control);
#   0071  Send to Parent: the linked thread's footer offers "Send to Parent", and the parent's
#         does not (control).
# "Sub-thread with context" is not checked: it needs an agent that forks sessions, and the seeded
# threads belong to the native agent, which does not (0070's header). No model turn is taken.
#
# How (the 037, 038 and 039 recipes, on one --keep directory: an isolated --user-data-dir under a
# fresh mktemp dir, never the operator's profile; one xvfb-proof.sh run per phase). The harness
# replays a fixed step script, so a point found in one phase's capture is used in the next:
#   0  launch once: databases and migrations; seed project alpha with Apricot (tagged php),
#      Blueberry, Marmalade (a body with the reply QUINCUNX ORBIT ZEPHYR) and Forkling (a body,
#      linked to Marmalade as a clean sub-thread in thread_organization)
#   1  open alpha: p1-sidebar (rows, the chip); hover the footer, one capture per x (038)
#   2  relaunch: the thread menu on Apricot; the Lists view and back; open Marmalade, then
#      Forkling (header and Send to Parent against the parent)
#   3  relaunch: open Marmalade; its reply's menu without, then with, a selected phrase; About
# Every seed uses tables that 0.6.1 already has (0048), so on a build without a patch the seed
# succeeds and the check of that patch fails: a missing feature is exit 1, never exit 2.
#
# Binary: the installed editor is /usr/libexec/zeo-editor (the harness's default). /usr/bin/zeo is
# the CLI launcher, which forwards to a running Zeo; it is refused.
#
# Red: deferred to Run mode. Against the installed 0.6.1 the About does not read "Zeo 0.7.0" and
# no chip, Tags…, Lists button, Move to List, header, Clean sub-thread or Send to Parent is drawn,
# while every control passes: the run exits 1.
#
# Tuning: FOOTER_Y and the scan range are 038's (1920x1080, debug build), the About crop is 048's,
# the selection drag is 039's; that the native agent opens a seeded body with an agent message and
# draws its composer footer is a first guess (038 opened a body with a user message only). Tune on
# the release build if needed and record what changed in the README; never change a verdict.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland, GPU,
# a real agent turn, a fork with context, delivering to the parent, the Agent Tasks panel's
# sub-thread item, the tag filter, filing into a list (each proved live by 037–040).
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

# ── Pure matchers: exercised by --self-test, which needs no display ───────
SCALE=3
# names_version <text> <X.Y.Z>: "Zeo X.Y.Z" not followed by a digit, dots literal, so 0.7.01,
# 0.7.00 and 0x7y0 never pass for 0.7.0.
names_version() {
	grep -qE "Zeo ${2//./\\.}([^0-9]|\$)" <<<"$1"
}
# row_has <prefix> <row y> <left> <right> < tesseract TSV (3x): a box starting with <prefix>
# (case-insensitive; "php," still counts) whose centre is inside the sidebar's x span and within
# ROW_TOLERANCE px of the row's centre. A chip on the next row, or the word elsewhere on the same
# line of the screen, is not on the row.
ROW_TOLERANCE=8
row_has() {
	awk -F '\t' -v word="$1" -v y="$2" -v l="$3" -v r="$4" -v s="${SCALE}" -v tol="${ROW_TOLERANCE}" '
		NR > 1 && $12 != "" && index(tolower($12), tolower(word)) == 1 {
			x = ($7 + $9 / 2) / s; d = ($8 + $10 / 2) / s - y; if (d < 0) d = -d
			if (x >= l && x < r && d <= tol) found = 1
		}
		END { exit !found }'
}

self_test() {
	local bad=0 tsv
	expect() { # <0|1> <why> <command...>
		local want="$1" why="$2" got=0
		shift 2
		"$@" || got=1
		if [[ "${got}" == "${want}" ]]; then printf 'ok    %s\n' "${why}"; else
			printf 'FAIL  %s\n' "${why}"
			bad=1
		fi
	}
	expect 0 "names 0.7.0" names_version "Zeo 0.7.0" 0.7.0
	expect 0 "names 0.7.0 before the PF suffix" names_version "Zeo 0.7.0_p20261021" 0.7.0
	expect 0 "names 0.7.0 on a line of its own" names_version $'About\nZeo 0.7.0\nZed 1.27.0' 0.7.0
	expect 1 "refuses a trailing digit (0.7.01)" names_version "Zeo 0.7.01" 0.7.0
	expect 1 "refuses a trailing digit (0.7.00)" names_version "Zeo 0.7.00" 0.7.0
	expect 1 "refuses the previous release" names_version "Zeo 0.6.1" 0.7.0
	expect 1 "refuses any character for a dot" names_version "Zeo 0x7y0" 0.7.0
	expect 1 "refuses a leading digit (10.7.0)" names_version "Zeo 10.7.0" 0.7.0
	expect 1 "refuses a bare version without Zeo" names_version "Zed 0.7.0" 0.7.0
	tsv=$'level\tpage\tblock\tpar\tline\tword\tleft\ttop\twidth\theight\tconf\ttext\n'
	expect 0 "a chip on the row" row_has php 120 194 454 <<<"${tsv}"$'5\t1\t1\t1\t1\t1\t1200\t345\t60\t30\t90\tphp,'
	expect 0 "a chip read upper case" row_has php 120 194 454 <<<"${tsv}"$'5\t1\t1\t1\t1\t1\t1200\t345\t60\t30\t90\tPHP'
	expect 1 "a chip on the next row is not on this one" row_has php 120 194 454 <<<"${tsv}"$'5\t1\t1\t1\t1\t1\t1200\t420\t60\t30\t90\tphp'
	expect 1 "the word outside the sidebar is not a chip" row_has php 120 194 454 <<<"${tsv}"$'5\t1\t1\t1\t1\t1\t3000\t345\t60\t30\t90\tphp'
	expect 1 "another word with the same letters is not the chip" row_has php 120 194 454 <<<"${tsv}"$'5\t1\t1\t1\t1\t1\t1200\t345\t60\t30\t90\tphase'
	expect 1 "nothing boxed" row_has php 120 194 454 <<<"${tsv}"
	exit "${bad}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
BINARY="/usr/libexec/zeo-editor"
OUT=""
VERSION=""
while (($#)); do
	case "$1" in
	--self-test) self_test ;;
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--version) VERSION="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor: ${BINARY:-<empty>}"
[[ "$(realpath -- "${BINARY}")" != /usr/bin/zeo ]] ||
	die 2 "/usr/bin/zeo is the CLI launcher (it forwards to a running Zeo); pass /usr/libexec/zeo-editor"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 2 "--version must be X.Y.Z, got: ${VERSION:-<empty>}"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for step in rclick drag; do
	grep -q "\"${step}\"" "${HARNESS}" || die 2 "xvfb-proof.sh has no \"${step}\" step"
done
for tool in tesseract xdotool Xvfb sqlite3 jq python3 awk realpath sha256sum; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then MAGICK=(magick); elif command -v convert >/dev/null; then
	MAGICK=(convert)
else die 2 "missing tool: magick (ImageMagick)"; fi
python3 -c 'import PIL' 2>/dev/null || die 2 "missing python3 Pillow (the About crop)"

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
# Captures left by an earlier run would be read as this run's.
rm -f -- "${OUT}"/p[0-9]-*.png "${OUT}"/footer-*.png "${OUT}/README.md"
# /tmp, not TMPDIR: xvfb-proof.sh caps the workdir at 60 bytes (Unix socket paths).
STATE="$(mktemp -d /tmp/zp059-XXXX)"
PROFILE="${STATE}/zeo"
ALPHA="${STATE}/p/alpha"
mkdir -p -- "${ALPHA}"
printf 'alpha\n' >"${ALPHA}/README"
printf '{"use_system_path_prompts": false, "cursor_blink": false, "session": {"trust_all_worktrees": true}}\n' \
	>"${STATE}/settings.json"
printf 'binary: %s\nstate: %s\nout: %s\n' "${BINARY}" "${STATE}" "${OUT}"

# ── Verdicts, kept for the README ─────────────────────────────────────────
failed=0
RESULTS=()
verdict() { # <PASS|FAIL> <patch> <capture> <text>
	RESULTS+=("| $2 | $4 | **$1** | \`$3\` |")
	if [[ "$1" == PASS ]]; then printf 'ok    [%s] %s (%s)\n' "$2" "$4" "$3"; else
		printf 'FAIL  [%s] %s (%s)\n' "$2" "$4" "$3"
		failed=1
	fi
}

# ── Steps and the harness ─────────────────────────────────────────────────
steps() { # <phase> <JSON step objects...>
	local file="${STATE}/steps-$1.json"
	shift
	printf '%s\n' "$@" | jq -s '.' >"${file}" || die 2 "cannot write ${file}"
	printf '%s' "${file}"
}
at() { jq -cn --arg k "$1" --argjson x "$2" --argjson y "$3" '{($k): [$x, $y]}'; }
shot() { jq -cn --arg p "${OUT}/$1" '{shot: $p}'; }
typed() { jq -cn --arg t "$1" '{type: $t}'; }
AWAY="$(at move 960 540)"
# The steps are validated (--dry-run) first, so a refusal is this script's fault (exit 2) and an
# exit 1 during the run is Zeo or the input failing.
harness() { # <phase> <steps file>
	local status=0
	"${HARNESS}" --dry-run --steps "$2" >/dev/null || die 2 "xvfb-proof.sh refused the steps of phase $1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "${PROFILE}" \
		--steps "$2" || status=$?
	case "${status}" in
	0) ;;
	1)
		printf 'FAIL  phase %s: Zeo or the input failed during the run (exit 1 from the harness)\n' "$1"
		printf 'state kept for inspection: %s\n' "${STATE}"
		exit 1
		;;
	*) die 2 "xvfb-proof.sh failed on phase $1 (exit ${status})" ;;
	esac
}
# 037's tuned recipe for one project: workspace::Open, the path, then the threads sidebar. On a
# relaunch the project is restored and opening it again only activates it.
OPEN=('{"sleep": 15}' '{"chord": ["ctrl", "k"]}' '{"chord": ["ctrl", "o"]}' '{"sleep": 2}'
	'{"chord": ["ctrl", "a"]}' "$(typed "${ALPHA}/")" '{"sleep": 1}' '{"key": ["Return"]}'
	'{"sleep": 8}' '{"chord": ["ctrl", "alt", "semicolon"]}' '{"sleep": 3}')
# ── OCR: red channel (037: matched text is accent blue) and greyscale (041), each read twice,
# default and sparse (--psm 11, which alone read 039's tooltip). A phrase counts when any reading
# has it, so a "lacks" check only gets stricter. Both caches are filled in the main shell, never
# inside $(…) or <(…), so a tesseract failure exits 2 instead of passing for a missing feature.
declare -A OCR_CACHE=() TSV_CACHE=()
to_pgm() { # <png> <pgm> <red|grey> [crop]
	local args=()
	[[ -n "${4:-}" ]] && args=(-crop "$4" +repage)
	if [[ "$3" == red ]]; then args+=(-channel R -separate +channel); else args+=(-colorspace Gray); fi
	"${MAGICK[@]}" "$1" "${args[@]}" -resize "$((SCALE * 100))%" -threshold 70% -depth 8 "PGM:$2" ||
		die 2 "cannot convert $1 for tesseract"
}
load_ocr() { # <capture> [crop]
	local key="$1|${2:-}" pgm="${STATE}/ocr.pgm" mode psm text all=""
	[[ -z "${OCR_CACHE[${key}]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	for mode in red grey; do
		to_pgm "${OUT}/$1" "${pgm}" "${mode}" "${2:-}"
		for psm in 3 11; do
			text="$(tesseract "${pgm}" - --psm "${psm}" 2>/dev/null)" || die 2 "tesseract could not read $1"
			all+=" ||| ${text//$'\n'/ }"
		done
	done
	OCR_CACHE[${key}]="${all}"
}
reads() { # <capture> <text> [crop]
	local key="$1|${3:-}"
	load_ocr "$1" "${3:-}"
	[[ "${OCR_CACHE[${key}]}" == *"$2"* ]]
}
check_reads() { # <patch> <capture> <text> <why>
	if reads "$2" "$3"; then verdict PASS "$1" "$2" "reads \"$3\": $4"; else verdict FAIL "$1" "$2" "does not read \"$3\": $4"; fi
}
check_lacks() {
	if reads "$2" "$3"; then verdict FAIL "$1" "$2" "reads \"$3\": $4"; else verdict PASS "$1" "$2" "has no \"$3\": $4"; fi
}
load_tsv() { # <capture>: word boxes, red channel, 3x
	[[ -z "${TSV_CACHE[$1]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	to_pgm "${OUT}/$1" "${STATE}/box.pgm" red
	TSV_CACHE[$1]="$(tesseract "${STATE}/box.pgm" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
}

# The sidebar's box, measured once on p1-sidebar from its search field (036/038): from "Search"'s
# left edge minus 24 px to SIDEBAR_SPAN px right of it, below that row. The Lists view may not
# draw the field, so every later capture uses these numbers (one screen, one window).
SIDEBAR_SPAN=260
SB_LEFT="" SB_RIGHT="" SB_TOP=""
measure_sidebar() {
	load_tsv "$1"
	read -r SB_LEFT SB_RIGHT SB_TOP < <(awk -F '\t' -v s="${SCALE}" -v span="${SIDEBAR_SPAN}" '
		NR > 1 && $12 == "Search" { printf "%d %d %d\n", $7 / s - 24, $7 / s + span, ($8 + $10) / s; f = 1; exit }
		END { exit !f }' <<<"${TSV_CACHE[$1]}") || die 2 "the sidebar's search field was not boxed in $1"
	printf 'sidebar: x %s..%s, below y %s\n' "${SB_LEFT}" "${SB_RIGHT}" "${SB_TOP}"
}
# box <capture> <word> <sidebar|any> <top|bottom>: "left top width height" in screen pixels of the
# topmost (or bottommost) box reading exactly <word>; exit 1 when there is none. load_tsv first.
box() {
	awk -F '\t' -v word="$2" -v where="$3" -v pick="$4" -v s="${SCALE}" \
		-v l="${SB_LEFT:-0}" -v r="${SB_RIGHT:-0}" -v t="${SB_TOP:-0}" '
		NR > 1 && $12 == word {
			x = ($7 + $9 / 2) / s; y = ($8 + $10 / 2) / s
			if (where == "sidebar" && (x < l || x >= r || y <= t)) next
			if (!f || (pick == "top" && $8 < top) || (pick == "bottom" && $8 > top)) {
				left = $7; top = $8; width = $9; height = $10; f = 1
			}
		}
		END { if (!f) exit 1; printf "%d %d %d %d\n", left / s, top / s, width / s, height / s }' \
		<<<"${TSV_CACHE[$1]}"
}
# point <capture> <word> <sidebar|any> <top|bottom> <variable prefix>: sets <prefix>X and <prefix>Y
# to the box's centre, or exits 2 (a recipe problem, not a product one).
point() {
	local l t w h
	load_tsv "$1"
	read -r l t w h < <(box "$1" "$2" "$3" "$4") || die 2 "\"$2\" was not boxed in $1"
	printf -v "$5X" '%d' "$((l + w / 2))"
	printf -v "$5Y" '%d' "$((t + h / 2))"
}
in_sidebar() {
	load_tsv "$1"
	box "$1" "$2" sidebar top >/dev/null
}
check_in_sidebar() { # <patch> <capture> <word> <why>
	if in_sidebar "$2" "$3"; then verdict PASS "$1" "$2" "the sidebar shows $3: $4"; else verdict FAIL "$1" "$2" "the sidebar does not show $3: $4"; fi
}
check_not_in_sidebar() {
	if in_sidebar "$2" "$3"; then verdict FAIL "$1" "$2" "the sidebar still shows $3: $4"; else verdict PASS "$1" "$2" "the sidebar does not show $3: $4"; fi
}
# check_on_row <patch> <capture> <word> <row title> <expected: yes|no> <why>
check_on_row() {
	local on=no
	point "$2" "$4" sidebar top ROW_
	if row_has "$3" "${ROW_Y}" "${SB_LEFT}" "${SB_RIGHT}" <<<"${TSV_CACHE[$2]}"; then on=yes; fi
	if [[ "${on}" == "$5" ]]; then verdict PASS "$1" "$2" "\"$3\" on $4's row: ${on} ($6)"; else
		verdict FAIL "$1" "$2" "\"$3\" on $4's row: ${on}, want $5 ($6)"
	fi
}

# ── 0: first launch, then seed ────────────────────────────────────────────
harness 0 "$(steps 0 '{"sleep": 20}')"
has_table() { [[ "$(sqlite3 "$1" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$2'")" == 1 ]]; }
DB=""
while IFS= read -r -d '' candidate; do
	if has_table "${candidate}" sidebar_threads; then
		DB="${candidate}"
		break
	fi
done < <(find "${PROFILE}" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database under ${PROFILE} holds sidebar_threads: the editor did not start"
for table in thread_organization thread_tags tags; do
	has_table "${DB}" "${table}" || die 2 "${DB} has no ${table}: not a Zeo build (patch 0048 ships since 0.3.0)"
done
THREADS_DB="$(find "${PROFILE}" -path '*/threads/threads.db' -print -quit)"
[[ -n "${THREADS_DB}" ]] || die 2 "no threads/threads.db under ${PROFILE}: the native agent store was not created"
printf 'database: %s\nthreads: %s\n' "${DB}" "${THREADS_DB}"

APRICOT="59a1000000000000000000000000000a" BLUEBERRY="59a1000000000000000000000000000b"
MARMALADE="59a1000000000000000000000000000c" FORKLING="59a1000000000000000000000000000d"
TAG="php"
REPLY=(QUINCUNX ORBIT ZEPHYR)
t() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
# agent_id NULL is the native agent's id, so no agent server and no model turn are needed. One
# word per title, none equal to a reply word, a project label or the tag.
sqlite3 "${DB}" <<SQL || die 2 "seeding ${DB} failed"
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'${APRICOT}', 'p059-apricot', NULL, 'Apricot', '$(t '-1 hour')', '$(t '-1 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${BLUEBERRY}', 'p059-blueberry', NULL, 'Blueberry', '$(t '-2 hour')', '$(t '-2 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${MARMALADE}', 'p059-marmalade', NULL, 'Marmalade', '$(t '-3 hour')', '$(t '-3 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${FORKLING}', 'p059-forkling', NULL, 'Forkling', '$(t '-4 hour')', '$(t '-4 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0');
INSERT INTO tags (tag_key, display) VALUES ('${TAG}', '${TAG}');
INSERT INTO thread_tags (thread_id, tag_key) VALUES (X'${APRICOT}', '${TAG}');
INSERT INTO thread_organization (thread_id, parent_thread_id, fork_kind) VALUES (X'${FORKLING}', X'${MARMALADE}', 'clean');
SQL
# 036's lesson: sidebar_threads is only the index; opening a row reads the body from threads.db
# (DbThread 0.3.0 as plain JSON). Marmalade carries the reply whose words are selected in phase 3.
body() { # <session> <title> <user text> <agent text>
	jq -cn --arg id "$1" --arg title "$2" --arg user "$3" --arg agent "$4" --arg at "$(t '-3 hour')" '{
		version: "0.3.0", title: $title, updated_at: $at,
		messages: [{User: {id: ($id + "-1"), content: [{Text: $user}]}},
			{Agent: {content: [{Text: $agent}], tool_results: {}}}]}'
}
seed_body() { # <session> <title> <user text> <agent text>
	local json
	json="$(body "$@")"
	sqlite3 "${THREADS_DB}" "INSERT INTO threads (id, summary, updated_at, data_type, data, folder_paths, folder_paths_order, created_at)
		VALUES ('$1', '$2', '$(t '-3 hour')', 'json', CAST('${json}' AS BLOB), '${ALPHA}', '0', '$(t '-3 hour')')" ||
		die 2 "seeding $2's body into ${THREADS_DB} failed"
}
seed_body p059-marmalade Marmalade "Seeded question." "${REPLY[*]}"
seed_body p059-forkling Forkling "Seeded follow-up." "Seeded answer."

# ── 1: the thread list, then the footer scan (038) ────────────────────────
FOOTER_Y=1065
FOOTER_CROP="900x220+0+860"
scan=()
for ((x = 200; x <= 360; x += 8)); do
	scan+=("$(at move "${x}" "${FOOTER_Y}")" '{"sleep": 2}' "$(shot "footer-${x}.png")")
done
harness 1 "$(steps 1 "${OPEN[@]}" "$(shot p1-sidebar.png)" "${scan[@]}")"
[[ -s "${OUT}/p1-sidebar.png" ]] || die 1 "no p1-sidebar capture: the editor did not open a window"
verdict PASS window p1-sidebar.png "the released editor opened a window"
measure_sidebar p1-sidebar.png
for word in Apricot Blueberry Marmalade Forkling; do
	check_in_sidebar control p1-sidebar.png "${word}" "the seeded thread is listed"
done
check_on_row 0068 p1-sidebar.png "${TAG}" Apricot yes "the seeded tag shows as a chip"
check_on_row 0068 p1-sidebar.png "${TAG}" Blueberry no "control: the untagged row has no chip"
HOVER_X=""
first_hover() { # <tooltip>: sets HOVER_X to the first x whose capture reads it (main shell: OCR caches)
	local x
	HOVER_X=""
	for ((x = 200; x <= 360; x += 8)); do
		if reads "footer-${x}.png" "$1" "${FOOTER_CROP}"; then
			HOVER_X="${x}"
			return 0
		fi
	done
	return 1
}
first_hover "Thread History" ||
	die 2 "no footer capture showed History's tooltip: the scan missed the footer (tune FOOTER_Y)"
HX="${HOVER_X}"
verdict PASS control "footer-${HX}.png" "History's button is at ${HX},${FOOTER_Y}"
LX=""
if first_hover "Thread Lists"; then
	LX="${HOVER_X}"
	verdict PASS 0069 "footer-${LX}.png" "a footer button shows the \"Thread Lists\" tooltip, at ${LX},${FOOTER_Y}"
else
	verdict FAIL 0069 "footer-*.png" "no footer button shows a \"Thread Lists\" tooltip"
fi
for ((x = 200; x <= 360; x += 8)); do
	[[ "${x}" == "${HX}" || "${x}" == "${LX}" ]] || rm -f -- "${OUT}/footer-${x}.png"
done

# ── 2: the thread menu, the Lists view, the parent and its sub-thread ─────
point p1-sidebar.png Apricot sidebar top A
point p1-sidebar.png Marmalade sidebar top M
point p1-sidebar.png Forkling sidebar top F
lists=()
if [[ -n "${LX}" ]]; then
	lists=("$(at click "${LX}" "${FOOTER_Y}")" '{"sleep": 2}' "${AWAY}" '{"sleep": 1}' "$(shot p2-lists-view.png)")
	lists+=("$(at click "${LX}" "${FOOTER_Y}")" '{"sleep": 2}' "${AWAY}" '{"sleep": 1}' "$(shot p2-lists-back.png)")
fi
harness 2 "$(steps 2 "${OPEN[@]}" \
	"$(at rclick "${AX}" "${AY}")" '{"sleep": 2}' "$(shot p2-thread-menu.png)" '{"key": ["Escape"]}' '{"sleep": 1}' \
	"${lists[@]}" \
	"$(at click "${MX}" "${MY}")" '{"sleep": 4}' "${AWAY}" '{"sleep": 1}' "$(shot p2-parent.png)" \
	"$(at click "${FX}" "${FY}")" '{"sleep": 4}' "${AWAY}" '{"sleep": 1}' "$(shot p2-child.png)")"
check_reads control p2-thread-menu.png "Archive" "Apricot's context menu is open"
check_reads 0068 p2-thread-menu.png "Tags" "the thread menu offers Tags…"
check_reads 0069 p2-thread-menu.png "Move to List" "the thread menu offers Move to List"
if [[ -n "${LX}" ]]; then
	check_in_sidebar 0069 p2-lists-view.png New "the Lists view's empty state offers New List"
	check_not_in_sidebar 0069 p2-lists-view.png Apricot "the Lists view replaced the thread list"
	check_in_sidebar control p2-lists-back.png Apricot "a second click brings the thread list back"
fi
check_reads control p2-parent.png "${REPLY[0]}" "the parent opened with its seeded reply"
check_lacks control p2-parent.png "Sub-thread of" "the parent has no sub-thread header"
check_lacks control p2-parent.png "Send to Parent" "the parent's footer has no Send to Parent"
check_reads 0070 p2-child.png "Sub-thread of" "the linked thread is headed by its parent"
check_reads 0071 p2-child.png "Send to Parent" "the linked thread's footer offers Send to Parent"

# ── 3: the reply's menu without, then with, a selection (039); the About ──
load_tsv p2-parent.png
read -r L0 T0 _ _ < <(box p2-parent.png "${REPLY[0]}" any bottom) || die 2 "${REPLY[0]} not boxed in p2-parent"
read -r L2 T2 W2 _ < <(box p2-parent.png "${REPLY[2]}" any bottom) || die 2 "${REPLY[2]} not boxed in p2-parent"
point p2-parent.png "${REPLY[1]}" any bottom Q
printf 'reply: phrase from %s,%s to %s,%s; right-click at %s,%s\n' "${L0}" "${T0}" "$((L2 + W2))" "${T2}" "${QX}" "${QY}"
# The press must land on the first glyph: one in the padding left of it selects nothing (039).
SELECT="$(jq -cn --argjson a "$((L0 + 2))" --argjson b "$((T0 + 6))" --argjson c "$((L2 + W2 + 2))" \
	--argjson d "$((T2 + 6))" '{drag: [$a, $b, $c, $d]}')"
# The sidebar lists by recency: opening Marmalade and Forkling in phase 2 moved them up, and the
# relaunch keeps that order, so phase 1's point would land on Apricot (Red run, 2026-10-25).
# Marmalade is re-located in phase 2's last capture, inside the sidebar box.
point p2-child.png Marmalade sidebar top M3
printf 'phase 3: Marmalade at %s,%s (phase 1: %s,%s)\n' "${M3X}" "${M3Y}" "${MX}" "${MY}"
harness 3 "$(steps 3 "${OPEN[@]}" \
	"$(at click "${M3X}" "${M3Y}")" '{"sleep": 4}' "${AWAY}" '{"sleep": 1}' "$(shot p3-parent.png)" \
	"$(at rclick "${QX}" "${QY}")" '{"sleep": 2}' "$(shot p3-menu-no-selection.png)" '{"key": ["Escape"]}' '{"sleep": 1}' \
	"${SELECT}" '{"sleep": 1}' "$(at rclick "${QX}" "${QY}")" '{"sleep": 2}' "$(shot p3-menu-selection.png)" \
	'{"key": ["Escape"]}' '{"sleep": 1}' \
	'{"chord": ["ctrl", "shift", "p"]}' '{"sleep": 1}' "$(typed about)" '{"sleep": 1}' '{"key": ["Return"]}' '{"sleep": 3}' \
	"$(shot p3-about.png)")"
check_reads control p3-parent.png "${REPLY[1]}" "the parent reopened in the same layout"
check_reads control p3-menu-no-selection.png "Copy This Agent Response" "the reply's menu opened"
check_lacks control p3-menu-no-selection.png "sub-thread" "no sub-thread entry without a selection"
check_lacks control p3-menu-no-selection.png "Sub-thread" "no sub-thread entry without a selection"
check_reads 0070 p3-menu-selection.png "Clean sub-thread" "a selected phrase offers Clean sub-thread"

# The version, as 048 reads it: a centre crop of the About capture, 3x, as 8-bit PGM.
python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("L"); w, h = im.size
box = (w // 2 - 260, h // 2 - 280, w // 2 + 260, h // 2 + 120)
im.crop(box).resize(((box[2] - box[0]) * 3, (box[3] - box[1]) * 3)).save(sys.argv[2])' \
	"${OUT}/p3-about.png" "${STATE}/about.pgm" || die 2 "could not convert the About capture to PGM"
about="$(tesseract "${STATE}/about.pgm" - 2>/dev/null || true)"
if names_version "${about}" "${VERSION}"; then
	verdict PASS about p3-about.png "the About names Zeo ${VERSION}"
else
	verdict FAIL about p3-about.png "the About does not name Zeo ${VERSION}; OCR: ${about//$'\n'/ }"
fi

# ── The record ────────────────────────────────────────────────────────────
result="PASS — Zeo ${VERSION} opened, and a feature of each of 0068, 0069, 0070 and 0071 is present"
((failed == 0)) || result="FAILED — see the FAIL rows (exit 1)"
# The backticks below are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
{
	printf '# Zeo %s — release smoke of the installed build (story 059, task 7.3)\n\n' "${VERSION}"
	printf -- '- **Run:** %s, `zed-patches/scripts/proofs/059-release-smoke/run.sh --version %s`\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "${VERSION}"
	printf -- '- **Binary:** `%s`, sha256 `%s`\n' "${BINARY}" "$(sha256sum -- "${BINARY}" | cut -d' ' -f1)"
	if command -v qlist >/dev/null; then printf -- '- **Installed:** `%s`\n' "$(qlist -ICv app-editors/zeo 2>/dev/null | tr '\n' ' ')"; fi
	printf -- '- **Rung:** X11 on Xvfb (llvmpipe), no window manager, isolated `--user-data-dir` under `%s`, no model turn. Not covered: Wayland, GPU, a fork with context, delivery to the parent, the Agent Tasks panel item, the tag filter, filing into a list (037–040 live proofs).\n' "${STATE}"
	printf -- '- **Result:** %s\n\n| Patch | Check | Result | Capture |\n|---|---|---|---|\n' "${result}"
	printf '%s\n' "${RESULTS[@]}"
} >"${OUT}/README.md"
printf 'state kept for inspection: %s\nrecord: %s/README.md\nrun.sh: %s\n' "${STATE}" "${OUT}" "${result}"
exit "${failed}"
