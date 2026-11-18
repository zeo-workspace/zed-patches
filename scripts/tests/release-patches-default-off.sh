#!/usr/bin/env bash
# Story 043, sub-task 10.5 (R10.5): the portable build's release_patches must skip a
# series group marked `# @default: off`, as it skips `test`, so the portable release
# matches the package's default USE set.
#
# The function lives in release/portable/release-patches.sh, sourced by both the
# portable (build-in-container.sh) and the Windows (release-windows.sh) builds, and
# takes the series file as its argument; here it is fed a fixture series.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${ZP_REPO:-$(cd "${here}/../.." && pwd)}"
script="${repo}/release/portable/release-patches.sh"
[[ -f "${script}" ]] || { echo "FAIL: ${script} not found" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

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

# shellcheck source=release/portable/release-patches.sh
source "${script}"
got="$(release_patches "${tmp}/series" | tr '\n' ' ')"
want="0001-base.patch 0035-on.patch 0054-voice.patch "

if [[ "${got}" != "${want}" ]]; then
	printf 'FAIL: release_patches listed [%s], want [%s]\n' "${got}" "${want}" >&2
	exit 1
fi
echo "PASS: default-off and test groups skipped; default-on groups kept in order"
