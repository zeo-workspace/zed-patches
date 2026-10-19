#!/usr/bin/env bash
# Story 044, task 7.3 — GUI proof of voice input in the agent composer, on a private X display (E2E).
#
#     run.sh --binary <zeo-editor built from dev-044> --out <docs/assets/044-live-proof-DATE>
#            [--allow-download] [--keep <dir, at most 40 bytes>]
#
# What it proves: the microphone button exists only when `voice_input.enabled` is on (R1.1, R1.2);
# its tooltip names the action; a click with no model shows the consent strip naming the model, its
# size and huggingface.co and starts no recording (R6.1); Download shows a percentage and Cancel
# (R6.2, R6.3) and the file that lands has the pinned size and SHA-256 (R6.4); then three dictations
# land in the composer, unsent and still editable (R4.1, R4.5):
#   1. click → speak → click            (R2.1, R2.3, R2.4: the m:ss label while recording)
#   2. tap ctrl+alt+v → speak → tap      (R2.2 toggle by shortcut)
#   3. hold ctrl+alt+v while speaking    (R3.1 push-to-talk)
#
# How: one --keep directory (an isolated --user-data-dir, never the operator's profile). Speech is a
# fixture WAV synthesised with flite and played into a PRIVATE PipeWire server whose only source
# is a null sink's monitor: the operator's microphone and sound server are never reached. The server
# listens in the same run/ directory xvfb-proof.sh hands Zeo as XDG_RUNTIME_DIR, and PIPEWIRE_REMOTE /
# PULSE_SERVER are exported so cpal's ALSA→PipeWire route lands there.
# xvfb-proof.sh has no key-down/key-up step, and a fixed step script cannot react to the screen, so
# (as the 033 proof did) the harness runs a hold script in the background and this driver sends
# input with xdotool and captures with `import` on the display the harness reports — after checking
# it is not the operator's DISPLAY and that the Xvfb on it is the harness's.
#
# The model download is 78 MB from huggingface.co: it happens only with --allow-download (the
# operator's go). With --keep, a model already downloaded by an earlier run is reused.
#
# Red (before story 044): phase 0 and phase 1 captures do not differ in the composer toolbar —
# no button is drawn — and the run exits 1 at "R1.1".
#
# Rung: X11 on Xvfb, software rendering, no window manager, synthetic speech, the `tiny` model.
# Not covered: Wayland, a real microphone, Flatpak (task 7.2), accuracy on human speech.
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused, audio
# server not private, a capture could not be read or located).

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
KEEP=""
ALLOW_DOWNLOAD=0
while (($#)); do
	case "$1" in
	--binary) BINARY="${2:-}" && shift ;;
	--out) OUT="${2:-}" && shift ;;
	--keep) KEEP="${2:-}" && shift ;;
	--allow-download) ALLOW_DOWNLOAD=1 ;;
	*) die 2 "unknown argument: $1" ;;
	esac
	shift
done
[[ -n "${BINARY}" && -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in Xvfb xdotool import tesseract jq pipewire wireplumber pipewire-pulse pactl paplay \
	flite sox sha256sum dbus-run-session setsid pgrep; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done
if command -v magick >/dev/null; then MAGICK=(magick); else MAGICK=(convert); fi
command -v "${MAGICK[0]}" >/dev/null || die 2 "missing tool: magick (ImageMagick)"

readonly MODEL_FILE="ggml-tiny.bin"
readonly MODEL_SIZE=77691713
readonly MODEL_SHA="be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
if [[ -n "${KEEP}" ]]; then
	mkdir -p -- "${KEEP}"
	STATE="$(cd -- "${KEEP}" && pwd)"
else
	STATE="$(mktemp -d /tmp/zp044-XXXX)"
fi
PROFILE="${STATE}/z" # xvfb-proof.sh caps the workdir at 60 bytes (Unix socket paths)
((${#PROFILE} <= 60)) || die 2 "profile path too long for the harness: ${PROFILE}"
RUNDIR="${PROFILE}/run"
mkdir -p -- "${RUNDIR}" "${STATE}/audio-config/wireplumber/wireplumber.conf.d" "${STATE}/fixtures" \
	"${STATE}/audio-state" "${STATE}/audio-cache"
chmod 700 "${RUNDIR}"
printf 'binary: %s\nprofile: %s\nout: %s\n' "${BINARY}" "${PROFILE}" "${OUT}"

failed=0
ok() { printf 'ok    %s\n' "$*"; }
fail() {
	printf 'FAIL  %s\n' "$*"
	failed=1
}
stop_if_failed() {
	((failed == 0)) && return 0
	printf 'stopping after %s: later phases depend on it\nstate kept: %s\n' "$1" "${STATE}"
	exit 1
}

# ── private audio server ─────────────────────────────────────────────────────
AUDIO_PGID=""
HARNESS_PID=""
cleanup() {
	[[ -z "${HARNESS_PID}" ]] || kill -TERM "${HARNESS_PID}" 2>/dev/null || true
	[[ -z "${HARNESS_PID}" ]] || wait "${HARNESS_PID}" 2>/dev/null || true
	[[ -z "${AUDIO_PGID}" ]] || kill -TERM -- "-${AUDIO_PGID}" 2>/dev/null || true
}
trap cleanup EXIT

# No ALSA, BlueZ, V4L2 or libcamera monitor: the private server must not see any real device.
cat >"${STATE}/audio-config/wireplumber/wireplumber.conf.d/90-proof-044.conf" <<'CONF'
wireplumber.profiles = {
  main = {
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
  }
}
CONF
# Setup: XDG_STATE_HOME and XDG_CACHE_HOME too. WirePlumber saves the configured default source
# in $XDG_STATE_HOME/wireplumber/default-nodes; left at its default, set-default-source below
# wrote `default.configured.audio.source=proof_mic` into the operator's ~/.local/state (2026-10-19).
AUDIO_ENV=(env XDG_RUNTIME_DIR="${RUNDIR}" PIPEWIRE_RUNTIME_DIR="${RUNDIR}"
	XDG_CONFIG_HOME="${STATE}/audio-config" XDG_STATE_HOME="${STATE}/audio-state"
	XDG_CACHE_HOME="${STATE}/audio-cache" PULSE_RUNTIME_PATH="${RUNDIR}/pulse")
setsid "${AUDIO_ENV[@]}" dbus-run-session -- bash -c \
	'pipewire & sleep 1; wireplumber & pipewire-pulse & wait' >"${STATE}/audio.log" 2>&1 &
AUDIO_PGID=$!
export PIPEWIRE_REMOTE="${RUNDIR}/pipewire-0"
export PULSE_SERVER="unix:${RUNDIR}/pulse/native"
for _ in $(seq 50); do [[ -S "${RUNDIR}/pulse/native" ]] && break; sleep 0.2; done
[[ -S "${RUNDIR}/pulse/native" ]] || die 2 "the private PipeWire/Pulse server did not start (see ${STATE}/audio.log)"
pa() { "${AUDIO_ENV[@]}" PULSE_SERVER="${PULSE_SERVER}" "$@"; }
pa pactl load-module module-null-sink sink_name=proof_mic \
	sink_properties=device.description=ProofMic >/dev/null || die 2 "cannot create the null sink"
# Setup: pipewire-pulse answers "Not supported" until WirePlumber has published its default
# metadata, which can lag the socket on a --keep rerun; retry for up to 10 s.
for _ in $(seq 50); do pa pactl set-default-source proof_mic.monitor 2>/dev/null && break; sleep 0.2; done
pa pactl set-default-source proof_mic.monitor || die 2 "cannot select the proof source"
sources="$(pa pactl list short sources | awk '{print $2}')"
[[ "${sources}" == "proof_mic.monitor" ]] ||
	die 2 "the private audio server sees more than the proof source: ${sources//$'\n'/ }"
ok "private audio server: the only source is proof_mic.monitor"

# ── speech fixtures (48 kHz mono, half a second of silence first) ─────────
fixture() {
	local name="$1" text="$2" raw="${STATE}/fixtures/$1-raw.wav"
	flite -voice slt -t "${text}" -o "${raw}" || die 2 "flite failed"
	sox "${raw}" -r 48000 -c 1 "${STATE}/fixtures/$1.wav" pad 0.5 0.5 || die 2 "sox failed"
}
# Setup: flite's `slt` voice, not espeak-ng. Measured on this build with `tiny` (2026-10-19):
# espeak-ng's "parser" came back as "Parasur", "Parcer" or "Power Service" depending on the
# session, its "settings" as "padding" or "landing"; flite's sentences below came back word for
# word, each still carrying the word its check looks for. "Open the settings file." came back as
# "Open the Settings file." in one run of five, so fixture two avoids the file-name reading
# (8 of 8 lowercase under jittered start and stop).
fixture one "The parser is broken."
fixture two "Please check your settings."
fixture three "Run the test suite."
speak() { pa paplay --device=proof_mic "${STATE}/fixtures/$1.wav" || die 2 "paplay failed for $1"; }

# ── Zeo under the harness, driven from here ────────────────────────────────
settings() {
	cat >"${STATE}/settings.json" <<JSON
{"use_system_path_prompts": false, "cursor_blink": false,
 "voice_input": {"enabled": $1, "model": "tiny"}}
JSON
}
DISPLAY_N=""
# Setup: with no project open the agent panel offers only "Open Project" and has no composer,
# and the harness launches the editor with no arguments. A wrapper in the state directory
# appends a throwaway project folder; the harness runs it as the editor.
mkdir -p -- "${STATE}/proj"
[[ -f "${STATE}/proj/README.md" ]] || printf '# voice input proof\n' >"${STATE}/proj/README.md"
cat >"${STATE}/zeo-proj" <<WRAPPER
#!/bin/sh
exec '${BINARY}' "\$@" '${STATE}/proj'
WRAPPER
chmod 755 "${STATE}/zeo-proj"
launch() {
	local steps="${STATE}/hold.json"
	jq -n '[{"sleep": 20}] + [range(40) | {"sleep": 60}]' >"${steps}"
	"${HARNESS}" --dry-run --steps "${steps}" >/dev/null || die 2 "xvfb-proof.sh refused the hold script"
	"${HARNESS}" --binary "${STATE}/zeo-proj" --settings "${STATE}/settings.json" --keep "${PROFILE}" \
		--steps "${steps}" >"${STATE}/harness.log" 2>&1 &
	HARNESS_PID=$!
	for _ in $(seq 100); do
		DISPLAY_N="$(sed -n 's/^display: \(:[0-9]*\) .*/\1/p' "${STATE}/harness.log" | head -n 1)"
		[[ -n "${DISPLAY_N}" ]] && grep -q '^window: ' "${STATE}/harness.log" && break
		kill -0 "${HARNESS_PID}" 2>/dev/null || die 2 "the harness exited: $(tail -n 3 "${STATE}/harness.log")"
		sleep 0.5
	done
	[[ -n "${DISPLAY_N}" ]] || die 2 "the harness reported no display"
	[[ "${DISPLAY_N}" != "${DISPLAY:-none}" ]] || die 2 "refusing to drive the operator's DISPLAY"
	pgrep -f "Xvfb ${DISPLAY_N} " >/dev/null || die 2 "no Xvfb on ${DISPLAY_N}"
	sleep 18 # Zeo settles (the harness's first step is a 20 s sleep)
	# Setup: the project raises the "Unrecognized Project" modal; Return is its default, Trust.
	x key Return && sleep 2
}
quit() {
	kill -TERM "${HARNESS_PID}" 2>/dev/null || true
	wait "${HARNESS_PID}" 2>/dev/null || true
	HARNESS_PID=""
}
x() {
	pgrep -f "Xvfb ${DISPLAY_N} " >/dev/null || die 2 "the Xvfb on ${DISPLAY_N} is gone"
	DISPLAY="${DISPLAY_N}" xdotool "$@"
}
shot() { DISPLAY="${DISPLAY_N}" import -window root "${OUT}/$1" || die 2 "capture failed: $1"; }

# Open the agent panel and a new thread; the composer has focus afterwards.
open_composer() {
	x key ctrl+question && sleep 3
	x key ctrl+n && sleep 4
}

SCALE=3
to_pnm() {
	"${MAGICK[@]}" "$1" -channel B -separate +channel -resize "$((SCALE * 100))%" -threshold 70% "$2" ||
		die 2 "cannot convert $1"
}
ocr() {
	to_pnm "${OUT}/$1" "${STATE}/ocr.pnm"
	tesseract "${STATE}/ocr.pnm" - 2>/dev/null | tr '\n' ' ' || die 2 "tesseract failed on $1"
}
reads() { [[ "$(ocr "$1")" == *"$2"* ]]; }
check_reads() { if reads "$1" "$2"; then ok "$1 reads \"$2\" ($3)"; else fail "$1 does not read \"$2\" ($3)"; fi; }
check_not_reads() { if reads "$1" "$2"; then fail "$1 reads \"$2\" ($3)"; else ok "$1 does not read \"$2\" ($3)"; fi; }
locate() {
	to_pnm "${OUT}/$1" "${STATE}/loc.pnm"
	tesseract "${STATE}/loc.pnm" - tsv 2>/dev/null | awk -F '\t' -v w="$2" -v s="${SCALE}" '
		NR > 1 && $12 ~ w { x = ($7 + $9 / 2) / s; y = ($8 + $10 / 2) / s; f = 1 }
		END { if (f) printf "%d %d\n", x, y; exit !f }' # the last match: "Download it?" in the sentence comes before the button
}
# The centre of every pixel that differs between two captures, if the difference is button-sized.
diff_centre() {
	local g w h x0 y0
	g="$("${MAGICK[@]}" "${OUT}/$1" "${OUT}/$2" -compose difference -composite -colorspace Gray \
		-threshold 8% -format '%@' info:)" || die 2 "cannot diff $1 $2"
	[[ "${g}" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] || return 1
	w="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}" x0="${BASH_REMATCH[3]}" y0="${BASH_REMATCH[4]}"
	((w > 0 && w <= 80 && h > 0 && h <= 48)) || { printf 'difference %s is not one button\n' "${g}" >&2; return 1; }
	printf '%d %d\n' "$((x0 + w / 2))" "$((y0 + h / 2))"
}
# Setup: the model selector sits left of where the button appears and shifts left by the
# button's width when it does, so a plain p0/p1 difference spans selector and button (about
# 118 px). Each capture gets its own copy with the selector painted over in the toolbar's
# background, so the comparison sees what is right of the selector in each, at unchanged
# coordinates. The selector is found by OCR ("Select a Model") in the bottom toolbar row.
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
	# 18 px past the text covers the selector's chevron; the send button starts further right.
	"${MAGICK[@]}" "${src}" -fill "${bg}" -draw "rectangle $((l - 4)),$((t - 6)) $((r + 18)),$((b + 6))" "${dst}" ||
		die 2 "cannot mask the selector in $1"
}
# Waits up to $3 s for capture $1 (re-taken every 2 s) to read $2.
wait_reads() {
	local name="$1" needle="$2" limit="$3" t=0
	while ((t < limit)); do
		shot "${name}"
		reads "${name}" "${needle}" && return 0
		sleep 2
		t=$((t + 2))
	done
	return 1
}
# The transcript is in the composer, unsent, and still editable: typing appends right after it.
check_unsent_and_editable() {
	local name="$1" word="$2" mark="$3"
	x type --delay 30 " ${mark}" && sleep 1
	shot "${name}"
	check_reads "${name}" "${word}" "R4.1 the transcript is in the composer"
	check_reads "${name}" "${mark}" "R4.1/R4.5 still editable after it: nothing was sent"
	x key ctrl+a BackSpace && sleep 1
}

# ── 0: control — voice input disabled ─────────────────────────────────────
settings false
launch
open_composer
shot p0-disabled.png
quit

# ── 1: enabled — the button appears; consent ───────────────────────────────
settings true
launch
open_composer
shot p1-enabled.png
mask_selector p0-disabled.png p0-disabled-masked.png
mask_selector p1-enabled.png p1-enabled-masked.png
if read -r MIC_X MIC_Y < <(diff_centre p0-disabled-masked.png p1-enabled-masked.png); then
	ok "R1.1/R1.2 a button-sized control appears only with voice_input.enabled (at ${MIC_X},${MIC_Y})"
else
	fail "R1.1 no microphone button appears when voice_input.enabled is true"
fi
stop_if_failed "R1.1"
x mousemove "${MIC_X}" "${MIC_Y}" && sleep 2
shot p1-tooltip.png
check_reads p1-tooltip.png "Voice input" "R1.1 the tooltip names the action"
MODEL_PATH="$(find "${PROFILE}" -name "${MODEL_FILE}" -size "${MODEL_SIZE}c" -print -quit 2>/dev/null || true)"

if [[ -z "${MODEL_PATH}" ]]; then
	x click 1 && sleep 2
	shot p2-consent.png
	check_reads p2-consent.png "huggingface.co" "R6.1 the host is named"
	check_reads p2-consent.png "78 MB" "R6.1 the download size is named"
	check_reads p2-consent.png "tiny" "R6.1 the model is named"
	check_not_reads p2-consent.png "0:0" "R6.1 no recording started"
	stop_if_failed "consent"
	((ALLOW_DOWNLOAD)) || die 2 "the model is missing: rerun with --allow-download (78 MB from huggingface.co)"
	read -r DL_X DL_Y < <(locate p2-consent.png "Download") || die 2 "\"Download\" was read but not boxed"
	x mousemove "${DL_X}" "${DL_Y}" click 1
	# Setup: a 78 MB download can finish in under 3 s, so a single capture after a fixed sleep
	# misses it. Capture back to back until the model lands, then keep, as p3-downloading.png,
	# the first frame that reads both "%" and "Cancel" — the progress strip the two checks below
	# read — or else the first frame, for the checks to judge.
	mkdir -p -- "${STATE}/burst" && rm -f -- "${STATE}"/burst/*.png
	for n in $(seq -w 1 600); do
		DISPLAY="${DISPLAY_N}" import -window root "${STATE}/burst/${n}.png" || die 2 "capture failed: burst ${n}"
		[[ -n "$(find "${PROFILE}" -name "${MODEL_FILE}" -size "${MODEL_SIZE}c" -print -quit 2>/dev/null)" ]] && break
		sleep 0.2
	done
	frames=("${STATE}"/burst/*.png)
	cp -- "${frames[0]}" "${OUT}/p3-downloading.png"
	for frame in "${frames[@]}"; do
		to_pnm "${frame}" "${STATE}/ocr.pnm"
		text="$(tesseract "${STATE}/ocr.pnm" - 2>/dev/null | tr '\n' ' ')"
		if [[ "${text}" == *"%"* && "${text}" == *"Cancel"* ]]; then
			cp -- "${frame}" "${OUT}/p3-downloading.png"
			printf 'download progress: frame %s of %s\n' "$(basename -- "${frame}" .png)" "${#frames[@]}"
			break
		fi
	done
	check_reads p3-downloading.png "%" "R6.2 the progress is a percentage"
	check_reads p3-downloading.png "Cancel" "R6.3 a Cancel control during the download"
	for _ in $(seq 300); do
		MODEL_PATH="$(find "${PROFILE}" -name "${MODEL_FILE}" -size "${MODEL_SIZE}c" -print -quit 2>/dev/null || true)"
		[[ -n "${MODEL_PATH}" ]] && break
		sleep 1
	done
	[[ -n "${MODEL_PATH}" ]] || die 2 "the model did not arrive within 300 s"
	ok "the model arrived at ${MODEL_PATH}"
	leftovers="$(find "$(dirname -- "${MODEL_PATH}")" -name '.download-*' | wc -l)"
	((leftovers == 0)) && ok "no staging file left" || fail "staging files left beside the model"
fi
[[ "$(sha256sum "${MODEL_PATH}" | cut -d' ' -f1)" == "${MODEL_SHA}" ]] &&
	ok "R6.4 the model on disk has the pinned SHA-256" || fail "R6.4 the model's SHA-256 is not the pinned one"
[[ "$(dirname -- "${MODEL_PATH}")" == */voice/models ]] &&
	ok "R6.4 the model lives in <data_dir>/voice/models" || fail "the model is not under voice/models"
stop_if_failed "the download"

# ── 2: click → speak → click ───────────────────────────────────────────────
x mousemove "${MIC_X}" "${MIC_Y}" click 1 && sleep 1
speak one &
SPEAK_PID=$!
sleep 1.5
shot p4-recording.png
check_reads p4-recording.png "0:0" "R2.4 the elapsed time as m:ss while recording"
wait "${SPEAK_PID}"
x mousemove "${MIC_X}" "${MIC_Y}" click 1
shot p5-transcribing.png
if wait_reads p6-click-transcript.png "parser" 30; then
	ok "R2.1/R2.3 click, speak, click: the transcript landed"
	check_unsent_and_editable p7-click-edited.png "parser" "ENDONE"
else
	fail "no transcript containing \"parser\" within 30 s of the click stop"
fi

# ── 3: tap → speak → tap (toggle by shortcut) ──────────────────────────────
x key ctrl+alt+v && sleep 1
speak two
sleep 0.5
x key ctrl+alt+v
if wait_reads p8-tap-transcript.png "settings" 30; then
	ok "R2.2 a tap of ctrl+alt+v toggles recording"
	check_unsent_and_editable p9-tap-edited.png "settings" "ENDTWO"
else
	fail "no transcript containing \"settings\" after the tap toggle"
fi

# ── 4: hold while speaking (push-to-talk) ──────────────────────────────────
x keydown ctrl alt v && sleep 0.6
speak three
x keyup v alt ctrl
if wait_reads p10-hold-transcript.png "test" 30; then
	ok "R3.1 holding ctrl+alt+v records until the release"
	check_unsent_and_editable p11-hold-edited.png "test" "ENDTHREE"
else
	fail "no transcript containing \"test\" after the hold"
fi
quit

grep -E 'voice_input event=' "${PROFILE}"/logs/*.log "${PROFILE}"/zeo.log 2>/dev/null >"${OUT}/zeo-log-voice-excerpt.txt" || true
printf 'state kept for inspection: %s\n' "${STATE}"
exit "${failed}"
