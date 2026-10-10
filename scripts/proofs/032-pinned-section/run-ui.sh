#!/usr/bin/env bash
# Story 032 v4, task 11.1 — pins made through the UI, on the release binary (E2E).
#
#     run-ui.sh --out <docs/assets/032-ui-pin-proof-DATE> [--binary <zeo-editor>] [--pin-key <keys>]
#
# What it proves (R1.5, R1.2, R1.4, R2.11; Q11, Q12): on the installed release build, a thread of
# `alpha` is pinned with `shift-p`, unpinned through its context menu ("Unpin Thread"), pinned
# again through the hover button, and is still pinned after a restart. Starting the binary at all
# also proves the `agents_sidebar::TogglePinSelectedThread` keymap name resolves: the default
# keymap is loaded with an unwrap, so a wrong name would kill Zeo at startup (discovery 4.3).
#
# Each action's verdict compares the capture after it with a negative-control capture taken
# before it in the same run. Nothing is seeded but two threads: no pin exists until the UI makes
# one. The database is read after each action, and at the end it must hold exactly one pin, for
# the target thread.
#
# How: one --keep directory (an isolated --user-data-dir under a fresh mktemp dir, never the
# operator's profile) and one xvfb-proof.sh run per phase. The harness replays a fixed step script,
# so a coordinate cannot be read and used in the same run: a phase captures, tesseract's TSV boxes
# locate what to point at, and the next phase relaunches into the same layout and points there.
#   0  launch once: database and migrations;  seed two sidebar_threads rows (no pins)
#   1  open alpha, focus the sidebar, shot c0 (control: no "Pinned"); Up selects the target (the
#      last entry); --pin-key (shift+p); shot c1 ("Pinned" + the target)
#   2  relaunch, shot c1b (control: "Pinned"); right-click the pinned row; shot m ("Unpin Thread")
#   3  relaunch, right-click the pinned row, click "Unpin Thread"; shot c2 (no "Pinned")
#   4  relaunch, shot c2b (control: no "Pinned"); hover the target's group row; shot h
#      (the pin button is located from the c2b/h difference: the middle of the three buttons)
#   5  relaunch, hover the row, click the pin button; shot c3 ("Pinned")
#   6  relaunch (the restart), shot c4 ("Pinned" + the target survive)
#
# Red is deferred to the run (task 11.1): `--pin-key shift+o` must make the run exit 1, at c1.
#
# Requires the harness to accept a right-click step, {"rclick": [x, y]} (xdotool click 3); this
# driver checks for it and exits 2 without it.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland, GPU.
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, a
# capture could not be read or located).

set -euo pipefail

die() {
	local code="$1"
	shift
	printf 'run-ui.sh: %s\n' "$*" >&2
	exit "${code}"
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HERE}/../../xvfb-proof.sh"
BINARY="/usr/libexec/zeo-editor"
OUT=""
PIN_KEY="shift+p"
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--pin-key) PIN_KEY="${2:-}" && shift ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -n "${PIN_KEY}" ]] || die 2 "--pin-key must not be empty"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
grep -q '"rclick"' "${HARNESS}" ||
	die 2 "xvfb-proof.sh has no {\"rclick\": [x, y]} step; the context-menu phase needs it"
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
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp032ui-XXXX")"
PROFILE="${STATE}/zeo"
ALPHA="${STATE}/projects/alpha"
mkdir -p -- "${ALPHA}"
printf 'alpha\n' >"${ALPHA}/README"
# The target is the OLDER thread, so it is the group's last row: from the filter with no
# selection, Up selects the last entry. Its title carries the one word located on screen.
TARGET_TITLE="Alpha target thread"
TARGET_WORD="target"
OTHER_TITLE="Alpha other thread"
TARGET_ID="2a1b2c3d4e5f40718293a4b5c6d7e8f9"
OTHER_ID="3a1b2c3d4e5f40718293a4b5c6d7e8f9"
cat >"${STATE}/settings.json" <<'JSON'
{"use_system_path_prompts": false, "session": {"trust_all_worktrees": true}}
JSON
printf 'binary: %s\nprofile: %s\npin key: %s\n' "${BINARY}" "${PROFILE}" "${PIN_KEY}"

failed=0
fail() {
	printf 'FAIL  %s\n' "$*"
	failed=1
}
ok() {
	printf 'ok    %s\n' "$*"
}
# A later phase points at what an earlier one found; once a check has failed there may be nothing
# to point at, and that is the failure already reported, not an environment problem.
stop_if_failed() {
	if ((failed)); then
		printf 'stopping after phase %s: a check failed, later phases depend on it\n' "$1"
		printf 'state kept for inspection: %s\n' "${STATE}"
		exit 1
	fi
}

# The steps are validated (--dry-run) before each launch, so a refusal is the script's fault
# (exit 2) and an exit 1 during the run is Zeo or the input failing — for phase 0, the startup
# a wrong keymap action name would crash.
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

# Open alpha through Zeo's own path prompt, then show and focus the threads sidebar (the tuned
# recipe of run.sh; on a relaunch alpha is restored and opening it again only activates it).
OPEN='{"sleep": 15},
  {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "'"${ALPHA}"'/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8},
  {"chord": ["ctrl", "alt", "semicolon"]}, {"sleep": 3}'

# ── OCR and location ───────────────────────────────────────────────────────
# Leptonica under tesseract may read no PNG here, and muted text at 1x is pale: enlarge 3x and
# threshold to black on white, as PNM (run.sh's recipe). Boxes come back in 3x pixels.
# Tuned on the release build (11.1): the threshold runs on the BLUE channel, not on luminance. A
# selected entry is drawn inside a blue focus border, which luminance turns black, boxing the word
# in so tesseract drops it ("Pinned" in c1 was the selected header). In the blue channel that
# border is light and goes white, while the dark grey text stays black.
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
check_not_reads() {
	if reads "$1" "$2"; then fail "$1 reads \"$2\" ($3)"; else ok "$1 does not read \"$2\" ($3)"; fi
}
# The centre, in screen pixels, of the first word box whose text contains $2 ("x y").
locate() {
	local pnm="${STATE}/locate.pnm" tsv
	to_pnm "${OUT}/$1" "${pnm}"
	tsv="$(tesseract "${pnm}" - tsv 2>/dev/null)" || die 2 "tesseract could not box $1"
	awk -F '\t' -v word="$2" -v s="${SCALE}" '
		NR > 1 && $12 ~ word { printf "%d %d\n", ($7 + $9 / 2) / s, ($8 + $10 / 2) / s; found = 1; exit }
		END { exit !found }' <<<"${tsv}"
}
# The bounding box ("x0 y0 x1 y1") of every pixel that differs between two captures.
diff_box() {
	local geometry w h x y
	geometry="$("${MAGICK[@]}" "$1" "$2" -compose difference -composite -colorspace Gray \
		-threshold 8% -format '%@' info:)" || die 2 "cannot diff $1 and $2"
	[[ "${geometry}" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] ||
		die 2 "no difference between $1 and $2 (geometry ${geometry})"
	w="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" x="${BASH_REMATCH[3]}" y="${BASH_REMATCH[4]}"
	printf '%d %d %d %d\n' "${x}" "${y}" "$((x + w))" "$((y + h))"
}
# The hovered row shows [Rename, Pin/Unpin, Archive] right-aligned (sidebar.rs, the action slot).
# In the hovered capture, inside the hover box's band and its rightmost 110 px, the glyphs are
# grouped into icons by horizontal gaps; the pin button is the middle one of the last three.
# Tuned on the release build (11.1): the glyphs are not assumed light. Zeo on Xvfb runs its light
# theme, so the icons are dark on the row; the background is the largest component, and a glyph
# is any component of the other colour, whichever theme drew it.
pin_button() {
	local hovered="$1" x0="$2" y0="$3" x1="$4" y1="$5" left width height
	left=$((x1 - 110))
	((left > x0)) || left="${x0}"
	width=$((x1 - left))
	height=$((y1 - y0))
	"${MAGICK[@]}" "${hovered}" -crop "${width}x${height}+${left}+${y0}" +repage -colorspace Gray \
		-threshold 45% -define connected-components:verbose=true \
		-define connected-components:area-threshold=4 -connected-components 8 null: 2>/dev/null |
		awk -v left="${left}" -v top="${y0}" '
			# "  id: WxH+X+Y cx,cy area color" — every component, with its colour and area.
			$2 ~ /x/ {
				split($2, g, /[x+]/); c++; cx[c] = g[3]; ce[c] = g[3] + g[1]; cy[c] = g[4] + g[2] / 2
				col[c] = $NF; if ($4 + 0 > bgarea) { bgarea = $4 + 0; bg = $NF }
			}
			END {
				# keep the glyphs: the components not of the background (largest) colour
				for (k = 1; k <= c; k++) if (col[k] != bg) { xs[++n] = cx[k]; xe[n] = ce[k]; ys[n] = cy[k] }
				# sort by left edge, then merge components closer than 4 px into one icon
				for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (xs[j] < xs[i]) {
					t = xs[i]; xs[i] = xs[j]; xs[j] = t; t = xe[i]; xe[i] = xe[j]; xe[j] = t
					t = ys[i]; ys[i] = ys[j]; ys[j] = t
				}
				m = 0
				for (i = 1; i <= n; i++) {
					if (m > 0 && xs[i] <= ie[m] + 4) { if (xe[i] > ie[m]) ie[m] = xe[i]; continue }
					is[++m] = xs[i]; ie[m] = xe[i]; iy[m] = ys[i]
				}
				if (m < 3) exit 1
				p = m - 1
				printf "%d %d\n", left + (is[p] + ie[p]) / 2, top + iy[p]
			}'
}
pins() {
	sqlite3 "${DB}" "SELECT lower(hex(thread_id)) FROM thread_organization
		WHERE pinned_position IS NOT NULL ORDER BY pinned_position"
}
check_pins() {
	local want="$1" why="$2" got
	got="$(pins | tr '\n' ' ' | sed 's/ $//')" || die 2 "cannot read thread_organization in ${DB}"
	if [[ "${got}" == "${want}" ]]; then
		ok "pins are [${want}] (${why})"
	else
		fail "pins are [${got}], want [${want}] (${why})"
	fi
}
steps() {
	local file="${STATE}/steps-$1.json"
	printf '[\n  %s\n]\n' "$2" >"${file}"
	printf '%s' "${file}"
}

# ── 0: first launch, then seed two threads and no pin ─────────────────────
harness 0 "$(steps 0 '{"sleep": 20}')"
ok "phase 0: Zeo stayed up (the default keymap, with its shift-p action name, loaded)"
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
has_table "${DB}" thread_organization ||
	die 2 "${DB} has no thread_organization table: this build stores no pin (not a 0.3.0 build)"
printf 'database: %s\n' "${DB}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
EARLIER="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S+00:00)"
# agent_id NULL is the native agent's id (ThreadMetadataDb::save), so no agent server is needed.
sqlite3 "${DB}" <<SQL || die 2 "seeding the threads into ${DB} failed"
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'${OTHER_ID}', 'proof-032-ui-other', NULL, '${OTHER_TITLE}', '${NOW}', '${NOW}',
     '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'${TARGET_ID}', 'proof-032-ui-target', NULL, '${TARGET_TITLE}', '${EARLIER}', '${EARLIER}',
     '${ALPHA}', '0', 0, '${ALPHA}', '0');
SQL
check_pins "" "seeded: two threads, no pin"
stop_if_failed 0

# ── 1: shift-p ─────────────────────────────────────────────────────────────
harness 1 "$(steps 1 "${OPEN},
  {\"shot\": \"${OUT}/c0-before-shift-p.png\"},
  {\"key\": [\"Up\"]}, {\"sleep\": 1},
  {\"shot\": \"${OUT}/c0s-target-selected.png\"},
  {\"key\": [\"${PIN_KEY}\"]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c1-after-shift-p.png\"}")"
check_reads c0-before-shift-p.png "${TARGET_TITLE}" "control: the sidebar shows the target"
check_not_reads c0-before-shift-p.png "Pinned" "control: no section before the pin"
check_reads c1-after-shift-p.png "Pinned" "R1.5 shift-p on the selected row pins it"
check_reads c1-after-shift-p.png "${TARGET_TITLE}" "the pinned row is the target"
check_pins "${TARGET_ID}" "R1.5 the store holds the keyboard pin"
stop_if_failed 1
read -r PIN_X PIN_Y < <(locate c1-after-shift-p.png "${TARGET_WORD}") ||
	die 2 "the target's pinned row was read but not boxed in c1"
printf 'pinned row at %s,%s\n' "${PIN_X}" "${PIN_Y}"

# ── 2: the context menu, captured ──────────────────────────────────────────
harness 2 "$(steps 2 "${OPEN},
  {\"shot\": \"${OUT}/c1b-before-menu.png\"},
  {\"rclick\": [${PIN_X}, ${PIN_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/m-pinned-row-menu.png\"}")"
check_reads c1b-before-menu.png "Pinned" "control: the pin survived the relaunch, before the menu"
check_reads m-pinned-row-menu.png "Unpin Thread" "R1.3 a pinned row's menu offers Unpin Thread"
stop_if_failed 2
read -r UNPIN_X UNPIN_Y < <(locate m-pinned-row-menu.png "Unpin") ||
	die 2 "\"Unpin Thread\" was read but not boxed in m"
printf 'Unpin Thread at %s,%s\n' "${UNPIN_X}" "${UNPIN_Y}"

# ── 3: unpin through the context menu ──────────────────────────────────────
harness 3 "$(steps 3 "${OPEN},
  {\"rclick\": [${PIN_X}, ${PIN_Y}]}, {\"sleep\": 2},
  {\"click\": [${UNPIN_X}, ${UNPIN_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c2-after-unpin.png\"}")"
check_not_reads c2-after-unpin.png "Pinned" "R1.2 Unpin Thread removes the section"
check_reads c2-after-unpin.png "${TARGET_TITLE}" "the target is back in its group"
check_pins "" "R1.2 the store holds no pin"
stop_if_failed 3
read -r ROW_X ROW_Y < <(locate c2-after-unpin.png "${TARGET_WORD}") ||
	die 2 "the target's group row was read but not boxed in c2"
printf 'group row at %s,%s\n' "${ROW_X}" "${ROW_Y}"

# ── 4: hover, captured ─────────────────────────────────────────────────────
harness 4 "$(steps 4 "${OPEN},
  {\"shot\": \"${OUT}/c2b-before-hover.png\"},
  {\"move\": [${ROW_X}, ${ROW_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/h-row-hovered.png\"}")"
check_not_reads c2b-before-hover.png "Pinned" "control: no section before the hover button"
stop_if_failed 4
read -r HX0 HY0 HX1 HY1 < <(diff_box "${OUT}/c2b-before-hover.png" "${OUT}/h-row-hovered.png")
printf 'hover changed %s,%s .. %s,%s\n' "${HX0}" "${HY0}" "${HX1}" "${HY1}"
((HY0 <= ROW_Y && ROW_Y <= HY1)) ||
	die 2 "the hover changed pixels outside the target's row (${HY0}..${HY1}, row ${ROW_Y})"
read -r BTN_X BTN_Y < <(pin_button "${OUT}/h-row-hovered.png" "${HX0}" "${HY0}" "${HX1}" "${HY1}") ||
	die 2 "fewer than three buttons found at the right of the hovered row"
printf 'pin button at %s,%s\n' "${BTN_X}" "${BTN_Y}"

# ── 5: pin through the hover button ────────────────────────────────────────
harness 5 "$(steps 5 "${OPEN},
  {\"move\": [${ROW_X}, ${ROW_Y}]}, {\"sleep\": 2},
  {\"click\": [${BTN_X}, ${BTN_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/c3-after-hover-pin.png\"}")"
check_reads c3-after-hover-pin.png "Pinned" "R1.4 the hover button pins the thread"
check_pins "${TARGET_ID}" "R1.4 the store holds the hover pin"
stop_if_failed 5

# ── 6: the restart ─────────────────────────────────────────────────────────
harness 6 "$(steps 6 "${OPEN},
  {\"shot\": \"${OUT}/c4-after-restart.png\"}")"
check_reads c4-after-restart.png "Pinned" "R2.11 the section survives a restart"
check_reads c4-after-restart.png "${TARGET_TITLE}" "R2.11 with the same thread"
check_pins "${TARGET_ID}" "exactly one pin, the target's, at the end"

printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
