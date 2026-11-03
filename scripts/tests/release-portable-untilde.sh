#!/usr/bin/env bash
# Story 073, sub-task 4.1 (R4.2): the portable release names every artefact the way
# GitHub serves it. GitHub stores an asset whose name holds "~" under "." (0.7.1's .deb
# and .rpm), so a SHA256SUMS written over the local "~" names listed files the release
# does not serve, and `sha256sum -c` failed on the downloaded set.
#
# The function is extracted from release-portable.sh (sourcing it would run main) and
# fed a fixture directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${ZP_REPO:-$(cd "${here}/../.." && pwd)}"
script="${repo}/scripts/release-portable.sh"
[[ -f "${script}" ]] || {
	echo "FAIL: ${script} not found" >&2
	exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

sed -n '/^untilde_artefacts() {/,/^}/p' "${script}" >"${tmp}/fn.sh"
[[ -s "${tmp}/fn.sh" ]] || {
	echo "FAIL: untilde_artefacts not found in ${script}" >&2
	exit 1
}

dist="${tmp}/dist"
mkdir -p "${dist}"
printf 'deb' >"${dist}/zeo_0.8.0~p20261101-1_amd64.deb"
printf 'rpm' >"${dist}/zeo-0.8.0~p20261101-1.x86_64.rpm"
printf 'tar' >"${dist}/zeo-0.8.0_p20261101-x86_64.tar.xz"

# shellcheck disable=SC1091
source "${tmp}/fn.sh"
untilde_artefacts "${dist}"

got="$(cd "${dist}" && ls | LC_ALL=C sort | tr '\n' ' ')"
want="zeo-0.8.0.p20261101-1.x86_64.rpm zeo-0.8.0_p20261101-x86_64.tar.xz zeo_0.8.0.p20261101-1_amd64.deb "
[[ "${got}" == "${want}" ]] || {
	printf 'FAIL: got [%s]\n      want [%s]\n' "${got}" "${want}" >&2
	exit 1
}
[[ "$(cat "${dist}/zeo_0.8.0.p20261101-1_amd64.deb")" == deb ]] || {
	echo "FAIL: the .deb lost its bytes" >&2
	exit 1
}

(cd "${dist}" && sha256sum -- * >SHA256SUMS)
if grep -q '~' "${dist}/SHA256SUMS"; then
	echo "FAIL: SHA256SUMS still names a file with ~" >&2
	exit 1
fi

echo "PASS: ~ becomes . in every artefact name; a name without ~ is left alone"
