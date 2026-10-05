#!/usr/bin/env bash
# Prove a Zeo GUI change on a virtual display that never touches the operator's desktop.
#
#     xvfb-proof.sh --steps <file.json> [--dry-run] [--binary <path>]
#                   [--settings <file>] [--keymap <file>] [--keep <dir>]
#
# live-proof.py drives the real session through the KDE RemoteDesktop portal: a
# consent click, input injected at seat level into whatever has focus. This is the
# other route. It starts its own Xvfb, launches an isolated Zeo on it, replays the
# step script with xdotool and keeps only captures that decode at a sane size. No
# consent dialog, and no input can reach a display the run did not start.
#
# Steps use live-proof.py's JSON format -- an array of one-key objects:
#   {"type": "<text>"} | {"key": ["<keysym>", ...]} | {"chord": ["<mod>", ..., "<key>"]} |
#   {"click": [x, y]} | {"move": [x, y]} | {"sleep": <seconds, at most 60>} |
#   {"shot": "<path.png>"}
# A live-proof.py script without focus or drag steps runs here unchanged. One
# extension: a "key" name may be an xdotool combination ("ctrl+shift+p"), which
# live-proof.py rejects -- use "chord" in a script meant for both. A "window" field
# beside "shot" is accepted and ignored: the capture is always the whole screen.
# The whole script is validated before anything starts; --dry-run stops there and
# prints the plan.
#
# --binary   the editor to launch (default /usr/libexec/zeo-editor)
# --settings, --keymap   copied into the isolated config directory before launch
# --keep     use <dir> as the isolated state and keep it, so a second run reopens
#            the same threads; without it a temporary directory is removed on exit
#
# X11 only, software rendering (llvmpipe): what this proves is behaviour, not
# Wayland, not GPU rendering.
#
# Test hooks: XVFB_PROOF_X11_ROOT (default /tmp, where .X11-unix and .X<N>-lock
# live), XVFB_PROOF_TMP_ROOT (default /tmp, where the zp-XXXX directory is made),
# XVFB_PROOF_XVFB_TIMEOUT (5 s), XVFB_PROOF_WINDOW_TIMEOUT (60 s).
#
# Exit: 0 ok · 1 refused/failed · 2 environment problem.

set -euo pipefail

# lib.sh is linted on its own; not following it keeps this file clean from any cwd.
# shellcheck disable=SC1091
source "${BASH_SOURCE[0]%/*}/lib.sh"

STEPS_FILE=""
DRY_RUN=0
BINARY="/usr/libexec/zeo-editor"
SETTINGS=""
KEYMAP=""
KEEP=""

X11_ROOT="${XVFB_PROOF_X11_ROOT:-/tmp}"
TMP_ROOT="${XVFB_PROOF_TMP_ROOT:-/tmp}"
XVFB_TIMEOUT="${XVFB_PROOF_XVFB_TIMEOUT:-5}"
WINDOW_TIMEOUT="${XVFB_PROOF_WINDOW_TIMEOUT:-60}"

# Zeo's sockets live under its data dir, and a Unix socket path is capped near
# 108 bytes; 60 leaves room for the names Zeo appends.
readonly MAX_WORKDIR_BYTES=60

# Run state: only what this run started is ever driven or stopped.
WORKDIR=""
XVFB_DISPLAY=""
XVFB_PID=""
ZEO_PID=""
SLEEP_PID=""
WINDOW_ID=""

# One entry per step, filled by validate_steps; values are read back from the file.
STEP_KINDS=()

usage() {
	sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
	exit 2
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--steps | --binary | --settings | --keymap | --keep)
			[[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die 2 "$1 needs a value"
			;;
		esac
		case "$1" in
		--steps) STEPS_FILE="$2" && shift ;;
		--dry-run) DRY_RUN=1 ;;
		--binary) BINARY="$2" && shift ;;
		--settings) SETTINGS="$2" && shift ;;
		--keymap) KEYMAP="$2" && shift ;;
		--keep) KEEP="$2" && shift ;;
		-h | --help) usage ;;
		*) die 2 "unknown argument: $1" ;;
		esac
		shift
	done
	[[ -n "${STEPS_FILE}" ]] || die 2 "--steps <file.json> is required"
}

# The jq program that checks every step and emits one line per step:
#   ok<TAB><n><TAB><kind>   or   err<TAB><n><TAB><kind><TAB><what is wrong>
# <n> is 1-based. A step is one object with exactly one kind key; "window" is
# accepted beside "shot" because live-proof.py reads it there.
# shellcheck disable=SC2016  # jq program, not shell
readonly STEP_CHECK='
def kinds: ["type", "key", "chord", "click", "move", "sleep", "shot"];
def point: type == "array" and length == 2 and all(.[]; type == "number" and . >= 0 and . == floor);
def check($k; $v):
  if $k == "type" then ($v | type == "string" and length > 0) // false
  elif $k == "key" then ($v | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) // false
  elif $k == "chord" then ($v | type == "array" and length >= 2 and all(.[]; type == "string" and length > 0)) // false
  elif $k == "click" or $k == "move" then ($v | point) // false
  elif $k == "sleep" then ($v | type == "number" and . > 0 and . <= 60) // false
  elif $k == "shot" then ($v | type == "string" and length > 0) // false
  else false end;
def need($k):
  {"type": "a non-empty string", "key": "a non-empty list of keysyms",
   "chord": "modifiers then a key, at least two keysyms",
   "click": "[x, y] in whole pixels", "move": "[x, y] in whole pixels", "sleep": "seconds, above 0 and at most 60",
   "shot": "a file path"}[$k];
if type != "array" then "err\t0\t-\tthe step script is not a JSON array"
else
  to_entries[] | (.key + 1) as $n | .value as $s |
  if ($s | type) != "object" then "err\t\($n)\t-\tnot an object"
  else
    ($s | keys_unsorted | map(select(. != "window"))) as $ks |
    if ($ks | length) != 1 then "err\t\($n)\t\($ks | join(",") | if . == "" then "-" else . end)\tneeds exactly one kind"
    elif (kinds | index($ks[0])) == null then "err\t\($n)\t\($ks[0])\tunknown kind"
    elif ($s | has("window")) and $ks[0] != "shot" then "err\t\($n)\t\($ks[0])\t\"window\" belongs to shot only"
    elif check($ks[0]; $s[$ks[0]]) then "ok\t\($n)\t\($ks[0])"
    else "err\t\($n)\t\($ks[0])\tneeds \(need($ks[0]))"
    end
  end
end
'

# validate_steps — check the whole script; exit 1 listing every bad step.
validate_steps() {
	local lines status n kind what errors=0
	command -v jq >/dev/null || die 2 "jq is not on PATH"
	[[ -f "${STEPS_FILE}" && -r "${STEPS_FILE}" ]] || die 2 "cannot read the step script: ${STEPS_FILE}"
	lines="$(jq -r "${STEP_CHECK}" "${STEPS_FILE}" 2>&1)" ||
		die 1 "the step script is not valid JSON: ${STEPS_FILE}: ${lines}"
	[[ -n "${lines}" ]] || die 1 "the step script has no steps: ${STEPS_FILE}"
	while IFS=$'\t' read -r status n kind what; do
		if [[ "${status}" == ok ]]; then
			STEP_KINDS+=("${kind}")
		else
			printf 'error: step %s (%s): %s\n' "${n}" "${kind}" "${what}" >&2
			errors=$((errors + 1))
		fi
	done <<<"${lines}"
	[[ "${errors}" -eq 0 ]] || die 1 "${errors} invalid step(s) in ${STEPS_FILE}; nothing was started"
}

# step_value <index0> <kind> — the step's value as text (lists space-joined).
step_value() {
	jq -j --argjson i "$1" --arg k "$2" '.[$i][$k] | if type == "array" then map(tostring) | join(" ") else tostring end' "${STEPS_FILE}"
}

print_plan() {
	local i
	printf 'plan: %d steps from %s\n' "${#STEP_KINDS[@]}" "${STEPS_FILE}"
	for i in "${!STEP_KINDS[@]}"; do
		printf '  %d %s %s\n' "$((i + 1))" "${STEP_KINDS[i]}" "$(step_value "${i}" "${STEP_KINDS[i]}")"
	done
}

# --- isolation ----------------------------------------------------------------

setup_workdir() {
	if [[ -n "${KEEP}" ]]; then
		mkdir -p -- "${KEEP}" || die 2 "cannot create the --keep directory: ${KEEP}"
		WORKDIR="$(cd -- "${KEEP}" && pwd)"
		printf 'workdir: %s\n' "${WORKDIR}"
		printf 'kept: %s survives this run\n' "${WORKDIR}"
	else
		WORKDIR="$(mktemp -d "${TMP_ROOT}/zp-XXXX")" || die 2 "cannot create a temporary directory under ${TMP_ROOT}"
		printf 'workdir: %s\n' "${WORKDIR}"
	fi
	[[ "${#WORKDIR}" -le "${MAX_WORKDIR_BYTES}" ]] ||
		die 2 "the isolated directory is ${#WORKDIR} bytes, over the ${MAX_WORKDIR_BYTES} bytes a Unix socket under it allows: ${WORKDIR}"
}

# --- lifecycle -----------------------------------------------------------------

# alive <pid> — running, and not a zombie waiting to be reaped.
alive() {
	local state
	kill -0 "$1" 2>/dev/null || return 1
	state="$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" || return 1
	[[ "${state}" != Z ]]
}

# mine <pid> — the process is still a child of this run. A recorded PID that
# died and was reused by something else is never signalled.
mine() {
	[[ -n "$1" && "$(awk '{print $4}' "/proc/$1/stat" 2>/dev/null)" == "$$" ]]
}

# stop <pid> [group] — SIGTERM, up to 5 s of grace, then SIGKILL. With "group",
# the whole process group the PID leads: Zeo's own children (agent servers, the
# CLI it spawns) go with it.
stop() {
	local pid="$1" target="$1" tries
	mine "${pid}" || return 0
	[[ "${2-}" != group ]] || target="-${pid}"
	kill -TERM -- "${target}" 2>/dev/null || true
	for ((tries = 50; tries > 0; tries--)); do
		alive "${pid}" || break
		sleep 0.1
	done
	if alive "${pid}"; then
		printf 'warning: pid %s ignored SIGTERM for 5 s; killing it\n' "${pid}" >&2
		kill -KILL -- "${target}" 2>/dev/null || true
	fi
	wait "${pid}" 2>/dev/null || true
}

# cleanup — on every exit: stop what this run started, newest first, then drop
# the temporary directory unless --keep named it.
cleanup() {
	trap - EXIT INT TERM
	stop "${SLEEP_PID}"
	stop "${ZEO_PID}" group
	stop "${XVFB_PID}"
	if [[ -n "${WORKDIR}" && -z "${KEEP}" ]]; then
		rm -rf -- "${WORKDIR}"
	fi
}

# display_number <display> — the N of [host]:N[.screen], empty when there is none.
display_number() {
	local d="${1##*:}"
	d="${d%%.*}"
	[[ "${d}" =~ ^[0-9]+$ ]] && printf '%s' "${d}"
	return 0
}

# pick_display — the first :N (N >= 90) with neither a socket nor a lock file.
pick_display() {
	local n
	for ((n = 90; n < 200; n++)); do
		[[ -e "${X11_ROOT}/.X11-unix/X${n}" || -e "${X11_ROOT}/.X${n}-lock" ]] && continue
		printf ':%d' "${n}"
		return 0
	done
	die 2 "no free display between :90 and :199 under ${X11_ROOT}"
}

start_xvfb() {
	local display log tries
	display="$(pick_display)"
	log="${WORKDIR}/xvfb.log"
	Xvfb "${display}" -screen 0 1920x1080x24 >"${log}" 2>&1 &
	XVFB_PID=$!
	XVFB_DISPLAY="${display}"
	for ((tries = XVFB_TIMEOUT * 10; tries > 0; tries--)); do
		kill -0 "${XVFB_PID}" 2>/dev/null ||
			die 2 "Xvfb exited while starting on ${display} (log: ${log})"
		[[ -e "${X11_ROOT}/.X11-unix/X${display#:}" ]] && {
			printf 'display: %s (Xvfb pid %s)\n' "${display}" "${XVFB_PID}"
			return 0
		}
		sleep 0.1
	done
	die 2 "Xvfb did not start on ${display} within ${XVFB_TIMEOUT} s (log: ${log})"
}

# guard_display <display> — exit 1 unless <display> is the live Xvfb this run
# started and is not the operator's own DISPLAY. Called before Zeo is launched
# onto it and again before every input step.
guard_display() {
	local target="$1" mine
	[[ -n "${XVFB_DISPLAY}" && "${target}" == "${XVFB_DISPLAY}" ]] ||
		die 1 "refusing input on ${target}: this run did not start it"
	mine="$(display_number "${DISPLAY-}")"
	[[ -z "${mine}" || "${mine}" != "$(display_number "${target}")" ]] ||
		die 1 "refusing input on ${target}: it is the operator's DISPLAY (${DISPLAY})"
	kill -0 "${XVFB_PID}" 2>/dev/null ||
		die 1 "refusing input on ${target}: the Xvfb this run started is gone"
}

# launch_zeo — start the editor on the private display with state of its own.
#
# --user-data-dir alone makes it a separate instance: on Linux the socket a second
# launch would hand its arguments to lives under the data dir. ZED_STATELESS is
# stripped rather than set, so a --keep directory keeps its threads.
launch_zeo() {
	local log="${WORKDIR}/zeo.log"
	[[ -x "${BINARY}" ]] || die 2 "the editor is not executable: ${BINARY}"
	mkdir -p "${WORKDIR}/config" "${WORKDIR}/cache" "${WORKDIR}/state" ||
		die 2 "cannot create config/, cache/ and state/ under ${WORKDIR}"
	if [[ -n "${SETTINGS}" ]]; then
		cp -- "${SETTINGS}" "${WORKDIR}/config/settings.json" || die 2 "cannot copy the settings: ${SETTINGS}"
	fi
	if [[ -n "${KEYMAP}" ]]; then
		cp -- "${KEYMAP}" "${WORKDIR}/config/keymap.json" || die 2 "cannot copy the keymap: ${KEYMAP}"
	fi
	guard_display "${XVFB_DISPLAY}"
	# setsid makes Zeo lead its own process group, so stop() can take its
	# children with it; in a non-interactive shell it execs without forking.
	env -u ZED_STATELESS \
		WAYLAND_DISPLAY= \
		DISPLAY="${XVFB_DISPLAY}" \
		ZED_ALLOW_EMULATED_GPU=1 \
		XDG_CACHE_HOME="${WORKDIR}/cache" \
		XDG_STATE_HOME="${WORKDIR}/state" \
		setsid "${BINARY}" --user-data-dir "${WORKDIR}" >"${log}" 2>&1 &
	ZEO_PID=$!
	printf 'zeo: pid %s, log %s\n' "${ZEO_PID}" "${log}"
}

# wait_for_window — the first visible window on the private display, or exit 2.
wait_for_window() {
	local log="${WORKDIR}/zeo.log" tries
	for ((tries = WINDOW_TIMEOUT * 2; tries > 0; tries--)); do
		kill -0 "${ZEO_PID}" 2>/dev/null ||
			die 2 "Zeo exited before showing a window (log: ${log})"
		WINDOW_ID="$(DISPLAY="${XVFB_DISPLAY}" xdotool search --onlyvisible --name . 2>/dev/null | head -n 1)" || true
		if [[ -n "${WINDOW_ID}" ]]; then
			printf 'window: %s\n' "${WINDOW_ID}"
			return 0
		fi
		sleep 0.5
	done
	die 2 "no Zeo window appeared within ${WINDOW_TIMEOUT} s (log: ${log})"
}

# --- driving -------------------------------------------------------------------

# A capture smaller than this on either side is not evidence: a 1x1 PNG once sat
# among committed proofs looking exactly like one.
readonly MIN_CAPTURE_PX=200

# xdo <args...> — xdotool on the private display, after the guard.
xdo() {
	guard_display "${XVFB_DISPLAY}"
	DISPLAY="${XVFB_DISPLAY}" xdotool "$@"
}

# take_shot <n> <path> — capture the virtual screen and keep it only if sane.
take_shot() {
	local n="$1" path="$2" geom w h
	mkdir -p -- "$(dirname -- "${path}")" || die 1 "step ${n} (shot): cannot create the directory of ${path}"
	guard_display "${XVFB_DISPLAY}"
	DISPLAY="${XVFB_DISPLAY}" import -window root "${path}" ||
		die 1 "step ${n} (shot): import failed for ${path}"
	geom="$(identify -format '%w %h' "${path}" 2>/dev/null)" || {
		rm -f -- "${path}"
		die 1 "step ${n} (shot): ${path} does not decode as an image; deleted"
	}
	read -r w h <<<"${geom}"
	if ! [[ "${w}" =~ ^[0-9]+$ && "${h}" =~ ^[0-9]+$ ]] ||
		((w < MIN_CAPTURE_PX || h < MIN_CAPTURE_PX)); then
		rm -f -- "${path}"
		die 1 "step ${n} (shot): ${path} is ${w}x${h}, under ${MIN_CAPTURE_PX} px on a side; deleted"
	fi
	printf 'step %d: shot %s (%sx%s)\n' "${n}" "${path}" "${w}" "${h}"
}

run_steps() {
	local i n kind value x y keys=()
	for i in "${!STEP_KINDS[@]}"; do
		n=$((i + 1))
		kind="${STEP_KINDS[i]}"
		[[ "${kind}" == shot ]] || printf 'step %d: %s\n' "${n}" "${kind}"
		case "${kind}" in
		type)
			value="$(jq -j --argjson i "${i}" '.[$i].type' "${STEPS_FILE}")"
			xdo type --delay 20 -- "${value}" || die 1 "step ${n} (type): xdotool failed"
			;;
		key)
			mapfile -t keys < <(jq -r --argjson i "${i}" '.[$i].key[]' "${STEPS_FILE}")
			xdo key -- "${keys[@]}" || die 1 "step ${n} (key): xdotool failed on ${keys[*]}"
			;;
		chord)
			# live-proof.py's chord: modifiers held, the last name pressed.
			mapfile -t keys < <(jq -r --argjson i "${i}" '.[$i].chord[]' "${STEPS_FILE}")
			value="$(
				IFS=+
				printf '%s' "${keys[*]}"
			)"
			xdo key -- "${value}" || die 1 "step ${n} (chord): xdotool failed on ${value}"
			;;
		click | move)
			read -r x y <<<"$(step_value "${i}" "${kind}")"
			if [[ "${kind}" == click ]]; then
				xdo mousemove "${x}" "${y}" click 1 || die 1 "step ${n} (click): xdotool failed at ${x},${y}"
			else
				xdo mousemove "${x}" "${y}" || die 1 "step ${n} (move): xdotool failed at ${x},${y}"
			fi
			;;
		sleep)
			# In the background and waited on: bash runs a signal trap only
			# once the foreground command returns, and wait returns at once.
			sleep "$(step_value "${i}" sleep)" &
			SLEEP_PID=$!
			wait "${SLEEP_PID}" || true
			SLEEP_PID=""
			;;
		shot)
			take_shot "${n}" "$(step_value "${i}" shot)"
			;;
		esac
	done
	printf 'done: %d steps on %s\n' "${#STEP_KINDS[@]}" "${XVFB_DISPLAY}"
}

main() {
	parse_args "$@"
	validate_steps
	print_plan
	[[ "${DRY_RUN}" -eq 0 ]] || exit 0
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	command -v Xvfb >/dev/null || die 2 "Xvfb is not on PATH"
	command -v xdotool >/dev/null || die 2 "xdotool is not on PATH"
	command -v import >/dev/null || die 2 "import (ImageMagick) is not on PATH"
	command -v identify >/dev/null || die 2 "identify (ImageMagick) is not on PATH"
	command -v setsid >/dev/null || die 2 "setsid (util-linux) is not on PATH"
	setup_workdir
	start_xvfb
	launch_zeo
	wait_for_window
	run_steps
}

main "$@"
