#!/usr/bin/env bash
# Story 043, sub-task 10.5 (R10.5): the portable build's release_patches must skip a
# series group marked `# @default: off`, as it skips `test`, so the portable release
# matches the package's default USE set.
#
# The function is extracted from build-in-container.sh (it is not sourceable: the
# script runs the whole build at top level) and fed a fixture series.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${ZP_REPO:-$(cd "${here}/../.." && pwd)}"
script="${repo}/release/portable/build-in-container.sh"
[[ -f "${script}" ]] || { echo "FAIL: ${script} not found" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Extract release_patches() { ... } up to its closing brace at column 0.
sed -n '/^release_patches() {/,/^}/p' "${script}" > "${tmp}/fn.sh"
[[ -s "${tmp}/fn.sh" ]] || { echo "FAIL: release_patches not found in ${script}" >&2; exit 1; }
# The function reads /in/patches/series; point it at the fixture instead.
sed -i "s#/in/patches/series#${tmp}/series#" "${tmp}/fn.sh"

cat > "${tmp}/series" <<'SERIES'
0001-base.patch
# @feature: claude-agent-acp-plus
0035-on.patch
# @feature: ai-jail
# @default: off
0053-jail.patch
# @feature: voice
0054-voice.patch
# @feature: test
0050-test.patch
SERIES

# shellcheck disable=SC1091
source "${tmp}/fn.sh"
got="$(release_patches | tr '\n' ' ')"
want="0001-base.patch 0035-on.patch 0054-voice.patch "

if [[ "${got}" != "${want}" ]]; then
	printf 'FAIL: release_patches listed [%s], want [%s]\n' "${got}" "${want}" >&2
	exit 1
fi
echo "PASS: default-off and test groups skipped; default-on groups kept in order"
