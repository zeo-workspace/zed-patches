#!/usr/bin/env bash
# Story 073, task 8.3 — smoke proof of the released Zeo 0.8.0 on a private X display (E2E).
#
#     run.sh --version <X.Y.Z> --out <docs/assets/073-release-0.8.0> [--binary <zeo-editor>]
#     run.sh --self-test        (the pure matchers only: no display, no editor)
#
# What it proves (R8.4, Q9): the editor the operator emerged opens a window, its About names the
# released version exactly, and the visible features the 0.8.0 train adds are present, each
# against a negative control taken in the same run:
#   0073  ToDo: a new Claude Agent (Plus) thread's agent menu ("Toggle Agent Menu", opened with
#         `agent: toggle options menu`) holds "ToDo" under the "Current Thread" header, and the
#         composer row holds no "Plan updates" (controls: the menu is open — it reads
#         "MCP Servers"; the session's own options are drawn — "Ultracode" or "Fast mode");
#   0066  the Epico panel reads `.epico/`: project alpha holds `.epico/` (EPICO.md, stories 901
#         marmalade and 902 zeppelin) AND a stale `.epic/` (EPIC.md, story 901 tangerine — the
#         same number). The panel shows "Open EPICO.md" and marmalade and zeppelin, and neither
#         "Open EPIC.md" nor tangerine: the two corpora never merge (patch header: "with both
#         present ... that is the one read"). Control, in its own profile: project legacy, with
#         only `.epic/` (story 903 pumpernickel), shows "Open EPIC.md" and pumpernickel and no
#         "Open EPICO.md" — the fallback, which 0.7.1 also passes;
#   0002  the command palette offers "claude code ide: mention selection in claude code" for the
#         query "mention selection" (control: the palette is open, it echoes the query).
# No model turn is taken: opening a Claude Agent (Plus) thread starts the adapter's session (the
# isolated profile reaches ~/.claude for auth, as 2026-10-06's proofs did) and nothing is sent.
#
# How (the 059 recipe: an isolated --user-data-dir under a fresh mktemp dir, never the operator's
# profile or workspace; one xvfb-proof.sh run per phase, each validated with --dry-run first). The
# harness replays a fixed step script, so a point found in one phase's capture is used in the next:
#   warm-alpha   first launch of profile zeo (databases, first-run state), nothing driven
#   alpha-1      open alpha; `epic panel: toggle focus`; the palette on "mention selection";
#                `agent: toggle focus`; `agent: toggle new thread menu` (the "+" menu, captured)
#   alpha-2      relaunch: the "+" menu again, click "Claude Agent (Plus)" where alpha-1's capture
#                boxed it, wait for the session, capture the composer; `agent: toggle options
#                menu`, capture the agent menu
#   warm-legacy  first launch of profile zl
#   legacy       open legacy; `epic panel: toggle focus`; the About
# Every menu is opened by its palette action, never by a hard-coded button coordinate: the one
# point clicked is located by OCR in this run's own capture.
#
# Binary: the installed editor is /usr/libexec/zeo-editor (the harness's default). /usr/bin/zeo is
# the CLI launcher, which forwards to a running Zeo; it is refused.
#
# Red: deferred to Run mode. Against the installed 0.7.1 the About does not read "Zeo 0.8.0"; the
# alpha panel shows "Open EPIC.md" and tangerine instead of the .epico corpus; the palette has no
# mention action; the composer row shows "Plan updates" and the agent menu of a thread with no
# message has no "Current Thread" header — while every control passes: the run exits 1.
#
# Tuning: the measured layout is 2026-11-03's (docs/assets/todo-menu-epico-2026-11-03, 1920x1080,
# debug build): the "+" menu entry was at 655,161 and the placeholder "Message Claude Agent (Plus)"
# at y 88, hence PLUS_MIN_Y; the About crop is 048's. Tune on the release build if needed and
# record what changed in the README; never change a verdict.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland, GPU,
# a model turn, ToDo actually toggled (10-todo-toggled-off.png of 2026-11-03 covers it), the
# selection reaching a connected Claude Code CLI (066's live proof), native subagents (064).
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
# names_version <text> <X.Y.Z>: "Zeo X.Y.Z" not followed by a digit, dots literal, so 0.8.01,
# 0.8.00 and 0x8y0 never pass for 0.8.0.
names_version() {
	grep -qE "Zeo ${2//./\\.}([^0-9]|\$)" <<<"$1"
}
# epico_index <text>: the panel's index link for the renamed layout. "Open EPIC.md" (the legacy
# label) never counts; a zero for the O is the one OCR misreading accepted.
# shellcheck disable=SC2329 # called through check_seen
epico_index() {
	grep -qE 'Open EPIC[O0]\.md' <<<"$1"
}
# legacy_index <text>: the legacy label only — "EPIC" followed directly by ".md".
# shellcheck disable=SC2329 # called through check_seen
legacy_index() {
	grep -qE 'Open EPIC\.md' <<<"$1"
}
# offers_mention <text>: the palette entry, humanized ("claude code ide: mention selection in
# claude code") or title case; the query echo "mention selection" alone is not the entry.
# shellcheck disable=SC2329 # called through check_seen
offers_mention() {
	grep -qiE 'mention selection in claude code' <<<"$1"
}
# has_any <text> <phrase>...: any phrase as a substring (OCR may glue "Plan updates").
# shellcheck disable=SC2329 # called through check_seen
has_any() {
	local text="$1" phrase
	shift
	for phrase in "$@"; do
		[[ "${text}" == *"${phrase}"* ]] && return 0
	done
	return 1
}
# todo_under_header < tesseract TSV (3x): a "Current" box with a "Thread" box right after it on
# the same line (the menu header), and a box containing "ToDo" whose top is 9..40 px below the
# header's and whose left edge is within 60 px of it. A ToDo anywhere else on the screen (a
# composer-row toggle, a second line far away) is not the menu entry under that header.
todo_under_header() {
	awk -F '\t' -v s="${SCALE}" '
		NR > 1 && $12 != "" { n++; text[n] = $12; left[n] = $7 / s; top[n] = $8 / s; width[n] = $9 / s }
		END {
			for (i = 1; i <= n; i++) {
				if (text[i] != "Current") continue
				for (j = 1; j <= n; j++) {
					if (text[j] != "Thread") continue
					dy = top[j] - top[i]; if (dy < 0) dy = -dy
					gap = left[j] - (left[i] + width[i])
					if (dy <= 4 && gap >= 0 && gap <= 20) { h++; hx[h] = left[i]; hy[h] = top[i] }
				}
			}
			for (k = 1; k <= h; k++) {
				for (i = 1; i <= n; i++) {
					if (!index(text[i], "ToDo")) continue
					d = top[i] - hy[k]; dx = left[i] - hx[k]; if (dx < 0) dx = -dx
					if (d > 8 && d <= 40 && dx <= 60) found = 1
				}
			}
			exit !found
		}'
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
	# The About: hostile spellings first, then the ones that denote 0.8.0.
	expect 1 "refuses a trailing digit (0.8.01)" names_version "Zeo 0.8.01" 0.8.0
	expect 1 "refuses a trailing digit (0.8.00)" names_version "Zeo 0.8.00" 0.8.0
	expect 1 "refuses the previous release (0.7.1)" names_version "Zeo 0.7.1" 0.8.0
	expect 1 "refuses any character for a dot" names_version "Zeo 0x8y0" 0.8.0
	expect 1 "refuses a leading digit (10.8.0)" names_version "Zeo 10.8.0" 0.8.0
	expect 1 "refuses a bare version without Zeo" names_version "Zed 0.8.0" 0.8.0
	expect 0 "names 0.8.0 before the PF suffix" names_version "Zeo 0.8.0_p20261101" 0.8.0
	expect 0 "names 0.8.0 on a line of its own" names_version $'About\nZeo 0.8.0\nZed 1.27.0' 0.8.0
	expect 0 "names 0.8.0" names_version "Zeo 0.8.0" 0.8.0
	# The index link: the two layouts must never pass for each other, in either direction.
	expect 1 "the legacy label is not the .epico index" epico_index "Open EPIC.md"
	expect 1 "the .epico label is not the legacy index" legacy_index "Open EPICO.md"
	expect 1 "the .epico label read with a zero is not the legacy index" legacy_index "Open EPIC0.md"
	expect 0 "the .epico label read with a zero is still the .epico index" epico_index "Open EPIC0.md"
	expect 0 "the .epico index" epico_index "x ||| Open EPICO.md 901 marmalade"
	expect 0 "the legacy index" legacy_index "x ||| Open EPIC.md 903 pumpernickel"
	# The palette entry: the query echo and near entries are not it.
	expect 1 "the query echo alone is not the entry" offers_mention "> mention selection"
	expect 1 "a truncated entry is not the entry" offers_mention "claude code ide: mention selection in claude"
	expect 1 "another selection action is not the entry" offers_mention "agent: add selection to thread"
	expect 0 "the humanized entry" offers_mention "mention selection ||| claude code ide: mention selection in claude code"
	expect 0 "the entry in title case" offers_mention "Mention Selection in Claude Code"
	# Plan updates: a glued reading still counts as present, so a "lacks" only gets stricter.
	expect 1 "the composer's other options are not Plan updates" has_any "Ultracode Fast mode" "Plan updates" "Planupdates"
	expect 0 "a glued reading is Plan updates" has_any "Ultracode Planupdates" "Plan updates" "Planupdates"
	expect 0 "Plan updates" has_any "Ultracode Plan updates" "Plan updates" "Planupdates"
	# ToDo under the header (2026-11-03's 09-agent-menu-todo.png boxes, 3x: Current 580,73;
	# Thread 623,72; ToDo 599,97). Hostile placements first.
	tsv=$'level\tpage\tblock\tpar\tline\tword\tleft\ttop\twidth\theight\tconf\ttext\n'
	local cur=$'5\t1\t1\t1\t1\t1\t1740\t219\t119\t24\t90\tCurrent\n'
	local thr=$'5\t1\t1\t1\t1\t2\t1869\t216\t111\t27\t90\tThread\n'
	expect 1 "a ToDo in the composer row is not under the header" todo_under_header <<<"${tsv}${cur}${thr}"$'5\t1\t2\t1\t1\t1\t1836\t2900\t95\t32\t90\tToDo'
	expect 1 "a ToDo with no header is not the menu entry" todo_under_header <<<"${tsv}"$'5\t1\t2\t1\t1\t1\t1797\t290\t95\t32\t90\tToDo'
	expect 1 "\"Current\" alone is not the header" todo_under_header <<<"${tsv}${cur}"$'5\t1\t2\t1\t1\t1\t1797\t290\t95\t32\t90\tToDo'
	expect 1 "\"Current\" and a far \"Thread\" are not the header" todo_under_header <<<"${tsv}${cur}"$'5\t1\t1\t1\t1\t2\t3000\t216\t111\t27\t90\tThread\n5\t1\t2\t1\t1\t1\t1797\t290\t95\t32\t90\tToDo'
	expect 1 "a ToDo above the header is not under it" todo_under_header <<<"${tsv}${cur}${thr}"$'5\t1\t2\t1\t1\t1\t1797\t150\t95\t32\t90\tToDo'
	expect 1 "a ToDo far to the right is not under it" todo_under_header <<<"${tsv}${cur}${thr}"$'5\t1\t2\t1\t1\t1\t4500\t290\t95\t32\t90\tToDo'
	expect 1 "another entry under the header is not ToDo" todo_under_header <<<"${tsv}${cur}${thr}"$'5\t1\t2\t1\t1\t1\t1797\t290\t95\t32\t90\tRegenerate'
	expect 0 "a ToDo read with its check mark glued on" todo_under_header <<<"${tsv}${cur}${thr}"$'5\t1\t2\t1\t1\t1\t1760\t290\t130\t32\t90\tvToDo'
	expect 0 "a ToDo under the header" todo_under_header <<<"${tsv}${cur}${thr}"$'5\t1\t2\t1\t1\t1\t1797\t290\t95\t32\t90\tToDo'
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
grep -q '"chord"' "${HARNESS}" || die 2 "xvfb-proof.sh has no \"chord\" step"
for tool in tesseract xdotool Xvfb jq python3 awk realpath sha256sum; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then MAGICK=(magick); elif command -v convert >/dev/null; then
	MAGICK=(convert)
else die 2 "missing tool: magick (ImageMagick)"; fi
python3 -c 'import PIL' 2>/dev/null || die 2 "missing python3 Pillow (the About crop)"

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
# Captures left by an earlier run would be read as this run's.
rm -f -- "${OUT}"/p[0-9L]-*.png "${OUT}/README.md"
# /tmp, not TMPDIR: xvfb-proof.sh caps the workdir at 60 bytes (Unix socket paths).
STATE="$(mktemp -d /tmp/zp073-XXXX)"
PROFILE="${STATE}/zeo"
PROFILE_L="${STATE}/zl"
ALPHA="${STATE}/p/alpha"
LEGACY="${STATE}/p/legacy"
printf '{"use_system_path_prompts": false, "cursor_blink": false, "session": {"trust_all_worktrees": true}, "telemetry": {"diagnostics": false, "metrics": false}}\n' \
	>"${STATE}/settings.json"

# ── The scratch corpora: one word per slug, none equal to a project name or a UI label ──
story() { # <area dir> <NNN-slug> <status>
	local dir="$1/$2" slug="${2#*-}"
	mkdir -p -- "${dir}"
	printf -- '---\nstory: %s\ntype: feature\nscale: standard\nstatus: %s\n---\n\n# Story - %s\n' \
		"${slug}" "$3" "${slug}" >"${dir}/story.md"
	printf '# Implementation Plan - %s\n\n## Task List\n\n- [x] 1 - First\n- [ ] 2 - Second\n' \
		"${slug}" >"${dir}/tasks.md"
}
mkdir -p -- "${ALPHA}/.epico/stories" "${ALPHA}/.epic/stories" "${LEGACY}/.epic/stories"
printf 'alpha\n' >"${ALPHA}/README"
printf 'legacy\n' >"${LEGACY}/README"
printf '# Epico\n\n<!-- epico:index:start -->\n<!-- epico:index:end -->\n' >"${ALPHA}/.epico/EPICO.md"
story "${ALPHA}/.epico/stories" 901-marmalade draft
story "${ALPHA}/.epico/stories" 902-zeppelin open
# The decoy: a stale .epic/ beside .epico/, with the SAME story number as an .epico story.
printf '# Epic\n\n<!-- epic:index:start -->\n<!-- epic:index:end -->\n' >"${ALPHA}/.epic/EPIC.md"
story "${ALPHA}/.epic/stories" 901-tangerine draft
printf '# Epic\n\n<!-- epic:index:start -->\n<!-- epic:index:end -->\n' >"${LEGACY}/.epic/EPIC.md"
story "${LEGACY}/.epic/stories" 903-pumpernickel draft
printf 'binary: %s\nstate: %s\nout: %s\n' "${BINARY}" "${STATE}" "${OUT}"

# ── Verdicts, kept for the README ─────────────────────────────────────────
failed=0
RESULTS=()
verdict() { # <PASS|FAIL> <area> <capture> <text>
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
pause() { jq -cn --argjson s "$1" '{sleep: $s}'; }
# Inside the window (x 194..1730): with no window manager the keyboard follows the pointer.
AWAY="$(at move 960 540)"
ESC=('{"key": ["Escape"]}' '{"sleep": 1}')
# add_palette <array> <query> <seconds after Return>: run a command palette action.
add_palette() {
	local -n into="$1"
	into+=('{"chord": ["ctrl", "shift", "p"]}' '{"sleep": 1}' "$(typed "$2")" '{"sleep": 1}'
	'{"key": ["Return"]}' "$(pause "$3")")
}
# 059's recipe for opening a folder: workspace::Open, the prefilled path replaced, Return.
add_open() { # <array> <folder>
	# shellcheck disable=SC2178 # a nameref to the caller's array, as in add_palette
	local -n into="$1"
	into+=('{"sleep": 15}' '{"chord": ["ctrl", "k"]}' '{"chord": ["ctrl", "o"]}' '{"sleep": 2}'
		'{"chord": ["ctrl", "a"]}' "$(typed "$2/")" '{"sleep": 1}' '{"key": ["Return"]}' '{"sleep": 8}')
}
# The steps are validated (--dry-run) first, so a refusal is this script's fault (exit 2) and an
# exit 1 during the run is Zeo or the input failing.
harness() { # <phase> <steps file> <profile>
	local status=0
	"${HARNESS}" --dry-run --steps "$2" >/dev/null || die 2 "xvfb-proof.sh refused the steps of phase $1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" --keep "$3" \
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

# ── OCR: 059's — red channel and greyscale, each read default and sparse (--psm 11). A phrase
# counts when any reading has it, so a "lacks" check only gets stricter. Both caches are filled in
# the main shell, never inside $(…) or <(…), so a tesseract failure exits 2 instead of passing
# for a missing feature.
declare -A OCR_CACHE=() TSV_CACHE=()
to_pgm() { # <png> <pgm> <red|grey> [crop]
	local args=()
	[[ -n "${4:-}" ]] && args=(-crop "$4" +repage)
	if [[ "$3" == red ]]; then args+=(-channel R -separate +channel); else args+=(-colorspace Gray); fi
	"${MAGICK[@]}" "$1" "${args[@]}" -resize "$((SCALE * 100))%" -threshold 70% -depth 8 "PGM:$2" ||
		die 2 "cannot convert $1 for tesseract"
}
load_ocr() { # <capture>
	local pgm="${STATE}/ocr.pgm" mode psm text all=""
	[[ -z "${OCR_CACHE[$1]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	for mode in red grey; do
		to_pgm "${OUT}/$1" "${pgm}" "${mode}"
		for psm in 3 11; do
			text="$(tesseract "${pgm}" - --psm "${psm}" 2>/dev/null)" || die 2 "tesseract could not read $1"
			all+=" ||| ${text//$'\n'/ }"
		done
	done
	OCR_CACHE[$1]="${all}"
}
load_tsv() { # <capture>: word boxes, red channel, 3x
	[[ -z "${TSV_CACHE[$1]+set}" ]] || return 0
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	to_pgm "${OUT}/$1" "${STATE}/box.pgm" red
	TSV_CACHE[$1]="$(tesseract "${STATE}/box.pgm" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
}
# check_seen <area> <capture> <yes|no> <what> <matcher> [args...]: the matcher run on the
# capture's OCR text (inserted as its first argument) must answer <yes|no>.
check_seen() {
	local area="$1" capture="$2" want="$3" what="$4" matcher="$5" got=no
	shift 5
	load_ocr "${capture}"
	if "${matcher}" "${OCR_CACHE[${capture}]}" "$@"; then got=yes; fi
	if [[ "${got}" == "${want}" ]]; then verdict PASS "${area}" "${capture}" "${what}: ${got}"; else
		verdict FAIL "${area}" "${capture}" "${what}: ${got}, want ${want}"
	fi
}
# A menu entry's centre: the topmost box starting with <prefix> whose centre is below <min y>.
PLUS_MIN_Y=100
menu_point() { # <capture> <prefix> <min y> <variable prefix>; exits 2 when there is none
	local x y
	load_tsv "$1"
	read -r x y < <(awk -F '\t' -v word="$2" -v miny="$3" -v s="${SCALE}" '
		NR > 1 && $12 != "" && index($12, word) == 1 {
			cx = ($7 + $9 / 2) / s; cy = ($8 + $10 / 2) / s
			if (cy > miny && (!f || cy < by)) { bx = cx; by = cy; f = 1 }
		}
		END { if (!f) exit 1; printf "%d %d\n", bx, by }' <<<"${TSV_CACHE[$1]}") ||
		die 2 "\"$2\" was not boxed below y $3 in $1: the menu did not open (tune the recipe)"
	printf -v "$4X" '%d' "${x}"
	printf -v "$4Y" '%d' "${y}"
}

# ── warm-alpha: first launch of profile zeo ───────────────────────────────
harness warm-alpha "$(steps warm-alpha '{"sleep": 20}')" "${PROFILE}"

# ── alpha-1: the Epico panel, the palette, the "+" menu ───────────────────
a1=()
add_open a1 "${ALPHA}"
a1+=("$(shot p1-project.png)")
add_palette a1 "epic panel: toggle focus" 4
a1+=("${AWAY}" '{"sleep": 1}' "$(shot p1-epico-panel.png)")
a1+=('{"chord": ["ctrl", "shift", "p"]}' '{"sleep": 1}' "$(typed "mention selection")" '{"sleep": 2}'
"$(shot p1-palette.png)" "${ESC[@]}")
add_palette a1 "agent: toggle focus" 5
a1+=("$(shot p1-agent-panel.png)")
add_palette a1 "agent: toggle new thread menu" 2
a1+=("$(shot p1-new-menu.png)" "${ESC[@]}")
harness alpha-1 "$(steps alpha-1 "${a1[@]}")" "${PROFILE}"
[[ -s "${OUT}/p1-project.png" ]] || die 1 "no p1-project capture: the editor did not open a window"
verdict PASS window p1-project.png "the released editor opened a window"

check_seen 0066 p1-epico-panel.png yes 'the panel links the .epico index ("Open EPICO.md")' epico_index
check_seen 0066 p1-epico-panel.png yes "the .epico story 901 marmalade is listed" has_any marmalade
check_seen 0066 p1-epico-panel.png yes "the .epico story 902 zeppelin is listed" has_any zeppelin
check_seen 0066 p1-epico-panel.png no 'the stale .epic/ beside .epico/ is linked ("Open EPIC.md")' legacy_index
check_seen 0066 p1-epico-panel.png no "the stale .epic/ story 901 tangerine (same number) is listed" has_any tangerine

check_seen control p1-palette.png yes 'the palette is open and echoes "mention selection"' has_any "mention selection"
check_seen 0002 p1-palette.png yes 'the palette offers "mention selection in claude code"' offers_mention

menu_point p1-new-menu.png "(Plus" "${PLUS_MIN_Y}" PLUS_
verdict PASS control p1-new-menu.png "the new-thread menu offers Claude Agent (Plus), at ${PLUS_X},${PLUS_Y}"

# ── alpha-2: a new Claude Agent (Plus) thread, its composer and agent menu ──
a2=()
add_open a2 "${ALPHA}"
add_palette a2 "agent: toggle new thread menu" 2
a2+=("$(shot p2-new-menu.png)" "$(at click "${PLUS_X}" "${PLUS_Y}")" '{"sleep": 25}' "${AWAY}"
'{"sleep": 1}' "$(shot p2-plus-thread.png)")
add_palette a2 "agent: toggle options menu" 2
a2+=("$(shot p2-agent-menu.png)" "${ESC[@]}")
harness alpha-2 "$(steps alpha-2 "${a2[@]}")" "${PROFILE}"

check_seen control p2-plus-thread.png yes "the new thread runs on Claude Agent (Plus)" has_any "Claude Agent (Plus)"
check_seen control p2-plus-thread.png yes 'the session'"'"'s options are drawn ("Ultracode" or "Fast mode")' \
	has_any Ultracode "Fast mode" Fastmode
check_seen 0073 p2-plus-thread.png no 'the composer row shows "Plan updates"' has_any "Plan updates" Planupdates
check_seen control p2-agent-menu.png yes 'the agent menu is open ("MCP Servers")' has_any "MCP Servers"
MENU=p2-agent-menu.png
load_tsv "${MENU}"
if todo_under_header <<<"${TSV_CACHE[${MENU}]}"; then
	verdict PASS 0073 p2-agent-menu.png '"ToDo" sits under the agent menu'"'"'s "Current Thread" header'
else
	verdict FAIL 0073 p2-agent-menu.png 'no "ToDo" under a "Current Thread" header in the agent menu'
fi

# ── warm-legacy and legacy: the .epic/ fallback in its own profile; the About ──
harness warm-legacy "$(steps warm-legacy '{"sleep": 20}')" "${PROFILE_L}"
lg=()
add_open lg "${LEGACY}"
add_palette lg "epic panel: toggle focus" 4
lg+=("${AWAY}" '{"sleep": 1}' "$(shot pL-epic-panel.png)")
add_palette lg about 3
lg+=("$(shot pL-about.png)")
harness legacy "$(steps legacy "${lg[@]}")" "${PROFILE_L}"

check_seen control pL-epic-panel.png yes 'a project with only .epic/ links its index ("Open EPIC.md"; 0066'"'"'s fallback)' legacy_index
check_seen control pL-epic-panel.png yes "its story 903 pumpernickel is listed" has_any pumpernickel
check_seen control pL-epic-panel.png no 'it is labelled as .epico ("Open EPICO.md")' epico_index

# The version, as 048 reads it: a centre crop of the About capture, 3x, as 8-bit PGM.
python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("L"); w, h = im.size
box = (w // 2 - 260, h // 2 - 280, w // 2 + 260, h // 2 + 120)
im.crop(box).resize(((box[2] - box[0]) * 3, (box[3] - box[1]) * 3)).save(sys.argv[2])' \
	"${OUT}/pL-about.png" "${STATE}/about.pgm" || die 2 "could not convert the About capture to PGM"
about="$(tesseract "${STATE}/about.pgm" - 2>/dev/null || true)"
if names_version "${about}" "${VERSION}"; then
	verdict PASS about pL-about.png "the About names Zeo ${VERSION}"
else
	verdict FAIL about pL-about.png "the About does not name Zeo ${VERSION}; OCR: ${about//$'\n'/ }"
fi

# ── The record ────────────────────────────────────────────────────────────
result="PASS — Zeo ${VERSION} opened, with 0073's ToDo, 0066's .epico panel and 0002's palette entry"
((failed == 0)) || result="FAILED — see the FAIL rows (exit 1)"
# The backticks below are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
{
	printf '# Zeo %s — release smoke of the installed build (story 073, task 8.3)\n\n' "${VERSION}"
	printf -- '- **Run:** %s, `zed-patches/scripts/proofs/073-release-smoke/run.sh --version %s`\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "${VERSION}"
	printf -- '- **Binary:** `%s`, sha256 `%s`\n' "${BINARY}" "$(sha256sum -- "${BINARY}" | cut -d' ' -f1)"
	if command -v qlist >/dev/null; then printf -- '- **Installed:** `%s`\n' "$(qlist -ICv app-editors/zeo 2>/dev/null | tr '\n' ' ')"; fi
	printf -- '- **Rung:** X11 on Xvfb (llvmpipe), no window manager, isolated `--user-data-dir` profiles and scratch projects under `%s`, no model turn. Not covered: Wayland, GPU, ToDo toggled (2026-11-03 proof), a mention reaching a connected CLI (066 live proof), native subagents (064).\n' "${STATE}"
	printf -- '- **Result:** %s\n\n| Area | Check | Result | Capture |\n|---|---|---|---|\n' "${result}"
	printf '%s\n' "${RESULTS[@]}"
} >"${OUT}/README.md"
printf 'state kept for inspection: %s\nrecord: %s/README.md\nrun.sh: %s\n' "${STATE}" "${OUT}" "${result}"
exit "${failed}"
