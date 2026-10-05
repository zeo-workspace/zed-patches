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
#   {"type": "<text>"} | {"key": ["<keysym>", ...]} | {"click": [x, y]} |
#   {"move": [x, y]} | {"sleep": <seconds, at most 60>} | {"shot": "<path.png>"}
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
# live), XVFB_PROOF_XVFB_TIMEOUT (5 s), XVFB_PROOF_WINDOW_TIMEOUT (60 s).
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

# One entry per step, filled by validate_steps; values are read back from the file.
STEP_KINDS=()

usage() {
	sed -n '2,/^# Exit:/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
	exit 2
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--steps) STEPS_FILE="${2-}" && shift ;;
		--dry-run) DRY_RUN=1 ;;
		--binary) BINARY="${2-}" && shift ;;
		--settings) SETTINGS="${2-}" && shift ;;
		--keymap) KEYMAP="${2-}" && shift ;;
		--keep) KEEP="${2-}" && shift ;;
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
def kinds: ["type", "key", "click", "move", "sleep", "shot"];
def point: type == "array" and length == 2 and all(.[]; type == "number" and . >= 0);
def check($k; $v):
  if $k == "type" then ($v | type == "string" and length > 0) // false
  elif $k == "key" then ($v | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) // false
  elif $k == "click" or $k == "move" then ($v | point) // false
  elif $k == "sleep" then ($v | type == "number" and . > 0 and . <= 60) // false
  elif $k == "shot" then ($v | type == "string" and length > 0) // false
  else false end;
def need($k):
  {"type": "a non-empty string", "key": "a non-empty list of keysyms",
   "click": "[x, y]", "move": "[x, y]", "sleep": "seconds, above 0 and at most 60",
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

main() {
	parse_args "$@"
	validate_steps
	print_plan
	[[ "${DRY_RUN}" -eq 0 ]] || exit 0
	die 2 "only --dry-run is implemented"
}

main "$@"
