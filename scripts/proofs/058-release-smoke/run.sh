#!/usr/bin/env bash
# Story 058, task 7.3 — smoke proof of the released Zeo 0.6.0 on a private X display (E2E).
#
#     run.sh --version <X.Y.Z> --out <docs/assets/058-release-0.6.0> [--binary <zeo-editor>]
#
# What it proves (R7.3, Q9): the editor the operator emerged opens a window, its About names the
# released version (048's smoke), and the three features the release train carries are present:
#   epic   the Epic Stories dock button (patch 0066): it appears only over a project that holds
#          .epic/, its tooltip reads "Epic Stories", and a click opens the panel ("Open EPIC.md"
#          and the seeded story's slug);
#   voice  the composer's microphone button (patch 0067): it appears only with
#          voice_input.enabled, and its tooltip reads "Voice input";
#   drag   sidebar drag (patch 0065): a project header dragged onto the one above it takes its
#          place.
#
# Each presence check is paired with a negative control in which the thing must be ABSENT, so an
# unrelated difference (a toast, a blinking cursor, a shifted label) is never taken for it:
#   epic   the same steps over a project with no .epic/: no dock button may differ in the status
#          bar — the button is located as the one button-sized difference between the two;
#   voice  the same steps with voice_input.enabled false: the microphone is located as the one
#          button-sized difference in the composer toolbar (044's recipe, model selector masked);
#   drag   the order before the drag (beta above alpha) is checked in the same run.
# A located difference counts only if hovering it shows the feature's own tooltip.
#
# How: one xvfb-proof.sh run per phase, each with its own isolated --keep directory (never the
# operator's profile). The harness replays a fixed step script, so a coordinate found in one
# phase's capture is pointed at in a later phase that repeats the same steps on a fresh profile:
#   on       project epic-proof (with a seeded .epic/), voice on:  window, composer, About
#   voff     the same project, voice off                            (control for the microphone)
#   noepic   project plain (no .epic/), voice on:  window          (control for the epic button)
#   hover    as `on`, then hover the microphone, hover the epic button, click it
#   d0..d2   036's recipe: create the database, seed one thread per project, open alpha and
#            beta, then drag alpha's header onto beta's
#
# Binary: the installed editor is /usr/libexec/zeo-editor (the harness's default). /usr/bin/zeo is
# the CLI launcher, which forwards to a running Zeo; it is refused.
#
# Red: before 0.6.0 is installed, the installed 0.5.1 About does not read "Zeo 0.6.0", and has no
# epic button, no microphone and no drag: the run exits 1. Red is deferred to Run mode (task 7.3).
#
# Tuning: the sleeps, the status-bar band and the composer recipe are taken from the 036, 042,
# 044 and 048 proofs, which were tuned on dev builds; tune them on the release build if needed
# and record what changed in the proof README.
#
# Rung: X11 on Xvfb, software rendering (llvmpipe), no window manager. Not covered: Wayland, GPU,
# a real microphone (no recording is started), the epic panel's live updates, drag of threads or
# pins (036's full proof), the drop-target highlight mid-drag.
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
VERSION=""
while (($#)); do
	case "$1" in
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
grep -q '"drag"' "${HARNESS}" ||
	die 2 "xvfb-proof.sh has no {\"drag\": [x1, y1, x2, y2]} step (story 036); nothing can be dragged"
for tool in tesseract xdotool Xvfb sqlite3 python3 awk realpath; do
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
# Captures left by an earlier run would be compared with this run's.
rm -f -- "${OUT}"/{on,voff,noepic,hover,drag}-*.png "${OUT}/epic-panel.png"
# /tmp, not TMPDIR: xvfb-proof.sh caps the workdir at 60 bytes (Unix socket paths).
STATE="$(mktemp -d /tmp/zp058-XXXX)"
printf 'binary: %s\nstate: %s\nout: %s\n' "${BINARY}" "${STATE}" "${OUT}"

failed=0
ok() { printf 'ok    %s\n' "$*"; }
fail() {
	printf 'FAIL  %s\n' "$*"
	failed=1
}

# ── Fixtures ───────────────────────────────────────────────────────────────
EPIC_PROJECT="${STATE}/p/epic-proof"
PLAIN_PROJECT="${STATE}/p/plain"
STORY_SLUG="zeo-release-smoke"
mkdir -p -- "${EPIC_PROJECT}/.epic/stories/901-${STORY_SLUG}" "${PLAIN_PROJECT}"
printf '.epic/\n' >"${EPIC_PROJECT}/.gitignore"
printf 'release smoke\n' >"${EPIC_PROJECT}/README"
printf 'release smoke\n' >"${PLAIN_PROJECT}/README"
printf '# Epic\n' >"${EPIC_PROJECT}/.epic/EPIC.md"
cat >"${EPIC_PROJECT}/.epic/stories/901-${STORY_SLUG}/story.md" <<'MD'
---
story: zeo-release-smoke
type: feature
scale: standard
status: draft
---

# Story - release smoke fixture
MD
printf -- '- [ ] 1 - one open box\n- [x] 2 - one closed box\n' \
	>"${EPIC_PROJECT}/.epic/stories/901-${STORY_SLUG}/tasks.md"

# settings <voice true|false>: the cursor does not blink, so captures compare pixel for pixel.
settings() {
	local file="${STATE}/settings-$1.json"
	cat >"${file}" <<JSON
{"use_system_path_prompts": false, "cursor_blink": false,
 "session": {"trust_all_worktrees": true},
 "voice_input": {"enabled": $1, "model": "tiny"}}
JSON
	printf '%s' "${file}"
}

# The harness launches the editor with no project; a wrapper appends one (044's recipe).
wrapper() {
	local file="${STATE}/zeo-$1"
	cat >"${file}" <<WRAPPER
#!/bin/sh
exec '${BINARY}' "\$@" '$2'
WRAPPER
	chmod 755 "${file}"
	printf '%s' "${file}"
}

# harness <phase> <binary> <settings> <profile> <steps>: the steps are validated (--dry-run)
# first, so a refusal is this script's fault (exit 2) and an exit 1 during the run is Zeo or the
# input failing.
harness() {
	local phase="$1" binary="$2" settings_file="$3" profile="$4" steps_file="$5" status=0
	"${HARNESS}" --dry-run --steps "${steps_file}" >/dev/null ||
		die 2 "xvfb-proof.sh refused the steps of phase ${phase}"
	"${HARNESS}" --binary "${binary}" --settings "${settings_file}" --keep "${profile}" \
		--steps "${steps_file}" || status=$?
	case "${status}" in
	0) ;;
	1)
		fail "phase ${phase}: Zeo or the input failed during the run (exit 1 from the harness)"
		printf 'state kept for inspection: %s\n' "${STATE}"
		exit 1
		;;
	*) die 2 "xvfb-proof.sh failed on phase ${phase} (exit ${status})" ;;
	esac
}

steps() {
	local file="${STATE}/steps-$1.json"
	printf '[\n  %s\n]\n' "$2" >"${file}"
	printf '%s' "${file}"
}

# The steps every presence phase shares, so the captures of a phase and its control are taken
# in the same state: the window (status bar baseline), then the agent panel and a new thread.
common() {
	printf '{"sleep": 20},
  {"shot": "%s/%s-window.png"},
  {"chord": ["ctrl", "question"]}, {"sleep": 3},
  {"chord": ["ctrl", "n"]}, {"sleep": 4},
  {"shot": "%s/%s-composer.png"}' "${OUT}" "$1" "${OUT}" "$1"
}

# ── OCR and image geometry ────────────────────────────────────────────────
SCALE=3
# Two recipes: the blue channel (032/036/044, sidebar and composer) and greyscale (042, the epic
# panel). A needle counts when either reads it; the needles are specific enough for that.
to_pnm() {
	"${MAGICK[@]}" "$1" -channel B -separate +channel -resize "$((SCALE * 100))%" -threshold 70% "$2" ||
		die 2 "cannot convert $1 for tesseract"
}
ocr() {
	local pnm="${STATE}/ocr.pnm" text grey
	to_pnm "${OUT}/$1" "${pnm}"
	text="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read $1"
	"${MAGICK[@]}" "${OUT}/$1" -colorspace Gray -resize "$((SCALE * 100))%" -threshold 70% "${pnm}" ||
		die 2 "cannot convert $1 for tesseract"
	grey="$(tesseract "${pnm}" - 2>/dev/null)" || die 2 "tesseract could not read $1"
	tr '\n' ' ' <<<"${text} ${grey}"
}
reads() { [[ "$(ocr "$1")" == *"$2"* ]]; }
check_reads() {
	if reads "$1" "$2"; then ok "$1 reads \"$2\" ($3)"; else fail "$1 does not read \"$2\" ($3)"; fi
}
size_of() {
	"${MAGICK[@]}" identify -format '%w %h\n' "$1" 2>/dev/null ||
		"${MAGICK[@]}" "$1" -format '%w %h\n' info: || die 2 "cannot read the size of $1"
}

# diff_centre <a> <b> [<crop WxH+X+Y>] [right]: prints "x y" (screen pixels) of the centre of every
# pixel that differs between captures a and b, inside the crop. Returns 3 when nothing differs (the
# element is absent: a product failure) and 4 when the difference is not one button (the recipe
# needs tuning: an environment problem).
# `right` is for a right-aligned row such as the status bar: a button inserted there shifts every
# icon to its left by one slot, so the difference spans several icons and the inserted one is its
# rightmost glyph (the icons right of it do not move). Measured on 0.6.0, 2026-10-20: 126x14. The
# hover that follows must still show the feature's own tooltip, which is what proves the guess.
diff_centre() {
	local crop="${3:-}" anchor="${4:-}" g w h x0 y0 ox=0 oy=0 args=()
	if [[ -n "${crop}" ]]; then
		[[ "${crop}" =~ ^[0-9]+x[0-9]+\+([0-9]+)\+([0-9]+)$ ]] || die 2 "bad crop ${crop}"
		ox="${BASH_REMATCH[1]}" oy="${BASH_REMATCH[2]}"
		args=(-crop "${crop}" +repage)
	fi
	g="$("${MAGICK[@]}" \( "${OUT}/$1" "${args[@]}" \) \( "${OUT}/$2" "${args[@]}" \) \
		-compose difference -composite -colorspace Gray -threshold 8% -format '%@' info: 2>/dev/null)" ||
		die 2 "cannot diff $1 $2"
	[[ "${g}" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] || return 3
	w="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" x0="${BASH_REMATCH[3]}" y0="${BASH_REMATCH[4]}"
	((w > 0 && h > 0)) || return 3
	if [[ "${anchor}" == right ]] && ((w > 80 && h <= 48)); then
		printf '%d %d\n' "$((ox + x0 + w - h / 2))" "$((oy + y0 + h / 2))"
		return 0
	fi
	if ((w > 80 || h > 48)); then
		printf 'difference %s between %s and %s is not one button\n' "${g}" "$1" "$2" >&2
		return 4
	fi
	printf '%d %d\n' "$((ox + x0 + w / 2))" "$((oy + y0 + h / 2))"
}

# 044's recipe: the model selector sits left of where the microphone appears and shifts left by
# the button's width when it does, so each capture gets a copy with the selector painted over in
# the toolbar's background. The selector is found by OCR ("Select a Model") in the bottom row.
mask_selector() {
	local src="${OUT}/$1" dst="${OUT}/$2" l t r b bg
	to_pnm "${src}" "${STATE}/sel.pnm"
	read -r l t r b < <(tesseract "${STATE}/sel.pnm" - tsv 2>/dev/null | awk -F '\t' -v s="${SCALE}" '
		NR > 1 && $12 ~ /Select|Model/ && $8 / s > 900 {
			if (!f || $7 < l) l = $7; if (!f || $8 < t) t = $8
			if ($7 + $9 > r) r = $7 + $9; if ($8 + $10 > b) b = $8 + $10; f = 1 }
		END { if (f) printf "%d %d %d %d\n", l / s, t / s, r / s, b / s; exit !f }') ||
		die 2 "the model selector was not found in $1"
	bg="$("${MAGICK[@]}" "${src}" -format "%[pixel:p{$((l - 12)),$(((t + b) / 2))}]" info:)" ||
		die 2 "cannot sample the toolbar background in $1"
	"${MAGICK[@]}" "${src}" -fill "${bg}" -draw "rectangle $((l - 4)),$((t - 6)) $((r + 18)),$((b + 6))" "${dst}" ||
		die 2 "cannot mask the selector in $1"
}

# locate <capture> <word>: 036's recipe — the topmost word box reading <word> inside the threads
# sidebar, which is bounded by its own search field ("Search threads...").
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
y_of() {
	local _x y
	read -r _x y < <(locate "$1" "$2") || die 2 "\"$2\" was not boxed in $1"
	printf '%s' "${y}"
}
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

# ── Phases on, voff, noepic: the captures and their controls ───────────────
ON_SETTINGS="$(settings true)"
OFF_SETTINGS="$(settings false)"
EPIC_ZEO="$(wrapper epic "${EPIC_PROJECT}")"
PLAIN_ZEO="$(wrapper plain "${PLAIN_PROJECT}")"

harness on "${EPIC_ZEO}" "${ON_SETTINGS}" "${STATE}/on" "$(steps on "$(common on),
  {\"chord\": [\"ctrl\", \"shift\", \"p\"]}, {\"sleep\": 1},
  {\"type\": \"about\"}, {\"sleep\": 1},
  {\"key\": [\"Return\"]}, {\"sleep\": 3},
  {\"shot\": \"${OUT}/on-about.png\"}")"
harness voff "${EPIC_ZEO}" "${OFF_SETTINGS}" "${STATE}/voff" "$(steps voff "$(common voff)")"
harness noepic "${PLAIN_ZEO}" "${ON_SETTINGS}" "${STATE}/noepic" "$(steps noepic '{"sleep": 20},
  {"shot": "'"${OUT}"'/noepic-window.png"}')"

for shot in on-window on-composer on-about voff-composer noepic-window; do
	[[ -s "${OUT}/${shot}.png" ]] || die 1 "no ${shot} capture: the editor did not open a window"
done
ok "the released editor opened a window (on-window.png)"

# The version, as 048 reads it: a centre crop of the About capture, scaled 3x, as 8-bit PGM
# (this host's tesseract cannot decode PNG). A trailing digit is refused, so "Zeo 0.6.01" or
# "Zeo 0.6.0" read out of "Zeo 0.6.00" never pass for 0.6.0.
python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("L"); w, h = im.size
box = (w // 2 - 260, h // 2 - 280, w // 2 + 260, h // 2 + 120)
im.crop(box).resize(((box[2] - box[0]) * 3, (box[3] - box[1]) * 3)).save(sys.argv[2])' \
	"${OUT}/on-about.png" "${STATE}/about.pgm" || die 2 "could not convert the About capture to PGM (python3 + Pillow)"
about="$(tesseract "${STATE}/about.pgm" - 2>/dev/null || true)"
if grep -qE "Zeo ${VERSION//./\\.}([^0-9]|$)" <<<"${about}"; then
	ok "on-about.png names Zeo ${VERSION} (R7.3 the About)"
else
	fail "on-about.png does not name Zeo ${VERSION} (R7.3 the About); OCR text: ${about//$'\n'/ }"
fi

# The epic button: the one button-sized difference in the right half of the status bar between a
# project with .epic/ and one without (the bottom 40 rows).
read -r W H < <(size_of "${OUT}/on-window.png") || true
[[ "${W:-}" =~ ^[0-9]+$ && "${H:-}" =~ ^[0-9]+$ ]] || die 2 "cannot read the size of on-window.png"
BAND="$((W / 2))x40+$((W / 2))+$((H - 40))"
EPIC_X="" EPIC_Y="" status=0
coords="$(diff_centre noepic-window.png on-window.png "${BAND}" right)" || status=$?
case "${status}" in
0)
	read -r EPIC_X EPIC_Y <<<"${coords}"
	ok "a button-sized status-bar control appears only over a project with .epic/ (at ${EPIC_X},${EPIC_Y})"
	;;
3) fail "R7.3 no status-bar control appears over a project with .epic/: the Epic panel button is absent" ;;
*) die 2 "the status-bar difference could not be read as one button; tune BAND" ;;
esac

# The microphone: the one button-sized difference in the composer between voice on and voice off.
MIC_X="" MIC_Y="" status=0
mask_selector voff-composer.png voff-composer-masked.png
mask_selector on-composer.png on-composer-masked.png
coords="$(diff_centre voff-composer-masked.png on-composer-masked.png)" || status=$?
case "${status}" in
0)
	read -r MIC_X MIC_Y <<<"${coords}"
	ok "a button-sized composer control appears only with voice_input.enabled (at ${MIC_X},${MIC_Y})"
	;;
3) fail "R7.3 no composer control appears with voice_input.enabled: the microphone button is absent" ;;
*) die 2 "the composer difference could not be read as one button; tune mask_selector" ;;
esac

# ── Phase hover: a located difference counts only with the feature's own tooltip ─────────
hover_steps="$(common hover)"
if [[ -n "${MIC_X}" ]]; then
	hover_steps+=",
  {\"move\": [${MIC_X}, ${MIC_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/hover-mic.png\"}"
fi
if [[ -n "${EPIC_X}" ]]; then
	hover_steps+=",
  {\"move\": [${EPIC_X}, ${EPIC_Y}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/hover-epic.png\"},
  {\"click\": [${EPIC_X}, ${EPIC_Y}]}, {\"sleep\": 3},
  {\"shot\": \"${OUT}/epic-panel.png\"}"
fi
if [[ -n "${MIC_X}${EPIC_X}" ]]; then
	harness hover "${EPIC_ZEO}" "${ON_SETTINGS}" "${STATE}/hover" "$(steps hover "${hover_steps}")"
fi
if [[ -n "${MIC_X}" ]]; then
	check_reads hover-mic.png "Voice input" "R7.3 the composer's microphone button, by its tooltip"
fi
if [[ -n "${EPIC_X}" ]]; then
	check_reads hover-epic.png "Epic Stories" "R7.3 the Epic panel button, by its tooltip"
	check_reads epic-panel.png "Open EPIC.md" "R7.3 the button opens the Epic panel"
	check_reads epic-panel.png "${STORY_SLUG}" "R7.3 the panel lists the seeded story"
fi

# ── Phases d0..d2: sidebar drag (036's recipe, one header drag) ───────────────────────────
DRAG_PROFILE="${STATE}/drag"
ALPHA="${STATE}/p/alpha"
BETA="${STATE}/p/beta"
mkdir -p -- "${ALPHA}" "${BETA}"
printf 'alpha\n' >"${ALPHA}/README"
printf 'beta\n' >"${BETA}/README"
DRAG_SETTINGS="${STATE}/settings-drag.json"
printf '{"use_system_path_prompts": false, "session": {"trust_all_worktrees": true}}\n' >"${DRAG_SETTINGS}"

harness d0 "${BINARY}" "${DRAG_SETTINGS}" "${DRAG_PROFILE}" "$(steps d0 '{"sleep": 20}')"
has_table() {
	[[ "$(sqlite3 "$1" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$2'")" == 1 ]]
}
DB=""
while IFS= read -r -d '' candidate; do
	if has_table "${candidate}" sidebar_threads; then
		DB="${candidate}"
		break
	fi
done < <(find "${DRAG_PROFILE}" -path '*/db/*' -name 'db.sqlite' -print0)
[[ -n "${DB}" ]] || die 2 "no database under ${DRAG_PROFILE} holds sidebar_threads"
t() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
# One thread per project, so each project has a group in the sidebar; agent_id NULL is the
# native agent's id, so no agent server is needed.
sqlite3 "${DB}" <<SQL || die 2 "seeding ${DB} failed"
INSERT INTO sidebar_threads
    (thread_id, session_id, agent_id, title, updated_at, created_at,
     folder_paths, folder_paths_order, archived, main_worktree_paths, main_worktree_paths_order)
VALUES
    (X'58a1000000000000000000000000000a', 'p058-apricot', NULL, 'Apricot', '$(t '-1 hour')', '$(t '-1 hour')', '${ALPHA}', '0', 0, '${ALPHA}', '0'),
    (X'58b1000000000000000000000000000d', 'p058-damson', NULL, 'Damson', '$(t '-2 hour')', '$(t '-2 hour')', '${BETA}', '0', 0, '${BETA}', '0');
SQL

# ctrl-k ctrl-o is workspace::Open (036's tuning): beta joins alpha's window as another project
# group in the same sidebar; ctrl-alt-; shows the threads sidebar.
open_folder() {
	printf '{"chord": ["ctrl", "k"]}, {"chord": ["ctrl", "o"]}, {"sleep": 2},
  {"chord": ["ctrl", "a"]}, {"type": "%s/"}, {"sleep": 1},
  {"key": ["Return"]}, {"sleep": 8}' "$1"
}
OPEN='{"sleep": 15},
  '"$(open_folder "${ALPHA}")"',
  '"$(open_folder "${BETA}")"',
  {"chord": ["ctrl", "alt", "semicolon"]}, {"sleep": 3}'

harness d1 "${BINARY}" "${DRAG_SETTINGS}" "${DRAG_PROFILE}" "$(steps d1 "${OPEN},
  {\"shot\": \"${OUT}/drag-0-opened.png\"}")"
for word in alpha beta Apricot Damson; do
	check_reads drag-0-opened.png "${word}" "control: the sidebar shows ${word}"
done
read -r AX AY < <(locate drag-0-opened.png alpha) || die 2 "alpha's header not boxed in drag-0"
read -r BX BY < <(locate drag-0-opened.png beta) || die 2 "beta's header not boxed in drag-0"

harness d2 "${BINARY}" "${DRAG_SETTINGS}" "${DRAG_PROFILE}" "$(steps d2 "${OPEN},
  {\"shot\": \"${OUT}/drag-1-before.png\"},
  {\"drag\": [${AX}, ${AY}, ${BX}, ${BY}]}, {\"sleep\": 2},
  {\"shot\": \"${OUT}/drag-2-after.png\"}")"
check_above drag-1-before.png beta alpha "control: the most recently opened project first, before the drag"
check_above drag-2-after.png alpha beta "R7.3 sidebar drag: the dragged project took beta's place"

printf 'state kept for inspection: %s\n' "${STATE}"
if ((failed == 0)); then
	printf 'run.sh: PASS — Zeo %s opened, and the Epic panel button, the microphone and sidebar drag are present\n' "${VERSION}"
fi
exit "${failed}"
