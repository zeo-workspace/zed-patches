#!/usr/bin/env bash
# Print one Zeo version's changelog section, for use as a GitHub release body.
#
#     changelog-notes.sh <X.Y.Z|PF>
#
# The body of the "## [X.Y.Z] — <date>" section of CHANGELOG.md, up to the next
# "## [" heading, without the heading itself and without the link reference
# definitions. A PF is reduced to its X.Y.Z, so zeo-0.1.1_p20261004-r3 prints
# the same bytes as 0.1.1. What counts as a section: lib.sh changelog_section.
#
#     gh release create v<PVR> ... -F <(scripts/changelog-notes.sh <PF>)
#
# The changelog is ZP_CHANGELOG, else zeo/CHANGELOG.md beside this repository.
#
# Exit: 0 printed · 1 the version has no section · 2 environment problem (the
# changelog cannot be read, or the argument carries no X.Y.Z).

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

main() {
	[[ $# -eq 1 && "${1}" != -* ]] || {
		printf 'usage: %s <X.Y.Z|PF>\n' "${0##*/}" >&2
		exit 2
	}
	local version changelog
	version="$(zeo_version_of "$1")" ||
		die 2 "no Zeo version (X.Y.Z) in $1 — expected X.Y.Z or zeo-<X.Y.Z>_p<YYYYMMDD>[-rN]"
	changelog="$(zeo_changelog)"
	[[ -f "${changelog}" && -r "${changelog}" ]] || die 2 "cannot read the changelog: ${changelog}"

	local notes
	notes="$(changelog_section "${changelog}" "${version}")" ||
		die 1 "Zeo ${version} has no \"## [${version}] — <date>\" section in ${changelog}"
	printf '%s\n' "${notes}"
}

main "$@"
