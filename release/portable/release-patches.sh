# shellcheck shell=bash
# release_patches <series> -- the series as the release ships it: every group the
# package's default USE set enables. That is every group except `test` (tests
# only, applied by the ebuild under USE=test) and every group whose `@feature`
# line is followed by a `# @default: off` marker (its USE flag is off by
# default, e.g. ai-jail). The marker belongs to the group above it and is reset
# at the next `@feature`. Same order as the series.
#
# Sourced by build-in-container.sh (portable, in the image as /pkg) and by
# scripts/release-windows.sh, so the Linux and Windows releases ship one selection.
release_patches() {
	local series=$1 line group="" default_off=0
	while IFS= read -r line; do
		if [[ "${line}" =~ ^#[[:space:]]*@feature:[[:space:]]*([^[:space:]]+) ]]; then
			group="${BASH_REMATCH[1]}"
			default_off=0
			continue
		fi
		if [[ "${line}" =~ ^#[[:space:]]*@default:[[:space:]]*off[[:space:]]*$ ]]; then
			default_off=1
			continue
		fi
		[[ -z "${line}" || "${line}" == \#* || "${group}" == test ]] && continue
		((default_off)) && continue
		printf '%s\n' "${line}"
	done <"${series}"
}
