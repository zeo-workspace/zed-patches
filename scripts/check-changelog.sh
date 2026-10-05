#!/usr/bin/env bash
# Answer whether the packaged Zeo version has its section in Zeo's changelog.
#
#     check-changelog.sh [<PF>]
#
# Zeo's version is the X.Y.Z of the PF -- zeo-0.1.1_p20261004-r3 is 0.1.1: the
# snapshot date and the revision never need an entry of their own. The answer is
# yes only when CHANGELOG.md has a line beginning "## [X.Y.Z] — " outside a
# fenced code block; a mention anywhere else does not count (lib.sh
# changelog_section). The rules it enforces: zeo/docs/RELEASING.md.
#
# The changelog is ZP_CHANGELOG, else zeo/CHANGELOG.md beside this repository.
# With no <PF>, the version is the overlay's only zeo ebuild, as in check-sync.sh.
#
# check-sync.sh runs it, so bump.sh and status.sh report a missing entry as
# drift; release-portable.sh and release-zeo-bin.sh run it before building.
#
# Exit: 0 the section exists · 1 it does not · 2 environment problem (the
# changelog cannot be read, or the PF carries no X.Y.Z).

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
	printf 'usage: %s [<PF>]\n' "${0##*/}" >&2
	exit 2
}

# _sole_pf — the overlay's only zeo ebuild, or a refusal naming the candidates.
_sole_pf() {
	local dir="${ZP_OVERLAY}/${ZP_CATEGORY_PATH}" f
	local -a found=()
	for f in "${dir}"/*.ebuild; do
		[[ -e "${f}" ]] || continue
		f="${f##*/}"
		found+=("${f%.ebuild}")
	done
	((${#found[@]} > 0)) || die 2 "no ebuild in ${dir}"
	((${#found[@]} == 1)) || die 2 "more than one ebuild — name one: ${found[*]}"
	printf '%s' "${found[0]}"
}

main() {
	local pf="" arg
	for arg in "$@"; do
		case "${arg}" in
		-h | --help) usage ;;
		-*) die 2 "unknown option: ${arg}" ;;
		*)
			[[ -z "${pf}" ]] || die 2 "more than one version given: ${pf} and ${arg}"
			pf="${arg}"
			;;
		esac
	done
	if [[ -z "${pf}" ]]; then
		ZP_OVERLAY="$(_zp_overlay)"
		pf="$(_sole_pf)"
	fi

	local version changelog
	version="$(zeo_version_of "${pf}")" ||
		die 2 "no Zeo version (X.Y.Z) in ${pf} — expected zeo-<X.Y.Z>_p<YYYYMMDD>[-rN]"
	changelog="$(zeo_changelog)"
	[[ -f "${changelog}" && -r "${changelog}" ]] || die 2 "cannot read the changelog: ${changelog}"

	if changelog_section "${changelog}" "${version}" >/dev/null; then
		printf 'Zeo %s has its section in %s\n' "${version}" "${changelog}"
		return 0
	fi
	printf 'Zeo %s (%s) has no "## [%s] — <date>" section in %s\n' \
		"${version}" "${pf}" "${version}" "${changelog}" >&2
	return 1
}

main "$@"
