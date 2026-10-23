#!/usr/bin/env bash
# Story 039, task 8.1 — both sub-threads from a selection in a real agent reply, on a real Zeo
# window, off-desktop (E2E).
#
#     run.sh --out <docs/assets/039-live-proof-DATE> [--binary <zeo-editor>] [--adapter <index.js>]
#
# What it proves (R1.1, R1.2, R1.4, R2.2, R3.2, R4.1, R4.2, R4.4/R4.5, R5.1, R5.4; Q11, Q12),
# each verdict against a negative control from the same run:
#   c1  right-click on the reply with NO selection: the menu opens ("Copy This Agent Response")
#       and offers no sub-thread entry                                    (control, R1.4)
#   c2  the same right-click on a drag-selected phrase: both entries      (R1.1, R1.2)
#   c3  "Sub-thread with context": a new thread whose header names the parent and whose band says
#       "Inherited 2 messages", the phrase in its composer; the store holds the with_context link
#       to the parent                                                    (R3.2, R4.1, R4.4)
#   c4  after a restart the header is back and the band reads "Inherited the conversation" (the
#       count lives in memory only, design.md)                            (R4.5, R5.4)
#   c5  the header's parent title opens the parent; hovering the sub-thread's sidebar row marker
#       shows "Sub-thread of Marmalade"; the parent's own row shows none (control)  (R4.2, R5.1)
#   c6  "Clean sub-thread": a new draft holding the phrase, nothing sent (its row has no session)
#       and no clean link stored                                         (R2.2, R2.3)
#
# How (036's recipe): one --keep directory (an isolated --user-data-dir under a fresh mktemp dir,
# never the operator's profile) and one xvfb-proof.sh run per phase. The harness replays a fixed
# step script, so a point cannot be read and used in the same run: a phase captures, tesseract's
# TSV boxes locate what to point at, and the next phase relaunches into the same layout and points
# there. Titles are set in the database between phases (Zeo is not running then): the parent is
# "Marmalade", the fork "Forkling" — one word each, unique on screen, so OCR can box them.
# The reply is asked to be exactly "MARMALADE QUINCUNX ORBIT": UPPER case, so a reply word is
# never confused with the parent's title in the sidebar (word matches are case-sensitive).
#
# Cost: ONE model turn (the parent's). The forks send nothing.
#
# Red: on a build without the story the preflight finds no "Sub-thread with context" string in the
# binary and exits 1 before launching anything; with the string but no working hook, c2 fails.
#
# Tuning (Run mode, task 8.1, dev-039 91db5f5, 2026-10-23): coordinates come from OCR; the sleeps,
# MARKER_DX and the focus chord held as authored. Tuned, no check changed: centre_of ends its line
# (an unterminated `read` is exit 1 under set -e); phase 0 opens the threads sidebar
# (OPEN_SIDEBAR) before p0, since the marker lives there and the later phases reuse p0's points;
# box picks the bottommost reply word and the leftmost sidebar row; the drag starts on the first
# glyph; phase 4 opens the parent from its sidebar row; ocr adds a sparse-text reading.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager; the adapter talks to the
# real API with the operator's own Claude login. Not covered: Wayland, GPU, keyboard-only menu
# navigation (Q12 is the upstream menu's; not re-proved here).
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, no
# reply from the model, a capture could not be read or located).

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
ADAPTER="/usr/lib/node_modules/claude-agent-acp-plus/dist/index.js"
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
[[ -n "${ADAPTER}" && -f "${ADAPTER}" ]] || die 2 "--adapter must name the adapter's dist/index.js"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
grep -q '"rclick"' "${HARNESS}" || die 2 "xvfb-proof.sh has no rclick step"
grep -q '"drag"' "${HARNESS}" || die 2 "xvfb-proof.sh has no drag step"
for tool in sqlite3 tesseract xdotool Xvfb awk jq node; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then
	MAGICK=(magick)
elif command -v convert >/dev/null; then
	MAGICK=(convert)
else
	die 2 "missing tool: magick (ImageMagick)"
fi

# Preflight, before anything starts: a build without the story carries neither entry's label.
if ! grep -aqF 'Sub-thread with context' "${BINARY}"; then
	printf 'FAIL  %s has no "Sub-thread with context" entry: not a build carrying story 039\n' \
		"${BINARY}"
	exit 1
fi

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp039-XXXX")"
PROFILE="${STATE}/zeo"
PROJECT="${STATE}/project"
mkdir -p -- "${PROJECT}"
printf 'proof\n' >"${PROJECT}/README"
jq -n --arg node "$(command -v node)" --arg adapter "${ADAPTER}" '{
  use_system_path_prompts: false,
  use_system_prompts: false,
  session: { trust_all_worktrees: true },
  agent: { dock: "left", default_width: 900.0 },
  agent_servers: { "Claude Agent (Plus)": { type: "custom", command: $node, args: [$adapter] } }
}' >"${STATE}/settings.json"
cat >"${STATE}/keymap.json" <<'JSON'
[{"context": "Workspace", "bindings": {
  "ctrl-alt-j": ["agent::NewExternalAgentThread", {"agent": "Claude Agent (Plus)"}]}}]
JSON
printf 'binary: %s\nadapter: %s\nprofile: %s\n' "${BINARY}" "${ADAPTER}" "${PROFILE}"

PROMPT='Reply with exactly this line and nothing else: MARMALADE QUINCUNX ORBIT'
MARKER_DX=14

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

steps() { # $1 = phase, rest = JSON step objects
	local file="${STATE}/steps-$1.json"
	shift
	printf '%s\n' "$@" | jq -s '.' >"${file}"
	printf '%s' "${file}"
}
at() { # $1 = click|rclick|move, $2 = x, $3 = y
	jq -cn --arg k "$1" --argjson x "$2" --argjson y "$3" '{($k): [$x, $y]}'
}
drag() { # x1 y1 x2 y2
	jq -cn --argjson a "$1" --argjson b "$2" --argjson c "$3" --argjson d "$4" '{drag: [$a, $b, $c, $d]}'
}
shot() {
	jq -cn --arg p "${OUT}/$1" '{shot: $p}'
}

# The steps are validated (--dry-run) first, so a refusal is the script's fault (exit 2) and an
# exit 1 during the run is Zeo or the input failing.
harness() { # $1 = phase, $2 = steps file
	local status=0
	"${HARNESS}" --dry-run --steps "$2" >/dev/null || die 2 "xvfb-proof.sh refused phase $1"
	"${HARNESS}" --binary "${BINARY}" --settings "${STATE}/settings.json" \
		--keymap "${STATE}/keymap.json" --keep "${PROFILE}" --steps "$2" || status=$?
	case "${status}" in
	0) ;;
	1)
		fail "phase $1: Zeo or the input failed during the run (exit 1 from the harness)"
		stop_if_failed "$1"
		;;
	*) die 2 "xvfb-proof.sh failed on phase $1 (exit ${status})" ;;
	esac
}

# ── OCR (036's recipe: blue channel, 3x, threshold, PNM — this host's Leptonica reads no PNG) ──
SCALE=3
to_pnm() {
	"${MAGICK[@]}" "$1" -channel B -separate +channel -resize "$((SCALE * 100))%" -threshold 70% \
		-depth 8 "PGM:$2" || die 2 "cannot convert $1 for tesseract"
}
# Two readings, joined by a separator no phrase contains: the default page segmentation, and
# sparse text (--psm 11), which alone found the marker's tooltip over the sidebar on dev-039. A
# phrase counts as read when either reading has it, so a check_lacks gets stricter, never looser.
ocr() {
	local pnm="${STATE}/ocr.pnm" text sparse
	[[ -s "${OUT}/$1" ]] || die 2 "capture missing: $1"
	to_pnm "${OUT}/$1" "${pnm}"
	text="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read $1"
	sparse="$(tesseract "${pnm}" - --psm 11 2>/dev/null)" || die 2 "tesseract could not read $1 (sparse)"
	printf '%s ||| %s' "$(tr '\n' ' ' <<<"${text}")" "$(tr '\n' ' ' <<<"${sparse}")"
}
reads() { [[ "$(ocr "$1")" == *"$2"* ]]; }
check_reads() {
	if reads "$1" "$2"; then ok "$1 reads \"$2\" ($3)"; else fail "$1 does not read \"$2\" ($3)"; fi
}
check_lacks() {
	if reads "$1" "$2"; then fail "$1 reads \"$2\" ($3)"; else ok "$1 has no \"$2\" ($3)"; fi
}
# box <capture> <word> [top|bottom|left] -> "left top width height" of the box reading exactly
# <word> (case-sensitive), in screen pixels: the topmost by default. Tuned on dev-039: the same
# word is on screen more than once — the reply's words also sit in the echoed prompt and the
# auto-generated title (so the reply is the bottommost), and a title sits both in the panel and in
# the threads sidebar (whose rows are the leftmost).
box() {
	local pnm="${STATE}/box.pnm" tsv
	to_pnm "${OUT}/$1" "${pnm}"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	awk -F '\t' -v word="$2" -v s="${SCALE}" -v pick="${3:-top}" '
		NR > 1 && $12 == word && (!found || (pick == "top" && $8 < top) ||
			(pick == "bottom" && $8 > top) || (pick == "left" && $7 < left)) {
			left = $7; top = $8; width = $9; height = $10; found = 1
		}
		END {
			if (!found) exit 1
			printf "%d %d %d %d\n", left / s, top / s, width / s, height / s
		}' <<<"${tsv}"
}
centre_of() { # <capture> <word> [top|bottom|left] -> "x y"
	local l t w hh
	read -r l t w hh < <(box "$1" "$2" "${3:-top}") || die 2 "\"$2\" was not boxed in $1"
	# The newline matters: `read` returns 1 at an unterminated line, which set -e turns into exit 1.
	printf '%d %d\n' "$((l + w / 2))" "$((t + hh / 2))"
}

# ── The database ───────────────────────────────────────────────────────────
DB=""
find_db() {
	local candidate
	while IFS= read -r -d '' candidate; do
		if [[ "$(sqlite3 "${candidate}" "SELECT count(*) FROM sqlite_master WHERE name = 'thread_organization'")" == 1 ]]; then
			DB="${candidate}"
			return
		fi
	done < <(find "${PROFILE}" -path '*/db/*' -name 'db.sqlite' -print0)
	die 2 "no database under ${PROFILE} holds thread_organization: not a build with patch 0048"
}
q() { sqlite3 "${DB}" "$1"; }

OPEN_PROJECT=(
	'{"sleep": 12}'
	'{"chord": ["ctrl", "o"]}' '{"sleep": 2}'
	'{"chord": ["ctrl", "a"]}' "$(jq -cn --arg t "${PROJECT}/" '{type: $t}')" '{"sleep": 1}'
	'{"key": ["Return"]}' '{"sleep": 8}'
)
RELAUNCH='{"sleep": 15}'
# multi_workspace::FocusWorkspaceSidebar (default keymap) opens the threads sidebar; Zeo restores it
# on every relaunch, so phase 0 opens it once, before the capture whose points the later phases use.
OPEN_SIDEBAR='{"chord": ["ctrl", "alt", "semicolon"]}'

# ── 0: the parent's one turn ───────────────────────────────────────────────
harness 0 "$(steps 0 "${OPEN_PROJECT[@]}" \
	'{"chord": ["ctrl", "question"]}' '{"sleep": 3}' \
	'{"chord": ["ctrl", "alt", "j"]}' '{"sleep": 10}' \
	"$(jq -cn --arg t "${PROMPT}" '{type: $t}')" '{"key": ["Return"]}' '{"sleep": 40}' \
	"${OPEN_SIDEBAR}" '{"sleep": 3}' "$(shot p0-reply.png)")"
reads p0-reply.png QUINCUNX || die 2 "no reply from the model in p0-reply.png (auth, credit, adapter?)"
find_db
printf 'database: %s\n' "${DB}"
PARENT_ID="$(q "SELECT lower(hex(thread_id)) FROM sidebar_threads WHERE session_id IS NOT NULL")"
[[ "${PARENT_ID}" =~ ^[0-9a-f]{32}$ ]] || die 2 "expected exactly one thread with a session, got [${PARENT_ID}]"
q "UPDATE sidebar_threads SET title_override = 'Marmalade' WHERE thread_id = X'${PARENT_ID}'"
read -r MX MY _ _ < <(box p0-reply.png MARMALADE bottom) || die 2 "MARMALADE not boxed in p0"
read -r OX OY OW _ < <(box p0-reply.png ORBIT bottom) || die 2 "ORBIT not boxed in p0"
read -r QX QY < <(centre_of p0-reply.png QUINCUNX bottom)
printf 'reply: phrase from %s,%s to %s,%s; right-click at %s,%s\n' \
	"${MX}" "${MY}" "$((OX + OW))" "${OY}" "${QX}" "${QY}"
# The press must land on the first glyph: one in the padding left of it selects nothing (dev-039).
SELECT_PHRASE="$(drag "$((MX + 2))" "$((MY + 6))" "$((OX + OW + 2))" "$((OY + 6))")"

# ── 1: the menu without, then with, a selection ────────────────────────────
harness 1 "$(steps 1 "${RELAUNCH}" "$(shot c0-restored.png)" \
	"$(at rclick "${QX}" "${QY}")" '{"sleep": 2}' "$(shot c1-menu-no-selection.png)" \
	'{"key": ["Escape"]}' '{"sleep": 1}' \
	"${SELECT_PHRASE}" '{"sleep": 1}' \
	"$(at rclick "${QX}" "${QY}")" '{"sleep": 2}' "$(shot c2-menu-selection.png)" \
	'{"key": ["Escape"]}')"
check_reads c1-menu-no-selection.png "Copy This Agent Response" "control: the menu opened"
check_lacks c1-menu-no-selection.png "sub-thread" "R1.4: no entry without a selection"
check_lacks c1-menu-no-selection.png "Sub-thread" "R1.4: no entry without a selection"
check_reads c2-menu-selection.png "Clean sub-thread" "R1.1"
check_reads c2-menu-selection.png "Sub-thread with context" "R1.2"
stop_if_failed 1
read -r FX FY < <(centre_of c2-menu-selection.png context)
read -r CX CY < <(centre_of c2-menu-selection.png Clean)

# ── 2: Sub-thread with context ─────────────────────────────────────────────
harness 2 "$(steps 2 "${RELAUNCH}" "${SELECT_PHRASE}" '{"sleep": 1}' \
	"$(at rclick "${QX}" "${QY}")" '{"sleep": 2}' \
	"$(at click "${FX}" "${FY}")" '{"sleep": 15}' "$(shot c3-forked.png)")"
check_reads c3-forked.png "Sub-thread of" "R4.1 the header"
check_reads c3-forked.png "Marmalade" "R4.1 it names the parent"
check_reads c3-forked.png "Inherited 2 messages" "R4.4 the band, counted at the fork"
check_reads c3-forked.png "QUINCUNX" "R3.2 the phrase is in the composer"
FORK_ID="$(q "SELECT lower(hex(thread_id)) FROM thread_organization WHERE fork_kind = 'with_context'")"
if [[ "${FORK_ID}" =~ ^[0-9a-f]{32}$ ]]; then
	ok "R3.3 one with_context link stored"
else
	fail "R3.3 one with_context link stored, got [${FORK_ID}]"
fi
stop_if_failed 2
LINKED="$(q "SELECT lower(hex(parent_thread_id)) FROM thread_organization WHERE thread_id = X'${FORK_ID}'")"
if [[ "${LINKED}" == "${PARENT_ID}" ]]; then
	ok "R3.3 the link names the parent"
else
	fail "R3.3 the link names [${LINKED}], not the parent [${PARENT_ID}]"
fi
stop_if_failed 2
q "UPDATE sidebar_threads SET title_override = 'Forkling' WHERE thread_id = X'${FORK_ID}'"

# ── 3: restart, header back, parent by its title, the marker's tooltip ─────
harness 3 "$(steps 3 "${RELAUNCH}" "$(shot c4-restarted.png)")"
check_reads c4-restarted.png "Sub-thread of" "R5.4 the header survives a restart"
check_reads c4-restarted.png "Inherited the conversation of" "R4.5 the count is not kept"
stop_if_failed 3
# The header's parent title is the topmost "Marmalade"; the sidebar rows are the leftmost.
read -r PX PY < <(centre_of c4-restarted.png Marmalade top)
read -r KL KT KW KH < <(box c4-restarted.png Forkling left) || die 2 "Forkling not boxed in c4"
read -r ML MT MW MH < <(box c4-restarted.png Marmalade left) || die 2 "Marmalade not boxed in c4"
printf 'c4: header parent title at %s,%s; rows Forkling %s,%s and Marmalade %s,%s\n' \
	"${PX}" "${PY}" "${KL}" "${KT}" "${ML}" "${MT}"
harness 3b "$(steps 3b "${RELAUNCH}" \
	"$(at click "${PX}" "${PY}")" '{"sleep": 3}' "$(shot c5a-parent-opened.png)" \
	"$(at move "$((ML + MW + MARKER_DX))" "$((MT + MH / 2))")" '{"sleep": 2}' \
	"$(shot c5b-parent-row-hover.png)" \
	"$(at move "$((KL + KW + MARKER_DX))" "$((KT + KH / 2))")" '{"sleep": 2}' \
	"$(shot c5c-marker-tooltip.png)")"
check_reads c5a-parent-opened.png "QUINCUNX" "R4.2 the parent title opened the parent"
check_lacks c5a-parent-opened.png "Sub-thread of" "R4.7 the parent has no header"
check_lacks c5b-parent-row-hover.png "Sub-thread of" "control: the parent's row has no marker"
check_reads c5c-marker-tooltip.png "Sub-thread of Marmalade" "R5.1 the marker's tooltip"
stop_if_failed 3

# ── 4: Clean sub-thread, from the parent ───────────────────────────────────
# Phase 3b left the parent open, so the relaunch restores it and the header's spot is the parent's
# own message; its sidebar row opens it whatever was restored.
harness 4 "$(steps 4 "${RELAUNCH}" \
	"$(at click "$((ML + MW / 2))" "$((MT + MH / 2))")" '{"sleep": 3}' "${SELECT_PHRASE}" '{"sleep": 1}' \
	"$(at rclick "${QX}" "${QY}")" '{"sleep": 2}' \
	"$(at click "${CX}" "${CY}")" '{"sleep": 5}' "$(shot c6-clean.png)")"
check_reads c6-clean.png "QUINCUNX" "R2.2 the phrase is in the clean composer"
check_lacks c6-clean.png "Inherited" "R4.6 a clean sub-thread has no band"
if (("$(q "SELECT count(*) FROM sidebar_threads WHERE session_id IS NULL")" >= 1)); then
	ok "R2.2 the clean sub-thread is an unsent draft"
else
	fail "R2.2 no unsent draft row"
fi
if [[ "$(q "SELECT count(*) FROM thread_organization WHERE fork_kind = 'clean'")" == 0 ]]; then
	ok "R2.3 no clean link before its first message"
else
	fail "R2.3 a clean link was stored early"
fi

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
