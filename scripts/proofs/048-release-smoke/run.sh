#!/usr/bin/env bash
# Story 048, task 6.3 — smoke proof of a released Zeo on a private X display (E2E).
#
#     run.sh --version <X.Y.Z> --out <docs/assets/048-release-PVR> [--binary <zeo-editor>]
#
# What it proves (R5.3): the editor the operator emerged opens a window, and its About names
# the released Zeo version. Run after the operator has emerged the release; the default
# binary is the installed /usr/libexec/zeo-editor.
#
# How: one xvfb-proof.sh run with an isolated --keep directory (never the operator's profile):
# wait for the window, capture it, open the command palette, run "about", capture again. The
# About capture is read with tesseract and must contain "Zeo <X.Y.Z>". Before the release is
# installed the installed About names the previous version: that is this proof's Red.
#
# Exit: 0 proven · 1 a check failed · 2 environment problem (missing tool, harness refused).

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
[[ -x "${BINARY}" ]] || die 2 "--binary must name an executable zeo-editor: ${BINARY}"
[[ -n "${OUT}" ]] || die 2 "--out is required"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 2 "--version must be X.Y.Z, got: ${VERSION:-<empty>}"
[[ -x "${HARNESS}" ]] || die 2 "harness not found: ${HARNESS}"
for tool in tesseract xdotool Xvfb; do
	command -v "${tool}" >/dev/null || die 2 "missing tool: ${tool}"
done

mkdir -p -- "${OUT}"
OUT="$(cd -- "${OUT}" && pwd)"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/zp048-XXXX")"
trap 'rm -rf -- "${STATE}"' EXIT

cat >"${STATE}/steps.json" <<STEPS
[
  {"sleep": 10},
  {"shot": "${OUT}/proof-1-window.png"},
  {"chord": ["ctrl", "shift", "p"]},
  {"sleep": 1},
  {"type": "about"},
  {"sleep": 1},
  {"key": ["Return"]},
  {"sleep": 3},
  {"shot": "${OUT}/proof-2-about.png"}
]
STEPS

if ! bash "${HARNESS}" --steps "${STATE}/steps.json" --binary "${BINARY}" --keep "${STATE}/keep"; then
	die 2 "xvfb-proof.sh refused or failed; see its output above"
fi

[[ -s "${OUT}/proof-1-window.png" ]] || die 1 "no window capture: the editor did not open a window"
[[ -s "${OUT}/proof-2-about.png" ]] || die 1 "no About capture"

# This host's tesseract cannot decode PNG (story 041's finding); hand it 8-bit greyscale PGM.
# The About dialog is small and centred: OCR of the whole screen misses it, so read a
# centre crop scaled 3x.
python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("L"); w, h = im.size
box = (w // 2 - 260, h // 2 - 280, w // 2 + 260, h // 2 + 120)
im.crop(box).resize(((box[2] - box[0]) * 3, (box[3] - box[1]) * 3)).save(sys.argv[2])' \
	"${OUT}/proof-2-about.png" "${STATE}/about.pgm" || die 2 "could not convert the About capture to PGM (python3 + Pillow)"
text="$(tesseract "${STATE}/about.pgm" - 2>/dev/null || true)"
if ! grep -qF "Zeo ${VERSION}" <<<"${text}"; then
	printf 'run.sh: the About capture does not read "Zeo %s"; OCR text follows\n%s\n' "${VERSION}" "${text}" >&2
	exit 1
fi
printf 'run.sh: PASS — the released editor opened and its About names Zeo %s\n' "${VERSION}"
